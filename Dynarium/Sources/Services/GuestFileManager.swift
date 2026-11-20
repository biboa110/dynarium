// SPDX-License-Identifier: GPL-2.0-or-later

import Combine
import Darwin
import Foundation
import GuestHostCore

nonisolated enum GuestStoragePath {
    static let root = "/storage/emulated/0"
    static let downloads = "/storage/emulated/0/Download"
    static let dcim = "/storage/emulated/0/DCIM"
    static let pictures = "/storage/emulated/0/Pictures"
    static let documents = "/storage/emulated/0/Documents"

    static func child(_ name: String, of folder: String) -> String {
        folder == "/" ? "/" + name : folder + "/" + name
    }

    static func name(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? ""
    }

    static func parent(of path: String) -> String {
        if path == root { return root }
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return root }
        let candidate = String(path[path.startIndex..<slash])
        return isInsideRoot(candidate) ? candidate : root
    }

    static func isInsideRoot(_ path: String) -> Bool {
        guard path == root || path.hasPrefix(root + "/") else { return false }
        return path.dropFirst(root.count)
            .split(separator: "/", omittingEmptySubsequences: false)
            .dropFirst()
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
            && name.utf8.count <= 255
    }

    static func freeName(for name: String, taken: Set<String>) -> String {
        if !taken.contains(name) { return name }
        let ns = name as NSString
        let base = ns.deletingPathExtension
        let suffix = ns.pathExtension
        var count = 1
        while true {
            let candidate = suffix.isEmpty ? "\(base) (\(count))" : "\(base) (\(count)).\(suffix)"
            if !taken.contains(candidate) { return candidate }
            count += 1
        }
    }

    static func temporaryPath(in folder: String, token: String) -> String {
        child(".dynarium-\(token).part", of: folder)
    }

    static func isPartial(_ name: String) -> Bool {
        name.hasPrefix(".dynarium-") && name.hasSuffix(".part")
    }

    private static let uriSafe = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/"
    )

    static func uriPath(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: uriSafe) ?? path
    }

    static func scanCommand(for path: String) -> String {
        "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d \(AdbShellQuote.quote("file://" + uriPath(path)))"
    }

    static func finishCommand(temporary: String, path: String) -> String {
        let from = AdbShellQuote.quote(temporary)
        let to = AdbShellQuote.quote(path)
        return "if [ -e \(to) ] || [ -L \(to) ]; then exit 17; fi; mv -- \(from) \(to) && { \(scanCommand(for: path)) >/dev/null 2>&1; true; }"
    }

    static func removeCommand(for temporary: String) -> String {
        "rm -f -- \(AdbShellQuote.quote(temporary))"
    }

    static func removeStaleCommand(in folder: String) -> String {
        "rm -f -- \(AdbShellQuote.quote(folder))/.dynarium-*.part"
    }

    static func freeSpaceCommand(for path: String) -> String {
        "df -Pk \(AdbShellQuote.quote(path))"
    }

    static func parseFreeSpace(_ output: String) -> UInt64? {
        let lines = output.split(whereSeparator: \.isNewline).map {
            $0.split(whereSeparator: { $0 == " " || $0 == "\t" })
        }
        guard lines.count >= 2, let row = lines.last, row.count >= 4, let kib = UInt64(row[3]) else {
            return nil
        }
        let (bytes, overflow) = kib.multipliedReportingOverflow(by: 1024)
        return overflow ? nil : bytes
    }
}

nonisolated struct GuestStorageEntry: Identifiable, Hashable, Sendable {
    var path: String
    var isFolder: Bool
    var size: UInt64
    var modified: Date

    var id: String { path }
    var name: String { GuestStoragePath.name(of: path) }
    var isSingleApk: Bool { !isFolder && name.lowercased().hasSuffix(".apk") }
}

nonisolated struct HostSharedFile: Identifiable, Hashable, Sendable {
    var url: URL
    var name: String
    var size: UInt64
    var modified: Date

    var id: String { url.path }
    var isApkPackage: Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "apk" || ext == "apks" || ext == "apkm" || ext == "xapk" || ext == "zip"
    }
}

