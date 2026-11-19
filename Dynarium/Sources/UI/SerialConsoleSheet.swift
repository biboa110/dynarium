// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit

struct SerialConsoleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: VMRuntimeSession

    @State private var commandInput: String = ""

    private let quickCommands = [
        ("Version", "getprop ro.build.version.release"),
        ("Disk", "df -h /data"),
        ("Memory", "free -m"),
        ("Top", "top -n 1 | head -n 18"),
        ("Logcat", "logcat -d -t 30"),
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(session.consoleText.isEmpty ? "Đang chờ đầu ra Serial Console từ nhân Linux\u{2026}" : session.consoleText)
                            .font(.system(size: 11.5, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(12)
                            .id("CONSOLE_BOTTOM")
                    }
                    .background(Color(.systemGroupedBackground))
                    .onChange(of: session.consoleText.count) { _ in
                        withAnimation(.linear(duration: 0.1)) {
                            proxy.scrollTo("CONSOLE_BOTTOM", anchor: .bottom)
                        }
                    }
                }

                Divider()

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(quickCommands, id: \.0) { title, cmd in
                            Button(title) {
                                session.sendConsoleLine(cmd)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }

                HStack(spacing: 8) {
                    TextField("Nhập lệnh shell (vd: ls -la /data)", text: $commandInput)
                        .font(.system(size: 13, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.send)
                        .onSubmit(submitCommand)

                    Button("Gửi", action: submitCommand)
                        .buttonStyle(.borderedProminent)
                        .disabled(commandInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .padding(.top, 4)
            }
            .navigationTitle("Serial Console")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            UIPasteboard.general.string = session.consoleText
                        } label: {
                            Label("Sao chép toàn bộ nhật ký", systemImage: "doc.on.doc")
                        }
                        Button(role: .destructive) {
                            session.clearConsole()
                        } label: {
                            Label("Xóa nhật ký hiển thị", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Đóng") { dismiss() }
                }
            }
        }
    }

    private func submitCommand() {
        let trimmed = commandInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        session.sendConsoleLine(trimmed)
        commandInput = ""
    }
}
