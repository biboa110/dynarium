// SPDX-License-Identifier: GPL-2.0-or-later

import Combine
import Darwin
import Foundation
import GuestHostCore
import MetalKit
import SwiftUI
import UIKit

nonisolated enum VMSessionPhase: Equatable, Sendable {
    case idle
    case booting(vmName: String)
    case running(vmName: String)
    case restarting(vmName: String, count: Int)
    case stopping(vmName: String)
    case ended(vmName: String, exitCode: Int32, note: String?)

    var isActive: Bool {
        switch self {
        case .booting, .running, .restarting, .stopping: true
        default: false
        }
    }

    var isPresented: Bool {
        switch self {
        case .idle: false
        default: true
        }
    }
}

nonisolated enum BootStage: Int, Comparable, Sendable {
    case preparing = 0
    case kernelBooting = 1
    case formattingOrInit = 2
    case startingGraphics = 3
    case ready = 4

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

nonisolated struct VMTelemetrySnapshot: Equatable, Sendable {
    var cpuUtilizationPercent: Double = 0
    var activeVCPUs: Int = 0
    var guestRamTotalBytes: UInt64 = 0
    var guestRamHeldBytes: UInt64 = 0
    var gpuBudgetBytes: UInt64 = 0
    var gpuUsedBytes: UInt64 = 0
    var gpuRefusals: UInt64 = 0
    var fps: Double = 0
    var displayActive: Bool = false
    var guestAndroidVersion: String?
}

private nonisolated struct UncheckedViewBox: @unchecked Sendable {
    let view: GuestMetalView
}

private nonisolated final class ConsoleLogBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var milestoneScratch = ""
    private var dirty = false
    private let limitBytes = 64 * 1024

    func reset() {
        lock.withLock {
            text = ""
            milestoneScratch = ""
            dirty = false
        }
    }

    func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        lock.withLock {
            text.append(chunk)
            if text.utf8.count > limitBytes {
                let trimStart = text.index(text.endIndex, offsetBy: -48_000, limitedBy: text.startIndex) ?? text.startIndex
                text = String(text[trimStart...])
            }
            milestoneScratch.append(chunk)
            if milestoneScratch.utf8.count > 16_384 {
                let cut = milestoneScratch.index(milestoneScratch.endIndex, offsetBy: -8_192, limitedBy: milestoneScratch.startIndex) ?? milestoneScratch.startIndex
                milestoneScratch = String(milestoneScratch[cut...])
            }
            dirty = true
        }
    }

    func drain(needText: Bool, needMilestones: Bool) -> (lines: [String], partialLine: String, textSnapshot: String?) {
        lock.withLock {
            var lines: [String] = []
            var partial = ""
            if needMilestones {
                while let newlineIdx = milestoneScratch.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                    let line = String(milestoneScratch[..<newlineIdx])
                    milestoneScratch.removeSubrange(...newlineIdx)
                    if !line.isEmpty { lines.append(line) }
                }
                if milestoneScratch.utf8.count > 4096 {
                    milestoneScratch.removeAll(keepingCapacity: true)
                } else {
                    partial = milestoneScratch
                }
            } else if !milestoneScratch.isEmpty {
                milestoneScratch.removeAll(keepingCapacity: false)
            }
            let snapshot: String? = (needText && dirty) ? text : nil
            if snapshot != nil {
                dirty = false
            }
            return (lines, partial, snapshot)
        }
    }

    func snapshotAll() -> String {
        lock.withLock {
            dirty = false
            return text
        }
    }
}

@MainActor
final class VMRuntimeSession: ObservableObject, SpacePauseEffects {
    static let shared = VMRuntimeSession()

    @Published private(set) var phase: VMSessionPhase = .idle
    @Published private(set) var activeVM: VirtualMachineConfig?
    @Published private(set) var telemetry = VMTelemetrySnapshot()
    @Published private(set) var consoleText: String = ""
    @Published private(set) var bootStage: BootStage = .preparing
    @Published private(set) var bootStartedAt: Date = Date()
    @Published var bootOverlayDismissed: Bool = false
    @Published private(set) var isFirstBootSession: Bool = false
    @Published private(set) var spacePause: SpacePause?
    @Published var startSpaceShortage: StartSpace?
    @Published private(set) var afkEcoMode: Bool = false
    @Published private(set) var oledBlackoutActive: Bool = false
    @Published private(set) var jitActiveInSession: Bool = false
    @Published private(set) var coolModeEnabled: Bool = false
    @Published private(set) var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    @Published private(set) var thermalAutoThrottleActive: Bool = false
    @Published private(set) var microphoneOn: Bool = false
    @Published private(set) var adbLanAddress: String?
    @Published var keyboardVisible: Bool = false
    @Published var errorBannerMessage: String?
    @Published private(set) var processRequiresRestart: Bool = false
    @Published private(set) var shutdownStatusDetail: String?

    var shouldShowBootOverlay: Bool {
        guard phase.isActive, bootStage != .ready, !bootOverlayDismissed else { return false }
        if bootStage >= .startingGraphics && telemetry.displayActive && framesSinceGraphics >= 8 {
            return false
        }
        return true
    }

    let installer = ApkInstaller()
    let pipController = DynariumPiPController()
    let adbClock = AdbRunClock()

