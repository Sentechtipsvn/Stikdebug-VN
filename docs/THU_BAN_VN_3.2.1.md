# Thử StikDebug VN 3.2.1 beta 1

Bản này đã có mã Việt hóa và các nâng cấp tuyến. IPA được tạo bởi workflow **Build StikDebug VN IPA** trên nhánh `work/vn-3.2.1`. Không dùng IPA có tên chỉ `StikDebug-9d7a917.ipa`: đó là bản gốc.

## Cài bản VN

1. Tải artifact có tên `StikDebug-VN-3.2.1-<commit>.ipa` từ lượt build VN thành công mới nhất.
2. Ký và cài qua AltStore/phương thức sideload đang dùng trên **iPhone 11/iOS 18.7.8**. IPA do CI tạo chưa ký. Không thử bản này trên iPhone 7 Plus/iOS 15.
3. App hiển thị tên **StikDebug VN**, Bundle ID trước khi ký lại là `com.sentechtipsvn.stikdebugvn`. Có thể giữ bản gốc cài song song.
4. Nhập pairing cho thiết bị, kết nối LocalDevVPN và chờ DDI/kết nối sẵn sàng. Đây là sandbox mới nên pairing, cấu hình và Bookmarks của bản gốc không tự chuyển.

## Các thao tác cần thử trên iPhone

| Thao tác | Kết quả cần quan sát |
| --- | --- |
| Mở JIT, Công cụ, Cài đặt, Kịch bản, Nhật ký | Nhãn giao diện tiếng Việt; chức năng gốc vẫn sử dụng được |
| Công cụ → Mô phỏng vị trí → Chọn vị trí | Dán được link Apple Maps/Google Maps hoặc tọa độ và xem ghim trước khi dùng |
| Dán link chỉ có tên địa điểm | Hiện danh sách để chọn, không âm thầm đoán một tọa độ |
| Dán link rút gọn | Cần mạng để phân giải; link không đọc được phải báo lỗi rõ ràng |
| Đặt một vị trí, mở Maps rồi bấm Dừng | Có mô phỏng một điểm; sau xóa mô phỏng, kiểm tra bằng bản cập nhật vị trí mới của Maps |
| Chọn điểm rồi Lưu thành Dấu trang | Điểm đó xuất hiện trong Dấu trang và trong picker của từng điểm tuyến |
| Tạo tuyến, dùng Vị trí thiết bị làm điểm đi | Có bản cập nhật vị trí mới; khi đang mô phỏng phải có nhãn phù hợp, không khẳng định GPS thật |
| Thêm 2–3 điểm dừng, bấm Sửa và đổi thứ tự | Tuyến nối các chặng đúng thứ tự; chỉ rõ chặng lỗi nếu không tìm được đường |
| Đặt thời gian dừng ở điểm trung gian | Bộ phát giữ điểm trong thời gian đã chọn; ETA gồm thời gian dừng |
| Bắt đầu ở 30 km/h rồi đổi tốc độ | Tiến độ tiếp tục từ vị trí hiện tại; thời gian còn lại thay đổi cùng tốc độ |
| Tạm dừng vài giây rồi Tiếp tục | Giữ vị trí/tiến độ, tiếp tục từ đó, không quay về đầu |
| Chuyển màn hình trong app khi tuyến đang chạy | Phiên phát được quản lý ở controller chung, không tạo phiên thứ hai |
| Lưu tuyến với tên riêng, đóng/mở lại app | Mở lại đúng điểm, đường đi, tốc độ và thời gian dừng |
| Mở Tuyến đã lưu, vuốt trái → Xuất; Nhập JSON | Xuất/nhập lại được; không thay thế nhầm dữ liệu của tuyến khác |
| Nhập GPX/KML/GeoJSON/CSV/text | Vẫn đọc được track/tọa độ theo định dạng được hỗ trợ |
| Chạy tuyến, gửi một yêu cầu vị trí qua URL scheme rồi bấm Dừng | Phiên cũ bị vô hiệu hóa; tọa độ cũ không được gửi lại sau thao tác mới |
| Chuyển app, khóa màn hình, ngắt rồi nối lại VPN | Ghi nhận kết quả thực tế. Nếu iOS đình chỉ lâu, bộ phát tạm dừng tại tiến độ cuối thay vì chạy bù gây nhảy vị trí |

Đường đã lưu có thể phát lại mà không gọi tính tuyến mới. Điều này không đồng nghĩa mọi lớp bản đồ tải offline hoặc mọi cấu hình VPN hoạt động không cần mạng.

## Kết nối Shortcuts

Bản VN dùng scheme riêng để tránh trùng bản gốc:

`stikdebugvn://simulate-location?lat=10.87139&lon=106.73716`

`stikdebugvn://clear-location`

Các phím tắt dùng `stikdebug://` vẫn trỏ đến bản gốc; đổi tiền tố sang `stikdebugvn://` khi muốn gửi sang bản VN. Các tích hợp bên ngoài ghi cố định scheme của bản gốc cần được kiểm tra riêng.

## Bằng chứng và giới hạn kiểm tra

Workflow chạy bộ kiểm tra Swift thuần trước khi archive cho thiết bị iOS: tọa độ hợp lệ, nội suy và khoảng cách, đổi tốc độ, dừng ở waypoint, JSON, link và vô hiệu hóa lệnh gửi lại cũ. Xem dòng `PASS:` trong log để biết số kiểm tra thực sự chạy ở commit đó.

Build và kiểm tra tự động không xác nhận hoạt động GPS, pairing, chạy nền, AltStore hay giao diện trên iPhone. Trợ lý chưa thao tác trực tiếp trên iPhone của Sếp.

Theo [AGENTS.md](../AGENTS.md), Sếp cần tự đọc/hiểu thay đổi và kiểm tra kết quả thử trước khi gửi PR/hợp nhất. Mô tả PR/issue do Sếp viết; nếu dùng AI dịch thì ghi rõ việc dịch. Nhánh hiện tại là bản nháp phục vụ đọc và thử, chưa mở PR hoặc hợp nhất vào `main`.
