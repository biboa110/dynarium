// SPDX-License-Identifier: GPL-2.0-or-later

import Darwin
import Foundation
import Security

// MARK: - ADB Error & Clock

nonisolated enum AdbError: Error, Equatable, Sendable {
    case refused
    case notAnswering
    case guestGone
    case timedOut
    case cancelled
    case keyRejected
    case serviceRefused(String)
    case streamClosed
    case protocolViolation(String)
    case remote(String)
    case io(Int32)

    var localizedMessage: String {
        switch self {
        case .refused:
            return "Dịch vụ ADB trong Android chưa sẵn sàng (máy đang khởi động hoặc chưa bật Gỡ lỗi USB)."
        case .notAnswering:
            return "Không nhận được phản hồi từ Android qua VSOCK."
        case .guestGone:
            return "Kết nối tới Android đã đóng."
        case .timedOut:
            return "Quá thời gian chờ phản hồi từ Android."
        case .cancelled:
            return "Thao tác đã bị hủy."
        case .keyRejected:
            return "Android từ chối khóa xác thực ADB của máy ảo này."
        case .serviceRefused(let svc):
            return "Android từ chối mở dịch vụ: \(svc)"
        case .streamClosed:
            return "Luồng truyền dữ liệu ADB đã đóng sớm."
        case .protocolViolation(let detail):
            return "Lỗi giao thức ADB: \(detail)"
        case .remote(let detail):
            return "Android báo lỗi: \(detail)"
        case .io(let code):
            return "Lỗi kết nối I/O: \(String(cString: strerror(code)))"
        }
    }
}

nonisolated final class AdbRunClock: @unchecked Sendable {
    private let lock = NSLock()
    private var pausedAt: TimeInterval?
    private var pausedAccumulated: TimeInterval = 0

    var nowSeconds: TimeInterval {
        lock.withLock {
            let up = ProcessInfo.processInfo.systemUptime
            if let p = pausedAt {
                return p - pausedAccumulated
            }
            return up - pausedAccumulated
        }
    }

    func setPaused(_ paused: Bool) {
        lock.withLock {
            let up = ProcessInfo.processInfo.systemUptime
            if paused {
                if pausedAt == nil { pausedAt = up }
            } else if let p = pausedAt {
                pausedAccumulated += max(0, up - p)
                pausedAt = nil
            }
        }
    }
}

// MARK: - Wire Protocol

nonisolated enum AdbWire {
    static let headerSize = 24
    static let version: UInt32 = 0x0100_0001
    static let maxData = 1 << 20

    static let cnxn = fourCC("CNXN")
    static let auth = fourCC("AUTH")
    static let open = fourCC("OPEN")
    static let okay = fourCC("OKAY")
    static let close = fourCC("CLSE")
    static let write = fourCC("WRTE")

    static let authToken: UInt32 = 1
    static let authSignature: UInt32 = 2
    static let hostBanner = "host::features=shell_v2,cmd,stat_v2,ls_v2,abb_exec"

    static func fourCC(_ tag: String) -> UInt32 {
        var value: UInt32 = 0
        for (index, byte) in tag.utf8.prefix(4).enumerated() {
            value |= UInt32(byte) << (8 * UInt32(index))
        }
        return value
    }
}

nonisolated struct AdbMessage: Equatable, Sendable {
    var command: UInt32
    var arg0: UInt32
    var arg1: UInt32
    var payload: Data

    init(command: UInt32, arg0: UInt32 = 0, arg1: UInt32 = 0, payload: Data = Data()) {
        self.command = command
        self.arg0 = arg0
        self.arg1 = arg1
        self.payload = payload
    }

    func encoded() -> Data {
        var data = Data(capacity: AdbWire.headerSize + payload.count)
        data.appendLE32(command)
        data.appendLE32(arg0)
        data.appendLE32(arg1)
        data.appendLE32(UInt32(payload.count))
        data.appendLE32(0)
        data.appendLE32(~command)
        data.append(payload)
        return data
    }

    struct Header: Equatable, Sendable {
        var command: UInt32
        var arg0: UInt32
        var arg1: UInt32
        var length: Int

        init(_ bytes: Data, maxData: Int = AdbWire.maxData) throws {
            guard bytes.count == AdbWire.headerSize else {
                throw AdbError.protocolViolation("a header of \(bytes.count) bytes")
            }
            command = bytes.readLE32(at: 0)
            arg0 = bytes.readLE32(at: 4)
            arg1 = bytes.readLE32(at: 8)
            let length = bytes.readLE32(at: 12)
            guard bytes.readLE32(at: 20) == ~command else {
                throw AdbError.protocolViolation("a header with a bad magic")
            }
            guard length <= UInt32(maxData) else {
                throw AdbError.protocolViolation("a payload of \(length) bytes")
            }
            self.length = Int(length)
        }
    }
}

