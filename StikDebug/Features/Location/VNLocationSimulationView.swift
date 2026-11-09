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

private enum RouteConfirmation: Identifiable {
    case newRoute, detour, discard, previous, importFile, pin(RouteWaypoint)

    var id: String { title }
    var title: String {
        switch self {
        case .newRoute: return "Tạo bản nháp mới?"
        case .detour: return "Tạo nhánh dò mới?"
        case .discard: return "Xóa bản nháp và tuyến đang xem?"
        case .previous: return "Mở lại tuyến trước?"
        case .importFile: return "Thay tuyến bằng tệp nhập?"
        case .pin: return "Chuyển sang chọn vị trí?"
        }
    }
    var message: String {
        switch self {
        case .newRoute: return "App sẽ thay bản nháp hiện tại. Tuyến đang chạy chỉ đổi khi Sếp áp dụng."
        case .detour: return "App sẽ lấy vị trí bot làm điểm đi nếu đang mô phỏng và giữ điểm đến. Bản nháp hiện tại sẽ được thay."
        case .discard: return "Thao tác này bỏ bản nháp và tuyến đang hiển thị. Tuyến đã lưu vẫn có trong thư viện."
        case .previous: return "App sẽ thay bản nháp và chuẩn bị tuyến trước từ đầu. Phiên mô phỏng hiện tại sẽ tắt nếu đang chạy."
        case .importFile: return "Tệp hợp lệ sẽ thay bản nháp và tuyến đang hiển thị."
        case .pin: return "Chọn vị trí này sẽ thay bản nháp và tuyến đang hiển thị."
        }
    }
}

