import SwiftUI

private struct RouteEditingRow: Identifiable {
    let id: UUID
    let title: String
    var editsDuration = false
}

struct RouteEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = LocationWorkspaceStore.shared
    @ObservedObject private var playback = RoutePlaybackController.shared
    @StateObject private var currentLocation = CurrentLocationProvider()
    @AppStorage("vn.location.preferredVehicle") private var preferredVehicle: RouteVehicle = .car
    let onApply: (SavedSimulationRoute) -> Void
    @State private var editing: RouteEditingRow?
    @State private var isCalculating = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var confirmReplacement = false
    @State private var motorcycleKey = MotorcycleRoutingKey.load()
    @State private var editMotorcycleKey = false
    @State private var keyInput = ""

    var body: some View {
        NavigationStack {
            Form {
                vehicleSection
                pointsSection
                speedSection
                if currentLocation.isLoading { ProgressView("Đang lấy điểm đi hiện tại…") }
                if let error = error ?? currentLocation.error { Text(error).font(.footnote).foregroundStyle(.red) }
                if isCalculating { ProgressView("Đang tính các chặng…") }
                if playback.hasActiveRoute {
                    Text("Tuyến đang chạy vẫn được giữ khi soạn bản nháp. Khi áp dụng, app sẽ tạm dừng và tính phần đường còn lại từ vị trí đang mô phỏng.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Tạo tuyến mô phỏng").navigationBarTitleDisplayMode(.inline).tint(.green)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Đóng") { task?.cancel(); dismiss() } }
                ToolbarItemGroup(placement: .confirmationAction) {
                    EditButton().disabled(isCalculating)
                    Button(playback.hasActiveRoute ? "Áp dụng" : "Tính tuyến") {
                        if playback.hasActiveRoute { confirmReplacement = true } else { calculate() }
                    }.fontWeight(.semibold).disabled(!canCalculate)
                }
            }
            .confirmationDialog("Áp dụng bản nháp tuyến?", isPresented: $confirmReplacement, titleVisibility: .visible) {
                Button("Tạm dừng và tính lại") { calculate() }
                Button("Hủy", role: .cancel) {}
            } message: { Text("Dùng vị trí đang mô phỏng làm điểm đi mới. Các trạm đã qua được bỏ khỏi phần đường còn lại; thời gian nghỉ còn lại ở trạm hiện tại được giữ.") }
            .alert("Khóa API Geoapify", isPresented: $editMotorcycleKey) {
                SecureField("Nhập khóa API", text: $keyInput)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Lưu") { saveMotorcycleKey() }
                if motorcycleKey != nil {
                    Button("Xóa khóa", role: .destructive) { removeMotorcycleKey() }
                }
                Button("Hủy", role: .cancel) { keyInput = "" }
            } message: { Text("Khóa được lưu trong Keychain trên iPhone.") }
            .sheet(item: $editing) { item in
                if item.editsDuration {
                    let seconds = store.draft.rows.first(where: { $0.id == item.id })?.dwell ?? 0
                    RestDurationSheet(seconds: seconds, pointName: item.title) { value in
                        if let index = store.draft.rows.firstIndex(where: { $0.id == item.id }) {
                            store.draft.rows[index].dwell = value
                            store.draft.dirty = true
                        }
                    }
                } else {
                    LocationInputSheet(title: item.title) { point in
                        store.setPoint(point, rowID: item.id)
                        editing = nil
                    }
                }
            }
            .task { requestOriginIfNeeded() }
            .onReceive(currentLocation.$result) { if let value = $0 { store.acceptAutomaticOrigin(value) } }
            .onDisappear { task?.cancel(); currentLocation.cancel(); store.flush() }
        }
    }

    private var canCalculate: Bool {
        !isCalculating && !currentLocation.isLoading && store.draft.points != nil && store.draft.speedKmh.isFinite &&
            (1...300).contains(store.draft.speedKmh) && (vehicle != .motorcycle || motorcycleKey != nil)
    }

    private var vehicle: RouteVehicle { store.draft.vehicle ?? preferredVehicle }

    private var vehicleSection: some View {
        Section {
            Picker("Phương tiện", selection: Binding(get: { vehicle }, set: { selection in
                store.draft.vehicle = selection
                store.draft.dirty = true
                preferredVehicle = selection
                error = nil
            })) {
                Text("Ô tô").tag(RouteVehicle.car)
                Text("Xe máy").tag(RouteVehicle.motorcycle)
            }.pickerStyle(.segmented)
            if vehicle == .motorcycle {
                Button(motorcycleKey == nil ? "Nhập khóa API Geoapify" : "Quản lý khóa API Geoapify", systemImage: "key") {
                    keyInput = ""
                    editMotorcycleKey = true
                }
            }
        } header: {
            Text("Phương tiện")
        } footer: {
            if vehicle == .motorcycle {
                Text("Khi tính tuyến xe máy, app gửi tọa độ các điểm đã chọn đến Geoapify. Đường đi phụ thuộc dữ liệu OpenStreetMap.")
            }
        }.disabled(isCalculating)
    }

    private func saveMotorcycleKey() {
        defer { keyInput = "" }
        do {
            motorcycleKey = try MotorcycleRoutingKey.save(keyInput)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func removeMotorcycleKey() {
        defer { keyInput = "" }
        do {
            try MotorcycleRoutingKey.remove()
            motorcycleKey = nil
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private var pointsSection: some View {
        Section {
            ForEach(Array(store.draft.rows.enumerated()), id: \.element.id) { index, row in
                VStack(alignment: .leading, spacing: 10) {
                    Button { editing = .init(id: row.id, title: rowTitle(index)) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: index == 0 ? "location.circle.fill" : index == store.draft.rows.count - 1 ? "flag.checkered.circle.fill" : "mappin.circle.fill")
                                .font(.title2).foregroundStyle(index == store.draft.rows.count - 1 ? .red : .green)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(rowTitle(index)).font(.caption).foregroundStyle(.secondary)
                                Text(row.point?.name ?? "Chọn vị trí").foregroundStyle(.primary)
                                if let point = row.point {
                                    Text(String(format: "%.5f, %.5f", point.coordinate.latitude, point.coordinate.longitude))
                                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }.contentShape(Rectangle())
                    }.disabled(isCalculating)
                    if index == 0 {
                        Button("Lấy lại vị trí hiện tại", systemImage: "location") {
                            store.draft.originIsAutomatic = true
                            store.draft.dirty = true
                            requestOriginIfNeeded()
                        }
                            .font(.caption).disabled(isCalculating || currentLocation.isLoading)
                    }
                    if index > 0 && index < store.draft.rows.count - 1 {
                        Button { editing = .init(id: row.id, title: row.point?.name ?? rowTitle(index), editsDuration: true) } label: {
                            HStack {
                                Label("Thời gian nghỉ", systemImage: "timer")
                                Spacer()
                                Text(row.dwell == 0 ? "Không nghỉ" : RestDuration.clock(row.dwell)).monospacedDigit()
                                Image(systemName: "chevron.right").font(.caption2)
                            }.font(.footnote).contentShape(Rectangle())
                        }.disabled(isCalculating)
                    }
                }.buttonStyle(.borderless).padding(.vertical, 4)
            }
            .onMove { from, to in if !isCalculating { store.draft.rows.move(fromOffsets: from, toOffset: to); store.draft.dirty = true; store.draft.originIsAutomatic = false } }
            .onDelete { offsets in
                if !isCalculating && store.draft.rows.count - offsets.count >= 2 {
                    if offsets.contains(0) { store.draft.originIsAutomatic = false }
                    store.draft.rows.remove(atOffsets: offsets)
                    store.draft.dirty = true
                }
            }
            Button("Thêm điểm dừng", systemImage: "plus.circle.fill") {
                let row = RouteDraftRow()
                store.draft.rows.insert(row, at: max(1, store.draft.rows.count - 1))
                store.draft.dirty = true
                editing = .init(id: row.id, title: "Điểm dừng mới")
            }.disabled(isCalculating || store.draft.rows.count >= 100)
        } header: { Text("Các điểm theo thứ tự") } footer: {
            Text("Chọn điểm bằng link, tọa độ, Dấu trang hoặc bản đồ. Mỗi trạm có thời gian nghỉ riêng và tự đi tiếp khi hết giờ.")
        }
    }

    private var speedSection: some View {
        Section("Tốc độ đặt") {
            Picker("Chế độ", selection: Binding(get: { store.draft.mode }, set: { store.draft.mode = $0; store.draft.dirty = true })) {
                Text("Tốc độ cố định").tag(RouteSpeedMode.fixed)
                Text("Theo dữ liệu đường").tag(RouteSpeedMode.road)
            }
            if store.draft.mode == .fixed {
                HStack {
                    Text("Tốc độ")
                    Spacer()
                    TextField("km/h", value: speedBinding, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90)
                    Text("km/h").foregroundStyle(.secondary)
                }
                Slider(value: speedBinding, in: 1...300, step: 1).tint(.green)
            } else {
                Text("Lấy tốc độ đường từ OpenStreetMap; nếu thiếu sẽ dùng tốc độ dự phòng từ tuyến.").font(.footnote).foregroundStyle(.secondary)
            }
        }.disabled(isCalculating)
    }

    private var speedBinding: Binding<Double> {
        Binding(get: { store.draft.speedKmh }, set: { store.draft.speedKmh = $0; store.draft.dirty = true })
    }

    private func requestOriginIfNeeded() {
        guard store.draft.originIsAutomatic else { return }
        if LocationSimulationSession.shared.isActive, let point = LocationSimulationSession.shared.coordinate {
            store.acceptAutomaticOrigin(.init(name: "Vị trí đang mô phỏng", coordinate: RouteCoordinate(point), source: "simulated"))
        } else { currentLocation.request() }
    }

    private func rowTitle(_ index: Int) -> String {
        if index == 0 { return "Điểm đi" }
        if index == store.draft.rows.count - 1 { return "Điểm đến" }
        return "Điểm dừng \(index)"
    }

    private func calculate() {
        guard canCalculate else { return }
        isCalculating = true
        error = nil
        task = Task {
            do {
                let anchor = try await playback.pauseForEditing()
                try Task.checkCancellation()
                let points: [RouteWaypoint]
                if let anchor { points = try store.draft.rebased(at: anchor.coordinate, completedIDs: anchor.completedIDs) }
                else { guard let selected = store.draft.points else { throw RouteDataError.invalid }; points = selected }
                var route = try await VNRoutePlanner.calculate(waypoints: points, speedKmh: store.draft.speedKmh,
                                                               mode: store.draft.mode, vehicle: vehicle, motorcycleKey: motorcycleKey)
                try Task.checkCancellation()
                if let anchor, route.legs.first?.coordinates.first != anchor.coordinate {
                    route.legs[0].coordinates.insert(anchor.coordinate, at: 0)
                    if !route.roadSpeeds.isEmpty { route.roadSpeeds.insert(route.roadSpeeds[0], at: 0) }
                }
                try playback.installDraft(route, anchor: anchor)
                store.didApply(route)
                onApply(route)
                dismiss()
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                isCalculating = false
            }
        }
    }
}
