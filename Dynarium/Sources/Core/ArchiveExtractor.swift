// SPDX-License-Identifier: GPL-2.0-or-later

import CryptoKit
import Darwin
import Foundation
import LibZstd

nonisolated enum ArchiveCompressionFormat: Sendable {
    case tar
    case gzipTar
    case zstdTar
}

nonisolated struct ExtractionProgress: Sendable {
    let compressedConsumedBytes: UInt64
    let compressedTotalBytes: UInt64
    let extractedFileCount: Int
    let writtenBytes: UInt64
    let sparseSkippedBytes: UInt64
    let currentEntry: String

    var fraction: Double {
        guard compressedTotalBytes > 0 else { return 0 }
        return min(1.0, Double(compressedConsumedBytes) / Double(compressedTotalBytes))
    }
}

nonisolated enum ArchiveExtractorError: LocalizedError, Sendable {
    case unsupportedFormat
    case openFailed(String)
    case corruptedArchive(String)
    case unsafePath(String)
    case ioError(Int32, String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "Định dạng tệp ROM không được hỗ trợ (hỗ trợ .tar.gz, .tar.zst, .tar)."
        case .openFailed(let detail):
            return "Không thể mở tệp: \(detail)"
        case .corruptedArchive(let detail):
            return "Tệp lưu trữ bị hỏng hoặc không đầy đủ: \(detail)"
        case .unsafePath(let path):
            return "Đường dẫn trong gói không an toàn: \(path)"
        case .ioError(let code, let context):
            return "Lỗi ghi tệp (\(context)): \(String(cString: strerror(code)))"
        }
    }
}

