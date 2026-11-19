// SPDX-License-Identifier: GPL-2.0-or-later

import Combine
import Foundation
import GuestHostCore

nonisolated struct OfficialCatalogImage: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let androidMajor: String
    let kernelVersion: String
    let pageProfile: String
    let approximateDownloadBytes: UInt64
    let downloadURL: URL
    let defaultDataGiB: Int
    let releaseTag: String
    let sourceName: String
    let sourcePageURL: URL
    let badgeText: String?
    let publishedLabel: String?

    var shortRevision: String {
        if let range = id.range(of: "los24-") {
            return String(id[range.lowerBound...])
        }
        return releaseTag
    }

    static let builtinCatalog: [OfficialCatalogImage] = [
        OfficialCatalogImage(
            id: "lineage24-mainline6.18-4k-20261115-los24-r28",
            title: "LineageOS 24 (Android 17)",
            subtitle: "Bản phát hành r28 cập nhật (Mesa / Vulkan + ARM64 & 32-bit)",
            androidMajor: "17",
            kernelVersion: "Linux 6.18 LTS",
            pageProfile: "4 KiB Guest",
            approximateDownloadBytes: 1_042_700_000,
            downloadURL: URL(string: "https://github.com/imxieyi/Kernarium/releases/download/1.0b15-release/lineage24-mainline6.18-4k-20261115-los24-r28.tar.gz")!,
            defaultDataGiB: 16,
            releaseTag: "1.0b15-release",
            sourceName: "Kernarium Releases",
            sourcePageURL: URL(string: "https://github.com/imxieyi/Kernarium/releases/tag/1.0b15-release")!,
            badgeText: "Mới nhất",
            publishedLabel: "2026-11-15"
        ),
        OfficialCatalogImage(
            id: "lineage24-mainline6.18-4k-20261110-los24-r22",
            title: "LineageOS 24 (Android 17)",
            subtitle: "Bản chuẩn r22 ổn định (Vulkan / Mesa + ARM64 & 32-bit)",
            androidMajor: "17",
            kernelVersion: "Linux 6.18 LTS",
            pageProfile: "4 KiB Guest",
            approximateDownloadBytes: 1_034_840_000,
            downloadURL: URL(string: "https://github.com/imxieyi/Kernarium/releases/download/1.0b9-beta/lineage24-mainline6.18-4k-20261110-los24-r22.tar.gz")!,
            defaultDataGiB: 16,
            releaseTag: "1.0b9-beta",
            sourceName: "Kernarium Releases",
            sourcePageURL: URL(string: "https://github.com/imxieyi/Kernarium/releases/tag/1.0b9-beta")!,
            badgeText: "Ổn định",
            publishedLabel: "2026-11-10"
        )
    ]

    static var catalog: [OfficialCatalogImage] { builtinCatalog }
}

nonisolated struct OfficialWebsiteSource: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let subtitle: String
    let url: URL
    let iconName: String

    static let all: [OfficialWebsiteSource] = [
        OfficialWebsiteSource(
            id: "kernarium-releases",
            name: "GitHub Releases — Kernarium",
            subtitle: "Kho ROM chính thức Android 17 / LineageOS 24 (.tar.gz, 4 KiB Page)",
            url: URL(string: "https://github.com/imxieyi/Kernarium/releases")!,
            iconName: "shippingbox"
        ),
        OfficialWebsiteSource(
            id: "dynarium-releases",
            name: "GitHub Releases — Dynarium",
            subtitle: "Trang phát hành chính thức các bản IPA (Universal & Metal 4)",
            url: URL(string: "https://github.com/userlethekhoi/dynarium/releases")!,
            iconName: "arrow.down.app"
        ),
        OfficialWebsiteSource(
            id: "lineageos-official",
            name: "LineageOS Official",
            subtitle: "Trang chủ dự án mã nguồn mở LineageOS",
            url: URL(string: "https://lineageos.org")!,
            iconName: "globe"
        )
    ]
}

