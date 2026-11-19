# Dynarium

A clean, lightweight **Multi-VM Android Hypervisor** for iPhone and iPad (**iOS 16.0 – iOS 27+**) powered by **User-Mode Linux (Mainline 6.18 LTS)** and the **Gadget Engine**.

Dynarium builds upon [`imxieyi/Kernarium`](https://github.com/imxieyi/Kernarium) with a VMware-style multi-instance workflow: keep your `.ipa` compact, install or import Android 17 (LineageOS 24) system images on demand, clone VMs instantaneously with APFS copy-on-write, install standard `.apk` or split `.apks`/`.apkm` bundles over built-in VSOCK ADB, and run long-lived AFK sessions cleanly with Picture-in-Picture and Eco throttling.

## Release Editions

Every versioned GitHub Release publishes two unsigned/sideload-ready `.ipa` packages (`ldid`-entitled for increased memory limit and extended virtual addressing):

- **`Dynarium-v<version>.ipa` (`iOS 16.0+` Universal):** Works across iOS 16, 17, 18, 26, and 27+ (AltStore, SideStore, TrollStore). Defaults safely to `GALLIUM_DRIVER=softpipe` on non-JIT devices and upgrades automatically to `llvmpipe` when JIT/debugger access is active.
- **`Dynarium-v<version>-Metal4-iOS26.ipa` (`iOS 26.0+` Metal 4):** Hardware-accelerated Vulkan 1.4 / GLES 3.2 stack powered by **`KosmicKrisp` + `Mesa Zink`** for iOS 26.0+ on A14/M1 and newer Apple Silicon.

## Key Capabilities

- **VMware-Style ROM & Multi-VM Management:** Keep `.ipa` downloads lightweight. Download the upstream LineageOS 24 image in one tap, fetch from a custom URL, or import `.tar.gz`/`.tar.zst`/`.tar` bundles from Files with streaming sparse extraction (`F_PUNCHHOLE`) and SHA-256 layout verification. Share one read-only `system.img` across VMs and clone VMs cleanly with APFS `clonefile`.
- **Smart Hardware Profile & Anti-Jetsam Protection:** Reads host chip and process memory ceiling (`kernarium_runtime_loader_*`), enforces GPU budget limits ($B = \max(L - A - G - E - S,\; 384\text{ MiB})$), and guards low storage (`RunSpace` / `SpacePauser`).
- **Hybrid APK & Split-APK Installer:** Built-in VSOCK (`port 5555`) ADB client with per-VM RSA-2048 Keychain credentials supporting `.apk` and multi-split `.apks`/`.apkm`/`.zip` archives, interactive serial console, and optional ADB-over-LAN forwarding.
- **AFK & Picture-in-Picture Suite:** iOS 16.0+-compatible `AVPictureInPictureController` (`AVSampleBufferDisplayLayer`) alongside **AFK Eco Mode** (`set_background_throttle`, `set_page_cache_trimming`, and True Black `#000000` OLED overlay).
- **Pure Apple HIG Interface:** Native semantic system colors, `SF Pro` / `SF Mono`, `SF Symbols`, `.insetGrouped` lists, Light/Dark mode, Dynamic Type, and iPadOS windowing (`GuestResizeHold`).

## Building on macOS (XcodeGen)

1. Populate `.build/dependencies` from the `deps-ios16-latest` pre-release (or build via `dependencies/build-ios-*.sh` and `dependencies/build-apple-gpu.sh`).
2. Configure and build `KernariumRuntime` (`cmake --preset kernarium-ios-device-android && cmake --build --preset kernarium-ios-device-android`).
3. Package XCFrameworks (`./Dynarium/scripts/package-dynarium-frameworks.sh --tier ios16-universal`).
4. Generate the Xcode project from `Dynarium/project.yml` (`cd Dynarium && xcodegen generate`) and archive/package with `./Dynarium/scripts/package-ipa.sh`.

For automated cloud builds on push / manual dispatch, see [`.github/workflows/build-deps.yml`](.github/workflows/build-deps.yml) and [`.github/workflows/build-ipa.yml`](.github/workflows/build-ipa.yml).

## Repository Map

- [`PLAN.md`](PLAN.md) — Competitive analysis, dual-edition strategy, and 5-phase engineering roadmap.
- [`AGENTS.md`](AGENTS.md) — Workspace guardrails, Windows LF rules, and Darwin invariants.
- [`CREDITS.md`](CREDITS.md) — Attribution to [`imxieyi/Kernarium`](https://github.com/imxieyi/Kernarium), [`ish-app/ish`](https://github.com/ish-app/ish), and open-source dependencies.
- `Dynarium/` — XcodeGen specification, SwiftUI/UIKit Multi-VM app sources, Config/entitlements, and packaging scripts.
- `darwin/`, `dependencies/`, `cmake/`, `scripts/` — Core hypervisor engine, dependency manifests, and verification audits.

## Attribution & License

Dynarium builds directly on [`imxieyi/Kernarium`](https://github.com/imxieyi/Kernarium) (by Yi Xie) and draws interpreter inspiration from [`ish-app/ish`](https://github.com/ish-app/ish). See [`CREDITS.md`](CREDITS.md) for complete notices.

Licensed under **`GPL-2.0-or-later`** ([`LICENSE`](LICENSE)), except where individual components carry their own `SPDX-License-Identifier` (such as **`Apache-2.0`** for Android guest overlay/tree code). See [`LICENSES/`](LICENSES/).
