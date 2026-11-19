// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import GuestHostCore
import SwiftUI
import UIKit

struct MachinesListView: View {
    let switchToImagesTab: () -> Void

    @EnvironmentObject private var hardware: HostHardwareProfile
    @EnvironmentObject private var imageStore: SystemImageStore
    @EnvironmentObject private var vmStore: VirtualMachineStore
    @EnvironmentObject private var session: VMRuntimeSession

    @State private var presentingCreate = false
    @State private var editingVM: VirtualMachineConfig?
    @State private var cloningVMID: UUID?
    @State private var confirmingWipeVM: VirtualMachineConfig?
    @State private var confirmingDeleteVM: VirtualMachineConfig?
    @State private var cloneErrorMessage: String?

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
    }

    @ViewBuilder
    private var listView: some View {
        List {
            Section {
                HardwareSummaryCard(hardware: hardware)
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
        VMRowView(
            vm: vm,
            image: linkedImage,
            diskAllocatedBytes: vmStore.dataDiskAllocatedBytes(for: vm.id),
            diskCreated: vmStore.dataDiskExists(for: vm.id),
            lastNote: vmStore.lastSessionSummary(for: vm.id),
            isCloning: cloningVMID == vm.id,
            canLaunch: !session.phase.isActive,
            onLaunch: { launch(vm) },
            onEdit: { editingVM = vm },
            onClone: { clone(vm) },
            onWipeData: { confirmingWipeVM = vm },
            onDelete: { confirmingDeleteVM = vm }
        )
    }

    private func nextDefaultVMName() -> String {
        "Android 17 #\(vmStore.machines.count + 1)"
    }

    private func launch(_ vm: VirtualMachineConfig) {
        guard let image = imageStore.images.first(where: { $0.id == vm.systemImageID }) else {
            cloneErrorMessage = "ROM gắn với máy ảo này không còn tồn tại. Hãy chỉnh sửa để chọn ROM mới."
            return
        }
        session.start(vm: vm, image: image)
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                        .frame(width: 40, height: 40)
                    Image(systemName: "cpu")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(hardware.chipGenerationLabel)
                        .font(.headline)
                    Text("iOS \(hardware.osVersionString) • \(hardware.metalDeviceName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(hardware.edition.badgeTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }

            Divider()

            HStack(spacing: 16) {
                StatChip(
                    label: "Tối đa vCPU",
                    value: "\(hardware.maxVCPUs)"
                )
                StatChip(
                    label: "Trần RAM tiến trình",
                    value: hardware.availableProcessMemoryBytes > 0
                        ? Formats.size(bytes: hardware.availableProcessMemoryBytes)
                        : Formats.size(bytes: hardware.physicalMemoryBytes)
                )
                StatChip(
                    label: "Trống trên máy",
                    value: Formats.size(bytes: hardware.hostFreeDiskBytes)
                )
            }
        }
        .padding(.vertical, 4)
    }
}

private struct StatChip: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NoImageGuidanceCard: View {
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Chưa có hệ điều hành (ROM)", systemImage: "internaldrive")
                .font(.headline)
            Text("Dynarium tách riêng Hypervisor và ROM giống VMware. Hãy tải LineageOS 24 (Android 17) từ Kho ROM hoặc nhập tệp .tar.gz / .tar.zst có sẵn để tạo máy ảo.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(action: action) {
                Label("Mở Kho ROM để tải", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 2)
        }
        .padding(.vertical, 6)
    }
}

private struct NoMachineGuidanceCard: View {
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Sẵn sàng tạo máy ảo đầu tiên", systemImage: "desktopcomputer")
                .font(.headline)
            Text("ROM Android đã sẵn sàng. Hãy tạo máy ảo mới với thông số RAM/CPU được tự động tối ưu theo thiết bị của bạn.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(action: action) {
                Label("Tạo máy ảo mới", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 2)
        }
        .padding(.vertical, 6)
    }
}

private struct VMRowView: View {
    let vm: VirtualMachineConfig
    let image: SystemImageManifest?
    let diskAllocatedBytes: UInt64
    let diskCreated: Bool
    let lastNote: String?
    let isCloning: Bool
    let canLaunch: Bool
    let onLaunch: () -> Void
    let onEdit: () -> Void
    let onClone: () -> Void
    let onWipeData: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(.tertiarySystemFill))
                        .frame(width: 44, height: 44)
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(image != nil ? Color.accentColor : Color.orange)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(vm.name)
                        .font(.headline)
                    if let image {
                        Text("\(image.name) • Android \(image.androidMajor)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("Thiếu ROM gắn kết — Cần chọn lại ROM")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }

                Spacer()

                if isCloning {
                    ProgressView()
                } else {
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
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                            .padding(4)
                    }

                    Button(action: onLaunch) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .disabled(!canLaunch || image == nil)
                }
            }

            HStack(spacing: 12) {
                Label("\(vm.vcpuCount) vCPU", systemImage: "cpu")
                Label(Formats.size(mib: vm.guestMemoryMiB), systemImage: "memorychip")
                Label(
                    diskCreated
                        ? "\(Formats.size(bytes: diskAllocatedBytes)) / \(vm.dataDiskGiB) GiB"
                        : "0 B / \(vm.dataDiskGiB) GiB",
                    systemImage: "internaldrive"
                )
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)

            if let lastNote {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(lastNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
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
