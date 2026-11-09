import Foundation
import CoreLocation
import Combine

@MainActor
final class CurrentLocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var result: RouteWaypoint?
    @Published private(set) var error: String?
    @Published private(set) var isLoading = false
    private(set) var horizontalAccuracy: CLLocationAccuracy?
    private let manager = CLLocationManager()
    private var timeout: Task<Void, Never>?
    private var requestedAt = Date()
    private var freshAfter: Date?
    var requestedFreshLocation: Bool { freshAfter != nil }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func request(freshAfter: Date? = nil) {
        cancel()
        result = nil
        horizontalAccuracy = nil
        error = nil
        self.freshAfter = freshAfter
        requestedAt = Date()
        isLoading = true
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard let self else { return }
            self.finish(error: "Chưa lấy được vị trí mới. Sếp thử ra nơi thoáng hoặc chọn từ Dấu trang/bản đồ.")
        }
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse: startReading()
        default: finish(error: "Chưa được cấp quyền vị trí. Hãy bật quyền cho StikDebug VN trong Cài đặt.")
        }
    }

    func cancel() {
        timeout?.cancel()
        timeout = nil
        manager.stopUpdatingLocation()
        isLoading = false
    }

    private func finish(error: String?) {
        cancel()
        self.error = error
    }

    private func startReading() {
        if freshAfter != nil { manager.startUpdatingLocation() }
        else { manager.requestLocation() }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self, self.isLoading else { return }
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse: self.startReading()
            case .denied, .restricted: self.finish(error: "Quyền vị trí bị từ chối. Sếp có thể chọn vị trí bằng link, Dấu trang hoặc bản đồ.")
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak self] in
            guard let self, self.isLoading, let location = locations.last else { return }
            let simulated = location.sourceInformation?.isSimulatedBySoftware == true || LocationSimulationSession.shared.isActive
            let oldest = self.freshAfter ?? self.requestedAt.addingTimeInterval(-5)
            let maxAccuracy = self.freshAfter == nil ? 300.0 : 50.0
            guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= maxAccuracy, location.timestamp >= oldest,
                  self.freshAfter == nil || !simulated else {
                if self.freshAfter == nil { manager.requestLocation() }
                return
            }
            self.horizontalAccuracy = location.horizontalAccuracy
            self.result = RouteWaypoint(name: simulated ? "Vị trí thiết bị (đang mô phỏng)" : "Vị trí thiết bị", coordinate: RouteCoordinate(location.coordinate), source: simulated ? "simulated" : "device")
            self.finish(error: nil)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.isLoading else { return }
            if let error = error as? CLError, error.code == .locationUnknown {
                if self.freshAfter == nil { manager.requestLocation() }
                return
            }
            self.finish(error: error.localizedDescription)
        }
    }
}
