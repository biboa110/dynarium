<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/dynarium-logo-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs/assets/dynarium-logo-light.svg">
    <img alt="Dynarium — Android 17 Virtual Machines on iOS" src="docs/assets/dynarium-logo-light.svg" width="460">
  </picture>
</p>

<p align="center">
  <a href="https://github.com/userlethekhoi/dynarium/releases"><img alt="Latest Release" src="https://img.shields.io/github/v/release/userlethekhoi/dynarium?style=flat-square&color=22B867"></a>
  <img alt="iOS 16.0 – 27+" src="https://img.shields.io/badge/iOS-16.0%20--%2027%2B-111318?style=flat-square">
  <a href="LICENSE"><img alt="License: GPL-2.0-or-later" src="https://img.shields.io/badge/License-GPL--2.0--or--later-303C4E?style=flat-square"></a>
</p>

<p align="center">
  <strong>English</strong> ·
  <a href="docs/i18n/README.vi.md">Tiếng Việt</a> ·
  <a href="docs/i18n/README.zh-CN.md">简体中文</a> ·
  <a href="docs/i18n/README.ja.md">日本語</a> ·
  <a href="docs/i18n/README.ko.md">한국어</a> ·
  <a href="docs/i18n/README.es.md">Español</a>
</p>

---

Dynarium is a multi-VM Android hypervisor for iPhone and iPad (**iOS 16.0 through iOS 27+**). It runs **Android 17 (LineageOS 24)** directly on User-Mode Linux (`6.18 LTS`) and the Gadget Engine built in [`imxieyi/Kernarium`](https://github.com/imxieyi/Kernarium).

Instead of shipping a fixed ~1 GB disk image inside the `.ipa`, Dynarium works like VMware: install a small app binary (~22–38 MiB), pull or import Android system images whenever you need them, and run multiple isolated VMs sharing the same read-only `system.img` through APFS copy-on-write cloning (`clonefile`).

## Download & Edition Guide

Every GitHub Release ships two unsigned, sideload-ready `.ipa` packages (`ldid`-signed with increased-memory-limit and extended-virtual-addressing entitlements):

| Package | Target Devices | Graphics Backend | Download Size |
| :--- | :--- | :--- | :--- |
| `Dynarium-v<version>-Metal4-iOS26.ipa` | **Recommended for iOS 26 / 27+** (A14 / M1 and newer) | Hardware Vulkan 1.4 / GLES 3.2 (`KosmicKrisp + Mesa Zink`) | ~22 MiB |
| `Dynarium-v<version>.ipa` | **iOS 16.0 – 27+ Universal** (all Apple Silicon devices) | CPU `Mesa softpipe` (`DRAW_USE_LLVM=0`, no JIT needed); auto-switches to `llvmpipe` when JIT is attached | ~38 MiB |

Get both builds and `SHA256SUMS.txt` on the [Releases page](https://github.com/userlethekhoi/dynarium/releases).

## Quick Start

1. Sideload the `.ipa` for your iOS version via **TrollStore**, **AltStore**, or **SideStore**.
2. Open the **ROMs (Kho ROM)** tab to download LineageOS 24 (Android 17) in one tap, fetch from a custom `.tar.gz`/`.tar.zst` URL, or import a local archive from Files.
3. Open **VMs (Máy ảo)**, tap **+** to create an instance (CPU, RAM, and display scaling are pre-tuned from `os_proc_available_memory()`), then hit Play.
4. Use the floating bottom HUD while running to open Serial Console, switch keyboard input, install `.apk` or split `.apks`/`.apkm` bundles, toggle Picture-in-Picture, or turn on **AFK Eco Mode**.

## What It Does

- **Separated ROMs & Instant APFS Clone:** Extracts `.tar.gz`, `.tar.zst`, and `.tar` images with streaming sparse hole skipping (`F_PUNCHHOLE`) and SHA-256 verification. Multiple VMs share one read-only `system.img`, and cloning an existing VM uses APFS `clonefile` so copies take near-zero extra disk space at first.
- **Anti-Jetsam Memory Tuning:** Queries the real process memory limit at launch and adjusts guest RAM, vCPU count, and 1x vs Retina resolution automatically. Before starting an oversized VM config, Dynarium warns you and lets you apply safe settings in one tap.
- **Live Boot Progress & Crash Diagnosis:** Shows the four kernel/Android startup stages with an elapsed timer instead of leaving a blank screen while `data.img` initializes. If a prior session was killed by iOS, `session.record` checkpoints are translated into clear diagnostics.
- **Direct APK & Split-APK Install (VSOCK ADB):** Connects straight to guest ADB over internal VSOCK (`port 5555`) with per-VM RSA-2048 keys stored in the iOS Keychain. Supports single `.apk` files as well as `.apks`, `.apkm`, and `.zip` split bundles via `pm install-create`, plus optional Wi-Fi ADB forwarding.
- **Background & AFK Controls:** Uses iOS 16+ `AVPictureInPictureController` (`AVSampleBufferDisplayLayer`) alongside background CPU throttling (`set_background_throttle`), page-cache trimming, and a pure `#000000` OLED overlay.
- **Native iOS Interface:** Built with Apple system semantics, `SF Pro` / `SF Mono`, `.insetGrouped` tables, Light/Dark mode, and iPadOS window resizing (`GuestResizeHold`).

## Notes & Limits

- **First boot takes longer:** Creating and formatting `data.img` (`f2fs`) on a fresh VM takes roughly **45–90 seconds** before Android draws its boot animation.
- **Free Apple ID sideloading:** Certificates that strip `com.apple.developer.kernel.increased-memory-limit` cap process RAM around `~2.0–2.3 GiB`. On those installs (and 4 GiB devices), keep Retina disabled and guest RAM at `1 GiB` so iOS Jetsam does not kill the VM.
- **CPU rendering vs Metal 4:** Running iOS 26 or 27 on an A14/M1+ device? Pick the `Metal4-iOS26` build — hardware GPU rendering via KosmicKrisp + Zink is faster and uses less host RAM than CPU rasterization.

## Building on macOS (XcodeGen)

1. Fetch or unpack prebuilt dependencies into `.build/dependencies` from the `deps-ios16-latest` release (or run `dependencies/build-ios-*.sh` and `dependencies/build-apple-gpu.sh`).
2. Build `KernariumRuntime`:
   ```sh
   cmake --preset kernarium-ios-device-android
   cmake --build --preset kernarium-ios-device-android
   ```
3. Stage embedded XCFrameworks (`--tier ios16-universal` or `--tier ios26-metal4`):
   ```sh
   ./Dynarium/scripts/package-dynarium-frameworks.sh --tier ios16-universal
   ```
4. Generate the Xcode project from `Dynarium/project.yml` and package an unsigned `.ipa`:
   ```sh
   (CDPATH= cd -- Dynarium && xcodegen generate)
   ```
   Automated GitHub Actions workflows live in [`.github/workflows/build-deps.yml`](.github/workflows/build-deps.yml) and [`.github/workflows/build-ipa.yml`](.github/workflows/build-ipa.yml).

## Project Layout

- [`PLAN.md`](PLAN.md) — Architecture design notes and development roadmap.
- [`AGENTS.md`](AGENTS.md) — Workspace rules, Windows LF enforcement, and Darwin invariants.
- [`CREDITS.md`](CREDITS.md) — Upstream attribution and third-party license notices.
- `Dynarium/` — XcodeGen spec, SwiftUI/UIKit app sources, entitlements, and packaging scripts.
- `darwin/`, `dependencies/`, `cmake/`, `scripts/` — Core UML hypervisor runtime, GPU/network/storage layers, and verification audits.

## Credits & License

Dynarium is built on the core runtime and kernel work of [`imxieyi/Kernarium`](https://github.com/imxieyi/Kernarium) (by Yi Xie) and draws threaded interpreter inspiration from [`ish-app/ish`](https://github.com/ish-app/ish). Full component notices are in [`CREDITS.md`](CREDITS.md).

Licensed under **`GPL-2.0-or-later`** ([`LICENSE`](LICENSE)), except guest overlay/tree code marked **`Apache-2.0`** and individual third-party patches under [`LICENSES/`](LICENSES/).
