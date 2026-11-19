// SPDX-License-Identifier: GPL-2.0-or-later

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
                    touchDidBegin: {
                        if !hudCollapsed {
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
                adbLanAddress: session.adbLanAddress
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

                HStack {
                    Button("Tắt máy ảo", role: .destructive, action: onStop)
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("Thử tiếp tục", action: onResume)
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

                if let note {
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 12) {
                    Button("Xem Console", action: onOpenConsole)
                        .buttonStyle(.bordered)
                    Button("Về màn hình chính", action: onDismiss)
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

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Hiệu năng thời gian thực") {
                    LabeledContent("CPU máy ảo") {
                        Text(String(format: "%.0f%% (%d vCPU)", telemetry.cpuUtilizationPercent, telemetry.activeVCPUs))
                            .monospacedDigit()
                    }
                    LabeledContent("Tốc độ khung hình") {
                        Text(String(format: "%.1f FPS", telemetry.fps))
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
                    if let vm {
                        LabeledContent("Backend đồ họa") {
                            Text(
                                hardware.edition == .metal4Vulkan
                                    ? "KosmicKrisp + Zink"
                                    : hardware.resolvedGalliumDriver(preference: vm.softwareBackend, jitActive: hardware.debuggerAttached)
                            )
                        }
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
