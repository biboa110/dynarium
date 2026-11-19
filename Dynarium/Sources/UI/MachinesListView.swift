// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import GuestHostCore
import SwiftUI
import UIKit

private struct PendingSafetyLaunch: Equatable {
    let vm: VirtualMachineConfig
    let image: SystemImageManifest
    let safety: LaunchSafetyAssessment
}

private struct DiagnosticSheetItem: Identifiable {
    let id = UUID()
    let vmName: String
    let diagnostic: VMSessionDiagnostic
}

struct MachinesListView: View {
    let switchToImagesTab: () -> Void

    @EnvironmentObject private var hardware: HostHardwareProfile
    @EnvironmentObject private var imageStore: SystemImageStore
    @EnvironmentObject private var vmStore: VirtualMachineStore
    @EnvironmentObject private var session: VMRuntimeSession

    @AppStorage("dynarium.dismissedMetal4Tip") private var dismissedMetal4Tip = false
    @State private var presentingCreate = false
    @State private var editingVM: VirtualMachineConfig?
    @State private var cloningVMID: UUID?
    @State private var confirmingWipeVM: VirtualMachineConfig?
    @State private var confirmingDeleteVM: VirtualMachineConfig?
    @State private var cloneErrorMessage: String?
    @State private var pendingSafetyLaunch: PendingSafetyLaunch?
    @State private var inspectingDiagnostic: DiagnosticSheetItem?

    var body: some View {
        NavigationStack {
            listWithSheets
                .modifier(
                    MachineAlertsModifier(
                        confirmingWipeVM: $confirmingWipeVM,
                        confirmingDeleteVM: $confirmingDeleteVM,
                        shortage: $session.startSpaceShortage,
                        cloneErrorMessage: $cloneErrorMessage,
                        deviceKindName: hardware.deviceKindName,
                        onWipe: { vmStore.wipeDataDisk(for: $0) },
                        onDelete: { vmStore.deleteVM($0) }
                    )
                )
                .modifier(
                    SafetyLaunchAlertModifier(
                        pending: $pendingSafetyLaunch,
                        onApplyAndStart: { item in
                            let target = vmStore.applySafeProfile(for: item.vm.id, hardware: hardware) ?? item.vm
                            session.start(vm: target, image: item.image)
                        },
                        onForceStart: { item in
                            session.start(vm: item.vm, image: item.image)
                        }
                    )
                )
        }
    }

    @ViewBuilder
    private var listWithSheets: some View {
        listView
            .sheet(isPresented: $presentingCreate) {
                if let firstImage = imageStore.images.first {
                    VMConfigurationSheet(
                        mode: .create,
                        initialConfig: vmStore.makeDefaultConfig(
                            name: nextDefaultVMName(),
                            systemImageID: firstImage.id,
                            hardware: hardware
                        )
                    )
                }
            }
            .sheet(item: $editingVM) { vm in
                VMConfigurationSheet(mode: .edit, initialConfig: vm)
            }
            .sheet(item: $inspectingDiagnostic) { item in
                SessionDiagnosticSheet(vmName: item.vmName, diagnostic: item.diagnostic)
            }
    }

