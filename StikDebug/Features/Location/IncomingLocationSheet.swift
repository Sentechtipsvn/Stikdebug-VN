import SwiftUI
import MapKit

enum IncomingLocationChoice { case destination, stop, pin }

struct IncomingLocationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var playback = RoutePlaybackController.shared
    @ObservedObject private var workspace = LocationWorkspaceStore.shared
    let request: LocationReceiveRequest
    let onChoice: (IncomingLocationChoice, RouteWaypoint) -> Void
    @State private var point: RouteWaypoint?
    @State private var isLoading = true
    @State private var error: String?
    @State private var needsPicker = false
    @State private var showPicker = false
    @State private var confirmPin = false
    @State private var confirmDestination = false

    private var canAddStop: Bool {
        if workspace.draft.dirty { return workspace.draft.hasDestination }
        return playback.route != nil && playback.state != .finished
    }

    var body: some View {
        NavigationStack {
            List {
                if isLoading { ProgressView("Đang đọc vị trí được chia sẻ…") }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                if let point {
                    Section(point.source == "shortcut" ? "Tọa độ từ Phím tắt" : "Vị trí đã chọn") {
                        Text(point.name).font(.headline)
                        Text(String(format: "%.6f, %.6f", point.coordinate.latitude, point.coordinate.longitude)).font(.caption.monospaced())
                        Map(initialPosition: .region(.init(center: point.coordinate.clCoordinate, latitudinalMeters: 700, longitudinalMeters: 700))) {
                            Marker(point.name, coordinate: point.coordinate.clCoordinate).tint(.green)
                        }.frame(height: 170).clipShape(RoundedRectangle(cornerRadius: 14)).id(point.id)
                        Button("Dùng tọa độ làm điểm đến", systemImage: "flag.checkered") {
                            if workspace.draft.dirty, let old = workspace.draft.rows.last?.point, old.coordinate != point.coordinate {
                                confirmDestination = true
                            } else {
                                onChoice(.destination, point)
                            }
                        }.fontWeight(.semibold)
                    }
                    Text("Chọn điểm đi trong màn hình tạo tuyến, rồi bấm Định tuyến.").font(.footnote).foregroundStyle(.secondary)
                    Section("Dùng theo cách khác") {
                        Button("Thêm điểm dừng", systemImage: "plus.circle") { onChoice(.stop, point) }
                            .disabled(!canAddStop)
                        Button("Đặt vị trí tại đây", systemImage: "location.fill") {
                            if LocationSimulationSession.shared.isActive || playback.isLocked || playback.route != nil || workspace.draft.dirty { confirmPin = true }
                            else { onChoice(.pin, point) }
                        }
                    }
                    if playback.hasActiveRoute {
                        Text("Điểm đến hoặc điểm dừng được đưa vào bản nháp. Tuyến đang chạy chỉ thay đổi khi Sếp xác nhận áp dụng.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if needsPicker || point != nil {
                    Button(point == nil && request.input == nil ? "Dán link hoặc chọn ghim" :
                           point == nil ? "Chọn điểm chính xác" : "Chọn lại vị trí",
                           systemImage: "mappin.and.ellipse") { showPicker = true }
                }
            }
            .navigationTitle("Vị trí từ Phím tắt").navigationBarTitleDisplayMode(.inline).tint(.green)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Hủy") { dismiss() } } }
            .confirmationDialog("Thay tuyến bằng vị trí này?", isPresented: $confirmPin, titleVisibility: .visible) {
                Button("Đặt vị trí", role: .destructive) { if let point { onChoice(.pin, point) } }
                Button("Hủy", role: .cancel) {}
            } message: { Text("App sẽ bỏ tuyến đang xem và bản nháp chưa áp dụng, rồi mô phỏng tại điểm mới.") }
            .alert("Đổi điểm đến trong bản nháp?", isPresented: $confirmDestination) {
                Button("Dùng điểm đến mới") { if let point { onChoice(.destination, point) } }
                Button("Hủy", role: .cancel) {}
            } message: { Text("App sẽ dùng tọa độ vừa nhận làm điểm đến. Điểm đi và các điểm dừng vẫn có trong bản nháp.") }
            .sheet(isPresented: $showPicker) {
                LocationInputSheet(title: "Chọn điểm được chia sẻ", initialInput: request.input ?? "") { point in
                    self.point = point
                    self.error = nil
                    showPicker = false
                }
            }
            .task(id: request.id) {
                if let received = request.point {
                    point = received
                    isLoading = false
                    return
                }
                guard let input = request.input else {
                    error = "Chưa nhận được link hoặc tọa độ hợp lệ từ Phím tắt. Sếp có thể dán link bản đồ hoặc chọn lại ghim."
                    needsPicker = true
                    isLoading = false
                    return
                }
                do {
                    let result = try await LocationInputResolver.resolve(input)
                    try Task.checkCancellation()
                    switch result {
                    case .coordinate(let coordinate, let name): point = .init(name: name ?? "Địa điểm được chia sẻ", coordinate: coordinate, source: "shortcut")
                    case .search, .multiple:
                        error = "Cần chọn đúng điểm trước khi dùng. Bấm Chọn điểm chính xác để xem kết quả."
                        needsPicker = true
                    case .unresolvedURL: throw LocationInputError.noExactCoordinate
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    self.error = error.localizedDescription
                    needsPicker = true
                }
                isLoading = false
            }
        }
    }
}
