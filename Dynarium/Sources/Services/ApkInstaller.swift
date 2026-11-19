// SPDX-License-Identifier: GPL-2.0-or-later

import Combine
import Foundation

nonisolated enum ApkInstallState: Equatable, Sendable {
    case idle
    case preparing(String)
    case transferring(detail: String, progress: Double)
    case installing(String)
    case completed(String)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .preparing, .transferring, .installing: true
        default: false
        }
    }
}

nonisolated enum PackageErrorMessages {
    private static let table: [(codes: [String], message: String)] = [
        (["PARSE_FAILED_NOT_APK", "FAILED_INVALID_APK", "PARSE_FAILED_BAD_MANIFEST", "PARSE_FAILED_MANIFEST_MALFORMED"],
         "Tệp không phải là gói ứng dụng Android hợp lệ."),
        (["PARSE_FAILED_NO_CERTIFICATES", "PARSE_FAILED_INCONSISTENT_CERTIFICATES", "PARSE_FAILED_CERTIFICATE_ENCODING"],
         "Ứng dụng không có chữ ký hợp lệ."),
        (["FAILED_UPDATE_INCOMPATIBLE", "FAILED_SHARED_USER_INCOMPATIBLE"],
         "Bản cài hiện có trên máy dùng chữ ký khác. Hãy gỡ cài đặt bản cũ trước."),
        (["FAILED_VERSION_DOWNGRADE"],
         "Máy ảo đã cài sẵn phiên bản mới hơn của ứng dụng này."),
        (["FAILED_OLDER_SDK"],
         "Ứng dụng yêu cầu phiên bản Android mới hơn bản đang chạy."),
        (["FAILED_NO_MATCHING_ABIS"],
         "Ứng dụng không có mã thực thi tương thích CPU ARM của máy ảo."),
        (["FAILED_INSUFFICIENT_STORAGE"],
         "Ổ dữ liệu máy ảo (data.img) không còn đủ dung lượng trống."),
        (["FAILED_MISSING_SPLIT"],
         "Thiếu thành phần split APK trong gói cài đặt."),
        (["FAILED_DUPLICATE_PACKAGE", "FAILED_CONFLICTING_PROVIDER"],
         "Xung đột tên gói hoặc nhà cung cấp nội dung với app đã cài."),
    ]

    static func failureMessage(in output: String) -> String? {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains(where: { $0.hasPrefix("Success") }) { return nil }
        guard let failureLine = lines.last(where: { $0.hasPrefix("Failure") }),
              let open = failureLine.firstIndex(of: "[") else {
            return "Android không thể hoàn tất cài đặt (\(output.trimmingCharacters(in: .whitespacesAndNewlines)))."
        }
        let inside = failureLine[failureLine.index(after: open)...]
        let rawCode = inside.prefix { $0 != ":" && $0 != "]" }.trimmingCharacters(in: .whitespaces)
        let code = rawCode.hasPrefix("INSTALL_") ? String(rawCode.dropFirst("INSTALL_".count)) : rawCode
        return table.first { $0.codes.contains(code) }?.message ?? "Cài đặt thất bại (\(code))."
    }
}

@MainActor
final class ApkInstaller: ObservableObject {
    @Published private(set) var state: ApkInstallState = .idle

    private var activeTask: Task<Void, Never>?
    private var activeSession: AdbSession?

    func install(fileURL: URL, vmID: UUID, clock: AdbRunClock) {
        guard !state.isBusy else { return }
        state = .preparing(fileURL.lastPathComponent)

        activeTask = Task {
            let scoped = fileURL.startAccessingSecurityScopedResource()
            defer {
                if scoped { fileURL.stopAccessingSecurityScopedResource() }
            }
            do {
                let message = try await Self.runInstall(
                    fileURL: fileURL,
                    vmID: vmID,
                    clock: clock,
                    onSession: { [weak self] session in
                        Task { @MainActor [weak self] in self?.activeSession = session }
                    },
                    onState: { [weak self] next in
                        Task { @MainActor [weak self] in self?.state = next }
                    }
                )
                state = .completed(message)
            } catch is CancellationError {
                state = .idle
            } catch let adbErr as AdbError where adbErr == .cancelled {
                state = .idle
            } catch let adbErr as AdbError {
                state = .failed(adbErr.localizedMessage)
            } catch {
                state = .failed(error.localizedDescription)
            }
            activeSession = nil
            activeTask = nil
        }
    }

    func cancel() {
        activeSession?.cancel()
        activeTask?.cancel()
    }

    func dismissStatus() {
        if !state.isBusy {
            state = .idle
        }
    }

