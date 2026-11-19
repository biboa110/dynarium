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
        let ram = hardware.recommendedMemoryMiB(for: vcpus)
        return VirtualMachineConfig(
            id: UUID(),
            name: name,
            systemImageID: systemImageID,
            guestMemoryMiB: ram,
            vcpuCount: vcpus,
            dataDiskGiB: 16,
            retinaDisplay: true,
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

    func lastSessionSummary(for id: UUID) -> String? {
        let url = sessionRecordURL(for: id)
        guard let data = try? Data(contentsOf: url), data.count > 4096 else {
            return nil
        }
        // Session summary follows the 4096-byte memory checkpoint slot (session_record.hpp).
        let text = String(decoding: data.dropFirst(4096), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text == "running" {
            return "Phiên trước bị đóng đột ngột (hoặc hệ thống thu hồi RAM)."
        }
        if text == "powered_off" {
            return nil
        }
        return text
    }
}
