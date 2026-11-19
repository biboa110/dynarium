// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

struct AboutCreditsView: View {
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Dynarium")
                        .font(.title2.bold())
                    Text("Trình quản lý và ảo hóa đa máy ảo Android 17 (LineageOS 24) dành cho iOS & iPadOS (iOS 16.0 – iOS 27+), xây dựng theo triết lý VMware với hệ thống ROM tách rời và giao diện chuẩn Apple HIG.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("Nền tảng cốt lõi & Ghi công") {
                CreditRow(
                    title: "imxieyi/Kernarium",
                    role: "Runtime cốt lõi, Linux 6.18 UML + Gadget Engine, giải pháp Anti-Jetsam & Virtio Android (GPL-2.0-or-later)",
                    urlString: "https://github.com/imxieyi/Kernarium"
                )
                CreditRow(
                    title: "ish-app/ish",
                    role: "Cảm hứng kỹ thuật threaded interpreter / Gadget execution và ánh xạ trang nhớ trên Darwin/iOS (GPL-3.0 / trích xuất hợp lệ)",
                    urlString: "https://github.com/ish-app/ish"
                )
            }

            Section("Thành phần mã nguồn mở đi kèm") {
                CreditRow(
                    title: "Linux Mainline 6.18 LTS & LineageOS 24",
                    role: "Nhân hệ điều hành và hệ thống Android 17 (4 KiB guest pages)",
                    urlString: nil
                )
                CreditRow(
                    title: "Mesa 3D (KosmicKrisp, Zink, LLVMpipe, Softpipe), virglrenderer & libepoxy",
                    role: "Đồ họa 3D Vulkan / Metal 4 và bộ dựng hình CPU an toàn trên iOS 16+",
                    urlString: nil
                )
                CreditRow(
                    title: "libslirp, GLib, libzstd & GPT fdisk",
                    role: "Mạng SLiRP thân thiện quyền riêng tư DNS iOS, giải nén Zstandard & phân vùng GPT",
                    urlString: nil
                )
            }

            Section("Giấy phép phân phối") {
                Text("Mã nguồn phần Host/Hypervisor được phát hành theo giấy phép GPL-2.0-or-later. Phần lớp phủ/cấu hình khách Android theo giấy phép Apache-2.0.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Ghi công & Nguồn mở")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct CreditRow: View {
    let title: String
    let role: String
    let urlString: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let urlString, let url = URL(string: urlString) {
                Link(destination: url) {
                    HStack {
                        Text(title)
                            .font(.headline)
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                    }
                }
            } else {
                Text(title)
                    .font(.headline)
            }
            Text(role)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
