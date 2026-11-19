# Dynarium Workspace Agent Guide

This file governs all AI coding agents working inside `C:\dynarium`. Direct user instructions take precedence.

## 1. Mandatory First Step & Progress Tracking

- **Always read [`PLAN.md`](PLAN.md) first** before proposing architectural changes, modifying build scripts, or starting any work phase.
- Update the phase checklist (`- [ ]` → `- [x]`) in `PLAN.md` whenever a milestone or phase is verified and completed.
- After importing the upstream runtime, also respect the architectural ownership rules in `docs/architecture.md` and subsystem `README.md` files unless `PLAN.md` explicitly specifies an intentional divergence (such as lowering the iOS deployment target, the Multi-VM VMware model, or adding the ANGLE Metal 2/3 GPU tier).

## 2. Project Identity & Direction

- **Name:** `Dynarium`
- **Product Scope (VMware-Style Android Hypervisor):** A lightweight iOS/iPadOS virtual-machine manager & hypervisor running **Android 17 (LineageOS 24)** natively via **User-Mode Linux (Mainline 6.18 LTS)** and the **Gadget Engine**, targeting **iOS 16.0 through iOS 27+**. Instead of embedding a ~1 GiB system image inside the `.ipa`, users manage ROM images (1-tap download, custom URL, or Files import) and run multiple isolated VMs sharing read-only `system.img` layers via APFS copy-on-write cloning (`clonefile`).
- **Dual-Edition Releases (`build-ipa.yml`):**
  1. `Dynarium-v<version>.ipa` (`IPHONEOS_DEPLOYMENT_TARGET = 16.0`): Universal iOS 16.0–27+ build using Mesa `softpipe` safely by default on non-JIT devices and switching cleanly to `llvmpipe` when JIT/debugger is active.
  2. `Dynarium-v<version>-Metal4-iOS26.ipa` (`IPHONEOS_DEPLOYMENT_TARGET = 26.0`): Hardware-accelerated Vulkan 1.4 / Metal 4 build (`KosmicKrisp` + `Mesa Zink`) for iOS 26.0+ A14/M1+ devices.
- **Tier 2 Graphics Roadmap (`darwin/device/gpu/`):** Future `virglrenderer` over `Google ANGLE` (Metal backend) zero-copy `IOSurface` → `MTLTexture` acceleration for Metal 2/3 devices on iOS 16–25.
- **Smart Chip & RAM Profile (`HostHardwareProfile`):** Auto-tunes vCPU count, guest RAM ceiling ($G$), GPU pool budget ($B = \max(L - A - G - E - S,\; 384\text{ MiB})$), resolution/Retina, and Jetsam safety margin (`RunSpace` / `SpacePauser`).
- **AFK & Background Keep-Alive:** iOS 16.0+ Picture-in-Picture (`AVPictureInPictureController` via `AVSampleBufferDisplayLayer` + `CMSampleBuffer`) and **AFK Eco Mode** (`set_background_throttle` + `set_page_cache_trimming` + True Black `#000000` OLED overlay).
- **Clean Apple HIG Native UI:** Built strictly with system semantic colors (`.systemGroupedBackground`, `.blue` accent), `SF Pro` / `SF Mono`, `SF Symbols`, and iOS 16+ `ObservableObject`/`@Published` patterns. Never use neon purple gradients or AI sparkle icons.

## 3. Windows Host & GitHub Actions CI Rules

- **Local machine is Windows (`powershell`):** Do not attempt to run `xcrun`, `xcodebuild`, Apple SDK CMake presets, or iOS Meson cross-compiles locally on Windows. All Apple compilation and `.ipa` packaging MUST be authored for **GitHub Actions `macos` ARM64 runners** (`.github/workflows/build-deps.yml` and `.github/workflows/build-ipa.yml`).
- **Xcode Project Format:** Never rely on Xcode 27's JSON `.xcproj` format or check `.xcodeproj` directories into Git. Maintain `Dynarium/project.yml` for **XcodeGen**, so CI generates a compatible `.xcodeproj` on `macos-26` runners.
- **Line Endings & Source Audits (Critical on Windows):**
  - Always enforce **LF (`\n`)** line endings without UTF-8 BOM via `.gitattributes`.
  - Respect `scripts/audit-source-tree.cmake` and `tests/tooling/cmake/check_license_headers.py`: no `.c` files or `Makefile`s inside `Dynarium/` (use `static inline` helpers in bridging headers or `.mm`), use `CDPATH= cd --` in shell scripts, keep `SPDX-License-Identifier: GPL-2.0-or-later` within the first 8 lines of every first-party source/script file, and keep root markdown files restricted to the audit allowlist.
- **Prebuilt Dependencies & Unsigned Packaging:**
  - Do NOT modify `dependencies/` unless updating pinned dependency builds intentionally, so warm caches and `deps-ios16-latest` remain valid.
  - CI builds unsigned (`CODE_SIGNING_ALLOWED=NO`) and applies `ldid -SConfig/Dynarium.entitlements` (or ad-hoc signing + entitlements) preserving `com.apple.developer.kernel.increased-memory-limit` and `com.apple.developer.kernel.extended-virtual-addressing`.

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
- **Secrets & Privacy:** Never commit Apple Team IDs, signing certificates, provisioning profiles, `.ipa` archives, `.xcodeproj` outputs, SSH endpoints, or personal local paths into tracked files. Keep local signing configuration in ignored `*.local.xcconfig` files or GitHub Actions secrets.
