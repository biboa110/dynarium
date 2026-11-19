// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

struct FloatingSessionHUD: View {
    @Binding var collapsed: Bool
    @Binding var presentingConsole: Bool
    @Binding var presentingStats: Bool
    @Binding var presentingApkImporter: Bool
    @Binding var confirmingShutdown: Bool

    @EnvironmentObject private var session: VMRuntimeSession
    @ObservedObject private var pip = VMRuntimeSession.shared.pipController

    var body: some View {
        VStack {
            Spacer()
            if collapsed {
                HStack {
                    Spacer()
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                            collapsed = false
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(session.phase.isActive ? Color.green : Color.orange)
                                .frame(width: 8, height: 8)
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
                    }
                }
                .padding(.trailing, 14)
                .padding(.bottom, 14)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        HUDButton(icon: "chevron.backward", label: "Back") {
                            session.sendHardwareKey(158) // KEY_BACK
                        }
                        HUDButton(icon: "circle", label: "Home") {
                            session.sendHardwareKey(172) // KEY_HOMEPAGE
                        }
                        HUDButton(icon: "power", label: "Nguồn") {
                            session.sendHardwareKey(116) // KEY_POWER
                        }

                        Divider().frame(height: 22)

                        HUDButton(
                            icon: session.keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard",
                            label: "Phím",
                            active: session.keyboardVisible
                        ) {
                            session.keyboardVisible.toggle()
                        }

                        HUDButton(icon: "square.and.arrow.down.on.square", label: "Cài APK") {
                            presentingApkImporter = true
                        }

                        if pip.isSupported {
                            HUDButton(
                                icon: pip.isActive ? "pip.exit" : "pip.enter",
                                label: "PiP",
                                active: pip.isActive
                            ) {
                                session.togglePiP()
                            }
                        }

                        HUDButton(
                            icon: session.afkEcoMode ? "moon.fill" : "moon",
                            label: "AFK Eco",
                            active: session.afkEcoMode
                        ) {
                            session.setAfkEcoMode(!session.afkEcoMode)
                        }

                        Divider().frame(height: 22)

                        Menu {
                            Button {
                                presentingStats = true
                            } label: {
                                Label("Thông số CPU / RAM / GPU", systemImage: "gauge.medium")
                            }

                            Button {
                                presentingConsole = true
                            } label: {
                                Label("Cửa sổ Serial Console", systemImage: "terminal")
                            }

                            Button {
                                session.setMicrophone(!session.microphoneOn)
                            } label: {
                                Label(
                                    session.microphoneOn ? "Tắt Micro Android" : "Bật Micro Android",
                                    systemImage: session.microphoneOn ? "mic.fill" : "mic.slash"
                                )
                            }

                            Button {
                                session.setAdbOverLan(enabled: session.adbLanAddress == nil)
                            } label: {
                                Label(
                                    session.adbLanAddress == nil ? "Bật ADB qua Wi-Fi" : "Tắt ADB Wi-Fi (\(session.adbLanAddress ?? ""))",
                                    systemImage: "wifi"
                                )
                            }

                            Button {
                                session.sendHardwareKey(115) // KEY_VOLUMEUP
                            } label: {
                                Label("Tăng âm lượng", systemImage: "speaker.plus")
                            }

                            Button {
                                session.sendHardwareKey(114) // KEY_VOLUMEDOWN
                            } label: {
                                Label("Giảm âm lượng", systemImage: "speaker.minus")
                            }

                            Divider()

                            Button(role: .destructive) {
                                confirmingShutdown = true
                            } label: {
                                Label("Tắt máy ảo", systemImage: "power")
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "ellipsis.circle")
                                    .font(.system(size: 16, weight: .semibold))
                                Text("Thêm")
                                    .font(.caption.weight(.medium))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Color.white.opacity(0.08), in: Capsule())
                        }

                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                                collapsed = true
                            }
                        } label: {
                            Image(systemName: "chevron.down.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.leading, 2)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
    }
}

private struct HUDButton: View {
    let icon: String
    let label: String
    var active: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(active ? Color.accentColor : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                active ? Color.accentColor.opacity(0.16) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }
}