private nonisolated extension Data {
    func readLE32(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(self[startIndex + offset + index]) << (8 * UInt32(index))
        }
        return value
    }

    mutating func appendLE32(_ value: UInt32) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}

// MARK: - ADB RSA-2048 Key Encoding & Keychain

nonisolated enum AdbPublicKey {
    static let wordCount = 64

    enum Failure: Error, Equatable, Sendable {
        case notPKCS1
        case wrongSize(bits: Int)
        case wrongExponent
    }

    static func encode(pkcs1: Data) throws -> String {
        try structure(pkcs1: pkcs1).base64EncodedString()
    }

    static func structure(pkcs1: Data) throws -> Data {
        let parts = try parse(pkcs1)
        guard parts.modulus.count == 4 * wordCount else {
            throw Failure.wrongSize(bits: parts.modulus.count * 8)
        }
        guard parts.exponent == 65537 else { throw Failure.wrongExponent }

        var modulus = [UInt32](repeating: 0, count: wordCount)
        for index in 0..<wordCount {
            let offset = parts.modulus.count - 4 * (index + 1)
            var word: UInt32 = 0
            for byte in 0..<4 { word = word << 8 | UInt32(parts.modulus[offset + byte]) }
            modulus[index] = word
        }
        guard modulus[0] & 1 == 1, modulus[wordCount - 1] >> 31 == 1 else {
            throw Failure.wrongSize(bits: parts.modulus.count * 8 - 1)
        }

        var data = Data(capacity: 4 + 4 + 4 * 64 + 4 * 64 + 4)
        data.appendLE32(UInt32(wordCount))
        data.appendLE32(negatedInverse(of: modulus[0]))
        for word in modulus { data.appendLE32(word) }
        for word in rr(modulus: modulus) { data.appendLE32(word) }
        data.appendLE32(UInt32(65537))
        return data
    }

    private static func negatedInverse(of n: UInt32) -> UInt32 {
        var inverse = n
        for _ in 0..<5 { inverse = inverse &* (2 &- n &* inverse) }
        return 0 &- inverse
    }

    private static func rr(modulus n: [UInt32]) -> [UInt32] {
        var value = [UInt32](repeating: 0, count: n.count)
        value[0] = 1
        for _ in 0..<(32 * n.count * 2) {
            var carry: UInt32 = 0
            for index in 0..<n.count {
                let next = value[index] >> 31
                value[index] = value[index] << 1 | carry
                carry = next
            }
            if carry == 1 || !isLess(value, n) { subtract(&value, n) }
        }
        return value
    }

    private static func isLess(_ a: [UInt32], _ b: [UInt32]) -> Bool {
        for index in stride(from: a.count - 1, through: 0, by: -1) where a[index] != b[index] {
            return a[index] < b[index]
        }
        return false
    }

    private static func subtract(_ a: inout [UInt32], _ b: [UInt32]) {
        var borrow: UInt64 = 0
        for index in 0..<a.count {
            let difference = UInt64(a[index]) &- UInt64(b[index]) &- borrow
            a[index] = UInt32(truncatingIfNeeded: difference)
            borrow = difference >> 63
        }
    }

    private static func parse(_ der: Data) throws -> (modulus: [UInt8], exponent: UInt64) {
        var reader = DERReader(Array(der))
        let sequence = try reader.read(tag: 0x30)
        var inner = DERReader(sequence)
        var modulus = try inner.read(tag: 0x02)
        let exponentBytes = try inner.read(tag: 0x02)
        guard inner.isAtEnd, reader.isAtEnd, exponentBytes.count <= 8 else { throw Failure.notPKCS1 }
        while modulus.first == 0 { modulus.removeFirst() }
        let exponent = exponentBytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return (modulus, exponent)
    }

    private struct DERReader {
        let bytes: [UInt8]
        var position = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }
        var isAtEnd: Bool { position == bytes.count }

        mutating func read(tag: UInt8) throws -> [UInt8] {
            guard position < bytes.count, bytes[position] == tag else { throw Failure.notPKCS1 }
            position += 1
            guard position < bytes.count else { throw Failure.notPKCS1 }
            var length = Int(bytes[position])
            position += 1
            if length & 0x80 != 0 {
                let count = length & 0x7F
                guard (1...3).contains(count), position + count <= bytes.count else { throw Failure.notPKCS1 }
                length = 0
                for _ in 0..<count {
                    length = length << 8 | Int(bytes[position])
                    position += 1
                }
            }
            guard position + length <= bytes.count else { throw Failure.notPKCS1 }
            defer { position += length }
            return Array(bytes[position..<(position + length)])
        }
    }
}