    @ViewBuilder
    private var listView: some View {
        List {
            Section {
                HardwareSummaryCard(hardware: hardware)
                if !hardware.hasExtendedVirtualAddressing {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Thiếu quyền địa chỉ ảo 64 GiB (lỗi mã -4)", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                        Text("Công cụ ký đã gỡ bỏ entitlement Extended Virtual Addressing. Trên iOS 16 hãy cài IPA bằng TrollStore hoặc dùng chứng chỉ giữ nguyên entitlements để chạy máy ảo.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
                if session.processRequiresRestart {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Cần khởi động lại ứng dụng Dynarium", systemImage: "arrow.clockwise.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                        Text("Phiên trước bị ép dừng ngang nên vùng nhớ nhân vẫn còn giữ lại. Hãy vuốt đóng hoàn toàn ứng dụng Dynarium rồi mở lại để tránh lỗi mã -3.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
                if hardware.recommendsMetal4Edition && !dismissedMetal4Tip {
                    Metal4RecommendationBanner(
                        chipLabel: hardware.chipGenerationLabel,
                        osVersion: hardware.osVersionString
                    ) {
                        dismissedMetal4Tip = true
                    }
                }
            } header: {
                Text("Nền tảng phần cứng")
            }

            machinesSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Dynarium")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    presentingCreate = true
                } label: {
                    Label("Tạo máy ảo", systemImage: "plus")
                }
                .disabled(imageStore.images.isEmpty)
            }
        }
        .onAppear {
            hardware.refreshDynamicMetrics()
            vmStore.reload()
        }
    }

    @ViewBuilder
    private var machinesSection: some View {
        if imageStore.images.isEmpty {
            Section {
                NoImageGuidanceCard(action: switchToImagesTab)
            } header: {
                Text("Bắt đầu nhanh")
            }
        } else if vmStore.machines.isEmpty {
            Section {
                NoMachineGuidanceCard {
                    presentingCreate = true
                }
            } header: {
                Text("Máy ảo Android")
            }
        } else {
            Section {
                ForEach(vmStore.machines) { vm in
                    vmRow(for: vm)
                }
            } header: {
                Text("Danh sách máy ảo (\(vmStore.machines.count))")
            } footer: {
                Text("Các máy ảo dùng chung hệ điều hành gốc ở chế độ chỉ đọc và lưu dữ liệu riêng theo chuẩn thưa APFS (CoW).")
            }
        }
    }

    @ViewBuilder
    private func vmRow(for vm: VirtualMachineConfig) -> some View {
        let linkedImage = imageStore.images.first { $0.id == vm.systemImageID }
        let diagnostic = vmStore.lastSessionDiagnostic(for: vm.id)
        VMRowView(
            vm: vm,
            image: linkedImage,
            diskAllocatedBytes: vmStore.dataDiskAllocatedBytes(for: vm.id),
            diskCreated: vmStore.dataDiskExists(for: vm.id),
            diagnostic: diagnostic,
            isCloning: cloningVMID == vm.id,
            canLaunch: !session.phase.isActive,
            onLaunch: { launch(vm) },
            onEdit: { editingVM = vm },
            onClone: { clone(vm) },
            onApplySafeTune: {
                _ = vmStore.applySafeProfile(for: vm.id, hardware: hardware)
            },
            onInspectDiagnostic: {
                if let diagnostic {
                    inspectingDiagnostic = DiagnosticSheetItem(vmName: vm.name, diagnostic: diagnostic)
                }
            },
            onDismissDiagnostic: {
                vmStore.clearSessionRecord(for: vm.id)
            },
            onWipeData: { confirmingWipeVM = vm },
            onDelete: { confirmingDeleteVM = vm }
        )
    }

    private func nextDefaultVMName() -> String {
        "Android 17 #\(vmStore.machines.count + 1)"
    }

    private func launch(_ vm: VirtualMachineConfig) {
        hardware.refreshDynamicMetrics()
        guard let image = imageStore.images.first(where: { $0.id == vm.systemImageID }) else {
            cloneErrorMessage = "ROM gắn với máy ảo này không còn tồn tại. Hãy chỉnh sửa để chọn ROM mới."
            return
        }
        let safety = hardware.evaluateLaunchSafety(for: vm)
        if safety.needsOptimization {
            pendingSafetyLaunch = PendingSafetyLaunch(vm: vm, image: image, safety: safety)
        } else {
            session.start(vm: vm, image: image)
        }
    }

    private func clone(_ vm: VirtualMachineConfig) {
        cloningVMID = vm.id
        Task {
            do {
                _ = try await vmStore.cloneVM(vm)
            } catch {
                cloneErrorMessage = error.localizedDescription
            }
            cloningVMID = nil
        }
    }
}

private struct HardwareSummaryCard: View {
    @ObservedObject var hardware: HostHardwareProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                        .frame(width: 40, height: 40)
                    Image(systemName: "cpu")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(hardware.chipGenerationLabel)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("iOS \(hardware.osVersionString) • \(hardware.deviceKindName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Text(hardware.edition.badgeShortTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .fixedSize()
            }

