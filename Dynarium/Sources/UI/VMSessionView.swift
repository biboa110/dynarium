// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import GuestHostCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct VMSessionView: View {
    @EnvironmentObject private var hardware: HostHardwareProfile
    @EnvironmentObject private var session: VMRuntimeSession
    @ObservedObject private var installer = VMRuntimeSession.shared.installer
    @ObservedObject private var pip = VMRuntimeSession.shared.pipController

    @State private var coversScreen = true
    @State private var hudCollapsed = false
    @State private var presentingConsole = false
    @State private var presentingStats = false
    @State private var presentingApkImporter = false
    @State private var confirmingShutdown = false

    private var apkTypes: [UTType] {
        var list: [UTType] = [.zip, .data]
        for ext in ["apk", "apks", "apkm"] {
            if let ut = UTType(filenameExtension: ext) { list.append(ut) }
        }
        return list
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
                    retinaMode: vm.retinaDisplay,
                    targetDisplayFPS: min(max(vm.targetDisplayFPS, 60), hardware.maxDisplayRefreshRate),
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
                    onOpenConsole: { presentingConsole = true },
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
                    presentingConsole: $presentingConsole,
                    presentingStats: $presentingStats,
                    presentingApkImporter: $presentingApkImporter,
                    confirmingShutdown: $confirmingShutdown
                )
            }

            if session.thermalAutoThrottleActive && !session.oledBlackoutActive && session.spacePause == nil && installer.state == .idle {
                VStack {
                    HStack(spacing: 6) {
                        Image(systemName: "thermometer.sun.fill")
                            .font(.caption.weight(.semibold))
                        Text("Đang tự hạ nhiệt CPU")
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

            if case let .ended(vmName, exitCode, note) = session.phase {
                EndedSessionModal(
                    vmName: vmName,
                    exitCode: exitCode,
                    note: note,
                    onOpenConsole: { presentingConsole = true },
                    onDismiss: { session.dismissEndedSession() }
                )
            }
        }
        .statusBarHidden(session.oledBlackoutActive)
        .persistentSystemOverlays(session.oledBlackoutActive ? .hidden : .automatic)
        .sheet(isPresented: $presentingConsole) {
            SerialConsoleSheet()
        }
        .sheet(isPresented: $presentingStats) {
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
        }
        .fileImporter(
            isPresented: $presentingApkImporter,
            allowedContentTypes: apkTypes,
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result,
               let url = urls.first,
               let vmID = session.activeVM?.id {
                installer.install(fileURL: url, vmID: vmID, clock: session.adbClock)
            }
        }
        .confirmationDialog(
            "Tắt máy ảo Android?",
            isPresented: $confirmingShutdown,
            titleVisibility: .visible
        ) {
            Button("Tắt nguồn an toàn (reboot -p)") {
                session.requestCleanShutdown()
            }
            Button("Dừng ngay lập tức", role: .destructive) {
                session.forceStop()
            }
            Button("Tiếp tục chạy", role: .cancel) {}
        } message: {
            Text("Tắt nguồn an toàn sẽ đồng bộ dữ liệu đĩa trước khi dừng tiến trình để bảo vệ phân vùng Android.")
        }
        .alert(
            "Thông báo phiên chạy",
            isPresented: Binding(
                get: { session.errorBannerMessage != nil },
                set: { if !$0 { session.errorBannerMessage = nil } }
            )
        ) {
            Button("Đóng", role: .cancel) { session.errorBannerMessage = nil }
        } message: {
            Text(session.errorBannerMessage ?? "")
        }
    }
}

