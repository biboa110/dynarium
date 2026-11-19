// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import SwiftUI

struct AddSystemImageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var imageStore: SystemImageStore
    @EnvironmentObject private var l10n: AppLocalization

    @State private var romName: String = ""
    @State private var urlString: String = ""
    @State private var validationMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(l10n.t("rom.add_url.name_placeholder"), text: $romName)
                    TextField("https://example.com/android-rom.tar.gz", text: $urlString)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text(l10n.t("rom.add_url.section_header"))
                } footer: {
                    Text(l10n.t("rom.add_url.section_footer"))
                }

                if let validationMessage {
                    Section {
                        Text(validationMessage)
                            .foregroundStyle(.red)
                            .font(.subheadline)
                    }
                }
            }
            .navigationTitle(l10n.t("rom.add_url.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(l10n.t("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(l10n.t("rom.add_url.download")) {
                        startDownload()
                    }
                    .disabled(urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func startDownload() {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil else {
            validationMessage = l10n.t("rom.add_url.invalid_url")
            return
        }
        let cleanName = romName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = cleanName.isEmpty ? url.deletingPathExtension().lastPathComponent : cleanName
        imageStore.installFromRemoteURL(
            url,
            preferredName: resolvedName.isEmpty ? l10n.t("rom.add_url.default_custom_name") : resolvedName,
            sourceDescription: l10n.f("rom.source.url", url.host ?? trimmedURL)
        )
        dismiss()
    }
}
