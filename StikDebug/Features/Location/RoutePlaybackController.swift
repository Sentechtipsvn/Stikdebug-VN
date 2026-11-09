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
    fileprivate let generation: UUID
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
    @Published private(set) var pausePending = false
    @Published private(set) var previousRoute: SavedSimulationRoute?
    @Published private(set) var probeDistance: Double?
    @Published private(set) var holdUnconfirmed = false
    @Published private(set) var lastConfirmedAt: Date?
    @Published var speedKmh: Double = 30 {
        didSet { if speedKmh.isFinite { route?.speedKmh = min(300, max(1, speedKmh)) } }
    }
    @Published var speedMode: RouteSpeedMode = .fixed { didSet { route?.speedMode = speedMode } }

    private var path = RoutePath(coordinates: [])
    private var visualStep: RouteVisualStep?
    private var dwells: [RouteDwell] = []
    private var task: Task<Void, Never>?
    private var routeID: UUID?
    private var generation = UUID()
    private var lastUptime: TimeInterval = 0
    private var restDeadline: TimeInterval?
    private var initialRestName: String?
    private var pendingPauseReason: String?
    private var needsRouteReconnect = false
    private var commandCount = 0
    private let session: LocationSimulationSession
    private let clock: () -> TimeInterval
    private let automaticTicks: Bool
    private let commandFeedbackDelay: Duration

    init(clock: @escaping () -> TimeInterval = { RouteSteadyClock.seconds() }, automaticTicks: Bool = true, session: LocationSimulationSession = .shared, commandFeedbackDelay: Duration = .seconds(3)) {
        self.clock = clock
        self.automaticTicks = automaticTicks
        self.session = session
        self.commandFeedbackDelay = commandFeedbackDelay
    }

    var isLocked: Bool { [.starting, .running, .paused, .stopping].contains(state) || isSending }
    var needsLocationRestore: Bool { session.isActive || isLocked || state == .failed }
    var hasActiveRoute: Bool { [.running, .paused].contains(state) && route != nil }
    var canContinueFromBot: Bool { hasActiveRoute || (state == .finished && session.isActive) }
    var simulatedRouteOrigin: RouteWaypoint? {
        guard canContinueFromBot, let coordinate = session.coordinate else { return nil }
        return .init(name: "Vị trí đang mô phỏng", coordinate: RouteCoordinate(coordinate), source: "simulated")
    }
    var isResting: Bool { progress.dwellRemaining > 0 && [.running, .paused].contains(state) }
    var canResumeInterruptedRoute: Bool { state == .failed && needsRouteReconnect && route != nil && session.coordinate != nil }
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
        if holdUnconfirmed { return "Chưa xác nhận giữ vị trí" }
        if pausePending { return "Đang tạm dừng…" }
        if isHoldingProbe { return "Đã tới mốc dò — đang giữ vị trí" }
        if state == .finished { return "Đã đến — đang giữ vị trí" }
        if phase == .resting { return "Đang nghỉ tại \(restName ?? "trạm")" }
        return phase.title
    }
    var displaySpeedKmh: Double? {
        if pausePending || holdUnconfirmed { return nil }
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
    var isHoldingProbe: Bool {
        guard state == .paused, let probeDistance else { return false }
        return progress.distance >= probeDistance
    }
    var probeCoordinate: RouteCoordinate? { probeDistance.flatMap { path.coordinate(at: $0) } }
    var animatesRouteMarker: Bool { state == .running && !isResting && !pausePending && visualStep != nil }

    func visualPose(interpolate: Bool) -> (coordinate: RouteCoordinate, bearing: Double?)? {
        guard let coordinate = session.coordinate else { return nil }
        let confirmed = RouteCoordinate(coordinate)
        guard routeID != nil || state == .finished || canResumeInterruptedRoute else { return (confirmed, nil) }
        if interpolate, animatesRouteMarker, let visualStep {
            let distance = visualStep.distance(at: clock())
            if let point = path.coordinate(at: distance) { return (point, path.bearing(at: distance)) }
        }
        return (confirmed, path.bearing(at: progress.distance))
    }

    func setProbe(at distance: Double) throws {
        guard !isSending, state != .starting, state != .stopping else { throw LocationWorkflowError.busy }
        guard distance.isFinite, distance > 0, distance <= totalDistance else { throw LocationWorkflowError.probeOutsideRoute }
        if state != .finished && distance <= progress.distance { throw LocationWorkflowError.probeAlreadyPassed }
        probeDistance = distance
    }

    func setProbe(near coordinate: RouteCoordinate) throws {
        guard let distance = path.nearestDistance(to: coordinate, within: 100) else { throw LocationWorkflowError.probeOutsideRoute }
        try setProbe(at: distance)
    }

    func clearProbe() { probeDistance = nil }
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
        visualStep = nil
        var points: [RouteCoordinate] = []
        dwells = []
        for (index, leg) in validated.legs.enumerated() {
            for point in leg.coordinates where points.last != point { points.append(point) }
            if index < validated.legs.count - 1 {
                dwells.append(.init(distance: RoutePath(coordinates: points).totalDistance, seconds: validated.waypoints[index + 1].dwellSeconds))
            }
        }
        progress = RouteProgress()
        probeDistance = nil
        restDeadline = nil
        initialRestName = nil
        pausePending = false
        needsRouteReconnect = false
        state = .ready
        message = nil
    }

    func resetDraft() {
        guard !isLocked else { return }
        route = nil
        path = RoutePath(coordinates: [])
        visualStep = nil
        progress = RouteProgress()
        probeDistance = nil
        dwells = []
        restDeadline = nil
        initialRestName = nil
        needsRouteReconnect = false
        state = .ready
        message = nil
    }

    func updateRouteName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { route?.name = trimmed }
    }

    func remainingDraft() -> LocationRouteDraft {
        guard let route, hasActiveRoute, let origin = simulatedRouteOrigin else { return LocationRouteDraft() }
        var result = LocationRouteDraft(route: route)
        result.originIsAutomatic = true
        result.rows = [.init(point: origin)]
        result.rows += route.waypoints.dropFirst(progress.nextStop + 1).map { .init(point: $0, dwell: $0.dwellSeconds) }
        if result.rows.count < 2 { result.rows.append(.init()) }
        return result
    }

    func pauseForEditing() async throws -> RouteEditAnchor? {
        guard canContinueFromBot else {
            if isLocked { throw LocationWorkflowError.busy }
            return nil
        }
        let editGeneration = generation
        if state == .running { pause(reason: "Đã tạm dừng để áp dụng tuyến sửa. Bấm Tiếp tục khi sẵn sàng.") }
        while generation == editGeneration && (isSending || pausePending) {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(30))
        }
        try Task.checkCancellation()
        guard generation == editGeneration, [.paused, .finished].contains(state),
              !holdUnconfirmed, let origin = simulatedRouteOrigin, let route else {
            throw LocationWorkflowError.simulationOriginUnavailable
        }
        let completed = Set(route.waypoints.dropFirst().prefix(progress.nextStop).map(\.id))
        return .init(generation: editGeneration, coordinate: origin.coordinate, remainingRest: progress.dwellRemaining,
                     restName: restName, completedIDs: completed)
    }

    func installDraft(_ route: SavedSimulationRoute, anchor: RouteEditAnchor?, keepPrevious: Bool = false) async throws {
        let route = try route.validated()
        if let anchor {
            while generation == anchor.generation && isSending {
                try await Task.sleep(for: .milliseconds(30))
            }
            try Task.checkCancellation()
            guard generation == anchor.generation, [.paused, .finished].contains(state),
                  !holdUnconfirmed, simulatedRouteOrigin?.coordinate == anchor.coordinate else {
                throw LocationWorkflowError.simulationOriginUnavailable
            }
            let oldRoute = self.route
            _ = interruptForExternalAction()
            try configure(route)
            progress.setDwellRemaining(anchor.remainingRest)
            initialRestName = anchor.restName
            routeID = session.startRoute(at: anchor.coordinate.clCoordinate, coordinates: route.coordinates.map(\.clCoordinate))
            if keepPrevious { previousRoute = oldRoute }
            state = .paused
            holdLastCoordinate()
        } else { try load(route) }
    }

    func restoreDeviceLocation() async throws -> Date {
        guard needsLocationRestore else { return Date() }
        if state != .stopping { stop() }
        let token = generation
        await task?.value
        try Task.checkCancellation()
        guard generation == token, !session.isActive, state == .ready else {
            throw LocationWorkflowError.gpsNotRestored
        }
        return Date()
    }

    func replaceRoute(with candidate: SavedSimulationRoute) async throws {
        let validated = try candidate.validated()
        let oldRoute = route
        _ = try await restoreDeviceLocation()
        try Task.checkCancellation()
        try load(validated)
        previousRoute = oldRoute
    }

    func start() {
        guard !isLocked, let route, let first = route.coordinates.first else { return }
        beginPlayback(at: first, route: route, resetProgress: true)
    }

    private func beginPlayback(at coordinate: RouteCoordinate, route: SavedSimulationRoute, resetProgress: Bool) {
        let pairing = PairingFileStore.prepareURL().path
        guard FileManager.default.fileExists(atPath: pairing) else { message = "Hãy nhập tệp ghép đôi trước khi mô phỏng."; return }
        generation = UUID()
        let token = generation
        task?.cancel()
        session.pauseResending()
        state = .starting
        message = nil
        if resetProgress {
            progress = RouteProgress()
            restDeadline = nil
            initialRestName = nil
            needsRouteReconnect = false
        }
        task = Task { [weak self] in
            guard let self else { return }
            let code = await self.send(coordinate, pairing: pairing)
            guard !Task.isCancelled, self.generation == token else { return }
            guard code == 0 else { self.fail(code); return }
            self.routeID = self.session.startRoute(at: coordinate.clCoordinate, coordinates: route.coordinates.map(\.clCoordinate))
            self.needsRouteReconnect = false
            self.runFromCurrentProgress()
        }
    }

    func pause(reason: String? = nil) {
        guard state == .running, !pausePending else { return }
        if isSending {
            pausePending = true
            pendingPauseReason = reason
            return
        }
        completePause(reason: reason)
    }

    private func completePause(reason: String?, resending: Bool = true) {
        if let deadline = restDeadline { progress.setDwellRemaining(max(0, deadline - clock())) }
        restDeadline = nil
        pausePending = false
        pendingPauseReason = nil
        task?.cancel()
        task = nil
        state = .paused
        message = reason
        if resending { holdLastCoordinate() }
    }

    func resume() {
        guard !isSending, !holdUnconfirmed else { return }
        if canResumeInterruptedRoute, let route, let coordinate = session.coordinate {
            beginPlayback(at: RouteCoordinate(coordinate), route: route, resetProgress: false)
            return
        }
        guard state == .paused, let id = routeID, session.isCurrentRoute(id) else { return }
        if isHoldingProbe { clearProbe() }
        runFromCurrentProgress()
    }

    private func runFromCurrentProgress() {
        visualStep = nil
        state = .running
        message = nil
        lastUptime = clock()
        if progress.dwellRemaining > 0 {
            restDeadline = lastUptime + progress.dwellRemaining
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
        visualStep = nil
        task?.cancel()
        task = nil
        routeID = nil
        restDeadline = nil
        pausePending = false
        needsRouteReconnect = false
        holdUnconfirmed = false
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
        message = nil
        let token = generation
        let ip = DeviceConnectionContext.targetIPAddress
        let pairing = PairingFileStore.prepareURL().path
        task = Task { [weak self] in
            guard let self else { return }
            let code = await self.command { clear_simulated_location(ip, pairing) }
            guard self.generation == token else { return }
            if code == 0 {
                self.session.stop()
                self.state = .ready
                self.progress = RouteProgress()
                self.probeDistance = nil
                self.lastConfirmedAt = nil
                self.message = "Đã tắt mô phỏng."
            } else {
                self.state = .failed
                self.message = "Chưa tắt được mô phỏng (mã \(code)). Kiểm tra kết nối và thử lại."
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
        candidate.advance(seconds: elapsed, speed: speedMetersPerSecond, totalDistance: probeDistance ?? path.totalDistance,
                          stops: dwells, stopAtArrival: true)
        guard let point = path.coordinate(at: candidate.distance) else { return }
        let code = await send(point, pairing: PairingFileStore.prepareURL().path, reconnect: false)
        guard generation == token, session.isCurrentRoute(id), state == .running else { return }
        guard code == 0 else { fail(code); return }
        visualStep = .init(fromDistance: progress.distance, toDistance: candidate.distance, confirmedAt: clock())
        progress = candidate
        session.updateCoordinate(point.clCoordinate)
        if candidate.distance >= path.totalDistance {
            state = .finished
            pausePending = false
            message = nil
            session.clearRoute()
            routeID = nil
            holdLastCoordinate()
            return
        }
        if candidate.dwellRemaining > 0 {
            restDeadline = clock() + candidate.dwellRemaining
        }
        if let probeDistance, candidate.distance >= probeDistance {
            completePause(reason: "Đã tới mốc dò. Bấm Tiếp tục khi muốn đi tiếp.")
        } else if pausePending {
            completePause(reason: pendingPauseReason)
        } else if candidate.dwellRemaining > 0 {
            holdLastCoordinate()
        }
    }

    private func fail(_ code: Int32) {
        needsRouteReconnect = needsRouteReconnect || routeID != nil
        state = .failed
        pausePending = false
        restDeadline = nil
        message = "Mô phỏng bị gián đoạn (mã \(code)). Kiểm tra kết nối thiết bị rồi thử lại."
        session.pauseResending()
        session.clearRoute()
        routeID = nil
    }
    func refreshHeldCoordinate() {
        guard !isSending, state == .paused || state == .ready || state == .finished || isResting else { return }
        holdLastCoordinate(immediately: true)
    }

    private func holdLastCoordinate(immediately: Bool = false) {
        guard let coordinate = session.coordinate else { return }
        session.startResending(at: coordinate, immediately: immediately) { [weak self] token in
            Task { @MainActor [weak self] in
                await self?.resendHeldCoordinate(RouteCoordinate(coordinate), token: token)
            }
        }
    }

    private func resendHeldCoordinate(_ coordinate: RouteCoordinate, token: UUID) async {
        guard !isSending, session.isCurrentResend(token) else { return }
        let previousMessage = message
        let retrying = holdUnconfirmed
        let code = await send(coordinate, pairing: PairingFileStore.prepareURL().path, reconnect: retrying, resendToken: token)
        guard session.isCurrentResend(token) else { return }
        if code != 0 {
            session.pauseResending()
            let failure = "Chưa giữ được tọa độ (mã \(code)). Nối lại VPN rồi bấm Thử giữ lại."
            if state == .running { completePause(reason: failure, resending: false) }
            holdUnconfirmed = true
            message = failure
        } else {
            holdUnconfirmed = false
            if pausePending { completePause(reason: pendingPauseReason) }
            else { message = retrying ? "Thiết bị đã xác nhận giữ vị trí." : previousMessage }
        }
    }

    private func send(_ coordinate: RouteCoordinate, pairing: String, reconnect: Bool = true, resendToken: UUID? = nil) async -> Int32 {
        let ip = DeviceConnectionContext.targetIPAddress
        let token = generation
        let activeSession = session
        let code = await command {
            if let resendToken, !activeSession.isCurrentResend(resendToken) { return 0 }
            return simulate_location(ip, coordinate.latitude, coordinate.longitude, pairing, reconnect: reconnect)
        }
        if code == 0, generation == token, resendToken.map(activeSession.isCurrentResend) != false {
            lastConfirmedAt = Date()
        }
        return code
    }
    private func command(_ operation: @escaping () -> Int32) async -> Int32 {
        commandCount += 1
        isSending = commandCount > 0
        let token = generation
        let feedback = Task { [weak self, commandFeedbackDelay] in
            do { try await Task.sleep(for: commandFeedbackDelay) } catch { return }
            guard let self, !Task.isCancelled, self.generation == token else { return }
            if self.state == .running {
                self.pause(reason: "Tuyến đã tạm dừng sau khi thiết bị phản hồi chậm.")
            }
            self.message = "Thiết bị chưa phản hồi. Kiểm tra kết nối thiết bị."
        }
        defer {
            feedback.cancel()
            commandCount -= 1
            isSending = commandCount > 0
        }
        return await withCheckedContinuation { continuation in
            LocationSimulationCommandQueue.shared.async { continuation.resume(returning: operation()) }
        }
    }
}
