import Foundation
import CoreLocation
import Combine

extension RouteCoordinate {
    init(_ value: CLLocationCoordinate2D) { self.init(latitude: value.latitude, longitude: value.longitude) }
    var clCoordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

enum RoutePlaybackState: Equatable {
    case ready, starting, running, paused, finished, stopping, failed
}

struct RouteEditAnchor {
    let coordinate: RouteCoordinate
    let remainingRest: Double
    let restName: String?
    let completedIDs: Set<UUID>
}

// Includes device sleep and is unaffected by manual changes to the calendar clock.
enum RouteSteadyClock {
    private static let origin = ContinuousClock.now
    static func seconds() -> TimeInterval {
        let elapsed = origin.duration(to: ContinuousClock.now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }
}

@MainActor
final class RoutePlaybackController: ObservableObject {
    static let shared = RoutePlaybackController()
    @Published private(set) var route: SavedSimulationRoute?
    @Published private(set) var state: RoutePlaybackState = .ready
    @Published private(set) var progress = RouteProgress()
    @Published private(set) var message: String?
    @Published private(set) var isSending = false
    @Published var speedKmh: Double = 30 {
        didSet { if speedKmh.isFinite { route?.speedKmh = min(300, max(1, speedKmh)) } }
    }
    @Published var speedMode: RouteSpeedMode = .fixed { didSet { route?.speedMode = speedMode } }

    private var path = RoutePath(coordinates: [])
    private var dwells: [RouteDwell] = []
    private var task: Task<Void, Never>?
    private var routeID: UUID?
    private var generation = UUID()
    private var lastUptime: TimeInterval = 0
    private var restDeadline: TimeInterval?
    private var initialRestName: String?
    private var pausePending = false
    private var pendingPauseReason: String?
    private var commandCount = 0
    private let session: LocationSimulationSession
    private let clock: () -> TimeInterval
    private let automaticTicks: Bool

    init(clock: @escaping () -> TimeInterval = { RouteSteadyClock.seconds() }, automaticTicks: Bool = true, session: LocationSimulationSession = .shared) {
        self.clock = clock
        self.automaticTicks = automaticTicks
        self.session = session
    }

    var isLocked: Bool { [.starting, .running, .paused, .stopping].contains(state) || isSending }
    var hasActiveRoute: Bool { [.running, .paused].contains(state) && route != nil }
    var isResting: Bool { progress.dwellRemaining > 0 && [.running, .paused].contains(state) }
    var phase: SimulationDisplayPhase {
        switch state {
        case .starting: return .starting
        case .stopping: return .stopping
        case .failed: return .failed
        case .paused: return .paused
        case .running: return isResting ? .resting : .moving
        case .finished: return .holding
        case .ready:
            if session.isActive { return .holding }
            return route == nil ? .inactive : .ready
        }
    }
    var statusTitle: String {
        if state == .finished { return "Đã đến — đang giữ vị trí" }
        if phase == .resting { return "Đang nghỉ tại \(restName ?? "trạm")" }
        return phase.title
    }
    var displaySpeedKmh: Double? {
        if phase == .moving { return speedMetersPerSecond * 3.6 }
        return phase.showsZeroSpeed ? 0 : nil
    }
    var restName: String? {
        guard progress.dwellRemaining > 0 else { return nil }
        if let initialRestName { return initialRestName }
        guard let route, route.waypoints.indices.contains(progress.nextStop) else { return "trạm" }
        return route.waypoints[progress.nextStop].name
    }
    var fractionComplete: Double { path.totalDistance > 0 ? min(1, progress.distance / path.totalDistance) : 0 }
    var totalDistance: Double { path.totalDistance }
    var speedMetersPerSecond: Double {
        if speedMode == .road, let speeds = route?.roadSpeeds, !speeds.isEmpty {
            return max(1, speeds[min(speeds.count - 1, path.segmentIndex(at: progress.distance))])
        }
        return max(1, min(300, speedKmh)) / 3.6
    }
    var remainingTime: Double {
        let travel: Double
        if speedMode == .road, let speeds = route?.roadSpeeds, speeds.count == max(0, path.coordinates.count - 1), !speeds.isEmpty {
            travel = speeds.indices.reduce(0) { sum, i in
                let remaining = path.cumulativeDistances[i + 1] - max(progress.distance, path.cumulativeDistances[i])
                return sum + max(0, remaining) / max(1, speeds[i])
            }
        } else { travel = max(0, path.totalDistance - progress.distance) / speedMetersPerSecond }
        return travel + progress.remainingDwell(stops: dwells)
    }

