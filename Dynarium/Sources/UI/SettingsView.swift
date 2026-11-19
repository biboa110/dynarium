// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import GuestHostCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var hardware: HostHardwareProfile
    @EnvironmentObject private var imageStore: SystemImageStore
    @EnvironmentObject private var vmStore: VirtualMachineStore
    @EnvironmentObject private var session: VMRuntimeSession

    @State private var cacheClearedAlert = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Phiên bản Dynarium") {
                        Text("v\(hardware.appVersionString) (\(hardware.buildNumberString))")
                            .monospacedDigit()
                    }
                    LabeledContent("Kiến trúc bản dựng") {
                        Text(hardware.edition.badgeTitle)
                            .foregroundStyle(Color.accentColor)
                    }
                    LabeledContent("Thiết bị / Hệ điều hành") {
                        Text("\(hardware.chipGenerationLabel) • iOS \(hardware.osVersionString)")
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("GPU hệ thống") {
                        Text(hardware.metalDeviceName)
                    }
                    LabeledContent("RAM vật lý / Trần iOS") {
                        let ceiling = hardware.availableProcessMemoryBytes > 0
                            ? Formats.size(bytes: hardware.availableProcessMemoryBytes)
                            : "Không giới hạn"
                        Text("\(Formats.size(bytes: hardware.physicalMemoryBytes)) / \(ceiling)")
                            .monospacedDigit()
                    }
                    LabeledContent("Trạng thái JIT / Debugger") {
                        Text(hardware.debuggerAttached ? "Đang gắn (JIT khả dụng)" : "Không gắn (An toàn non-JIT)")
                            .foregroundStyle(hardware.debuggerAttached ? .green : .secondary)
                    }
                } header: {
                    Text("Phiên bản & Phần cứng")
                } footer: {
                    if hardware.isMemoryEntitlementLimited {
                        Text("iOS đang giới hạn trần RAM tiến trình dưới 2.5 GiB (thường gặp khi cài qua chứng chỉ miễn phí chưa giữ quyền mở rộng RAM hoặc trên máy 4 GiB). Dynarium tự động hạ mức RAM/Retina an toàn để tránh bị hệ thống đóng đột ngột.")
                    } else if hardware.recommendsMetal4Edition {
                        Text("Thiết bị của bạn hỗ trợ iOS \(hardware.osMajorVersion) và chip Apple GPU thế hệ mới — khuyên dùng gói Dynarium Metal4-iOS26.ipa để tăng tốc đồ họa Vulkan 1.4.")
                    }
                }

                Section {
                    Button(role: .destructive) {
                        clearShaderCaches()
                        cacheClearedAlert = true
                    } label: {
                        Label("Dọn bộ nhớ đệm Shader (Mesa & Metal)", systemImage: "paintbrush")
                    }
                    .disabled(session.phase.isActive)
                } header: {
                    Text("Bảo trì & Bộ nhớ")
                } footer: {
                    Text("Xóa cache biên dịch shader giúp thu hồi dung lượng nếu bạn vừa cài nhiều ứng dụng đồ họa khác nhau. Chỉ thực hiện được khi mọi máy ảo đã tắt.")
                }

                Section("Kết nối ADB & Split APK") {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Cài đặt ứng dụng trực tiếp", systemImage: "shippingbox")
                            .font(.subheadline.weight(.semibold))
                        Text("Dynarium hỗ trợ cài trực tiếp các tệp .apk đơn lẫn gói đa thành phần (.apks, .apkm, .zip) thông qua giao thức VSOCK ADB nội bộ (cổng 5555) mà không cần dây cáp.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)

                    if let ip = LanAddress.currentIPv4() {
                        LabeledContent("Địa chỉ Wi-Fi LAN hiện tại") {
                            Text("\(ip):5555")
                                .font(.subheadline.monospaced())
                        }
                    }
                }

                Section("Thông tin & Giấy phép") {
                    NavigationLink {
                        AboutCreditsView()
                    } label: {
                        Label("Giới thiệu, Nguồn mở & Ghi công", systemImage: "doc.text")
                    }
                }
            }
            .navigationTitle("Cài đặt")
            .onAppear {
                hardware.refreshDynamicMetrics()
            }
            .alert("Đã dọn Shader Cache", isPresented: $cacheClearedAlert) {
                Button("Xong", role: .cancel) {}
            } message: {
                Text("Bộ nhớ đệm Shader của Mesa và Metal đã được làm sạch an toàn.")
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