struct VNLocationSimulationView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var playback = RoutePlaybackController.shared
    @ObservedObject private var session = LocationSimulationSession.shared
    @ObservedObject private var tunnel = TunnelManager.shared
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var displayCamera: MapCamera?
    @ObservedObject private var workspace = LocationWorkspaceStore.shared
    @State private var modal: LocationModal?
    @State private var nextModal: LocationModal?
    @State private var awaitingModalDismiss = false
    @State private var polyline: MKPolyline?
    @State private var showImporter = false
    @State private var showSaveRoute = false
    @State private var showSaveBookmark = false
    @State private var name = ""
    @State private var error: String?
    @State private var bookmarks: [LocationBookmark] = []
    @State private var isImporting = false
    @State private var confirmation: RouteConfirmation?
    @State private var deferredConfirmation: RouteConfirmation?
    @State private var showProbeOptions = false
    @State private var selectingProbe = false

    private var pin: RouteWaypoint? { workspace.selectedPin }
    private var canDraft: Bool { !isImporting && ![.starting, .stopping].contains(playback.state) }
    private var pairingExists: Bool { FileManager.default.fileExists(atPath: PairingFileStore.prepareURL().path) }
    private var canEdit: Bool { !playback.isLocked && !isImporting }
    private var hasRouteWork: Bool { playback.route != nil || workspace.draft.dirty }

    private var map: some View {
        MapReader { proxy in
            Map(position: $camera) {
                if let polyline { MapPolyline(polyline).stroke(.green, lineWidth: 5) }
                routeMarkers
                if let probe = playback.probeCoordinate {
                    Marker("Mốc dò", systemImage: "scope", coordinate: probe.clCoordinate).tint(.orange)
                }
            }
            .mapStyle(.standard(elevation: .realistic))
            .mapControls { MapCompass() }
            .onMapCameraChange(frequency: .continuous) { context in displayCamera = context.camera }
            .overlay { simulationArrow(using: proxy, camera: displayCamera) }
            .onTapGesture { point in
                guard let coordinate = proxy.convert(point, from: .local) else { return }
                if selectingProbe {
                    do {
                        try playback.setProbe(near: RouteCoordinate(coordinate))
                        selectingProbe = false
                    } catch { self.error = error.localizedDescription }
                    return
                }
                guard canEdit, !hasRouteWork else { return }
                playback.resetDraft()
                workspace.discardDraft()
                workspace.selectedPin = .init(name: "Điểm trên bản đồ", coordinate: RouteCoordinate(coordinate), source: "map")
            }
        }
    }

    private func simulationArrow(using proxy: MapProxy, camera: MapCamera?) -> some View {
        let animated = !reduceMotion && playback.animatesRouteMarker
        let heading = camera?.heading ?? 0
        return TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animated)) { _ in
            if let pose = playback.visualPose(interpolate: animated),
               let position = proxy.convert(pose.coordinate.clCoordinate, to: .local) {
                let color: Color = playback.holdUnconfirmed || playback.state == .failed ? .orange : .blue
                Image(systemName: pose.bearing == nil ? "circle.fill" : "location.north.fill")
                    .font(.system(size: pose.bearing == nil ? 12 : 22, weight: .semibold))
                    .foregroundStyle(color)
                    .rotationEffect(.degrees((pose.bearing ?? heading) - heading))
                    .accessibilityLabel(simulationMarkerTitle)
                    .position(position)
            }
        }.allowsHitTesting(false).clipped()
    }

    @MapContentBuilder private var routeMarkers: some MapContent {
        if let route = playback.route {
            ForEach(Array(route.waypoints.enumerated()), id: \.element.id) { item in
                waypointMarker(item.element, index: item.offset, lastIndex: route.waypoints.count - 1)
            }
        } else if let pin {
            Marker(pin.name, coordinate: pin.coordinate.clCoordinate).tint(.red)
        }
    }

    private func waypointMarker(_ point: RouteWaypoint, index: Int, lastIndex: Int) -> some MapContent {
        let title: String
        if index == 0 { title = "Điểm đi" }
        else if index == lastIndex { title = "Điểm đến" }
        else { title = "Dừng \(index)" }
        let color: Color = index == lastIndex ? .red : .green
        return Marker(title, coordinate: point.coordinate.clCoordinate).tint(color)
    }

    private var simulationMarkerTitle: String {
        let isUnconfirmed = playback.state == .failed || playback.pausePending || playback.holdUnconfirmed
        return isUnconfirmed ? "Vị trí cuối đã xác nhận" : "Đang mô phỏng"
    }

    private var mapPage: some View {
        map
        .overlay(alignment: .topLeading) { routeAttribution.padding(8) }
        .safeAreaInset(edge: .top) {
            if !tunnel.isConnected || tunnel.lastError != nil {
                DeviceConnectionStatusView(errorMessage: nil).padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)).padding(.horizontal)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            controls.padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                .padding(.horizontal, 10).padding(.bottom, 6)
        }
        .navigationTitle("Mô phỏng vị trí").navigationBarTitleDisplayMode(.inline).tint(.green)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Chọn vị trí", systemImage: "magnifyingglass") { modal = .input }.disabled(!canEdit)
                locationMenu
            }
        }
        .onAppear { loadBookmarks(); updateMap() }
        .onChange(of: playback.route?.legs) { _, _ in updateMap() }
        .onChange(of: playback.route?.id) { _, _ in selectingProbe = false }
        .onChange(of: confirmation?.id) { _, next in
            if next == nil && modal == nil { receivePendingInput() }
        }
        .task(id: workspace.incoming?.id) {
            await Task.yield()
            if !Task.isCancelled { receivePendingInput() }
        }
    }

    private var locationMenu: some View {
        Menu {
            if let route = playback.route {
                Section(route.name) {
                    Button("Đổi nhánh từ đây", systemImage: "arrow.triangle.branch") {
                        if workspace.draft.replacement == .detour { openEditor() }
                        else { confirmation = .detour }
                    }.disabled(!canDraft)
                    if selectingProbe {
                        Button("Hủy chọn mốc", systemImage: "xmark") { selectingProbe = false }
                    } else {
                        Button("Dò tới mốc", systemImage: "scope") { showProbeOptions = true }.disabled(!canDraft)
                    }
                    if playback.probeDistance != nil {
                        Button("Bỏ mốc dò", systemImage: "scope") { playback.clearProbe() }
                    }
                    Button("Lưu tuyến", systemImage: "square.and.arrow.down") { name = route.name; showSaveRoute = true }
                }
            }
            Button("Tạo / sửa tuyến", systemImage: "point.topleft.down.curvedto.point.bottomright.up") { openEditor() }.disabled(!canDraft)
            Button("Tuyến đã lưu", systemImage: "tray.full") { modal = .library }.disabled(!canEdit)
            Button("Dấu trang", systemImage: "bookmark.fill") { loadBookmarks(); modal = .bookmarks }.disabled(!canEdit)
            Button("Nhập GPX, KML, CSV…", systemImage: "square.and.arrow.down") {
                if hasRouteWork { confirmation = .importFile } else { showImporter = true }
            }.disabled(!canEdit)
            if let previous = playback.previousRoute {
                Button("Mở lại tuyến trước", systemImage: "arrow.uturn.backward") {
                    confirmation = .previous
                }.disabled(!canDraft || previous.id == playback.route?.id)
            }
            if hasRouteWork {
                Button("Tạo tuyến mới", systemImage: "plus.square") { confirmation = .newRoute }.disabled(!canDraft)
                Button("Xóa bản nháp", systemImage: "trash", role: .destructive) {
                    confirmation = .discard
                }.disabled(!canEdit)
            }
        } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("Tùy chọn mô phỏng") }
    }

    @ViewBuilder private var routeAttribution: some View {
        if let route = playback.route, route.vehicle == .motorcycle || playback.speedMode == .road {
            HStack(spacing: 6) {
                if route.vehicle == .motorcycle {
                    Link("Powered by Geoapify", destination: URL(string: "https://www.geoapify.com/")!)
                }
                Link("© OpenStreetMap contributors", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
            }
            .font(.caption2).padding(.horizontal, 6).padding(.vertical, 3)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    var body: some View {
        mapPage
        .sheet(item: $modal, onDismiss: {
            awaitingModalDismiss = false
            if let action = deferredConfirmation { deferredConfirmation = nil; confirmation = action }
            else if workspace.incoming != nil { receivePendingInput() }
            else if let queued = nextModal { nextModal = nil; modal = queued }
        }) { item in
            switch item {
            case .input:
                LocationInputSheet(title: "Chọn vị trí") { choosePin($0); modal = nil }
            case .editor:
                RouteEditorSheet { _ in workspace.selectedPin = nil; modal = nil }
            case .library:
                RouteLibrarySheet(confirmSelection: hasRouteWork) { route in
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
        .alert(confirmation?.title ?? "", isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
        ), presenting: confirmation) { action in
            Button("Xác nhận") { applyConfirmation(action) }
            Button("Hủy", role: .cancel) {}
        } message: { action in Text(action.message) }
        .confirmationDialog("Dò tới mốc", isPresented: $showProbeOptions, titleVisibility: .visible) {
            Button("2 km từ điểm đi") { setProbe(at: 2_000) }
            Button("3 km từ điểm đi") { setProbe(at: 3_000) }
            Button("Chọn trên đường màu xanh") { selectingProbe = true }
            Button("Hủy", role: .cancel) {}
        } message: { Text("Bot sẽ giữ vị trí khi tới mốc. Quãng đường tính dọc tuyến từ điểm đi đã chọn.") }
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
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(selectingProbe ? "Chạm đường xanh để đặt mốc" : playback.statusTitle)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(playback.isResting ? .orange : .primary)
                Spacer(minLength: 8)
                let speed = playback.displaySpeedKmh
                let rounded = Int((speed ?? 0).rounded())
                Text("\(rounded) km/h").font(.headline.monospacedDigit())
                    .opacity(speed == nil ? 0 : 1)
                    .accessibilityHidden(speed == nil)
                    .accessibilityLabel("Tốc độ mô phỏng \(rounded) ki lô mét một giờ")
            }
            if let message = playback.message {
                Text(message).font(.caption).foregroundStyle(playback.state == .failed || playback.holdUnconfirmed ? .red : .secondary)
            }
            if (playback.isHoldingProbe || playback.holdUnconfirmed), let time = playback.lastConfirmedAt {
                Text("Xác nhận lần cuối \(time.formatted(date: .omitted, time: .standard))")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            if isImporting { ProgressView("Đang nhập tọa độ…") }
            if playback.route != nil {
                HStack(spacing: 8) {
                    Text(String(format: "%.2f / %.2f km", playback.progress.distance / 1000, playback.totalDistance / 1000))
                    ProgressView(value: playback.fractionComplete).tint(.green).accessibilityLabel("Tiến độ tuyến")
                    Text("Còn \(Int(ceil(playback.remainingTime / 60))) phút")
                }.font(.caption.monospaced()).foregroundStyle(.secondary)
                if playback.speedMode == .fixed {
                    HStack {
                        Text("Tốc độ đặt").font(.caption)
                        Slider(value: $playback.speedKmh, in: 1...300, step: 1).tint(.green)
                        Text("\(Int(playback.speedKmh)) km/h").font(.caption.monospaced()).frame(minWidth: 65)
                    }
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
                }.font(.subheadline).lineLimit(1).minimumScaleFactor(0.8)
            } else {
                if let pin {
                    Text(pin.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(String(format: "%.6f, %.6f", pin.coordinate.latitude, pin.coordinate.longitude)).font(.caption.monospaced()).foregroundStyle(.secondary)
                } else { Text("Chọn vị trí hoặc tạo tuyến để bắt đầu").font(.subheadline) }
                HStack(spacing: 8) {
                    returnGPSButton
                    if playback.holdUnconfirmed {
                        retryHoldButton
                    } else if let pin {
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

    private var retryHoldButton: some View {
        Button("Thử giữ lại", systemImage: "location.circle") { playback.refreshHeldCoordinate() }
            .buttonStyle(.borderedProminent).disabled(!pairingExists || playback.isSending)
    }

    private var playbackAction: (title: String, symbol: String, disabled: Bool, run: () -> Void) {
        if playback.holdUnconfirmed {
            return ("Thử giữ lại", "location.circle", !pairingExists || playback.isSending, { playback.refreshHeldCoordinate() })
        }
        switch playback.state {
        case .starting: return ("Bắt đầu", "play.fill", true, {})
        case .stopping: return ("Về GPS thật", "location.fill", true, {})
        case .running: return ("Tạm dừng", "pause.fill", playback.pausePending, { playback.pause() })
        case .paused: return ("Tiếp tục", "play.fill", playback.isSending, { playback.resume() })
        case .failed where playback.canResumeInterruptedRoute:
            return ("Thử tiếp tục", "play.fill", !pairingExists || playback.isSending, { playback.resume() })
        default:
            return (playback.state == .finished ? "Chạy lại" : "Bắt đầu", "play.fill",
                    !pairingExists || playback.isSending, { playback.start() })
        }
    }

    private var mainPlaybackButton: some View {
        let action = playbackAction
        let isWaiting = playback.pausePending || [.starting, .stopping].contains(playback.state)
        return Button(action: action.run) {
            HStack(spacing: 6) {
                ZStack {
                    if isWaiting { ProgressView().controlSize(.small).tint(.white) }
                    else { Image(systemName: action.symbol) }
                }.frame(width: 18, height: 18)
                ZStack {
                    Text("Thử tiếp tục").hidden()
                    Text(action.title)
                }
            }
        }
        .buttonStyle(.borderedProminent)
        .layoutPriority(1)
        .disabled(action.disabled)
        .accessibilityLabel(isWaiting ? playback.statusTitle : action.title)
    }

    private func setProbe(at distance: Double) {
        do { try playback.setProbe(at: distance) }
        catch { self.error = error.localizedDescription }
    }

    private func applyConfirmation(_ action: RouteConfirmation) {
        switch action {
        case .newRoute, .detour:
            guard canDraft else { return }
            let replacement: RouteDraftReplacement
            if case .detour = action { replacement = .detour } else { replacement = .newRoute }
            workspace.draft = .init(replacement: replacement, from: playback.route)
            openEditor()
        case .discard:
            guard canEdit else { return }
            playback.resetDraft()
            workspace.discardDraft()
            polyline = nil
        case .previous:
            guard canDraft, let previous = playback.previousRoute else { return }
            Task {
                do {
                    try await playback.replaceRoute(with: previous)
                    workspace.didApply(previous)
                    workspace.selectedPin = nil
                } catch { self.error = error.localizedDescription }
            }
        case .importFile:
            if canEdit { showImporter = true }
        case .pin(let point):
            applyPinSelection(point)
        }
    }

    private func openEditor() {
        workspace.prepareEditor(playback: playback)
        modal = .editor
    }

    private func receivePendingInput() {
        guard !awaitingModalDismiss, confirmation == nil, deferredConfirmation == nil, let request = workspace.incoming else { return }
        nextModal = nil
        if modal != nil {
            awaitingModalDismiss = true
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
                openEditorAfterReceive()
            case .stop:
                try workspace.receiveStop(point, playback: playback)
                openEditorAfterReceive()
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

    private func openEditorAfterReceive() {
        nextModal = .editor
        awaitingModalDismiss = true
        modal = nil
    }

    private func choosePin(_ point: RouteWaypoint) {
        guard canEdit else { return }
        if hasRouteWork { deferredConfirmation = .pin(point) }
        else { applyPinSelection(point) }
    }

    private func applyPinSelection(_ point: RouteWaypoint) {
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
                    if points.count == 1 { isImporting = false; applyPinSelection(.init(name: url.deletingPathExtension().lastPathComponent, coordinate: first, source: "import")); return }
                    let route = SavedSimulationRoute(name: url.deletingPathExtension().lastPathComponent, waypoints: [.init(name: "Điểm đi", coordinate: first, source: "import"), .init(name: "Điểm đến", coordinate: last, source: "import")], legs: [.init(coordinates: points, expectedTravelTime: RoutePath(coordinates: points).totalDistance / 13.4)])
                    try playback.load(route)
                    workspace.selectedPin = nil
                    workspace.didApply(route)
                } catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
}
