// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum ActionButtonTone {
    case prominent
    case tinted
}

struct CenteredActionButton: View {
    let title: String
    let systemImage: String
    var tone: ActionButtonTone = .prominent
    var disabled: Bool = false
    let action: () -> Void

    private var foregroundColor: Color {
        if disabled {
            return tone == .prominent ? Color.white.opacity(0.75) : Color.secondary
        }
        return tone == .prominent ? .white : Color.accentColor
    }

    private var backgroundColor: Color {
        if disabled {
            return Color(.quaternarySystemFill)
        }
        return tone == .prominent ? Color.accentColor : Color.accentColor.opacity(0.14)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(foregroundColor)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
            .padding(.horizontal, 14)
            .background(
                backgroundColor,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

struct Metal4RecommendationBanner: View {
    let chipLabel: String
    let osVersion: String
    let onDismiss: () -> Void
    @EnvironmentObject private var l10n: AppLocalization

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                    .frame(width: 34, height: 34)
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(l10n.f("machines.banner.metal4.title", osVersion))
                    .font(.subheadline.weight(.semibold))
                Text(l10n.f("machines.banner.metal4.body", chipLabel))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link(destination: URL(string: "https://github.com/userlethekhoi/dynarium/releases/latest")!) {
                    Label(l10n.t("machines.banner.metal4.cta"), systemImage: "arrow.down.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Color.accentColor.opacity(0.14),
                            in: Capsule()
                        )
                }
                .buttonStyle(.borderless)
                .padding(.top, 2)
            }

            Spacer(minLength: 4)

            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    onDismiss()
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(l10n.t("machines.banner.metal4.dismiss"))
        }
        .padding(.vertical, 4)
    }
}

struct DocumentPickerSheet: UIViewControllerRepresentable {
    let contentTypes: [UTType]
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    init(
        contentTypes: [UTType] = [.item],
        onPick: @escaping (URL) -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        self.contentTypes = contentTypes
        self.onPick = onPick
        self.onCancel = onCancel
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = RetainingDocumentPicker(forOpeningContentTypes: contentTypes, asCopy: false)
        controller.allowsMultipleSelection = false
        controller.delegate = context.coordinator
        // UIDocumentPickerViewController holds its delegate weakly; when the
        // picker dismisses its own sheet SwiftUI may release the coordinator
        // before the pick is delivered. The picker keeps it alive instead.
        controller.retainedDelegate = context.coordinator
        return controller
    }

    final class RetainingDocumentPicker: UIDocumentPickerViewController {
        var retainedDelegate: AnyObject?
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {
        context.coordinator.onPick = onPick
        context.coordinator.onCancel = onCancel
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var onPick: (URL) -> Void
        var onCancel: () -> Void

        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                onCancel()
                return
            }
            onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}

@MainActor
private func dynariumTopViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let activeScene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    let windows = activeScene?.windows ?? []
    let window = windows.first(where: \.isKeyWindow)
        ?? windows.first(where: { !$0.isHidden })
        ?? windows.first
    guard var top = window?.rootViewController else { return nil }
    while let presented = top.presentedViewController, !presented.isBeingDismissed {
        top = presented
    }
    return top
}

@MainActor
final class HostDocumentPickerPresenter: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
    static let shared = HostDocumentPickerPresenter()

    private var onPick: (([URL]) -> Void)?
    private var onCancel: (() -> Void)?
    private weak var activePicker: UIDocumentPickerViewController?

    private override init() {
        super.init()
    }

    func present(
        contentTypes: [UTType] = [.item],
        allowsMultipleSelection: Bool = false,
        onPick: @escaping ([URL]) -> Void,
        onCancel: @escaping () -> Void = {},
        onError: @escaping (String) -> Void = { _ in }
    ) {
        if let existing = activePicker, existing.presentingViewController != nil {
            onError(L10n.t("picker.error.busy"))
            return
        }
        activePicker = nil
        self.onPick = nil
        self.onCancel = nil

        guard let top = dynariumTopViewController() else {
            onError(L10n.t("picker.error.unavailable"))
            return
        }

        // End text editing first so GuestMetalView releases keyboard focus before UIKit presents the picker.
        top.view.window?.endEditing(true)

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: false)
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.delegate = self
        picker.presentationController?.delegate = self

        self.onPick = onPick
        self.onCancel = onCancel
        self.activePicker = picker

        top.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let pickHandler = onPick
        let cancelHandler = onCancel
        clearState()
        if urls.isEmpty {
            cancelHandler?()
        } else {
            pickHandler?(urls)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        let cancelHandler = onCancel
        clearState()
        cancelHandler?()
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        let cancelHandler = onCancel
        clearState()
        cancelHandler?()
    }

    private func clearState() {
        onPick = nil
        onCancel = nil
        activePicker = nil
    }
}

@MainActor
enum HostSharePresenter {
    @discardableResult
    static func present(_ items: [URL], completed: @escaping @MainActor @Sendable (Bool) -> Void = { _ in }) -> Bool {
        guard let top = dynariumTopViewController() else { return false }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        sheet.completionWithItemsHandler = { _, done, _, _ in
            Task { @MainActor in
                completed(done)
            }
        }
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        top.present(sheet, animated: true)
        return true
    }
}