nonisolated enum ArchiveExtractor {
    private static let readBufferSize = 512 * 1024
    private static let decompBufferSize = 1024 * 1024
    private static let sparseChunkSize = 64 * 1024

    static func sha256Hex(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func detectFormat(of fileURL: URL) throws -> ArchiveCompressionFormat {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 512) ?? Data()
        if header.count >= 4,
           header[0] == 0x28, header[1] == 0xB5, header[2] == 0x2F, header[3] == 0xFD {
            return .zstdTar
        }
        if header.count >= 2, header[0] == 0x1F, header[1] == 0x8B {
            return .gzipTar
        }
        if header.count >= 263 {
            let magic = String(decoding: header[257..<262], as: UTF8.self)
            if magic == "ustar" {
                return .tar
            }
        }
        let lower = fileURL.lastPathComponent.lowercased()
        if lower.hasSuffix(".zst") || lower.hasSuffix(".tzst") { return .zstdTar }
        if lower.hasSuffix(".gz") || lower.hasSuffix(".tgz") { return .gzipTar }
        if lower.hasSuffix(".tar") { return .tar }
        throw ArchiveExtractorError.unsupportedFormat
    }

    static func extractTarArchive(
        from sourceURL: URL,
        to destinationDirectory: URL,
        progress: (@Sendable (ExtractionProgress) -> Void)? = nil
    ) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let totalBytes = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let format = try detectFormat(of: sourceURL)

        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let sink = TarStreamSink(
            destinationRoot: destinationDirectory,
            compressedTotalBytes: totalBytes,
            progress: progress
        )

        let fd = Darwin.open(sourceURL.path, O_RDONLY)
        guard fd >= 0 else {
            throw ArchiveExtractorError.ioError(errno, sourceURL.lastPathComponent)
        }
        defer { Darwin.close(fd) }

        switch format {
        case .tar:
            try streamRawTar(fd: fd, sink: sink)
        case .gzipTar:
            try streamGzipTar(fd: fd, sink: sink)
        case .zstdTar:
            try streamZstdTar(fd: fd, sink: sink)
        }

        try sink.finish()
    }

    private static func streamRawTar(fd: Int32, sink: TarStreamSink) throws {
        var buf = [UInt8](repeating: 0, count: readBufferSize)
        var consumed: UInt64 = 0
        while true {
            try Task.checkCancellation()
            let count = buf.withUnsafeMutableBytes { ptr in
                Darwin.read(fd, ptr.baseAddress!, readBufferSize)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw ArchiveExtractorError.ioError(errno, "read tar")
            }
            if count == 0 { break }
            consumed += UInt64(count)
            try buf.withUnsafeBytes { ptr in
                try sink.consume(
                    UnsafeRawBufferPointer(start: ptr.baseAddress, count: count),
                    compressedConsumed: consumed
                )
            }
        }
    }

    private static func streamGzipTar(fd: Int32, sink: TarStreamSink) throws {
        var strm = z_stream()
        let initRc = dynarium_zlib_init_gzip(&strm)
        guard initRc == Z_OK else {
            throw ArchiveExtractorError.corruptedArchive("zlib init failed (\(initRc))")
        }
        defer { _ = dynarium_zlib_inflate_end(&strm) }

        var inBuf = [UInt8](repeating: 0, count: readBufferSize)
        var outBuf = [UInt8](repeating: 0, count: decompBufferSize)
        var consumed: UInt64 = 0
        var streamEnded = false

        while !streamEnded {
            try Task.checkCancellation()
            let count = inBuf.withUnsafeMutableBytes { ptr in
                Darwin.read(fd, ptr.baseAddress!, readBufferSize)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw ArchiveExtractorError.ioError(errno, "read gzip")
            }
            if count == 0 {
                if !streamEnded {
                    // Attempt one trailing flush if EOF reached right on Z_STREAM_END boundary.
                    break
                }
            }
            try inBuf.withUnsafeMutableBytes { inPtr in
                strm.next_in = inPtr.baseAddress?.assumingMemoryBound(to: Bytef.self)
                strm.avail_in = uInt(count)

                repeat {
                    try Task.checkCancellation()
                    let produced = try outBuf.withUnsafeMutableBytes { outPtr -> Int in
                        strm.next_out = outPtr.baseAddress?.assumingMemoryBound(to: Bytef.self)
                        strm.avail_out = uInt(decompBufferSize)
                        let rc = dynarium_zlib_inflate(&strm, Z_NO_FLUSH)
                        if rc == Z_STREAM_END {
                            streamEnded = true
                        } else if rc != Z_OK && rc != Z_BUF_ERROR {
                            throw ArchiveExtractorError.corruptedArchive("gzip inflate error \(rc)")
                        }
                        return decompBufferSize - Int(strm.avail_out)
                    }
                    let deltaIn = UInt64(count) - UInt64(strm.avail_in)
                    let currentConsumed = consumed + deltaIn
                    if produced > 0 {
                        try outBuf.withUnsafeBytes { ptr in
                            try sink.consume(
                                UnsafeRawBufferPointer(start: ptr.baseAddress, count: produced),
                                compressedConsumed: currentConsumed
                            )
                        }
                    }
                } while strm.avail_out == 0 && !streamEnded
            }
            consumed += UInt64(count)
        }
    }

    private static func streamZstdTar(fd: Int32, sink: TarStreamSink) throws {
        guard let dstream = ZSTD_createDStream() else {
            throw ArchiveExtractorError.corruptedArchive("ZSTD_createDStream failed")
        }
        defer { _ = ZSTD_freeDStream(dstream) }
        let initRc = ZSTD_initDStream(dstream)
        if ZSTD_isError(initRc) != 0 {
            throw ArchiveExtractorError.corruptedArchive(String(cString: ZSTD_getErrorName(initRc)))
        }

        var inBuf = [UInt8](repeating: 0, count: readBufferSize)
        var outBuf = [UInt8](repeating: 0, count: decompBufferSize)
        var consumed: UInt64 = 0
        var lastReturn: Int = 1

        while true {
            try Task.checkCancellation()
            let count = inBuf.withUnsafeMutableBytes { ptr in
                Darwin.read(fd, ptr.baseAddress!, readBufferSize)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw ArchiveExtractorError.ioError(errno, "read zstd")
            }
            if count == 0 {
                break
            }
            let baseConsumed = consumed
            try inBuf.withUnsafeBytes { inBytes in
                var zIn = ZSTD_inBuffer(src: inBytes.baseAddress, size: count, pos: 0)
                while zIn.pos < zIn.size {
                    try Task.checkCancellation()
                    let produced = try outBuf.withUnsafeMutableBytes { outBytes -> Int in
                        var zOut = ZSTD_outBuffer(dst: outBytes.baseAddress, size: decompBufferSize, pos: 0)
                        let rc = ZSTD_decompressStream(dstream, &zOut, &zIn)
                        if ZSTD_isError(rc) != 0 {
                            throw ArchiveExtractorError.corruptedArchive(String(cString: ZSTD_getErrorName(rc)))
                        }
                        lastReturn = Int(rc)
                        return zOut.pos
                    }
                    if produced > 0 {
                        try outBuf.withUnsafeBytes { outPtr in
                            try sink.consume(
                                UnsafeRawBufferPointer(start: outPtr.baseAddress, count: produced),
                                compressedConsumed: baseConsumed + UInt64(zIn.pos)
                            )
                        }
                    }
                }
            }
            consumed += UInt64(count)
        }
        if lastReturn != 0 {
            throw ArchiveExtractorError.corruptedArchive("Luồng Zstandard kết thúc trước khi hoàn tất")
        }
    }
}

