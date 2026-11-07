// Device-only services replaced at the boundary. Production controller and session are compiled unchanged.
import Foundation

enum LocationSimulationCommandQueue {
    static let shared = DispatchQueue(label: "validation.location-device")
}
enum DeviceConnectionContext { static let targetIPAddress = "127.0.0.1" }
enum PairingFileStore {
    static func prepareURL() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("stikdebug-validation-pairing") }
}
final class BackgroundAudioManager {
    static let shared = BackgroundAudioManager()
    func requestStart() {}
    func requestStop() {}
}
final class BackgroundLocationManager {
    static let shared = BackgroundLocationManager()
    func requestStart() {}
    func requestStop() {}
}

final class FakeDevice: @unchecked Sendable {
    static let shared = FakeDevice()
    private let lock = NSLock()
    private var events: [String] = []
    private var nextCode: Int32 = 0
    private var clearCode: Int32 = 0
    private var gate: DispatchSemaphore?
    private var lastRequest: (point: RouteCoordinate, reconnect: Bool)?
    func reset() { lock.lock(); defer { lock.unlock() }; events = []; nextCode = 0; clearCode = 0; gate = nil; lastRequest = nil }
    func failNextSet(_ code: Int32) { lock.lock(); defer { lock.unlock() }; nextCode = code }
    func failClear(_ code: Int32) { lock.lock(); defer { lock.unlock() }; clearCode = code }
    func blockNextSet() -> DispatchSemaphore {
        lock.lock(); defer { lock.unlock() }
        let value = DispatchSemaphore(value: 0); gate = value; return value
    }
    var recorded: [String] { lock.lock(); defer { lock.unlock() }; return events }
    var lastSet: (point: RouteCoordinate, reconnect: Bool)? { lock.lock(); defer { lock.unlock() }; return lastRequest }
    func set(_ latitude: Double, _ longitude: Double, reconnect: Bool) -> Int32 {
        lock.lock()
        let result = nextCode; nextCode = 0
        let blocker = gate; gate = nil
        lastRequest = (RouteCoordinate(latitude: latitude, longitude: longitude), reconnect)
        events.append("set-start")
        lock.unlock()
        if let blocker { _ = blocker.wait(timeout: .now() + 5) }
        lock.lock(); events.append("set-done"); lock.unlock()
        return result
    }
    func clear() -> Int32 {
        lock.lock(); defer { lock.unlock() }
        events.append("clear"); return clearCode
    }
}
func simulate_location(_ ip: String, _ lat: Double, _ lon: Double, _ pairing: String, reconnect: Bool = true) -> Int32 {
    FakeDevice.shared.set(lat, lon, reconnect: reconnect)
}
func clear_simulated_location(_ ip: String, _ pairing: String) -> Int32 { FakeDevice.shared.clear() }