    nonisolated private static func runInstall(
        fileURL: URL,
        vmID: UUID,
        clock: AdbRunClock,
        onSession: @escaping @Sendable (AdbSession) -> Void,
        onState: @escaping @Sendable (ApkInstallState) -> Void
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let identity = try AdbKeyStore.forVM(vmID).loadOrCreate()
            let session = AdbSession(signer: identity.signer, clock: clock)
            onSession(session)

            let ext = fileURL.pathExtension.lowercased()
            if ext == "apk" {
                return try installSingleApk(url: fileURL, session: session, onState: onState)
            } else {
                return try installSplitBundle(url: fileURL, session: session, onState: onState)
            }
        }.value
    }

    nonisolated private static func installSingleApk(
        url: URL,
        session: AdbSession,
        onState: @escaping @Sendable (ApkInstallState) -> Void
    ) throws -> String {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else {
            throw NSError(domain: "Dynarium.ApkInstaller", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Tệp APK rỗng hoặc không hợp lệ."
            ])
        }
        try session.run { conn in
            try streamSingleApkToAbb(handleURL: url, size: size, connection: conn, watchdog: session.watchdog) { prog in
                onState(.transferring(detail: url.lastPathComponent, progress: prog * 0.85))
            }
        }
        return "Đã cài đặt xong \(url.lastPathComponent)."
    }

    nonisolated private static func installSplitBundle(
        url: URL,
        session: AdbSession,
        onState: @escaping @Sendable (ApkInstallState) -> Void
    ) throws -> String {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("dynarium-splits-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        onState(.preparing("Đang tách bộ cài split từ \(url.lastPathComponent)\u{2026}"))
        let splits = try ZipArchiveReader.extractSplitApks(from: url, to: scratch)
        guard !splits.isEmpty else {
            throw NSError(domain: "Dynarium.ApkInstaller", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Không tìm thấy tệp .apk nào bên trong gói \(url.lastPathComponent)."
            ])
        }

        let totalSize = splits.reduce(UInt64(0)) { $0 + $1.uncompressedSize }
        try session.run { conn in
            session.watchdog.arm(idle: 30, overall: 120)
            let createStream = try conn.open("abb_exec:package\0install-create\0-r\0-t\0-S\0\(totalSize)")
            let createOut = String(decoding: try createStream.readToEnd(limit: 16 * 1024), as: UTF8.self)
            guard let sessionID = parseSessionID(from: createOut) else {
                throw AdbError.remote("Không thể tạo phiên cài đặt split: \(createOut)")
            }

            var uploadedBytes: UInt64 = 0
            do {
                for (idx, split) in splits.enumerated() {
                    try Task.checkCancellation()
                    let splitSize = Int(split.uncompressedSize)
                    let service = "abb_exec:package\0install-write\0-S\0\(splitSize)\0\(sessionID)\0split_\(idx)_\(split.fileName)"
                    session.watchdog.arm(idle: 60)
                    let writeStream = try conn.open(service)
                    let fh = try FileHandle(forReadingFrom: split.tempFileURL)
                    defer { try? fh.close() }

                    var sent = 0
                    while sent < splitSize {
                        let chunk = try fh.read(upToCount: min(256 * 1024, splitSize - sent)) ?? Data()
                        if chunk.isEmpty { throw AdbError.io(EIO) }
                        try writeStream.write(chunk)
                        sent += chunk.count
                        uploadedBytes += UInt64(chunk.count)
                        session.watchdog.touch()
                        let frac = totalSize > 0 ? Double(uploadedBytes) / Double(totalSize) * 0.85 : 0.5
                        onState(.transferring(detail: "\(split.fileName) (\(idx + 1)/\(splits.count))", progress: frac))
                    }
                    let writeRes = String(decoding: try writeStream.readToEnd(limit: 16 * 1024), as: UTF8.self)
                    if let err = PackageErrorMessages.failureMessage(inOutput: writeRes) {
                        throw AdbError.remote(err)
                    }
                }

                onState(.installing("Android đang hợp nhất & biên dịch ứng dụng\u{2026}"))
                session.watchdog.arm(idle: nil, overall: 15 * 60)
                let commitStream = try conn.open("abb_exec:package\0install-commit\0\(sessionID)")
                let commitOut = String(decoding: try commitStream.readToEnd(limit: 32 * 1024), as: UTF8.self)
                if let err = PackageErrorMessages.failureMessage(inOutput: commitOut) {
                    throw AdbError.remote(err)
                }
            } catch {
                let abandon = try? conn.open("abb_exec:package\0install-abandon\0\(sessionID)")
                abandon?.close()
                throw error
            }
        }
        return "Đã cài đặt xong gói \(url.lastPathComponent) (\(splits.count) thành phần)."
    }

    nonisolated private static func streamSingleApkToAbb(
        handleURL: URL,
        size: Int,
        connection: AdbConnection,
        watchdog: AdbWatchdog,
        progress: (Double) -> Void
    ) throws {
        let fh = try FileHandle(forReadingFrom: handleURL)
        defer { try? fh.close() }
        watchdog.arm(idle: 60)
        let stream = try connection.open("abb_exec:package\0install\0-r\0-t\0-S\0\(size)")
        var sent = 0
        do {
            while sent < size {
                let chunk = try fh.read(upToCount: min(256 * 1024, size - sent)) ?? Data()
                if chunk.isEmpty { throw AdbError.io(EIO) }
                try stream.write(chunk)
                sent += chunk.count
                watchdog.touch()
                progress(Double(sent) / Double(size))
            }
        } catch AdbError.streamClosed {
            // Package manager aborted early; read remaining diagnostic message below.
        }
        watchdog.arm(idle: nil, overall: 15 * 60)
        let output = String(decoding: try stream.readToEnd(limit: 64 * 1024), as: UTF8.self)
        if let err = PackageErrorMessages.failureMessage(inOutput: output) {
            throw AdbError.remote(err)
        }
    }

    nonisolated private static func parseSessionID(from output: String) -> String? {
        guard let open = output.firstIndex(of: "["),
              let close = output[output.index(after: open)...].firstIndex(of: "]") else {
            return nil
        }
        let id = output[output.index(after: open)..<close].trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }
}