nonisolated enum HostSharedInbox {
    static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    static var sharedDirectoryURL: URL {
        documentsURL.appendingPathComponent("Shared", isDirectory: true)
    }

    static var exportsTempDirectoryURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("DynariumExports", isDirectory: true)
    }

    static func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(at: sharedDirectoryURL, withIntermediateDirectories: true)
    }

    static func sweepExports() {
        try? FileManager.default.removeItem(at: exportsTempDirectoryURL)
    }

    static func listFiles() -> [HostSharedFile] {
        ensureDirectoryExists()
        var results: [HostSharedFile] = []
        var seenPaths = Set<String>()

        for dir in [sharedDirectoryURL, documentsURL] {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for url in urls {
                let name = url.lastPathComponent
                if name.hasPrefix(".") || name == "Inbox" { continue }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
                guard values?.isDirectory != true, values?.isRegularFile != false else { continue }
                let resolvedPath = url.resolvingSymlinksInPath().path
                guard seenPaths.insert(resolvedPath).inserted else { continue }
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? UInt64(max(values?.fileSize ?? 0, 0))
                let modified = (attrs?[.modificationDate] as? Date) ?? values?.contentModificationDate ?? Date()
                results.append(HostSharedFile(url: url, name: name, size: size, modified: modified))
            }
        }

        return results.sorted { lhs, rhs in
            if lhs.modified != rhs.modified {
                return lhs.modified > rhs.modified
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

nonisolated enum GuestTransferState: Equatable, Sendable {
    case idle
    case transferring(title: String, detail: String, progress: Double?)
    case completed(String)
    case failed(String)

    var isBusy: Bool {
        if case .transferring = self { return true }
        return false
    }
}

private nonisolated enum GuestFileTransferError: LocalizedError, Sendable {
    case directoryNotSupported(String)
    case guestFull(needed: String, free: String)
    case deviceFull(needed: String, free: String)
    case changed(String)
    case badPath(String)
    case folderRefused
    case folderMissing

    var errorDescription: String? {
        switch self {
        case let .directoryNotSupported(name):
            return L10n.f("files.err.directory_not_supported", name)
        case let .guestFull(needed, free):
            return L10n.f("files.err.guest_full", needed, free)
        case let .deviceFull(needed, free):
            return L10n.f("files.err.device_full", needed, free)
        case let .changed(name):
            return L10n.f("files.err.changed", name)
        case let .badPath(path):
            return L10n.f("files.err.bad_path", path)
        case .folderRefused:
            return L10n.t("files.folder.refused")
        case .folderMissing:
            return L10n.t("files.folder.missing")
        }
    }
}

private nonisolated struct GuestListingResult: Sendable {
    var folder: String
    var entries: [GuestStorageEntry]
    var freeBytes: UInt64?
}

private nonisolated struct GuestWalkItem: Sendable {
    var relativePath: String
    var isFolder: Bool
    var size: UInt64
    var modified: Date
}

@MainActor
final class GuestFileManager: ObservableObject {
    @Published private(set) var currentFolder: String = GuestStoragePath.downloads
    @Published private(set) var entries: [GuestStorageEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?
    @Published private(set) var guestFreeBytes: UInt64?
    @Published private(set) var transferState: GuestTransferState = .idle
    @Published private(set) var sharedInboxFiles: [HostSharedFile] = []

    private var activeLoadGeneration = UUID()
    private var activeLoadTask: Task<Void, Never>?
    private var activeLoadSessionHolder: AdbSessionHolder?

    private var activeTransferGeneration = UUID()
    private var activeTransferTask: Task<Void, Never>?
    private var activeTransferSessionHolder: AdbSessionHolder?
    private var activeTransferCoordinator: AdbFileCoordinatorBox?

    private nonisolated static let hostReserveBytes: UInt64 = 256 * 1024 * 1024
    private nonisolated static let guestReserveBytes: UInt64 = 256 * 1024 * 1024

    func refreshSharedInbox() {
        sharedInboxFiles = HostSharedInbox.listFiles()
    }

    func load(folder: String, vmID: UUID, clock: AdbRunClock, allowDownloadFallback: Bool = false) {
        let targetFolder = GuestStoragePath.isInsideRoot(folder) ? folder : GuestStoragePath.root
        activeLoadSessionHolder?.cancel()
        activeLoadTask?.cancel()

        let generation = UUID()
        activeLoadGeneration = generation
        let sessionHolder = AdbSessionHolder()
        activeLoadSessionHolder = sessionHolder

        currentFolder = targetFolder
        isLoading = true
        loadError = nil

        activeLoadTask = Task {
            do {
                let listing = try await Self.performList(
                    folder: targetFolder,
                    allowDownloadFallback: allowDownloadFallback,
                    vmID: vmID,
                    clock: clock,
                    sessionHolder: sessionHolder
                )
                guard self.activeLoadGeneration == generation else { return }
                self.currentFolder = listing.folder
                self.entries = listing.entries
                self.guestFreeBytes = listing.freeBytes
                self.loadError = nil
                self.isLoading = false
            } catch is CancellationError {
                guard self.activeLoadGeneration == generation else { return }
                self.isLoading = false
            } catch let adbErr as AdbError where adbErr == .cancelled {
                guard self.activeLoadGeneration == generation else { return }
                self.isLoading = false
            } catch let adbErr as AdbError {
                guard self.activeLoadGeneration == generation else { return }
                self.entries = []
                self.loadError = adbErr.localizedMessage
                self.isLoading = false
            } catch {
                guard self.activeLoadGeneration == generation else { return }
                self.entries = []
                self.loadError = error.localizedDescription
                self.isLoading = false
            }
            if self.activeLoadGeneration == generation {
                self.activeLoadSessionHolder = nil
                self.activeLoadTask = nil
            }
        }
    }

    func uploadFiles(urls: [URL], toFolder targetFolder: String? = nil, vmID: UUID, clock: AdbRunClock) {
        guard !transferState.isBusy, !urls.isEmpty else { return }
        let destinationFolder = targetFolder ?? currentFolder
        guard GuestStoragePath.isInsideRoot(destinationFolder) else {
            transferState = .failed(GuestFileTransferError.badPath(destinationFolder).localizedDescription)
            return
        }

        // Acquire security scope immediately before any UIKit picker unwinds.
        let scopedEntries: [(url: URL, scoped: Bool)] = urls.map { url in
            (url, url.startAccessingSecurityScopedResource())
        }
        let generation = UUID()
        activeTransferGeneration = generation
        let coordinator = AdbFileCoordinatorBox()
        let sessionHolder = AdbSessionHolder()
        activeTransferCoordinator = coordinator
        activeTransferSessionHolder = sessionHolder

        let title = L10n.t("files.transfer.uploading_title")
        let initialDetail = urls.count == 1
            ? L10n.f("files.transfer.preparing", urls[0].lastPathComponent)
            : L10n.f("files.transfer.preparing", "\(urls.count)")
        transferState = .transferring(title: title, detail: initialDetail, progress: 0)

        activeTransferTask = Task {
            defer {
                for item in scopedEntries where item.scoped {
                    item.url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let uploadedCount = try await Self.performUpload(
                    urls: urls,
                    destinationFolder: destinationFolder,
                    vmID: vmID,
                    clock: clock,
                    coordinator: coordinator,
                    sessionHolder: sessionHolder
                ) { [weak self] detail, progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.activeTransferGeneration == generation else { return }
                        self.transferState = .transferring(title: title, detail: detail, progress: progress)
                    }
                }
                guard self.activeTransferGeneration == generation else { return }
                let message = uploadedCount == 1
                    ? L10n.f("files.transfer.uploaded_one", urls[0].lastPathComponent, GuestStoragePath.name(of: destinationFolder))
                    : L10n.f("files.transfer.uploaded_many", String(uploadedCount), GuestStoragePath.name(of: destinationFolder))
                self.transferState = .completed(message)
                self.load(folder: destinationFolder, vmID: vmID, clock: clock)
            } catch is CancellationError {
                guard self.activeTransferGeneration == generation else { return }
                self.transferState = .idle
            } catch let adbErr as AdbError where adbErr == .cancelled {
                guard self.activeTransferGeneration == generation else { return }
                self.transferState = .idle
            } catch let adbErr as AdbError {
                guard self.activeTransferGeneration == generation else { return }
                self.transferState = .failed(adbErr.localizedMessage)
            } catch {
                guard self.activeTransferGeneration == generation else { return }
                self.transferState = .failed(error.localizedDescription)
            }
            if self.activeTransferGeneration == generation {
                self.activeTransferCoordinator = nil
                self.activeTransferSessionHolder = nil
                self.activeTransferTask = nil
            }
        }
    }

    func exportEntry(_ entry: GuestStorageEntry, vmID: UUID, clock: AdbRunClock) {
        guard !transferState.isBusy else { return }
        guard GuestStoragePath.isInsideRoot(entry.path) else {
            transferState = .failed(GuestFileTransferError.badPath(entry.path).localizedDescription)
            return
        }

        let generation = UUID()
        activeTransferGeneration = generation
        let sessionHolder = AdbSessionHolder()
        activeTransferSessionHolder = sessionHolder

        let title = L10n.t("files.transfer.exporting_title")
        transferState = .transferring(title: title, detail: L10n.f("files.transfer.preparing", entry.name), progress: 0)

        let stagingDir = HostSharedInbox.exportsTempDirectoryURL.appendingPathComponent(UUID().uuidString, isDirectory: true)

        activeTransferTask = Task {
            do {
                let exportedURL = try await Self.performExport(
                    entry: entry,
                    stagingDir: stagingDir,
                    vmID: vmID,
                    clock: clock,
                    sessionHolder: sessionHolder
                ) { [weak self] detail, progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.activeTransferGeneration == generation else { return }
                        self.transferState = .transferring(title: title, detail: detail, progress: progress)
                    }
                }
                guard self.activeTransferGeneration == generation else {
                    try? FileManager.default.removeItem(at: stagingDir)
                    return
                }
                let presented = HostSharePresenter.present([exportedURL]) { _ in
                    try? FileManager.default.removeItem(at: stagingDir)
                }
                if presented {
                    self.transferState = .completed(L10n.f("files.transfer.exported", entry.name))
                } else {
                    try? FileManager.default.removeItem(at: stagingDir)
                    self.transferState = .failed(L10n.t("files.err.share_unavailable"))
                }
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: stagingDir)
                guard self.activeTransferGeneration == generation else { return }
                self.transferState = .idle
            } catch let adbErr as AdbError where adbErr == .cancelled {
                try? FileManager.default.removeItem(at: stagingDir)
                guard self.activeTransferGeneration == generation else { return }
                self.transferState = .idle
            } catch let adbErr as AdbError {
                try? FileManager.default.removeItem(at: stagingDir)
                guard self.activeTransferGeneration == generation else { return }
                self.transferState = .failed(adbErr.localizedMessage)
            } catch {
                try? FileManager.default.removeItem(at: stagingDir)
                guard self.activeTransferGeneration == generation else { return }
                self.transferState = .failed(error.localizedDescription)
            }
            if self.activeTransferGeneration == generation {
                self.activeTransferSessionHolder = nil
                self.activeTransferTask = nil
            }
        }
    }

    func installGuestApk(_ entry: GuestStorageEntry, vmID: UUID, clock: AdbRunClock) {
        guard !transferState.isBusy, entry.isSingleApk else { return }
        guard GuestStoragePath.isInsideRoot(entry.path) else {
            transferState = .failed(GuestFileTransferError.badPath(entry.path).localizedDescription)
            return
        }

        let generation = UUID()
        activeTransferGeneration = generation
        let sessionHolder = AdbSessionHolder()
        activeTransferSessionHolder = sessionHolder

        let title = L10n.t("files.transfer.installing_title")
        transferState = .transferring(title: title, detail: L10n.f("apk.installing_single", entry.name), progress: nil)

        activeTransferTask = Task {
            do {
                let message = try await Self.performGuestApkInstall(
                    entry: entry,
                    vmID: vmID,
                    clock: clock,
                    sessionHolder: sessionHolder
                )
                guard self.activeTransferGeneration == generation else { return }
                self.transferState = .completed(message)
            } catch is CancellationError {
                guard self.activeTransferGeneration == generation else { return }
                self.transferState = .idle
            } catch let adbErr as AdbError where adbErr == .cancelled {
                guard self.activeTransferGeneration == generation else { return }
                self.transferState = .idle
            } catch let adbErr as AdbError {
                guard self.activeTransferGeneration == generation else { return }
                self.transferState = .failed(adbErr.localizedMessage)
            } catch {
                guard self.activeTransferGeneration == generation else { return }
                self.transferState = .failed(error.localizedDescription)
            }
            if self.activeTransferGeneration == generation {
                self.activeTransferSessionHolder = nil
                self.activeTransferTask = nil
            }
        }
    }

    func cancelTransfer() {
        activeTransferGeneration = UUID()
        activeTransferCoordinator?.cancel()
        activeTransferSessionHolder?.cancel()
        activeTransferTask?.cancel()
        activeTransferCoordinator = nil
        activeTransferSessionHolder = nil
        activeTransferTask = nil
        if transferState.isBusy {
            transferState = .idle
        }
    }

    func dismissTransferStatus() {
        if !transferState.isBusy {
            transferState = .idle
        }
    }

    func reset() {
        activeLoadGeneration = UUID()
        activeLoadSessionHolder?.cancel()
        activeLoadTask?.cancel()
        activeLoadSessionHolder = nil
        activeLoadTask = nil

        cancelTransfer()

        currentFolder = GuestStoragePath.downloads
        entries = []
        isLoading = false
        loadError = nil
        guestFreeBytes = nil
        transferState = .idle
        HostSharedInbox.sweepExports()
    }

    // MARK: - Synchronous ADB Worker Implementations

    nonisolated private static func performList(
        folder: String,
        allowDownloadFallback: Bool,
        vmID: UUID,
        clock: AdbRunClock,
        sessionHolder: AdbSessionHolder
    ) async throws -> GuestListingResult {
        try await AdbThreadRunner.run(
            name: "dynarium-files-list",
            onCancel: { sessionHolder.cancel() }
        ) {
            let identity = try AdbKeyStore.forVM(vmID).loadOrCreate()
            let session = AdbSession(signer: identity.signer, clock: clock)
            sessionHolder.set(session)

            return try session.run { conn in
                session.watchdog.arm(idle: 30, overall: 120)
                var chosenFolder = folder
                do {
                    let listed = try listSingleFolder(chosenFolder, connection: conn)
                    let free = queryGuestFreeBytes(on: conn)
                    return GuestListingResult(folder: chosenFolder, entries: listed, freeBytes: free)
                } catch GuestFileTransferError.folderMissing where allowDownloadFallback && chosenFolder == GuestStoragePath.downloads {
                    chosenFolder = GuestStoragePath.root
                    let listed = try listSingleFolder(chosenFolder, connection: conn)
                    let free = queryGuestFreeBytes(on: conn)
                    return GuestListingResult(folder: chosenFolder, entries: listed, freeBytes: free)
                }
            }
        }
    }

    nonisolated private static func listSingleFolder(
        _ folder: String,
        connection: AdbConnection
    ) throws -> [GuestStorageEntry] {
        guard GuestStoragePath.isInsideRoot(folder) else {
            throw GuestFileTransferError.badPath(folder)
        }
        let sync = try AdbSync(connection: connection)
        var raw = [AdbDirectoryEntry]()
        var entries = [GuestStorageEntry]()
        do {
            raw = try sync.list(folder)
            raw.removeAll { $0.name == "." || $0.name == ".." }
            for item in raw where !item.name.hasPrefix(".") {
                var mode = item.mode
                var size = item.size
                var modified = item.modified
                if item.isSymlink {
                    let target = try sync.stat(GuestStoragePath.child(item.name, of: folder))
                    guard target.exists else { continue }
                    mode = target.mode
                    size = target.size
                    modified = target.modified
                }
                let type = mode & AdbFileMode.typeMask
                guard type == AdbFileMode.directory || type == AdbFileMode.regular else { continue }
                let isFolder = (type == AdbFileMode.directory)
                entries.append(GuestStorageEntry(
                    path: GuestStoragePath.child(item.name, of: folder),
                    isFolder: isFolder,
                    size: isFolder ? 0 : size,
                    modified: Date(timeIntervalSince1970: TimeInterval(modified))
                ))
            }
        } catch {
            sync.quit()
            throw error
        }
        sync.quit()

        if raw.isEmpty {
            try checkReadable(folder, on: connection)
        }

        return entries.sorted { lhs, rhs in
            if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    nonisolated private static func checkReadable(_ folder: String, on connection: AdbConnection) throws {
        let result = try connection.runShell("ls -A -- \(AdbShellQuote.quote(folder)) >/dev/null")
        guard result.exitCode != 0 else { return }
        let stderr = String(decoding: result.stderr, as: UTF8.self)
        if stderr.contains("No such file") || stderr.contains("Not a directory") {
            throw GuestFileTransferError.folderMissing
        }
        throw GuestFileTransferError.folderRefused
    }

    nonisolated private static func queryGuestFreeBytes(on connection: AdbConnection) -> UInt64? {
        guard let res = try? connection.runShell(GuestStoragePath.freeSpaceCommand(for: GuestStoragePath.root)),
              res.exitCode == 0 else { return nil }
        return GuestStoragePath.parseFreeSpace(res.text)
    }

    nonisolated private static func performUpload(
        urls: [URL],
        destinationFolder: String,
        vmID: UUID,
        clock: AdbRunClock,
        coordinator: AdbFileCoordinatorBox,
        sessionHolder: AdbSessionHolder,
        onProgress: @escaping @Sendable (String, Double?) -> Void
    ) async throws -> Int {
        try await AdbThreadRunner.run(
            name: "dynarium-files-upload",
            onCancel: {
                coordinator.cancel()
                sessionHolder.cancel()
            }
        ) {
            let identity = try AdbKeyStore.forVM(vmID).loadOrCreate()
            let session = AdbSession(signer: identity.signer, clock: clock)
            sessionHolder.set(session)

            return try session.run { conn in
                session.watchdog.arm(idle: 30, overall: 90)
                if destinationFolder == GuestStoragePath.downloads {
                    _ = try? conn.runShell("mkdir -p \(AdbShellQuote.quote(destinationFolder))")
                }
                _ = try? conn.runShell(GuestStoragePath.removeStaleCommand(in: destinationFolder))
                let existing = try listSingleFolder(destinationFolder, connection: conn)
                var takenNames = Set(existing.map(\.name))
                var remainingGuestFree = queryGuestFreeBytes(on: conn)

                var uploadedCount = 0
                let totalFiles = urls.count

                for (index, url) in urls.enumerated() {
                    guard !sessionHolder.isCancelled else { throw CancellationError() }
                    try coordinator.coordinateReading(at: url) { readableURL in
                        guard !sessionHolder.isCancelled else { throw CancellationError() }
                        let values = try readableURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                        if values.isDirectory == true {
                            throw GuestFileTransferError.directoryNotSupported(readableURL.lastPathComponent)
                        }

                        let attrs = try FileManager.default.attributesOfItem(atPath: readableURL.path)
                        let fileSize = (attrs[.size] as? NSNumber)?.uint64Value ?? UInt64(max(values.fileSize ?? 0, 0))
                        let modified = (attrs[.modificationDate] as? Date) ?? values.contentModificationDate ?? Date()
                        let rawName = readableURL.lastPathComponent
                        guard GuestStoragePath.isValidName(rawName) else {
                            throw GuestFileTransferError.badPath(rawName)
                        }

                        let hostFree = HostStorage.freeBytes()
                        if hostFree > 0, hostFree < fileSize || (hostFree - fileSize) < hostReserveBytes {
                            throw GuestFileTransferError.deviceFull(
                                needed: Formats.size(bytes: fileSize),
                                free: Formats.size(bytes: hostFree)
                            )
                        }
                        if let free = remainingGuestFree,
                           free < fileSize || (free - fileSize) < guestReserveBytes {
                            throw GuestFileTransferError.guestFull(
                                needed: Formats.size(bytes: fileSize),
                                free: Formats.size(bytes: free)
                            )
                        }

                        let finalName = GuestStoragePath.freeName(for: rawName, taken: takenNames)
                        takenNames.insert(finalName)
                        let finalPath = GuestStoragePath.child(finalName, of: destinationFolder)
                        let tempPath = GuestStoragePath.temporaryPath(
                            in: destinationFolder,
                            token: String(UUID().uuidString.prefix(8)).lowercased()
                        )
                        let totalLabel = Formats.size(bytes: fileSize)
                        let prefixLabel = totalFiles > 1 ? "[\(index + 1)/\(totalFiles)] \(finalName)" : finalName

                        let handle = try FileHandle(forReadingFrom: readableURL)
                        defer { try? handle.close() }

                        onProgress(L10n.f("files.transfer.progress", prefixLabel, Formats.size(bytes: 0), totalLabel), Double(index) / Double(totalFiles))

                        session.watchdog.arm(idle: 60)
                        let sync = try AdbSync(connection: conn)
                        var uploadedBytes: UInt64 = 0
                        var lastReportedBytes: UInt64 = 0
                        let mtime = UInt32(clamping: max(0, Int64(modified.timeIntervalSince1970)))

                        do {
                            try sync.send(
                                tempPath,
                                mode: AdbFileMode.regular | 0o664,
                                modified: mtime,
                                next: {
                                    guard !sessionHolder.isCancelled else { throw CancellationError() }
                                    guard let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty else {
                                        return nil
                                    }
                                    return chunk
                                },
                                sent: { bytesSent in
                                    session.watchdog.touch()
                                    uploadedBytes = bytesSent
                                    if bytesSent == fileSize || bytesSent &- lastReportedBytes >= 524_288 {
                                        lastReportedBytes = bytesSent
                                        let fileFrac = fileSize > 0 ? min(max(Double(bytesSent) / Double(fileSize), 0), 1) : 1
                                        let totalFrac = (Double(index) + fileFrac) / Double(totalFiles)
                                        onProgress(
                                            L10n.f("files.transfer.progress", prefixLabel, Formats.size(bytes: bytesSent), totalLabel),
                                            totalFrac
                                        )
                                    }
                                }
                            )
                            let stat = try sync.stat(tempPath)
                            guard stat.exists, stat.size == uploadedBytes else {
                                throw GuestFileTransferError.changed(finalName)
                            }
                            sync.quit()
                        } catch {
                            sync.quit()
                            Self.cleanupTempInBackground(tempPath: tempPath, vmID: vmID, clock: clock)
                            throw error
                        }

                        session.watchdog.arm(idle: 30, overall: 60)
                        let moveRes = try conn.runShell(GuestStoragePath.finishCommand(temporary: tempPath, path: finalPath))
                        guard moveRes.exitCode == 0 else {
                            Self.cleanupTempInBackground(tempPath: tempPath, vmID: vmID, clock: clock)
                            let msg = String(decoding: moveRes.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                            throw AdbError.remote(msg.isEmpty ? "mv failed" : msg)
                        }

                        if let free = remainingGuestFree {
                            remainingGuestFree = free >= uploadedBytes ? (free - uploadedBytes) : 0
                        }
                        uploadedCount += 1
                    }
                }
                return uploadedCount
            }
        }
    }

    nonisolated private static func cleanupTempInBackground(tempPath: String, vmID: UUID, clock: AdbRunClock) {
        let cmd = GuestStoragePath.removeCommand(for: tempPath)
        let thread = Thread {
            if let identity = try? AdbKeyStore.forVM(vmID).loadOrCreate() {
                let cleanupSession = AdbSession(signer: identity.signer, clock: clock, connectLimit: 5)
                _ = try? cleanupSession.run { conn in
                    cleanupSession.watchdog.arm(idle: 15, overall: 20)
                    _ = try? conn.runShell(cmd)
                }
            }
        }
        thread.name = "dynarium-files-cleanup"
        thread.qualityOfService = .utility
        thread.start()
    }

    nonisolated private static func performExport(
        entry: GuestStorageEntry,
        stagingDir: URL,
        vmID: UUID,
        clock: AdbRunClock,
        sessionHolder: AdbSessionHolder,
        onProgress: @escaping @Sendable (String, Double?) -> Void
    ) async throws -> URL {
        try await AdbThreadRunner.run(
            name: "dynarium-files-export",
            onCancel: { sessionHolder.cancel() }
        ) {
            let identity = try AdbKeyStore.forVM(vmID).loadOrCreate()
            let session = AdbSession(signer: identity.signer, clock: clock)
            sessionHolder.set(session)

            return try session.run { conn in
                let fm = FileManager.default
                try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
                let outputURL = stagingDir.appendingPathComponent(entry.name, isDirectory: entry.isFolder)

                session.watchdog.arm(idle: 60)
                if entry.isFolder {
                    try checkReadable(entry.path, on: conn)
                }

                let sync = try AdbSync(connection: conn)
                defer { sync.quit() }

                if entry.isFolder {
                    let items = try walkFolder(entry.path, using: sync, holder: sessionHolder, watchdog: session.watchdog)
                    let totalBytes = items.reduce(UInt64(0)) { $0 + $1.size }
                    let hostFree = HostStorage.freeBytes()
                    if hostFree > 0, hostFree < totalBytes || (hostFree - totalBytes) < hostReserveBytes {
                        throw GuestFileTransferError.deviceFull(
                            needed: Formats.size(bytes: totalBytes),
                            free: Formats.size(bytes: hostFree)
                        )
                    }
                    try fm.createDirectory(at: outputURL, withIntermediateDirectories: true)
                    let totalLabel = Formats.size(bytes: totalBytes)
                    var completedBytes: UInt64 = 0
                    var lastReportedBytes: UInt64 = 0

                    onProgress(L10n.f("files.transfer.progress", entry.name, Formats.size(bytes: 0), totalLabel), 0)

                    for item in items {
                        guard !sessionHolder.isCancelled else { throw CancellationError() }
                        let local = outputURL.appendingPathComponent(item.relativePath, isDirectory: item.isFolder)
                        if item.isFolder {
                            try fm.createDirectory(at: local, withIntermediateDirectories: true)
                            continue
                        }
                        try fm.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try receiveSingleFile(
                            remotePath: GuestStoragePath.child(item.relativePath, of: entry.path),
                            expectedSize: item.size,
                            modified: item.modified,
                            to: local,
                            sync: sync,
                            holder: sessionHolder,
                            watchdog: session.watchdog
                        ) { receivedInFile in
                            let current = completedBytes + receivedInFile
                            if current == totalBytes || current &- lastReportedBytes >= 524_288 {
                                lastReportedBytes = current
                                let frac = totalBytes > 0 ? min(max(Double(current) / Double(totalBytes), 0), 1) : 1
                                onProgress(
                                    L10n.f("files.transfer.progress", entry.name, Formats.size(bytes: current), totalLabel),
                                    frac
                                )
                            }
                        }
                        completedBytes += item.size
                    }
                } else {
                    let stat = try sync.stat(entry.path)
                    guard stat.exists else { throw GuestFileTransferError.folderMissing }
                    let fileSize = stat.size
                    let hostFree = HostStorage.freeBytes()
                    if hostFree > 0, hostFree < fileSize || (hostFree - fileSize) < hostReserveBytes {
                        throw GuestFileTransferError.deviceFull(
                            needed: Formats.size(bytes: fileSize),
                            free: Formats.size(bytes: hostFree)
                        )
                    }
                    let totalLabel = Formats.size(bytes: fileSize)
                    var lastReported: UInt64 = 0
                    onProgress(L10n.f("files.transfer.progress", entry.name, Formats.size(bytes: 0), totalLabel), 0)

                    try receiveSingleFile(
                        remotePath: entry.path,
                        expectedSize: fileSize,
                        modified: Date(timeIntervalSince1970: TimeInterval(stat.modified)),
                        to: outputURL,
                        sync: sync,
                        holder: sessionHolder,
                        watchdog: session.watchdog
                    ) { received in
                        if received == fileSize || received &- lastReported >= 524_288 {
                            lastReported = received
                            let frac = fileSize > 0 ? min(max(Double(received) / Double(fileSize), 0), 1) : 1
                            onProgress(
                                L10n.f("files.transfer.progress", entry.name, Formats.size(bytes: received), totalLabel),
                                frac
                            )
                        }
                    }
                }

                return outputURL
            }
        }
    }

    nonisolated private static func walkFolder(
        _ folder: String,
        using sync: AdbSync,
        holder: AdbSessionHolder,
        watchdog: AdbWatchdog
    ) throws -> [GuestWalkItem] {
        var items: [GuestWalkItem] = []
        var pending: [(path: String, relative: String)] = [(folder, "")]
        while let next = pending.popLast() {
            guard !holder.isCancelled else { throw CancellationError() }
            watchdog.touch()
            let raw = try sync.list(next.path)
            var subFolders: [(String, String)] = []
            for item in raw where item.name != "." && item.name != ".." && !GuestStoragePath.isPartial(item.name) {
                let relative = next.relative.isEmpty ? item.name : next.relative + "/" + item.name
                let type = item.mode & AdbFileMode.typeMask
                let modified = Date(timeIntervalSince1970: TimeInterval(item.modified))
                if type == AdbFileMode.directory {
                    items.append(GuestWalkItem(relativePath: relative, isFolder: true, size: 0, modified: modified))
                    subFolders.append((GuestStoragePath.child(item.name, of: next.path), relative))
                } else if type == AdbFileMode.regular {
                    items.append(GuestWalkItem(relativePath: relative, isFolder: false, size: item.size, modified: modified))
                }
            }
            pending.append(contentsOf: subFolders.reversed())
        }
        return items
    }

    nonisolated private static func receiveSingleFile(
        remotePath: String,
        expectedSize: UInt64,
        modified: Date,
        to localURL: URL,
        sync: AdbSync,
        holder: AdbSessionHolder,
        watchdog: AdbWatchdog,
        progress: (UInt64) -> Void
    ) throws {
        let fm = FileManager.default
        guard fm.createFile(atPath: localURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: localURL)
        defer { try? handle.close() }

        var received: UInt64 = 0
        try sync.receive(remotePath) { chunk in
            guard !holder.isCancelled else { throw CancellationError() }
            try handle.write(contentsOf: chunk)
            received += UInt64(chunk.count)
            watchdog.touch()
            progress(received)
        }
        if expectedSize > 0, received != expectedSize {
            throw GuestFileTransferError.changed(GuestStoragePath.name(of: remotePath))
        }
        try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: localURL.path)
    }

    nonisolated private static func performGuestApkInstall(
        entry: GuestStorageEntry,
        vmID: UUID,
        clock: AdbRunClock,
        sessionHolder: AdbSessionHolder
    ) async throws -> String {
        try await AdbThreadRunner.run(
            name: "dynarium-guest-apk-install",
            onCancel: { sessionHolder.cancel() }
        ) {
            let identity = try AdbKeyStore.forVM(vmID).loadOrCreate()
            let session = AdbSession(signer: identity.signer, clock: clock)
            sessionHolder.set(session)

            return try session.run { conn in
                session.watchdog.arm(idle: 30, overall: 60)
                let sync = try AdbSync(connection: conn)
                let stat: AdbFileStat
                do {
                    stat = try sync.stat(entry.path)
                    sync.quit()
                } catch {
                    sync.quit()
                    throw error
                }
                guard stat.exists else { throw GuestFileTransferError.folderMissing }
                let size = stat.size > 0 ? stat.size : entry.size
                guard size > 0 else {
                    throw NSError(domain: "Dynarium.GuestFileManager", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: L10n.t("apk.empty_file")
                    ])
                }

                session.watchdog.arm(idle: nil, overall: 15 * 60)
                let result = try conn.runShell(
                    "cmd package install -r -t -S \(size) < \(AdbShellQuote.quote(entry.path))",
                    limit: 64 * 1024
                )
                let combined = result.text + "\n" + String(decoding: result.stderr, as: UTF8.self)
                if let err = PackageErrorMessages.failureMessage(in: combined) {
                    throw AdbError.remote(err)
                }
                return L10n.f("apk.installed_single", entry.name)
            }
        }
    }
}
