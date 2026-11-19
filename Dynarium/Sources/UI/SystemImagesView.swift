// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import GuestHostCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SystemImagesView: View {
    @EnvironmentObject private var imageStore: SystemImageStore
    @EnvironmentObject private var vmStore: VirtualMachineStore

    @State private var presentingFileImporter = false
    @State private var presentingCustomURL = false
    @State private var presentingCustomGuide = false
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
                    if let refreshError = imageStore.catalogRefreshError {
                        Label(refreshError, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    ForEach(imageStore.catalogImages) { item in
                        let alreadyInstalled = imageStore.images.contains {
                            $0.sourceDescription.contains(item.id)
                                || (!item.shortRevision.isEmpty && $0.name.contains(item.shortRevision))
                                || (!item.releaseTag.isEmpty && $0.sourceDescription.contains(item.releaseTag))
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
                    HStack {
                        Text("Kho ROM chính thức")
                        Spacer()
                        if imageStore.isRefreshingCatalog {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }
                } footer: {
                    if let last = imageStore.catalogLastRefreshed {
                        Text("Đã đồng bộ nguồn phát hành chính thức lúc \(last.formatted(date: .omitted, time: .shortened)). Các bản ROM đều giải nén thưa (APFS Sparse) để tiết kiệm dung lượng.")
                    } else {
                        Text("Các bản ROM chính thức từ GitHub Releases (Kernarium / Dynarium) hỗ trợ giải nén dạng thưa (APFS Sparse) để tiết kiệm dung lượng. Kéo xuống để cập nhật danh sách phiên bản mới.")
                    }
                }

                Section {
                    Text("Bạn có thể tự tải tệp ROM (.tar.gz / .tar.zst) từ website phát hành chính thức hoặc nạp bản ROM tự tùy biến rồi nhập trực tiếp vào máy.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 2)

                    CenteredActionButton(
                        title: "Nhập tệp ROM từ Tệp (Files)",
                        systemImage: "folder.badge.plus",
                        tone: .tinted,
                        disabled: imageStore.isBusy()
                    ) {
                        presentingFileImporter = true
                    }

                    CenteredActionButton(
                        title: "Tải từ liên kết URL tùy chỉnh",
                        systemImage: "link.badge.plus",
                        tone: .tinted,
                        disabled: imageStore.isBusy()
                    ) {
                        presentingCustomURL = true
                    }

                    Button {
                        presentingCustomGuide = true
                    } label: {
                        Label("Nguồn chính thức & Hướng dẫn Custom ROM", systemImage: "doc.text.magnifyingglass")
                    }
                } header: {
                    Text("Nhập ROM thủ công & Tự Custom")
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
            .refreshable {
                await imageStore.refreshOfficialCatalog()
            }
            .task {
                await imageStore.refreshOfficialCatalogIfNeeded()
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        Task { await imageStore.refreshOfficialCatalog() }
                    } label: {
                        if imageStore.isRefreshingCatalog {
                            ProgressView()
                        } else {
                            Label("Làm mới nguồn ROM", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(imageStore.isRefreshingCatalog)

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
                        Divider()
                        Button {
                            presentingCustomGuide = true
                        } label: {
                            Label("Nguồn chính thức & Custom ROM", systemImage: "doc.text.magnifyingglass")
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
            .sheet(isPresented: $presentingCustomGuide) {
                CustomRomGuideSheet()
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

    private var badgeTint: Color {
        switch item.badgeText {
        case "Mới nhất":
            return .accentColor
        case "Trực tuyến":
            return .teal
        default:
            return .indigo
        }
    }

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

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
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
                        } else if let badge = item.badgeText {
                            Text(badge)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(badgeTint)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(badgeTint.opacity(0.14), in: Capsule())
                                .fixedSize()
                        }
                    }

                    Text(item.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        Text("\(item.sourceName) • \(item.releaseTag)")
                        if let published = item.publishedLabel {
                            Text("•")
                            Text(published)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
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

            VStack(spacing: 8) {
                CenteredActionButton(
                    title: alreadyInstalled ? "Tải thêm bản sao" : "Tải trực tiếp trong app",
                    systemImage: "square.and.arrow.down",
                    tone: alreadyInstalled ? .tinted : .prominent,
                    disabled: disabled,
                    action: onDownload
                )

                Link(destination: item.sourcePageURL) {
                    Label("Mở trang phát hành chính thức", systemImage: "safari")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            Color(.secondarySystemFill),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
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

private struct CustomRomGuideSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(OfficialWebsiteSource.all) { source in
                        Link(destination: source.url) {
                            HStack(spacing: 12) {
                                Image(systemName: source.iconName)
                                    .font(.title3)
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(source.name)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text(source.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } header: {
                    Text("Website phát hành chính thức & an toàn")
                } footer: {
                    Text("Chỉ nên tải tệp ROM từ kho phát hành chính thức trên GitHub Releases hoặc tự biên dịch từ mã nguồn LineageOS để đảm bảo toàn vẹn SHA-256.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Lưu trữ dưới dạng .tar.gz, .tgz hoặc .tar.zst với các tệp bên trong:")
                            .font(.subheadline)
                        Text("• guest/system.img (hoặc guest/super.img)\n• guest/partition-layout.json\n• boot/kernel-command-line.txt")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Yêu cầu kỹ thuật 4 KiB Guest Page")
                            .font(.subheadline.weight(.medium))
                        Text("Android Runtime và linker 64/32-bit cần phân vùng gốc định dạng 4 KiB để tương thích hoàn toàn với User-Mode Linux Mainline 6.18.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Cấu trúc gói ROM tự custom")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Nguồn & Custom ROM")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Xong") {
                        dismiss()
                    }
                }
            }
        }
    }
}
