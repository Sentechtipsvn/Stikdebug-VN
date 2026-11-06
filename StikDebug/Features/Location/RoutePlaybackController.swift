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
    @Published var speedMode: RouteSpeedMode = .fixed {
        didSet { route?.speedMode = speedMode }
    }

    private var path = RoutePath(coordinates: [])
    private var dwells: [RouteDwell] = []
    private var task: Task<Void, Never>?
    private var routeID: UUID?
    private var generation = UUID()
    private var lastUptime: TimeInterval = 0
    private let session = LocationSimulationSession.shared

    var isLocked: Bool { [.starting, .running, .paused, .stopping].contains(state) || isSending }
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
            var result = 0.0
            for i in speeds.indices {
                let remaining = path.cumulativeDistances[i + 1] - max(progress.distance, path.cumulativeDistances[i])
                if remaining > 0 { result += remaining / max(1, speeds[i]) }
            }
            travel = result
        } else {
            travel = max(0, path.totalDistance - progress.distance) / speedMetersPerSecond
        }
        return travel + progress.remainingDwell(stops: dwells)
    }

    func load(_ route: SavedSimulationRoute) throws {
        guard !isLocked else { return }
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
        state = .ready
        message = nil
    }

    func resetDraft() {
        guard !isLocked else { return }
        route = nil
        path = RoutePath(coordinates: [])
        progress = RouteProgress()
        dwells = []
        state = .ready
        message = nil
    }

    func updateRouteName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { route?.name = trimmed }
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
        task = Task { [weak self] in
            guard let self else { return }
            let code = await self.send(first, pairing: pairing)
            guard !Task.isCancelled, self.generation == token else { return }
            guard code == 0 else { self.fail(code); return }
            self.routeID = self.session.startRoute(at: first.clCoordinate, coordinates: route.coordinates.map(\.clCoordinate))
            self.state = .running
            self.lastUptime = ProcessInfo.processInfo.systemUptime
            await self.play(token: token, pairing: pairing)
        }
    }

    func pause(reason: String? = nil) {
        guard state == .running, !isSending else { return }
        task?.cancel()
        task = nil
        state = .paused
        message = reason
        holdLastCoordinate()
    }

    func resume() {
        guard state == .paused, !isSending, let id = routeID, session.isCurrentRoute(id) else { return }
        session.pauseResending()
        state = .running
        message = nil
        lastUptime = ProcessInfo.processInfo.systemUptime
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            await self.play(token: token, pairing: PairingFileStore.prepareURL().path)
        }
    }

    // External URL actions share the same serial command queue. Invalidate this producer first.
    @discardableResult
    func interruptForExternalAction() -> UUID {
        generation = UUID()
        task?.cancel()
        task = nil
        routeID = nil
        session.pauseResending()
        session.clearRoute()
        if route != nil { state = .ready }
        return generation
    }

    func isCurrentAction(_ token: UUID) -> Bool { generation == token }

    func stop() {
        guard state != .stopping, !isSending else { return }
        interruptForExternalAction()
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
                self.message = nil
            } else {
                self.state = .failed
                self.message = "Chưa xóa được vị trí mô phỏng (mã \(code)). Hãy kết nối lại và bấm Dừng lần nữa."
                self.holdLastCoordinate()
            }
        }
    }

    func simulatePin(_ coordinate: RouteCoordinate) async throws {
        guard !isLocked, coordinate.isValid else { return }
        let token = interruptForExternalAction()
        let code = await send(coordinate, pairing: PairingFileStore.prepareURL().path)
        guard generation == token else { return }
        guard code == 0 else { throw NSError(domain: "StikDebugVN", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "Không đặt được vị trí (mã \(code)). Kiểm tra VPN, ghép đôi và DDI."]) }
        session.start(at: coordinate.clCoordinate)
        holdLastCoordinate()
    }

    private func play(token: UUID, pairing: String) async {
        while !Task.isCancelled && generation == token && state == .running {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard !Task.isCancelled, generation == token, let id = routeID, session.isCurrentRoute(id) else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = now - lastUptime
            lastUptime = now
            if elapsed > 3 {
                pause(reason: "Ứng dụng vừa bị gián đoạn. Tuyến đã tạm dừng tại vị trí cuối; bấm Tiếp tục khi sẵn sàng.")
                return
            }
            var candidate = progress
            candidate.advance(seconds: elapsed, speed: speedMetersPerSecond, totalDistance: path.totalDistance, stops: dwells)
            guard let point = path.coordinate(at: candidate.distance) else { return }
            let code = await send(point, pairing: pairing)
            guard !Task.isCancelled, generation == token, session.isCurrentRoute(id), state == .running else { return }
            guard code == 0 else { fail(code); return }
            progress = candidate
            session.updateCoordinate(point.clCoordinate)
            if candidate.distance >= path.totalDistance {
                state = .finished
                session.clearRoute()
                routeID = nil
                holdLastCoordinate()
                return
            }
        }
    }

    private func fail(_ code: Int32) {
        state = .failed
        message = "Mô phỏng bị gián đoạn (mã \(code)). Kiểm tra kết nối trước khi chạy lại hoặc bấm Dừng."
        session.clearRoute()
        routeID = nil
        holdLastCoordinate()
    }

    private func holdLastCoordinate() {
        guard let coordinate = session.coordinate else { return }
        let ip = DeviceConnectionContext.targetIPAddress
        let pairing = PairingFileStore.prepareURL().path
        session.startResending(at: coordinate) { token in
            LocationSimulationCommandQueue.shared.async {
                guard LocationSimulationSession.shared.isCurrentResend(token) else { return }
                _ = simulate_location(ip, coordinate.latitude, coordinate.longitude, pairing)
            }
        }
    }

    private func send(_ coordinate: RouteCoordinate, pairing: String) async -> Int32 {
        let ip = DeviceConnectionContext.targetIPAddress
        return await command { simulate_location(ip, coordinate.latitude, coordinate.longitude, pairing) }
    }

    private func command(_ operation: @escaping () -> Int32) async -> Int32 {
        isSending = true
        let code: Int32 = await withCheckedContinuation { continuation in
            LocationSimulationCommandQueue.shared.async { continuation.resume(returning: operation()) }
        }
        isSending = false
        return code
    }
}
