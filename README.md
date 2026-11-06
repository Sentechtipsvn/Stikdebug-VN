# StikDebug VN 3.2.2 — beta 2

Bản Việt hóa và nâng cấp mô phỏng tuyến của [StikDebug](https://github.com/StikDebug/StikDebug), do © Sentechtipsvn phát triển trên bản fork. Giữ giấy phép AGPL-3.0 và ghi công tác giả gốc.

- Chọn điểm bằng link Apple Maps/Google Maps, tọa độ, Dấu trang, tìm kiếm hoặc bản đồ.
- Lấy vị trí thiết bị cho điểm đi; phân biệt vị trí đang mô phỏng.
- Tuyến nhiều điểm; nhập tự do thời gian nghỉ bằng giây/phút/giờ, tự đi tiếp và giữ bộ đếm khi tạm dừng.
- Trạng thái rõ ràng, tốc độ mô phỏng tách khỏi tốc độ đặt, Về GPS thật có xác nhận kết quả lệnh.
- Phím tắt chia sẻ vị trí vào app để đặt một điểm, dùng làm điểm đến hoặc thêm trạm; mở phím tắt không đầu vào để soạn tuyến.
- Sửa bản nháp khi đang chạy; chỉ áp dụng sau xác nhận, giữ tọa độ và phần nghỉ còn lại, chờ Tiếp tục.
- Lưu đường đi và cấu hình, mở lại và xuất/nhập JSON; giữ nhập GPX/KML/GeoJSON/CSV/text.
- Giao diện tiếng Việt, tài nguyên dịch tách riêng; giữ các công cụ JIT, Scripts, nhật ký và thiết bị.

## Bản thử nghiệm

- Cần iOS 17.4 trở lên. Máy đích của dự án là iPhone 11/iOS 18.7.8.
- Build bằng workflow **Build StikDebug VN IPA**. IPA không ký; ký/cài bằng phương thức sideload của người dùng.
- Tên cài đặt **StikDebug VN**, Bundle ID `com.sentechtipsvn.stikdebugvn`. Cập nhật đè lên VN 3.2.1 bằng cùng AltStore/tài khoản; không gỡ app VN để giữ dữ liệu. Bản gốc vẫn có mã ứng dụng riêng.
- Sandbox riêng: pairing, cấu hình và Bookmarks của bản gốc không tự chuyển. Nhập lại pairing/VPN và thêm/nhập dữ liệu trong bản VN; không cần gỡ bản gốc.
- URL scheme riêng `stikdebugvn://` và `stikjitvn://`; endpoint và tham số tương đương bản gốc. Ví dụ `stikdebugvn://simulate-location?lat=10.87139&lon=106.73716`.
- Link rút gọn và tính tuyến mới cần mạng. Link chỉ có tên/Place ID có thể cần chọn lại kết quả; không cam kết mọi link đều phân giải chính xác. Đường đi đã lưu có thể phát lại mà không tính tuyến mới, nhưng lớp bản đồ và kết nối mô phỏng có yêu cầu riêng.
- Nếu bị đình chỉ khi di chuyển, bộ phát tạm dừng tại tiến độ đã xác nhận. Khi đang nghỉ, đối chiếu hạn nghỉ lúc được chạy lại rồi tiếp tục từ trạm, không chạy bù quãng đường. Chạy nền, khóa màn hình và liên kết thực tế cần thử trên iPhone.

`Validation/main.swift` kiểm tra logic thuần. `Validation/Controller` chạy đúng controller, session và kho bản nháp dùng trong app với đồng hồ điều khiển và biên thiết bị mô phỏng. `Validation/verify_bridge.py` kiểm tra đồ thị tác vụ/phân nhánh/mã hóa của phím tắt; đây không phải chạy Shortcuts trên iPhone. Phím tắt đã được ký bằng Shortcuty; CI đối chiếu SHA-256 và bao AEA1 trước khi tải lên. [Hướng dẫn 3.2.2](docs/THU_BAN_VN_3.2.2.md). Build thành công không thay thế kiểm thử thiết bị hoặc đánh giá của người dùng.

Bản nháp được chuẩn bị để chủ repo đọc, hiểu và thử trước khi gửi PR hoặc hợp nhất theo [AGENTS.md](AGENTS.md). Sếp đã thử VN 3.2.1; thay đổi 3.2.2 cần kiểm thử iPhone sau khi CI đạt. Không mở PR/issue tự động.

---

<div align="center">
   <img width="217" height="217" src="/assets/StikDebug.png" alt="Logo">
</div>

<div align="center">
  <h1><b>StikDebug</b></h1>
  <p><i>An on-device debugger/JIT enabler for iOS versions 17.4+ powered by <a href="https://github.com/jkcoxson/idevice">idevice</a>.</i></p>
</div>

<h3 align="center">
  <a href="https://discord.gg/ZnNcrRT3M8"><img src="https://img.shields.io/badge/Discord-join%20us-7289DA?logo=discord&logoColor=white&style=for-the-badge&labelColor=23272A" /></a>&nbsp;
  <a href="https://github.com/StikDebug/StikDebug/blob/main/LICENSE"><img src="https://img.shields.io/github/license/StikDebug/StikDebug?label=License&color=5865F2&style=for-the-badge&labelColor=23272A" /></a>&nbsp;
  <a href="https://github.com/StikDebug/StikDebug"><img src="https://img.shields.io/github/stars/StikDebug/StikDebug?label=Stars&color=FEE75C&style=for-the-badge&labelColor=23272A" /></a>&nbsp;
  <a href="https://github.com/StikDebug/StikDebug/releases"><img src="https://img.shields.io/github/v/release/StikDebug/StikDebug?label=Latest&color=00BFFF&style=for-the-badge&labelColor=23272A" /></a>&nbsp;
   <a href="https://deepwiki.com/StikDebug/StikDebug"><img src="https://img.shields.io/badge/Ask-DeepWiki-grey?style=for-the-badge&labelColor=23272A&color=007ec6" /></a>
   <br />
</h3>

## Features
- **JIT:** Enable Just-In-Time compilation for sideloaded apps that have the `get-task-allow` entitlement.
- **App Launching:** Launch every app installed on your device.
- **Console:** Live app and system logs.
- **Scripts:** Manage automation scripts (mainly used for iOS 26 JIT). 
- **App Expiry:** See when apps will expire and install/remove profiles.
- **Device Info:** View detailed device metadata.
- **Processes:** Inspect running apps/processes and terminate them.
- **Location Simulator:** Simulate the GPS location of your device.

## Download
> [!NOTE]
> **Notice:** StikDebug is no longer available on the App Store. Please use the official download methods below.

<h3 align="center">
<a href="https://altdirect.app/?url=https://stikdebug.xyz/index.json" target="_blank"><img src="https://altdirect.app/assets/png/AltSource_Blue.png" alt="Add AltSource" width="200"></a>
&nbsp;
<a href="https://github.com/StikDebug/StikDebug/releases/latest/download/StikDebug-3.1.15.ipa" target="_blank"><img src="https://altdirect.app/assets/png/Download_Blue.png" alt="Download .ipa" width="200"></a>
</h3>

## Compatibility

| iOS Version              | Status               | Notes                                                                 |
|--------------------------|----------------------|-----------------------------------------------------------------------|
| 1.0 – 17.3.X             | Not supported        | Uses Different Connection Protocols                                   |
| 17.4 – 18.x              | Fully supported      | Stable                                                                |
| 26.0+              | Supported            | Limited App Availability (Developers need to update their apps to work.) |

See [Officially Supported Apps](SUPPORTED_APPS.md) for the apps supported by the StikDebug team and their bundled scripts.

## How to Enable JIT

StikDebug enables **JIT** for sideloaded apps on iOS 17.4+ without needing a computer after the initial pairing setup.

### Requirements
- StikDebug installed (via AltSource, direct .ipa, or self-built)
- A valid **pairing file** (.plist / .mobiledevicepairing) for your device
- SideStore / AltStore / similar sideload tool (for app refreshing)
- A loopback VPN such as [LocalDevVPN](https://apps.apple.com/us/app/localdevvpn/id6755608044)

### Steps
1. **Obtain a pairing file**  
   - Detailed guide: [Pairing File Instructions](PAIRING.md) (or ask in Discord).

2. **Set up VPN**  
   - Launch LocalDevVPN and enable the VPN.

4. **Enable JIT for an app**  
   - Launch StikDebug and tap the `Enable JIT` button.
   - Select your sideloaded app from the list in StikDebug.  

**Troubleshooting**  
- "Connection dropped" or loopback errors → Check iOS version compatibility / beta warnings.  
- Heartbeat errors → Ensure that the VPN is on and that you are connected to Wi-Fi. It may be a pairing file issue.
- Pairing file issues → Replace file with device unlocked & trusted.  
- Still stuck? Join the [Discord](https://discord.gg/ZnNcrRT3M8) with logs/screenshots.

<!-- 
## Screenshots

<div align="center">
  <img src="screenshots/pairing-import.png" width="320" alt="Pairing file import screen">
  <img src="screenshots/app-list.png" width="320" alt="Sideloaded apps list">
  <img src="screenshots/jit-enabled.png" width="320" alt="JIT successfully enabled">
  <img src="screenshots/processes.png" width="320" alt="Process management tab">
</div>

(Add images to a /screenshots/ folder in the repo and uncomment when ready.)
-->

## Kill a Process by URL

Use `stikdebug://kill-process?name=ProcessName` to terminate a running process by its exact, case-sensitive executable name, not its bundle ID. For example: `stikdebug://kill-process?name=LiveContainer`. Percent-encode names containing spaces or other special characters.

StikDebug asks for confirmation, then looks up the current PID before terminating the process. If several processes have the same name, use `stikdebug://kill-process?pid=1234` to select one. When both parameters are provided, `pid` takes precedence.

## Building from Source

> [!IMPORTANT]
> **Integrating StikDebug or StikJIT into your own project?**  
> See the [StikJIT Integration Guide](https://github.com/StikDebug/StikJIT/blob/main/INTEGRATION.md) for integration instructions.

### Requirements
- macOS (latest recommended)
- Xcode 27 or later (required for the new `.xcproj` project format)
- iOS device on iOS 17.4+ (for testing)
- Git
- Basic Xcode/Swift knowledge

### Steps
1. **Clone the repo**
   ```bash
   git clone https://github.com/StikDebug/StikDebug.git
   cd StikDebug
   ```

2. **Open in Xcode**
   - Launch Xcode
   - Open `StikDebug.xcodeproj`

3. **Configure signing**
   - Select the **StikDebug** target
   - Go to **Signing & Capabilities**
   - Sign in with your Apple ID (free or paid developer account)
   - Set a unique **Bundle Identifier** (e.g., `com.yourname.StikDebug`)

4. **Build & install**
   - Select your connected device
   - Press **Cmd + R** (or Product → Run)
   - Trust the certificate on device: Settings → General → VPN & Device Management

After install, follow the JIT setup steps above (pairing import, etc.).

## Contributing

Thank you for your interest in contributing to this project. Contributions of all kinds are welcome.

### Reporting Bugs
If you discover a bug, please open an issue and include:
- A clear and descriptive title
- Steps to reproduce the issue
- Expected behavior vs. actual behavior
- Relevant logs, screenshots, or environment details (iOS version, device model, etc.)

### Suggesting Features
To propose a new feature, open a feature request issue and provide:
- A clear description of the feature
- The problem it solves or the use case it addresses
- Any relevant examples or implementation ideas

### Code Contributions (Best Practices)
- Follow normal Swift and SwiftUI style.
- Write clear and easy-to-understand code.
- Keep your changes consistent with how the project is already set up.
- Make sure everything builds and works without errors.

We appreciate your time and effort in helping improve this project.

## License
StikDebug is licensed under **AGPL-3.0**. See [`LICENSE`](LICENSE) for details.

