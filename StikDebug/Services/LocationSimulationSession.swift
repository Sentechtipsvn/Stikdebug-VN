import Foundation
import CoreLocation
import Combine

final class LocationSimulationSession: ObservableObject {
    static let shared = LocationSimulationSession()

    @Published private(set) var isActive = false
    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var routeCoordinates: [CLLocationCoordinate2D]?
    private var resendTimer: Timer?
    private let resendGeneration = SimulationCommandToken()
    private var routeID: UUID?

    private init() {}

    func start(at coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
        if !isActive {
            isActive = true
            BackgroundAudioManager.shared.requestStart()
            BackgroundLocationManager.shared.requestStart()
        }
    }

    func startResending(at coordinate: CLLocationCoordinate2D, immediately: Bool = false, _ operation: @escaping (UUID) -> Void) {
        start(at: coordinate)
        pauseResending()
        let token = resendGeneration.begin()
        let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            guard self?.isCurrentResend(token) == true else { return }
            operation(token)
        }
        RunLoop.main.add(timer, forMode: .common)
        resendTimer = timer
        if immediately { operation(token) }
    }

    func startRoute(at coordinate: CLLocationCoordinate2D, coordinates: [CLLocationCoordinate2D]) -> UUID {
        pauseResending()
        let routeID = UUID()
        self.routeID = routeID
        routeCoordinates = coordinates
        start(at: coordinate)
        return routeID
    }

    func isCurrentRoute(_ routeID: UUID) -> Bool {
        self.routeID == routeID
    }

    func clearRoute() {
        routeID = nil
        routeCoordinates = nil
    }

    func pauseResending() {
        resendGeneration.invalidate()
        resendTimer?.invalidate()
        resendTimer = nil
    }

    func isCurrentResend(_ token: UUID) -> Bool { resendGeneration.isCurrent(token) }

    func updateCoordinate(_ coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
    }

    func stop() {
        pauseResending()
        clearRoute()
        guard isActive else { return }
        isActive = false
        coordinate = nil
        BackgroundAudioManager.shared.requestStop()
        BackgroundLocationManager.shared.requestStop()
    }
}