private struct OLEDBlackoutOverlay: View {
    let vmName: String
    let telemetry: VMTelemetrySnapshot
    let onWake: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "moon.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Color(white: 0.35))
                Text("\(vmName) • AFK Eco Mode")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color(white: 0.45))
                Text(
                    "CPU \(Int(telemetry.cpuUtilizationPercent.rounded()))%  •  RAM \(Formats.size(bytes: telemetry.guestRamHeldBytes))"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color(white: 0.32))
                Text("Chạm đúp vào màn hình để tắt AFK & mở lại hiển thị")
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

    var body: some View {
        HStack(spacing: 12) {
            switch state {
            case let .preparing(detail):
                ProgressView()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Đang chuẩn bị cài đặt")
                        .font(.subheadline.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Hủy", action: onCancel)
                    .font(.caption.weight(.semibold))

            case let .transferring(detail, progress):
                ProgressView(value: progress)
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Đang đẩy APK vào Android")
                        .font(.subheadline.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Hủy", action: onCancel)
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
                Button("Đóng", action: onDismiss)
                    .font(.caption.weight(.semibold))

            case let .failed(msg):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(msg)
                    .font(.caption.weight(.medium))
                    .lineLimit(3)
                Spacer()
                Button("Đóng", action: onDismiss)
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

    private struct StepItem: Identifiable {
        let id: BootStage
        let title: String
        let detail: String
    }

    private var steps: [StepItem] {
        [
            StepItem(
                id: .preparing,
                title: "Chuẩn bị đĩa ảo & Hypervisor",
                detail: "Nạp nhân Linux 6.18 LTS và ánh xạ vùng nhớ"
            ),
            StepItem(
                id: .kernelBooting,
                title: "Khởi chạy nhân hệ điều hành",
                detail: "Nạp trình điều khiển Virtio & hệ thống tệp"
            ),
            StepItem(
                id: .formattingOrInit,
                title: isFirstBoot ? "Khởi tạo phân vùng dữ liệu Android" : "Gắn phân vùng & dịch vụ Android",
                detail: isFirstBoot
                    ? "Lần đầu tạo định dạng F2FS mất khoảng 45–90 giây"
                    : "Khởi động tiến trình init & các dịch vụ hệ thống"
            ),
            StepItem(
                id: .startingGraphics,
                title: "Khởi động đồ họa SurfaceFlinger",
                detail: "Kết xuất giao diện Android lên màn hình"
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
                        Text("Đang khởi động \(vmName)")
                            .font(.headline)
                            .lineLimit(1)
                        Text(isFirstBoot ? "Dynarium • Thiết lập lần đầu" : "Dynarium • Android 17")
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
                    Text("CPU \(Int(telemetry.cpuUtilizationPercent.rounded()))%")
                    Text("•")
                    Text("RAM đang giữ \(Formats.size(bytes: telemetry.guestRamHeldBytes))")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

                HStack(spacing: 10) {
                    CenteredActionButton(
                        title: "Mở Console",
                        systemImage: "terminal",
                        tone: .tinted,
                        action: onOpenConsole
                    )
                    CenteredActionButton(
                        title: "Ẩn bảng chờ",
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

    var body: some View {
        ZStack {
            Color.black.opacity(0.65).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                Label("Cảnh báo bộ nhớ iPhone/iPad đầy", systemImage: "internaldrive.trianglebadge.exclamationmark")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(
                    "Dung lượng trống chỉ còn \(Formats.size(bytes: spacePause.freeBytes)). Dynarium đã tạm dừng máy ảo để bảo vệ ổ đĩa Android không bị hỏng dữ liệu."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button(action: onStop) {
                        Text("Tắt máy ảo")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 38)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)

                    Button(action: onResume) {
                        Text("Thử tiếp tục")
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

private struct EndedSessionModal: View {
    let vmName: String
    let exitCode: Int32
    let note: String?
    let onOpenConsole: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: exitCode == 0 ? "checkmark.circle.fill" : "exclamationmark.octagon.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(exitCode == 0 ? .green : .orange)

                Text(exitCode == 0 ? "Đã tắt \(vmName)" : "Phiên \(vmName) đã dừng")
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
                        Text("Xem Console")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 38)
                    }
                    .buttonStyle(.bordered)

                    Button(action: onDismiss) {
                        Text("Màn hình chính")
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

    private var thermalDescription: (label: String, color: Color) {
        switch thermalState {
        case .nominal:
            return ("Bình thường", .green)
        case .fair:
            return ("Hơi ấm", .secondary)
        case .serious:
            return ("Ấm / Nóng — nên rút sạc hoặc bật Mát máy", .orange)
        case .critical:
            return ("Quá nhiệt — đang tự hạ nhiệt", .red)
        @unknown default:
            return ("Không xác định", .secondary)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Hiệu năng thời gian thực") {
                    LabeledContent("CPU máy ảo") {
                        Text(String(format: "%.0f%% (%d vCPU)", telemetry.cpuUtilizationPercent, telemetry.activeVCPUs))
                            .monospacedDigit()
                    }
                    LabeledContent("Tốc độ khung hình") {
                        let targetHz = vm.map { min(max($0.targetDisplayFPS, 60), hardware.maxDisplayRefreshRate) } ?? 60
                        Text(String(format: "%.1f / %d FPS (%d Hz)", telemetry.fps, targetHz, targetHz))
                            .monospacedDigit()
                    }
                    LabeledContent("RAM cấp / đang giữ") {
                        Text("\(Formats.size(bytes: telemetry.guestRamTotalBytes)) / \(Formats.size(bytes: telemetry.guestRamHeldBytes))")
                            .monospacedDigit()
                    }
                }

                Section("Bộ nhớ Đồ họa (GPU Pool)") {
                    LabeledContent("Ngân sách GPU tối đa") {
                        Text(Formats.size(bytes: telemetry.gpuBudgetBytes))
                            .monospacedDigit()
                    }
                    LabeledContent("Đang sử dụng") {
                        Text(Formats.size(bytes: telemetry.gpuUsedBytes))
                            .monospacedDigit()
                    }
                    LabeledContent("Số lần từ chối cấp GPU") {
                        Text("\(telemetry.gpuRefusals)")
                            .monospacedDigit()
                            .foregroundStyle(telemetry.gpuRefusals > 0 ? .orange : .secondary)
                    }
                }

                Section("Kết nối & Hệ thống") {
                    LabeledContent("Phiên bản ứng dụng") {
                        Text(hardware.edition.badgeTitle)
                    }
                    LabeledContent("Động cơ CPU") {
                        Text(jitActive ? "JIT Compiler (Tốc độ cao)" : "Gadget Engine (Chưa bật JIT)")
                            .foregroundStyle(jitActive ? .green : .secondary)
                    }
                    if let vm {
                        LabeledContent("Backend đồ họa") {
                            Text(
                                hardware.edition == .metal4Vulkan
                                    ? "KosmicKrisp + Zink"
                                    : hardware.resolvedGalliumDriver(preference: vm.softwareBackend, jitActive: hardware.debuggerAttached)
                            )
                        }
                    }
                    LabeledContent("Trạng thái nhiệt iOS") {
                        Text(thermalDescription.label)
                            .foregroundStyle(thermalDescription.color)
                    }
                    LabeledContent("Chế độ Mát máy") {
                        Text(coolModeEnabled ? "Đang bật" : (thermalAutoThrottleActive ? "Tự kích hoạt" : "Tắt"))
                            .foregroundStyle((coolModeEnabled || thermalAutoThrottleActive) ? Color.accentColor : Color.secondary)
                    }
                    LabeledContent("ADB qua Wi-Fi") {
                        Text(adbLanAddress ?? "Đang tắt")
                            .font(.subheadline.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Thông số máy ảo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Xong") { dismiss() }
                }
            }
        }
    }
}
