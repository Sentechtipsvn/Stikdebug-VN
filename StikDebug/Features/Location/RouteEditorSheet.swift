import SwiftUI

private struct RouteDraftRow: Identifiable {
    var id = UUID()
    var point: RouteWaypoint?
    var dwell: Double = 0
}

private struct RouteEditingRow: Identifiable { let id: UUID; let title: String }

struct RouteEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let initial: SavedSimulationRoute?
    let onApply: (SavedSimulationRoute) -> Void
    @State private var rows: [RouteDraftRow]
    @State private var editing: RouteEditingRow?
    @State private var speedKmh: Double
    @State private var mode: RouteSpeedMode
    @State private var isCalculating = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    init(initial: SavedSimulationRoute?, onApply: @escaping (SavedSimulationRoute) -> Void) {
        self.initial = initial
        self.onApply = onApply
        _rows = State(initialValue: initial?.waypoints.map { .init(point: $0, dwell: $0.dwellSeconds) } ?? [.init(), .init()])
        _speedKmh = State(initialValue: initial?.speedKmh ?? 30)
        _mode = State(initialValue: initial?.speedMode ?? .fixed)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        VStack(alignment: .leading, spacing: 10) {
                            Button { editing = .init(id: row.id, title: rowTitle(index)) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: index == 0 ? "location.circle.fill" : index == rows.count - 1 ? "flag.checkered.circle.fill" : "mappin.circle.fill")
                                        .font(.title2).foregroundStyle(index == rows.count - 1 ? .red : .green)
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
                                }
                            }
                            .disabled(isCalculating)
                            if index > 0 && index < rows.count - 1 {
                                Stepper(value: Binding(get: { rows.first(where: { $0.id == row.id })?.dwell ?? 0 }, set: { value in
                                    if let i = rows.firstIndex(where: { $0.id == row.id }) { rows[i].dwell = value }
                                }), in: 0...86400, step: 30) {
                                    Text("Dừng \(Int(rows.first(where: { $0.id == row.id })?.dwell ?? 0)) giây").font(.footnote)
                                }.disabled(isCalculating)
                            }
                        }.padding(.vertical, 4)
                    }
                    .onMove { from, to in if !isCalculating { rows.move(fromOffsets: from, toOffset: to) } }
                    .onDelete { offsets in if !isCalculating && rows.count - offsets.count >= 2 { rows.remove(atOffsets: offsets) } }
                    Button("Thêm điểm dừng", systemImage: "plus.circle.fill") {
                        let row = RouteDraftRow()
                        rows.insert(row, at: max(1, rows.count - 1))
                        editing = .init(id: row.id, title: "Điểm dừng mới")
                    }.disabled(isCalculating || rows.count >= 100)
                } header: { Text("Các điểm theo thứ tự") } footer: {
                    Text("Mỗi điểm có thể chọn từ link, tọa độ, Dấu trang, vị trí thiết bị hoặc bản đồ. Bấm Sửa để đổi thứ tự.")
                }
                Section("Tốc độ mô phỏng") {
                    Picker("Chế độ", selection: $mode) {
                        Text("Tốc độ cố định").tag(RouteSpeedMode.fixed)
                        Text("Theo dữ liệu đường").tag(RouteSpeedMode.road)
                    }.disabled(isCalculating)
                    if mode == .fixed {
                        HStack {
                            Text("Tốc độ")
                            Spacer()
                            TextField("km/h", value: $speedKmh, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90)
                            Text("km/h").foregroundStyle(.secondary)
                        }
                        Slider(value: $speedKmh, in: 1...300, step: 1).tint(.green)
                    } else {
                        Text("Lấy tốc độ đường từ OpenStreetMap; nếu thiếu dữ liệu sẽ dùng tốc độ dự phòng từ tuyến. Cần mạng khi tính tuyến.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }.disabled(isCalculating)
                if let error { Section { Text(error).font(.footnote).foregroundStyle(.red) } }
                if isCalculating { Section { ProgressView(mode == .road ? "Đang tính các chặng và đọc tốc độ đường…" : "Đang tính các chặng…") } }
            }
            .navigationTitle("Tạo tuyến mô phỏng").navigationBarTitleDisplayMode(.inline).tint(.green)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Hủy") { task?.cancel(); dismiss() } }
                ToolbarItemGroup(placement: .confirmationAction) {
                    EditButton().disabled(isCalculating)
                    Button("Tính tuyến") { calculate() }
                        .fontWeight(.semibold)
                        .disabled(isCalculating || rows.contains(where: { $0.point == nil }) || !speedKmh.isFinite || !(1...300).contains(speedKmh))
                }
            }
            .sheet(item: $editing) { item in
                LocationInputSheet(title: item.title) { point in
                    if let index = rows.firstIndex(where: { $0.id == item.id }) { rows[index].point = point }
                    editing = nil
                }
            }
            .onDisappear { task?.cancel() }
        }
    }

    private func rowTitle(_ index: Int) -> String {
        if index == 0 { return "Điểm đi" }
        if index == rows.count - 1 { return "Điểm đến" }
        return "Điểm dừng \(index)"
    }

    private func calculate() {
        guard !isCalculating, !rows.contains(where: { $0.point == nil }) else { return }
        let points = rows.compactMap { row -> RouteWaypoint? in
            guard var point = row.point else { return nil }
            point.dwellSeconds = row.dwell
            return point
        }
        isCalculating = true
        error = nil
        task = Task {
            do {
                let route = try await VNRoutePlanner.calculate(waypoints: points, speedKmh: speedKmh, mode: mode)
                guard !Task.isCancelled else { return }
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