private nonisolated struct GitHubReleaseDTO: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let name: String
        let size: UInt64
        let browser_download_url: String
    }

    let tag_name: String
    let html_url: String
    let published_at: String?
    let draft: Bool
    let assets: [Asset]

    var publishedDateLabel: String? {
        guard let published_at, published_at.count >= 10 else { return nil }
        return String(published_at.prefix(10))
    }
}

nonisolated struct SystemImageManifest: Codable, Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    var name: String
    var version: String
    var androidMajor: String
    var sourceDescription: String
    var directoryName: String
    var systemLogicalBytes: UInt64
    var systemSha256: String
    var verified: Bool
    var installedAt: Date
}

nonisolated enum ImageInstallPhase: Equatable, Sendable {
    case downloading(bytesReceived: UInt64, totalBytes: UInt64, speedBytesPerSecond: Double)
    case extracting(fraction: Double, entry: String, sparseSavedBytes: UInt64)
    case verifyingSHA256

    var title: String {
        switch self {
        case .downloading: "Đang tải gói ROM\u{2026}"
        case .extracting: "Đang giải nén thưa (APFS Sparse)\u{2026}"
        case .verifyingSHA256: "Đang kiểm tra toàn vẹn SHA-256\u{2026}"
        }
    }
}

nonisolated struct ImageInstallState: Equatable, Sendable {
    let title: String
    var phase: ImageInstallPhase
}

nonisolated enum SystemImageError: LocalizedError, Sendable {
    case invalidReleaseLayout(String)
    case sha256Mismatch(expected: String, actual: String)
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .invalidReleaseLayout(let detail):
            return "Cấu trúc ROM không hợp lệ: \(detail)"
        case .sha256Mismatch(let expected, let actual):
            return "Mã kiểm tra SHA-256 không khớp (kỳ vọng \(expected.prefix(12)), thực tế \(actual.prefix(12)))."
        case .invalidURL:
            return "Đường dẫn tải ROM không hợp lệ."
        }
    }
}

private nonisolated struct PartitionLayoutContract: Decodable {
    struct SystemDisk: Decodable {
        let sizeBytes: UInt64
        let sha256: String

        enum CodingKeys: String, CodingKey {
            case sizeBytes = "size_bytes"
            case sha256
        }
    }

    let schemaVersion: Int
    let systemDisk: SystemDisk

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case systemDisk = "system_disk"
    }
}

private nonisolated struct ReleaseManifestContract: Decodable {
    let releaseID: String?
    let androidMajor: Int?

    enum CodingKeys: String, CodingKey {
        case releaseID = "release_id"
        case androidMajor = "android_major"
    }
}

@MainActor
final class SystemImageStore: NSObject, ObservableObject {
    static let shared = SystemImageStore()

    @Published private(set) var images: [SystemImageManifest] = []
    @Published private(set) var activeInstall: ImageInstallState?
    @Published var lastErrorMessage: String?
    @Published private(set) var catalogImages: [OfficialCatalogImage] = OfficialCatalogImage.builtinCatalog
    @Published private(set) var isRefreshingCatalog = false
    @Published private(set) var catalogLastRefreshed: Date?
    @Published private(set) var catalogRefreshError: String?

    private let rootURL: URL
    private let indexURL: URL
    private var downloadSession: URLSession?
    private var currentDownloadTask: URLSessionDownloadTask?
    private var downloadContinuation: CheckedContinuation<URL, Error>?
    private var activeTask: Task<Void, Never>?
    private var lastSpeedSampleTime = Date()
    private var lastSpeedSampleBytes: UInt64 = 0
    private var currentSpeedBps: Double = 0

