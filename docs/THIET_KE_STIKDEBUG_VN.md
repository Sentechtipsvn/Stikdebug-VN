# StikDebug VN — Khảo sát và thiết kế nâng cấp

Ngày: 06/11/2026. Chủ dự án: Sếp Sen / © Sentechtipsvn.

**Trạng thái:** đã đọc mã và lập thiết kế; chưa triển khai tính năng, chưa build, chưa ký IPA và chưa thử trên iPhone. Các thông số giao diện và ngưỡng dưới đây là đề xuất triển khai.

## 1. Mốc mã nguồn và thiết bị

- Repo: https://github.com/dammeiosvn/Stikdebug-VN
- Commit khảo sát: `9d7a917c7d698ed6d393ee3dc1a8ff1feba773fe`.
- Project khai báo phiên bản 3.2.0, iOS tối thiểu 17.4; khớp số phiên bản trong ảnh Sếp cung cấp.
- Máy thử chính: iPhone 11, iOS 18.7.8; ảnh Settings xác nhận phiên bản iOS.
- iPhone 7 Plus/iOS 15.8.8 có TrollStore không chạy được bản dự án này. Cài được IPA không đồng nghĩa đáp ứng phiên bản hệ điều hành, API và giao thức kết nối. Hỗ trợ iOS 15 sẽ là một dự án chuyển đổi riêng, không chỉ sửa deployment target.
- MacBook macOS 12.7.2 không đáp ứng yêu cầu Xcode của bản mã hiện tại. Chưa cần nâng cấp hoặc sửa hệ điều hành máy.
- Phương án build: dùng GitHub Actions của fork, nhận IPA chưa ký rồi ký/cài trên máy của Sếp. Workflow hiện chọn runner `xcode-27`, Xcode 27.1 và build thiết bị iOS.
- API GitHub cho biết chủ repo có quyền push. Khi khảo sát, fork chưa có lượt workflow run nào; chưa xác nhận Actions đã được bật hay build có thành công.