            Divider()

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                StatChip(
                    label: "Nhân vCPU",
                    value: "\(hardware.maxVCPUs)"
                )
                StatChip(
                    label: "Trần RAM",
                    value: hardware.availableProcessMemoryBytes > 0
                        ? Formats.size(bytes: hardware.availableProcessMemoryBytes)
                        : Formats.size(bytes: hardware.physicalMemoryBytes)
                )
                StatChip(
                    label: "Bộ nhớ trống",
                    value: Formats.size(bytes: hardware.hostFreeDiskBytes)
                )
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(hardware.debuggerAttached ? Color.green : Color.secondary.opacity(0.45))
                    .frame(width: 7, height: 7)
                Text(hardware.debuggerAttached
                     ? "JIT đang bật — Tốc độ CPU tối đa"
                     : "Chưa bật JIT (Gadget) — Bật JIT qua TrollStore / StikDebug để nhanh hơn 4–8×")
                    .font(.caption2)
                    .foregroundStyle(hardware.debuggerAttached ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct StatChip: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NoImageGuidanceCard: View {
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Chưa có hệ điều hành (ROM)", systemImage: "internaldrive")
                .font(.headline)
            Text("Dynarium tách riêng Hypervisor và ROM giống VMware. Hãy tải LineageOS 24 (Android 17) từ Kho ROM hoặc nhập tệp .tar.gz / .tar.zst có sẵn để tạo máy ảo.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            CenteredActionButton(
                title: "Mở Kho ROM để tải",
                systemImage: "square.and.arrow.down",
                tone: .prominent,
                action: action
            )
        }
        .padding(.vertical, 6)
    }
}

private struct NoMachineGuidanceCard: View {
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Sẵn sàng tạo máy ảo đầu tiên", systemImage: "desktopcomputer")
                .font(.headline)
            Text("ROM Android đã sẵn sàng. Hãy tạo máy ảo mới với thông số RAM/CPU được tự động tối ưu theo thiết bị của bạn.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            CenteredActionButton(
                title: "Tạo máy ảo mới",
                systemImage: "plus.circle.fill",
                tone: .prominent,
                action: action
            )
        }
        .padding(.vertical, 6)
    }
}

private struct VMRowView: View {
    let vm: VirtualMachineConfig
    let image: SystemImageManifest?
    let diskAllocatedBytes: UInt64
    let diskCreated: Bool
    let diagnostic: VMSessionDiagnostic?
    let isCloning: Bool
    let canLaunch: Bool
    let onLaunch: () -> Void
    let onEdit: () -> Void
    let onClone: () -> Void
    let onApplySafeTune: () -> Void
    let onInspectDiagnostic: () -> Void
    let onDismissDiagnostic: () -> Void
    let onWipeData: () -> Void
    let onDelete: () -> Void

