import SwiftUI
import MapKit
import UniformTypeIdentifiers

private enum LocationModal: Identifiable {
    case input, editor, library, bookmarks
    case receiver(LocationReceiveRequest)
    var id: String {
        switch self {
        case .input: return "input"
        case .editor: return "editor"
        case .library: return "library"
        case .bookmarks: return "bookmarks"
        case .receiver(let request): return request.id.uuidString
        }
    }
}

struct VNLocationSimulationView: View {
    @ObservedObject private var playback = RoutePlaybackController.shared
    @ObservedObject private var session = LocationSimulationSession.shared
    @ObservedObject private var tunnel = TunnelManager.shared
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @ObservedObject private var workspace = LocationWorkspaceStore.shared
    @State private var modal: LocationModal?
    @State private var nextModal: LocationModal?
    @State private var polyline: MKPolyline?
    @State private var showImporter = false
    @State private var showSaveRoute = false
    @State private var showSaveBookmark = false
    @State private var name = ""
    @State private var error: String?
    @State private var bookmarks: [LocationBookmark] = []
    @State private var isImporting = false

    private var pin: RouteWaypoint? { workspace.selectedPin }
    private var canDraft: Bool { !isImporting && ![.starting, .stopping].contains(playback.state) }
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
                if let coordinate = session.coordinate {
                    Marker(playback.state == .failed || playback.pausePending ? "Vị trí cuối đã xác nhận" : "Đang mô phỏng", coordinate: coordinate).tint(.blue)
                }
            }
            .mapStyle(.standard(elevation: .realistic))
            .mapControls { MapCompass() }
            .onTapGesture { point in
                guard canEdit, playback.route == nil, !workspace.draft.dirty,
                      let coordinate = proxy.convert(point, from: .local) else { return }
                playback.resetDraft()
                workspace.discardDraft()
                workspace.selectedPin = .init(name: "Điểm trên bản đồ", coordinate: RouteCoordinate(coordinate), source: "map")
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
                Button("Chọn vị trí", systemImage: "magnifyingglass") { modal = .input }.disabled(!canEdit)
                Menu {
                    Button("Tạo / sửa tuyến", systemImage: "point.topleft.down.curvedto.point.bottomright.up") { openEditor() }.disabled(!canDraft)
                    Button("Tuyến đã lưu", systemImage: "tray.full") { modal = .library }.disabled(!canEdit)
                    Button("Dấu trang", systemImage: "bookmark.fill") { loadBookmarks(); modal = .bookmarks }.disabled(!canEdit)
                    Button("Nhập GPX, KML, CSV…", systemImage: "square.and.arrow.down") { showImporter = true }.disabled(!canEdit)
                    if playback.route != nil || workspace.draft.dirty {
                        Button("Xóa bản nháp", systemImage: "arrow.counterclockwise") {
                            playback.resetDraft(); workspace.discardDraft(); polyline = nil
                        }.disabled(!canEdit)
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .onAppear { loadBookmarks(); updateMap() }
        .onChange(of: playback.route?.legs) { _, _ in updateMap() }
        .task(id: workspace.incoming?.id) {
            await Task.yield()
            if !Task.isCancelled { receivePendingInput() }
        }
        .sheet(item: $modal, onDismiss: {
            if workspace.incoming != nil { receivePendingInput() }
            else if let queued = nextModal { nextModal = nil; modal = queued }
        }) { item in
            switch item {
            case .input:
                LocationInputSheet(title: "Chọn vị trí") { choosePin($0); modal = nil }
            case .editor:
                RouteEditorSheet { _ in workspace.selectedPin = nil; modal = nil }
            case .library:
                RouteLibrarySheet { route in
                    do { try playback.load(route); workspace.selectedPin = nil; workspace.didApply(route) }
                    catch { self.error = error.localizedDescription }
                }
            case .bookmarks:
                BookmarksView(bookmarks: $bookmarks) { bookmark in
                    choosePin(.init(name: bookmark.name, coordinate: RouteCoordinate(bookmark.coordinate), source: "bookmark"))
                    modal = nil
                } onDelete: { offsets in bookmarks.remove(atOffsets: offsets); saveBookmarks() }
            case .receiver(let request):
                IncomingLocationSheet(request: request) { choice, point in receive(choice, point: point) }
            }
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
            HStack(alignment: .firstTextBaseline) {
                Text(playback.statusTitle).font(.subheadline.weight(.semibold)).foregroundStyle(playback.isResting ? .orange : .primary)
                Spacer(minLength: 8)
                if let speed = playback.displaySpeedKmh {
                    Text("\(Int(speed.rounded())) km/h").font(.headline.monospacedDigit())
                        .accessibilityLabel("Tốc độ mô phỏng \(Int(speed.rounded())) ki lô mét một giờ")
                }
            }
            if let message = playback.message { Text(message).font(.caption).foregroundStyle(playback.state == .failed ? .red : .secondary) }
            if isImporting { ProgressView("Đang nhập tọa độ…") }
            if let route = playback.route {
                HStack {
                    Text(route.name).font(.subheadline).lineLimit(1)
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
                        Text("Tốc độ đặt").font(.caption)
                        Slider(value: $playback.speedKmh, in: 1...300, step: 1).tint(.green)
                        Text("\(Int(playback.speedKmh)) km/h").font(.caption.monospaced()).frame(minWidth: 65)
                    }
                } else {
                    Text("Tốc độ đặt: theo dữ liệu đường").font(.caption)
                    Link("© OpenStreetMap contributors · ODbL", destination: URL(string: "https://www.openstreetmap.org/copyright")!).font(.caption2)
                }
                if playback.isResting {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(playback.restName ?? "Điểm dừng").font(.caption).lineLimit(1)
                            Text("Còn \(RestDuration.clock(playback.progress.dwellRemaining))").font(.title3.monospacedDigit().weight(.semibold))
                        }
                        Spacer()
                        if playback.state == .running {
                            Button("Đi tiếp ngay") { playback.skipRest() }.font(.caption).buttonStyle(.bordered).disabled(playback.isSending)
                        } else { Text("Đã giữ bộ đếm").font(.caption).foregroundStyle(.secondary) }
                    }.foregroundStyle(.orange)
                }
                HStack(spacing: 8) {
                    returnGPSButton
                    mainPlaybackButton
                    Button("Sửa tuyến") { openEditor() }.buttonStyle(.bordered).disabled(!canDraft)
                }.font(.subheadline)
            } else {
                if let pin {
                    Text(pin.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(String(format: "%.6f, %.6f", pin.coordinate.latitude, pin.coordinate.longitude)).font(.caption.monospaced()).foregroundStyle(.secondary)
                } else { Text("Chọn vị trí hoặc tạo tuyến để bắt đầu").font(.subheadline) }
                HStack(spacing: 8) {
                    returnGPSButton
                    if let pin {
                        Button("Đặt vị trí") {
                            Task { do { try await playback.simulatePin(pin.coordinate) } catch { self.error = error.localizedDescription } }
                        }.buttonStyle(.borderedProminent).disabled(!pairingExists || !canEdit)
                        Button("Lưu", systemImage: "bookmark") { name = pin.name; showSaveBookmark = true }.buttonStyle(.bordered).disabled(!canEdit)
                    } else {
                        Button("Chọn vị trí") { modal = .input }.buttonStyle(.bordered).disabled(!canEdit)
                    }
                    Button("Tạo tuyến") { openEditor() }.buttonStyle(.borderedProminent).disabled(!canDraft)
                }.font(.subheadline)
            }
        }
    }

    @ViewBuilder private var returnGPSButton: some View {
        if session.isActive || playback.isLocked || playback.state == .failed {
            Button("Về GPS thật", role: .destructive) { playback.stop() }.buttonStyle(.bordered)
                .disabled(playback.state == .stopping)
        }
    }

    @ViewBuilder private var mainPlaybackButton: some View {
        switch playback.state {
        case .starting, .stopping: ProgressView().padding(.horizontal)
        case .running where playback.pausePending:
            ProgressView().accessibilityLabel("Đang tạm dừng").padding(.horizontal)
        case .running:
            Button("Tạm dừng", systemImage: "pause.fill") { playback.pause() }.buttonStyle(.borderedProminent)
        case .paused:
            Button("Tiếp tục", systemImage: "play.fill") { playback.resume() }.buttonStyle(.borderedProminent).disabled(playback.isSending)
        case .failed where playback.canResumeInterruptedRoute:
            Button("Thử tiếp tục", systemImage: "play.fill") { playback.resume() }
                .buttonStyle(.borderedProminent).disabled(!pairingExists || playback.isSending)
        default:
            Button(playback.state == .finished ? "Chạy lại" : "Bắt đầu", systemImage: "play.fill") { playback.start() }
                .buttonStyle(.borderedProminent).disabled(!pairingExists || playback.isSending)
        }
    }

    private func openEditor() {
        workspace.prepareEditor(playback: playback)
        modal = .editor
    }

    private func receivePendingInput() {
        guard let request = workspace.incoming else { return }
        if modal != nil {
            nextModal = nil
            modal = nil
            return
        }
        workspace.incoming = nil
        if request.isCompose { workspace.prepareEditor(playback: playback); modal = .editor }
        else { modal = .receiver(request) }
    }

    private func receive(_ choice: IncomingLocationChoice, point: RouteWaypoint) {
        do {
            switch choice {
            case .destination:
                workspace.receiveDestination(point, playback: playback)
                nextModal = .editor
                modal = nil
            case .stop:
                try workspace.receiveStop(point, playback: playback)
                nextModal = .editor
                modal = nil
            case .pin:
                modal = nil
                Task {
                    do {
                        try await playback.replaceWithPin(point.coordinate)
                        workspace.discardDraft()
                        workspace.selectedPin = point
                        camera = .region(.init(center: point.coordinate.clCoordinate, latitudinalMeters: 1000, longitudinalMeters: 1000))
                    } catch { self.error = error.localizedDescription }
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    private func choosePin(_ point: RouteWaypoint) {
        guard canEdit else { return }
        playback.resetDraft()
        workspace.discardDraft()
        workspace.selectedPin = point
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
                    workspace.selectedPin = nil
                    workspace.didApply(route)
                } catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
}