    func load(_ route: SavedSimulationRoute) throws {
        guard !isLocked else { throw LocationWorkflowError.busy }
        try configure(route)
    }

    private func configure(_ route: SavedSimulationRoute) throws {
        let validated = try route.validated()
        task?.cancel()
        self.route = validated
        speedKmh = validated.speedKmh
        speedMode = validated.speedMode
        path = RoutePath(coordinates: validated.coordinates)
        var points: [RouteCoordinate] = []
        dwells = []
        for (index, leg) in validated.legs.enumerated() {
            for point in leg.coordinates where points.last != point { points.append(point) }
            if index < validated.legs.count - 1 {
                dwells.append(.init(distance: RoutePath(coordinates: points).totalDistance, seconds: validated.waypoints[index + 1].dwellSeconds))
            }
        }
        progress = RouteProgress()
        restDeadline = nil
        initialRestName = nil
        pausePending = false
        state = .ready
        message = nil
    }

    func resetDraft() {
        guard !isLocked else { return }
        route = nil
        path = RoutePath(coordinates: [])
        progress = RouteProgress()
        dwells = []
        restDeadline = nil
        initialRestName = nil
        state = .ready
        message = nil
    }

    func updateRouteName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { route?.name = trimmed }
    }

    func remainingDraft() -> LocationRouteDraft {
        guard let route, hasActiveRoute, let current = session.coordinate else { return LocationRouteDraft() }
        var result = LocationRouteDraft(route: route)
        result.originIsAutomatic = true
        result.rows = [.init(point: .init(name: "Vị trí đang mô phỏng", coordinate: RouteCoordinate(current), source: "simulated"))]
        result.rows += route.waypoints.dropFirst(progress.nextStop + 1).map { .init(point: $0, dwell: $0.dwellSeconds) }
        if result.rows.count < 2 { result.rows.append(.init()) }
        return result
    }

    func pauseForEditing() async throws -> RouteEditAnchor? {
        guard hasActiveRoute || (state == .finished && session.isActive) else {
            if isLocked { throw LocationWorkflowError.busy }
            return nil
        }
        if state == .running { pause(reason: "Đã tạm dừng để áp dụng tuyến sửa. Bấm Tiếp tục khi sẵn sàng.") }
        while isSending || pausePending {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(30))
        }
        guard [.paused, .finished].contains(state), let current = session.coordinate, let route else { throw LocationWorkflowError.busy }
        let completed = Set(route.waypoints.dropFirst().prefix(progress.nextStop).map(\.id))
        return .init(coordinate: RouteCoordinate(current), remainingRest: progress.dwellRemaining, restName: restName, completedIDs: completed)
    }

    func installDraft(_ route: SavedSimulationRoute, anchor: RouteEditAnchor?) throws {
        let route = try route.validated()
        if let anchor {
            guard !isSending, [.paused, .finished].contains(state) else { throw LocationWorkflowError.busy }
            _ = interruptForExternalAction()
            try configure(route)
            progress.setDwellRemaining(anchor.remainingRest)
            initialRestName = anchor.restName
            routeID = session.startRoute(at: anchor.coordinate.clCoordinate, coordinates: route.coordinates.map(\.clCoordinate))
            state = .paused
            message = "Đã áp dụng tuyến mới. Bấm Tiếp tục để đi tiếp."
            holdLastCoordinate()
        } else { try load(route) }
    }