    private var imageSubtitle: String {
        guard let image else {
            return "Thiếu ROM gắn kết — Cần chọn lại ROM"
        }
        if image.name.localizedCaseInsensitiveContains("Android") {
            return image.name
        }
        return "\(image.name) • Android \(image.androidMajor)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(.tertiarySystemFill))
                        .frame(width: 42, height: 42)
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(image != nil ? Color.accentColor : Color.orange)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(imageSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(image != nil ? Color.secondary : Color.orange)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 6)

                if isCloning {
                    ProgressView()
                        .frame(width: 38, height: 38)
                } else {
                    HStack(spacing: 8) {
                        Menu {
                            Button(action: onLaunch) {
                                Label("Khởi động máy ảo", systemImage: "play.fill")
                            }
                            .disabled(!canLaunch || image == nil)

                            Button(action: onEdit) {
                                Label("Cấu hình phần cứng", systemImage: "slider.horizontal.3")
                            }

                            Button(action: onClone) {
                                Label("Nhân bản nhanh (APFS)", systemImage: "doc.on.doc")
                            }

                            Divider()

                            Button(role: .destructive, action: onWipeData) {
                                Label("Đặt lại dữ liệu (Wipe)", systemImage: "eraser")
                            }
                            .disabled(!diskCreated)

                            Button(role: .destructive, action: onDelete) {
                                Label("Xóa máy ảo", systemImage: "trash")
                            }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color(.tertiarySystemFill))
                                    .frame(width: 34, height: 34)
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Circle())
                        }
                        .buttonStyle(.plain)

                        Button(action: onLaunch) {
                            ZStack {
                                Circle()
                                    .fill((!canLaunch || image == nil) ? Color(.quaternarySystemFill) : Color.accentColor)
                                    .frame(width: 38, height: 38)
                                Image(systemName: "play.fill")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle((!canLaunch || image == nil) ? Color.secondary : Color.white)
                                    .offset(x: 1)
                            }
                            .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!canLaunch || image == nil)
                    }
                }
            }

            HStack(spacing: 10) {
                Label("\(vm.vcpuCount) vCPU", systemImage: "cpu")
                Label(Formats.size(mib: vm.guestMemoryMiB), systemImage: "memorychip")
                Label(
                    diskCreated
                        ? "\(Formats.size(bytes: diskAllocatedBytes)) / \(vm.dataDiskGiB) GiB"
                        : "0 B / \(vm.dataDiskGiB) GiB",
                    systemImage: "internaldrive"
                )
                Spacer(minLength: 0)
                if let qualityBadge = vm.displayQuality.badgeTitle {
                    Text(qualityBadge)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)

            if let diagnostic {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .center, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text(diagnostic.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 4)
                        Button(action: onDismissDiagnostic) {
                            Image(systemName: "xmark")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                                .padding(4)
                        }
                        .buttonStyle(.plain)
                    }

                    Text(diagnostic.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let breakdown = diagnostic.peakBreakdown {
                        Text("Đỉnh RAM: \(breakdown)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if diagnostic.suggestsSafeTune || diagnostic.peakBreakdown != nil || diagnostic.rawTail != nil {
                        HStack(spacing: 8) {
                            if diagnostic.suggestsSafeTune {
                                Button(action: onApplySafeTune) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "wrench.and.screwdriver.fill")
                                            .font(.caption.weight(.semibold))
                                        Text("Tối ưu an toàn")
                                            .font(.caption.weight(.semibold))
                                    }
                                    .foregroundStyle(Color.accentColor)
                                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .center)
                                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                                .buttonStyle(.borderless)
                            }

                            if diagnostic.peakBreakdown != nil || diagnostic.rawTail != nil {
                                Button(action: onInspectDiagnostic) {
                                    HStack(spacing: 5) {
                                        Image(systemName: "doc.text.magnifyingglass")
                                            .font(.caption.weight(.semibold))
                                        Text("Xem chi tiết")
                                            .font(.caption.weight(.semibold))
                                    }
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: diagnostic.suggestsSafeTune ? nil : .infinity, minHeight: 32, alignment: .center)
                                    .padding(.horizontal, 10)
                                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.24), lineWidth: 0.5)
                )
            }
        }
        .padding(.vertical, 4)
    }
}

private struct SafetyLaunchAlertModifier: ViewModifier {
    @Binding var pending: PendingSafetyLaunch?
    let onApplyAndStart: (PendingSafetyLaunch) -> Void
    let onForceStart: (PendingSafetyLaunch) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Điều chỉnh cấu hình tránh tràn RAM?",
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let item = pending {
                Button("Tối ưu an toàn (\(item.safety.suggestedVCPUs) vCPU • \(Formats.size(mib: item.safety.suggestedMemoryMiB)))") {
                    pending = nil
                    onApplyAndStart(item)
                }
                Button("Vẫn chạy cấu hình hiện tại") {
                    pending = nil
                    onForceStart(item)
                }
            }
            Button("Hủy", role: .cancel) { pending = nil }
        } message: {
            if let item = pending, let reason = item.safety.reason {
                Text(reason)
            }
        }
    }
}

