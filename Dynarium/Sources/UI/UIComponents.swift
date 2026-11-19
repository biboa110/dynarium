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
                Text("Khuyên dùng bản Metal 4 cho iOS \(osVersion)")
                    .font(.subheadline.weight(.semibold))
                Text("\(chipLabel) hỗ trợ tăng tốc GPU Vulkan 1.4 qua gói Metal4-iOS26.ipa (mượt và nhẹ RAM hơn). Bản Universal hiện tại vẫn chạy an toàn bằng CPU.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link(destination: URL(string: "https://github.com/userlethekhoi/dynarium/releases/latest")!) {
                    Label("Mở trang tải Metal4-iOS26.ipa", systemImage: "arrow.down.circle")
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
            .accessibilityLabel("Ẩn gợi ý")
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
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: false)
        controller.allowsMultipleSelection = false
        controller.delegate = context.coordinator
        return controller
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