// MARK: - Streaming TAR Parser with Sparse Hole Support

private nonisolated final class TarStreamSink {
    private enum ParseState {
        case header
        case payload(remaining: UInt64, padRemaining: Int)
        case metadataPayload(kind: MetadataKind, remaining: UInt64, padRemaining: Int, buffer: Data)
    }

    private enum MetadataKind {
        case paxGlobal
        case paxPerFile
        case gnuLongName
        case gnuLongLink
    }

    private struct ActiveFile {
        let fd: Int32
        let path: String
        let isSparseCandidate: Bool
        var writtenBytes: UInt64 = 0
        var pendingHoleBytes: Int64 = 0
        var zeroBuffer = Data()
    }

    private let destinationRoot: URL
    private let resolvedRootPath: String
    private let compressedTotalBytes: UInt64
    private let progress: (@Sendable (ExtractionProgress) -> Void)?

    private var state: ParseState = .header
    private var headerScratch = Data()
    private var activeFile: ActiveFile?
    private var nextPaxPath: String?
    private var nextPaxLinkPath: String?
    private var nextPaxSize: UInt64?
    private var nextGnuName: String?
    private var nextGnuLink: String?
    private var extractedCount = 0
    private var totalWritten: UInt64 = 0
    private var totalSparseSkipped: UInt64 = 0
    private var currentEntryName = ""
    private var lastReportedConsumed: UInt64 = 0
    private var seenEOFZeroBlocks = 0
    private var pendingDeferredSymlinks: [(dest: URL, target: String)] = []

    init(
        destinationRoot: URL,
        compressedTotalBytes: UInt64,
        progress: (@Sendable (ExtractionProgress) -> Void)?
    ) {
        self.destinationRoot = destinationRoot
        self.resolvedRootPath = destinationRoot.resolvingSymlinksInPath().path
        self.compressedTotalBytes = compressedTotalBytes
        self.progress = progress
        self.headerScratch.reserveCapacity(512)
    }

    deinit {
        if let file = activeFile {
            Darwin.close(file.fd)
        }
    }

    func consume(_ chunk: UnsafeRawBufferPointer, compressedConsumed: UInt64) throws {
        var offset = 0
        let total = chunk.count
        guard let base = chunk.baseAddress else { return }

        while offset < total {
            switch state {
            case .header:
                let needed = 512 - headerScratch.count
                let take = min(needed, total - offset)
                headerScratch.append(base.advanced(by: offset).assumingMemoryBound(to: UInt8.self), count: take)
                offset += take
                if headerScratch.count == 512 {
                    let block = headerScratch
                    headerScratch.removeAll(keepingCapacity: true)
                    try processHeaderBlock(block, compressedConsumed: compressedConsumed)
                }

            case let .payload(remaining, padRemaining):
                if remaining > 0 {
                    let take = min(Int(min(remaining, UInt64(Int.max))), total - offset)
                    let span = UnsafeRawBufferPointer(start: base.advanced(by: offset), count: take)
                    try writePayloadChunk(span)
                    offset += take
                    let nextRem = remaining - UInt64(take)
                    state = .payload(remaining: nextRem, padRemaining: padRemaining)
                    if nextRem == 0 {
                        try finalizeActiveFile()
                        if padRemaining == 0 {
                            state = .header
                        }
                    }
                } else if padRemaining > 0 {
                    let take = min(padRemaining, total - offset)
                    offset += take
                    let nextPad = padRemaining - take
                    state = nextPad == 0 ? .header : .payload(remaining: 0, padRemaining: nextPad)
                } else {
                    try finalizeActiveFile()
                    state = .header
                }

            case .metadataPayload(let kind, let remaining, let padRemaining, var metaBuf):
                if remaining > 0 {
                    let take = min(Int(min(remaining, UInt64(Int.max))), total - offset)
                    metaBuf.append(base.advanced(by: offset).assumingMemoryBound(to: UInt8.self), count: take)
                    offset += take
                    let nextRem = remaining - UInt64(take)
                    if nextRem == 0 {
                        applyMetadata(kind: kind, data: metaBuf)
                        if padRemaining == 0 {
                            state = .header
                        } else {
                            state = .metadataPayload(kind: kind, remaining: 0, padRemaining: padRemaining, buffer: Data())
                        }
                    } else {
                        state = .metadataPayload(kind: kind, remaining: nextRem, padRemaining: padRemaining, buffer: metaBuf)
                    }
                } else if padRemaining > 0 {
                    let take = min(padRemaining, total - offset)
                    offset += take
                    let nextPad = padRemaining - take
                    state = nextPad == 0
                        ? .header
                        : .metadataPayload(kind: kind, remaining: 0, padRemaining: nextPad, buffer: Data())
                } else {
                    state = .header
                }
            }
        }

        if compressedConsumed &- lastReportedConsumed >= 2_097_152 || compressedConsumed == compressedTotalBytes {
            lastReportedConsumed = compressedConsumed
            emitProgress(compressedConsumed: compressedConsumed)
        }
    }

    func finish() throws {
        if let file = activeFile {
            try finalizeActiveFile()
            _ = file
        }
        // Apply deferred symlinks cleanly once real directories & files are extracted.
        let fm = FileManager.default
        for item in pendingDeferredSymlinks {
            let parent = item.dest.deletingLastPathComponent()
            try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
            try? fm.removeItem(at: item.dest)
            try fm.createSymbolicLink(atPath: item.dest.path, withDestinationPath: item.target)
        }
        emitProgress(compressedConsumed: compressedTotalBytes)
    }

    private func emitProgress(compressedConsumed: UInt64) {
        progress?(
            ExtractionProgress(
                compressedConsumedBytes: compressedConsumed,
                compressedTotalBytes: compressedTotalBytes,
                extractedFileCount: extractedCount,
                writtenBytes: totalWritten,
                sparseSkippedBytes: totalSparseSkipped,
                currentEntry: currentEntryName
            )
        )
    }

    private func processHeaderBlock(_ block: Data, compressedConsumed: UInt64) throws {
        let allZero = block.withUnsafeBytes { ptr in
            dynarium_is_all_zero(ptr.baseAddress, ptr.count)
        }
        if allZero {
            seenEOFZeroBlocks += 1
            return
        }
        seenEOFZeroBlocks = 0

        let storedChecksum = parseOctal(block[148..<156]) ?? 0
        var computedSum = 0
        for (idx, b) in block.enumerated() {
            if idx >= 148 && idx < 156 {
                computedSum += 32 // spaces during checksum calculation
            } else {
                computedSum += Int(b)
            }
        }
        guard storedChecksum == UInt64(computedSum) else {
            throw ArchiveExtractorError.corruptedArchive("TAR header checksum không khớp")
        }

        let nameField = extractCString(block[0..<100])
        let prefixField = extractCString(block[345..<500])
        let basePath = prefixField.isEmpty ? nameField : "\(prefixField)/\(nameField)"
        let typeByte = block[156]
        let fileSize = nextPaxSize ?? parseNumericField(block[124..<136])
        let linkField = extractCString(block[157..<257])

        let pad = Int((512 - (fileSize % 512)) % 512)

        switch Character(UnicodeScalar(typeByte)) {
        case "x":
            state = .metadataPayload(kind: .paxPerFile, remaining: fileSize, padRemaining: pad, buffer: Data())
            return
        case "g":
            state = .metadataPayload(kind: .paxGlobal, remaining: fileSize, padRemaining: pad, buffer: Data())
            return
        case "L":
            state = .metadataPayload(kind: .gnuLongName, remaining: fileSize, padRemaining: pad, buffer: Data())
            return
        case "K":
            state = .metadataPayload(kind: .gnuLongLink, remaining: fileSize, padRemaining: pad, buffer: Data())
            return
        default:
            break
        }

        let resolvedPath = nextPaxPath ?? nextGnuName ?? basePath
        let resolvedLink = nextPaxLinkPath ?? nextGnuLink ?? linkField
        nextPaxPath = nil
        nextPaxLinkPath = nil
        nextPaxSize = nil
        nextGnuName = nil
        nextGnuLink = nil

        if resolvedPath.isEmpty || resolvedPath == "." || resolvedPath == "./" {
            if fileSize > 0 {
                state = .payload(remaining: fileSize, padRemaining: pad)
            }
            return
        }

        let destURL = try safeDestinationURL(for: resolvedPath)
        currentEntryName = destURL.lastPathComponent
        let fm = FileManager.default

        switch typeByte {
        case UInt8(ascii: "5"):
            try fm.createDirectory(at: destURL, withIntermediateDirectories: true)
            if fileSize > 0 {
                state = .payload(remaining: fileSize, padRemaining: pad)
            }
        case UInt8(ascii: "2"):
            // Validate symlink does not escape destination root.
            guard !resolvedLink.hasPrefix("/") else {
                throw ArchiveExtractorError.unsafePath("\(resolvedPath) -> \(resolvedLink)")
            }
            let targetResolved = destURL.deletingLastPathComponent().appendingPathComponent(resolvedLink).standardizedFileURL.path
            guard targetResolved == resolvedRootPath || targetResolved.hasPrefix(resolvedRootPath + "/") else {
                throw ArchiveExtractorError.unsafePath("\(resolvedPath) -> \(resolvedLink)")
            }
            pendingDeferredSymlinks.append((dest: destURL, target: resolvedLink))
            if fileSize > 0 {
                state = .payload(remaining: fileSize, padRemaining: pad)
            }
        case UInt8(ascii: "0"), 0:
            try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let fd = Darwin.open(destURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            guard fd >= 0 else {
                throw ArchiveExtractorError.ioError(errno, destURL.lastPathComponent)
            }
            let isSparse = destURL.pathExtension.lowercased() == "img"
            extractedCount += 1
            activeFile = ActiveFile(fd: fd, path: destURL.path, isSparseCandidate: isSparse)
            if fileSize == 0 {
                try finalizeActiveFile()
                state = .header
            } else {
                state = .payload(remaining: fileSize, padRemaining: pad)
            }
            if compressedConsumed > 0 {
                emitProgress(compressedConsumed: compressedConsumed)
            }
        default:
            if fileSize > 0 {
                state = .payload(remaining: fileSize, padRemaining: pad)
            }
        }
    }

    private func writePayloadChunk(_ span: UnsafeRawBufferPointer) throws {
        guard var file = activeFile else { return }
        defer { activeFile = file }

        if !file.isSparseCandidate {
            try writeAll(fd: file.fd, buffer: span, path: file.path)
            file.writtenBytes += UInt64(span.count)
            totalWritten += UInt64(span.count)
            return
        }

        file.zeroBuffer.append(span.baseAddress!.assumingMemoryBound(to: UInt8.self), count: span.count)
        while file.zeroBuffer.count >= 65_536 {
            let blockCount = 65_536
            let slice = file.zeroBuffer.prefix(blockCount)
            let allZero = slice.withUnsafeBytes { ptr in
                dynarium_is_all_zero(ptr.baseAddress, ptr.count)
            }
            if allZero {
                file.pendingHoleBytes += Int64(blockCount)
                totalSparseSkipped += UInt64(blockCount)
            } else {
                if file.pendingHoleBytes > 0 {
                    guard Darwin.lseek(file.fd, off_t(file.pendingHoleBytes), SEEK_CUR) >= 0 else {
                        throw ArchiveExtractorError.ioError(errno, file.path)
                    }
                    file.pendingHoleBytes = 0
                }
                try slice.withUnsafeBytes { ptr in
                    try writeAll(fd: file.fd, buffer: ptr, path: file.path)
                }
            }
            file.writtenBytes += UInt64(blockCount)
            totalWritten += UInt64(blockCount)
            file.zeroBuffer.removeFirst(blockCount)
        }
    }

    private func finalizeActiveFile() throws {
        guard var file = activeFile else { return }
        activeFile = nil
        defer { Darwin.close(file.fd) }

        if file.isSparseCandidate && !file.zeroBuffer.isEmpty {
            let tailAllZero = file.zeroBuffer.withUnsafeBytes { ptr in
                dynarium_is_all_zero(ptr.baseAddress, ptr.count)
            }
            if tailAllZero {
                file.pendingHoleBytes += Int64(file.zeroBuffer.count)
                totalSparseSkipped += UInt64(file.zeroBuffer.count)
            } else {
                if file.pendingHoleBytes > 0 {
                    guard Darwin.lseek(file.fd, off_t(file.pendingHoleBytes), SEEK_CUR) >= 0 else {
                        throw ArchiveExtractorError.ioError(errno, file.path)
                    }
                    file.pendingHoleBytes = 0
                }
                try file.zeroBuffer.withUnsafeBytes { ptr in
                    try writeAll(fd: file.fd, buffer: ptr, path: file.path)
                }
            }
            file.writtenBytes += UInt64(file.zeroBuffer.count)
            totalWritten += UInt64(file.zeroBuffer.count)
            file.zeroBuffer.removeAll()
        }

        if file.isSparseCandidate && file.pendingHoleBytes > 0 {
            guard Darwin.ftruncate(file.fd, off_t(file.writtenBytes)) == 0 else {
                throw ArchiveExtractorError.ioError(errno, file.path)
            }
        }
    }

    private func writeAll(fd: Int32, buffer: UnsafeRawBufferPointer, path: String) throws {
        guard let base = buffer.baseAddress else { return }
        var sent = 0
        while sent < buffer.count {
            let n = Darwin.write(fd, base.advanced(by: sent), buffer.count - sent)
            if n < 0 {
                if errno == EINTR { continue }
                throw ArchiveExtractorError.ioError(errno, path)
            }
            sent += n
        }
    }

    private func applyMetadata(kind: MetadataKind, data: Data) {
        switch kind {
        case .gnuLongName:
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0\n"))
            if !text.isEmpty { nextGnuName = text }
        case .gnuLongLink:
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0\n"))
            if !text.isEmpty { nextGnuLink = text }
        case .paxPerFile, .paxGlobal:
            let text = String(decoding: data, as: UTF8.self)
            for line in text.split(separator: "\n") {
                guard let spaceIdx = line.firstIndex(of: " "),
                      let eqIdx = line[spaceIdx...].firstIndex(of: "=") else { continue }
                let key = String(line[line.index(after: spaceIdx)..<eqIdx])
                let value = String(line[line.index(after: eqIdx)...])
                switch key {
                case "path": nextPaxPath = value
                case "linkpath": nextPaxLinkPath = value
                case "size": nextPaxSize = UInt64(value)
                default: break
                }
            }
        }
    }

    private func safeDestinationURL(for tarPath: String) throws -> URL {
        var cleaned = tarPath
        while cleaned.hasPrefix("./") { cleaned.removeFirst(2) }
        guard !cleaned.hasPrefix("/") else {
            throw ArchiveExtractorError.unsafePath(tarPath)
        }
        let components = cleaned.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains("..") && !components.contains(".") else {
            throw ArchiveExtractorError.unsafePath(tarPath)
        }
        var url = destinationRoot
        for part in components {
            url.appendPathComponent(String(part))
        }
        let standardized = url.standardizedFileURL.path
        let rootStd = destinationRoot.standardizedFileURL.path
        guard standardized == rootStd || standardized.hasPrefix(rootStd + "/") else {
            throw ArchiveExtractorError.unsafePath(tarPath)
        }
        return url
    }

    private func extractCString(_ slice: Data.SubSequence) -> String {
        let bytes = slice.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func parseOctal(_ slice: Data.SubSequence) -> UInt64? {
        let trimmed = String(decoding: slice, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
        if trimmed.isEmpty { return 0 }
        return UInt64(trimmed, radix: 8)
    }

    private func parseNumericField(_ slice: Data.SubSequence) -> UInt64 {
        if let first = slice.first, (first & 0x80) != 0 {
            var value: UInt64 = 0
            for (idx, b) in slice.enumerated() {
                let masked = idx == 0 ? (b & 0x7F) : b
                value = (value << 8) | UInt64(masked)
            }
            return value
        }
        return parseOctal(slice) ?? 0
    }
}

// MARK: - Streaming ZIP Reader for Split APK Bundles (.apks / .apkm / .zip)

nonisolated struct ZipSplitApkEntry: Sendable {
    let fileName: String
    let tempFileURL: URL
    let uncompressedSize: UInt64
}

nonisolated enum ZipArchiveReader {
    static func extractSplitApks(from archiveURL: URL, to scratchDir: URL) throws -> [ZipSplitApkEntry] {
        let handle = try FileHandle(forReadingFrom: archiveURL)
        defer { try? handle.close() }

        let totalSize = try handle.seekToEnd()
        guard totalSize >= 22 else {
            throw ArchiveExtractorError.corruptedArchive("Tệp ZIP quá nhỏ")
        }

        let tailSize = Int(min(totalSize, 66_000))
        try handle.seek(toOffset: totalSize - UInt64(tailSize))
        let tail = try handle.read(upToCount: tailSize) ?? Data()

        guard let eocdOffset = findEOCD(in: tail) else {
            throw ArchiveExtractorError.corruptedArchive("Không tìm thấy End of Central Directory trong tệp APK/APKS")
        }

        let cdCount = Int(readLE16(tail, eocdOffset + 10))
        let cdSize = Int(readLE32(tail, eocdOffset + 12))
        let cdOffset = UInt64(readLE32(tail, eocdOffset + 16))
        guard cdOffset + UInt64(cdSize) <= totalSize else {
            throw ArchiveExtractorError.corruptedArchive("Central Directory vượt kích thước tệp")
        }

        try handle.seek(toOffset: cdOffset)
        let cdData = try handle.read(upToCount: cdSize) ?? Data()
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)

        var cursor = 0
        var results: [ZipSplitApkEntry] = []

        for _ in 0..<cdCount {
            try Task.checkCancellation()
            guard cursor + 46 <= cdData.count,
                  readLE32(cdData, cursor) == 0x0201_4B50 else {
                break
            }
            let method = readLE16(cdData, cursor + 10)
            let compSize = UInt64(readLE32(cdData, cursor + 20))
            let uncompSize = UInt64(readLE32(cdData, cursor + 24))
            let nameLen = Int(readLE16(cdData, cursor + 28))
            let extraLen = Int(readLE16(cdData, cursor + 30))
            let commentLen = Int(readLE16(cdData, cursor + 32))
            let localHeaderOffset = UInt64(readLE32(cdData, cursor + 42))

            let headerEnd = cursor + 46
            guard headerEnd + nameLen <= cdData.count else { break }
            let entryName = String(decoding: cdData[headerEnd..<(headerEnd + nameLen)], as: UTF8.self)
            cursor = headerEnd + nameLen + extraLen + commentLen

            let lower = entryName.lowercased()
            guard lower.hasSuffix(".apk"), !entryName.contains(".."), !entryName.hasPrefix("__MACOSX") else {
                continue
            }

            let safeName = URL(fileURLWithPath: entryName).lastPathComponent
            let destURL = scratchDir.appendingPathComponent("\(results.count)_\(safeName)")
            try extractEntry(
                handle: handle,
                localHeaderOffset: localHeaderOffset,
                compressedSize: compSize,
                method: method,
                destination: destURL
            )
            results.append(ZipSplitApkEntry(
                fileName: safeName,
                tempFileURL: destURL,
                uncompressedSize: uncompSize
            ))
        }

        // Order base.apk first, then primary/non-config APKs (largest first for .xapk/.apkm), then split configs.
        return results.sorted { lhs, rhs in
            let lLower = lhs.fileName.lowercased()
            let rLower = rhs.fileName.lowercased()
            let lIsBase = lLower == "base.apk"
            let rIsBase = rLower == "base.apk"
            if lIsBase != rIsBase { return lIsBase }

            let lIsConfig = lLower.hasPrefix("split_") || lLower.hasPrefix("config.")
            let rIsConfig = rLower.hasPrefix("split_") || rLower.hasPrefix("config.")
            if lIsConfig != rIsConfig { return !lIsConfig }

            if !lIsConfig && lhs.uncompressedSize != rhs.uncompressedSize {
                return lhs.uncompressedSize > rhs.uncompressedSize
            }
            return lhs.fileName.localizedStandardCompare(rhs.fileName) == .orderedAscending
        }
    }

    private static func extractEntry(
        handle: FileHandle,
        localHeaderOffset: UInt64,
        compressedSize: UInt64,
        method: UInt16,
        destination: URL
    ) throws {
        try handle.seek(toOffset: localHeaderOffset)
        let localHdr = try handle.read(upToCount: 30) ?? Data()
        guard localHdr.count == 30, readLE32(localHdr, 0) == 0x0403_4B50 else {
            throw ArchiveExtractorError.corruptedArchive("Local File Header ZIP không hợp lệ")
        }
        let nameLen = UInt64(readLE16(localHdr, 26))
        let extraLen = UInt64(readLE16(localHdr, 28))
        let dataOffset = localHeaderOffset + 30 + nameLen + extraLen
        try handle.seek(toOffset: dataOffset)

        let outFd = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard outFd >= 0 else {
            throw ArchiveExtractorError.ioError(errno, destination.lastPathComponent)
        }
        defer { Darwin.close(outFd) }

        if method == 0 {
            var remaining = compressedSize
            while remaining > 0 {
                try Task.checkCancellation()
                let chunk = try handle.read(upToCount: Int(min(remaining, 512 * 1024))) ?? Data()
                if chunk.isEmpty { throw ArchiveExtractorError.corruptedArchive("ZIP entry kết thúc sớm") }
                try writeFd(outFd, data: chunk, name: destination.lastPathComponent)
                remaining -= UInt64(chunk.count)
            }
            return
        }

        guard method == 8 else {
            throw ArchiveExtractorError.corruptedArchive("Phương thức nén ZIP không hỗ trợ: \(method)")
        }

        var strm = z_stream()
        let rc = dynarium_zlib_init_raw(&strm)
        guard rc == Z_OK else {
            throw ArchiveExtractorError.corruptedArchive("zlib raw inflate init failed (\(rc))")
        }
        defer { _ = dynarium_zlib_inflate_end(&strm) }

        var remaining = compressedSize
        var outBuf = [UInt8](repeating: 0, count: 512 * 1024)
        var ended = false

        while remaining > 0 && !ended {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: Int(min(remaining, 256 * 1024))) ?? Data()
            if chunk.isEmpty { throw ArchiveExtractorError.corruptedArchive("ZIP deflate bị cắt cụt") }
            remaining -= UInt64(chunk.count)

            var mutableChunk = chunk
            try mutableChunk.withUnsafeMutableBytes { mutInPtr in
                strm.next_in = mutInPtr.baseAddress?.assumingMemoryBound(to: Bytef.self)
                strm.avail_in = uInt(chunk.count)

                repeat {
                    let produced = try outBuf.withUnsafeMutableBytes { outPtr -> Int in
                        strm.next_out = outPtr.baseAddress?.assumingMemoryBound(to: Bytef.self)
                        strm.avail_out = uInt(512 * 1024)
                        let infRc = dynarium_zlib_inflate(&strm, Z_NO_FLUSH)
                        if infRc == Z_STREAM_END {
                            ended = true
                        } else if infRc != Z_OK && infRc != Z_BUF_ERROR {
                            throw ArchiveExtractorError.corruptedArchive("ZIP inflate error \(infRc)")
                        }
                        return (512 * 1024) - Int(strm.avail_out)
                    }
                    if produced > 0 {
                        try writeFdBytes(outFd, bytes: outBuf, count: produced, name: destination.lastPathComponent)
                    }
                } while strm.avail_out == 0 && !ended
            }
        }
    }

    private static func writeFd(_ fd: Int32, data: Data, name: String) throws {
        try data.withUnsafeBytes { ptr in
            var sent = 0
            while sent < ptr.count {
                let n = Darwin.write(fd, ptr.baseAddress!.advanced(by: sent), ptr.count - sent)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw ArchiveExtractorError.ioError(errno, name)
                }
                sent += n
            }
        }
    }

    private static func writeFdBytes(_ fd: Int32, bytes: [UInt8], count: Int, name: String) throws {
        try bytes.withUnsafeBytes { ptr in
            var sent = 0
            while sent < count {
                let n = Darwin.write(fd, ptr.baseAddress!.advanced(by: sent), count - sent)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw ArchiveExtractorError.ioError(errno, name)
                }
                sent += n
            }
        }
    }

    private static func findEOCD(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        for idx in stride(from: data.count - 22, through: 0, by: -1) {
            if data[idx] == 0x50, data[idx + 1] == 0x4B, data[idx + 2] == 0x05, data[idx + 3] == 0x06 {
                return idx
            }
        }
        return nil
    }

    private static func readLE16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readLE32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
