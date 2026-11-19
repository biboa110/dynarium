// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import GuestHostCore
import SwiftUI
import UniformTypeIdentifiers

struct SystemImagesView: View {
    @EnvironmentObject private var imageStore: SystemImageStore
    @EnvironmentObject private var vmStore: VirtualMachineStore

    @State private var presentingFileImporter = false
    @State private var presentingCustomURL = false
    @State private var imagePendingDeletion: SystemImageManifest?

    private var importContentTypes: [UTType] {
        var list: [UTType] = [.gzip, .archive, .data]
        if let zst = UTType(filenameExtension: "zst") { list.append(zst) }
        if let tar = UTType(filenameExtension: "tar") { list.append(tar) }
        return list
    }

    var body: some View {
        NavigationStack {
            List {
                if let active = imageStore.activeInstall {
                    Section("Đang xử lý") {
                        ActiveInstallProgressCard(state: active) {
                            imageStore.cancelActiveInstall()
                        }
                    }
                }

                Section {
                    ForEach(OfficialCatalogImage.catalog) { item in
                        let alreadyInstalled = imageStore.images.contains {
                            $0.sourceDescription.contains(item.id)
                        }
                        CatalogRowView(
                            item: item,
                            alreadyInstalled: alreadyInstalled,
                            disabled: imageStore.isBusy()
                        ) {
                            imageStore.installCatalogImage(item)
                        }
                    }
                } header: {
                    Text("Kho ROM chính thức")
                } footer: {
                    Text("Bản ROM Android 17 (LineageOS 24) tải trực tiếp từ kho phát hành và giải nén dạng thưa (APFS Sparse) để tiết kiệm dung lượng.")
                }

                Section {
                    if imageStore.images.isEmpty {
                        Text("Chưa có ROM nào trên máy. Bạn có thể tải 1 chạm ở mục trên hoặc nhập tệp .tar.gz / .tar.zst từ Tệp.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(imageStore.images) { image in
                            InstalledImageRow(
                                image: image,
                                allocatedBytes: imageStore.allocatedBytes(for: image),
                                dependentVMCount: vmStore.countVMsUsingImage(image.id)
                            )
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    imagePendingDeletion = image
                                } label: {
                                    Label("Xóa", systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    Text("ROM đã cài trên thiết bị (\(imageStore.images.count))")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Kho ROM")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            presentingFileImporter = true
                        } label: {
                            Label("Nhập tệp ROM từ Tệp (.tar.gz / .tar.zst)", systemImage: "folder")
                        }
                        Button {
                            presentingCustomURL = true
                        } label: {
                            Label("Tải từ liên kết URL", systemImage: "link")
                        }
                    } label: {
                        Label("Thêm ROM", systemImage: "plus")
                    }
                    .disabled(imageStore.isBusy())
                }
            }
            .fileImporter(
                isPresented: $presentingFileImporter,
                allowedContentTypes: importContentTypes,
                allowsMultipleSelection: false
            ) { result in
                if case let .success(urls) = result, let url = urls.first {
                    imageStore.importLocalArchive(at: url)
                }
            }
            .sheet(isPresented: $presentingCustomURL) {
                AddSystemImageSheet()
            }
            .alert(
                "Lỗi cài đặt ROM",
                isPresented: Binding(
                    get: { imageStore.lastErrorMessage != nil },
                    set: { if !$0 { imageStore.lastErrorMessage = nil } }
                )
            ) {
                Button("Đóng", role: .cancel) { imageStore.lastErrorMessage = nil }
            } message: {
                Text(imageStore.lastErrorMessage ?? "")
            }
            .confirmationDialog(
                "Xóa ROM hệ thống?",
                isPresented: Binding(
                    get: { imagePendingDeletion != nil },
                    set: { if !$0 { imagePendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let img = imagePendingDeletion {
                    Button("Xóa ROM này", role: .destructive) {
                        imageStore.deleteImage(img)
                        imagePendingDeletion = nil
                    }
                }
                Button("Hủy", role: .cancel) { imagePendingDeletion = nil }
            } message: {
                if let img = imagePendingDeletion {
                    let refs = vmStore.countVMsUsingImage(img.id)
                    Text(
                        refs > 0
                            ? "Đang có \(refs) máy ảo liên kết tới ROM này. Sau khi xóa bạn cần gán ROM khác trước khi khởi động lại chúng."
                            : "Xóa gói hệ điều hành \(img.name) để giải phóng bộ nhớ trên máy."
                    )
                }
            }
        }
    }
}

private struct ActiveInstallProgressCard: View {
    let state: ImageInstallState
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title)
                        .font(.headline)
                    Text(state.phase.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Hủy", role: .cancel, action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            switch state.phase {
            case let .downloading(received, total, speed):
                if total > 0 {
                    ProgressView(value: Double(received), total: Double(total))
                } else {
                    ProgressView()
                }
                HStack {
                    Text(
                        total > 0
                            ? "\(Formats.size(bytes: received)) / \(Formats.size(bytes: total))"
                            : Formats.size(bytes: received)
                    )
                    Spacer()
                    if speed > 1024 {
                        Text("\(Formats.size(bytes: UInt64(speed)))/s")
                    }
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            case let .extracting(fraction, entry, sparseSaved):
                ProgressView(value: fraction)
                HStack {
                    Text(entry.isEmpty ? "Đang giải nén\u{2026}" : entry)
                        .lineLimit(1)
                    Spacer()
                    if sparseSaved > 0 {
                        Text("Tiết kiệm APFS: \(Formats.size(bytes: sparseSaved))")
                            .monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

            case .verifyingSHA256:
                ProgressView()
                Text("Đang tính mã băm SHA-256 của guest/system.img\u{2026}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct CatalogRowView: View {
    let item: OfficialCatalogImage
    let alreadyInstalled: Bool
    let disabled: Bool
    let onDownload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                        .frame(width: 42, height: 42)
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .center, spacing: 8) {
                        Text(item.title)
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        if alreadyInstalled {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                Text("Đã cài")
                            }
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.green.opacity(0.14), in: Capsule())
                            .fixedSize()
                        }
                    }
                    Text(item.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                Text(item.kernelVersion)
                Text("•")
                Text(item.pageProfile)
                Text("•")
                Text(Formats.size(bytes: item.approximateDownloadBytes))
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            CenteredActionButton(
                title: alreadyInstalled ? "Tải thêm bản sao" : "Tải về ngay (1 chạm)",
                systemImage: "square.and.arrow.down",
                tone: alreadyInstalled ? .tinted : .prominent,
                disabled: disabled,
                action: onDownload
            )
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }
}

private struct InstalledImageRow: View {
    let image: SystemImageManifest
    let allocatedBytes: UInt64
    let dependentVMCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(image.name)
                    .font(.headline)
                Spacer()
                if image.verified {
                    Label("SHA-256 OK", systemImage: "checkmark.seal.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                }
            }

            HStack(spacing: 10) {
                Text("Android \(image.androidMajor)")
                Text("•")
                Text("Thật: \(Formats.size(bytes: allocatedBytes))")
                    .monospacedDigit()
                Text("•")
                Text("Dùng bởi \(dependentVMCount) VM")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text("SHA-256: \(image.systemSha256.prefix(24))\u{2026}")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
