// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import GuestHostCore
import SwiftUI
import UniformTypeIdentifiers

struct GuestFileBrowserSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: VMRuntimeSession
    @EnvironmentObject private var l10n: AppLocalization
    @ObservedObject private var fileManager = VMRuntimeSession.shared.fileManager

    @State private var selectedEntry: GuestStorageEntry?
    @State private var confirmingCancelClose = false
    @State private var pickerAlertMessage: String?

    private var activeVMID: UUID? { session.activeVM?.id }

    private var shortcuts: [(path: String, title: String, symbol: String)] {
        [
            (GuestStoragePath.root, l10n.t("files.shortcut.internal"), "internaldrive"),
            (GuestStoragePath.downloads, l10n.t("files.shortcut.downloads"), "arrow.down.circle"),
            (GuestStoragePath.dcim, l10n.t("files.shortcut.dcim"), "photo.on.rectangle"),
            (GuestStoragePath.pictures, l10n.t("files.shortcut.pictures"), "photo"),
            (GuestStoragePath.documents, l10n.t("files.shortcut.documents"), "doc"),
        ]
    }

    var body: some View {
        NavigationStack {
            List {
                transferStatusSection
                quickActionsSection
                sharedInboxSection
                androidStorageSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle(l10n.t("files.nav.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        fileManager.refreshSharedInbox()
                        if let vmID = activeVMID {
                            fileManager.load(folder: fileManager.currentFolder, vmID: vmID, clock: session.adbClock)
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(fileManager.isLoading)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(l10n.t("common.done")) {
                        if fileManager.transferState.isBusy {
                            confirmingCancelClose = true
                        } else {
                            dismiss()
                        }
                    }
                }
            }
            .interactiveDismissDisabled(fileManager.transferState.isBusy)
            .onAppear {
                fileManager.refreshSharedInbox()
                if let vmID = activeVMID {
                    fileManager.load(
                        folder: fileManager.currentFolder,
                        vmID: vmID,
                        clock: session.adbClock,
                        allowDownloadFallback: true
                    )
                }
            }
            .confirmationDialog(
                selectedEntry?.name ?? "",
                isPresented: Binding(
                    get: { selectedEntry != nil },
                    set: { if !$0 { selectedEntry = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let entry = selectedEntry, let vmID = activeVMID {
                    if entry.isSingleApk {
                        Button(l10n.t("files.dialog.install_apk")) {
                            fileManager.installGuestApk(entry, vmID: vmID, clock: session.adbClock)
                            selectedEntry = nil
                        }
                        .disabled(fileManager.transferState.isBusy)
                    }
                    Button(l10n.t("files.dialog.export_iphone")) {
                        fileManager.exportEntry(entry, vmID: vmID, clock: session.adbClock)
                        selectedEntry = nil
                    }
                    .disabled(fileManager.transferState.isBusy)
                }
                Button(l10n.t("common.cancel"), role: .cancel) {
                    selectedEntry = nil
                }
            }
            .confirmationDialog(
                l10n.t("files.close_confirm.title"),
                isPresented: $confirmingCancelClose,
                titleVisibility: .visible
            ) {
                Button(l10n.t("files.close_confirm.stop"), role: .destructive) {
                    fileManager.cancelTransfer()
                    dismiss()
                }
                Button(l10n.t("files.close_confirm.keep"), role: .cancel) {}
            }
            .alert(
                l10n.t("session.alert.title"),
                isPresented: Binding(
                    get: { pickerAlertMessage != nil },
                    set: { if !$0 { pickerAlertMessage = nil } }
                )
            ) {
                Button(l10n.t("common.close"), role: .cancel) {
                    pickerAlertMessage = nil
                }
            } message: {
                Text(pickerAlertMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private var transferStatusSection: some View {
        switch fileManager.transferState {
        case .idle:
            EmptyView()
        case let .transferring(title, detail, progress):
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title)
                                .font(.subheadline.weight(.semibold))
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Button(l10n.t("common.cancel")) {
                            fileManager.cancelTransfer()
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderless)
                    }
                    if let progress {
                        ProgressView(value: min(max(progress, 0), 1))
                    }
                }
                .padding(.vertical, 2)
            }
        case let .completed(message):
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(message)
                        .font(.subheadline)
                    Spacer()
                    Button(l10n.t("common.close")) {
                        fileManager.dismissTransferStatus()
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
                }
            }
        case let .failed(message):
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(l10n.t("common.close")) {
                        fileManager.dismissTransferStatus()
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private var quickActionsSection: some View {
        Section(l10n.t("files.section.quick_actions")) {
            Button {
                presentSendPicker()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "square.and.arrow.down.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(l10n.t("files.action.send_from_iphone"))
                            .font(.body)
                            .foregroundStyle(.primary)
                        Text(l10n.f("files.action.send_to_folder", GuestStoragePath.name(of: fileManager.currentFolder)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            .disabled(activeVMID == nil || fileManager.transferState.isBusy)

            Button {
                presentInstallApkPicker()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.app.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28)
                    Text(l10n.t("files.action.install_apk_iphone"))
                        .font(.body)
                        .foregroundStyle(.primary)
                    Spacer()
                }
            }
            .disabled(activeVMID == nil || session.installer.state.isBusy || fileManager.transferState.isBusy)
        }
    }

    private var sharedInboxSection: some View {
        Section {
            if fileManager.sharedInboxFiles.isEmpty {
                Text(l10n.t("files.shared.empty"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(fileManager.sharedInboxFiles) { item in
                    HStack(spacing: 10) {
                        Image(systemName: item.isApkPackage ? "shippingbox.fill" : "doc.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(Formats.size(bytes: item.size))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Spacer(minLength: 8)
                        if item.isApkPackage {
                            Button(l10n.t("files.action.install_apk_short")) {
                                guard let vmID = activeVMID else { return }
                                if session.installer.state.isBusy {
                                    pickerAlertMessage = l10n.t("session.error.apk_busy")
                                } else {
                                    dismiss()
                                    session.installer.install(fileURL: item.url, vmID: vmID, clock: session.adbClock)
                                }
                            }
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.accentColor.opacity(0.14), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                            .buttonStyle(.borderless)
                            .disabled(activeVMID == nil || session.installer.state.isBusy)
                        }
                        Button(l10n.t("files.action.send_short")) {
                            guard let vmID = activeVMID else { return }
                            fileManager.uploadFiles(urls: [item.url], vmID: vmID, clock: session.adbClock)
                        }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                        .foregroundStyle(.primary)
                        .buttonStyle(.borderless)
                        .disabled(activeVMID == nil || fileManager.transferState.isBusy)
                    }
                }
            }
        } header: {
            Text(l10n.t("files.section.iphone_shared"))
        } footer: {
            Text(l10n.t("files.shared.footer"))
        }
    }

    private var androidStorageSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(shortcuts, id: \.path) { item in
                        let selected = fileManager.currentFolder == item.path
                        Button {
                            guard let vmID = activeVMID else { return }
                            fileManager.load(folder: item.path, vmID: vmID, clock: session.adbClock)
                        } label: {
                            Label(item.title, systemImage: item.symbol)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    selected ? Color.accentColor : Color(.tertiarySystemFill),
                                    in: Capsule()
                                )
                                .foregroundStyle(selected ? Color.white : Color.primary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.vertical, 2)
            }

            if fileManager.currentFolder != GuestStoragePath.root {
                Button {
                    guard let vmID = activeVMID else { return }
                    let parent = GuestStoragePath.parent(of: fileManager.currentFolder)
                    fileManager.load(folder: parent, vmID: vmID, clock: session.adbClock)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.turn.left.up")
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 24)
                        Text(l10n.t("files.action.parent_folder"))
                            .font(.subheadline.weight(.medium))
                        Spacer()
                    }
                }
            }

            if fileManager.isLoading && fileManager.entries.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(l10n.t("files.folder.loading"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if let err = fileManager.loadError {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(err)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Button(l10n.t("files.action.try_again")) {
                        guard let vmID = activeVMID else { return }
                        fileManager.load(folder: fileManager.currentFolder, vmID: vmID, clock: session.adbClock)
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 2)
            } else if fileManager.entries.isEmpty {
                Text(l10n.t("files.folder.empty"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(fileManager.entries) { entry in
                    androidEntryRow(entry)
                }
            }
        } header: {
            if let free = fileManager.guestFreeBytes {
                Text(l10n.f("files.section.android_storage_free", fileManager.currentFolder, Formats.size(bytes: free)))
            } else {
                Text(l10n.f("files.section.android_storage", fileManager.currentFolder))
            }
        }
    }

    @ViewBuilder
    private func androidEntryRow(_ entry: GuestStorageEntry) -> some View {
        Button {
            if entry.isFolder {
                guard let vmID = activeVMID else { return }
                fileManager.load(folder: entry.path, vmID: vmID, clock: session.adbClock)
            } else {
                selectedEntry = entry
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbolName(for: entry))
                    .font(.system(size: 17))
                    .foregroundStyle(entry.isFolder ? Color.accentColor : Color.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !entry.isFolder {
                        let dateText = entry.modified.formatted(date: .abbreviated, time: .omitted)
                        Text("\(Formats.size(bytes: entry.size)) • \(dateText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Spacer()
                if entry.isFolder {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .contextMenu {
            if let vmID = activeVMID {
                if entry.isFolder {
                    Button {
                        fileManager.exportEntry(entry, vmID: vmID, clock: session.adbClock)
                    } label: {
                        Label(l10n.t("files.context.export_folder"), systemImage: "square.and.arrow.up")
                    }
                    .disabled(fileManager.transferState.isBusy)
                } else {
                    if entry.isSingleApk {
                        Button {
                            fileManager.installGuestApk(entry, vmID: vmID, clock: session.adbClock)
                        } label: {
                            Label(l10n.t("files.dialog.install_apk"), systemImage: "arrow.down.app")
                        }
                        .disabled(fileManager.transferState.isBusy)
                    }
                    Button {
                        fileManager.exportEntry(entry, vmID: vmID, clock: session.adbClock)
                    } label: {
                        Label(l10n.t("files.dialog.export_iphone"), systemImage: "square.and.arrow.up")
                    }
                    .disabled(fileManager.transferState.isBusy)
                }
            }
        }
    }

    private func symbolName(for entry: GuestStorageEntry) -> String {
        if entry.isFolder { return "folder.fill" }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        switch ext {
        case "apk", "apks", "apkm", "xapk":
            return "shippingbox.fill"
        case "png", "jpg", "jpeg", "webp", "heic", "gif":
            return "photo"
        case "mp4", "mov", "mkv", "avi", "webm":
            return "film"
        case "zip", "tar", "gz", "zst", "7z", "rar":
            return "doc.zipper"
        default:
            return "doc.fill"
        }
    }

    private func presentSendPicker() {
        guard let vmID = activeVMID else { return }
        HostDocumentPickerPresenter.shared.present(
            contentTypes: [.item],
            allowsMultipleSelection: true,
            onPick: { urls in
                fileManager.uploadFiles(urls: urls, vmID: vmID, clock: session.adbClock)
            },
            onError: { message in
                pickerAlertMessage = message
            }
        )
    }

    private func presentInstallApkPicker() {
        guard let vmID = activeVMID else { return }
        if session.installer.state.isBusy {
            pickerAlertMessage = l10n.t("session.error.apk_busy")
            return
        }
        HostDocumentPickerPresenter.shared.present(
            contentTypes: [.item],
            allowsMultipleSelection: false,
            onPick: { urls in
                guard let url = urls.first else { return }
                if session.installer.state.isBusy {
                    pickerAlertMessage = l10n.t("session.error.apk_busy")
                } else {
                    dismiss()
                    session.installer.install(fileURL: url, vmID: vmID, clock: session.adbClock)
                }
            },
            onError: { message in
                pickerAlertMessage = message
            }
        )
    }
}