    func start() {
        guard !isLocked, let route, let first = route.coordinates.first else { return }
        let pairing = PairingFileStore.prepareURL().path
        guard FileManager.default.fileExists(atPath: pairing) else { message = "Hãy nhập tệp ghép đôi trước khi mô phỏng."; return }
        generation = UUID()
        let token = generation
        task?.cancel()
        session.pauseResending()
        state = .starting
        message = nil
        progress = RouteProgress()
        restDeadline = nil
        initialRestName = nil
        pausePending = false
        task = Task { [weak self] in
            guard let self else { return }
            let code = await self.send(first, pairing: pairing)
            guard !Task.isCancelled, self.generation == token else { return }
            guard code == 0 else { self.fail(code); return }
            self.routeID = self.session.startRoute(at: first.clCoordinate, coordinates: route.coordinates.map(\.clCoordinate))
            self.state = .running
            self.lastUptime = self.clock()
            if self.automaticTicks { await self.play(token: token) }
        }
    }

    func pause(reason: String? = nil) {
        guard state == .running else { return }
        if isSending { pausePending = true; pendingPauseReason = reason; return }
        completePause(reason: reason)
    }

    private func completePause(reason: String?) {
        if let deadline = restDeadline { progress.setDwellRemaining(max(0, deadline - clock())) }
        restDeadline = nil
        pausePending = false
        pendingPauseReason = nil
        task?.cancel()
        task = nil
        state = .paused
        message = reason
        holdLastCoordinate()
    }

    func resume() {
        guard state == .paused, !isSending, let id = routeID, session.isCurrentRoute(id) else { return }
        state = .running
        message = nil
        lastUptime = clock()
        if progress.dwellRemaining > 0 {
            restDeadline = clock() + progress.dwellRemaining
            holdLastCoordinate()
        } else { session.pauseResending() }
        let token = generation
        if automaticTicks {
            task = Task { [weak self] in guard let self else { return }; await self.play(token: token) }
        }
    }

    func skipRest() {
        guard state == .running, progress.dwellRemaining > 0, !isSending else { return }
        progress.setDwellRemaining(0)
        restDeadline = nil
        initialRestName = nil
        lastUptime = clock()
        session.pauseResending()
    }

    @discardableResult
    func interruptForExternalAction() -> UUID {
        generation = UUID()
        task?.cancel()
        task = nil
        routeID = nil
        restDeadline = nil
        pausePending = false
        session.pauseResending()
        session.clearRoute()
        if route != nil { state = .ready }
        return generation
    }
    func isCurrentAction(_ token: UUID) -> Bool { generation == token }

