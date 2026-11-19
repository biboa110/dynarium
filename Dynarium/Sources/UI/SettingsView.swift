// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import GuestHostCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var hardware: HostHardwareProfile
    @EnvironmentObject private var imageStore: SystemImageStore
    @EnvironmentObject private var vmStore: VirtualMachineStore
    @EnvironmentObject private var session: VMRuntimeSession
    @EnvironmentObject private var l10n: AppLocalization

    @State private var cacheClearedAlert = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(selection: $l10n.language) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.nativeName).tag(lang)
                        }
                    } label: {
                        Label(l10n.t("settings.language.title"), systemImage: "globe")
                    }
                } header: {
                    Text(l10n.t("settings.language.section"))
                } footer: {
                    Text(l10n.t("settings.language.footer"))
                }

                Section {
                    LabeledContent(l10n.t("settings.hw.version")) {
                        Text("v\(hardware.appVersionString) (\(hardware.buildNumberString))")
                            .monospacedDigit()
                    }
                    LabeledContent(l10n.t("settings.hw.edition")) {
                        Text(hardware.edition.badgeTitle)
                            .foregroundStyle(Color.accentColor)
                    }
                    LabeledContent(l10n.t("settings.hw.device_os")) {
                        Text("\(hardware.chipGenerationLabel) • iOS \(hardware.osVersionString)")
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent(l10n.t("settings.hw.gpu")) {
                        Text(hardware.metalDeviceName)
                    }
                    LabeledContent(l10n.t("settings.hw.ram")) {
                        let ceiling = hardware.availableProcessMemoryBytes > 0
                            ? Formats.size(bytes: hardware.availableProcessMemoryBytes)
                            : l10n.t("common.unlimited")
                        Text("\(Formats.size(bytes: hardware.physicalMemoryBytes)) / \(ceiling)")
                            .monospacedDigit()
                    }
                    LabeledContent(l10n.t("settings.hw.jit")) {
                        Text(hardware.debuggerAttached ? l10n.t("settings.hw.jit_attached") : l10n.t("settings.hw.jit_none"))
                            .foregroundStyle(hardware.debuggerAttached ? .green : .secondary)
                    }
                    LabeledContent(l10n.t("settings.hw.eva")) {
                        Text(hardware.hasExtendedVirtualAddressing ? l10n.t("common.enabled") : l10n.t("settings.hw.eva_missing"))
                            .foregroundStyle(hardware.hasExtendedVirtualAddressing ? .green : .orange)
                    }
                } header: {
                    Text(l10n.t("settings.section.hardware"))
                } footer: {
                    if hardware.isMemoryEntitlementLimited {
                        Text(l10n.t("settings.hw.footer_ram_limited"))
                    } else if hardware.recommendsMetal4Edition {
                        Text(l10n.f("settings.hw.footer_metal4_rec", String(hardware.osMajorVersion)))
                    }
                }

                Section {
                    Button(role: .destructive) {
                        clearShaderCaches()
                        cacheClearedAlert = true
                    } label: {
                        Label(l10n.t("settings.maintenance.clear_cache"), systemImage: "paintbrush")
                    }
                    .disabled(session.phase.isActive)
                } header: {
                    Text(l10n.t("settings.section.maintenance"))
                } footer: {
                    Text(l10n.t("settings.maintenance.footer"))
                }

                Section(l10n.t("settings.section.adb")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(l10n.t("settings.adb.direct_title"), systemImage: "shippingbox")
                            .font(.subheadline.weight(.semibold))
                        Text(l10n.t("settings.adb.direct_body"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)

                    if let ip = LanAddress.currentIPv4() {
                        LabeledContent(l10n.t("settings.adb.lan_ip")) {
                            Text("\(ip):5555")
                                .font(.subheadline.monospaced())
                        }
                    }
                }

                Section(l10n.t("settings.section.about")) {
                    NavigationLink {
                        AboutCreditsView()
                    } label: {
                        Label(l10n.t("settings.about.link"), systemImage: "doc.text")
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(l10n.t("settings.jit.trollstore_title"), systemImage: "bolt.shield")
                            .font(.subheadline.weight(.semibold))
                        Text(l10n.t("settings.jit.trollstore_body"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)

                    VStack(alignment: .leading, spacing: 6) {
                        Label(l10n.t("settings.jit.stik_title"), systemImage: "terminal")
                            .font(.subheadline.weight(.semibold))
                        Text(l10n.t("settings.jit.stik_body"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text(l10n.t("settings.section.jit_guide"))
                }
            }
            .navigationTitle(l10n.t("settings.nav.title"))
            .onAppear {
                hardware.refreshDynamicMetrics()
            }
            .alert(l10n.t("settings.alert.cache_cleared_title"), isPresented: $cacheClearedAlert) {
                Button(l10n.t("common.done"), role: .cancel) {}
            } message: {
                Text(l10n.t("settings.alert.cache_cleared_body"))
            }
        }
    }

    private func clearShaderCaches() {
        guard let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let bundleID = Bundle.main.bundleIdentifier else { return }
        let appCache = cacheRoot.appendingPathComponent(bundleID, isDirectory: true)
        try? FileManager.default.removeItem(at: appCache.appendingPathComponent("mesa_shader_cache", isDirectory: true))
        try? FileManager.default.removeItem(at: appCache.appendingPathComponent("com.apple.metal", isDirectory: true))
    }
}
