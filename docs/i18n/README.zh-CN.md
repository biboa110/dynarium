<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../assets/dynarium-logo-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="../assets/dynarium-logo-light.svg">
    <img alt="Dynarium — 在 iOS 上原生运行 Android 17 虚拟机" src="../assets/dynarium-logo-light.svg" width="460">
  </picture>
</p>

<p align="center">
  <a href="https://github.com/userlethekhoi/dynarium/releases"><img alt="Latest Release" src="https://img.shields.io/github/v/release/userlethekhoi/dynarium?style=flat-square&color=22B867"></a>
  <img alt="iOS 16.0 – 27+" src="https://img.shields.io/badge/iOS-16.0%20--%2027%2B-111318?style=flat-square">
  <a href="../../LICENSE"><img alt="License: GPL-2.0-or-later" src="https://img.shields.io/badge/License-GPL--2.0--or--later-303C4E?style=flat-square"></a>
</p>

<p align="center">
  <a href="../../README.md">English</a> ·
  <a href="README.vi.md">Tiếng Việt</a> ·
  <strong>简体中文</strong> ·
  <a href="README.ja.md">日本語</a> ·
  <a href="README.ko.md">한국어</a> ·
  <a href="README.es.md">Español</a>
</p>

---

Dynarium 是一款面向 iPhone 与 iPad（**iOS 16.0 – iOS 27+**）的多实例 Android 虚拟机管理器，基于 User-Mode Linux（`6.18 LTS`）以及源自 [`imxieyi/Kernarium`](https://github.com/imxieyi/Kernarium) 的 Gadget 引擎运行 **Android 17（LineageOS 24）**。

应用采用类似 VMware 的结构设计，不在安装包中硬编码 ~1 GB 系统镜像。`.ipa` 本体仅 ~22–38 MiB，你可以在应用内按需下载或导入 ROM，并借助 APFS 写时复制克隆（`clonefile`）同时管理多个共享只读 `system.img` 的独立虚拟机。

## 下载与版本选择

每个 GitHub Release 均提供两个已通过 `ldid` 附加内存权限的未签名 `.ipa` 安装包：

| 安装包文件名 | 适用设备 | 图形渲染后端 | 体积 |
| :--- | :--- | :--- | :--- |
| `Dynarium-v<version>-Metal4-iOS26.ipa` | **iOS 26 / 27+ 推荐**（A14 / M1 及更新芯片） | 硬件加速 Vulkan 1.4 / GLES 3.2（`KosmicKrisp + Mesa Zink`） | ~22 MiB |
| `Dynarium-v<version>.ipa` | **iOS 16.0 – 27+ 通用版**（所有 Apple Silicon） | 纯 CPU `Mesa softpipe`（`DRAW_USE_LLVM=0`，免 JIT）；检测到 JIT 时自动切换 `llvmpipe` | ~38 MiB |

请前往 [Releases 页面](https://github.com/userlethekhoi/dynarium/releases) 下载对应安装包及 `SHA256SUMS.txt`。

## 快速上手

1. 使用 **TrollStore**、**AltStore** 或 **SideStore** 安装对应 iOS 版本的 `.ipa`。
2. 切换到 **ROM 仓库（Kho ROM）**，一键下载官方 LineageOS 24（Android 17），或通过自定义 URL / 系统“文件”导入 `.tar.gz`、`.tar.zst` 镜像包。
3. 在 **虚拟机（Máy ảo）** 页点击 **+** 新建实例（应用已按 `os_proc_available_memory()` 自动适配安全规格），点击播放键启动。
4. 运行时可通过底部悬浮工具栏打开串口终端、弹出键盘、安装单包 `.apk` 或分包 `.apks`/`.apkm`、开启画中画（PiP）以及 **AFK 省电模式**。

## 核心功能

- **镜像分离与 APFS 快速克隆：** 支持 `.tar.gz` / `.tar.zst` / `.tar` 流式稀疏解压（`F_PUNCHHOLE`）与 SHA-256 校验。多台虚拟机共享同一份只读 `system.img`，克隆虚拟机使用 APFS `clonefile`，初始几乎不额外占用闪存空间。
- **Jetsam 内存保护与安全调优：** 启动前读取 iOS 进程可用内存上限，自动调整虚拟机内存、vCPU 核心数与 1x/Retina 分辨率；若既有配置存在 OOM 风险，将在启动前提示一键降至安全档位。
- **启动阶段面板与异常诊断：** 首次初始化 `data.img` 期间实时展示 4 个内核及系统引导阶段与计时，避免长时间黑屏；若上次会话被系统杀掉，会自动解析 `session.record` 并给出明确排查建议。
- **内置 VSOCK ADB 与分包安装：** 通过内部 VSOCK（`5555` 端口）配合 Keychain 独立 RSA-2048 密钥直连客体 ADB，直接安装 `.apk` 及 `.apks` / `.apkm` / `.zip`（`pm install-create`），并支持按需开启局域网 Wi-Fi ADB 转发。
- **画中画与后台省电：** 兼容 iOS 16+ 的 `AVSampleBufferDisplayLayer` 画中画输出，配合后台降频（`set_background_throttle`）、页缓存裁剪及 OLED 纯黑遮罩（`#000000`）。

## 使用说明与已知限制

- **首次启动耗时：** 新建虚拟机第一次创建并格式化 `f2fs` 格式的 `data.img` 大约需要 **45–90 秒**，随后会进入 Android 开机动画。
- **免费个人证书的内存限制：** 若侧载工具移除了 `increased-memory-limit` 权限，iOS 会将单进程上限锁定在约 `2.0–2.3 GiB`。在此环境下（以及 4 GiB 内存机型），建议保持关闭 Retina 并将客户机内存设为 `1 GiB`，避免被 Jetsam 强杀。
- **iOS 26 / 27+ 机型优先选择 Metal 4 版：** A14 / M1 及更新机型升级到 iOS 26+ 后，请优先安装 `Metal4-iOS26` 版本，硬件渲染的帧率与内存占用均明显优于 CPU 软件渲染。

## 在 macOS 上从源码构建（XcodeGen）

1. 从 `deps-ios16-latest` Release 解压预编译依赖到 `.build/dependencies`（或运行 `dependencies/build-ios-*.sh` 与 `dependencies/build-apple-gpu.sh`）。
2. 构建 `KernariumRuntime`：
   ```sh
   cmake --preset kernarium-ios-device-android
   cmake --build --preset kernarium-ios-device-android
   ```
3. 打包 XCFrameworks（`--tier ios16-universal` 或 `--tier ios26-metal4`）：
   ```sh
   ./Dynarium/scripts/package-dynarium-frameworks.sh --tier ios16-universal
   ```
4. 使用 XcodeGen 从 `Dynarium/project.yml` 生成工程：
   ```sh
   (CDPATH= cd -- Dynarium && xcodegen generate)
   ```

## 致谢与开源协议

Dynarium 的底层运行时与内核支持基于 [`imxieyi/Kernarium`](https://github.com/imxieyi/Kernarium)（Yi Xie），并参考了 [`ish-app/ish`](https://github.com/ish-app/ish) 的解释器设计。完整第三方组件声明见 [`CREDITS.md`](../../CREDITS.md)。

本项目遵循 **`GPL-2.0-or-later`** 协议（[`LICENSE`](../../LICENSE)），Android 客体叠加配置代码遵循 **`Apache-2.0`**，其余第三方补丁协议详见 [`LICENSES/`](../../LICENSES/)。
