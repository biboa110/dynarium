// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import SwiftUI

struct AddSystemImageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var imageStore: SystemImageStore

    @State private var romName: String = ""
    @State private var urlString: String = ""
    @State private var validationMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Tên hiển thị (vd: LineageOS Custom)", text: $romName)
                    TextField("https://example.com/android-rom.tar.gz", text: $urlString)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Nguồn tải ROM")
                } footer: {
                    Text("Hỗ trợ tệp nén .tar.gz, .tar.zst hoặc .tar chứa guest/system.img, guest/partition-layout.json và boot/kernel-command-line.txt.")
                }

                if let validationMessage {
                    Section {
                        Text(validationMessage)
                            .foregroundStyle(.red)
                            .font(.subheadline)
                    }
                }
            }
            .navigationTitle("Tải ROM từ URL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Hủy") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Tải xuống") {
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
            validationMessage = "Vui lòng nhập đường dẫn http:// hoặc https:// hợp lệ."
            return
        }
        let cleanName = romName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = cleanName.isEmpty ? url.deletingPathExtension().lastPathComponent : cleanName
        imageStore.installFromRemoteURL(
            url,
            preferredName: resolvedName.isEmpty ? "ROM tùy chỉnh" : resolvedName,
            sourceDescription: "URL: \(url.host ?? trimmedURL)"
        )
        dismiss()
    }
}
