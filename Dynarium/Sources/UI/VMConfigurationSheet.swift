// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import GuestHostCore
import SwiftUI

struct VMConfigurationSheet: View {
    enum Mode {
        case create
        case edit
    }

    let mode: Mode

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var hardware: HostHardwareProfile
    @EnvironmentObject private var imageStore: SystemImageStore
    @EnvironmentObject private var vmStore: VirtualMachineStore
    @EnvironmentObject private var l10n: AppLocalization

    @State private var config: VirtualMachineConfig

    init(mode: Mode, initialConfig: VirtualMachineConfig) {
        self.mode = mode
        _config = State(initialValue: initialConfig)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(l10n.t("vmcfg.section.general")) {
                    TextField(l10n.t("vmcfg.field.name"), text: $config.name)
                        .textInputAutocapitalization(.words)

                    Picker(l10n.t("vmcfg.field.rom"), selection: $config.systemImageID) {
                        ForEach(imageStore.images) { img in
                            Text("\(img.name) (Android \(img.androidMajor))").tag(img.id)
                        }
                    }
                }

                let minRAM = hardware.minimumMemoryMiB()
                let maxRAM = max(minRAM, hardware.maximumMemoryMiB(vcpus: config.vcpuCount))
                let recRAM = hardware.recommendedMemoryMiB(for: config.vcpuCount)
                let gpuEval = hardware.evaluateGpuBudget(memoryMiB: config.guestMemoryMiB, vcpus: config.vcpuCount)

                Section {
                    HStack(spacing: 8) {
                        PresetPillButton(title: l10n.t("vmcfg.preset.eco"), icon: "leaf") {
                            let targetVCPUs = min(2, hardware.maxVCPUs)
                            let safeRAM = hardware.safeRecommendedMemoryMiB(for: targetVCPUs)
                            let maxAllowed = max(minRAM, hardware.maximumMemoryMiB(vcpus: targetVCPUs))
                            config.vcpuCount = targetVCPUs
                            config.guestMemoryMiB = min(max(min(safeRAM, 896), minRAM), maxAllowed)
                            config.displayQuality = .economy
                            config.retinaDisplay = false
                            config.targetDisplayFPS = 60
                            config.thermalSaverEnabled = true
                            config.fastUiMode = true
                            config.preloadRenderer = false
                        }
                        PresetPillButton(title: l10n.t("vmcfg.preset.recommended"), icon: "checkmark.shield") {
                            let targetVCPUs = hardware.defaultVCPUs()
                            let quality = hardware.defaultDisplayQuality()
                            config.vcpuCount = targetVCPUs
                            config.guestMemoryMiB = hardware.safeRecommendedMemoryMiB(for: targetVCPUs)
                            config.displayQuality = quality
                            config.retinaDisplay = (quality == .retina)
                            config.targetDisplayFPS = 60
                            config.thermalSaverEnabled = false
                            config.fastUiMode = true
                            config.preloadRenderer = hardware.defaultPreloadRenderer()
                        }
                        PresetPillButton(title: l10n.t("vmcfg.preset.performance"), icon: "speedometer") {
                            let targetVCPUs = min(max(2, hardware.maxVCPUs / 2), hardware.maxVCPUs)
                            let maxAllowed = max(minRAM, hardware.maximumMemoryMiB(vcpus: targetVCPUs))
                            let perfRAM = min(max(hardware.conservativeMemoryMiB(vcpus: targetVCPUs), hardware.safeRecommendedMemoryMiB(for: targetVCPUs)), maxAllowed)
                            let perfQuality: VMDisplayQuality = (hardware.edition == .metal4Vulkan) ? .retina : .balanced
                            config.vcpuCount = targetVCPUs
                            config.guestMemoryMiB = perfRAM
                            config.displayQuality = perfQuality
                            config.retinaDisplay = (perfQuality == .retina)
                            config.targetDisplayFPS = hardware.maxDisplayRefreshRate >= 120 ? 120 : 60
                            config.thermalSaverEnabled = false
                            config.fastUiMode = true
                            config.preloadRenderer = (hardware.edition == .metal4Vulkan)
                        }
                    }
                    .padding(.vertical, 2)

                    Stepper(value: $config.vcpuCount, in: 1...max(1, hardware.maxVCPUs)) {
                        LabeledContent(l10n.t("vmcfg.vcpu")) {
                            Text("\(config.vcpuCount) / \(hardware.maxVCPUs)")
                                .monospacedDigit()
                        }
                    }
                    .onChange(of: config.vcpuCount) { newVCPUs in
                        let newMax = hardware.maximumMemoryMiB(vcpus: newVCPUs)
                        if config.guestMemoryMiB > newMax {
                            config.guestMemoryMiB = max(minRAM, newMax)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(l10n.t("vmcfg.ram"))
                            Spacer()
                            Text(Formats.size(mib: config.guestMemoryMiB))
                                .fontWeight(.semibold)
                                .monospacedDigit()
                        }
                        if maxRAM > minRAM {
                            Slider(
                                value: Binding(
                                    get: { Double(min(max(config.guestMemoryMiB, minRAM), maxRAM)) },
                                    set: { val in
                                        let stepped = Int((val / 64.0).rounded()) * 64
                                        config.guestMemoryMiB = min(max(stepped, minRAM), maxRAM)
                                    }
                                ),
                                in: Double(minRAM)...Double(maxRAM),
                                step: 64
                            )
                        }
                        HStack {
                            Text(l10n.f("vmcfg.gpu_budget", Formats.size(mib: gpuEval.budgetMiB)))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(gpuEval.shortOfFloor ? .orange : .secondary)
                            Spacer()
                            if config.guestMemoryMiB != recRAM {
                                Button(l10n.f("vmcfg.use_recommended", Formats.size(mib: recRAM))) {
                                    config.guestMemoryMiB = recRAM
                                }
                                .font(.caption)
                            }
                        }
                        if gpuEval.shortOfFloor {
                            Text(l10n.t("vmcfg.jetsam_warning"))
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    Stepper(value: $config.dataDiskGiB, in: 4...128, step: 4) {
                        LabeledContent(l10n.t("vmcfg.data_disk")) {
                            Text("\(config.dataDiskGiB) GiB")
                                .monospacedDigit()
                        }
                    }
                } header: {
                    Text(l10n.t("vmcfg.section.hardware"))
                } footer: {
                    Text(l10n.t("vmcfg.section.hardware_footer"))
                }

                Section(l10n.t("vmcfg.section.graphics")) {
                    Picker(l10n.t("vmcfg.boot_mode"), selection: $config.bootMode) {
                        ForEach(VMBootMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    Picker(l10n.t("vmcfg.display_quality"), selection: Binding(
                        get: { config.displayQuality },
                        set: { nextQuality in
                            config.displayQuality = nextQuality
                            config.retinaDisplay = (nextQuality == .retina)
                        }
                    )) {
                        ForEach(VMDisplayQuality.allCases) { quality in
                            Text(quality.displayName).tag(quality)
                        }
                    }
                    if config.displayQuality == .economy {
                        Text(l10n.t("vmcfg.quality.economy_note"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if config.displayQuality == .retina && hardware.edition == .universalSoftware {
                        Text(l10n.t("vmcfg.quality.retina_universal_warn"))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Toggle(l10n.t("vmcfg.auto_resize"), isOn: $config.autoResizeDisplay)
                    Toggle(l10n.t("vmcfg.fast_ui"), isOn: $config.fastUiMode)

                    if hardware.edition == .universalSoftware {
                        Picker(l10n.t("vmcfg.cpu_renderer"), selection: $config.softwareBackend) {
                            ForEach(PreferredSoftwareBackend.allCases) { backend in
                                Text(backend.displayName).tag(backend)
                            }
                        }
                    } else {
                        LabeledContent(l10n.t("vmcfg.gpu_accel")) {
                            Text(l10n.t("vmcfg.gpu_accel_value"))
                                .foregroundStyle(.secondary)
                        }
                        Toggle(l10n.t("vmcfg.preload_renderer"), isOn: $config.preloadRenderer)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Picker(l10n.t("vmcfg.refresh_rate"), selection: $config.targetDisplayFPS) {
                            Text(l10n.t("vmcfg.refresh_rate.60")).tag(60)
                            if hardware.maxDisplayRefreshRate >= 90 {
                                Text(l10n.t("vmcfg.refresh_rate.90")).tag(90)
                            }
                            if hardware.maxDisplayRefreshRate >= 120 {
                                Text(l10n.t("vmcfg.refresh_rate.120")).tag(120)
                            }
                        }
                        Text(l10n.f("vmcfg.refresh_rate.note", String(hardware.maxDisplayRefreshRate)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(l10n.t("vmcfg.prefer_jit"), isOn: $config.preferJitIfAvailable)
                        Text(l10n.t("vmcfg.prefer_jit.note"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Toggle(l10n.t("vmcfg.mic"), isOn: $config.microphoneEnabled)
                    Toggle(l10n.t("vmcfg.adb_lan"), isOn: $config.adbOverLan)

                    Picker(l10n.t("vmcfg.pip_fps"), selection: $config.afkFrameRateLimit) {
                        Text(l10n.t("vmcfg.pip_fps.5")).tag(5)
                        Text(l10n.t("vmcfg.pip_fps.10")).tag(10)
                        Text(l10n.t("vmcfg.pip_fps.15")).tag(15)
                        Text(l10n.t("vmcfg.pip_fps.30")).tag(30)
                    }

                    Toggle(l10n.t("vmcfg.afk_blackout"), isOn: $config.afkBlackoutEnabled)
                    Toggle(l10n.t("vmcfg.cool_mode"), isOn: $config.thermalSaverEnabled)
                } header: {
                    Text(l10n.t("vmcfg.section.device_afk"))
                } footer: {
                    Text(l10n.t("vmcfg.section.device_afk_footer"))
                }
            }
            .navigationTitle(mode == .create ? l10n.t("vmcfg.title.create") : l10n.t("vmcfg.title.edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(l10n.t("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(mode == .create ? l10n.t("common.create") : l10n.t("common.save")) {
                        var finalCfg = config
                        let trimmed = finalCfg.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        finalCfg.name = trimmed.isEmpty ? l10n.t("vmcfg.default_vm_name") : trimmed
                        vmStore.save(finalCfg)
                        dismiss()
                    }
                    .disabled(imageStore.images.isEmpty)
                }
            }
        }
    }
}

private struct PresetPillButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity, minHeight: 46)
            .padding(.horizontal, 6)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
