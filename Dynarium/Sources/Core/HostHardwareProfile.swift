// SPDX-License-Identifier: GPL-2.0-or-later

import Combine
import Darwin
import Foundation
import GuestHostCore
import Metal
import UIKit

nonisolated enum DynariumEdition: String, Sendable {
    case universalSoftware
    case metal4Vulkan

    var badgeTitle: String {
        switch self {
        case .universalSoftware: "Universal iOS 16+"
        case .metal4Vulkan: "Metal 4 iOS 26+"
        }
    }

    var descriptionText: String {
        switch self {
        case .universalSoftware:
            "Phiên bản Phổ thông (iOS 16.0–27+): chạy ổn định bằng Mesa softpipe/llvmpipe trên mọi chip Apple Silicon."
        case .metal4Vulkan:
            "Phiên bản Metal 4 (iOS 26.0+): tăng tốc phần cứng Vulkan 1.4 / GLES 3.2 qua KosmicKrisp + Zink."
        }
    }
}

nonisolated enum PreferredSoftwareBackend: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case softpipe
    case llvmpipe

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: "Tự động (An toàn)"
        case .softpipe: "Softpipe (Không cần JIT)"
        case .llvmpipe: "LLVMpipe (Chỉ khi bật JIT)"
        }
    }

    var subtitle: String {
        switch self {
        case .auto: "Dùng softpipe khi không có JIT; tự nâng lên llvmpipe khi phát hiện JIT/Simulator."
        case .softpipe: "Thuần CPU interpreter, tương thích mọi thiết bị sideload chưa kích hoạt JIT."
        case .llvmpipe: "Nhanh hơn cho CPU rendering nhưng yêu cầu quyền JIT hoặc trình gỡ lỗi đang gắn."
        }
    }
}

nonisolated struct GpuBudgetEvaluation: Equatable, Sendable {
    let budgetBytes: UInt64
    let processLimitBytes: UInt64
    let availableBytes: UInt64
    let guestMemoryBytes: UInt64
    let engineBytes: UInt64
    let applicationBytes: UInt64
    let headroomBytes: UInt64
    let shortOfFloor: Bool

    var budgetMiB: Int { Int(budgetBytes / Bytes.mib) }
    var processLimitMiB: Int { Int(processLimitBytes / Bytes.mib) }
}

@MainActor
final class HostHardwareProfile: ObservableObject {
    static let shared = HostHardwareProfile()

    let machineIdentifier: String
    let deviceKindName: String
    let osVersionString: String
    let isRunningOnMac: Bool
    let metalDeviceName: String
    let physicalMemoryBytes: UInt64
    let physicalProcessorCount: Int
    let maxVCPUs: Int
    let guestMemoryCeilingMiB: Int
    let edition: DynariumEdition
    let appVersionString: String
    let buildNumberString: String

    @Published private(set) var availableProcessMemoryBytes: UInt64 = 0
    @Published private(set) var hostFreeDiskBytes: UInt64 = 0
    @Published private(set) var debuggerAttached: Bool = false

