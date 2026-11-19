// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import SwiftUI

@main
struct DynariumApp: App {
    @StateObject private var hardware = HostHardwareProfile.shared
    @StateObject private var imageStore = SystemImageStore.shared
    @StateObject private var vmStore = VirtualMachineStore.shared
    @StateObject private var session = VMRuntimeSession.shared
    @StateObject private var localization = AppLocalization.shared

    @State private var selectedTab: MainTab = .machines
    @State private var incomingNotice: String?

    init() {
        // Must configure Mesa & prune bloated Metal shader caches before any Metal/GPU initialization.
        MetalShaderCache.removeIfBloatedBeforeFirstUse()
        MesaShaderCache.configureBeforeFirstUse()
        HostHardwareProfile.configureProcessEnvironmentBeforeFirstUse()
    }

    var body: some Scene {
        WindowGroup {
            MainTabView(selectedTab: $selectedTab)
                .environmentObject(hardware)
                .environmentObject(imageStore)
                .environmentObject(vmStore)
                .environmentObject(session)
                .environmentObject(localization)
                .environment(\.locale, localization.locale)
                .onOpenURL { url in
                    handleIncomingFile(url)
                }
                .alert(
                    localization.t("app.import.alert_title"),
                    isPresented: Binding(
                        get: { incomingNotice != nil },
                        set: { if !$0 { incomingNotice = nil } }
                    )
                ) {
                    Button(localization.t("common.ok"), role: .cancel) { incomingNotice = nil }
                } message: {
                    Text(incomingNotice ?? "")
                }
        }
    }

    private func handleIncomingFile(_ url: URL) {
        let lower = url.lastPathComponent.lowercased()
        if lower.hasSuffix(".apk") || lower.hasSuffix(".apks") || lower.hasSuffix(".apkm") || lower.hasSuffix(".xapk") || lower.hasSuffix(".zip") {
            if let vm = session.activeVM, session.phase.isActive {
                session.installer.install(fileURL: url, vmID: vm.id, clock: session.adbClock)
            } else {
                incomingNotice = localization.f("app.import.need_running_vm", url.lastPathComponent)
            }
            return
        }
        if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") || lower.hasSuffix(".tar.zst")
            || lower.hasSuffix(".tzst") || lower.hasSuffix(".tar") || lower.hasSuffix(".zst") {
            selectedTab = .images
            imageStore.importLocalArchive(at: url)
            return
        }
        incomingNotice = localization.f("app.import.unrecognized_format", url.lastPathComponent)
    }
}
