<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../assets/dynarium-logo-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="../assets/dynarium-logo-light.svg">
    <img alt="Dynarium — Máy ảo Android 17 trên iOS" src="../assets/dynarium-logo-light.svg" width="460">
  </picture>
</p>

<p align="center">
  <a href="https://github.com/userlethekhoi/dynarium/releases"><img alt="Latest Release" src="https://img.shields.io/github/v/release/userlethekhoi/dynarium?style=flat-square&color=22B867"></a>
  <img alt="iOS 16.0 – 27+" src="https://img.shields.io/badge/iOS-16.0%20--%2027%2B-111318?style=flat-square">
  <a href="../../LICENSE"><img alt="License: GPL-2.0-or-later" src="https://img.shields.io/badge/License-GPL--2.0--or--later-303C4E?style=flat-square"></a>
</p>

<p align="center">
  <a href="../../README.md">English</a> ·
  <strong>Tiếng Việt</strong> ·
  <a href="README.zh-CN.md">简体中文</a> ·
  <a href="README.ja.md">日本語</a> ·
  <a href="README.ko.md">한국어</a> ·
  <a href="README.es.md">Español</a>
</p>

---

Dynarium là trình quản lý và chạy đa máy ảo Android dành cho iPhone và iPad (**iOS 16.0 đến iOS 27+**). Ứng dụng chạy **Android 17 (LineageOS 24)** trực tiếp trên nhân User-Mode Linux (`6.18 LTS`) và Gadget Engine phát triển từ [`imxieyi/Kernarium`](https://github.com/imxieyi/Kernarium).

Thay vì nhồi sẵn ~1 GB ảnh hệ thống vào trong file cài đặt, Dynarium tách biệt theo mô hình **VMware**: file `.ipa` chỉ nặng ~22–38 MiB đóng vai trò Hypervisor, bạn tự tải hoặc nhập ROM khi cần và có thể tạo nhiều máy ảo chạy song song trên cùng 1 `system.img` chỉ đọc thông qua cơ chế nhân bản copy-on-write của APFS (`clonefile`).

## Tải về & Chọn đúng phiên bản `.ipa`

Mỗi bản phát hành trên GitHub đi kèm 2 gói `.ipa` đã gắn sẵn entitlements bằng `ldid`:

| Tên file `.ipa` | Thiết bị khuyên dùng | Công nghệ đồ họa | Dung lượng |
| :--- | :--- | :--- | :--- |
| `Dynarium-v<version>-Metal4-iOS26.ipa` | **Khuyên dùng cho iOS 26 / 27+** (chip A14 / M1 trở lên) | Tăng tốc GPU phần cứng **Vulkan 1.4 / GLES 3.2** (`KosmicKrisp + Mesa Zink`) | ~22 MiB |
| `Dynarium-v<version>.ipa` | **iOS 16.0 – 27+ Universal** (tất cả máy Apple Silicon) | Dựng hình CPU `Mesa softpipe` (`DRAW_USE_LLVM=0`, không cần JIT); tự bật `llvmpipe` khi có JIT | ~38 MiB |

Tải trực tiếp tại trang [GitHub Releases](https://github.com/userlethekhoi/dynarium/releases) kèm `SHA256SUMS.txt`.

## Bắt đầu nhanh trong 4 bước

1. Cài file `.ipa` phù hợp với đời iOS qua **TrollStore**, **AltStore** hoặc **SideStore**.
2. Vào tab **Kho ROM** để tải LineageOS 24 (Android 17) chỉ với 1 chạm, dán link `.tar.gz`/`.tar.zst` tùy chỉnh hoặc nhập file có sẵn từ ứng dụng Tệp.
3. Sang tab **Máy ảo**, bấm **+** để tạo máy ảo mới (số nhân CPU, RAM và độ phân giải được cân sẵn theo `os_proc_available_memory()`), sau đó bấm nút Play để chạy.
4. Dùng thanh công cụ nổi phía dưới khi đang chạy để mở Serial Console, bật bàn phím ảo, cài `.apk` / `.apks` / `.apkm`, mở **PiP** hoặc kích hoạt **AFK Eco Mode**.

## Các tính năng chính

- **Kho ROM tách rời & Nhân bản APFS siêu tốc:** Hỗ trợ giải nén trực tiếp `.tar.gz`, `.tar.zst`, `.tar` theo chuẩn thưa (`F_PUNCHHOLE`) kèm kiểm tra SHA-256. Nhiều máy ảo dùng chung `system.img` chỉ đọc và khi nhân bản VM sẽ dùng `clonefile` của APFS nên gần như không tốn thêm dung lượng lưu trữ ban đầu.
- **Cân chỉnh phần cứng & Anti-Jetsam thông minh:** Tự đọc trần RAM hệ thống (`os_proc_available_memory()`), giới hạn ngân sách GPU và kiểm tra dung lượng trống trước khi khởi chạy. Nếu máy ảo cũ đặt cấu hình quá mức thiết bị cho phép, ứng dụng sẽ hỏi hạ về cấu hình an toàn chỉ với 1 chạm.
- **Hiển thị tiến trình boot & Chẩn đoán sự cố:** Hiển thị 4 bước khởi chạy nhân Linux 6.18 và phân vùng Android kèm đồng hồ đếm giây thay vì màn hình đen trống. Nếu phiên trước bị iOS thu hồi RAM, thông tin từ `session.record` sẽ được đọc và giải thích rõ bằng tiếng Việt.
- **Cài APK & Split APK trực tiếp qua VSOCK ADB:** Kết nối thẳng tới Android qua VSOCK (`cổng 5555`) với khóa RSA-2048 lưu trong iOS Keychain riêng cho từng VM. Hỗ trợ cả `.apk` đơn lẫn bộ `.apks`, `.apkm`, `.zip` (`pm install-create`) và tùy chọn mở ADB qua Wi-Fi LAN.
- **PiP & Chế độ treo máy AFK Eco:** Tương thích Picture-in-Picture từ iOS 16+ (`AVSampleBufferDisplayLayer`), tự giảm xung CPU nền (`set_background_throttle`), giải phóng cache trang nhớ và phủ màn đen OLED `#000000`.
- **Giao diện thuần Apple HIG:** Sử dụng đúng bảng màu hệ thống iOS, font `SF Pro` / `SF Mono`, hỗ trợ Dark Mode, Dynamic Type và co giãn cửa sổ iPadOS.

## Lưu ý thực tế khi sử dụng

- **Lần khởi động đầu tiên lâu hơn bình thường:** Máy ảo mới cần khoảng **45–90 giây** để tạo và định dạng phân vùng `data.img` (`f2fs`) trước khi xuất hình khởi động Android.
- **Chứng chỉ Apple ID miễn phí:** Các chứng chỉ cài đặt bỏ qua quyền `increased-memory-limit` thường bị iOS giới hạn tiến trình ở mức `~2.0–2.3 GiB`. Trên các máy này (hoặc iPhone RAM 4 GiB), nên giữ độ phân giải tiêu chuẩn 1x (tắt Retina) và mức RAM khách `1 GiB` để chạy ổn định.
- **Chọn đúng bản khi dùng iOS 26 / 27+:** Nếu máy dùng chip A14 / M1 trở lên và đang chạy iOS 26+, hãy chọn bản `Metal4-iOS26` để dùng tăng tốc GPU phần cứng — nhẹ RAM và mượt hơn dựng hình CPU rất nhiều.

## Tự biên dịch trên macOS (XcodeGen)

1. Tải gói thư viện dựng sẵn từ bản phát hành `deps-ios16-latest` vào `.build/dependencies` (hoặc chạy `dependencies/build-ios-*.sh` và `dependencies/build-apple-gpu.sh`).
2. Biên dịch `KernariumRuntime`:
   ```sh
   cmake --preset kernarium-ios-device-android
   cmake --build --preset kernarium-ios-device-android
   ```
3. Đóng gói XCFrameworks (`--tier ios16-universal` hoặc `--tier ios26-metal4`):
   ```sh
   ./Dynarium/scripts/package-dynarium-frameworks.sh --tier ios16-universal
   ```
4. Tạo dự án Xcode từ `Dynarium/project.yml` bằng XcodeGen:
   ```sh
   (CDPATH= cd -- Dynarium && xcodegen generate)
   ```

## Ghi công & Giấy phép

Dynarium xây dựng trên nền tảng runtime lõi của [`imxieyi/Kernarium`](https://github.com/imxieyi/Kernarium) (Yi Xie) và kế thừa cảm hứng kỹ thuật từ [`ish-app/ish`](https://github.com/ish-app/ish). Chi tiết đầy đủ xem tại [`CREDITS.md`](../../CREDITS.md).

Phát hành theo giấy phép **`GPL-2.0-or-later`** ([`LICENSE`](../../LICENSE)), ngoại trừ phần lớp phủ Android theo **`Apache-2.0`** và giấy phép thành phần bên thứ ba trong [`LICENSES/`](../../LICENSES/).