nonisolated protocol AdbSigner: Sendable {
    func sign(token: Data) throws -> Data
}

nonisolated struct SecKeySigner: AdbSigner, @unchecked Sendable {
    private let key: SecKey

    init(privateKey: SecKey) {
        self.key = privateKey
    }

    func sign(token: Data) throws -> Data {
        let alg = SecKeyAlgorithm.rsaSignatureDigestPKCS1v15SHA1
        guard SecKeyIsAlgorithmSupported(key, .sign, alg) else {
            throw AdbError.protocolViolation("Khóa RSA không hỗ trợ ký ADB")
        }
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, alg, token as CFData, &error) else {
            let code = error.map { Int32(clamping: CFErrorGetCode($0.takeRetainedValue())) } ?? -1
            throw AdbError.io(code)
        }
        return signature as Data
    }
}

nonisolated struct AdbKeyStore {
    static let baseTag = "com.dynarium.app.adb-key"
    static let label = "Dynarium ADB debugging key"

    struct Identity: @unchecked Sendable {
        var privateKey: SecKey
        var publicKeyLine: String
        var signer: SecKeySigner { SecKeySigner(privateKey: privateKey) }
    }

    enum Failure: Error, Equatable {
        case keychain(OSStatus)
        case noPublicKey
    }

    let tag: String

    init(tag: String) {
        self.tag = tag
    }

    static func forVM(_ vmID: UUID) -> AdbKeyStore {
        AdbKeyStore(tag: "\(baseTag).\(vmID.uuidString)")
    }

    private var tagData: Data { Data(tag.utf8) }
    private static let creationLock = NSLock()

    func find() throws -> SecKey? {
        let query: [String: Any] = baseQuery().merging([
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { _, new in new }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let item, CFGetTypeID(item) == SecKeyGetTypeID() else { throw Failure.noPublicKey }
            return unsafeDowncast(item, to: SecKey.self)
        case errSecItemNotFound:
            return nil
        default:
            throw Failure.keychain(status)
        }
    }

    func loadOrCreate() throws -> Identity {
        Self.creationLock.lock()
        defer { Self.creationLock.unlock() }
        let key = try find() ?? create()
        return try Identity(privateKey: key, publicKeyLine: Self.line(for: key))
    }

    private func create() throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecUseDataProtectionKeychain as String: true,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tagData,
                kSecAttrLabel as String: Self.label,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ] as [String: Any],
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let code = error.map { OSStatus(truncatingIfNeeded: CFErrorGetCode($0.takeRetainedValue())) } ?? errSecInternalError
            throw Failure.keychain(code)
        }
        return key
    }

    @discardableResult
    func delete() -> Bool {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrApplicationTag as String: tagData,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    static func line(for privateKey: SecKey) throws -> String {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else { throw Failure.noPublicKey }
        var error: Unmanaged<CFError>?
        guard let der = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw Failure.noPublicKey
        }
        return try AdbPublicKey.encode(pkcs1: der)
    }
}

// MARK: - Transport & Connection

nonisolated protocol AdbTransport: AnyObject, Sendable {
    func readExactly(_ count: Int) throws -> Data
    func writeAll(_ data: Data) throws
    func shutdown()
}

nonisolated final class DescriptorTransport: AdbTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    private var ended = false

    init(descriptor: Int32) {
        self.descriptor = descriptor
        var on: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit {
        if descriptor >= 0 { Darwin.close(descriptor) }
    }

    func readExactly(_ count: Int) throws -> Data {
        var data = Data(count: count)
        var done = 0
        while done < count {
            let fd = try currentDescriptor()
            try waitReadable(fd)
            let got = data.withUnsafeMutableBytes { buffer in
                Darwin.read(fd, buffer.baseAddress! + done, count - done)
            }
            if got > 0 {
                done += got
            } else if got == 0 {
                throw AdbError.guestGone
            } else if errno == EINTR || errno == EAGAIN {
                continue
            } else {
                throw Self.translated(errno)
            }
        }
        return data
    }

    func writeAll(_ data: Data) throws {
        var done = 0
        while done < data.count {
            let fd = try currentDescriptor()
            let wrote = data.withUnsafeBytes { buffer in
                Darwin.write(fd, buffer.baseAddress! + done, data.count - done)
            }
            if wrote >= 0 {
                done += wrote
            } else if errno == EINTR {
                continue
            } else {
                throw Self.translated(errno)
            }
        }
    }

    func shutdown() {
        lock.withLock {
            guard !ended, descriptor >= 0 else { return }
            ended = true
            _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        }
    }

    private func currentDescriptor() throws -> Int32 {
        try lock.withLock {
            guard !ended, descriptor >= 0 else { throw AdbError.guestGone }
            return descriptor
        }
    }

    private func waitReadable(_ fd: Int32) throws {
        var entry = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while true {
            let ready = poll(&entry, 1, 1000)
            if ready > 0 { return }
            if ready < 0, errno != EINTR { throw Self.translated(errno) }
            _ = try currentDescriptor()
        }
    }

    private static func translated(_ code: Int32) -> AdbError {
        switch code {
        case ECONNRESET, EPIPE, ENOTCONN, ECONNABORTED, EBADF: .guestGone
        default: .io(code)
        }
    }
}

