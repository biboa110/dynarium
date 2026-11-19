// SPDX-License-Identifier: GPL-2.0-or-later

import Combine
import Darwin
import Foundation
import GuestHostCore

nonisolated enum VMBootMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case normal
    case recovery

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: "Tự động"
        case .normal: "Android Bình thường"
        case .recovery: "Khôi phục (Recovery)"
        }
    }

    var runtimeValue: UInt32 {
        switch self {
        case .auto: UInt32(KERNARIUM_RUNTIME_ANDROID_BOOT_AUTO)
        case .normal: UInt32(KERNARIUM_RUNTIME_ANDROID_BOOT_NORMAL)
        case .recovery: UInt32(KERNARIUM_RUNTIME_ANDROID_BOOT_RECOVERY)
        }
    }
}

nonisolated struct VirtualMachineConfig: Codable, Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    var name: String
    var systemImageID: UUID
    var guestMemoryMiB: Int
    var vcpuCount: Int
    var dataDiskGiB: Int
    var retinaDisplay: Bool
    var autoResizeDisplay: Bool
    var bootMode: VMBootMode
    var microphoneEnabled: Bool
    var adbOverLan: Bool
    var preferJitIfAvailable: Bool
    var softwareBackend: PreferredSoftwareBackend
    var afkFrameRateLimit: Int
    var afkBlackoutEnabled: Bool
    var createdAt: Date
    var lastRunAt: Date?
}

nonisolated enum VMStoreError: LocalizedError, Sendable {
    case cloneFailed(String)

    var errorDescription: String? {
        switch self {
        case .cloneFailed(let detail):
            return "Không thể nhân bản máy ảo: \(detail)"
        }
    }
}

nonisolated struct VMSessionDiagnostic: Equatable, Sendable {
    let title: String
    let message: String
    let suggestsSafeTune: Bool
    let isCrashOrJetsam: Bool
}

@MainActor
final class VirtualMachineStore: ObservableObject {
    static let shared = VirtualMachineStore()

    @Published private(set) var machines: [VirtualMachineConfig] = []