    func stop() {
        guard state != .stopping else { return }
        _ = interruptForExternalAction()
        state = .stopping
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            let code = await self.command { clear_simulated_location() }
            guard self.generation == token else { return }
            if code == 0 {
                self.session.stop()
                self.state = .ready
                self.progress = RouteProgress()
                self.message = "Đã tắt mô phỏng."
            } else {
                self.state = .failed
                self.message = "Chưa tắt được mô phỏng (mã \(code)). Kiểm tra kết nối và thử lại."
                self.holdLastCoordinate()
            }
        }
    }

    func simulatePin(_ coordinate: RouteCoordinate) async throws {
        guard !isLocked else { throw LocationWorkflowError.busy }
        try await replaceWithPin(coordinate)
    }

    func replaceWithPin(_ coordinate: RouteCoordinate) async throws {
        guard coordinate.isValid else { throw RouteDataError.invalid }
        guard FileManager.default.fileExists(atPath: PairingFileStore.prepareURL().path) else {
            throw NSError(domain: "StikDebugVN", code: 1, userInfo: [NSLocalizedDescriptionKey: "Hãy nhập tệp ghép đôi trước khi mô phỏng."])
        }
        let token = interruptForExternalAction()
        state = .starting
        let code = await send(coordinate, pairing: PairingFileStore.prepareURL().path)
        guard generation == token else { throw CancellationError() }
        guard code == 0 else { fail(code); throw NSError(domain: "StikDebugVN", code: Int(code), userInfo: [NSLocalizedDescriptionKey: message ?? "Không đặt được vị trí."]) }
        state = .ready
        resetDraft()
        session.start(at: coordinate.clCoordinate)
        holdLastCoordinate()
    }

    private func play(token: UUID) async {
        while !Task.isCancelled && generation == token && state == .running {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            await advanceTick(at: clock())
        }
    }

    // Also driven by the deterministic macOS controller harness; it calls this production path.
    func advanceTick(at now: TimeInterval) async {
        guard state == .running, !isSending, let id = routeID, session.isCurrentRoute(id) else { return }
        let token = generation
        if progress.dwellRemaining > 0 {
            if restDeadline == nil { restDeadline = now + progress.dwellRemaining }
            progress.setDwellRemaining(max(0, (restDeadline ?? now) - now))
            lastUptime = now
            if progress.dwellRemaining <= 0 {
                restDeadline = nil
                initialRestName = nil
                session.pauseResending()
            }
            // After a suspended rest, movement starts from this point on the next tick, never catches up.
            return
        }
        let elapsed = now - lastUptime
        lastUptime = now
        guard elapsed >= 0 else { return }
        if elapsed > 3 {
            pause(reason: "Ứng dụng vừa bị gián đoạn. Tuyến đã tạm dừng tại vị trí cuối; bấm Tiếp tục khi sẵn sàng.")
            return
        }
        var candidate = progress
        candidate.advance(seconds: elapsed, speed: speedMetersPerSecond, totalDistance: path.totalDistance, stops: dwells, stopAtArrival: true)
        guard let point = path.coordinate(at: candidate.distance) else { return }
        let code = await send(point, pairing: PairingFileStore.prepareURL().path)
        guard generation == token, session.isCurrentRoute(id), state == .running else { return }
        guard code == 0 else { fail(code); return }
        progress = candidate
        session.updateCoordinate(point.clCoordinate)
        if candidate.distance >= path.totalDistance {
            state = .finished
            pausePending = false
            session.clearRoute()
            routeID = nil
            holdLastCoordinate()
            return
        }
        if candidate.dwellRemaining > 0 {
            restDeadline = clock() + candidate.dwellRemaining
            holdLastCoordinate()
        }
        if pausePending { completePause(reason: pendingPauseReason) }
    }

    private func fail(_ code: Int32) {
        state = .failed
        pausePending = false
        restDeadline = nil
        message = "Mô phỏng bị gián đoạn (mã \(code)). Kiểm tra kết nối trước khi chạy lại hoặc về GPS thật."
        session.clearRoute()
        routeID = nil
        holdLastCoordinate()
    }
    private func holdLastCoordinate() {
        guard let coordinate = session.coordinate else { return }
        let ip = DeviceConnectionContext.targetIPAddress
        let pairing = PairingFileStore.prepareURL().path
        let activeSession = session
        session.startResending(at: coordinate) { token in
            LocationSimulationCommandQueue.shared.async {
                guard activeSession.isCurrentResend(token) else { return }
                _ = simulate_location(ip, coordinate.latitude, coordinate.longitude, pairing)
            }
        }
    }
    private func send(_ coordinate: RouteCoordinate, pairing: String) async -> Int32 {
        let ip = DeviceConnectionContext.targetIPAddress
        return await command { simulate_location(ip, coordinate.latitude, coordinate.longitude, pairing) }
    }
    private func command(_ operation: @escaping () -> Int32) async -> Int32 {
        commandCount += 1
        isSending = commandCount > 0
        defer { commandCount -= 1; isSending = commandCount > 0 }
        return await withCheckedContinuation { continuation in
            LocationSimulationCommandQueue.shared.async { continuation.resume(returning: operation()) }
        }
    }
}