nonisolated struct VsockAdbConnector: Sendable {
    static let adbPort: UInt32 = 5555
    let timeoutMs: UInt32

    init(timeoutMs: UInt32 = 3000) {
        self.timeoutMs = timeoutMs
    }

    func connect() throws -> DescriptorTransport {
        let fd = kernarium_runtime_loader_connect_vsock(Self.adbPort, timeoutMs)
        if fd >= 0 {
            return DescriptorTransport(descriptor: fd)
        }
        let code = -fd
        switch code {
        case ECONNREFUSED, ENODEV:
            throw AdbError.refused
        case ETIMEDOUT:
            throw AdbError.notAnswering
        default:
            throw AdbError.io(code)
        }
    }
}

nonisolated struct AdbBanner: Equatable, Sendable {
    var features: Set<String>
    var text: String

    init(payload: Data) {
        var bytes = payload
        while bytes.last == 0 { bytes.removeLast() }
        text = String(decoding: bytes, as: UTF8.self)
        var found = Set<String>()
        for field in text.split(separator: ";") where field.hasPrefix("features=") || field.contains("::features=") {
            let list = field.split(separator: "=", maxSplits: 1).last ?? ""
            found.formUnion(list.split(separator: ",").map(String.init))
        }
        features = found
    }
}

nonisolated final class AdbConnection {
    let transport: any AdbTransport
    private(set) var maxData = AdbWire.maxData
    private(set) var banner = AdbBanner(payload: Data())
    private var nextLocalID: UInt32 = 1

    init(transport: any AdbTransport) {
        self.transport = transport
    }

    func send(_ message: AdbMessage) throws {
        try transport.writeAll(message.encoded())
    }

    func receive() throws -> AdbMessage {
        let header = try AdbMessage.Header(transport.readExactly(AdbWire.headerSize))
        let payload = header.length > 0 ? try transport.readExactly(header.length) : Data()
        return AdbMessage(command: header.command, arg0: header.arg0, arg1: header.arg1, payload: payload)
    }

    @discardableResult
    func handshake(signer: (any AdbSigner)?) throws -> AdbBanner {
        var connect = Data(AdbWire.hostBanner.utf8)
        connect.append(0)
        try send(AdbMessage(
            command: AdbWire.cnxn, arg0: AdbWire.version, arg1: UInt32(AdbWire.maxData), payload: connect
        ))
        var signed = false
        while true {
            let message = try receive()
            switch message.command {
            case AdbWire.cnxn:
                banner = AdbBanner(payload: message.payload)
                maxData = max(1, min(AdbWire.maxData, Int(message.arg1)))
                return banner
            case AdbWire.auth where message.arg0 == AdbWire.authToken:
                guard let signer, !signed else { throw AdbError.keyRejected }
                try send(AdbMessage(
                    command: AdbWire.auth, arg0: AdbWire.authSignature, payload: signer.sign(token: message.payload)
                ))
                signed = true
            default:
                throw AdbError.protocolViolation("Unexpected command \(String(format: "%08x", message.command))")
            }
        }
    }

    func open(_ service: String) throws -> AdbStream {
        let local = nextLocalID
        nextLocalID &+= 1
        var name = Data(service.utf8)
        name.append(0)
        try send(AdbMessage(command: AdbWire.open, arg0: local, payload: name))
        while true {
            let message = try receive()
            guard message.arg1 == local else { continue }
            switch message.command {
            case AdbWire.okay:
                return AdbStream(connection: self, localID: local, remoteID: message.arg0)
            case AdbWire.close:
                throw AdbError.serviceRefused(service)
            default:
                throw AdbError.protocolViolation("Unexpected response \(String(format: "%08x", message.command))")
            }
        }
    }
}

