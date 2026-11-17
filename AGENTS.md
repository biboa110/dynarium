# Dynarium Workspace Agent Guide

This file governs all AI coding agents working inside `C:\dynarium`. Direct user instructions take precedence.

## 1. Mandatory First Step & Progress Tracking

- **Always read [`PLAN.md`](PLAN.md) first** before proposing architectural changes, modifying build scripts, or starting any work phase.
- Update the phase checklist (`- [ ]` → `- [x]`) in `PLAN.md` whenever a milestone or phase is verified and completed.
- After importing the upstream runtime, also respect the architectural ownership rules in `docs/architecture.md` and subsystem `README.md` files unless `PLAN.md` explicitly specifies an intentional divergence (such as lowering the iOS deployment target or adding the ANGLE Metal 2/3 GPU tier).

## 2. Project Identity & Direction

- **Name:** `Dynarium`
- **Product Scope (Option 1 — Android-Focused):** An iOS/iPadOS emulator running **Android 17 (LineageOS 24)** natively via **User-Mode Linux (Mainline 6.18 LTS)** and the **Gadget Engine** (with optional Hybrid JIT research for TrollStore/`MAP_JIT` devices), targeting **iOS 16.0 through iOS 27+**. Linux desktop guest UI/distribution workflows are intentionally excluded from the user-facing app to keep the app lightweight and focused on APK execution, sandboxing, and AFK/background running.
- **Core Differentiators over Upstream (`imxieyi/Kernarium` / `Andarium`):**
  1. **Adaptive GPU Tiering (`darwin/device/gpu/`):**
     - **Tier 1 (`iOS 26.0+` & A14/M1+):** `KosmicKrisp` + `Zink` + `Venus` (Metal 4 — Vulkan 1.4, OpenGL 4.6, GLES 3.2), dynamically loaded (`dlopen`) only on iOS 26+.
     - **Tier 2 (`iOS 16.0–18.x` & Metal 2/3 GPUs):** `virglrenderer` (EGL/GLES mode) over **`Google ANGLE` (Metal backend)** with zero-copy `IOSurface` → `MTLTexture` presentation (hardware GLES 3.0/3.1; Vulkan Venus hidden on iOS < 26).
     - **Tier 3 (Safe Fallback):** `Mesa llvmpipe` (CPU NEON software rasterizer).
  2. **Smart Chip & RAM Profile (`Dynarium Smart Profile`):** Auto-tunes vCPU count, guest RAM ceiling ($G$), GPU pool budget ($B = \max(L - A - G - E - S,\; 384\text{ MiB})$), resolution/Retina, and Jetsam safety margin based on host chip, RAM, and TrollStore/`MAP_JIT` status.
  3. **AFK & Background Keep-Alive:** Picture-in-Picture (`AVPictureInPictureController`) streaming and **AFK Eco Mode** (throttled host FPS 5–10 FPS / OLED blackout overlay + vCPU throttling + periodic `uml_emulator_trim_page_cache()`).
  4. **iOS 16.0+ Native UI:** Rebuilt SwiftUI/UIKit interface using `ObservableObject`/`@Published` (no iOS 17+ `@Observable` or `TipKit` hard requirements).

## 3. Windows Host & GitHub Actions CI Rules

- **Local machine is Windows (`powershell`):** Do not attempt to run `xcrun`, `xcodebuild`, Apple SDK CMake presets, or iOS Meson cross-compiles locally on Windows. All Apple compilation and `.ipa` packaging MUST be authored for **GitHub Actions `macos` ARM64 runners** (`.github/workflows/build-deps.yml` and `.github/workflows/build-ipa.yml`).
- **Xcode Project Format:** Never rely on Xcode 27's JSON `.xcproj` format. Maintain `Dynarium/project.yml` for **XcodeGen**, so CI can generate a compatible `.xcodeproj` on Xcode 16 / Xcode 26 runners.
- **Line Endings (Critical on Windows):** Always enforce **LF (`\n`)** line endings for `.sh`, `.py`, `.patch`, `.tsv`, `.inc`, `.S`, and CMake/Meson files via `.gitattributes` (`* text=auto` and explicit `eol=lf` rules). Never commit CRLF line endings into shell scripts or patch files.
- **Prebuilt Guest Artifacts:** In Phases 1–4, reuse upstream release `1.0b9-beta` artifacts (`android-6.18-arm64-4k-20261111-6.18.60-mc2.tar.gz` and `lineage24-mainline6.18-4k-20261110-los24-r22.tar.gz`) inside CI workflows rather than requiring an external `x86_64` Linux build server.
- **Unsigned Sideload / TrollStore Packaging:** CI builds with `CODE_SIGNING_ALLOWED=NO` and applies `ldid -SConfig/Dynarium.entitlements` to preserve `com.apple.developer.kernel.increased-memory-limit` and `com.apple.developer.kernel.extended-virtual-addressing`.

## 4. Non-Negotiable Darwin / iOS Technical Invariants

1. **No `x18` Register Usage:** Never touch `x18` in assembly or host code under `darwin/` or `Dynarium/` (Darwin reserves and clobbers `x18` on thread interrupts).
2. **4 KiB Guest Pages on 16 KiB Apple Host Pages:** Keep the 4 KiB guest page geometry (required for 32-bit `armeabi-v7a` alignment) mapped via the 128 TiB sparse software-MMU.
3. **No POSIX File Locks Across iOS Suspension:** iOS terminates suspended processes holding `flock`/`fcntl` locks. Disk locks must remain managed in `platform/guest_files` and released across `uml_emulator_quiesce()` / `` `$TMPDIR` `` hibernation.
4. **Single Executable-Memory Owner:** Only `darwin/cpu/jit_memory/executable_memory.cpp` may allocate or publish executable memory. Gadget streams must remain non-executable data.
5. **Network Privacy (`libslirp`):** Keep SLiRP's built-in DNS proxy disabled and route DNS through the iOS system resolver so ordinary internet access does not trigger unnecessary Local Network permission prompts.
6. **Dependency Architecture Direction:** Preserve the one-way dependency DAG:
   `app -> emulator / device`, `emulator -> runtime / device / api`, `runtime -> cpu / memory / device contracts / platform`, `cpu -> memory / platform`, `memory -> platform`, `device -> memory / platform`.

## 5. Licensing, Attribution & Privacy

- **Licenses:** Preserve `GPL-2.0-or-later` SPDX headers for Darwin host/runtime/kernel code and `Apache-2.0` SPDX headers for Android overlay/guest code (and upstream licenses for patched dependencies).
- **Credits:** Always retain attribution to [`imxieyi/Kernarium`](https://github.com/imxieyi/Kernarium) and [`ish-app/ish`](https://github.com/ish-app/ish) in `CREDITS.md`, `README.md`, and the in-app Credits screen.
- **Secrets & Privacy:** Never commit Apple Team IDs, signing certificates, provisioning profiles, SSH endpoints, or personal local paths into tracked files. Keep local signing configuration in ignored `.local.xcconfig` files or GitHub Actions secrets.