    private let rootURL: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.rootURL = docs.appendingPathComponent("Dynarium/VMs", isDirectory: true)
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        reload()
    }

    func vmDirectoryURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func configURL(for id: UUID) -> URL {
        vmDirectoryURL(for: id).appendingPathComponent("vm.json")
    }

    func dataDiskURL(for id: UUID) -> URL {
        vmDirectoryURL(for: id).appendingPathComponent("data.img")
    }

    func sessionRecordURL(for id: UUID) -> URL {
        vmDirectoryURL(for: id).appendingPathComponent("session.record")
    }

    func dataDiskExists(for id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: dataDiskURL(for: id).path)
    }

    func dataDiskAllocatedBytes(for id: UUID) -> UInt64 {
        let url = dataDiskURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        return UInt64(max(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0, 0))
    }

    func reload() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            machines = []
            return
        }
        var loaded: [VirtualMachineConfig] = []
        let decoder = JSONDecoder()
        for entry in entries {
            let jsonURL = entry.appendingPathComponent("vm.json")
            if let data = try? Data(contentsOf: jsonURL),
               let cfg = try? decoder.decode(VirtualMachineConfig.self, from: data) {
                loaded.append(cfg)
            }
        }
        machines = loaded.sorted {
            if let lRun = $0.lastRunAt, let rRun = $1.lastRunAt, lRun != rRun {
                return lRun > rRun
            }
            return $0.createdAt > $1.createdAt
        }
    }

    func makeDefaultConfig(name: String, systemImageID: UUID, hardware: HostHardwareProfile) -> VirtualMachineConfig {
        let vcpus = hardware.defaultVCPUs()
        let ram = hardware.safeRecommendedMemoryMiB(for: vcpus)
        return VirtualMachineConfig(
            id: UUID(),
            name: name,
            systemImageID: systemImageID,
            guestMemoryMiB: ram,
            vcpuCount: vcpus,
            dataDiskGiB: 16,
            retinaDisplay: hardware.defaultRetinaDisplay(),
            autoResizeDisplay: true,
            bootMode: .auto,
            microphoneEnabled: false,
            adbOverLan: false,
            preferJitIfAvailable: hardware.debuggerAttached,
            softwareBackend: .auto,
            afkFrameRateLimit: 10,
            afkBlackoutEnabled: true,
            createdAt: Date(),
            lastRunAt: nil
        )
    }

    @discardableResult
    func applySafeProfile(for id: UUID, hardware: HostHardwareProfile) -> VirtualMachineConfig? {
        guard var cfg = machines.first(where: { $0.id == id }) else { return nil }
        let safeVCPUs = hardware.defaultVCPUs()
        cfg.vcpuCount = safeVCPUs
        cfg.guestMemoryMiB = hardware.safeRecommendedMemoryMiB(for: safeVCPUs)
        cfg.retinaDisplay = hardware.defaultRetinaDisplay()
        cfg.softwareBackend = .auto
        cfg.preferJitIfAvailable = hardware.debuggerAttached
        save(cfg)
        try? FileManager.default.removeItem(at: sessionRecordURL(for: id))
        objectWillChange.send()
        return cfg
    }

    func clearSessionRecord(for id: UUID) {
        try? FileManager.default.removeItem(at: sessionRecordURL(for: id))
        objectWillChange.send()
    }

    func save(_ config: VirtualMachineConfig) {
        let dir = vmDirectoryURL(for: config.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(config) {
            try? data.write(to: configURL(for: config.id), options: .atomic)
        }
        if let idx = machines.firstIndex(where: { $0.id == config.id }) {
            machines[idx] = config
        } else {
            machines.insert(config, at: 0)
        }
    }

    func markLaunched(id: UUID) {
        guard var cfg = machines.first(where: { $0.id == id }) else { return }
        cfg.lastRunAt = Date()
        save(cfg)
    }

    func cloneVM(_ source: VirtualMachineConfig) async throws -> VirtualMachineConfig {
        let newID = UUID()
        let srcDir = vmDirectoryURL(for: source.id)
        let dstDir = vmDirectoryURL(for: newID)
        try FileManager.default.createDirectory(at: dstDir, withIntermediateDirectories: true)

        let srcData = srcDir.appendingPathComponent("data.img")
        let dstData = dstDir.appendingPathComponent("data.img")

        if FileManager.default.fileExists(atPath: srcData.path) {
            try await Task.detached(priority: .userInitiated) {
                let cloneErrno = dynarium_apfs_clonefile(srcData.path, dstData.path)
                if cloneErrno != 0 {
                    // Fallback to standard copy if APFS clonefile is unavailable across volumes.
                    try FileManager.default.copyItem(at: srcData, to: dstData)
                }
            }.value
        }

        let cloned = VirtualMachineConfig(
            id: newID,
            name: "\(source.name) (Bản sao)",
            systemImageID: source.systemImageID,
            guestMemoryMiB: source.guestMemoryMiB,
            vcpuCount: source.vcpuCount,
            dataDiskGiB: source.dataDiskGiB,
            retinaDisplay: source.retinaDisplay,
            autoResizeDisplay: source.autoResizeDisplay,
            bootMode: source.bootMode,
            microphoneEnabled: source.microphoneEnabled,
            adbOverLan: false,
            preferJitIfAvailable: source.preferJitIfAvailable,
            softwareBackend: source.softwareBackend,
            afkFrameRateLimit: source.afkFrameRateLimit,
            afkBlackoutEnabled: source.afkBlackoutEnabled,
            createdAt: Date(),
            lastRunAt: nil
        )
        save(cloned)
        return cloned
    }

    func wipeDataDisk(for id: UUID) {
        try? FileManager.default.removeItem(at: dataDiskURL(for: id))
        try? FileManager.default.removeItem(at: sessionRecordURL(for: id))
        objectWillChange.send()
    }

    func deleteVM(_ id: UUID) {
        AdbKeyStore.forVM(id).delete()
        try? FileManager.default.removeItem(at: vmDirectoryURL(for: id))
        machines.removeAll { $0.id == id }
    }

    func countVMsUsingImage(_ imageID: UUID) -> Int {
        machines.filter { $0.systemImageID == imageID }.count
    }

    func lastSessionDiagnostic(for id: UUID) -> VMSessionDiagnostic? {
        let url = sessionRecordURL(for: id)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return nil
        }

        let raw = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\0", with: "")
        let headerSection = raw.components(separatedBy: "\nkernel-output\n").first ?? raw
        let lines = headerSection
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var fields: [String: String] = [:]
        for line in lines {
            if let space = line.firstIndex(of: " ") {
                let key = String(line[..<space])
                let value = String(line[line.index(after: space)...]).trimmingCharacters(in: .whitespaces)
                if key == "memory" || key == "state" || key == "end" || key == "status" || key == "message" {
                    fields[key] = value
                }
            } else if line == "running" || line == "powered_off" || line == "powered-off" {
                fields["state"] = line
                fields["end"] = line
            }
        }

        var peakBytes: UInt64?
        var availableBytes: UInt64?
        if let memoryLine = fields["memory"] {
            let words = memoryLine.split(separator: " ")
            var values: [String: UInt64] = [:]
            var idx = 0
            while idx + 1 < words.count {
                if let val = UInt64(words[idx + 1]) {
                    values[String(words[idx])] = val
                }
                idx += 2
            }
            peakBytes = values["peak"] ?? values["footprint"]
            availableBytes = values["available"]
        }

        let state = fields["state"] ?? ""
        let end = fields["end"] ?? state
        let message = fields["message"]
        let status = fields["status"]
        let detail = (message?.isEmpty == false) ? ": \(message!)" : ""

        if state != "running" && ["powered-off", "powered_off", "restarted", "stopped"].contains(end) {
            return nil
        }

        if state == "running" || end == "running" {
            let peakText = peakBytes.map { " (đỉnh \(Formats.size(bytes: $0)))" } ?? ""
            if let avail = availableBytes, avail < (320 << 20) {
                return VMSessionDiagnostic(
                    title: "iOS đã đóng máy ảo (chạm trần RAM)",
                    message: "Phiên trước bị iOS thu hồi bộ nhớ\(peakText), chỉ còn \(Formats.size(bytes: avail)) trước trần. Hãy bấm Tối ưu an toàn.",
                    suggestsSafeTune: true,
                    isCrashOrJetsam: true
                )
            }
            return VMSessionDiagnostic(
                title: "Phiên trước bị đóng đột ngột",
                message: "Máy ảo dừng bất thường khi đang khởi chạy\(peakText). Hãy dùng Tối ưu an toàn để giữ RAM và CPU ổn định.",
                suggestsSafeTune: true,
                isCrashOrJetsam: true
            )
        }

        switch end {
        case "guest-panic":
            return VMSessionDiagnostic(
                title: "Nhân Linux Android gặp lỗi",
                message: "Hệ điều hành khách dừng với kernel panic\(detail).",
                suggestsSafeTune: false,
                isCrashOrJetsam: true
            )
        case "kernel-abort":
            return VMSessionDiagnostic(
                title: "Nhân Linux dừng bất thường",
                message: "Nhân máy ảo gặp sự cố trong lúc chạy\(detail).",
                suggestsSafeTune: true,
                isCrashOrJetsam: true
            )
        case "kernel-exit":
            let codeText = status.map { " (mã \($0))" } ?? ""
            return VMSessionDiagnostic(
                title: "Android dừng ngoài ý muốn",
                message: "Nhân hệ điều hành khách đã thoát\(codeText)\(detail).",
                suggestsSafeTune: false,
                isCrashOrJetsam: true
            )
        case "hibernation-restore-failed":
            return VMSessionDiagnostic(
                title: "Cần khởi động lại từ đầu",
                message: "Không thể khôi phục bộ nhớ ngủ đông của phiên trước; lần bật tới sẽ khởi động mới.",
                suggestsSafeTune: false,
                isCrashOrJetsam: false
            )
        case "host-fault", "process-exit":
            return VMSessionDiagnostic(
                title: "Ứng dụng dừng khi máy ảo đang chạy",
                message: "Tiến trình Dynarium gặp sự cố đột ngột\(detail). Khuyên dùng Tối ưu an toàn trước khi chạy lại.",
                suggestsSafeTune: true,
                isCrashOrJetsam: true
            )
        case "":
            return nil
        default:
            return VMSessionDiagnostic(
                title: "Phiên trước kết thúc bất thường",
                message: "Máy ảo chưa tắt hoàn chỉnh\(detail). Nên kiểm tra lại cấu hình trước khi khởi chạy.",
                suggestsSafeTune: true,
                isCrashOrJetsam: false
            )
        }
    }

    func lastSessionSummary(for id: UUID) -> String? {
        lastSessionDiagnostic(for: id)?.message
    }
}
