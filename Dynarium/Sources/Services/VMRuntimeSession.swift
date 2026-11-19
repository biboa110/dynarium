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
    @Published private(set) var coolModeEnabled: Bool = false
    @Published private(set) var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    @Published private(set) var thermalAutoThrottleActive: Bool = false
    @Published private(set) var microphoneOn: Bool = false
    @Published private(set) var adbLanAddress: String?
    @Published var keyboardVisible: Bool = false
    @Published var errorBannerMessage: String?

    var shouldShowBootOverlay: Bool {
        phase.isActive && !telemetry.displayActive && bootStage != .ready && !bootOverlayDismissed
    }

    let installer = ApkInstaller()
    let pipController = DynariumPiPController()
    let adbClock = AdbRunClock()

    private let hardware = HostHardwareProfile.shared
    private let vmStore = VirtualMachineStore.shared
    private let imageStore = SystemImageStore.shared
    private let runtimeQueue = DispatchQueue(label: "com.dynarium.runtime.lifecycle", qos: .userInitiated)
    private let consoleLimitBytes = 64 * 1024

    private var activeImage: SystemImageManifest?
    private var activeMetalView: GuestMetalView?
    private var initialGeometry: GuestDisplayGeometry?
    private var bootLaunchedForSession = false
    private var consoleLineBuffer = ""
    private var runtimeThread: Thread?
    private var thermalObserver: NSObjectProtocol?
    private var lastAppliedThrottleState: Bool?
    private var lastAppliedPageTrimState: Bool?
    private var statsTimer: Task<Void, Never>?
    private var spaceCheckTask: Task<Void, Never>?
    private var spacePauser: SpacePauser?
    private var networkBridge: AdbNetworkBridge?
    private var micPermission = SystemMicrophonePermission()
    private var prevStatsTimestampNs: UInt64 = 0
    private var prevProcessorTimeNs: UInt64 = 0
    private var prevPresentedFrames: UInt64 = 0
    private var prevBootIndex: UInt32 = 0
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var isInBackground = false

    private init() {
        spacePauser = SpacePauser(effects: self)
        pipController.setStateHandler { [weak self] _ in
            self?.applyRuntimeResourcePolicies()
        }
    }

    // MARK: - Launch Lifecycle

    func start(vm: VirtualMachineConfig, image: SystemImageManifest) {
        guard !phase.isActive else { return }
        startSpaceShortage = nil
        errorBannerMessage = nil

        let isFirstBoot = !vmStore.dataDiskExists(for: vm.id)
        let freeBytes = HostStorage.freeBytes()
        if let shortage = StartSpace(freeBytes: freeBytes, firstStart: isFirstBoot) {
            startSpaceShortage = shortage
            return
        }

        isFirstBootSession = isFirstBoot
        activeVM = vm
        activeImage = image
        telemetry = VMTelemetrySnapshot()
        consoleText = ""
        consoleLineBuffer = ""
        bootStage = .preparing
        bootStartedAt = Date()
        bootOverlayDismissed = false
        spacePause = nil
        afkEcoMode = false
        oledBlackoutActive = false
        coolModeEnabled = vm.thermalSaverEnabled
        thermalState = ProcessInfo.processInfo.thermalState
        thermalAutoThrottleActive = (thermalState == .serious || thermalState == .critical)
        lastAppliedThrottleState = nil
        lastAppliedPageTrimState = nil
        keyboardVisible = false
        bootLaunchedForSession = false
        initialGeometry = nil
        prevStatsTimestampNs = 0
        prevProcessorTimeNs = 0
        prevPresentedFrames = 0
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

        // Configure Gallium software driver & disable LLVM draw JIT before selecting runtime.
        if isUniversal {
            let driver = hardware.resolvedGalliumDriver(
                preference: vm.softwareBackend,
                jitActive: hardware.debuggerAttached
            )
            setenv("GALLIUM_DRIVER", driver, 1)
            setenv("DRAW_USE_LLVM", driver == "llvmpipe" ? "1" : "0", 1)
        }

        let selectRC = kernarium_runtime_loader_select(UInt32(KERNARIUM_RUNTIME_GUEST_ANDROID))
        guard selectRC == 0 else {
            runtimeDidExit(code: selectRC, message: "Không thể nạp framework runtime Android (\(selectRC)).")
            return
        }

        kernarium_runtime_loader_set_console_output_handler { [weak self] data in
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in
                self?.appendConsole(text)
            }
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
                    if isUniversal {
                        setenv("GALLIUM_DRIVER", "llvmpipe", 1)
                        setenv("DRAW_USE_LLVM", "1", 1)
                    }
                }
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
        UIApplication.shared.isIdleTimerDisabled = false
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
            self.thermalObserver = nil
        }
        thermalAutoThrottleActive = false
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

        let name = activeVM?.name ?? "Android"
        if let message {
            phase = .ended(vmName: name, exitCode: code, note: message)
        } else if code == 0 {
            phase = .ended(vmName: name, exitCode: 0, note: "Máy ảo đã tắt nguồn an toàn.")
        } else if code == Int32(KERNARIUM_RUNTIME_RESULT_RESTART_LOOP) {
            phase = .ended(vmName: name, exitCode: code, note: "Android khởi động lại liên tục 5 lần nên hypervisor đã dừng bảo vệ.")
        } else {
            let recordSummary = activeVM.flatMap { vmStore.lastSessionSummary(for: $0.id) }
            phase = .ended(vmName: name, exitCode: code, note: recordSummary ?? "Phiên máy ảo kết thúc (mã \(code)).")
        }
    }

    func dismissEndedSession() {
        guard !phase.isActive else { return }
        phase = .idle
        activeVM = nil
        activeImage = nil
        activeMetalView = nil
    }

    // MARK: - Shutdown & Control Actions

    func requestCleanShutdown() {
        guard let vm = activeVM, phase.isActive else { return }
        phase = .stopping(vmName: vm.name)
        Task.detached(priority: .userInitiated) { [adbClock] in
            if let identity = try? AdbKeyStore.forVM(vm.id).loadOrCreate() {
                let session = AdbSession(signer: identity.signer, clock: adbClock, connectLimit: 5)
                _ = try? session.run { conn in
                    _ = try conn.runShell("reboot -p")
                }
            }
            // Wait up to 8 seconds for clean Android poweroff before issuing host sync+stop.
            try? await Task.sleep(for: .seconds(8))
            await MainActor.run { [weak self] in
                guard let self, case .stopping = self.phase else { return }
                self.forceStop()
            }
        }
    }

    func forceStop() {
        guard phase.isActive else { return }
        if let name = activeVM?.name {
            phase = .stopping(vmName: name)
        }
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

    func clearConsole() {
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
            errorBannerMessage = "Quyền Micro bị từ chối trong Cài đặt iOS."
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
                errorBannerMessage = "Không thể mở cổng ADB Wi-Fi (5555): \(error.localizedDescription)"
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
        let hot = (thermalState == .serious || thermalState == .critical)
        thermalAutoThrottleActive = hot

        let shouldThrottle = afkEcoMode || coolModeEnabled || hot || (isInBackground && pipController.isActive)
        let shouldTrimPages = shouldThrottle || hardware.isMemoryEntitlementLimited

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
                self.pollStatistics()
                try? await Task.sleep(for: .seconds(1))
            }
        }

        spaceCheckTask?.cancel()
        spaceCheckTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.phase.isActive {
                let free = HostStorage.freeBytes()
                if self.spacePause == nil, RunSpace.verdict(freeBytes: free) == .pause {
                    await self.triggerLowSpacePause(freeBytes: free)
                }
                let delay = RunSpace.nextCheck(freeBytes: free)
                try? await Task.sleep(for: delay)
            }
        }
    }

    private func stopMonitoringLoops() {
        statsTimer?.cancel()
        statsTimer = nil
        spaceCheckTask?.cancel()
        spaceCheckTask = nil
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
            next.cpuUtilizationPercent = min(max(share, 0), 100)

            let frameDelta = stats.presented_frames >= prevPresentedFrames
                ? Double(stats.presented_frames - prevPresentedFrames)
                : 0
            next.fps = frameDelta / (wallDelta / 1_000_000_000.0)
        }

        prevStatsTimestampNs = stats.timestamp_ns
        prevProcessorTimeNs = stats.processor_time_ns
        prevPresentedFrames = stats.presented_frames
        prevBootIndex = stats.boot_index
        telemetry = next

        if next.displayActive && bootStage < .startingGraphics {
            bootStage = .startingGraphics
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

    private func appendConsole(_ text: String) {
        guard !text.isEmpty else { return }
        consoleText.append(text)
        if consoleText.utf8.count > consoleLimitBytes {
            let trimStart = consoleText.index(consoleText.endIndex, offsetBy: -48_000, limitedBy: consoleText.startIndex) ?? consoleText.startIndex
            consoleText = String(consoleText[trimStart...])
        }

        guard bootStage < .ready else { return }
        consoleLineBuffer.append(text)
        while let newlineIdx = consoleLineBuffer.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            let line = String(consoleLineBuffer[..<newlineIdx])
            consoleLineBuffer.removeSubrange(...newlineIdx)
            scanBootMilestone(in: line)
        }
        if consoleLineBuffer.utf8.count > 4096 {
            consoleLineBuffer.removeAll(keepingCapacity: true)
        } else if !consoleLineBuffer.isEmpty {
            scanBootMilestone(in: consoleLineBuffer)
        }
    }

    private func scanBootMilestone(in line: String) {
        var detected: BootStage?
        if line.contains("processing action (sys.boot_completed=1)") || line.contains("starting service 'recovery'") {
            detected = .ready
        } else if line.contains("starting service 'surfaceflinger'") || line.contains("Virgl ") {
            detected = .startingGraphics
        } else if line.contains("init: init first stage started!") || line.contains("make_f2fs") || line.contains("Formatting ") || line.contains("EXT4-fs") {
            detected = .formattingOrInit
        } else if line.contains("Linux version ") {
            detected = .kernelBooting
        }
        if let detected, detected > bootStage {
            bootStage = detected
        }
    }
}
