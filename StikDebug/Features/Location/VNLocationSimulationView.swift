import SwiftUI
import MapKit
import UniformTypeIdentifiers

struct VNLocationSimulationView: View {
    @ObservedObject private var playback = RoutePlaybackController.shared
    @ObservedObject private var session = LocationSimulationSession.shared
    @ObservedObject private var tunnel = TunnelManager.shared
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var pin: RouteWaypoint?
    @State private var polyline: MKPolyline?
    @State private var showInput = false
    @State private var showEditor = false
    @State private var showLibrary = false
    @State private var showBookmarks = false
    @State private var showImporter = false
    @State private var showSaveRoute = false
    @State private var showSaveBookmark = false
    @State private var name = ""
    @State private var error: String?
    @State private var bookmarks: [LocationBookmark] = []
    @State private var isImporting = false

    private var pairingExists: Bool { FileManager.default.fileExists(atPath: PairingFileStore.prepareURL().path) }
    private var canEdit: Bool { !playback.isLocked && !isImporting }

    var body: some View {
        MapReader { proxy in
            Map(position: $camera) {
                if let polyline { MapPolyline(polyline).stroke(.green, lineWidth: 5) }
                if let route = playback.route {
                    ForEach(Array(route.waypoints.enumerated()), id: \.element.id) { index, point in
                        Marker(index == 0 ? "Điểm đi" : index == route.waypoints.count - 1 ? "Điểm đến" : "Dừng \(index)", coordinate: point.coordinate.clCoordinate)
                            .tint(index == route.waypoints.count - 1 ? .red : .green)
                    }
                } else if let pin { Marker(pin.name, coordinate: pin.coordinate.clCoordinate).tint(.red) }
                if let coordinate = session.coordinate { Marker("Đang mô phỏng", coordinate: coordinate).tint(.blue) }
            }
            .mapStyle(.standard(elevation: .realistic))
            .mapControls { MapCompass() }
            .onTapGesture { point in
                guard canEdit, let coordinate = proxy.convert(point, from: .local) else { return }
                playback.resetDraft()
                pin = .init(name: "Điểm trên bản đồ", coordinate: RouteCoordinate(coordinate), source: "map")
            }
        }
        .safeAreaInset(edge: .top) {
            if !tunnel.isConnected || tunnel.lastError != nil {
                DeviceConnectionStatusView(errorMessage: nil).padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)).padding(.horizontal)
            }
        }
        .safeAreaInset(edge: .bottom) { controls.padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22)).padding(12) }
        .navigationTitle("Mô phỏng vị trí").navigationBarTitleDisplayMode(.inline).tint(.green)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Chọn vị trí", systemImage: "magnifyingglass") { showInput = true }.disabled(!canEdit)
                Menu {
                    Button("Tạo / sửa tuyến", systemImage: "point.topleft.down.curvedto.point.bottomright.up") { showEditor = true }
                    Button("Tuyến đã lưu", systemImage: "tray.full") { showLibrary = true }
                    Button("Dấu trang", systemImage: "bookmark.fill") { loadBookmarks(); showBookmarks = true }
                    Button("Nhập GPX, KML, CSV…", systemImage: "square.and.arrow.down") { showImporter = true }
                    if playback.route != nil { Button("Xóa bản nháp", systemImage: "arrow.counterclockwise") { playback.resetDraft(); polyline = nil } }
                } label: { Image(systemName: "ellipsis.circle") }.disabled(!canEdit)
            }
        }
        .onAppear { loadBookmarks(); updateMap() }
        .onChange(of: playback.route?.legs) { _, _ in updateMap() }
        .sheet(isPresented: $showInput) { LocationInputSheet(title: "Chọn vị trí") { choosePin($0); showInput = false } }
        .sheet(isPresented: $showEditor) {
            RouteEditorSheet(initial: playback.route) { route in
                do { try playback.load(route); pin = nil; showEditor = false } catch { self.error = error.localizedDescription }
            }
        }
        .sheet(isPresented: $showLibrary) {
            RouteLibrarySheet { route in do { try playback.load(route); pin = nil } catch { self.error = error.localizedDescription } }
        }
        .sheet(isPresented: $showBookmarks) {
            BookmarksView(bookmarks: $bookmarks) { bookmark in
                choosePin(.init(name: bookmark.name, coordinate: RouteCoordinate(bookmark.coordinate), source: "bookmark"))
                showBookmarks = false
            } onDelete: { offsets in bookmarks.remove(atOffsets: offsets); saveBookmarks() }
        }
        .alert("Lưu tuyến", isPresented: $showSaveRoute) {
            TextField("Tên tuyến", text: $name)
            Button("Lưu") { saveRoute() }
            Button("Hủy", role: .cancel) {}
        } message: { Text("Lưu cả đường đi, các điểm dừng và tốc độ để mở lại.") }
        .alert("Lưu dấu trang", isPresented: $showSaveBookmark) {
            TextField("Tên địa điểm", text: $name)
            Button("Lưu") { savePin() }
            Button("Hủy", role: .cancel) {}
        }
        .alert("Không thực hiện được", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("Đóng", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: CoordinateImportParser.supportedContentTypes, allowsMultipleSelection: false) { result in
            importCoordinates(result)
        }
    }

    @ViewBuilder private var controls: some View {
        VStack(spacing: 10) {
            if let message = playback.message { Text(message).font(.footnote).foregroundStyle(playback.state == .failed ? .red : .secondary) }
            if isImporting { ProgressView("Đang nhập tọa độ…") }
            if let route = playback.route {
                HStack {
                    Text(route.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Button("Lưu tuyến", systemImage: "square.and.arrow.down") { name = route.name; showSaveRoute = true }.font(.caption)
                }
                ProgressView(value: playback.fractionComplete).tint(.green)
                HStack {
                    Text(String(format: "%.2f / %.2f km", playback.progress.distance / 1000, playback.totalDistance / 1000))
                    Spacer()
                    Text("Còn \(Int(ceil(playback.remainingTime / 60))) phút")
                }.font(.caption.monospaced()).foregroundStyle(.secondary)
                if playback.speedMode == .fixed {
                    HStack {
                        Image(systemName: "speedometer")
                        Slider(value: $playback.speedKmh, in: 1...300, step: 1).tint(.green)
                        Text("\(Int(playback.speedKmh)) km/h").font(.caption.monospaced()).frame(minWidth: 70)
                    }
                } else {
                    Text("Theo dữ liệu đường · \(Int(playback.speedMetersPerSecond * 3.6)) km/h").font(.caption)
                    Link("© OpenStreetMap contributors · ODbL", destination: URL(string: "https://www.openstreetmap.org/copyright")!).font(.caption2)
                }
                if playback.progress.dwellRemaining > 0 { Text("Đang dừng tại điểm: còn \(Int(ceil(playback.progress.dwellRemaining))) giây").font(.caption).foregroundStyle(.orange) }
                HStack(spacing: 12) {
                    if session.isActive || playback.isLocked || playback.state == .failed {
                        Button("Dừng", role: .destructive) { playback.stop() }.buttonStyle(.bordered)
                            .disabled(playback.isSending || playback.state == .stopping)
                    }
                    mainPlaybackButton
                    if canEdit { Button("Sửa tuyến") { showEditor = true }.buttonStyle(.bordered) }
                }
            } else {
                if let pin { Text(pin.name).font(.subheadline.weight(.semibold)).lineLimit(1); Text(String(format: "%.6f, %.6f", pin.coordinate.latitude, pin.coordinate.longitude)).font(.caption.monospaced()).foregroundStyle(.secondary) }
                else { Text("Chọn vị trí hoặc tạo tuyến để bắt đầu").font(.subheadline) }
                HStack(spacing: 10) {
                    if session.isActive { Button("Dừng", role: .destructive) { playback.stop() }.buttonStyle(.bordered).disabled(playback.isSending) }
                    if let pin {
                        Button("Đặt vị trí") {
                            Task { do { try await playback.simulatePin(pin.coordinate) } catch { self.error = error.localizedDescription } }
                        }.buttonStyle(.borderedProminent).disabled(!pairingExists || !canEdit)
                        Button("Lưu", systemImage: "bookmark") { name = pin.name; showSaveBookmark = true }.buttonStyle(.bordered).disabled(!canEdit)
                    } else {
                        Button("Chọn vị trí") { showInput = true }.buttonStyle(.bordered)
                    }
                    Button("Tạo tuyến") { showEditor = true }.buttonStyle(.borderedProminent).disabled(!canEdit)
                }
            }
        }
    }

    @ViewBuilder private var mainPlaybackButton: some View {
        switch playback.state {
        case .starting, .stopping: ProgressView().padding(.horizontal)
        case .running:
            Button("Tạm dừng", systemImage: "pause.fill") { playback.pause() }.buttonStyle(.borderedProminent).disabled(playback.isSending)
        case .paused:
            Button("Tiếp tục", systemImage: "play.fill") { playback.resume() }.buttonStyle(.borderedProminent).disabled(playback.isSending)
        default:
            Button(playback.state == .finished ? "Chạy lại" : "Bắt đầu", systemImage: "play.fill") { playback.start() }
                .buttonStyle(.borderedProminent).disabled(!pairingExists || playback.isSending)
        }
    }

    private func choosePin(_ point: RouteWaypoint) {
        guard canEdit else { return }
        playback.resetDraft()
        pin = point
        camera = .region(.init(center: point.coordinate.clCoordinate, latitudinalMeters: 1000, longitudinalMeters: 1000))
    }
    private func updateMap() {
        guard let route = playback.route else { polyline = nil; return }
        let points = route.coordinates.map(\.clCoordinate)
        polyline = MKPolyline(coordinates: points, count: points.count)
        if let polyline { camera = .rect(polyline.boundingMapRect) }
    }
    private func loadBookmarks() {
        if let data = UserDefaults.standard.data(forKey: "locationBookmarks") { bookmarks = (try? JSONDecoder().decode([LocationBookmark].self, from: data)) ?? [] }
    }
    private func saveBookmarks() {
        if let data = try? JSONEncoder().encode(bookmarks) { UserDefaults.standard.set(data, forKey: "locationBookmarks") }
    }
    private func savePin() {
        guard let pin else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        loadBookmarks()
        bookmarks.append(.init(name: trimmed.isEmpty ? pin.name : trimmed, latitude: pin.coordinate.latitude, longitude: pin.coordinate.longitude))
        saveBookmarks()
    }
    private func saveRoute() {
        guard var route = playback.route else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { route.name = trimmed }
        do { try RouteLibraryStore.shared.save(route); playback.updateRouteName(route.name) } catch { self.error = error.localizedDescription }
    }
    private func importCoordinates(_ result: Result<[URL], Error>) {
        guard canEdit else { return }
        do {
            guard let url = try result.get().first else { return }
            isImporting = true
            Task {
                defer { isImporting = false }
                do {
                    let points = try await Task.detached { try CoordinateImportParser.parse(url: url).map(RouteCoordinate.init) }.value
                    guard let first = points.first, let last = points.last else { throw RouteDataError.invalid }
                    if points.count == 1 { isImporting = false; choosePin(.init(name: url.deletingPathExtension().lastPathComponent, coordinate: first, source: "import")); return }
                    let route = SavedSimulationRoute(name: url.deletingPathExtension().lastPathComponent, waypoints: [.init(name: "Điểm đi", coordinate: first, source: "import"), .init(name: "Điểm đến", coordinate: last, source: "import")], legs: [.init(coordinates: points, expectedTravelTime: RoutePath(coordinates: points).totalDistance / 13.4)])
                    try playback.load(route)
                    pin = nil
                } catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
}