Nguồn: [project.xcproj](../StikDebug.xcodeproj/project.xcproj), [README](../README.md), [workflow build](../.github/workflows/build_ipa.yml), [bảng Xcode của Apple](https://developer.apple.com/xcode/system-requirements).

## 2. Những gì mã hiện tại cho thấy

| Quan sát | Vị trí mã | Hệ quả |
| --- | --- | --- |
| Hai điểm đầu/cuối; chỉ gọi tuyến ô tô, không lấy tuyến thay thế | MapSelectionView.swift:1494–1586, 1653–1892 | Chưa có điểm trung gian hay nguồn chọn từ link/Bookmarks |
| Bookmarks lưu JSON trong UserDefaults, khóa locationBookmarks | MapSelectionView.swift:683–692, 1104–1128 | Có thể dùng lại mô hình và dữ liệu trong cùng sandbox |
| Tốc độ dựng trước theo OSM, thiếu thì dùng tốc độ dự phòng | MapSelectionView.swift:306–351 | Chưa có điều khiển tốc độ trực tiếp |
| ETA lấy từ MapKit, mẫu phát có thể dùng tốc độ khác | MapSelectionView.swift:819–829, 1534–1566 | ETA trên giao diện có thể lệch thời gian mô phỏng |
| Nút Play Route không kiểm tra trạng thái tuyến đang chạy | MapSelectionView.swift:1309–1346 | Có thể bấm phát lại; cần một trạng thái điều khiển thống nhất |
| Task phát nằm trong View, session chung giữ ID/tọa độ | MapSelectionView.swift:1589–1637; LocationSimulationSession.swift | Chưa có tiến độ và tạm dừng/tiếp tục độc lập vòng đời màn hình |
| Import dùng bộ đọc GPX/KML/GeoJSON/JSON/CSV/text; text có nhánh tìm số tự do | MapSelectionView.swift:354–679 | Cần giữ bộ nhập; không dùng nhánh tìm số tự do để nhận diện URL |
| Có giữ nền bằng audio/location và background task | LocationSimulationSession.swift; BackgroundLocationManager.swift; Info.plist | Không thể kết luận chạy nền ổn định chỉ từ việc đọc mã |

Đây là kết quả phân tích tĩnh, chưa phải lỗi đã tái hiện trên thiết bị. [Mã bản đồ tại commit khảo sát](https://github.com/dammeiosvn/Stikdebug-VN/blob/9d7a917c7d698ed6d393ee3dc1a8ff1feba773fe/StikDebug/Views/MapSelectionView.swift).

## 3. Kịch bản sử dụng

1. Mở Công cụ → Mô phỏng vị trí → Tạo tuyến.
2. Chọn Điểm đi; menu gồm Vị trí thiết bị, Vị trí đang mô phỏng nếu có, Dán link hoặc tọa độ, Dấu trang, Chọn trên bản đồ, Tìm địa chỉ.
3. Chọn Điểm đến bằng các nguồn tương tự. Nút Thêm điểm dừng tạo một hàng ở giữa; kéo để sắp xếp, vuốt để xóa.
4. Xem trước tuyến, các điểm, độ dài và thời gian mô phỏng. Nếu một chặng không tìm được đường, chỉ rõ chặng đó để sửa.
5. Chọn tốc độ bằng km/h hoặc chế độ Theo dữ liệu đường. Chế độ cố định là lựa chọn nhanh; OSM là tùy chọn, không được bắt toàn bộ người dùng chờ tải OSM.
6. Bấm Bắt đầu. Thanh điều khiển hiển thị tốc độ, tiến độ, điểm dừng kế tiếp và thời gian còn lại.
7. Khi chạy, chỉ có Tạm dừng và Dừng; không có nút Bắt đầu thứ hai. Khi tạm dừng, nút chính đổi thành Tiếp tục.
8. Lưu tuyến với tên, các điểm, tốc độ và đường đi đã tính. Mở lại từ Tuyến đã lưu.

Thiết kế dùng SwiftUI và thành phần native của iOS: bảng điều khiển kính mờ có nền đủ tương phản, màu nhấn xanh lá, Light/Dark Mode, hỗ trợ chữ lớn. Hạn chế icon khó hiểu; các thao tác chính có nhãn tiếng Việt.

## 4. Đầu vào vị trí

### Dán link hoặc tọa độ

- Dùng PasteButton hoặc thao tác dán chủ động; không đọc clipboard liên tục.
- Hỗ trợ tọa độ vĩ độ/kinh độ rõ ràng; kiểm tra hữu hạn và miền hợp lệ.
- Ưu tiên Apple Maps và Google Maps có tọa độ đích rõ ràng. Phân biệt tọa độ điểm được chọn với tâm khung nhìn bản đồ.
- Link rút gọn cần mạng để mở rộng. Chỉ theo redirect đến các host bản đồ được nhận diện, có timeout và giới hạn số redirect.
- URL chỉ có tên địa điểm, Place ID hay CID không đồng nghĩa có tọa độ sẵn. Nếu chưa phân giải được chính xác, hiển thị trạng thái cần chọn điểm hoặc nhập tọa độ; không tự lấy vài con số trong URL làm vị trí.
- Với link chỉ đường chứa nhiều địa điểm, cho chọn điểm cần dùng hoặc nhập danh sách các điểm có tọa độ rõ ràng. Không âm thầm lấy điểm đầu tiên.
- Mỗi kết quả có tên, tọa độ và dấu ghim xem trước. Link lỗi hoặc không hỗ trợ phải báo cụ thể.
- Cache kết quả đã phân giải thành công để dùng lại; không hứa mọi link đều hoạt động offline.
- Bộ giải link phải có request ID/hủy tác vụ: đổi link hoặc chọn điểm khác thì kết quả cũ không được ghi đè điểm mới.

Nguồn định dạng: [Google Maps URLs](https://developers.google.com/maps/documentation/urls/get-started), [Apple Maps URLs](https://developer.apple.com/documentation/mapkit/unified-map-urls). Các định dạng không được tài liệu hóa chỉ được hỗ trợ sau khi có mẫu link và kiểm chứng; không coi là hợp đồng ổn định.

### Dấu trang

Tái sử dụng LocationBookmark và khóa locationBookmarks. Mở picker theo ngữ cảnh đang chọn Điểm đi, Điểm dừng hay Điểm đến. Chọn một dấu trang chỉ gán tọa độ vào hàng đó, chưa tự bắt đầu mô phỏng.

### Vị trí thiết bị làm điểm đi

- Lấy một bản cập nhật Core Location mới, kiểm tra tuổi dữ liệu, độ chính xác và quyền truy cập; không lấy tâm màn hình bản đồ.
- Khi có mô phỏng đang hoạt động, hiển thị thêm lựa chọn Vị trí đang mô phỏng, lấy từ session.
- Không gắn nhãn GPS thật cho mọi kết quả CLLocationManager. Core Location có thông tin nguồn mô phỏng; giá trị thiếu hoặc false cũng không phải chứng minh tuyệt đối về vị trí thực.
- Nếu cần lấy lại vị trí thiết bị sau mô phỏng, cung cấp thao tác riêng để dừng mô phỏng rồi chờ bản cập nhật mới; không âm thầm dừng phiên đang chạy.
- Từ chối quyền, hết thời gian chờ hoặc dữ liệu quá cũ phải có lối chọn Bookmarks/link/bản đồ.

Nguồn: [CLLocationSourceInformation](https://developer.apple.com/documentation/corelocation/cllocationsourceinformation).

## 5. Bộ điều khiển tuyến

### Trạng thái và ý nghĩa các nút

| Trạng thái | Điều khiển chính | Hành vi |
| --- | --- | --- |
| Đang soạn | Tính tuyến | Chưa gửi vị trí giả |
| Đang tính/đọc link | Hủy | Hiển thị công việc đang làm; bỏ kết quả request cũ |
| Sẵn sàng | Bắt đầu | Kiểm tra pairing, kết nối và dữ liệu tuyến |
| Đang chạy | Tạm dừng | Giữ nguyên tiến độ tại lần cập nhật thành công gần nhất |
| Tạm dừng | Tiếp tục | Không nhảy về đầu; giữ tọa độ cuối nếu còn kết nối |
| Hoàn tất | Chạy lại | Giữ vị trí điểm đến, phù hợp hành vi cũ |
| Lỗi hoặc mất kết nối | Kết nối lại / Thử tiếp | Lưu vị trí đã xác nhận, không báo đang chạy giả |
| Mọi phiên đang giữ vị trí | Dừng | Gọi xóa vị trí mô phỏng; chỉ xác nhận dừng khi lệnh thành công |

Đặt lại chỉ xóa bản nháp sau khi phiên đang chạy đã được xử lý; không trộn với Dừng. Nếu người dùng đã tạm dừng rồi mới đổi tốc độ, Tiếp tục vẫn xuất phát từ đúng tiến độ cũ.

### Tốc độ và nhịp phát

- Tách RoutePlaybackController khỏi View; một owner quản lý task, trạng thái và tiến độ.
- Đường đi lưu tọa độ cùng khoảng cách tích lũy, nội suy theo quãng đường đã đi. Không dựng hàng loạt mẫu mới mỗi khi kéo tốc độ.
- Nhịp cập nhật mục tiêu khoảng 0,5 giây, được điều chỉnh sau đo trên thiết bị.
- Tính tiến độ bằng thời gian đơn điệu; loại thời gian tạm dừng. Tính ETA từ cùng tốc độ/chế độ đang phát, tách khỏi ETA giao thông của MapKit nếu còn hiển thị cả hai.
- Khi trở lại sau khi iOS treo app, tạm dừng ở tiến độ đã xác nhận thay vì chạy bù hàng loạt hoặc nhảy qua một quãng lớn.
- Tuần tự hóa lệnh qua LocationSimulationCommandQueue; một lệnh đang gửi tại một thời điểm.
- Đổi phiên, Dừng hoặc lỗi phải vô hiệu hóa kết quả cũ bằng session ID; lệnh dừng và lệnh cập nhật cùng hàng đợi để kết quả cuối không bị lệnh cũ ghi đè.
- Đổi tốc độ không đổi hình học tuyến. Đổi điểm đi/đến yêu cầu kết thúc phiên hiện tại hoặc tạo bản nháp mới.

### Nhiều điểm và thời gian dừng

Tính từng chặng kề nhau bằng MapKit, ghép polyline và loại điểm nối trùng. Giữ thứ tự người dùng; chưa thêm tối ưu hóa thứ tự tự động.

Mỗi điểm trung gian có thời gian dừng tùy chọn, mặc định 0 giây. Thời gian này tham gia ETA và được giữ đúng qua thao tác tạm dừng/tiếp tục. Không tự nối đường thẳng xuyên khu vực khi một chặng không có đường.

Giữ chế độ ô tô của bản gốc ở bản đầu. Chưa gắn nhãn tuyến xe máy khi provider không thực sự cung cấp định tuyến xe máy phù hợp.

## 6. Lưu tuyến và dữ liệu

Đề xuất SavedRoute Codable có: schemaVersion, UUID, tên, ngày cập nhật, danh sách điểm có nguồn tọa độ và thời gian dừng, các chặng/polyline, tốc độ/chế độ phát.

- Lưu file JSON nội bộ bằng ghi nguyên tử; có phiên bản schema để nâng cấp.
- Lưu cả hình học đã tính, không chỉ địa chỉ hay hai điểm đầu/cuối.
- Tuyến đã lưu hoặc đã nhập có thể phát lại khi mất mạng nếu các điều kiện kết nối mô phỏng còn đáp ứng; tải bản đồ và tính tuyến mới vẫn có thể cần mạng.
- Giữ GPX/KML/GeoJSON/JSON/CSV/text import hiện có; tách phân biệt nhập track có sẵn với nhập điểm để tìm đường.
- Xuất/nhập JSON để sao lưu và chuyển dữ liệu. Không triển khai iCloud đồng bộ tự động ở bản đầu nếu chưa xử lý xung đột.
- Không lưu pairing file, chứng chỉ hay dữ liệu tài khoản vào repo.

Cài bản VN với Bundle ID mới tạo sandbox mới. Bookmarks trong app gốc không tự chuyển sang. Phần Bookmarks được khảo sát chưa có nút xuất; cần phương án sao lưu/chuyển dữ liệu thực tế trước khi khẳng định giữ được dữ liệu giữa hai app. Không yêu cầu gỡ bản gốc để thử.

## 7. Việt hóa và nhận diện bản fork

- Tiếng Việt là ngôn ngữ sản phẩm chính; giữ tiếng Anh làm dự phòng.
- Dùng tài nguyên localization native (.xcstrings hoặc .strings phù hợp project), không thay văn bản rải rác thiếu kiểm soát.
- Bao gồm tab, menu, thông báo lỗi, xin quyền, nút mặc định và accessibility; không chỉ dịch màn hình tuyến.
- Định dạng khoảng cách, tốc độ và thời gian theo locale; các giá trị máy đọc như JSON, tọa độ URL và khóa dữ liệu vẫn giữ cấu trúc ổn định.
- Giữ tên StikDebug, LICENSE AGPL-3.0, nguồn gốc và ghi công; thêm nhận diện bản Việt hóa của © Sentechtipsvn, không nhận tác giả lõi gốc.
- Khi cài song song, chọn Bundle ID và URL scheme riêng của bản VN. Giữ cấu trúc endpoint/tham số tương đương để tích hợp Shortcuts có thể chuyển sang bằng cách đổi scheme.
- Kiểm tra riêng các URL/Shortcuts hiện có, tính năng JIT, Scripts và mô phỏng một điểm để tránh hồi quy.

## 8. Bố trí mã dự kiến

| Thành phần | Trách nhiệm |
| --- | --- |
| RouteModels | Điểm, chặng, tuyến đã lưu, cấu hình tốc độ và trạng thái |
| LocationInputResolver | Chuẩn hóa tọa độ và link; kết quả có nguồn, độ chắc chắn |
| CurrentLocationProvider | Xin quyền, lấy bản cập nhật mới và cung cấp thông tin nguồn |
| BookmarkStore | Dùng lại dữ liệu locationBookmarks, đọc/ghi tập trung |
| RoutePlanner | MapKit từng chặng, hủy tính toán và kiểm tra request ID |
| RoutePlaybackController | Tiến độ, tốc độ, tạm dừng/tiếp tục, thời gian dừng |
| RouteLibraryStore | Lưu JSON, xuất/nhập và nâng cấp schema |
| RouteEditor / LocationPicker / PlaybackControls | SwiftUI chỉ hiển thị trạng thái và nhận thao tác |
| LocationSimulationSession và hàng đợi hiện tại | Tích hợp vòng đời phiên và lệnh mô phỏng thiết bị |

Tách từng phần theo nhu cầu thực tế, tránh tạo hệ thống framework lớn cho một app nhỏ.

## 9. Lộ trình triển khai và kiểm chứng

1. **Build gốc trước:** bật Actions của fork nếu chưa bật; chạy Build Debug IPA tại main, chưa tạo tag phát hành. Xác nhận runner/Xcode/phụ thuộc và IPA có thể ký/cài.
2. **Đầu vào và tiếng Việt:** Việt hóa luồng vị trí; picker dùng chung cho link/tọa độ, Bookmarks, bản đồ và vị trí thiết bị. Giữ nguyên phát một điểm và import.
3. **Bộ phát tuyến:** trạng thái rõ ràng, tốc độ, tạm dừng/tiếp tục, ETA thống nhất, xử lý hủy và lỗi.
4. **Nhiều điểm và thư viện tuyến:** chặng, thời gian dừng, lưu/mở/xuất/nhập; phát hình học đã lưu.
5. **Hoàn thiện app:** Việt hóa phần còn lại; kiểm tra nền, khóa màn hình, chữ lớn và Light/Dark Mode trên iPhone 11.

Trước phát hành cần điều chỉnh workflow của fork để không chạy job cập nhật website StikDebug/Website của tác giả gốc. Build thường chỉ cần quyền đọc nội dung; quyền phát hành chỉ dùng khi thật sự tạo release. IPA do workflow hiện tạo chưa được ký; đóng gói thành công không chứng minh đã cài hoặc chạy trên máy.

### Kiểm chứng tự động có ý nghĩa

- Giải tọa độ/link đúng trường, không đọc số trong token/tên đường thành tọa độ; link lỗi, redirect vòng, timeout, dữ liệu không hữu hạn và kết quả đến trễ.
- Ghép chặng và khoảng cách tích lũy; nội suy tại đầu/cuối và các điểm nối.
- Tạm dừng/tiếp tục, đổi tốc độ, thời gian dừng tại waypoint, kết thúc tuyến và hủy task không tạo cập nhật thừa.
- Round-trip dữ liệu SavedRoute, file lỗi và schema không được hỗ trợ.
- Tách logic thuần Swift để có thể thử không cần kết nối thiết bị; không mặc định thư viện FFI có đủ slice cho mọi simulator.

### Kiểm chứng trên iPhone do Sếp thực hiện

- Ký/cài IPA và kết nối pairing/VPN/DDI; thử lại các chức năng gốc.
- So sánh điểm từ link với đúng ghim trong Maps; thử link chia sẻ thực tế của Sếp.
- Chọn từng loại điểm, đọc đúng Bookmarks và lấy vị trí thiết bị khi có/không có mô phỏng.
- Tốc độ, tạm dừng, tiếp tục, nhiều chặng, thời gian dừng, dừng xóa mô phỏng.
- Chuyển app, khóa màn hình, mất kết nối, bị iOS đình chỉ; kiểm tra trên app bản đồ khác.
- Mở lại tuyến đã lưu khi mạng không có; kiểm tra dữ liệu và phần nào còn cần mạng.

Không cam kết chạy nền vô hạn: background task có thời hạn, và cơ chế audio/location không chứng minh ứng dụng sẽ luôn được chạy. [Tài liệu Apple về background task](https://developer.apple.com/documentation/uikit/uiapplication/beginbackgroundtask%28expirationhandler%3A%29).

## 10. Quy tắc đóng góp và trạng thái bàn giao

Theo [AGENTS.md](../AGENTS.md): người đóng góp cần tự đọc, hiểu và kiểm thử thay đổi trước khi gửi mã; thay đổi UI/lớn thường cần thử app. Mô tả PR/issue do người viết; AI chỉ dịch mô tả do người viết kèm công khai việc dịch. Không gắn Co-authored-by cho AI, không khẳng định con người đã kiểm thử khi chưa có.

Tài liệu này là bản khảo sát và đề xuất của trợ lý AI. Lần bàn giao này chỉ thêm tài liệu trên nhánh riêng, không sửa mã app hoặc tạo PR/issue. Chưa có IPA hay kết quả build/chạy máy để xác nhận.