    private let hardware = HostHardwareProfile.shared
    private let vmStore = VirtualMachineStore.shared
    private let imageStore = SystemImageStore.shared
    private let runtimeQueue = DispatchQueue(label: "com.dynarium.runtime.lifecycle", qos: .userInitiated)
    private let consoleBuffer = ConsoleLogBuffer()

    private var activeImage: SystemImageManifest?
    private var activeMetalView: GuestMetalView?
    private var initialGeometry: GuestDisplayGeometry?
    private var bootLaunchedForSession = false
    private var brandingAppliedForSession = false
    private var isConsoleSheetVisible = false
    private var usedHardForceStop = false
    private var runtimeThread: Thread?
    private var thermalObserver: NSObjectProtocol?
    private var lastAppliedThrottleState: Bool?
    private var lastAppliedPageTrimState: Bool?
    private var statsTimer: Task<Void, Never>?
    private var spaceCheckTask: Task<Void, Never>?
    private var consoleFlushTask: Task<Void, Never>?
    private var brandingTask: Task<Void, Never>?
    private var spacePauser: SpacePauser?
    private var networkBridge: AdbNetworkBridge?
    private var micPermission = SystemMicrophonePermission()
    private var prevStatsTimestampNs: UInt64 = 0
    private var prevProcessorTimeNs: UInt64 = 0
    private var prevPresentedFrames: UInt64 = 0
    private var framesSinceGraphics: UInt64 = 0
    private var prevBootIndex: UInt32 = 0
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var isInBackground = false

    /// Host memory pressure as the app sees it: os_proc_available_memory()
    /// against the jetsam line, plus UIKit's memory warnings.
    private nonisolated enum LowMemoryLevel: Int, Comparable, Sendable {
        case normal = 0
        case warning = 1
        case critical = 2

        static func < (lhs: LowMemoryLevel, rhs: LowMemoryLevel) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    private var lowMemoryLevel: LowMemoryLevel = .normal
    private var lowMemoryCriticalStreak = 0
    private var memoryWarningObserver: NSObjectProtocol?

    private init() {
        spacePauser = SpacePauser(effects: self)
        pipController.setStateHandler { [weak self] _ in
            self?.applyRuntimeResourcePolicies()
        }
    }

    // MARK: - Launch Lifecycle

    func start(vm requestedVM: VirtualMachineConfig, image: SystemImageManifest) {
        guard !phase.isActive else { return }
        startSpaceShortage = nil
        errorBannerMessage = nil

        hardware.refreshDynamicMetrics()
        let vm = hardware.lowMemorySafeConfiguration(for: requestedVM)
        let isFirstBoot = !vmStore.dataDiskExists(for: vm.id)
        let freeBytes = HostStorage.freeBytes()
        if freeBytes > 0, let shortage = StartSpace(freeBytes: freeBytes, firstStart: isFirstBoot) {
            startSpaceShortage = shortage
            return
        }

        isFirstBootSession = isFirstBoot
        activeVM = vm
        activeImage = image
        telemetry = VMTelemetrySnapshot()
        consoleBuffer.reset()
        consoleText = ""
        if vm != requestedVM {
            consoleBuffer.append(
                "[Dynarium] Low-memory host profile: \(vm.vcpuCount) vCPU, \(vm.guestMemoryMiB) MiB RAM, 720p @ 60 Hz "
                    + "(requested \(requestedVM.vcpuCount) vCPU, \(requestedVM.guestMemoryMiB) MiB)\n"
            )
        }
        lowMemoryLevel = .normal
        lowMemoryCriticalStreak = 0
        shutdownStatusDetail = nil
        usedHardForceStop = false
        bootStage = .preparing
        bootStartedAt = Date()
        bootOverlayDismissed = false
        spacePause = nil
        afkEcoMode = false
        oledBlackoutActive = false
        jitActiveInSession = false
        coolModeEnabled = vm.thermalSaverEnabled
        thermalState = ProcessInfo.processInfo.thermalState
        thermalAutoThrottleActive = (thermalState == .critical)
        lastAppliedThrottleState = nil
        lastAppliedPageTrimState = nil
        keyboardVisible = false
        bootLaunchedForSession = false
        brandingAppliedForSession = false
        initialGeometry = nil
        prevStatsTimestampNs = 0
        prevProcessorTimeNs = 0
        prevPresentedFrames = 0
        framesSinceGraphics = 0
        prevBootIndex = 0
        adbClock.setPaused(false)
        vmStore.markLaunched(id: vm.id)
        phase = .booting(vmName: vm.name)
    }

    func handleDisplayLayout(view: GuestMetalView, geometry: GuestDisplayGeometry) {
        activeMetalView = view
        guard !bootLaunchedForSession, let vm = activeVM, let image = activeImage else { return }
        initialGeometry = geometry
        bootLaunchedForSession = true
        launchRuntime(view: view, geometry: geometry, vm: vm, image: image)
    }

    private func launchRuntime(
        view: GuestMetalView,
        geometry: GuestDisplayGeometry,
        vm: VirtualMachineConfig,
        image: SystemImageManifest
    ) {
        let releasePath = imageStore.releaseURL(for: image).path
        let dataDiskPath = vmStore.dataDiskURL(for: vm.id).path
        let sessionRecordPath = vmStore.sessionRecordURL(for: vm.id).path
        let params = kernarium_runtime_loader_launch_memory_set()
        let appBudgetMiB = params.application_mib
        let engineBudgetMiB = params.engine_mib
        let headroomBudgetMiB = params.headroom_mib

        let boundedSize = GuestInputCoordinateSpace.boundedDisplaySize(geometry.pixelSize)
        let width = UInt32(max(1, Int(boundedSize.width.rounded(.down))))
        let height = UInt32(max(1, Int(boundedSize.height.rounded(.down))))
        let dpi = max(120, geometry.dotsPerInch)
        let timeZoneName = TimeZone.current.identifier
        let isUniversal = hardware.edition == .universalSoftware

        // Configure display target refresh rate, preload policy & safe software driver before selecting runtime.
        let displayHz = min(max(vm.targetDisplayFPS, 60), hardware.maxDisplayRefreshRate)
        setenv("UML_DISPLAY_REFRESH_HZ", String(displayHz), 1)
        setenv("DYNARIUM_RENDERER_PRELOAD", (vm.preloadRenderer && !isUniversal) ? "1" : "0", 1)

        if isUniversal {
            #if targetEnvironment(simulator)
            let preDriver = "llvmpipe"
            #else
            // Keep physical devices on softpipe until prepare_jit confirms executable JIT pages.
            let preDriver = HostHardwareProfile.resolveGalliumDriver(preference: vm.softwareBackend, jitActive: false)
            #endif
            setenv("GALLIUM_DRIVER", preDriver, 1)
            setenv("DRAW_USE_LLVM", preDriver == "llvmpipe" ? "1" : "0", 1)
        }

        let selectRC = kernarium_runtime_loader_select(UInt32(KERNARIUM_RUNTIME_GUEST_ANDROID))
        guard selectRC == 0 else {
            runtimeDidExit(code: selectRC, message: L10n.f("session.error.framework_select", String(selectRC)))
            return
        }

        let bufferRef = consoleBuffer
        kernarium_runtime_loader_set_console_output_handler { data in
            let text = String(decoding: data, as: UTF8.self)
            bufferRef.append(text)
        }

        kernarium_runtime_loader_set_restart_handler { [weak self] rawEvent, restartCount in
            guard let event = GuestRestartEvent(event: rawEvent, restartCount: restartCount) else { return }
            Task { @MainActor [weak self] in
                guard let self, let currentName = self.activeVM?.name else { return }
                switch event {
                case .began(let count):
                    self.bootStage = .preparing
                    self.bootStartedAt = Date()
                    self.bootOverlayDismissed = false
                    self.framesSinceGraphics = 0
                    self.brandingAppliedForSession = false
                    self.phase = .restarting(vmName: currentName, count: count)
                case .booted:
                    if case .restarting = self.phase {
                        self.phase = .running(vmName: currentName)
                    }
                    self.lastAppliedThrottleState = nil
                    self.lastAppliedPageTrimState = nil
                    self.applyRuntimeResourcePolicies()
                }
            }
        }

        view.setGuestDisplay(width: width, height: height)
        UIApplication.shared.isIdleTimerDisabled = true

        if let existingObserver = thermalObserver {
            NotificationCenter.default.removeObserver(existingObserver)
        }
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.thermalState = ProcessInfo.processInfo.thermalState
                self.applyRuntimeResourcePolicies()
            }
        }

