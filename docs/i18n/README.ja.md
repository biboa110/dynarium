<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../assets/dynarium-logo-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="../assets/dynarium-logo-light.svg">
    <img alt="Dynarium — iOS 上で動作する Android 17 仮想マシン" src="../assets/dynarium-logo-light.svg" width="460">
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
  <a href="README.zh-CN.md">简体中文</a> ·
  <strong>日本語</strong> ·
  <a href="README.ko.md">한국어</a> ·
  <a href="README.es.md">Español</a>
</p>

---

Dynarium は、iPhone および iPad（**iOS 16.0 – iOS 27+**）向けに開発されたマルチ VM 対応の Android ハイパーバイザです。User-Mode Linux（`6.18 LTS`）と [`imxieyi/Kernarium`](https://github.com/imxieyi/Kernarium) の Gadget Engine により、**Android 17（LineageOS 24）** をネイティブに近い環境で動作させます。

約 1 GB のシステムイメージを `.ipa` へ固定で埋め込むのではなく、VMware のような構成を採用しています。本体は約 22〜38 MiB に抑え、必要な ROM だけを後からダウンロード・インポートし、読み取り専用の `system.img` を APFS のコピーオンライト（`clonefile`）で共有しながら複数の仮想マシンを管理できます。

## ダウンロードとエディションの選び方

GitHub Releases では、`ldid` によりメモリ上限拡張エンタイトルメントを付与した 2 種類の未署名 `.ipa` を配布しています。

| パッケージ | 対象デバイス | グラフィックスバックエンド | 容量 |
| :--- | :--- | :--- | :--- |
| `Dynarium-v<version>-Metal4-iOS26.ipa` | **iOS 26 / 27+ 推奨**（A14 / M1 以降） | ハードウェア Vulkan 1.4 / GLES 3.2（`KosmicKrisp + Mesa Zink`） | 約 22 MiB |
| `Dynarium-v<version>.ipa` | **iOS 16.0 – 27+ 汎用版**（全 Apple Silicon） | CPU `Mesa softpipe`（`DRAW_USE_LLVM=0`、JIT 不要）；JIT 検出時は自動で `llvmpipe` へ切替 | 約 38 MiB |

[Releases ページ](https://github.com/userlethekhoi/dynarium/releases) から `.ipa` と `SHA256SUMS.txt` を入手できます。

## クイックスタート

1. ご利用の iOS バージョンに合った `.ipa` を **TrollStore**、**AltStore**、または **SideStore** でインストールします。
2. **ROM（Kho ROM）** タブを開き、ワンタップで LineageOS 24（Android 17）をダウンロードするか、URL 指定・ファイルアプリから `.tar.gz` / `.tar.zst` を読み込みます。
3. **VM（Máy ảo）** タブで **+** を押し、端末の実測メモリ上限（`os_proc_available_memory()`）に合わせて最適化された設定のまま起動します。
4. 実行中は下部のフローティング HUD からシリアルコンソール、ソフトウェアキーボード、`.apk` / 分割 `.apks` / `.apkm` インストール、ピクチャ・イン・ピクチャ（PiP）、**AFK Eco モード**を呼び出せます。

## 主な機能

- **ROM 分離と APFS 高速クローン:** `.tar.gz` / `.tar.zst` / `.tar` をスパース領域をスキップ（`F_PUNCHHOLE`）しながらストリーミング展開し、SHA-256 を検証します。VM の複製は APFS `clonefile` を用いるため、作成直後の追加ストレージ消費を抑えられます。
- **Jetsam 対策と自動プロファイル調整:** 起動時にプロセスメモリ上限を確認し、ゲスト RAM・vCPU 数・1x / Retina スケーリングを自動調整します。上限を超えやすい設定の既存 VM は、起動前に安全な値へのワンタップ調整を提案します。
- **起動ステージ表示とクラッシュ診断:** `data.img` 初期化中に真っ黒な画面のまま待たせないよう、カーネルおよび Android の 4 段階の起動進捗と経過時間を表示します。前回のセッションが iOS により終了された場合も `session.record` を解析して原因を表示します。
- **VSOCK ADB による APK / Split APK 導入:** 内部 VSOCK（`port 5555`）と VM 固有の Keychain RSA-2048 鍵でゲスト側 ADB に直接接続します。単体 `.apk` に加え `.apks` / `.apkm` / `.zip`（`pm install-create`）のインストール、Wi-Fi 経由の ADB 転送に対応しています。
- **PiP と AFK Eco モード:** iOS 16 以降対応の `AVSampleBufferDisplayLayer` PiP 出力に加え、バックグラウンド時のスロットリング、ページキャッシュの解放、OLED 保護用の純黒オーバーレイ（`#000000`）を備えています。

## 注意点と制限事項

- **初回起動は時間がかかります:** 新規 VM の初回起動では `data.img`（`f2fs`）の作成とフォーマットに約 **45〜90 秒**かかり、その後 Android のブート画面が表示されます。
- **無料 Apple ID でのサイドロード制限:** `increased-memory-limit` が外れる署名環境では iOS のメモリ上限が `~2.0–2.3 GiB` 付近になります。この環境や 4 GiB 搭載機では、Retina をオフにしゲスト RAM を `1 GiB` に保つと安定します。
- **iOS 26 / 27+ では Metal 4 版を推奨:** A14 / M1 以降のチップでは、CPU 描画版よりも `Metal4-iOS26` の方がフレームレート・消費メモリともに有利です。

## macOS でのビルド手順（XcodeGen）

1. `deps-ios16-latest` からビルド済み依存ライブラリを `.build/dependencies` へ展開します（または `dependencies/build-ios-*.sh` と `dependencies/build-apple-gpu.sh` を実行）。
2. `KernariumRuntime` をビルドします：
   ```sh
   cmake --preset kernarium-ios-device-android
   cmake --build --preset kernarium-ios-device-android
   ```
3. XCFrameworks を配置します（`--tier ios16-universal` または `--tier ios26-metal4`）：
   ```sh
   ./Dynarium/scripts/package-dynarium-frameworks.sh --tier ios16-universal
   ```
4. `Dynarium/project.yml` から Xcode プロジェクトを生成します：
   ```sh
   (CDPATH= cd -- Dynarium && xcodegen generate)
   ```

## クレジットとライセンス

Dynarium は Yi Xie 氏による [`imxieyi/Kernarium`](https://github.com/imxieyi/Kernarium) のランタイム・カーネル基盤の上に構築されており、スレッド化インタプリタの設計は [`ish-app/ish`](https://github.com/ish-app/ish) を参考にしています。各コンポーネントの表記は [`CREDITS.md`](../../CREDITS.md) をご覧ください。

ライセンスは **`GPL-2.0-or-later`**（[`LICENSE`](../../LICENSE)）です。Android ゲスト側のオーバーレイコードは **`Apache-2.0`**、サードパーティパッチのライセンスは [`LICENSES/`](../../LICENSES/) に記載されています。
