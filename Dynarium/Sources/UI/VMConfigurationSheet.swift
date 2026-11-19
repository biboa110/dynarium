// SPDX-License-Identifier: GPL-2.0-or-later

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

    @State private var config: VirtualMachineConfig

    init(mode: Mode, initialConfig: VirtualMachineConfig) {
        self.mode = mode
        _config = State(initialValue: initialConfig)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Thông tin chung") {
                    TextField("Tên máy ảo", text: $config.name)
                        .textInputAutocapitalization(.words)

                    Picker("Hệ điều hành (ROM)", selection: $config.systemImageID) {
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
                        PresetPillButton(title: "Tiết kiệm RAM", icon: "leaf") {
                            let targetVCPUs = min(2, hardware.maxVCPUs)
                            let safeRAM = hardware.safeRecommendedMemoryMiB(for: targetVCPUs)
                            let maxAllowed = max(minRAM, hardware.maximumMemoryMiB(vcpus: targetVCPUs))
                            config.vcpuCount = targetVCPUs
                            config.guestMemoryMiB = min(max(min(safeRAM, 896), minRAM), maxAllowed)
                            config.retinaDisplay = false
                            config.thermalSaverEnabled = true
                        }
                        PresetPillButton(title: "Khuyên dùng", icon: "checkmark.shield") {
                            let targetVCPUs = hardware.defaultVCPUs()
                            config.vcpuCount = targetVCPUs
                            config.guestMemoryMiB = hardware.safeRecommendedMemoryMiB(for: targetVCPUs)
                            config.retinaDisplay = hardware.defaultRetinaDisplay()
                            config.thermalSaverEnabled = false
                        }
                        PresetPillButton(title: "Hiệu năng", icon: "speedometer") {
                            let targetVCPUs = min(max(2, hardware.maxVCPUs / 2), hardware.maxVCPUs)
                            let maxAllowed = max(minRAM, hardware.maximumMemoryMiB(vcpus: targetVCPUs))
                            let perfRAM = min(max(hardware.conservativeMemoryMiB(vcpus: targetVCPUs), hardware.safeRecommendedMemoryMiB(for: targetVCPUs)), maxAllowed)
                            config.vcpuCount = targetVCPUs
                            config.guestMemoryMiB = perfRAM
                            config.retinaDisplay = (hardware.edition == .metal4Vulkan)
                            config.thermalSaverEnabled = false
                        }
                    }
                    .padding(.vertical, 2)

                    Stepper(value: $config.vcpuCount, in: 1...max(1, hardware.maxVCPUs)) {
                        LabeledContent("Số nhân CPU (vCPU)") {
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
                            Text("RAM máy ảo")
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
                            Text("Ngân sách GPU: \(Formats.size(mib: gpuEval.budgetMiB))")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(gpuEval.shortOfFloor ? .orange : .secondary)
                            Spacer()
                            if config.guestMemoryMiB != recRAM {
                                Button("Dùng mức đề xuất (\(Formats.size(mib: recRAM)))") {
                                    config.guestMemoryMiB = recRAM
                                }
                                .font(.caption)
                            }
                        }
                        if gpuEval.shortOfFloor {
                            Text("Cảnh báo Anti-Jetsam: Mức RAM này để lại quá ít bộ nhớ cho GPU/hệ thống, iOS có thể đóng tiến trình đột ngột.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    Stepper(value: $config.dataDiskGiB, in: 4...128, step: 4) {
                        LabeledContent("Dung lượng ổ Data tối đa") {
                            Text("\(config.dataDiskGiB) GiB")
                                .monospacedDigit()
                        }
                    }
                } header: {
                    Text("Tài nguyên phần cứng (Smart Profile)")
                } footer: {
                    Text("Ổ Data dùng định dạng thưa APFS: chỉ chiếm dung lượng thật theo dữ liệu Android ghi vào (không thể thu nhỏ sau khi tạo).")
                }

                Section("Đồ họa & Khởi động") {
                    Picker("Chế độ khởi động", selection: $config.bootMode) {
                        ForEach(VMBootMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    Toggle("Màn hình Retina sắc nét", isOn: $config.retinaDisplay)
                    if config.retinaDisplay && hardware.edition == .universalSoftware {
                        Text("Lưu ý: Dựng hình CPU trên bản Universal ở chế độ Retina tốn gấp 9 lần điểm ảnh và RAM, dễ gây chậm hoặc bị iOS đóng tiến trình.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Toggle("Tự khớp kích thước màn hình", isOn: $config.autoResizeDisplay)

                    if hardware.edition == .universalSoftware {
                        Picker("Bộ dựng hình CPU", selection: $config.softwareBackend) {
                            ForEach(PreferredSoftwareBackend.allCases) { backend in
                                Text(backend.displayName).tag(backend)
                            }
                        }
                        Toggle("Ưu tiên JIT (khi có Debugger/TrollStore)", isOn: $config.preferJitIfAvailable)
                    } else {
                        LabeledContent("Tăng tốc đồ họa") {
                            Text("KosmicKrisp + Zink (Metal 4)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Thiết bị & AFK Chạy nền") {
                    Toggle("Bật Micro cho Android", isOn: $config.microphoneEnabled)
                    Toggle("Tự mở ADB qua Wi-Fi (cổng 5555)", isOn: $config.adbOverLan)

                    Picker("Tốc độ khung hình PiP / AFK", selection: $config.afkFrameRateLimit) {
                        Text("5 FPS (Tiết kiệm pin tối đa)").tag(5)
                        Text("10 FPS (Cân bằng)").tag(10)
                        Text("15 FPS (Mượt)").tag(15)
                    }

                    Toggle("Màn đen OLED khi bật AFK Eco Mode", isOn: $config.afkBlackoutEnabled)
                    Toggle("Chế độ Mát máy (Giảm tải CPU & tiết kiệm pin)", isOn: $config.thermalSaverEnabled)
                }
            }
            .navigationTitle(mode == .create ? "Tạo máy ảo mới" : "Cấu hình máy ảo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Hủy") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(mode == .create ? "Tạo" : "Lưu") {
                        var finalCfg = config
                        let trimmed = finalCfg.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        finalCfg.name = trimmed.isEmpty ? "Android VM" : trimmed
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
