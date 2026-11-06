# StikDebug VN 3.2.2 beta 2

© Sentechtipsvn. Giữ giấy phép AGPL-3.0 và ghi công StikDebug.

## Cài cập nhật

Tải **StikDebug-VN-3.2.2-<commit>.ipa** của lượt CI thành công mới nhất. Ký/cài đè bằng cùng AltStore và tài khoản đã cài VN 3.2.1. Bundle ID vẫn `com.sentechtipsvn.stikdebugvn`; không gỡ VN để giữ pairing, Dấu trang và tuyến lưu. Không cần ký thêm một ứng dụng có ID mới. IPA chưa có chữ ký cá nhân; phím tắt là tệp riêng và không chiếm suất ứng dụng của AltStore.

## Thời gian nghỉ

Tạo/sửa tuyến → ở trạm trung gian bấm **Thời gian nghỉ** → nhập số và chọn giây/phút/giờ → Lưu. Ví dụ `5` phút = 05:00, `1,5` phút = 01:30. Nhập 0 để đi qua; giới hạn 24 giờ mỗi trạm, làm tròn đến giây. Chỉ trạm trung gian có đếm giờ; đích cuối vẫn giữ vị trí.

Khi đến trạm, tốc độ mô phỏng là 0 và bộ đếm bắt đầu sau khi lệnh vị trí được xác nhận. Hết giờ tự đi tiếp. **Tạm dừng** giữ nguyên phần thời gian còn lại; **Tiếp tục** chạy tiếp bộ đếm; **Đi tiếp ngay** bỏ phần nghỉ hiện tại. Nếu iOS đình chỉ app, việc đi tiếp chỉ diễn ra khi app được thực thi trở lại; không cam kết chạy đúng giây khi hệ điều hành không cho app chạy. Không chạy bù quãng đường sau gián đoạn.

## Phím tắt StikDebug VN

Cài **StikDebug-VN.shortcut** của cùng lượt CI. Đây là cầu nối gọn, gửi dữ liệu vào `stikdebugvn://`; không dùng nhầm scheme bản gốc `stikdebug://`.

- Chia sẻ một link Apple Maps/Google Maps hoặc văn bản tọa độ → **StikDebug VN** → trong app chọn **Đặt vị trí tại đây**, **Dùng làm điểm đến** hoặc **Thêm điểm dừng**.
- Mở phím tắt không có đầu vào → soạn tuyến. Điểm đi tự lấy vị trí hiện tại; nếu đang mô phỏng thì dùng và ghi rõ vị trí đang mô phỏng. Điểm đi vẫn có thể chọn tay từ link, địa chỉ, Dấu trang hoặc bản đồ.
- Điểm dừng, thời gian nghỉ và tốc độ chỉnh trong app. Chia sẻ tiếp một điểm sẽ giữ bản nháp trước đó. Chưa có điểm đến thì chọn điểm đến trước khi thêm trạm.
- Địa chỉ/tuyến có nhiều điểm cần chọn kết quả đúng; app không tự lấy tọa độ khung nhìn bản đồ làm đích. Link rút gọn cần mạng.
- Endpoint nhanh cũ `stikdebugvn://simulate-location?lat=...&lon=...` được giữ. Phím tắt cũ dùng `stikdebug://` vẫn trỏ vào app gốc.

## Sửa tuyến đang chạy

Soạn bản nháp không thay đổi tuyến đang chạy. Bấm **Áp dụng** và xác nhận: chờ lệnh đang gửi hoàn tất, tạm dừng tại tọa độ đã xác nhận, bỏ các trạm cũ đã qua, tính phần đường còn lại, giữ thời gian nghỉ còn lại tại trạm hiện tại. Sau khi áp dụng app vẫn tạm dừng; bấm **Tiếp tục** khi sẵn sàng. Nếu tính tuyến thất bại/hủy, tuyến cũ còn nguyên ở trạng thái tạm dừng.

**Về GPS thật** chỉ báo thành công khi backend xóa vị trí mô phỏng thành công. Nếu lỗi vẫn cho phép thử lại.

## Phạm vi kiểm chứng

CI kiểm tra logic Swift thuần, chạy controller/session/kho bản nháp sản xuất với đồng hồ điều khiển và biên thiết bị mô phỏng, kiểm tra phím tắt, build archive iPhone và xác minh danh tính gói. Có kết quả và SHA-256 trong artifact Verification. Đây không phải xác nhận hoạt động của GPS, VPN, quyền vị trí hay khóa màn hình trên iPhone thật.

Sau cập nhật, thử một tuyến ngắn: thêm trạm nghỉ 10 giây, tạm dừng/tiếp tục trong lúc nghỉ, chia sẻ thêm trạm và áp dụng, đến cuối vẫn giữ tọa độ, cuối cùng Về GPS thật. Theo AGENTS.md, chủ repo cần tự đọc, hiểu và kiểm thử trước khi hợp nhất/PR; chưa mở PR hay hợp nhất tự động.
