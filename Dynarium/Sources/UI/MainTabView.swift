// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

enum MainTab: Hashable {
    case machines
    case images
    case settings
}

struct MainTabView: View {
    @Binding var selectedTab: MainTab
    @EnvironmentObject private var session: VMRuntimeSession
    @EnvironmentObject private var l10n: AppLocalization
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $selectedTab) {
            MachinesListView(switchToImagesTab: {
                selectedTab = .images
            })
            .tabItem {
                Label(l10n.t("tab.machines"), systemImage: "desktopcomputer")
            }
            .tag(MainTab.machines)

            SystemImagesView()
                .tabItem {
                    Label(l10n.t("tab.images"), systemImage: "internaldrive")
                }
                .tag(MainTab.images)

            SettingsView()
                .tabItem {
                    Label(l10n.t("tab.settings"), systemImage: "gearshape")
                }
                .tag(MainTab.settings)
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { session.phase.isPresented },
                set: { presented in
                    if !presented {
                        session.dismissEndedSession()
                    }
                }
            )
        ) {
            VMSessionView()
        }
        .onChange(of: scenePhase) { nextPhase in
            session.handleScenePhaseChanged(nextPhase)
        }
    }
}