nonisolated final class AdbStream {
    private unowned let connection: AdbConnection
    let localID: UInt32
    let remoteID: UInt32
    private var queued: [Data] = []
    private(set) var isClosed = false

    init(connection: AdbConnection, localID: UInt32, remoteID: UInt32) {
        self.connection = connection
        self.localID = localID
        self.remoteID = remoteID
    }

    func write(_ data: Data) throws {
        var offset = data.startIndex
        while offset < data.endIndex {
            guard !isClosed else { throw AdbError.streamClosed }
            let end = min(offset + connection.maxData, data.endIndex)
            try connection.send(AdbMessage(
                command: AdbWire.write, arg0: localID, arg1: remoteID, payload: data[offset..<end]
            ))
            offset = end
            try awaitOkay()
        }
    }

    private func awaitOkay() throws {
        while true {
            let message = try connection.receive()
            guard message.arg1 == localID else { continue }
            switch message.command {
            case AdbWire.okay:
                return
            case AdbWire.write:
                try accept(message)
            case AdbWire.close:
                peerClosed()
                throw AdbError.streamClosed
            default:
                continue
            }
        }
    }

    func read() throws -> Data? {
        while true {
            if !queued.isEmpty { return queued.removeFirst() }
            if isClosed { return nil }
            let message = try connection.receive()
            guard message.arg1 == localID else { continue }
            switch message.command {
            case AdbWire.write:
                try accept(message)
            case AdbWire.close:
                peerClosed()
            default:
                continue
            }
        }
    }

    private func accept(_ message: AdbMessage) throws {
        try connection.send(AdbMessage(command: AdbWire.okay, arg0: localID, arg1: remoteID))
        if !message.payload.isEmpty { queued.append(message.payload) }
    }

    private func peerClosed() {
        guard !isClosed else { return }
        isClosed = true
        try? connection.send(AdbMessage(command: AdbWire.close, arg0: localID, arg1: remoteID))
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        try? connection.send(AdbMessage(command: AdbWire.close, arg0: localID, arg1: remoteID))
    }

    func readToEnd(limit: Int = 1 << 20) throws -> Data {
        var all = Data()
        while let chunk = try read() {
            all.append(chunk)
            if all.count > limit { throw AdbError.protocolViolation("Output exceeded \(limit) bytes") }
        }
        return all
    }
}

// MARK: - Shell V2 & Watchdog Session

nonisolated struct ShellPacket: Equatable, Sendable {
    static let stdout: UInt8 = 1
    static let stderr: UInt8 = 2
    static let exit: UInt8 = 3

    var id: UInt8
    var data: Data
}

nonisolated struct ShellV2Decoder: Sendable {
    private var buffer = Data()

    mutating func feed(_ data: Data) throws -> [ShellPacket] {
        buffer.append(data)
        var packets: [ShellPacket] = []
        var offset = buffer.startIndex
        while buffer.endIndex - offset >= 5 {
            let length = Int(buffer.readLE32(at: offset - buffer.startIndex + 1))
            guard length <= AdbWire.maxData else {
                throw AdbError.protocolViolation("Shell packet length \(length) too large")
            }
            guard buffer.endIndex - offset >= 5 + length else { break }
            packets.append(ShellPacket(id: buffer[offset], data: Data(buffer[(offset + 5)..<(offset + 5 + length)])))
            offset += 5 + length
        }
        buffer = Data(buffer[offset...])
        return packets
    }
}

nonisolated struct ShellResult: Equatable, Sendable {
    var stdout = Data()
    var stderr = Data()
    var exitCode: Int?

    var text: String { String(decoding: stdout, as: UTF8.self) }
}

nonisolated extension AdbConnection {
    func runShell(_ command: String, limit: Int = 1 << 20) throws -> ShellResult {
        let stream = try open("shell,v2,raw:\(command)")
        defer { stream.close() }
        var decoder = ShellV2Decoder()
        var result = ShellResult()
        while let chunk = try stream.read() {
            for packet in try decoder.feed(chunk) {
                switch packet.id {
                case ShellPacket.stdout:
                    guard result.stdout.count + packet.data.count <= limit else {
                        throw AdbError.protocolViolation("Shell stdout limit exceeded")
                    }
                    result.stdout.append(packet.data)
                case ShellPacket.stderr:
                    guard result.stderr.count + packet.data.count <= limit else {
                        throw AdbError.protocolViolation("Shell stderr limit exceeded")
                    }
                    result.stderr.append(packet.data)
                case ShellPacket.exit:
                    if let first = packet.data.first { result.exitCode = Int(first) }
                default:
                    break
                }
            }
        }
        return result
    }
}

