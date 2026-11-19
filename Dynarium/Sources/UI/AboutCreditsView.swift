// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

struct AboutCreditsView: View {
    @EnvironmentObject private var l10n: AppLocalization

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 14) {
                        Image("BrandMark")
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Dynarium")
                                .font(.title2.bold())
                            Text(l10n.t("credits.subtitle"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(l10n.t("credits.summary"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }

            Section(l10n.t("credits.section.core")) {
                CreditRow(
                    title: "imxieyi/Kernarium",
                    role: l10n.t("credits.kernarium.role"),
                    urlString: "https://github.com/imxieyi/Kernarium"
                )
                CreditRow(
                    title: "ish-app/ish",
                    role: l10n.t("credits.ish.role"),
                    urlString: "https://github.com/ish-app/ish"
                )
            }

            Section(l10n.t("credits.section.oss")) {
                CreditRow(
                    title: "Linux Mainline 6.18 LTS & LineageOS 24",
                    role: l10n.t("credits.linux.role"),
                    urlString: nil
                )
                CreditRow(
                    title: "Mesa 3D (KosmicKrisp, Zink, LLVMpipe, Softpipe), virglrenderer & libepoxy",
                    role: l10n.t("credits.mesa.role"),
                    urlString: nil
                )
                CreditRow(
                    title: "libslirp, GLib, libzstd & GPT fdisk",
                    role: l10n.t("credits.slirp.role"),
                    urlString: nil
                )
            }

            Section(l10n.t("credits.section.license")) {
                Text(l10n.t("credits.license.body"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(l10n.t("credits.nav.title"))
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
