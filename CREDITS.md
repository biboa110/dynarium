# Credits & Attribution

**Dynarium** is an independent Android-focused fork built upon open-source foundations. We gratefully acknowledge the original authors and upstream projects that make Dynarium possible:

## Core Runtime & Kernel Foundations

- **[`imxieyi/Kernarium`](https://github.com/imxieyi/Kernarium)** — Created by **Yi Xie (`imxieyi`)**
  - Provides the Darwin User-Mode Linux (Mainline 6.18 LTS) runtime, 4 KiB-on-16 KiB sparse software MMU, `arm64`/`arm32`/`x86_64` Gadget Engine, Virtio device implementations (`virtio-gpu`, `virtio-snd`, `virtio-video`, `virtio-vsock`, `virtio-input`, `ubd`), `libslirp` networking, and the LineageOS 24 (Android 17) overlay and guest integration.
  - Licensed under **`GPL-2.0-or-later`** (host runtime, Darwin subsystems, kernel tooling, and build scripts) and **`Apache-2.0`** (Android guest overlay and Android tree patches).
- **[`ish-app/ish`](https://github.com/ish-app/ish)** — Created by **Theodore Dubois & contributors**
  - Inspired the threaded gadget interpreter execution design enabling non-jailbroken iOS userspace emulation without `MAP_JIT`.

## Upstream Libraries & Guest Projects

Dynarium builds and ships components from the following open-source projects (see [`dependencies/manifest.tsv`](dependencies/manifest.tsv) and [`LICENSES/`](LICENSES/) for exact pinned commits and license texts):

- **Linux Kernel 6.18 LTS** (`GPL-2.0-only`) — User-Mode Linux (`ARCH=um`) guest kernel
- **LineageOS 24 / AOSP (Android 17)** (`Apache-2.0`) — Android guest operating system
- **Mesa 3D** (`MIT`) — `KosmicKrisp` Vulkan-to-Metal driver, `Zink` OpenGL-on-Vulkan, and `llvmpipe`/`softpipe` software fallback
- **virglrenderer** (`MIT`) — Virtio-GPU 3D host renderer
- **libepoxy** (`MIT`) — OpenGL/EGL function dispatch layer
- **LLVM** (`Apache-2.0 WITH LLVM-exception`) — Static AArch64 JIT compiler backend for `llvmpipe`
- **libslirp** (`BSD-3-Clause`) & **GLib** (`LGPL-2.1-or-later`) — User-mode virtual networking stack
- **zstd** (`BSD-3-Clause` / `GPL-2.0-only`) — High-speed decompression for Android guest images
- **GPT fdisk** (`GPL-2.0-or-later`) — File-only GPT partition management for virtual data disks
- **Google ANGLE** (`BSD-3-Clause`) *(Phase 3)* — Metal 2/3 hardware OpenGL ES backend for iOS 16–18 devices