nonisolated final class AdbWatchdog: @unchecked Sendable {
    enum Cause: Equatable, Sendable { case none, timedOut, cancelled }

    private let condition = NSCondition()
    private let clock: AdbRunClock
    private var transport: (any AdbTransport)?
    private var idleLimit: TimeInterval?
    private var overallDeadline: TimeInterval?
    private var lastActivity: TimeInterval
    private var armed = false
    private var cause = Cause.none
    private var stopped = false

    init(clock: AdbRunClock) {
        self.clock = clock
        self.lastActivity = clock.nowSeconds
        let thread = Thread { [weak self] in self?.watchLoop() }
        thread.name = "dynarium-adb-watchdog"
        thread.start()
    }

    var currentCause: Cause { condition.withLock { cause } }

    func attach(_ transport: any AdbTransport) {
        let ended = condition.withLock { () -> Bool in
            self.transport = transport
            return cause != .none
        }
        if ended { transport.shutdown() }
    }

    func arm(idle: TimeInterval?, overall: TimeInterval? = nil) {
        condition.withLock {
            let now = clock.nowSeconds
            idleLimit = idle
            overallDeadline = overall.map { now + $0 }
            lastActivity = now
            armed = true
        }
    }

    func disarm() { condition.withLock { armed = false } }
    func touch() { condition.withLock { lastActivity = clock.nowSeconds } }

    func cancel() {
        let target = condition.withLock { () -> (any AdbTransport)? in
            if cause == .none { cause = .cancelled }
            condition.broadcast()
            return transport
        }
        target?.shutdown()
    }

    func sleep(_ seconds: TimeInterval) {
        let end = Date(timeIntervalSinceNow: seconds)
        condition.withLock {
            while cause == .none, !stopped, Date() < end {
                _ = condition.wait(until: end)
            }
        }
    }

    func stop() {
        condition.withLock {
            stopped = true
            condition.broadcast()
        }
    }

    private func watchLoop() {
        condition.lock()
        defer { condition.unlock() }
        while !stopped {
            if armed, cause == .none {
                let now = clock.nowSeconds
                let idle = idleLimit.map { now - lastActivity >= $0 } ?? false
                let late = overallDeadline.map { now >= $0 } ?? false
                if idle || late {
                    cause = .timedOut
                    condition.broadcast()
                    let target = transport
                    condition.unlock()
                    target?.shutdown()
                    condition.lock()
                }
            }
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.25))
        }
    }
}

nonisolated final class AdbSession: @unchecked Sendable {
    private let connector: VsockAdbConnector
    private let signer: (any AdbSigner)?
    private let connectLimit: TimeInterval
    let watchdog: AdbWatchdog

    init(
        connector: VsockAdbConnector = VsockAdbConnector(),
        signer: (any AdbSigner)?,
        clock: AdbRunClock,
        connectLimit: TimeInterval = 20
    ) {
        self.connector = connector
        self.signer = signer
        self.connectLimit = connectLimit
        self.watchdog = AdbWatchdog(clock: clock)
    }

    func cancel() { watchdog.cancel() }

    func run<Result>(_ body: (AdbConnection) throws -> Result) throws -> Result {
        defer { watchdog.stop() }
        var transport: DescriptorTransport?
        defer { transport?.shutdown() }
        var connected: AdbConnection?
        var unanswered: AdbError?

        do {
            watchdog.arm(idle: nil, overall: connectLimit)
            while connected == nil {
                let opened = try openTransport(unanswered: &unanswered)
                transport = opened
                watchdog.attach(opened)
                let candidate = AdbConnection(transport: opened)
                do {
                    try candidate.handshake(signer: signer)
                    connected = candidate
                } catch AdbError.guestGone where ended() == nil {
                    opened.shutdown()
                    transport = nil
                    watchdog.sleep(1.0)
                    if let end = ended() { throw end }
                }
            }
            watchdog.disarm()
        } catch {
            let finalError = translated(error)
            if let adbErr = finalError as? AdbError, adbErr == .timedOut {
                throw unanswered == .notAnswering ? AdbError.notAnswering : AdbError.refused
            }
            throw finalError
        }

        guard let connection = connected else { throw AdbError.guestGone }
        do {
            return try body(connection)
        } catch {
            throw translated(error)
        }
    }

    private func openTransport(unanswered: inout AdbError?) throws -> DescriptorTransport {
        while true {
            if let end = ended() { throw end }
            do {
                let opened = try connector.connect()
                unanswered = nil
                return opened
            } catch let failure as AdbError where failure == .refused || failure == .notAnswering {
                unanswered = failure
                if let end = ended() { throw end }
                watchdog.sleep(1.0)
            }
        }
    }

    private func ended() -> AdbError? {
        switch watchdog.currentCause {
        case .none: nil
        case .timedOut: .timedOut
        case .cancelled: .cancelled
        }
    }

    private func translated(_ error: Error) -> Error {
        ended() ?? error
    }
}

// MARK: - LAN Address & ADB-over-LAN TCP Forwarder

