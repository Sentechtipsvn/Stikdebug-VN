import SwiftUI
import MapKit

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
    @State private var confirmFreshLocation = false
    @State private var originCandidate: RouteWaypoint?
    @State private var originTask: Task<Void, Never>?
    @State private var motorcycleKey = MotorcycleRoutingKey.load()
    @State private var editMotorcycleKey = false
    @State private var keyInput = ""

    var body: some View {
        NavigationStack {
            Form {
                vehicleSection
                pointsSection
                if let originCandidate { confirmOriginSection(originCandidate) }
                speedSection
                if originTask != nil {
                    ProgressView("Đang tắt mô phỏng…")
                    if let message = playback.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                }
                if currentLocation.isLoading { ProgressView("Đang lấy điểm đi hiện tại…") }
                if let error = error ?? currentLocation.error { Text(error).font(.footnote).foregroundStyle(.red) }
                if isCalculating { ProgressView("Đang tính các chặng…") }
                if playback.hasActiveRoute && !replacesFromSelectedOrigin && !store.draft.anchorsDetourToBot {
                    Text("Tuyến đang chạy vẫn được giữ khi soạn bản nháp. Khi áp dụng, app sẽ tạm dừng và tính phần đường còn lại từ vị trí đang mô phỏng.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(store.draft.replacement == .detour ? "Đổi nhánh từ đây" : "Tạo tuyến mô phỏng")
            .navigationBarTitleDisplayMode(.inline).tint(.green)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Đóng") { dismiss() } }
                ToolbarItemGroup(placement: .confirmationAction) {
                    EditButton().disabled(isCalculating)
                    Button(calculateTitle) {
                        if playback.route != nil { confirmReplacement = true } else { calculate() }
                    }.fontWeight(.semibold).disabled(!canCalculate)
                }
            }
            .confirmationDialog("Áp dụng bản nháp tuyến?", isPresented: $confirmReplacement, titleVisibility: .visible) {
                Button(replacesFromSelectedOrigin ? "Tính và thay tuyến" : "Tính và áp dụng") { calculate() }
                Button("Hủy", role: .cancel) {}
            } message: { Text(replacementExplanation) }
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
                    let isOrigin = store.draft.rows.first?.id == item.id
                    let manualOrigin = isOrigin && store.draft.replacement != nil
                    LocationInputSheet(title: item.title, allowDeviceLocation: !manualOrigin) { point in
                        if isOrigin { originCandidate = nil }
                        store.setPoint(point, rowID: item.id)
                        editing = nil
                    }
                }
            }
            .task { requestOriginIfNeeded() }
            .onReceive(currentLocation.$result) { value in
                guard let value else { return }
                if currentLocation.requestedFreshLocation { originCandidate = value }
                else { store.acceptAutomaticOrigin(value) }
            }
            .onDisappear {
                task?.cancel()
                originTask?.cancel()
                currentLocation.cancel()
                store.flush()
            }
        }
    }

    private var canCalculate: Bool {
        !isCalculating && originTask == nil && originCandidate == nil && !currentLocation.isLoading &&
            store.draft.points != nil && store.draft.speedKmh.isFinite &&
            (1...300).contains(store.draft.speedKmh) && (vehicle != .motorcycle || motorcycleKey != nil)
    }

    private var calculateTitle: String {
        if store.draft.replacement == .detour || store.draft.rows.last?.point?.source == "shortcut" { return "Định tuyến" }
        return playback.hasActiveRoute ? "Áp dụng" : "Tính tuyến"
    }

    private var replacesFromSelectedOrigin: Bool {
        store.draft.replacesRouteFromSelectedOrigin(whileContinuingRoute: playback.canContinueFromBot)
    }

    private var replacementExplanation: String {
        if replacesFromSelectedOrigin {
            return "Dùng điểm đi Sếp đã chọn. Khi tính được, app sẽ tắt phiên mô phỏng cũ nếu cần và giữ tuyến cũ ở mục Mở lại tuyến trước."
        }
        if store.draft.anchorsDetourToBot {
            return "App sẽ giữ bot tại vị trí đã xác nhận lúc áp dụng để tính nhánh mới. Tuyến cũ sẽ có trong mục Mở lại tuyến trước."
        }
        if playback.canContinueFromBot {
            return "Dùng vị trí bot làm điểm đi mới. App bỏ các trạm đã qua và giữ thời gian nghỉ còn lại ở trạm hiện tại."
        }
        return "Cập nhật tuyến đang hiển thị bằng các điểm trong bản nháp."
    }

    private func confirmOriginSection(_ point: RouteWaypoint) -> some View {
        Section("Xác nhận điểm đi") {
            Map(initialPosition: .region(.init(center: point.coordinate.clCoordinate, latitudinalMeters: 300, longitudinalMeters: 300))) {
                Marker("GPS vừa lấy", coordinate: point.coordinate.clCoordinate).tint(.green)
            }.frame(height: 150).id(point.id)
            if let accuracy = currentLocation.horizontalAccuracy {
                Text("Độ chính xác khoảng ±\(Int(accuracy.rounded())) m").font(.caption)
            }
            Button("Dùng điểm đi này", systemImage: "checkmark.circle") {
                guard let row = store.draft.rows.first else { return }
                store.setPoint(point, rowID: row.id)
                originCandidate = nil
            }
            Button("Bỏ ghim vừa lấy", role: .cancel) { originCandidate = nil }
        }
    }

    private func captureFreshOrigin() {
        guard originTask == nil else { return }
        error = nil
        originCandidate = nil
        originTask = Task {
            defer { originTask = nil }
            do {
                let clearedAt = try await playback.restoreDeviceLocation()
                try Task.checkCancellation()
                currentLocation.request(freshAfter: clearedAt)
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
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
                                    if index == store.draft.rows.count - 1 && point.source == "shortcut" {
                                        Text("Từ Phím tắt").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }.contentShape(Rectangle())
                    }.disabled(isCalculating || originTask != nil || (index == 0 && currentLocation.isLoading))
                    if index == 0 { originButtons }
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
            .onMove { from, to in
                guard !isCalculating else { return }
                let originID = store.draft.rows.first?.id
                store.draft.rows.move(fromOffsets: from, toOffset: to)
                if store.draft.rows.first?.id != originID { store.draft.originIsAutomatic = false }
                store.draft.dirty = true
            }
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

    @ViewBuilder private var originButtons: some View {
        let loading = isCalculating || originTask != nil || currentLocation.isLoading
        if store.draft.replacement == nil {
            let isSimulating = LocationSimulationSession.shared.isActive
            Button(isSimulating ? "Lấy vị trí đang mô phỏng" : "Lấy vị trí hiện tại", systemImage: "location") {
                originCandidate = nil
                store.draft.originIsAutomatic = true
                store.draft.dirty = true
                requestOriginIfNeeded()
            }.font(.caption).disabled(loading)
        }
        if store.draft.replacement == .detour, !store.draft.originIsAutomatic, let origin = playback.simulatedRouteOrigin {
            Button("Lấy vị trí đang mô phỏng", systemImage: "location") {
                originCandidate = nil
                store.useBotAsOrigin(origin)
            }.font(.caption).disabled(loading)
        }
        if store.draft.replacement != nil || playback.needsLocationRestore {
            Button("Lấy GPS thật mới", systemImage: "location.circle") {
                if playback.needsLocationRestore { confirmFreshLocation = true }
                else { captureFreshOrigin() }
            }.font(.caption).disabled(loading)
                .confirmationDialog("Tắt mô phỏng để lấy GPS thật?", isPresented: $confirmFreshLocation, titleVisibility: .visible) {
                    Button("Tắt và lấy GPS mới") { captureFreshOrigin() }
                    Button("Hủy", role: .cancel) {}
                } message: {
                    Text("Tuyến vẫn được giữ. App sẽ chờ thiết bị tắt mô phỏng rồi cho Sếp xem ghim mới.")
                }
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
        guard store.draft.originIsAutomatic, !store.draft.anchorsDetourToBot else { return }
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
        let draft = store.draft
        let selectedVehicle = vehicle
        task = Task {
            do {
                let replacesRoute = draft.replacesRouteFromSelectedOrigin(whileContinuingRoute: playback.canContinueFromBot)
                let anchor = replacesRoute ? nil : try await playback.pauseForEditing()
                if draft.anchorsDetourToBot && anchor == nil { throw LocationWorkflowError.simulationOriginUnavailable }
                try Task.checkCancellation()
                let points: [RouteWaypoint]
                if let anchor { points = try draft.rebased(at: anchor.coordinate, completedIDs: anchor.completedIDs) }
                else { guard let selected = draft.points else { throw RouteDataError.invalid }; points = selected }
                var route = try await VNRoutePlanner.calculate(waypoints: points, speedKmh: draft.speedKmh,
                                                               mode: draft.mode, vehicle: selectedVehicle, motorcycleKey: motorcycleKey)
                try Task.checkCancellation()
                if let anchor, route.legs.first?.coordinates.first != anchor.coordinate {
                    route.legs[0].coordinates.insert(anchor.coordinate, at: 0)
                    if !route.roadSpeeds.isEmpty { route.roadSpeeds.insert(route.roadSpeeds[0], at: 0) }
                }
                if replacesRoute { try await playback.replaceRoute(with: route) }
                else { try await playback.installDraft(route, anchor: anchor, keepPrevious: draft.anchorsDetourToBot) }
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
