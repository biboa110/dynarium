// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import GuestHostCore
import SwiftUI
import UIKit

private enum ActiveSessionSheet: Int, Identifiable {
    case console
    case stats
    case files

    var id: Int { rawValue }
}

struct VMSessionView: View {
    @EnvironmentObject private var hardware: HostHardwareProfile
    @EnvironmentObject private var session: VMRuntimeSession
    @EnvironmentObject private var l10n: AppLocalization
    @ObservedObject private var installer = VMRuntimeSession.shared.installer
    @ObservedObject private var pip = VMRuntimeSession.shared.pipController

    @State private var coversScreen = true
    @State private var hudCollapsed = false
    @State private var activeSheet: ActiveSessionSheet?
    @State private var confirmingShutdown = false

    private func sheetBinding(for target: ActiveSessionSheet) -> Binding<Bool> {
        Binding(
            get: { activeSheet == target },
            set: { isOn in
                if isOn {
                    activeSheet = target
                } else if activeSheet == target {
                    activeSheet = nil
                }
            }
        )
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Hidden small anchor required by AVSampleBufferDisplayLayer PiP on iOS 16+.
            PiPHostViewRepresentable(controller: pip)
                .frame(width: 16, height: 16)
                .opacity(0.01)
                .allowsHitTesting(false)

            if let vm = session.activeVM {
                GuestDisplayView(
                    keyboardVisible: $session.keyboardVisible,
                    retinaMode: vm.displayQuality == .retina,
                    targetDisplayFPS: min(max(vm.targetDisplayFPS, 60), hardware.maxDisplayRefreshRate),
                    maxLongEdgePixels: vm.displayQuality.maxLongEdgePixels,
                    touchDidBegin: {
                        if session.telemetry.displayActive && !hudCollapsed {
                            withAnimation(.easeOut(duration: 0.2)) {
                                hudCollapsed = true
                            }
                        }
                    },
                    viewDidLayout: { metalView, geometry in
                        session.handleDisplayLayout(view: metalView, geometry: geometry)
                    }
                )
                .ignoresSafeArea(edges: SceneCoverage.cornerOffsetEdges(coversScreen: coversScreen))
            }

            SceneCoverageReader { covers in
                coversScreen = covers
            }
            .allowsHitTesting(false)

            if session.shouldShowBootOverlay && !session.oledBlackoutActive && session.spacePause == nil {
                BootProgressOverlay(
                    vmName: session.activeVM?.name ?? "Android",
                    stage: session.bootStage,
                    startedAt: session.bootStartedAt,
                    isFirstBoot: session.isFirstBootSession,
                    telemetry: session.telemetry,
                    onOpenConsole: { activeSheet = .console },
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.2)) {
                            session.bootOverlayDismissed = true
                        }
                    }
                )
                .transition(.opacity)
            }

            if session.oledBlackoutActive {
                OLEDBlackoutOverlay(
                    vmName: session.activeVM?.name ?? "Android",
                    telemetry: session.telemetry,
                    onWake: {
                        session.setAfkEcoMode(false)
                    }
                )
            } else {
                FloatingSessionHUD(
                    collapsed: $hudCollapsed,
                    presentingConsole: sheetBinding(for: .console),
                    presentingStats: sheetBinding(for: .stats),
                    presentingFiles: sheetBinding(for: .files),
                    confirmingShutdown: $confirmingShutdown,
                    onInstallApk: presentApkPicker
                )
            }

            if session.thermalAutoThrottleActive && !session.oledBlackoutActive && session.spacePause == nil && installer.state == .idle {
                VStack {
                    HStack(spacing: 6) {
                        Image(systemName: "thermometer.sun.fill")
                            .font(.caption.weight(.semibold))
                        Text(l10n.t("session.thermal.banner"))
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.5))
                    .padding(.top, 8)
                    Spacer()
                }
                .allowsHitTesting(false)
            }

            if installer.state != .idle {
                VStack {
                    ApkInstallBanner(state: installer.state) {
                        installer.cancel()
                    } onDismiss: {
                        installer.dismissStatus()
                    }
                    Spacer()
                }
                .padding(.top, 12)
                .padding(.horizontal, 16)
            }

            if let spacePause = session.spacePause {
                LowSpacePauseModal(
                    spacePause: spacePause,
                    onResume: { session.attemptResumeFromSpacePause() },
                    onStop: { session.forceStop() }
                )
            }

            if case let .stopping(vmName) = session.phase {
                StoppingSessionOverlay(
                    vmName: vmName,
                    detail: session.shutdownStatusDetail ?? l10n.t("session.stop.syncing_disk"),
                    onForceStop: { session.forceStop() }
                )
            }

            if case let .ended(vmName, exitCode, note) = session.phase {
                EndedSessionModal(
                    vmName: vmName,
                    exitCode: exitCode,
                    note: note,
                    onOpenConsole: { activeSheet = .console },
                    onDismiss: { session.dismissEndedSession() }
                )
            }
        }
        .statusBarHidden(session.oledBlackoutActive)
        .persistentSystemOverlays(session.oledBlackoutActive ? .hidden : .automatic)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .console:
                SerialConsoleSheet()
            case .stats:
                SessionStatsSheet(
                    vm: session.activeVM,
                    hardware: hardware,
                    telemetry: session.telemetry,
                    adbLanAddress: session.adbLanAddress,
                    thermalState: session.thermalState,
                    coolModeEnabled: session.coolModeEnabled,
                    thermalAutoThrottleActive: session.thermalAutoThrottleActive,
                    jitActive: session.jitActiveInSession
                )
            case .files:
                GuestFileBrowserSheet()
            }
        }
        .confirmationDialog(
            l10n.t("session.shutdown.title"),
            isPresented: $confirmingShutdown,
            titleVisibility: .visible
        ) {
            Button(l10n.t("session.shutdown.clean")) {
                session.requestCleanShutdown()
            }
            Button(l10n.t("session.shutdown.quick_halt")) {
                session.requestQuickSafeStop()
            }
            if pip.isSupported {
                Button(l10n.t("session.shutdown.pip")) {
                    session.togglePiP()
                }
            }
            Button(l10n.t("session.shutdown.force"), role: .destructive) {
                session.forceStop()
            }
            Button(l10n.t("session.shutdown.keep_running"), role: .cancel) {}
        } message: {
            Text(l10n.t("session.shutdown.message"))
        }
        .alert(
            l10n.t("session.alert.title"),
            isPresented: Binding(
                get: { session.errorBannerMessage != nil },
                set: { if !$0 { session.errorBannerMessage = nil } }
            )
        ) {
            Button(l10n.t("common.close"), role: .cancel) { session.errorBannerMessage = nil }
        } message: {
            Text(session.errorBannerMessage ?? "")
        }
    }

    private func presentApkPicker() {
        if installer.state.isBusy {
            session.errorBannerMessage = l10n.t("session.error.apk_busy")
            return
        }
        session.keyboardVisible = false
        HostDocumentPickerPresenter.shared.present(
            contentTypes: [.item],
            allowsMultipleSelection: false,
            onPick: { urls in
                guard let url = urls.first else { return }
                if installer.state.isBusy {
                    session.errorBannerMessage = l10n.t("session.error.apk_busy")
                } else if let vmID = session.activeVM?.id {
                    installer.install(fileURL: url, vmID: vmID, clock: session.adbClock)
                } else {
                    session.errorBannerMessage = l10n.f("session.error.apk_no_vm", url.lastPathComponent)
                }
            },
            onError: { message in
                session.errorBannerMessage = message
            }
        )
    }
}