nonisolated enum LanAddress {
    static func currentIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(first) }
        var candidates: [(name: String, ip: String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let addr = entry.pointee.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let flags = Int32(entry.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_RUNNING) != 0, (flags & IFF_LOOPBACK) == 0 else {
                continue
            }
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            let raw = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let o1 = UInt8(truncatingIfNeeded: raw >> 24)
            let o2 = UInt8(truncatingIfNeeded: raw >> 16)
            let o3 = UInt8(truncatingIfNeeded: raw >> 8)
            let o4 = UInt8(truncatingIfNeeded: raw)
            if (o1 == 0 && o2 == 0 && o3 == 0 && o4 == 0) || o1 == 127 || (o1 == 169 && o2 == 254) {
                continue
            }
            candidates.append((name, "\(o1).\(o2).\(o3).\(o4)"))
        }
        return candidates.first { $0.name == "en0" }?.ip ?? candidates.first?.ip
    }
}

nonisolated final class AdbNetworkBridge: @unchecked Sendable {
    static let defaultPort: UInt16 = 5555

    private let port: UInt16
    private let maxPeers: Int
    private let lock = NSLock()
    private var running = false
    private var boundPort: UInt16 = 0
    private var wakeWriter: Int32 = -1
    private var links: [ObjectIdentifier: Link] = [:]
    private var acceptFinished: DispatchSemaphore?

    init(port: UInt16 = AdbNetworkBridge.defaultPort, maxPeers: Int = 8) {
        self.port = port
        self.maxPeers = maxPeers
    }

    var isRunning: Bool { lock.withLock { running } }

    @discardableResult
    func start() throws -> UInt16 {
        try lock.withLock { () throws -> UInt16 in
            if running { return boundPort }
            let listener = try Self.makeListener(port: port)
            var pipeEnds: [Int32] = [-1, -1]
            guard pipe(&pipeEnds) == 0 else {
                let code = errno
                Darwin.close(listener)
                throw AdbError.io(code)
            }
            let wakeReader = pipeEnds[0]
            let bound = (try? Self.localPort(of: listener)) ?? port
            running = true
            boundPort = bound
            wakeWriter = pipeEnds[1]
            let finished = DispatchSemaphore(value: 0)
            acceptFinished = finished
            spawnThread(name: "dynarium-adb-lan-listener") { [self] in
                acceptLoop(listener: listener, wake: wakeReader)
                Darwin.close(listener)
                Darwin.close(wakeReader)
                finished.signal()
            }
            return bound
        }
    }

    func stop() {
        let taken: (links: [Link], writer: Int32, finished: DispatchSemaphore?)? = lock.withLock {
            guard running else { return nil }
            running = false
            let writer = wakeWriter
            wakeWriter = -1
            let finished = acceptFinished
            acceptFinished = nil
            return (Array(links.values), writer, finished)
        }
        guard let taken else { return }
        var byte: UInt8 = 1
        _ = Darwin.write(taken.writer, &byte, 1)
        Darwin.close(taken.writer)
        for link in taken.links { link.abort() }
        _ = taken.finished?.wait(timeout: .now() + 2)
    }

    private static func makeListener(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AdbError.io(errno) }
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)
        let bound = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw AdbError.io(code)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return fd
    }

    private static func localPort(of fd: Int32) throws -> UInt16 {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafeMutablePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard rc == 0 else { throw AdbError.io(errno) }
        return UInt16(bigEndian: address.sin_port)
    }

    private func acceptLoop(listener: Int32, wake: Int32) {
        var fds = [
            pollfd(fd: listener, events: Int16(POLLIN), revents: 0),
            pollfd(fd: wake, events: Int16(POLLIN), revents: 0),
        ]
        while true {
            let ready = poll(&fds, 2, -1)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if fds[1].revents != 0 { return }
            guard (fds[0].revents & Int16(POLLIN)) != 0 else {
                if fds[0].revents != 0 { return }
                continue
            }
            let peer = accept(listener, nil, nil)
            if peer < 0 {
                if errno == EINTR || errno == EAGAIN || errno == ECONNABORTED || errno == EPROTO { continue }
                if errno == EMFILE || errno == ENFILE { usleep(50_000); continue }
                return
            }
            admit(peer)
        }
    }

    private func admit(_ peer: Int32) {
        Self.configure(peer: peer)
        guard let link = Link(peer: peer) else { Darwin.close(peer); return }
        let admitted = lock.withLock { () -> Bool in
            guard running, links.count < maxPeers else { return false }
            links[ObjectIdentifier(link)] = link
            return true
        }
        guard admitted else { link.closeDescriptors(); return }
        spawnThread(name: "dynarium-adb-lan-peer") { [self] in serve(link) }
    }

    private static func configure(peer: Int32) {
        Link.makeNonBlocking(peer)
        var on: Int32 = 1
        let size = socklen_t(MemoryLayout<Int32>.size)
        _ = setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &on, size)
        _ = setsockopt(peer, IPPROTO_TCP, TCP_NODELAY, &on, size)
        _ = setsockopt(peer, SOL_SOCKET, SO_KEEPALIVE, &on, size)
        var idle: Int32 = 30
        var interval: Int32 = 10
        var count: Int32 = 3
        _ = setsockopt(peer, IPPROTO_TCP, TCP_KEEPALIVE, &idle, size)
        _ = setsockopt(peer, IPPROTO_TCP, TCP_KEEPINTVL, &interval, size)
        _ = setsockopt(peer, IPPROTO_TCP, TCP_KEEPCNT, &count, size)
    }

    private func serve(_ link: Link) {
        let guest = kernarium_runtime_loader_connect_vsock(VsockAdbConnector.adbPort, 3000)
        guard guest >= 0 else {
            finish(link, closing: nil)
            return
        }
        var on: Int32 = 1
        _ = setsockopt(guest, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        Link.makeNonBlocking(guest)
        guard link.attach(guest: guest) else {
            finish(link, closing: guest)
            return
        }
        spawnThread(name: "dynarium-adb-lan-guest") { [self] in
            pump(from: guest, to: link.peer, link: link)
            if link.pumpEnded() { finish(link, closing: nil) }
        }
        pump(from: link.peer, to: guest, link: link)
        if link.pumpEnded() { finish(link, closing: nil) }
    }

    private func pump(from source: Int32, to sink: Int32, link: Link) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            guard link.wait(for: source, events: Int16(POLLIN)) else { return }
            let got = buffer.withUnsafeMutableBytes { Darwin.read(source, $0.baseAddress, $0.count) }
            if got == 0 {
                _ = Darwin.shutdown(sink, SHUT_WR)
                return
            }
            if got < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                link.abort()
                return
            }
            var done = 0
            while done < got {
                let wrote = buffer.withUnsafeBytes { Darwin.write(sink, $0.baseAddress! + done, got - done) }
                if wrote > 0 {
                    done += wrote
                } else if wrote < 0 && errno == EINTR {
                    continue
                } else if wrote < 0 && errno == EAGAIN {
                    guard link.wait(for: sink, events: Int16(POLLOUT)) else { return }
                } else {
                    link.abort()
                    return
                }
            }
        }
    }

    private func finish(_ link: Link, closing extra: Int32?) {
        if let extra { Darwin.close(extra) }
        link.closeDescriptors()
        lock.withLock { _ = links.removeValue(forKey: ObjectIdentifier(link)) }
    }

    private func spawnThread(name: String, _ body: @escaping @Sendable () -> Void) {
        let thread = Thread { body() }
        thread.name = name
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private final class Link: @unchecked Sendable {
        let peer: Int32
        private let wakeReader: Int32
        private let wakeWriter: Int32
        private let lock = NSLock()
        private var guest: Int32 = -1
        private var aborted = false
        private var closed = false
        private var pumpsRunning = 0

        init?(peer: Int32) {
            var ends: [Int32] = [-1, -1]
            guard pipe(&ends) == 0 else { return nil }
            self.peer = peer
            self.wakeReader = ends[0]
            self.wakeWriter = ends[1]
            Self.makeNonBlocking(ends[0])
            Self.makeNonBlocking(ends[1])
        }

        static func makeNonBlocking(_ descriptor: Int32) {
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        }

        func attach(guest: Int32) -> Bool {
            lock.withLock {
                guard !aborted else { return false }
                self.guest = guest
                pumpsRunning = 2
                return true
            }
        }

        func wait(for descriptor: Int32, events: Int16) -> Bool {
            var fds = [
                pollfd(fd: wakeReader, events: Int16(POLLIN), revents: 0),
                pollfd(fd: descriptor, events: events, revents: 0),
            ]
            while true {
                if poll(&fds, 2, -1) < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if fds[0].revents != 0 { return false }
                if (fds[1].revents & Int16(POLLNVAL)) != 0 { return false }
                if fds[1].revents != 0 { return true }
            }
        }

        func abort() {
            lock.withLock {
                aborted = true
                guard !closed else { return }
                var byte: UInt8 = 1
                _ = Darwin.write(wakeWriter, &byte, 1)
                _ = Darwin.shutdown(peer, SHUT_RDWR)
                if guest >= 0 { _ = Darwin.shutdown(guest, SHUT_RDWR) }
            }
        }

        func pumpEnded() -> Bool {
            lock.withLock {
                pumpsRunning -= 1
                return pumpsRunning == 0
            }
        }

        func closeDescriptors() {
            lock.withLock {
                guard !closed else { return }
                closed = true
                Darwin.close(peer)
                if guest >= 0 { Darwin.close(guest) }
                Darwin.close(wakeReader)
                Darwin.close(wakeWriter)
            }
        }
    }
}