    private init() {
        var uts = utsname()
        uname(&uts)
        let machine = withUnsafePointer(to: &uts.machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { cStr in
                String(cString: cStr)
            }
        }
        self.machineIdentifier = machine

        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let isMac = ProcessInfo.processInfo.isiOSAppOnMac
        self.isRunningOnMac = isMac
        self.deviceKindName = isMac ? "Mac" : (isPad ? "iPad" : "iPhone")

        let os = ProcessInfo.processInfo.operatingSystemVersion
        self.osVersionString = os.patchVersion > 0
            ? "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
            : "\(os.majorVersion).\(os.minorVersion)"

        self.metalDeviceName = MTLCreateSystemDefaultDevice()?.name ?? "Apple GPU"
        self.physicalMemoryBytes = ProcessInfo.processInfo.physicalMemory

        let cores = max(ProcessInfo.processInfo.processorCount, 1)
        self.physicalProcessorCount = cores
        self.maxVCPUs = max(1, GuestProcessorLimit.vCPUs(physicalProcessorCount: cores))
        self.guestMemoryCeilingMiB = max(512, Int(kernarium_runtime_loader_guest_memory_ceiling_mib()))

        if let frameworksURL = Bundle.main.privateFrameworksURL,
           FileManager.default.fileExists(
               atPath: frameworksURL.appendingPathComponent("KosmicKrisp.framework").path
           ) {
            self.edition = .metal4Vulkan
        } else {
            self.edition = .universalSoftware
        }

        let info = Bundle.main.infoDictionary
        self.appVersionString = (info?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
        self.buildNumberString = (info?["CFBundleVersion"] as? String) ?? "1"

        refreshDynamicMetrics()
    }

    func refreshDynamicMetrics() {
        availableProcessMemoryBytes = dynarium_available_memory_bytes()
        hostFreeDiskBytes = HostStorage.freeBytes()
        debuggerAttached = kernarium_runtime_loader_debugger_attached() != 0
    }

    var chipGenerationLabel: String {
        if isRunningOnMac { return "Apple Silicon (Mac)" }
        let m = machineIdentifier
        if m.hasPrefix("iPhone17,") { return "Apple A18 / A18 Pro" }
        if m.hasPrefix("iPhone16,") { return "Apple A17 Pro" }
        if m.hasPrefix("iPhone15,") { return "Apple A16 Bionic" }
        if m.hasPrefix("iPhone14,") { return "Apple A15 Bionic" }
        if m.hasPrefix("iPhone13,") { return "Apple A14 Bionic" }
        if m.hasPrefix("iPhone12,") { return "Apple A13 Bionic" }
        if m.hasPrefix("iPhone11,") { return "Apple A12 Bionic" }
        if m.hasPrefix("iPad16,") { return "Apple M4" }
        if m.hasPrefix("iPad14,") { return "Apple M2" }
        if m.hasPrefix("iPad13,") { return "Apple M1" }
        return "\(metalDeviceName) (\(m))"
    }

    func minimumMemoryMiB() -> Int { 512 }

    func maximumMemoryMiB(vcpus: Int) -> Int {
        let params = kernarium_runtime_loader_maximum_memory_set()
        let raw = Int(kernarium_runtime_loader_maximum_guest_memory_mib(UInt32(max(1, vcpus)), params))
        return max(512, raw)
    }

    func conservativeMemoryMiB(vcpus: Int) -> Int {
        let params = kernarium_runtime_loader_launch_memory_set()
        let raw = Int(kernarium_runtime_loader_conservative_guest_memory_mib(UInt32(max(1, vcpus)), params))
        return max(512, raw)
    }

    func defaultMemoryMiB(vcpus: Int) -> Int {
        let params = kernarium_runtime_loader_launch_memory_set()
        let raw = Int(kernarium_runtime_loader_default_guest_memory_mib(UInt32(max(1, vcpus)), params))
        return max(512, raw)
    }

    func evaluateGpuBudget(memoryMiB: Int, vcpus: Int) -> GpuBudgetEvaluation {
        let params = kernarium_runtime_loader_launch_memory_set()
        var plan = kernarium_runtime_gpu_budget()
        plan.struct_size = UInt32(MemoryLayout<kernarium_runtime_gpu_budget>.size)
        let rc = kernarium_runtime_loader_plan_gpu_budget(
            UInt32(max(512, memoryMiB)),
            UInt32(max(1, vcpus)),
            params.application_mib,
            params.engine_mib,
            params.headroom_mib,
            &plan
        )
        if rc != 0 {
            let fallbackMiB = UInt64(
                kernarium_runtime_loader_gpu_budget_mib(
                    UInt32(max(512, memoryMiB)),
                    UInt32(max(1, vcpus)),
                    params
                )
            ) * Bytes.mib
            return GpuBudgetEvaluation(
                budgetBytes: fallbackMiB,
                processLimitBytes: 0,
                availableBytes: fallbackMiB,
                guestMemoryBytes: UInt64(memoryMiB) * Bytes.mib,
                engineBytes: 0,
                applicationBytes: 0,
                headroomBytes: 0,
                shortOfFloor: false
            )
        }
        return GpuBudgetEvaluation(
            budgetBytes: plan.budget_bytes,
            processLimitBytes: plan.process_limit_bytes,
            availableBytes: plan.available_bytes,
            guestMemoryBytes: plan.guest_memory_bytes,
            engineBytes: plan.engine_bytes,
            applicationBytes: plan.application_bytes,
            headroomBytes: plan.headroom_bytes,
            shortOfFloor: plan.short_of_floor != 0
        )
    }

    func defaultVCPUs() -> Int {
        min(max(2, maxVCPUs / 2), maxVCPUs)
    }

    func recommendedMemoryMiB(for vcpus: Int) -> Int {
        let clampedVCPUs = min(max(1, vcpus), maxVCPUs)
        let def = defaultMemoryMiB(vcpus: clampedVCPUs)
        let maxAllowed = maximumMemoryMiB(vcpus: clampedVCPUs)
        return min(max(512, def), maxAllowed)
    }

    func resolvedGalliumDriver(preference: PreferredSoftwareBackend, jitActive: Bool) -> String {
        switch preference {
        case .softpipe:
            return "softpipe"
        case .llvmpipe:
            return "llvmpipe"
        case .auto:
            #if targetEnvironment(simulator)
            return "llvmpipe"
            #else
            return (jitActive || debuggerAttached) ? "llvmpipe" : "softpipe"
            #endif
        }
    }
}
