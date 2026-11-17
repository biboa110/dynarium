# Dynarium

Run **Android 17 (LineageOS 24)** natively on iPhone and iPad (**iOS 16.0 – iOS 27+**) without Jailbreak, powered by **User-Mode Linux (Mainline 6.18 LTS)** and the **Gadget Engine**.

Dynarium is an independent Android-focused fork of [`imxieyi/Kernarium`](https://github.com/imxieyi/Kernarium), engineered to unlock iOS 16–18 hardware, deliver native Metal GPU acceleration across older and newer Apple Silicon chips, and enable long-running AFK / background Android workloads.

## Key Capabilities

- **Broad iOS Support (`iOS 16.0 – iOS 27+`):** Unlocks support for iOS 16, 17, 18, and 26+ devices (including A12–A18 and M1–M4 hardware, as well as TrollStore-capable setups), while removing unused Linux desktop UI overhead.
- **Native-Speed Kernel + Gadget Userspace:** Compiles Linux Mainline 6.18 LTS directly to `arm64` Mach-O (`__TEXT,__uml_elf`) while translating `arm64-v8a` and `armeabi-v7a` Android userspace instructions via an iSH-inspired threaded Gadget Engine (`4 KiB` guest pages mapped over `16 KiB` Apple host pages).
- **Adaptive 3-Tier GPU Architecture:**
  - **Tier 1 (iOS 26.0+ / Metal 4):** `KosmicKrisp` + `Zink` + `Venus` (Vulkan 1.4, OpenGL 4.6, GLES 3.2).
  - **Tier 2 (iOS 16.0–18.x / Metal 2 & 3, Phase 3):** `virglrenderer` over `Google ANGLE` Metal backend with zero-copy `IOSurface` → `MTLTexture` presentation.
  - **Tier 3 (Safe Fallback):** `Mesa llvmpipe` / `softpipe` CPU rasterizer.
- **Dynarium Smart Profile (Anti-Jetsam):** Auto-tunes vCPU count, guest RAM, resolution, and strict GPU pool budgets based on host chip and `os_proc_available_memory()`.
- **AFK Eco Mode & Background Keep-Alive (Phase 4):** Picture-in-Picture (`AVPictureInPictureController`) streaming, low-FPS / OLED blackout throttling, vCPU pacing, and periodic `uml_emulator_trim_page_cache()`.

## Repository Structure & Architecture

- [`PLAN.md`](PLAN.md) — Master technical specification and 5-phase implementation roadmap.
- [`AGENTS.md`](AGENTS.md) — Engineering constraints, Windows CI guidelines, and Darwin invariants.
- [`CREDITS.md`](CREDITS.md) — Full attribution to [`imxieyi/Kernarium`](https://github.com/imxieyi/Kernarium), [`ish-app/ish`](https://github.com/ish-app/ish), and third-party libraries.
- `darwin/` — Host runtime, CPU engines, software MMU, and Virtio device services (`GPL-2.0-or-later`).
- `dependencies/` — Pinned external dependency manifests, patch series, and offline iOS/macOS build scripts.
- `cmake/` & `scripts/` — Apple cross-compilation toolchains and static/File-API architecture audits.
- `.github/workflows/` — Automated macOS ARM64 CI workflows for dependency builds and `.ipa` packaging.

## Attribution & License

Dynarium builds upon [`imxieyi/Kernarium`](https://github.com/imxieyi/Kernarium) (by Yi Xie) and draws interpreter inspiration from [`ish-app/ish`](https://github.com/ish-app/ish). See [`CREDITS.md`](CREDITS.md) for full acknowledgements.

This project is licensed under **`GPL-2.0-or-later`** (root [`LICENSE`](LICENSE)), except where individual files or directories carry another `SPDX-License-Identifier` (such as **`Apache-2.0`** for Android guest overlay/tree code). See [`LICENSES/`](LICENSES/) for full license texts and rules.