        if case .booting(let name) = phase {
            phase = .running(vmName: name)
        }
        if vm.microphoneEnabled {
            setMicrophone(enabled: true)
        }
        if vm.adbOverLan {
            setAdbOverLan(enabled: true)
        }
        startMonitoringLoops()
        applyRuntimeResourcePolicies()

        let metalViewBox = UncheckedViewBox(view: view)
        // Occupies a dedicated 8 MiB stack Thread rather than Swift's 512 KiB cooperative pool.
        let worker = Thread { [weak self] in
            let identity = try? AdbKeyStore.forVM(vm.id).loadOrCreate()
            let adbPubKey = identity?.publicKeyLine

            var useJitFlag: UInt32 = 0
            if vm.preferJitIfAvailable {
                let jitStatus = kernarium_runtime_loader_prepare_jit(
                    1,
                    UInt32(vm.guestMemoryMiB),
                    UInt32(vm.vcpuCount)
                )
                if jitStatus == KERNARIUM_RUNTIME_JIT_READY {
                    useJitFlag = 1
                }
            }

            let jitEnabledNow = (useJitFlag != 0)
            if isUniversal {
                #if targetEnvironment(simulator)
                let finalDriver = "llvmpipe"
                #else
                let finalDriver = HostHardwareProfile.resolveGalliumDriver(
                    preference: vm.softwareBackend,
                    jitActive: jitEnabledNow
                )
                #endif
                setenv("GALLIUM_DRIVER", finalDriver, 1)
                setenv("DRAW_USE_LLVM", finalDriver == "llvmpipe" ? "1" : "0", 1)
            }
            Task { @MainActor [weak self] in
                self?.jitActiveInSession = jitEnabledNow
            }

            let exitCode = Self.executeGuestRuntime(
                view: metalViewBox.view,
                releasePath: releasePath,
                dataDiskPath: dataDiskPath,
                sessionRecordPath: sessionRecordPath,
                adbPubKey: adbPubKey,
                timeZoneName: timeZoneName,
                width: width,
                height: height,
                dpi: dpi,
                vm: vm,
                appBudgetMiB: appBudgetMiB,
                engineBudgetMiB: engineBudgetMiB,
                headroomBudgetMiB: headroomBudgetMiB,
                useJitFlag: useJitFlag
            )

            Task { @MainActor [weak self] in
                self?.runtimeDidExit(code: exitCode, message: nil)
            }
        }
        worker.name = "dynarium-runtime"
        worker.qualityOfService = .userInitiated
        worker.stackSize = 8 * 1024 * 1024
        runtimeThread = worker
        worker.start()
    }

    nonisolated private static func executeGuestRuntime(
        view: GuestMetalView,
        releasePath: String,
        dataDiskPath: String,
        sessionRecordPath: String,
        adbPubKey: String?,
        timeZoneName: String,
        width: UInt32,
        height: UInt32,
        dpi: UInt32,
        vm: VirtualMachineConfig,
        appBudgetMiB: UInt32,
        engineBudgetMiB: UInt32,
        headroomBudgetMiB: UInt32,
        useJitFlag: UInt32
    ) -> Int32 {
        withOptionalCString(adbPubKey) { adbPtr in
            releasePath.withCString { releasePtr in
                dataDiskPath.withCString { dataPtr in
                    sessionRecordPath.withCString { recPtr in
                        timeZoneName.withCString { tzPtr in
                            var boot = kernarium_runtime_boot()
                            boot.struct_size = UInt32(MemoryLayout<kernarium_runtime_boot>.size)
                            boot.width = width
                            boot.height = height
                            boot.dots_per_inch = dpi
                            boot.guest_memory_mib = UInt32(vm.guestMemoryMiB)
                            boot.guest_processor_count = UInt32(vm.vcpuCount)
                            boot.android_boot_mode = vm.bootMode.runtimeValue
                            boot.auto_resize_guest = vm.autoResizeDisplay ? 1 : 0
                            boot.android_data_disk_path = dataPtr
                            boot.android_release_path = releasePtr
                            boot.android_data_gib = UInt32(vm.dataDiskGiB)
                            boot.gpu_budget_application_mib = appBudgetMiB
                            boot.gpu_budget_engine_mib = engineBudgetMiB
                            boot.gpu_budget_headroom_mib = headroomBudgetMiB
                            boot.android_adb_public_key = adbPtr
                            boot.android_time_zone = tzPtr
                            boot.session_record_path = recPtr
                            boot.use_jit = useJitFlag
                            return kernarium_runtime_loader_run(view, &boot)
                        }
                    }
                }
            }
        }
    }

    nonisolated private static func withOptionalCString<R>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
        if let string {
            return string.withCString { body($0) }
        }
        return body(nil)
    }

    private func runtimeDidExit(code: Int32, message: String?) {
        runtimeThread = nil
        brandingTask?.cancel()
        brandingTask = nil
        shutdownStatusDetail = nil
        UIApplication.shared.isIdleTimerDisabled = false
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
            self.thermalObserver = nil
        }
        thermalAutoThrottleActive = false
        jitActiveInSession = false
        framesSinceGraphics = 0
        brandingAppliedForSession = false
        lastAppliedThrottleState = nil
        lastAppliedPageTrimState = nil
        stopMonitoringLoops()
        setAdbOverLan(enabled: false)
        pipController.stop()
        spacePauser?.end()
        spacePause = nil
        adbClock.setPaused(false)
        endBackgroundTaskIfNeeded()
        kernarium_runtime_loader_set_console_output_handler(nil)
        kernarium_runtime_loader_set_restart_handler(nil)

        flushConsoleBuffer(forceText: true)
        hardware.refreshDynamicMetrics()

        var errorBuffer = [CChar](repeating: 0, count: 1024)
        _ = kernarium_runtime_loader_copy_last_error(&errorBuffer, errorBuffer.count)
        let runtimeDetail = String(cString: errorBuffer).trimmingCharacters(in: .whitespacesAndNewlines)

        let name = activeVM?.name ?? "Android"
        if let message {
            phase = .ended(vmName: name, exitCode: code, note: message)
            return
        }

        if code == 0 {
            processRequiresRestart = false
            phase = .ended(
                vmName: name,
                exitCode: 0,
                note: L10n.t("session.exit.clean")
            )
            return
        }

        if code == Int32(KERNARIUM_RUNTIME_RESULT_RESTART_LOOP) {
            let releaseFailed = runtimeDetail.contains("chua thu hoi duoc vung nho nhan")
            processRequiresRestart = releaseFailed
            let detailLine = runtimeDetail.isEmpty
                ? L10n.t("session.exit.restart_loop_fallback")
                : runtimeDetail
            phase = .ended(
                vmName: name,
                exitCode: code,
                note: L10n.f("session.exit.restart_loop_note", detailLine)
            )
            return
        }

        if code == -3 {
            processRequiresRestart = true
            let detailSuffix = runtimeDetail.isEmpty ? "" : L10n.f("session.exit.detail_suffix", runtimeDetail)
            phase = .ended(
                vmName: name,
                exitCode: code,
                note: L10n.f("session.exit.code_minus3", detailSuffix)
            )
            return
        }

        if code == -4 {
            if usedHardForceStop {
                processRequiresRestart = true
                phase = .ended(
                    vmName: name,
                    exitCode: code,
                    note: L10n.t("session.exit.force_stopped_minus4")
                )
                return
            }
            if !hardware.hasExtendedVirtualAddressing {
                phase = .ended(
                    vmName: name,
                    exitCode: code,
                    note: L10n.t("session.exit.no_eva")
                )
                return
            }
            if !runtimeDetail.isEmpty {
                phase = .ended(vmName: name, exitCode: code, note: L10n.f("session.exit.ended_detail", runtimeDetail, "-4"))
                return
            }
            let recordSummary = activeVM.flatMap { vmStore.lastSessionSummary(for: $0.id) }
            phase = .ended(
                vmName: name,
                exitCode: code,
                note: recordSummary ?? L10n.t("session.exit.init_generic_minus4")
            )
            return
        }

        if code == -2 {
            phase = .ended(
                vmName: name,
                exitCode: code,
                note: L10n.t("session.exit.oom_minus2")
            )
            return
        }

        if code == -1 {
            let note = runtimeDetail.isEmpty
                ? L10n.t("session.exit.invalid_args_minus1")
                : L10n.f("session.exit.ended_detail", runtimeDetail, "-1")
            phase = .ended(vmName: name, exitCode: code, note: note)
            return
        }

        if code == 126 {
            let note = runtimeDetail.isEmpty
                ? L10n.t("session.exit.elf_load_126")
                : L10n.f("session.exit.elf_load_126_detail", runtimeDetail)
            phase = .ended(
                vmName: name,
                exitCode: code,
                note: note
            )
            return
        }

        let recordSummary = activeVM.flatMap { vmStore.lastSessionSummary(for: $0.id) }
        let fallbackNote = !runtimeDetail.isEmpty
            ? L10n.f("session.exit.ended_detail", runtimeDetail, String(code))
            : (recordSummary ?? L10n.f("session.exit.ended_generic", String(code)))
        phase = .ended(vmName: name, exitCode: code, note: fallbackNote)
    }

    func dismissEndedSession() {
        guard !phase.isActive else { return }
        shutdownStatusDetail = nil
        phase = .idle
        activeVM = nil
        activeImage = nil
        activeMetalView = nil
    }

    // MARK: - Shutdown & Control Actions

    func requestCleanShutdown() {
        guard let vm = activeVM, phase.isActive else { return }
        phase = .stopping(vmName: vm.name)
        shutdownStatusDetail = L10n.t("session.stop.sending_reboot")
        Task.detached(priority: .userInitiated) { [weak self, adbClock] in
            var adbSent = false
            if let identity = try? AdbKeyStore.forVM(vm.id).loadOrCreate() {
                let session = AdbSession(signer: identity.signer, clock: adbClock, connectLimit: 3)
                adbSent = (try? session.run { conn in
                    _ = try conn.runShell("reboot -p")
                }) != nil
            }
            // Wait up to 20s if Android received `reboot -p`, or 3s if ADB wasn't reachable yet.
            let maxTicks = adbSent ? 80 : 12
            for _ in 0..<maxTicks {
                let stillStopping = await MainActor.run { [weak self] () -> Bool in
                    guard let self, case .stopping = self.phase else { return false }
                    return true
                }
                if !stillStopping { return }
                try? await Task.sleep(for: .milliseconds(250))
            }
            await MainActor.run { [weak self] in
                guard let self, case .stopping = self.phase else { return }
                self.shutdownStatusDetail = L10n.t("session.stop.kernel_halt")
            }
            await self?.performCleanKernelHalt()
        }
    }

    func requestQuickSafeStop() {
        guard let vm = activeVM, phase.isActive else { return }
        phase = .stopping(vmName: vm.name)
        shutdownStatusDetail = L10n.t("session.stop.syncing_halt")
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.performCleanKernelHalt()
        }
    }

    private func performCleanKernelHalt() async {
        let haltRC: Int32 = await withCheckedContinuation { continuation in
            runtimeQueue.async {
                _ = kernarium_runtime_loader_sync()
                let rc = kernarium_runtime_loader_request_halt()
                continuation.resume(returning: rc)
            }
        }
        let ticks = (haltRC == 0 || haltRC == -4) ? 25 : 8
        for _ in 0..<ticks {
            let stillStopping = await MainActor.run { [weak self] () -> Bool in
                guard let self, case .stopping = self.phase else { return false }
                return true
            }
            if !stillStopping { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
        await MainActor.run { [weak self] in
            guard let self, case .stopping = self.phase else { return }
            self.forceStop()
        }
    }

    func forceStop() {
        guard phase.isActive else { return }
        usedHardForceStop = true
        if let name = activeVM?.name {
            phase = .stopping(vmName: name)
        }
        shutdownStatusDetail = L10n.t("session.stop.force_stopping")
        runtimeQueue.async {
            _ = kernarium_runtime_loader_sync()
            kernarium_runtime_loader_request_stop()
        }
    }

    func sendHardwareKey(_ code: UInt16) {
        kernarium_runtime_loader_send_key(code, 1)
        Task {
            try? await Task.sleep(for: .milliseconds(60))
            kernarium_runtime_loader_send_key(code, 0)
        }
    }

    func sendConsoleLine(_ command: String) {
        let payload = command.hasSuffix("\n") ? command : command + "\n"
        payload.withCString { ptr in
            _ = kernarium_runtime_loader_send_console_input(ptr, payload.utf8.count)
        }
    }

    func setConsoleSheetVisible(_ visible: Bool) {
        isConsoleSheetVisible = visible
        if visible {
            flushConsoleBuffer(forceText: true)
        }
    }

    func clearConsole() {
        consoleBuffer.reset()
        consoleText = ""
    }

    // MARK: - AFK Eco Mode, PiP, Mic & ADB LAN

    func setAfkEcoMode(_ enabled: Bool) {
        afkEcoMode = enabled
        applyRuntimeResourcePolicies()
        if enabled {
            keyboardVisible = false
            oledBlackoutActive = activeVM?.afkBlackoutEnabled ?? true
        } else {
            oledBlackoutActive = false
        }
    }

    func setCoolMode(_ enabled: Bool) {
        coolModeEnabled = enabled
        applyRuntimeResourcePolicies()
    }

    func togglePiP() {
        let fps = activeVM?.afkFrameRateLimit ?? 10
        pipController.toggle(fps: fps)
    }

    func setMicrophone(enabled: Bool) {
        if !enabled {
            microphoneOn = false
            _ = kernarium_runtime_loader_set_microphone(0)
            return
        }
        switch micPermission.access {
        case .granted:
            microphoneOn = true
            _ = kernarium_runtime_loader_set_microphone(1)
        case .notAsked:
            micPermission.request { [weak self] access in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let granted = (access == .granted)
                    self.microphoneOn = granted
                    _ = kernarium_runtime_loader_set_microphone(granted ? 1 : 0)
                }
            }
        case .denied:
            microphoneOn = false
            _ = kernarium_runtime_loader_set_microphone(0)
            errorBannerMessage = L10n.t("session.error.mic_denied")
        }
    }

    func setAdbOverLan(enabled: Bool) {
        if !enabled {
            networkBridge?.stop()
            networkBridge = nil
            adbLanAddress = nil
            return
        }
        if networkBridge == nil {
            let bridge = AdbNetworkBridge()
            do {
                let port = try bridge.start()
                networkBridge = bridge
                let ip = LanAddress.currentIPv4() ?? "127.0.0.1"
                adbLanAddress = "\(ip):\(port)"
            } catch {
                errorBannerMessage = L10n.f("session.error.adb_lan_failed", error.localizedDescription)
            }
        }
    }

    // MARK: - Scene Background / Foreground

    func handleScenePhaseChanged(_ newPhase: ScenePhase) {
        guard phase.isActive else { return }
        switch newPhase {
        case .background:
            isInBackground = true
            beginBackgroundTaskIfNeeded()
            if pipController.isActive || afkEcoMode {
                applyRuntimeResourcePolicies()
            } else {
                adbClock.setPaused(true)
                runtimeQueue.async {
                    _ = kernarium_runtime_loader_set_gpu_hold(1)
                    _ = kernarium_runtime_loader_quiesce()
                }
            }
        case .active:
            isInBackground = false
            endBackgroundTaskIfNeeded()
            adbClock.setPaused(false)
            runtimeQueue.async {
                kernarium_runtime_loader_resume()
                _ = kernarium_runtime_loader_set_gpu_hold(0)
            }
            applyRuntimeResourcePolicies()
        default:
            break
        }
    }

    private func applyRuntimeResourcePolicies() {
        let criticalThermal = (thermalState == .critical)
        thermalAutoThrottleActive = criticalThermal

        let memoryCritical = lowMemoryLevel == .critical
        let shouldThrottle = afkEcoMode || coolModeEnabled || criticalThermal || memoryCritical
            || (isInBackground && pipController.isActive)
        let shouldTrimPages = shouldThrottle
            || lowMemoryLevel != .normal
            || hardware.isLowMemoryHost
            || (hardware.edition == .universalSoftware && hardware.isMemoryEntitlementLimited)

        if lastAppliedThrottleState != shouldThrottle {
            lastAppliedThrottleState = shouldThrottle
            _ = kernarium_runtime_loader_set_background_throttle(shouldThrottle ? 1 : 0)
        }
        if lastAppliedPageTrimState != shouldTrimPages {
            lastAppliedPageTrimState = shouldTrimPages
            runtimeQueue.async {
                _ = kernarium_runtime_loader_set_page_cache_trimming(shouldTrimPages ? 1 : 0)
            }
        }
    }

    private func beginBackgroundTaskIfNeeded() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "DynariumVMBackground") { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.pipController.isActive {
                    _ = kernarium_runtime_loader_set_gpu_hold(1)
                    _ = kernarium_runtime_loader_quiesce()
                }
                self.endBackgroundTaskIfNeeded()
            }
        }
    }

    private func endBackgroundTaskIfNeeded() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }

    // MARK: - Telemetry & Anti-Disk-Full Protection

    private func startMonitoringLoops() {
        statsTimer?.cancel()
        statsTimer = Task { [weak self] in
            while let self, !Task.isCancelled, self.phase.isActive {
                self.evaluateHostMemoryPressure(systemWarning: false)
                self.pollStatistics()
                try? await Task.sleep(for: .seconds(1))
            }
        }

        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluateHostMemoryPressure(systemWarning: true)
            }
        }

        spaceCheckTask?.cancel()
        spaceCheckTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.phase.isActive {
                let free = HostStorage.freeBytes()
                // Zero means the volume could not be read (it happens under
                // heavy memory pressure), not that the disk is full.
                if free > 0, self.spacePause == nil, RunSpace.verdict(freeBytes: free) == .pause {
                    await self.triggerLowSpacePause(freeBytes: free)
                }
                let delay = free > 0 ? RunSpace.nextCheck(freeBytes: free) : .seconds(15)
                try? await Task.sleep(for: delay)
            }
        }

        consoleFlushTask?.cancel()
        consoleFlushTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.phase.isActive {
                self.flushConsoleBuffer(forceText: false)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func stopMonitoringLoops() {
        statsTimer?.cancel()
        statsTimer = nil
        spaceCheckTask?.cancel()
        spaceCheckTask = nil
        consoleFlushTask?.cancel()
        consoleFlushTask = nil
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
            self.memoryWarningObserver = nil
        }
        lowMemoryLevel = .normal
        lowMemoryCriticalStreak = 0
    }

    /// Keeps the VM inside the jetsam line instead of letting iOS kill the
    /// whole app: trims the guest's page cache under pressure, throttles the
    /// guest when memory is critical, and stops the guest cleanly (syncing
    /// its data disk) if the footprint keeps closing on the limit.
    private func evaluateHostMemoryPressure(systemWarning: Bool) {
        guard phase.isActive, !hardware.isRunningOnMac else { return }
        if case .stopping = phase { return }
        if isInBackground && !pipController.isActive { return }

        let available = dynarium_available_memory_bytes()
        let mib = available / (1024 * 1024)
        var next = lowMemoryLevel
        if available > 0 {
            if mib < 64 {
                next = .critical
            } else if mib < 192 {
                next = .warning
            } else if mib > 320 {
                next = .normal
            } else if next == .critical {
                next = .warning
            }
        }
        if systemWarning {
            next = max(next, .warning)
        }

        // Booting Android fills RAM in bursts that the guest's own lmkd and
        // page-cache trimming then give back, so a short dip is normal. Only a
        // footprint that stays within a few MiB of the jetsam line for several
        // seconds ends the guest; anything less only trims and throttles.
        if available > 0 && mib < 40 {
            lowMemoryCriticalStreak += 1
        } else if next != .critical {
            lowMemoryCriticalStreak = 0
        }

        if next != lowMemoryLevel {
            lowMemoryLevel = next
            applyRuntimeResourcePolicies()
            if next == .critical {
                consoleBuffer.append(
                    "[Dynarium] Host RAM low (\(mib) MiB left): trimming guest page cache and throttling Android\n"
                )
            }
        }

        if lowMemoryCriticalStreak >= 6 {
            lowMemoryCriticalStreak = 0
            errorBannerMessage = L10n.f("session.lowmem.stopping", Formats.size(bytes: available))
            requestQuickSafeStop()
        }
    }

    private func pollStatistics() {
        var stats = kernarium_runtime_statistics()
        stats.struct_size = UInt32(MemoryLayout<kernarium_runtime_statistics>.size)
        guard kernarium_runtime_loader_read_statistics(&stats) == 0 else { return }

        var next = telemetry
        next.activeVCPUs = Int(stats.processor_count)
        next.guestRamTotalBytes = stats.memory_bytes
        next.guestRamHeldBytes = stats.memory_held_bytes
        next.gpuBudgetBytes = stats.gpu_memory_budget_bytes
        next.gpuUsedBytes = stats.gpu_memory_used_bytes
        next.gpuRefusals = stats.gpu_memory_refusals
        next.displayActive = stats.display_active > 0

        if stats.boot_index == prevBootIndex,
           prevStatsTimestampNs > 0,
           stats.timestamp_ns > prevStatsTimestampNs,
           stats.processor_time_ns >= prevProcessorTimeNs,
           stats.processor_count > 0 {
            let wallDelta = Double(stats.timestamp_ns - prevStatsTimestampNs)
            let cpuDelta = Double(stats.processor_time_ns - prevProcessorTimeNs)
            let share = (cpuDelta / (wallDelta * Double(stats.processor_count))) * 100.0
            next.cpuUtilizationPercent = min(max(share, 0), 100).rounded()

            let frameCountDelta: UInt64 = stats.presented_frames >= prevPresentedFrames
                ? (stats.presented_frames - prevPresentedFrames)
                : 0
            next.fps = (Double(frameCountDelta) / (wallDelta / 1_000_000_000.0) * 2).rounded() / 2
            if bootStage >= .startingGraphics {
                framesSinceGraphics += frameCountDelta
            }
        } else if stats.boot_index != prevBootIndex {
            framesSinceGraphics = 0
        }

        prevStatsTimestampNs = stats.timestamp_ns
        prevProcessorTimeNs = stats.processor_time_ns
        prevPresentedFrames = stats.presented_frames
        prevBootIndex = stats.boot_index
        // Publishing an unchanged snapshot re-renders the whole session view
        // (and the guest display representable) on the main thread.
        if next != telemetry {
            telemetry = next
        }

        let elapsed = Date().timeIntervalSince(bootStartedAt)
        if bootStage == .preparing
            && (stats.processor_time_ns > 0 || stats.memory_held_bytes >= 8 * 1024 * 1024) {
            bootStage = .kernelBooting
        }
        if bootStage == .kernelBooting
            && (stats.memory_held_bytes >= 96 * 1024 * 1024 || (elapsed > 12 && stats.processor_time_ns > 0)) {
            bootStage = .formattingOrInit
        }
        if next.displayActive && bootStage < .startingGraphics && (bootStage >= .formattingOrInit || elapsed > 15) {
            bootStage = .startingGraphics
        }
        if next.displayActive
            && ((bootStage >= .startingGraphics && framesSinceGraphics >= 8)
                || (stats.presented_frames >= 24 && elapsed > 18)) {
            bootStage = .ready
            applyDynariumGuestBrandingIfNeeded()
        }
    }

    private func triggerLowSpacePause(freeBytes: UInt64) async {
        guard let pauser = spacePauser else { return }
        pauser.begin()
        spacePause = SpacePause(guest: activeVM?.name ?? "Android", freeBytes: freeBytes, stage: .pausing)
        adbClock.setPaused(true)
        let result = await pauser.settle()
        guard case .pausing? = spacePause?.stage else { return }
        switch result {
        case .held:
            spacePause?.stage = .paused
        case .running, .none:
            spacePause?.stage = .notPaused
            adbClock.setPaused(false)
        }
    }

    func attemptResumeFromSpacePause() {
        guard var current = spacePause else { return }
        let free = HostStorage.freeBytes()
        current.freeBytes = free
        guard RunSpace.allowsResume(freeBytes: free) else {
            current.stillShort = true
            spacePause = current
            return
        }
        current.stillShort = false
        current.working = .resuming
        spacePause = current
        _ = spacePauser?.resume { [weak self] in
            self?.adbClock.setPaused(false)
            self?.spacePause = nil
        }
    }

    // MARK: - SpacePauseEffects

    func resumeGuest(finished: @escaping @MainActor () -> Void) {
        runtimeQueue.async {
            kernarium_runtime_loader_resume()
            _ = kernarium_runtime_loader_set_gpu_hold(0)
            DispatchQueue.main.async(execute: finished)
        }
    }

    func suspendGuestResident(reason: String, finished: @escaping @MainActor () -> Void) {
        runtimeQueue.async {
            _ = kernarium_runtime_loader_set_gpu_hold(1)
            _ = kernarium_runtime_loader_quiesce_resident()
            DispatchQueue.main.async(execute: finished)
        }
    }

    nonisolated func guestProcessorTime() async -> UInt64? {
        var stats = kernarium_runtime_statistics()
        stats.struct_size = UInt32(MemoryLayout<kernarium_runtime_statistics>.size)
        guard kernarium_runtime_loader_read_statistics(&stats) == 0 else { return nil }
        return stats.processor_time_ns
    }

    // MARK: - Console Buffer

    private func flushConsoleBuffer(forceText: Bool) {
        let needMilestones = bootStage < .ready
        let drained = consoleBuffer.drain(
            needText: forceText || isConsoleSheetVisible,
            needMilestones: needMilestones
        )
        if let snapshot = drained.textSnapshot {
            consoleText = snapshot
        } else if forceText {
            consoleText = consoleBuffer.snapshotAll()
        }
        guard needMilestones else { return }
        for line in drained.lines {
            scanBootMilestone(in: line)
        }
        if !drained.partialLine.isEmpty {
            scanBootMilestone(in: drained.partialLine)
        }
    }

    private func scanBootMilestone(in line: String) {
        var detected: BootStage?
        if line.contains("processing action (sys.boot_completed=1)") || line.contains("starting service 'recovery'") {
            detected = .ready
        } else if line.contains("starting service 'surfaceflinger'")
                    || line.contains("SurfaceFlinger")
                    || line.contains("hwcomposer")
                    || line.contains("Virgl ") {
            detected = .startingGraphics
        } else if line.contains("init: init first stage started!") || line.contains("make_f2fs") || line.contains("Formatting ") || line.contains("EXT4-fs") {
            detected = .formattingOrInit
        } else if line.contains("Linux version ") {
            detected = .kernelBooting
        }
        if let detected, detected > bootStage {
            bootStage = detected
            if detected == .ready {
                applyDynariumGuestBrandingIfNeeded()
            }
        }
    }

    private func applyDynariumGuestBrandingIfNeeded() {
        guard !brandingAppliedForSession, let vm = activeVM else { return }
        brandingAppliedForSession = true
        let vmID = vm.id
        let fastUiMode = vm.fastUiMode
        let animScale = fastUiMode ? "0.5" : "1.0"
        let clock = adbClock
        brandingTask?.cancel()
        brandingTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            if let identity = try? AdbKeyStore.forVM(vmID).loadOrCreate() {
                let session = AdbSession(signer: identity.signer, clock: clock, connectLimit: 8)
                _ = try? session.run { conn in
                    _ = try conn.runShell(
                        "settings put global device_name Dynarium && settings put secure bluetooth_name Dynarium && settings put global device_provisioned 1 && settings put secure user_setup_complete 1 && settings put global window_animation_scale \(animScale) && settings put global transition_animation_scale \(animScale) && settings put global animator_duration_scale \(animScale)"
                    )
                }
            }
        }
    }
}