private struct MachineAlertsModifier: ViewModifier {
    @Binding var confirmingWipeVM: VirtualMachineConfig?
    @Binding var confirmingDeleteVM: VirtualMachineConfig?
    @Binding var shortage: StartSpace?
    @Binding var cloneErrorMessage: String?
    let deviceKindName: String
    let onWipe: (UUID) -> Void
    let onDelete: (UUID) -> Void

    func body(content: Content) -> some View {
        let withWipe = content.confirmationDialog(
            "Đặt lại dữ liệu máy ảo?",
            isPresented: Binding(
                get: { confirmingWipeVM != nil },
                set: { if !$0 { confirmingWipeVM = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let target = confirmingWipeVM {
                Button("Xóa sạch phân vùng Data", role: .destructive) {
                    onWipe(target.id)
                    confirmingWipeVM = nil
                }
            }
            Button("Hủy", role: .cancel) { confirmingWipeVM = nil }
        } message: {
            Text("Toàn bộ ứng dụng đã cài và dữ liệu trong data.img sẽ bị xóa; cấu hình máy ảo vẫn được giữ lại.")
        }

        let withDelete = withWipe.confirmationDialog(
            "Xóa máy ảo vĩnh viễn?",
            isPresented: Binding(
                get: { confirmingDeleteVM != nil },
                set: { if !$0 { confirmingDeleteVM = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let target = confirmingDeleteVM {
                Button("Xóa máy ảo", role: .destructive) {
                    onDelete(target.id)
                    confirmingDeleteVM = nil
                }
            }
            Button("Hủy", role: .cancel) { confirmingDeleteVM = nil }
        } message: {
            Text("Hành động này xóa cả cấu hình và dữ liệu người dùng của máy ảo.")
        }

        let withSpaceAlert = withDelete.alert(
            "Không đủ dung lượng trống",
            isPresented: Binding(
                get: { shortage != nil },
                set: { if !$0 { shortage = nil } }
            )
        ) {
            Button("Đóng", role: .cancel) { shortage = nil }
        } message: {
            if let s = shortage {
                Text(s.message(device: deviceKindName) + "\n" + s.advice(device: deviceKindName))
            }
        }

        withSpaceAlert.alert(
            "Không thể nhân bản máy ảo",
            isPresented: Binding(
                get: { cloneErrorMessage != nil },
                set: { if !$0 { cloneErrorMessage = nil } }
            )
        ) {
            Button("Đóng", role: .cancel) { cloneErrorMessage = nil }
        } message: {
            Text(cloneErrorMessage ?? "")
        }
    }
}

private struct SessionDiagnosticSheet: View {
    let vmName: String
    let diagnostic: VMSessionDiagnostic

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private var exportText: String {
        var parts = [
            "Máy ảo: \(vmName)",
            "Sự cố: \(diagnostic.title)",
            "Tóm tắt: \(diagnostic.message)"
        ]
        if let breakdown = diagnostic.peakBreakdown {
            parts.append("Đỉnh RAM: \(breakdown)")
        }
        if let rawTail = diagnostic.rawTail, !rawTail.isEmpty {
            parts.append("\n--- kernel-output ---\n\(rawTail)")
        }
        return parts.joined(separator: "\n")
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Chẩn đoán phiên gần nhất") {
                    LabeledContent("Máy ảo", value: vmName)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(diagnostic.title)
                            .font(.headline)
                        Text(diagnostic.message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)

                    if let breakdown = diagnostic.peakBreakdown {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Phân bổ đỉnh RAM")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(breakdown)
                                .font(.caption.monospacedDigit())
                        }
                        .padding(.vertical, 2)
                    }
                }

                if let rawTail = diagnostic.rawTail, !rawTail.isEmpty {
                    Section("Nhật ký Kernel cuối phiên") {
                        ScrollView(.horizontal, showsIndicators: true) {
                            Text(rawTail)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                                .padding(.vertical, 4)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Chi tiết phiên chạy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        UIPasteboard.general.string = exportText
                        copied = true
                    } label: {
                        Label(
                            copied ? "Đã chép" : "Sao chép",
                            systemImage: copied ? "checkmark" : "doc.on.doc"
                        )
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Xong") {
                        dismiss()
                    }
                }
            }
        }
    }
}
