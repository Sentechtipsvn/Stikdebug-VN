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
                    Section("Địa điểm nhận được") {
                        Text(point.name).font(.headline)
                        Text(String(format: "%.6f, %.6f", point.coordinate.latitude, point.coordinate.longitude)).font(.caption.monospaced())
                        Map(initialPosition: .region(.init(center: point.coordinate.clCoordinate, latitudinalMeters: 700, longitudinalMeters: 700))) {
                            Marker(point.name, coordinate: point.coordinate.clCoordinate).tint(.green)
                        }.frame(height: 170).clipShape(RoundedRectangle(cornerRadius: 14)).id(point.id)
                    }
                    Section("Sếp muốn dùng điểm này thế nào?") {
                        Button("Dùng làm điểm đến", systemImage: "flag.checkered") { onChoice(.destination, point) }
                        Button("Thêm điểm dừng", systemImage: "plus.circle") { onChoice(.stop, point) }
                            .disabled(!canAddStop)
                        Button("Đặt vị trí tại đây", systemImage: "location.fill") {
                            if LocationSimulationSession.shared.isActive || playback.isLocked || playback.route != nil || workspace.draft.dirty { confirmPin = true }
                            else { onChoice(.pin, point) }
                        }
                    }
                    if !canAddStop {
                        Text("Chọn Dùng làm điểm đến để tạo tuyến trước; sau đó có thể chia sẻ thêm các điểm dừng.").font(.footnote).foregroundStyle(.secondary)
                    }
                    if playback.hasActiveRoute {
                        Text("Điểm đến hoặc điểm dừng được đưa vào bản nháp. Tuyến đang chạy chỉ thay đổi khi Sếp xác nhận áp dụng.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if needsPicker || point != nil {
                    Button(point == nil ? "Chọn điểm chính xác" : "Chọn lại vị trí", systemImage: "mappin.and.ellipse") { showPicker = true }
                }
            }
            .navigationTitle("Vị trí từ Shortcuts").navigationBarTitleDisplayMode(.inline).tint(.green)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Hủy") { dismiss() } } }
            .confirmationDialog("Thay tuyến bằng vị trí này?", isPresented: $confirmPin, titleVisibility: .visible) {
                Button("Đặt vị trí", role: .destructive) { if let point { onChoice(.pin, point) } }
                Button("Hủy", role: .cancel) {}
            } message: { Text("App sẽ bỏ tuyến đang xem và bản nháp chưa áp dụng, rồi mô phỏng tại điểm mới.") }
            .sheet(isPresented: $showPicker) {
                LocationInputSheet(title: "Chọn điểm được chia sẻ", initialInput: request.input ?? "") { point in
                    self.point = point
                    self.error = nil
                    showPicker = false
                }
            }
            .task(id: request.id) {
                do {
                    guard let input = request.input else { throw LocationWorkflowError.invalidRequest }
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
