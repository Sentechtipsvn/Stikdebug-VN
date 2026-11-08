import SwiftUI
import MapKit

struct LocationInputSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let onSelect: (RouteWaypoint) -> Void
    private let initialInput: String
    private let allowDeviceLocation: Bool
    @StateObject private var deviceLocation = CurrentLocationProvider()
    @StateObject private var completer = LocationSearchCompleter()
    @State private var text = ""
    @State private var candidate: RouteWaypoint?
    @State private var multiple: [RouteCoordinate] = []
    @State private var searchItems: [MKMapItem] = []
    @State private var bookmarks: [LocationBookmark] = []
    @State private var error: String?
    @State private var isResolving = false
    @State private var showMap = false
    @State private var requestID = UUID()
    @State private var task: Task<Void, Never>?

    init(title: String, initialInput: String = "", allowDeviceLocation: Bool = true, onSelect: @escaping (RouteWaypoint) -> Void) {
        self.title = title
        self.initialInput = initialInput
        self.onSelect = onSelect
        self.allowDeviceLocation = allowDeviceLocation
        _text = State(initialValue: initialInput)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Nhập vị trí") {
                    TextField("Dán link, tọa độ hoặc nhập địa chỉ", text: $text, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.search).onSubmit { resolve() }
                        .onChange(of: text) { _, value in
                            invalidateRequest()
                            candidate = nil
                            multiple = []
                            searchItems = []
                            error = nil
                            if !value.contains("://"), LocationLinkParser.coordinatePair(value) == nil { completer.update(query: value) }
                            else { completer.update(query: "") }
                        }
                    HStack {
                        PasteButton(payloadType: String.self) { values in
                            if let first = values.first { text = first }
                        }
                        .labelStyle(.titleAndIcon)
                        Spacer()
                        Button("Đọc vị trí", systemImage: "arrow.right.circle") { resolve() }
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isResolving)
                    }
                    if isResolving || deviceLocation.isLoading { ProgressView("Đang đọc vị trí…") }
                    if let error = error ?? deviceLocation.error { Text(error).foregroundStyle(.red).font(.footnote) }
                }
                if !multiple.isEmpty {
                    Section("Link có nhiều điểm — chọn điểm cần dùng") {
                        ForEach(Array(multiple.enumerated()), id: \.offset) { index, point in
                            Button { candidate = .init(name: "Điểm \(index + 1)", coordinate: point, source: "link") } label: {
                                Label(coordinateText(point), systemImage: "mappin.circle")
                            }
                        }
                    }
                }
                if !searchItems.isEmpty {
                    Section("Chọn kết quả đúng") {
                        ForEach(Array(searchItems.enumerated()), id: \.offset) { _, item in
                            Button { choose(item) } label: {
                                VStack(alignment: .leading) {
                                    Text(item.name ?? "Địa điểm")
                                    Text(item.placemark.title ?? "").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else if !completer.results.isEmpty {
                    Section("Gợi ý địa chỉ") {
                        ForEach(completer.results.prefix(6), id: \.self) { completion in
                            Button { search(completion: completion) } label: {
                                VStack(alignment: .leading) {
                                    Text(completion.title)
                                    Text(completion.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if let candidate {
                    Section("Kiểm tra điểm đã chọn") {
                        Text(candidate.name).font(.headline)
                        Text(coordinateText(candidate.coordinate)).font(.caption.monospaced())
                        Map(initialPosition: .region(MKCoordinateRegion(center: candidate.coordinate.clCoordinate, latitudinalMeters: 700, longitudinalMeters: 700))) {
                            Marker(candidate.name, coordinate: candidate.coordinate.clCoordinate).tint(.green)
                        }
                        .frame(height: 180).clipShape(RoundedRectangle(cornerRadius: 14)).id(candidate.id)
                        Button("Dùng vị trí này", systemImage: "checkmark.circle.fill") { apply(candidate) }
                            .font(.headline).tint(.green)
                    }
                }
                Section("Nguồn vị trí") {
                    if allowDeviceLocation {
                        Button("Lấy vị trí thiết bị", systemImage: "location.fill") { deviceLocation.request() }
                            .disabled(deviceLocation.isLoading)
                        if let coordinate = LocationSimulationSession.shared.coordinate {
                            Button("Vị trí đang mô phỏng", systemImage: "location.circle") {
                                candidate = .init(name: "Vị trí đang mô phỏng", coordinate: RouteCoordinate(coordinate), source: "simulated")
                            }
                        }
                    }
                    Button("Chọn trên bản đồ", systemImage: "map") { showMap = true }
                    if allowDeviceLocation {
                        Text("Khi đang mô phỏng, vị trí thiết bị có thể là tọa độ giả. Không coi đây là GPS thực.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Dấu trang") {
                    if bookmarks.isEmpty { Text("Chưa có dấu trang trong bản cài này.").foregroundStyle(.secondary) }
                    ForEach(bookmarks) { bookmark in
                        Button { apply(.init(name: bookmark.name, coordinate: RouteCoordinate(bookmark.coordinate), source: "bookmark")) } label: {
                            Label(bookmark.name, systemImage: "bookmark.fill")
                        }
                    }
                }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Hủy") { dismiss() } } }
            .tint(.green)
            .onAppear {
                if let data = UserDefaults.standard.data(forKey: "locationBookmarks") {
                    bookmarks = (try? JSONDecoder().decode([LocationBookmark].self, from: data)) ?? []
                }
                if !initialInput.isEmpty { resolve() }
            }
            .onReceive(deviceLocation.$result) { if let value = $0 { candidate = value } }
            .onDisappear { invalidateRequest(); deviceLocation.cancel() }
            .sheet(isPresented: $showMap) {
                VNMapPointPicker(initial: candidate?.coordinate) { candidate = $0; showMap = false }
            }
        }
    }

    private func coordinateText(_ point: RouteCoordinate) -> String { String(format: "%.6f, %.6f", point.latitude, point.longitude) }
    private func apply(_ point: RouteWaypoint) { onSelect(point); dismiss() }
    private func invalidateRequest() { task?.cancel(); task = nil; requestID = UUID(); isResolving = false }

    private func resolve() {
        invalidateRequest()
        let id = requestID
        let input = text
        isResolving = true
        error = nil
        completer.update(query: "")
        task = Task {
            do {
                let result = try await LocationInputResolver.resolve(input)
                guard !Task.isCancelled, requestID == id else { return }
                switch result {
                case .coordinate(let point, let name): candidate = .init(name: name ?? coordinateText(point), coordinate: point, source: "link")
                case .multiple(let points): multiple = points
                case .search(let query):
                    let request = MKLocalSearch.Request()
                    request.naturalLanguageQuery = query
                    let search = MKLocalSearch(request: request)
                    let response = try await withTaskCancellationHandler(operation: { try await search.start() }, onCancel: { search.cancel() })
                    guard !Task.isCancelled, requestID == id else { return }
                    searchItems = response.mapItems
                    if searchItems.isEmpty { error = "Không tìm thấy địa điểm. Sếp thử dán tọa độ hoặc chọn trên bản đồ." }
                case .unresolvedURL: throw LocationInputError.noExactCoordinate
                }
                isResolving = false
            } catch {
                guard !Task.isCancelled, requestID == id else { return }
                self.error = error.localizedDescription
                isResolving = false
            }
        }
    }

    private func search(completion: MKLocalSearchCompletion) {
        invalidateRequest()
        let id = requestID
        isResolving = true
        error = nil
        task = Task {
            do {
                let search = MKLocalSearch(request: MKLocalSearch.Request(completion: completion))
                let response = try await withTaskCancellationHandler(operation: { try await search.start() }, onCancel: { search.cancel() })
                guard !Task.isCancelled, requestID == id else { return }
                if response.mapItems.count == 1, let item = response.mapItems.first { choose(item) }
                else { searchItems = response.mapItems }
                if response.mapItems.isEmpty { error = "Không đọc được tọa độ của kết quả này." }
                completer.update(query: "")
                isResolving = false
            } catch {
                guard !Task.isCancelled, requestID == id else { return }
                self.error = error.localizedDescription
                isResolving = false
            }
        }
    }

    private func choose(_ item: MKMapItem) {
        candidate = .init(name: item.name ?? "Địa điểm", coordinate: RouteCoordinate(item.placemark.coordinate), source: "search")
        searchItems = []
        completer.update(query: "")
    }
}

private struct VNMapPointPicker: View {
    @Environment(\.dismiss) private var dismiss
    let initial: RouteCoordinate?
    let onSelect: (RouteWaypoint) -> Void
    @State private var point: RouteCoordinate?
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(position: $camera) {
                    if let point { Marker("Điểm đã chọn", coordinate: point.clCoordinate).tint(.green) }
                }
                .onTapGesture { location in if let coordinate = proxy.convert(location, from: .local) { point = RouteCoordinate(coordinate) } }
                .mapControls { MapCompass() }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Text("Chạm bản đồ để đặt ghim").font(.footnote)
                    Button("Dùng điểm này") {
                        if let point { onSelect(.init(name: String(format: "%.5f, %.5f", point.latitude, point.longitude), coordinate: point, source: "map")) }
                    }.buttonStyle(.borderedProminent).tint(.green).disabled(point == nil)
                }.frame(maxWidth: .infinity).padding().background(.regularMaterial)
            }
            .navigationTitle("Chọn trên bản đồ").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Hủy") { dismiss() } } }
            .onAppear {
                point = initial
                if let initial { camera = .region(.init(center: initial.clCoordinate, latitudinalMeters: 1500, longitudinalMeters: 1500)) }
            }
        }
    }
}