private struct OLEDBlackoutOverlay: View {
    let vmName: String
    let telemetry: VMTelemetrySnapshot
    let onWake: () -> Void
    @EnvironmentObject private var l10n: AppLocalization

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "moon.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Color(white: 0.35))
                Text(l10n.f("session.afk.title", vmName))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color(white: 0.45))
                Text(
                    l10n.f(
                        "session.afk.stats",
                        String(Int(telemetry.cpuUtilizationPercent.rounded())),
                        Formats.size(bytes: telemetry.guestRamHeldBytes)
                    )
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color(white: 0.32))
                Text(l10n.t("session.afk.wake_hint"))
                    .font(.caption2)
                    .foregroundStyle(Color(white: 0.25))
                    .padding(.top, 8)
            }
            .padding()
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onWake)
    }
}

private struct ApkInstallBanner: View {
    let state: ApkInstallState
    let onCancel: () -> Void
    let onDismiss: () -> Void
    @EnvironmentObject private var l10n: AppLocalization

    var body: some View {
        HStack(spacing: 12) {
            switch state {
            case let .preparing(detail):
                ProgressView()
                VStack(alignment: .leading, spacing: 2) {
                    Text(l10n.t("apk.preparing_banner"))
                        .font(.subheadline.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button(l10n.t("common.cancel"), action: onCancel)
                    .font(.caption.weight(.semibold))

            case let .transferring(detail, progress):
                ProgressView(value: progress)
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(l10n.t("apk.transferring_banner"))
                        .font(.subheadline.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button(l10n.t("common.cancel"), action: onCancel)
                    .font(.caption.weight(.semibold))

            case let .installing(detail):
                ProgressView()
                Text(detail)
                    .font(.caption.weight(.medium))
                Spacer()

            case let .completed(msg):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(msg)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                Spacer()
                Button(l10n.t("common.close"), action: onDismiss)
                    .font(.caption.weight(.semibold))

            case let .failed(msg):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(msg)
                    .font(.caption.weight(.medium))
                    .lineLimit(3)
                Spacer()
                Button(l10n.t("common.close"), action: onDismiss)
                    .font(.caption.weight(.semibold))

            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
    }
}

private struct BootProgressOverlay: View {
    let vmName: String
    let stage: BootStage
    let startedAt: Date
    let isFirstBoot: Bool
    let telemetry: VMTelemetrySnapshot
    let onOpenConsole: () -> Void
    let onDismiss: () -> Void
    @EnvironmentObject private var l10n: AppLocalization

    private struct StepItem: Identifiable {
        let id: BootStage
        let title: String
        let detail: String
    }

    private var steps: [StepItem] {
        [
            StepItem(
                id: .preparing,
                title: l10n.t("session.boot.step1.title"),
                detail: l10n.t("session.boot.step1.detail")
            ),
            StepItem(
                id: .kernelBooting,
                title: l10n.t("session.boot.step2.title"),
                detail: l10n.t("session.boot.step2.detail")
            ),
            StepItem(
                id: .formattingOrInit,
                title: isFirstBoot ? l10n.t("session.boot.step3.title_first") : l10n.t("session.boot.step3.title"),
                detail: isFirstBoot
                    ? l10n.t("session.boot.step3.detail_first")
                    : l10n.t("session.boot.step3.detail")
            ),
            StepItem(
                id: .startingGraphics,
                title: l10n.t("session.boot.step4.title"),
                detail: l10n.t("session.boot.step4.detail")
            ),
        ]
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.68).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 10) {
                    Image("BrandMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(l10n.f("session.boot.title", vmName))
                            .font(.headline)
                            .lineLimit(1)
                        Text(isFirstBoot ? l10n.t("session.boot.subtitle_first") : l10n.t("session.boot.subtitle"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    TimelineView(.periodic(from: startedAt, by: 1)) { ctx in
                        let elapsed = max(0, Int(ctx.date.timeIntervalSince(startedAt)))
                        Text(Formats.elapsed(elapsed))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(steps) { step in
                        HStack(alignment: .top, spacing: 12) {
                            stepIndicator(for: step.id)
                                .frame(width: 22, height: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(stage.rawValue < step.id.rawValue ? .secondary : .primary)
                                Text(step.detail)
                                    .font(.caption)
                                    .foregroundStyle(stage == step.id ? Color.accentColor : Color.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }

                Divider()

                HStack {
                    Text(l10n.f("session.boot.cpu_stat", String(Int(telemetry.cpuUtilizationPercent.rounded()))))
                    Text("•")
                    Text(l10n.f("session.boot.ram_held", Formats.size(bytes: telemetry.guestRamHeldBytes)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

                HStack(spacing: 10) {
                    CenteredActionButton(
                        title: l10n.t("session.boot.open_console"),
                        systemImage: "terminal",
                        tone: .tinted,
                        action: onOpenConsole
                    )
                    CenteredActionButton(
                        title: l10n.t("session.boot.hide"),
                        systemImage: "eye.slash",
                        tone: .tinted,
                        action: onDismiss
                    )
                }
            }
            .padding(18)
            .frame(maxWidth: 400)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 74)
            .environment(\.colorScheme, .dark)
        }
    }

    @ViewBuilder
    private func stepIndicator(for step: BootStage) -> some View {
        if stage.rawValue > step.rawValue {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(Color.accentColor)
        } else if stage == step {
            ProgressView()
                .controlSize(.small)
        } else {
            Image(systemName: "circle")
                .font(.system(size: 18))
                .foregroundStyle(.tertiary)
        }
    }
}

private struct LowSpacePauseModal: View {
    let spacePause: SpacePause
    let onResume: () -> Void
    let onStop: () -> Void
    @EnvironmentObject private var l10n: AppLocalization

    var body: some View {
        ZStack {
            Color.black.opacity(0.65).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                Label(l10n.t("session.low_space.title"), systemImage: "internaldrive.trianglebadge.exclamationmark")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(
                    l10n.f("session.low_space.body", Formats.size(bytes: spacePause.freeBytes))
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button(action: onStop) {
                        Text(l10n.t("session.low_space.stop"))
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 38)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)

                    Button(action: onResume) {
                        Text(l10n.t("session.low_space.resume"))
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 38)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .frame(maxWidth: 400)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(24)
        }
    }
}

private struct StoppingSessionOverlay: View {
    let vmName: String
    let detail: String
    let onForceStop: () -> Void
    @EnvironmentObject private var l10n: AppLocalization

    var body: some View {
        ZStack {
            Color.black.opacity(0.68).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text(l10n.f("session.stopping.title", vmName))
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(l10n.t("session.stopping.force_now"), role: .destructive, action: onForceStop)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
            }
            .padding(22)
            .frame(maxWidth: 340)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(24)
        }
    }
}

private struct EndedSessionModal: View {
    let vmName: String
    let exitCode: Int32
    let note: String?
    let onOpenConsole: () -> Void
    let onDismiss: () -> Void
    @EnvironmentObject private var l10n: AppLocalization

    var body: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: exitCode == 0 ? "checkmark.circle.fill" : "exclamationmark.octagon.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(exitCode == 0 ? .green : .orange)

                Text(exitCode == 0 ? l10n.f("session.ended.title_clean", vmName) : l10n.f("session.ended.title_stopped", vmName))
                    .font(.headline)
                    .multilineTextAlignment(.center)

                if let note {
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Button(action: onOpenConsole) {
                        Text(l10n.t("session.ended.open_console"))
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 38)
                    }
                    .buttonStyle(.bordered)

                    Button(action: onDismiss) {
                        Text(l10n.t("session.ended.home"))
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 38)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.top, 4)
            }
            .padding(22)
            .frame(maxWidth: 380)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(24)
        }
    }
}

private struct SessionStatsSheet: View {
    let vm: VirtualMachineConfig?
    let hardware: HostHardwareProfile
    let telemetry: VMTelemetrySnapshot
    let adbLanAddress: String?
    let thermalState: ProcessInfo.ThermalState
    let coolModeEnabled: Bool
    let thermalAutoThrottleActive: Bool
    let jitActive: Bool

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var l10n: AppLocalization

    private var thermalDescription: (label: String, color: Color) {
        switch thermalState {
        case .nominal:
            return (l10n.t("session.stats.thermal_nominal"), .green)
        case .fair:
            return (l10n.t("session.stats.thermal_fair"), .secondary)
        case .serious:
            return (l10n.t("session.stats.thermal_serious"), .orange)
        case .critical:
            return (l10n.t("session.stats.thermal_critical"), .red)
        @unknown default:
            return (l10n.t("common.unknown"), .secondary)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section(l10n.t("session.stats.section_realtime")) {
                    LabeledContent(l10n.t("session.stats.cpu")) {
                        let pct = String(Int(telemetry.cpuUtilizationPercent.rounded()))
                        Text(l10n.f("session.stats.cpu_value", pct, String(telemetry.activeVCPUs)))
                            .monospacedDigit()
                    }
                    LabeledContent(l10n.t("session.stats.fps")) {
                        let targetHz = vm.map { min(max($0.targetDisplayFPS, 60), hardware.maxDisplayRefreshRate) } ?? 60
                        let fpsStr = String(format: "%.1f", telemetry.fps)
                        Text(l10n.f("session.stats.fps_value", fpsStr, String(targetHz), String(targetHz)))
                            .monospacedDigit()
                    }
                    LabeledContent(l10n.t("session.stats.ram")) {
                        Text("\(Formats.size(bytes: telemetry.guestRamTotalBytes)) / \(Formats.size(bytes: telemetry.guestRamHeldBytes))")
                            .monospacedDigit()
                    }
                }

                Section(l10n.t("session.stats.section_gpu")) {
                    LabeledContent(l10n.t("session.stats.gpu_budget")) {
                        Text(Formats.size(bytes: telemetry.gpuBudgetBytes))
                            .monospacedDigit()
                    }
                    LabeledContent(l10n.t("session.stats.gpu_used")) {
                        Text(Formats.size(bytes: telemetry.gpuUsedBytes))
                            .monospacedDigit()
                    }
                    LabeledContent(l10n.t("session.stats.gpu_refusals")) {
                        Text("\(telemetry.gpuRefusals)")
                            .monospacedDigit()
                            .foregroundStyle(telemetry.gpuRefusals > 0 ? .orange : .secondary)
                    }
                }

                Section(l10n.t("session.stats.section_system")) {
                    LabeledContent(l10n.t("session.stats.app_edition")) {
                        Text(hardware.edition.badgeTitle)
                    }
                    LabeledContent(l10n.t("session.stats.cpu_engine")) {
                        Text(jitActive ? l10n.t("session.stats.cpu_jit") : l10n.t("session.stats.cpu_gadget"))
                            .foregroundStyle(jitActive ? .green : .secondary)
                    }
                    if let vm {
                        LabeledContent(l10n.t("session.stats.gpu_backend")) {
                            Text(
                                hardware.edition == .metal4Vulkan
                                    ? "KosmicKrisp + Zink"
                                    : HostHardwareProfile.resolveGalliumDriver(preference: vm.softwareBackend, jitActive: jitActive)
                            )
                        }
                    }
                    LabeledContent(l10n.t("session.stats.ios_thermal")) {
                        Text(thermalDescription.label)
                            .foregroundStyle(thermalDescription.color)
                    }
                    LabeledContent(l10n.t("session.stats.cool_mode")) {
                        Text(coolModeEnabled ? l10n.t("common.on") : (thermalAutoThrottleActive ? l10n.t("common.auto_activated") : l10n.t("common.disabled")))
                            .foregroundStyle((coolModeEnabled || thermalAutoThrottleActive) ? Color.accentColor : Color.secondary)
                    }
                    LabeledContent(l10n.t("session.stats.adb_wifi")) {
                        Text(adbLanAddress ?? l10n.t("common.off"))
                            .font(.subheadline.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(l10n.t("session.stats.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(l10n.t("common.done")) { dismiss() }
                }
            }
        }
    }
}