    override private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.rootURL = docs.appendingPathComponent("Dynarium/Images", isDirectory: true)
        self.indexURL = rootURL.appendingPathComponent("images.json")
        super.init()

        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 60 * 60 * 4
        self.downloadSession = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)

        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        load()
    }

    func releaseURL(for image: SystemImageManifest) -> URL {
        rootURL.appendingPathComponent(image.directoryName, isDirectory: true)
    }

    func allocatedBytes(for image: SystemImageManifest) -> UInt64 {
        let systemImg = releaseURL(for: image)
            .appendingPathComponent("guest/system.img")
        let values = try? systemImg.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey])
        if let alloc = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize {
            return UInt64(max(alloc, 0))
        }
        return image.systemLogicalBytes
    }

    func isBusy() -> Bool {
        activeInstall != nil
    }

    func installCatalogImage(_ item: OfficialCatalogImage) {
        let displayName = item.shortRevision.isEmpty
            ? item.title
            : "\(item.title) · \(item.shortRevision)"
        installFromRemoteURL(
            item.downloadURL,
            preferredName: displayName,
            sourceDescription: "Kho chính thức (\(item.sourceName) • \(item.releaseTag) • \(item.id))"
        )
    }

    func refreshOfficialCatalogIfNeeded() async {
        if let last = catalogLastRefreshed, Date().timeIntervalSince(last) < 600 {
            return
        }
        await refreshOfficialCatalog()
    }

    func refreshOfficialCatalog() async {
        guard !isRefreshingCatalog else { return }
        isRefreshingCatalog = true
        catalogRefreshError = nil
        defer { isRefreshingCatalog = false }

        let feeds: [(name: String, url: URL)] = [
            ("Dynarium Releases", URL(string: "https://api.github.com/repos/userlethekhoi/dynarium/releases?per_page=10")!),
            ("Kernarium Releases", URL(string: "https://api.github.com/repos/imxieyi/Kernarium/releases?per_page=10")!)
        ]

        let builtinByID = Dictionary(
            uniqueKeysWithValues: OfficialCatalogImage.builtinCatalog.map { ($0.id, $0) }
        )

        var discovered: [OfficialCatalogImage] = []
        var seenIDs = Set<String>()
        var succeededFeedCount = 0
        var lastErrorDescription: String?

        for feed in feeds {
            do {
                let items = try await Self.fetchCatalogFeed(
                    from: feed.url,
                    sourceName: feed.name,
                    builtinByID: builtinByID
                )
                succeededFeedCount += 1
                for item in items where seenIDs.insert(item.id).inserted {
                    discovered.append(item)
                }
            } catch {
                lastErrorDescription = error.localizedDescription
            }
        }

        if succeededFeedCount == 0 {
            catalogRefreshError = lastErrorDescription ?? "Không thể tải danh sách phiên bản mới từ GitHub."
            return
        }

        for item in OfficialCatalogImage.builtinCatalog where seenIDs.insert(item.id).inserted {
            discovered.append(item)
        }

        discovered.sort { lhs, rhs in
            let lDate = lhs.publishedLabel ?? ""
            let rDate = rhs.publishedLabel ?? ""
            if lDate != rDate {
                return lDate > rDate
            }
            return lhs.id > rhs.id
        }

        catalogImages = discovered
        catalogLastRefreshed = Date()
    }

    private static func fetchCatalogFeed(
        from url: URL,
        sourceName: String,
        builtinByID: [String: OfficialCatalogImage]
    ) async throws -> [OfficialCatalogImage] {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Dynarium-iOS", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 403 || http.statusCode == 429 {
                throw NSError(
                    domain: "DynariumCatalog",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "GitHub API tạm giới hạn truy vấn. Vui lòng thử lại sau ít phút hoặc mở trang phát hành."]
                )
            }
            guard (200..<300).contains(http.statusCode) else {
                throw NSError(
                    domain: "DynariumCatalog",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "Máy chủ phản hồi mã HTTP \(http.statusCode)."]
                )
            }
        }

        let releases = try JSONDecoder().decode([GitHubReleaseDTO].self, from: data)
        let supportedExts = [".tar.zst", ".tar.gz", ".tgz"]
        var items: [OfficialCatalogImage] = []

        for release in releases where !release.draft {
            for asset in release.assets {
                let lower = asset.name.lowercased()
                guard let matchedExt = supportedExts.first(where: { lower.hasSuffix($0) }) else {
                    continue
                }
                guard asset.size >= 150 * 1024 * 1024 else { continue }
                guard !lower.hasPrefix("android-6."),
                      !lower.contains("-kernel"),
                      !lower.contains("linux-") else {
                    continue
                }
                guard lower.contains("lineage") || lower.contains("android") || lower.contains("rom") else {
                    continue
                }
                guard let downloadURL = URL(string: asset.browser_download_url),
                      let pageURL = URL(string: release.html_url) else {
                    continue
                }

                let cleanID = String(asset.name.dropLast(matchedExt.count))
                if let curated = builtinByID[cleanID] {
                    items.append(
                        OfficialCatalogImage(
                            id: curated.id,
                            title: curated.title,
                            subtitle: curated.subtitle,
                            androidMajor: curated.androidMajor,
                            kernelVersion: curated.kernelVersion,
                            pageProfile: curated.pageProfile,
                            approximateDownloadBytes: asset.size > 0 ? asset.size : curated.approximateDownloadBytes,
                            downloadURL: downloadURL,
                            defaultDataGiB: curated.defaultDataGiB,
                            releaseTag: curated.releaseTag,
                            sourceName: sourceName,
                            sourcePageURL: pageURL,
                            badgeText: curated.badgeText,
                            publishedLabel: release.publishedDateLabel ?? curated.publishedLabel
                        )
                    )
                } else {
                    let androidMajor = (lower.contains("lineage24") || lower.contains("android17")) ? "17" : "Android"
                    let title = lower.contains("lineage24")
                        ? "LineageOS 24 (Android 17)"
                        : "Android ROM (\(release.tag_name))"
                    items.append(
                        OfficialCatalogImage(
                            id: cleanID,
                            title: title,
                            subtitle: "Phát hành \(release.tag_name) từ \(sourceName)",
                            androidMajor: androidMajor,
                            kernelVersion: lower.contains("6.18") ? "Linux 6.18 LTS" : "User-Mode Linux",
                            pageProfile: lower.contains("4k") ? "4 KiB Guest" : "Android ROM",
                            approximateDownloadBytes: asset.size,
                            downloadURL: downloadURL,
                            defaultDataGiB: 16,
                            releaseTag: release.tag_name,
                            sourceName: sourceName,
                            sourcePageURL: pageURL,
                            badgeText: "Trực tuyến",
                            publishedLabel: release.publishedDateLabel
                        )
                    )
                }
            }
        }

        return items
    }

    func installFromRemoteURL(
        _ url: URL,
        preferredName: String,
        sourceDescription: String
    ) {
        guard !isBusy() else { return }
        lastErrorMessage = nil
        activeInstall = ImageInstallState(
            title: preferredName,
            phase: .downloading(bytesReceived: 0, totalBytes: 0, speedBytesPerSecond: 0)
        )

        activeTask = Task {
            do {
                let downloadedURL = try await performDownload(from: url)
                defer { try? FileManager.default.removeItem(at: downloadedURL) }
                try await extractAndRegister(
                    archiveURL: downloadedURL,
                    preferredName: preferredName,
                    sourceDescription: sourceDescription
                )
                activeInstall = nil
            } catch is CancellationError {
                activeInstall = nil
            } catch {
                activeInstall = nil
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    func importLocalArchive(at fileURL: URL, preferredName: String? = nil) {
        guard !isBusy() else { return }
        lastErrorMessage = nil
        let name = preferredName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = (name?.isEmpty == false ? name! : fileURL.deletingPathExtension().lastPathComponent)
        activeInstall = ImageInstallState(
            title: resolvedName,
            phase: .extracting(fraction: 0, entry: fileURL.lastPathComponent, sparseSavedBytes: 0)
        )

        activeTask = Task {
            let scoped = fileURL.startAccessingSecurityScopedResource()
            defer {
                if scoped { fileURL.stopAccessingSecurityScopedResource() }
            }
            do {
                try await extractAndRegister(
                    archiveURL: fileURL,
                    preferredName: resolvedName,
                    sourceDescription: "Nhập từ Tệp (\(fileURL.lastPathComponent))"
                )
                activeInstall = nil
            } catch is CancellationError {
                activeInstall = nil
            } catch {
                activeInstall = nil
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    func cancelActiveInstall() {
        currentDownloadTask?.cancel()
        currentDownloadTask = nil
        activeTask?.cancel()
        activeTask = nil
        activeInstall = nil
    }

    func deleteImage(_ image: SystemImageManifest) {
        let dir = releaseURL(for: image)
        try? FileManager.default.removeItem(at: dir)
        images.removeAll { $0.id == image.id }
        save()
    }

    // MARK: - Pipeline

    private func performDownload(from url: URL) async throws -> URL {
        guard let session = downloadSession else { throw SystemImageError.invalidURL }
        lastSpeedSampleTime = Date()
        lastSpeedSampleBytes = 0
        currentSpeedBps = 0

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.downloadContinuation = continuation
                let task = session.downloadTask(with: url)
                self.currentDownloadTask = task
                task.resume()
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.currentDownloadTask?.cancel()
            }
        }
    }

    private func extractAndRegister(
        archiveURL: URL,
        preferredName: String,
        sourceDescription: String
    ) async throws {
        let imageID = UUID()
        let stageDir = rootURL.appendingPathComponent(".stage-\(imageID.uuidString)", isDirectory: true)
        let finalDir = rootURL.appendingPathComponent(imageID.uuidString, isDirectory: true)

        try? FileManager.default.removeItem(at: stageDir)
        defer { try? FileManager.default.removeItem(at: stageDir) }

        let progressCallback: @Sendable (ExtractionProgress) -> Void = { [weak self] prog in
            Task { @MainActor [weak self] in
                guard let self, self.activeInstall != nil else { return }
                self.activeInstall?.phase = .extracting(
                    fraction: prog.fraction,
                    entry: prog.currentEntry,
                    sparseSavedBytes: prog.sparseSkippedBytes
                )
            }
        }

        try await Task.detached(priority: .userInitiated) {
            try ArchiveExtractor.extractTarArchive(
                from: archiveURL,
                to: stageDir,
                progress: progressCallback
            )
        }.value

        try Task.checkCancellation()
        activeInstall?.phase = .verifyingSHA256

        let manifest = try await Task.detached(priority: .userInitiated) {
            let releaseRoot = try Self.locateReleaseRoot(inside: stageDir)
            let guestDir = releaseRoot.appendingPathComponent("guest", isDirectory: true)
            let systemImgURL = guestDir.appendingPathComponent("system.img")
            let layoutURL = guestDir.appendingPathComponent("partition-layout.json")
            let cmdlineURL = releaseRoot.appendingPathComponent("boot/kernel-command-line.txt")

            let fm = FileManager.default
            guard fm.fileExists(atPath: systemImgURL.path),
                  fm.fileExists(atPath: layoutURL.path),
                  fm.fileExists(atPath: cmdlineURL.path) else {
                throw SystemImageError.invalidReleaseLayout("Thiếu guest/system.img, partition-layout.json hoặc boot/kernel-command-line.txt")
            }

            let layoutData = try Data(contentsOf: layoutURL)
            let layout = try JSONDecoder().decode(PartitionLayoutContract.self, from: layoutData)
            guard layout.schemaVersion == 2 else {
                throw SystemImageError.invalidReleaseLayout("schema_version không khớp (\(layout.schemaVersion))")
            }

            let actualSha = try ArchiveExtractor.sha256Hex(of: systemImgURL)
            let expectedSha = layout.systemDisk.sha256.lowercased()
            guard actualSha == expectedSha else {
                throw SystemImageError.sha256Mismatch(expected: expectedSha, actual: actualSha)
            }

            var detectedVersion = "20261110-los24"
            var detectedAndroid = "17"
            let manifestJSON = releaseRoot.appendingPathComponent("release-manifest.json")
            if let mData = try? Data(contentsOf: manifestJSON),
               let parsed = try? JSONDecoder().decode(ReleaseManifestContract.self, from: mData) {
                if let rid = parsed.releaseID { detectedVersion = rid }
                if let amaj = parsed.androidMajor { detectedAndroid = "\(amaj)" }
            }

            try? fm.removeItem(at: finalDir)
            try fm.moveItem(at: releaseRoot, to: finalDir)

            return SystemImageManifest(
                id: imageID,
                name: preferredName,
                version: detectedVersion,
                androidMajor: detectedAndroid,
                sourceDescription: sourceDescription,
                directoryName: imageID.uuidString,
                systemLogicalBytes: layout.systemDisk.sizeBytes,
                systemSha256: actualSha,
                verified: true,
                installedAt: Date()
            )
        }.value

        images.insert(manifest, at: 0)
        save()
    }

    nonisolated private static func locateReleaseRoot(inside directory: URL) throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.appendingPathComponent("guest/system.img").path) {
            return directory
        }
        let entries = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for entry in entries {
            if fm.fileExists(atPath: entry.appendingPathComponent("guest/system.img").path) {
                return entry
            }
        }
        throw SystemImageError.invalidReleaseLayout("Không tìm thấy thư mục guest/system.img trong tệp ROM")
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([SystemImageManifest].self, from: data) else {
            return
        }
        images = decoded.filter {
            FileManager.default.fileExists(atPath: releaseURL(for: $0).appendingPathComponent("guest/system.img").path)
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(images) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}

extension SystemImageStore: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.activeInstall != nil else { return }
            let now = Date()
            let dt = now.timeIntervalSince(self.lastSpeedSampleTime)
            if dt >= 0.5 {
                let delta = totalBytesWritten > Int64(self.lastSpeedSampleBytes)
                    ? Double(UInt64(totalBytesWritten) - self.lastSpeedSampleBytes)
                    : 0
                self.currentSpeedBps = delta / dt
                self.lastSpeedSampleTime = now
                self.lastSpeedSampleBytes = UInt64(max(0, totalBytesWritten))
            }
            let total = totalBytesExpectedToWrite > 0 ? UInt64(totalBytesExpectedToWrite) : 0
            self.activeInstall?.phase = .downloading(
                bytesReceived: UInt64(max(0, totalBytesWritten)),
                totalBytes: total,
                speedBytesPerSecond: self.currentSpeedBps
            )
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Move downloaded temporary file immediately before delegate callback returns.
        let safeTemp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dynarium-dl-\(UUID().uuidString).tar.gz")
        do {
            try? FileManager.default.removeItem(at: safeTemp)
            try FileManager.default.moveItem(at: location, to: safeTemp)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let cont = self.downloadContinuation
                self.downloadContinuation = nil
                self.currentDownloadTask = nil
                cont?.resume(returning: safeTemp)
            }
        } catch {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let cont = self.downloadContinuation
                self.downloadContinuation = nil
                self.currentDownloadTask = nil
                cont?.resume(throwing: error)
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        Task { @MainActor [weak self] in
            guard let self, let cont = self.downloadContinuation else { return }
            self.downloadContinuation = nil
            self.currentDownloadTask = nil
            if (error as NSError).code == NSURLErrorCancelled {
                cont.resume(throwing: CancellationError())
            } else {
                cont.resume(throwing: error)
            }
        }
    }
}
