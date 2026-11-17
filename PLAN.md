# KẾ HOẠCH TỔNG THỂ DỰ ÁN DYNARIUM (`PLAN.md`)

> **Mục tiêu tài liệu:** Lưu giữ toàn bộ phân tích kỹ thuật, quyết định sản phẩm, kiến trúc phần mềm và lộ trình triển khai dự án **Dynarium** tại thư mục `C:\dynarium`, giúp các phiên làm việc tiếp theo nắm trọn ngữ cảnh ngay từ bước đầu mà không bị thất lạc thông tin.

---

## 1. Tổng quan Dự án `Dynarium` & Định vị Sản phẩm

**Lựa chọn chiến lược đã chốt: Hướng 1 — Chuyên biệt hóa cho Android trên iOS 16 $\rightarrow$ 27+**

### 1.1. Bản chất sản phẩm
**Dynarium** là ứng dụng chạy máy ảo **Android 17 (LineageOS 24)** hiệu năng cao ngay bên trong iPhone và iPad (hỗ trợ từ **iOS 16.0 đến iOS 27+**), không cần Jailbreak.
- **Công nghệ lõi:** Thay vì giả lập toàn bộ phần cứng chậm chạp bằng QEMU như các trình giả lập truyền thống, Dynarium biên dịch nhân **Linux Mainline 6.18 LTS** sang mã máy `arm64` gốc (native) thông qua **User-Mode Linux (UML)** và nhúng trực tiếp vào phân đoạn `__TEXT,__uml_elf` của framework iOS. Phần nhân chạy ở tốc độ CPU gốc; chỉ tầng ứng dụng userspace (`arm64-v8a`, `armeabi-v7a`, `armeabi`) chạy qua bộ thông dịch **Gadget Engine** (hoặc Hybrid JIT tùy chọn).
- **Vì sao tập trung 100% vào Android (lược bỏ giao diện Linux Desktop):**
  - Thực tế nhu cầu lớn nhất của người dùng iOS là **cài ứng dụng Android (`.apk`)** không có trên App Store, chạy môi trường **Sandbox cách ly an toàn**, và đặc biệt là **treo game / treo tài khoản phụ (AFK)** ngay trên iPhone/iPad mà không cần mang theo máy phụ.
  - Trên iOS, hệ sinh thái ứng dụng Linux desktop không tối ưu cho màn hình cảm ứng nhỏ và trải nghiệm kém tiện hơn Windows/macOS; dồn toàn lực vào Android giúp app tinh gọn, nhẹ dung lượng và tối ưu sâu hơn cho trải nghiệm di động.

