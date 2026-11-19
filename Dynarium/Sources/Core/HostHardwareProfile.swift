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

    var badgeShortTitle: String {
        switch self {
        case .universalSoftware: "Universal"
        case .metal4Vulkan: "Metal 4"
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

nonisolated struct LaunchSafetyAssessment: Equatable, Sendable {
    let needsOptimization: Bool
    let suggestedVCPUs: Int
    let suggestedMemoryMiB: Int
    let suggestedRetina: Bool
    let reason: String?
}

@MainActor
final class HostHardwareProfile: ObservableObject {
    static let shared = HostHardwareProfile()

    let machineIdentifier: String
    let deviceKindName: String
    let osVersionString: String
    let osMajorVersion: Int
    let isRunningOnMac: Bool
    let metalDeviceName: String
    let supportsMetal4Hardware: Bool
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

    static func configureProcessEnvironmentBeforeFirstUse() {
        let hasKosmicKrisp: Bool = {
            guard let frameworksURL = Bundle.main.privateFrameworksURL else { return false }
            return FileManager.default.fileExists(
                atPath: frameworksURL.appendingPathComponent("KosmicKrisp.framework").path
            )
        }()

        if hasKosmicKrisp {
            setenv("MESA_LOADER_DRIVER_OVERRIDE", "zink", 1)
            return
        }

        // Trim idle Mesa software GL contexts frequently so textures/buffers do not accumulate in CPU RAM.
        setenv("UML_GPU_IDLE_TRIM_MS", "250", 1)
        setenv("LIBGL_ALWAYS_SOFTWARE", "true", 1)
        #if targetEnvironment(simulator)
        setenv("GALLIUM_DRIVER", "llvmpipe", 1)
        setenv("DRAW_USE_LLVM", "1", 1)
        #else
        if kernarium_runtime_loader_debugger_attached() != 0 {
            setenv("GALLIUM_DRIVER", "llvmpipe", 1)
            setenv("DRAW_USE_LLVM", "1", 1)
        } else {
            setenv("GALLIUM_DRIVER", "softpipe", 1)
            setenv("DRAW_USE_LLVM", "0", 1)
        }
        #endif
    }

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
        self.osMajorVersion = os.majorVersion
        self.osVersionString = os.patchVersion > 0
            ? "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
            : "\(os.majorVersion).\(os.minorVersion)"

        let mtlDevice = MTLCreateSystemDefaultDevice()
        self.metalDeviceName = mtlDevice?.name ?? "Apple GPU"
        self.supportsMetal4Hardware = mtlDevice?.supportsFamily(.apple7) ?? false
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
        self.appVersionString = (info?["CFBundleShortVersionString"] as? String) ?? "1.1.0"
        self.buildNumberString = (info?["CFBundleVersion"] as? String) ?? "2"

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
        if m.hasPrefix("iPhone18,") { return "Apple A19 / A19 Pro" }
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

    var recommendsMetal4Edition: Bool {
        edition == .universalSoftware && osMajorVersion >= 26 && supportsMetal4Hardware
    }

    var isMemoryEntitlementLimited: Bool {
        !isRunningOnMac && availableProcessMemoryBytes > 0 && availableProcessMemoryBytes < 2_500 * Bytes.mib
    }

    private var effectiveMemoryLimitMiB: Int {
        guard !isRunningOnMac else { return 0 }
        let budgetLimit = evaluateGpuBudget(memoryMiB: 1024, vcpus: 2).processLimitMiB
        if budgetLimit > 0 { return budgetLimit }
        return Int(availableProcessMemoryBytes / Bytes.mib)
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

    func defaultRetinaDisplay() -> Bool {
        guard edition == .metal4Vulkan else {
            // CPU software rasterization uses ~9x more RAM & CPU at 3x Retina scale.
            return false
        }
        let limitMiB = effectiveMemoryLimitMiB
        return limitMiB == 0 || limitMiB >= 3200
    }

    func defaultVCPUs() -> Int {
        let limitMiB = effectiveMemoryLimitMiB
        if edition == .universalSoftware || (limitMiB > 0 && limitMiB < 3000) {
            return min(2, maxVCPUs)
        }
        return min(max(2, maxVCPUs / 2), maxVCPUs)
    }

    func recommendedMemoryMiB(for vcpus: Int) -> Int {
        safeRecommendedMemoryMiB(for: vcpus)
    }

    func safeRecommendedMemoryMiB(for vcpus: Int) -> Int {
        let clampedVCPUs = min(max(1, vcpus), maxVCPUs)
        let minAllowed = minimumMemoryMiB()
        let maxAllowed = max(minAllowed, maximumMemoryMiB(vcpus: clampedVCPUs))
        let runtimeDefault = min(max(minAllowed, defaultMemoryMiB(vcpus: clampedVCPUs)), maxAllowed)
        let limitMiB = effectiveMemoryLimitMiB
        guard limitMiB > 0 else { return runtimeDefault }

        let target: Int
        if limitMiB < 2000 {
            target = (edition == .universalSoftware && limitMiB < 1850) ? 640 : 768
        } else if limitMiB < 2600 {
            target = edition == .universalSoftware ? 768 : 1024
        } else if limitMiB < 3000 {
            target = edition == .universalSoftware ? 1024 : 1280
        } else if limitMiB < 3800 {
            target = min(1536, runtimeDefault)
        } else {
            target = runtimeDefault
        }

        let stepped = ((target + 32) / 64) * 64
        return min(max(stepped, minAllowed), max(minAllowed, min(maxAllowed, runtimeDefault)))
    }

    func evaluateLaunchSafety(for vm: VirtualMachineConfig) -> LaunchSafetyAssessment {
        let suggestedVCPUs = defaultVCPUs()
        let suggestedMemoryMiB = safeRecommendedMemoryMiB(for: suggestedVCPUs)
        let suggestedRetina = defaultRetinaDisplay()
        let limitMiB = effectiveMemoryLimitMiB

        guard limitMiB > 0 else {
            return LaunchSafetyAssessment(
                needsOptimization: false,
                suggestedVCPUs: suggestedVCPUs,
                suggestedMemoryMiB: suggestedMemoryMiB,
                suggestedRetina: suggestedRetina,
                reason: nil
            )
        }

        let baseOverhead = edition == .universalSoftware ? 420 : 280
        let vcpuOverhead = vm.vcpuCount * 80
        let displayOverhead = vm.retinaDisplay
            ? (edition == .universalSoftware ? 320 : 140)
            : 120
        let estimatedTotalMiB = vm.guestMemoryMiB + baseOverhead + vcpuOverhead + displayOverhead
        let safeCeilingMiB = max(768, limitMiB - 300)
        let riskyRetinaOnLowLimit = edition == .universalSoftware && vm.retinaDisplay && limitMiB < 3200
        let exceedsUniversalSafeTarget = (edition == .universalSoftware && limitMiB < 2600 && vm.guestMemoryMiB > suggestedMemoryMiB)
        let budget = evaluateGpuBudget(memoryMiB: vm.guestMemoryMiB, vcpus: vm.vcpuCount)

        if estimatedTotalMiB > safeCeilingMiB || budget.shortOfFloor || riskyRetinaOnLowLimit || exceedsUniversalSafeTarget {
            let retinaNote = vm.retinaDisplay ? ", Retina" : ""
            let reason = "Cấu hình hiện tại (\(vm.vcpuCount) vCPU, \(Formats.size(mib: vm.guestMemoryMiB))\(retinaNote)) dễ chạm trần RAM \(Formats.size(mib: limitMiB)) trên thiết bị này. Đề xuất hạ về \(suggestedVCPUs) vCPU, \(Formats.size(mib: suggestedMemoryMiB)) và tắt Retina để chạy ổn định."
            return LaunchSafetyAssessment(
                needsOptimization: true,
                suggestedVCPUs: suggestedVCPUs,
                suggestedMemoryMiB: suggestedMemoryMiB,
                suggestedRetina: suggestedRetina,
                reason: reason
            )
        }

        return LaunchSafetyAssessment(
            needsOptimization: false,
            suggestedVCPUs: suggestedVCPUs,
            suggestedMemoryMiB: suggestedMemoryMiB,
            suggestedRetina: suggestedRetina,
            reason: nil
        )
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
