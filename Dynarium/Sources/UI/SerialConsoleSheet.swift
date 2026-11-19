// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit

struct SerialConsoleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: VMRuntimeSession
    @EnvironmentObject private var l10n: AppLocalization

    @State private var commandInput: String = ""

    private var quickCommands: [(String, String)] {
        [
            (l10n.t("console.quick.version"), "getprop ro.build.version.release"),
            (l10n.t("console.quick.disk"), "df -h /data"),
            (l10n.t("console.quick.memory"), "free -m"),
            (l10n.t("console.quick.top"), "top -n 1 | head -n 18"),
            (l10n.t("console.quick.logcat"), "logcat -d -t 30"),
        ]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(session.consoleText.isEmpty ? l10n.t("console.waiting") : session.consoleText)
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
                        ForEach(quickCommands, id: \.1) { title, cmd in
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
                    TextField(l10n.t("console.cmd_placeholder"), text: $commandInput)
                        .font(.system(size: 13, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.send)
                        .onSubmit(submitCommand)

                    Button(l10n.t("common.send"), action: submitCommand)
                        .buttonStyle(.borderedProminent)
                        .disabled(commandInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .padding(.top, 4)
            }
            .navigationTitle(l10n.t("console.title"))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                session.setConsoleSheetVisible(true)
            }
            .onDisappear {
                session.setConsoleSheetVisible(false)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            UIPasteboard.general.string = session.consoleText
                        } label: {
                            Label(l10n.t("console.copy_all"), systemImage: "doc.on.doc")
                        }
                        Button(role: .destructive) {
                            session.clearConsole()
                        } label: {
                            Label(l10n.t("console.clear"), systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(l10n.t("common.close")) { dismiss() }
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