### 1.2. Bản quyền & Tính chính danh (Phát triển Fork Độc lập, Không Đạo Nhái)
- Dự án được xây dựng hợp pháp trên nền mã nguồn mở của **[`imxieyi/Kernarium`](https://github.com/imxieyi/Kernarium)** (tác giả Yi Xie) theo giấy phép **`GPL-2.0-or-later`** (cho phần host/runtime/kernel) và **`Apache-2.0`** (cho phần overlay/cây nguồn Android), kèm ghi công thiết kế gadget lấy cảm hứng từ **[`ish-app/ish`](https://github.com/ish-app/ish)**.
- Mọi sản phẩm của Dynarium phải giữ nguyên các tiêu đề giấy phép (`SPDX-License-Identifier`) tương ứng theo từng vùng mã nguồn và ghi công đầy đủ dự án gốc trong `CREDITS.md` / màn hình Giới thiệu trong app.
- **Giá trị sáng tạo riêng của Dynarium (những gì bản gốc `Andarium` không làm hoặc từ chối hỗ trợ):**
  1. **Mở khóa cho iOS 16, 17, 18 và 26:** Bản gốc khóa cứng mức sàn `27.0` (chỉ chạy iOS 27), bỏ rơi rất nhiều thiết bị có phần cứng rất mạnh (ví dụ **iPhone 13 Pro / 14 Pro / 14 Pro Max chip A16** đang ở iOS 16–17 hoặc sử dụng TrollStore).
  2. **Tăng tốc GPU phần cứng cho iOS 16–18:** Bổ sung backend **Google ANGLE (Metal 2/3)** để không bị rơi về render CPU chậm chạp trên các bản iOS chưa có Metal 4.
  3. **Chế độ Treo Máy Thông Minh (`AFK Eco Mode` + `Picture-in-Picture` chạy nền):** Bản gốc `Andarium` tắt hoàn toàn chạy nền (thoát app là đóng băng máy ảo). Dynarium biến khả năng treo máy chạy ngầm thành tính năng mũi nhọn.
  4. **Hệ thống `Dynarium Smart Profile`:** Tự động nhận diện đời chip Apple, RAM khả dụng và trạng thái quyền `MAP_JIT`/TrollStore để tự áp cấu hình tối ưu cho từng máy.
  5. **Giao diện SwiftUI + UIKit thiết kế mới 100% (tương thích iOS 16.0+)** thay cho giao diện iOS 27 của `Andarium`.

---

## 2. Kiến trúc Kỹ thuật Đột phá của `Dynarium`

### 2.1. Đa tầng Đồ họa Tự động (`Adaptive GPU Tiering`)
Trong dự án gốc, `darwin/device/gpu/host_gl_provider.cpp` bọc lớp EGL cho `virglrenderer`. Dynarium tách lớp này thành bộ điều phối 3 tầng tự động chọn lúc khởi chạy theo phiên bản iOS và phần cứng GPU:

| Tầng (Tier) | Điều kiện Thiết bị & iOS | Đường ống Đồ họa (Backend) | Năng lực & Ghi chú |
| :--- | :--- | :--- | :--- |
| **Tier 1 — Metal 4 Ultra** | **iOS 26.0+** & Chip A14 / M1 trở lên | `Guest Mesa (Virgl / Venus)` $\rightarrow$ `vhost-user` $\rightarrow$ `virglrenderer` $\rightarrow$ `Mesa Zink` / `KosmicKrisp` $\rightarrow$ `Metal 4` (`MTLTexture`) | Giữ nguyên sức mạnh tối đa của bản gốc: **Vulkan 1.4 + OpenGL 4.6 + GLES 3.2**. Nạp động (`dlopen`) plugin KosmicKrisp chỉ khi máy chạy iOS 26+. |
| **Tier 2 — Metal 2/3 Hardware** | **iOS 16.0 – 18.x** & Chip A12 $\rightarrow$ A18 / M1 $\rightarrow$ M4 *(mục tiêu trọng tâm cho iPhone 14 Pro Max A16)* | `Guest Mesa (Virgl)` $\rightarrow$ `vhost-user` $\rightarrow$ `virglrenderer` (chế độ EGL/GLES host) $\rightarrow$ **`Google ANGLE` (Metal 2/3)** $\rightarrow$ `IOSurface` zero-copy $\rightarrow$ `MTLTexture` | **Tăng tốc phần cứng GPU thật 100%** cho giao diện Android (`skiagl`), trình duyệt, video và phần lớn game/app **OpenGL ES 3.0 / 3.1**. Ẩn capset Vulkan 1.4 (`Venus`) trên iOS < 26 (do MoltenVK thiếu cơ chế Virtio-GPU shared-memory/blob lifetime). |
| **Tier 3 — CPU Safe Fallback** | Thiết bị không hỗ trợ hoặc lỗi khởi tạo GPU backend | `Mesa llvmpipe` (ARM NEON đa luồng, kế thừa từ nhánh iOS Simulator của upstream) | Đảm bảo máy ảo luôn khởi động được để sao lưu dữ liệu hoặc cứu hệ thống, không bao giờ văng app đột ngột. |

### 2.2. Hệ thống Tự nhận diện Phần cứng (`Dynarium Smart Profile`) & Ngân sách Chống Jetsam
iOS dùng cơ chế **Jetsam (OOM Killer)** để đóng ngay ứng dụng nếu tổng RAM vượt trần cho phép $L$ (lấy từ `os_proc_available_memory()` / `platform::process_memory_limit_bytes()`). Khi boot, Dynarium tính cứng ngân sách bộ nhớ GPU $B$ để không bị iOS giết app giữa chừng:

$$B = \max(L - A - G - E - S,\; 384\text{ MiB})$$

Trong đó:
- $L$: Tổng giới hạn bộ nhớ tiến trình iOS cấp cho app.
- $G$: RAM cấp cho máy ảo Android (`mem=`).
- $E$: Bộ nhớ phụ trợ của engine & cache dịch lệnh theo số vCPU.
- $A$: Trần bộ nhớ ước tính cho bản thân giao diện app iOS.
- $S$: Khoảng đệm an toàn tránh đột biến cấp phát.

**Bảng cấu hình tự động (`Smart Chip & RAM Profile`) đề xuất:**

| Nhóm thiết bị đại diện | RAM máy | vCPU | Guest RAM ($G$) | GPU Pool ($B$ mục tiêu) | Hiển thị & Chính sách |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Tiêu chuẩn** *(iPhone 11, 12, 13, SE3)* | 4 GB | 2–3 nhân | `1.5 GiB` | ~`512 MiB` | 720p (tắt Retina), bật trim page-cache tích cực (`uml_emulator_trim_page_cache()`). |
| **Cận cao cấp** *(iPhone 13 Pro, 14 Pro / 14 Pro Max A16, 15)* | 6 GB | 4–5 nhân | `2.0 – 2.5 GiB` | `768 MiB – 1 GiB` | 1080p sắc nét, ưu tiên cân bằng nhiệt độ khi chạy lâu. |
| **Pro / iPad M-series** *(iPhone 15 Pro+, 16/17 Pro, iPad M1–M4)* | 8–16 GB | 6–8 nhân | `3.5 – 6.0 GiB` | `1.5 – 3.0 GiB` | Bật độ phân giải Retina đầy đủ, tối đa hóa VRAM cho game/ứng dụng nặng. |

**Đặc quyền cho thiết bị iOS 16.0 – 17.0 (TrollStore / Jailbreak):**
- Khi cài qua TrollStore, hai entitlement `com.apple.developer.kernel.increased-memory-limit` và `com.apple.developer.kernel.extended-virtual-addressing` được cấp vĩnh viễn mà không phụ thuộc giới hạn provisioning của Apple ID miễn phí (7 ngày).
- **Định hướng Hybrid Execution (Giai đoạn 5):** Ở upstream (Issue #14), bật JIT ngay từ đầu làm Android boot **chậm hơn** chạy thông dịch vì quá trình khởi động Android sinh ra hàng trăm tiến trình ngắn hạn, khiến chi phí biên dịch & xóa cache liên tục quá lớn. Dynarium giữ mặc định **Gadget Engine** (`A64` + `A32/T32` cho app 32-bit `armeabi-v7a`) để boot nhanh và ổn định; trên máy có quyền `MAP_JIT` / TrollStore sẽ nghiên cứu cơ chế kích hoạt JIT có chọn lọc cho các tiến trình game/app chạy dài hơi.

### 2.3. Hệ thống "Treo Máy Thông Minh" (`AFK & PiP Keep-Alive`)
Đây là tính năng tạo khác biệt thực tế lớn nhất của Dynarium so với `Andarium` gốc:
1. **Chạy nền qua Picture-in-Picture (`AVPictureInPictureController`):**
   - Xuất luồng video thu gọn của khung hình Android sang cửa sổ nổi PiP (kết hợp tùy chọn giữ phiên âm thanh nền khi cần), giúp người dùng thoát ra màn hình chính iPhone hoặc dùng Zalo/Safari/TikTok mà máy ảo Android bên dưới vẫn tiếp tục hoạt động, không bị iOS đóng băng tiến trình.
2. **Chế độ Tiết kiệm Pin & Giảm nóng khi treo (`AFK Eco Mode`):**
   - Nút bật nhanh ngay trên thanh điều khiển nổi khi treo game/app:
     - Giữ nguyên nhân Android, timer mạng (`libslirp`) và tác vụ app Android chạy bình thường.
     - Hạ tốc độ dựng khung hình hiển thị trên host xuống **`5–10 FPS`** (hoặc phủ màn hình đen tiết kiệm pin cho màn OLED để không làm nóng GPU Metal).
     - Áp dụng **vCPU throttle** vừa đủ và gọi `uml_emulator_trim_page_cache()` định kỳ nhằm giữ RAM ở mức thấp và tránh thermal throttling sau nhiều giờ treo máy.

---

## 3. Bản đồ Mã nguồn Upstream (`imxieyi/Kernarium`) & Các Điểm Cần Can Thiệp

### 3.1. Prebuilt Artifacts có sẵn từ Upstream
Trong các giai đoạn đầu, **không cần máy chủ Linux `x86_64`** để biên dịch lại nhân Linux hay build lại ROM AOSP LineageOS 24 từ con số 0. Tái sử dụng trực tiếp hai gói nhị phân đã được kiểm thử từ bản Release **`1.0b9-beta`** của `imxieyi/Kernarium`:
- **Kernel Android 6.18 (4 KiB page):** `android-6.18-arm64-4k-20261111-6.18.60-mc2.tar.gz` (~10.8 MB) — dùng để nhúng vào phần `__TEXT,__uml_elf` của runtime framework.
- **ROM Hệ thống LineageOS 24 (Android 17):** `lineage24-mainline6.18-4k-20261110-los24-r22.tar.gz` (~986.9 MB).

### 3.2. Các Thành phần Cốt lõi Giữ lại & Điểm Cần Sửa Đổi

| Đường dẫn / Thành phần Upstream | Trạng thái Hiện tại (Upstream) | Việc cần làm cho Dynarium (iOS 16.0+) |
| :--- | :--- | :--- |
| `darwin/cpu/`, `darwin/memory/`, `darwin/runtime/`, `darwin/platform/`, `darwin/device/` (trừ GPU) | C++20/ASM chuẩn Darwin, phần lớn API POSIX/Mach/VideoToolbox dùng được trên iOS 16+ | Giữ nguyên kiến trúc lõi 1 chiều (`app -> emulator -> runtime -> cpu -> memory -> platform`), rà soát nếu có API SDK mới > 16.0 thì bọc điều kiện tương thích. |
| `cmake/toolchains/Apple.cmake` | Khóa cứng `set(_uml_apple_deployment_target 27.0)` và ném `FATAL_ERROR` nếu truyền phiên bản khác | Chuyển thành tham số cấu hình linh hoạt: mặc định `16.0` cho bản Universal iOS, và cho phép truyền `26.0` riêng khi build plugin `KosmicKrisp`. |
| `dependencies/build-apple-gpu.sh`<br>`dependencies/build-ios-network.sh`<br>`dependencies/build-ios-storage.sh`<br>`dependencies/build-ios-zstd.sh` | Gán cứng `DEPLOYMENT_TARGET=27.0` trong cờ `-target arm64-apple-ios$DEPLOYMENT_TARGET` và `MinimumOSVersion` trong `Info.plist` | Hạ `DEPLOYMENT_TARGET` xuống `16.0` cho `libslirp`, `glib-ios`, `proxy-libintl`, `zstd`, `gptfdisk`, `libepoxy`, `virglrenderer`, `Mesa llvmpipe`; bổ sung build `Google ANGLE` Metal cho iOS 16.0. |
| `darwin/device/gpu/host_gl_provider.hpp/.cpp`<br>`virgl_renderer.hpp/.cpp`<br>`metal_presentation.hpp/.mm` | Chỉ hỗ trợ `Zink/KosmicKrisp` (Metal 4) hoặc `llvmpipe` (Simulator) tại thời điểm biên dịch | Tách `HostGlProvider` thành kiến trúc đa backend lúc chạy (runtime selection): `AngleMetalGlProvider` (iOS 16–25), `KosmicKrispZinkProvider` (`dlopen` khi `@available(iOS 26, *)`), `SoftwareGlProvider` (fallback). Nối `IOSurface` từ ANGLE trực tiếp vào `MTLTexture` trong `MetalPresentation`. |
| `Andarium/Andarium.xcodeproj/project.xcproj` | Dùng định dạng JSON của Xcode 27 (Xcode 16 / 26 không mở được trực tiếp) | Thay hoàn toàn bằng **`XcodeGen` (`Dynarium/project.yml`)** để sinh `.xcodeproj` tự động trên mọi phiên bản Xcode của GitHub Actions. |
| `Andarium/Andarium/Shared/` & `Live/` | Dùng `@Observable`, `TipKit`, `.containerRelativeFrame` (chỉ có từ iOS 17+) | Thiết kế giao diện **`Dynarium` mới 100% chuẩn iOS 16.0+** (`ObservableObject` / `@Published`), giữ lại và tái sử dụng các module logic ổn định như `GuestAdb`, `AdbKeyStore`, `ApkInstall` (cài `.apk` qua `Virtio vsock`) và `GuestHost/Sources/` (`GuestDisplay.swift`, `GuestInput.swift`, `ZstdUtil.swift`). |

### 3.3. Năm Ràng Buộc Sống Còn (Invariants) Tuyệt Đối Không Được Phá Vỡ
1. **Cấm dùng thanh ghi `x18`:** Không một file C/C++/ASM nào dưới `darwin/` hay `Dynarium/` được dùng thanh ghi `x18` (Darwin xóa thanh ghi này khi chuyển/ngắt thread).
2. **Kiến trúc Trang nhớ 4 KiB trên 16 KiB:** Guest Android bắt buộc dùng trang **4 KiB** (do thư viện 32-bit `armeabi-v7a` căn lề 4 KiB), ánh xạ qua Software MMU 128 TiB trên trang **16 KiB** của Apple host.
3. **Cấm giữ File Lock (`flock`/`fcntl`) khi iOS vào nền (suspend):** iOS sẽ giết ngay ứng dụng nếu phát hiện tiến trình giữ file lock khi bị đóng băng. Mọi truy cập file đĩa phải đi qua `platform/guest_files` và luồng `uml_emulator_quiesce()` / hibernation vào `` `$TMPDIR` ``.
4. **Độc quyền Bộ nhớ Thực thi:** Chỉ duy nhất `darwin/cpu/jit_memory/executable_memory.cpp` được quản lý vùng nhớ thực thi; các stream của Gadget Engine luôn phải là dữ liệu thuần túy (`non-executable data`).
5. **Mạng `libslirp`:** Giữ tắt DNS proxy của SLiRP và đi qua system resolver của iOS để tránh kích hoạt cảnh báo quyền *Local Network* không cần thiết khi chỉ vào Internet.

---

## 4. Quy trình Làm việc trên Windows & Build Tự động qua GitHub Actions

Vì máy lập trình chạy **Windows** (không có Xcode hay Apple SDK), toàn bộ bước biên dịch thư viện C/C++, CMake và đóng gói `.ipa` được thực hiện trên **macOS ARM64 Runners của GitHub Actions**, tách thành 2 workflows để không bị chạm giới hạn thời gian (timeout):

1. **Workflow 1 — `.github/workflows/build-deps.yml` (Build Thư viện Nền):**
   - Kích hoạt thủ công hoặc khi thư mục `dependencies/` thay đổi.
   - Biên dịch toàn bộ static libraries + GPU providers ở target `arm64-apple-ios16.0` (trên runner `macos-15` / `macos-26`) và riêng slice `KosmicKrisp` ở target `arm64-apple-ios26.0` (trên `macos-26`).
   - Đóng gói kết quả thành GitHub Release Asset / Artifact cache để Workflow 2 tải về trong vài giây.
2. **Workflow 2 — `.github/workflows/build-ipa.yml` (Build Runtime & Đóng gói `.ipa`):**
   - Chạy mỗi khi push code C++/Swift.
   - Tải gói dependencies đã dựng sẵn + tải prebuilt `android-6.18` kernel & `lineage24` image từ upstream Release `1.0b9-beta`.
   - Chạy `CMake + Ninja` tạo `DynariumRuntime.xcframework`.
   - Chạy `xcodegen generate` từ `Dynarium/project.yml`.
   - Chạy `xcodebuild` với `CODE_SIGNING_ALLOWED=NO`, sau đó dùng `ldid -SConfig/Dynarium.entitlements` để gắn sẵn hai quyền `increased-memory-limit` & `extended-virtual-addressing`.
   - Xuất file **`Dynarium.ipa`** (unsigned kèm entitlements) để tải về cài qua **TrollStore**, **SideStore**, **AltStore**, **Feather** hoặc **LiveContainer**.

> **Lưu ý đặc biệt cho Windows (CRLF vs LF):** Bắt buộc tạo file `.gitattributes` ép `eol=lf` cho toàn bộ script `.sh`, `.py`, file `.patch` và `.tsv` ngay ở Giai đoạn 1. Nếu Windows tự đổi sang `CRLF`, các runner macOS/Linux trên GitHub Actions sẽ lỗi cú pháp khi chạy script shell.

---

## 5. Lộ trình Triển khai 5 Giai đoạn (Checklist Tiến độ)

- [ ] **Giai đoạn 1 — Khởi tạo Nguồn, Hạ sàn CMake/Deps xuống `iOS 16.0` & Xanh hóa Workflow Dependencies**
  - Nhập cây mã nguồn lõi từ `imxieyi/Kernarium` vào `C:\dynarium`, thiết lập `.gitattributes` (ép `LF`), thêm `CREDITS.md` và giữ nguyên giấy phép `GPL-2.0-or-later` / `Apache-2.0`.
  - Hạ mốc khóa `27.0` trong `cmake/toolchains/Apple.cmake` và các script `dependencies/build-ios-*.sh` xuống `16.0`.
  - Viết `.github/workflows/build-deps.yml` và chạy thành công bộ thư viện nền + `Mesa software/llvmpipe` (làm đường ống test khởi động đầu tiên).

- [ ] **Giai đoạn 2 — Xây dựng Ứng dụng `Dynarium` (UI iOS 16.0+) + `XcodeGen` + Xuất bản `.ipa` Boot Android Đầu tiên**
  - Tạo `Dynarium/project.yml` (`XcodeGen`, target `IPHONEOS_DEPLOYMENT_TARGET: 16.0`).
  - Xây dựng giao diện SwiftUI mới cho iOS 16+ (`ObservableObject`), tích hợp `GuestDisplay` (Metal + cảm ứng 10 điểm), cài `.apk` qua `GuestAdb` (`Virtio vsock`).
  - Viết `.github/workflows/build-ipa.yml` tải kernel `android-6.18` + ROM `lineage24`, biên dịch `DynariumRuntime` và xuất ra file `Dynarium.ipa` gắn sẵn entitlements qua `ldid`.
  - Cài thử nghiệm và kiểm chứng Android 17 boot lên màn hình chính trên thiết bị thật chạy iOS 16 / 17 / 18 (dù tạm ở bước này dùng renderer `llvmpipe` để chốt chạy được trước).

- [ ] **Giai đoạn 3 — Mở khóa GPU Phần cứng `Google ANGLE (Metal 2/3)` cho iOS 16–18**
  - Bổ sung script build/nạp tĩnh hoặc framework `Google ANGLE` (`libEGL` + `libGLESv2` Metal backend) ở `arm64-apple-ios16.0`.
  - Tái cấu trúc `HostGlProvider` + `VirglRenderer` để chạy `virglrenderer` qua EGL/GLES trên `ANGLE` và nối `IOSurface` (`EGL_ANGLE_iosurface_client_buffer`) trực tiếp vào `MTLTexture` trong `MetalPresentation`.
  - Xác nhận hiệu năng UI Android & ứng dụng 3D GLES trên chip A15/A16/M-series chạy iOS 16–18.

- [ ] **Giai đoạn 4 — Tính năng Độc quyền "Treo Máy Thông Minh" (`PiP` + `AFK Eco Mode`)**
  - Triển khai `AVPictureInPictureController` và luồng giữ tiến trình sống ở chế độ nền cho máy ảo Android.
  - Bổ sung bảng điều khiển nhanh **AFK Eco Mode**: hạ tần suất dựng hình trên host xuống `5–10 FPS` / màn che OLED đen tại chỗ, điều tiết nhịp vCPU và tự động chạy `uml_emulator_trim_page_cache()` định kỳ.

- [ ] **Giai đoạn 5 — Hoàn thiện `Smart Chip Profile`, Dual-Backend `KosmicKrisp` (iOS 26+) & Tối ưu Nâng cao**
  - Hoàn thiện bộ nhận diện đời chip (`A12` $\rightarrow$ `A20`, `M1` $\rightarrow$ `M5`), RAM và cảnh báo ngưỡng Jetsam tự động.
  - Tích hợp plugin `KosmicKrisp` nạp động (`dlopen`) chỉ khi chạy trên iOS 26.0+ để giữ nguyên Vulkan 1.4 trên các máy mới.
  - Nghiên cứu và thử nghiệm **Hybrid Execution** (boot bằng Gadget Engine cho nhanh, chỉ kích hoạt JIT chọn lọc cho tiến trình game nặng trên máy có TrollStore / `MAP_JIT`).

---

## 6. Hướng dẫn Mở Phiên Làm Việc Mới tại `C:\dynarium`

1. Trong công cụ Antigravity, chọn mở thư mục **`C:\dynarium`** làm **Active Workspace** (thay cho chế độ No Project).
2. Khi mở cuộc trò chuyện mới trong thư mục này, agent sẽ tự động đọc `AGENTS.md` và `PLAN.md`.
3. Bạn chỉ cần gõ câu lệnh bắt đầu ngay:
   > *"Hãy đọc `PLAN.md` và bắt đầu triển khai Giai đoạn 1: chuẩn bị cấu trúc repo `Dynarium`, tải/nhập mã nguồn lõi từ `imxieyi/Kernarium` vào `C:\dynarium` và cấu hình `.gitattributes` + CMake/deps xuống iOS 16.0."*
