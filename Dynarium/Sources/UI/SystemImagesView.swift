// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import GuestHostCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private enum ActiveImageSheet: Int, Identifiable {
    case filePicker
    case customURL
    case customGuide

    var id: Int { rawValue }
}

struct SystemImagesView: View {
    @EnvironmentObject private var imageStore: SystemImageStore
    @EnvironmentObject private var vmStore: VirtualMachineStore
    @EnvironmentObject private var l10n: AppLocalization

    @State private var activeSheet: ActiveImageSheet?
    @State private var imagePendingDeletion: SystemImageManifest?

    var body: some View {
        NavigationStack {
            List {
                if let active = imageStore.activeInstall {
                    Section(l10n.t("rom.section.active_install")) {
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
                        Text(l10n.t("rom.section.official"))
                        Spacer()
                        if imageStore.isRefreshingCatalog {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }
                } footer: {
                    if let last = imageStore.catalogLastRefreshed {
                        Text(l10n.f("rom.section.official_footer_synced", last.formatted(date: .omitted, time: .shortened)))
                    } else {
                        Text(l10n.t("rom.section.official_footer_default"))
                    }
                }

                Section {
                    Text(l10n.t("rom.section.custom_body"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 2)

                    CenteredActionButton(
                        title: l10n.t("rom.action.import_files"),
                        systemImage: "folder.badge.plus",
                        tone: .tinted,
                        disabled: imageStore.isBusy()
                    ) {
                        activeSheet = .filePicker
                    }

                    CenteredActionButton(
                        title: l10n.t("rom.action.import_url"),
                        systemImage: "link.badge.plus",
                        tone: .tinted,
                        disabled: imageStore.isBusy()
                    ) {
                        activeSheet = .customURL
                    }

                    Button {
                        activeSheet = .customGuide
                    } label: {
                        Label(l10n.t("rom.action.guide"), systemImage: "doc.text.magnifyingglass")
                    }
                } header: {
                    Text(l10n.t("rom.section.custom_header"))
                }

                Section {
                    if imageStore.images.isEmpty {
                        Text(l10n.t("rom.section.installed_empty"))
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
                                    Label(l10n.t("common.delete"), systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    Text(l10n.f("rom.section.installed", String(imageStore.images.count)))
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(l10n.t("rom.nav.title"))
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
                            Label(l10n.t("rom.toolbar.refresh"), systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(imageStore.isRefreshingCatalog)

                    Menu {
                        Button {
                            activeSheet = .filePicker
                        } label: {
                            Label(l10n.t("rom.menu.import_files"), systemImage: "folder")
                        }
                        Button {
                            activeSheet = .customURL
                        } label: {
                            Label(l10n.t("rom.menu.import_url"), systemImage: "link")
                        }
                        Divider()
                        Button {
                            activeSheet = .customGuide
                        } label: {
                            Label(l10n.t("rom.menu.guide"), systemImage: "doc.text.magnifyingglass")
                        }
                    } label: {
                        Label(l10n.t("rom.toolbar.add"), systemImage: "plus")
                    }
                    .disabled(imageStore.isBusy())
                }
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .filePicker:
                    DocumentPickerSheet(
                        contentTypes: [.item],
                        onPick: { url in
                            activeSheet = nil
                            imageStore.importLocalArchive(at: url)
                        },
                        onCancel: {
                            activeSheet = nil
                        }
                    )
                    .ignoresSafeArea()
                case .customURL:
                    AddSystemImageSheet()
                case .customGuide:
                    CustomRomGuideSheet()
                }
            }
            .alert(
                l10n.t("rom.alert.error_title"),
                isPresented: Binding(
                    get: { imageStore.lastErrorMessage != nil },
                    set: { if !$0 { imageStore.lastErrorMessage = nil } }
                )
            ) {
                Button(l10n.t("common.close"), role: .cancel) { imageStore.lastErrorMessage = nil }
            } message: {
                Text(imageStore.lastErrorMessage ?? "")
            }
            .confirmationDialog(
                l10n.t("rom.delete.dialog_title"),
                isPresented: Binding(
                    get: { imagePendingDeletion != nil },
                    set: { if !$0 { imagePendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let img = imagePendingDeletion {
                    Button(l10n.t("rom.delete.confirm"), role: .destructive) {
                        imageStore.deleteImage(img)
                        imagePendingDeletion = nil
                    }
                }
                Button(l10n.t("common.cancel"), role: .cancel) { imagePendingDeletion = nil }
            } message: {
                if let img = imagePendingDeletion {
                    let refs = vmStore.countVMsUsingImage(img.id)
                    Text(
                        refs > 0
                            ? l10n.f("rom.delete.message_in_use", String(refs))
                            : l10n.f("rom.delete.message_unused", img.name)
                    )
                }
            }
        }
    }
}

private struct ActiveInstallProgressCard: View {
    let state: ImageInstallState
    let onCancel: () -> Void
    @EnvironmentObject private var l10n: AppLocalization

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
                Button(l10n.t("common.cancel"), role: .cancel, action: onCancel)
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
                    Text(entry.isEmpty ? l10n.t("rom.extract.working") : entry)
                        .lineLimit(1)
                    Spacer()
                    if sparseSaved > 0 {
                        Text(l10n.f("rom.extract.apfs_saved", Formats.size(bytes: sparseSaved)))
                            .monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

            case .verifyingSHA256:
                ProgressView()
                Text(l10n.t("rom.verify.sha_hint"))
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
    @EnvironmentObject private var l10n: AppLocalization

    private var badgeTint: Color {
        switch item.badgeKind {
        case .latest:
            return .accentColor
        case .online:
            return .teal
        case .stable:
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
                                Text(l10n.t("rom.badge.installed"))
                            }
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.green.opacity(0.14), in: Capsule())
                            .fixedSize()
                        } else {
                            Text(item.badgeText)
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
                    title: alreadyInstalled ? l10n.t("rom.action.download_another") : l10n.t("rom.action.download_in_app"),
                    systemImage: "square.and.arrow.down",
                    tone: alreadyInstalled ? .tinted : .prominent,
                    disabled: disabled,
                    action: onDownload
                )

                Link(destination: item.sourcePageURL) {
                    Label(l10n.t("rom.action.open_release_page"), systemImage: "safari")
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
    @EnvironmentObject private var l10n: AppLocalization

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
                Text(l10n.f("rom.installed.actual_size", Formats.size(bytes: allocatedBytes)))
                    .monospacedDigit()
                Text("•")
                Text(l10n.f("rom.installed.used_by", String(dependentVMCount)))
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
    @EnvironmentObject private var l10n: AppLocalization

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
                    Text(l10n.t("rom.guide.section_sites"))
                } footer: {
                    Text(l10n.t("rom.guide.section_sites_footer"))
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(l10n.t("rom.guide.archive_req"))
                            .font(.subheadline)
                        Text("• guest/system.img (or guest/super.img)\n• guest/partition-layout.json\n• boot/kernel-command-line.txt")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(l10n.t("rom.guide.page_req_title"))
                            .font(.subheadline.weight(.medium))
                        Text(l10n.t("rom.guide.page_req_body"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text(l10n.t("rom.guide.section_layout"))
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(l10n.t("rom.guide.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(l10n.t("common.done")) {
                        dismiss()
                    }
                }
            }
        }
    }
}
