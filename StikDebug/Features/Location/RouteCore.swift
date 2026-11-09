import Foundation

// A queued resend must re-check its token when it actually reaches the device queue.
final class SimulationCommandToken: @unchecked Sendable {
    private let lock = NSLock()
    private var current: UUID?

    func begin() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let token = UUID()
        current = token
        return token
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        current = nil
    }

    func isCurrent(_ token: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return current == token
    }
}

struct RouteCoordinate: Codable, Equatable, Sendable {
    var latitude: Double
    var longitude: Double

    var isValid: Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    func distance(to other: Self) -> Double {
        let radians = Double.pi / 180
        let a = latitude * radians
        let b = other.latitude * radians
        let dLat = (other.latitude - latitude) * radians
        let dLon = (other.longitude - longitude) * radians
        let h = pow(sin(dLat / 2), 2) + cos(a) * cos(b) * pow(sin(dLon / 2), 2)
        return 6_371_008.8 * 2 * asin(sqrt(min(1, max(0, h))))
    }

    func interpolated(to other: Self, fraction: Double) -> Self {
        let t = min(1, max(0, fraction))
        var delta = other.longitude - longitude
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        var lon = longitude + delta * t
        if lon > 180 { lon -= 360 }
        if lon < -180 { lon += 360 }
        return Self(latitude: latitude + (other.latitude - latitude) * t, longitude: lon)
    }
}

struct RouteWaypoint: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var coordinate: RouteCoordinate
    var dwellSeconds: Double = 0
    var source: String = "manual"
}

enum RouteSpeedMode: String, Codable, CaseIterable, Sendable {
    case fixed
    case road
}

enum RouteVehicle: String, Codable, Sendable {
    case car
    case motorcycle
}

struct RouteLegData: Codable, Equatable, Sendable {
    var coordinates: [RouteCoordinate]
    var expectedTravelTime: Double
}

struct SavedSimulationRoute: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var updatedAt = Date()
    var waypoints: [RouteWaypoint]
    var legs: [RouteLegData]
    var speedKmh: Double = 30
    var speedMode: RouteSpeedMode = .fixed
    var roadSpeeds: [Double] = []
    var vehicle: RouteVehicle? = nil

    var coordinates: [RouteCoordinate] {
        legs.reduce(into: []) { result, leg in
            for point in leg.coordinates where result.last != point { result.append(point) }
        }
    }

    func validated() throws -> Self {
        guard (2...100).contains(waypoints.count), Set(waypoints.map(\.id)).count == waypoints.count, legs.count == waypoints.count - 1,
              speedKmh.isFinite, (1...300).contains(speedKmh), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              waypoints.allSatisfy({ $0.coordinate.isValid && $0.dwellSeconds.isFinite && (0...86400).contains($0.dwellSeconds) }),
              legs.allSatisfy({ $0.coordinates.count >= 2 && $0.coordinates.allSatisfy(\.isValid) && $0.expectedTravelTime.isFinite && $0.expectedTravelTime >= 0 }),
              legs.reduce(0, { $0 + $1.coordinates.count }) <= 100_000,
              roadSpeeds.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 150 }) else {
            throw RouteDataError.invalid
        }
        let path = RoutePath(coordinates: coordinates)
        guard path.totalDistance > 0 else { throw RouteDataError.invalid }
        if !roadSpeeds.isEmpty && roadSpeeds.count != max(0, path.coordinates.count - 1) { throw RouteDataError.invalid }
        for (index, leg) in legs.enumerated() {
            guard let first = leg.coordinates.first, let last = leg.coordinates.last,
                  first.distance(to: waypoints[index].coordinate) < 300,
                  last.distance(to: waypoints[index + 1].coordinate) < 300 else { throw RouteDataError.invalid }
        }
        return self
    }
}

enum RouteDataError: LocalizedError {
    case invalid
    case unsupportedVersion
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .invalid: return "Dữ liệu tuyến không hợp lệ hoặc không khớp các điểm đã chọn."
        case .unsupportedVersion: return "Tệp tuyến dùng phiên bản dữ liệu chưa được hỗ trợ."
        case .tooLarge: return "Tệp quá lớn. Vui lòng chọn tệp dưới 20 MB."
        }
    }
}

struct RoutePath: Sendable {
    let coordinates: [RouteCoordinate]
    let cumulativeDistances: [Double]
    var totalDistance: Double { cumulativeDistances.last ?? 0 }

    init(coordinates: [RouteCoordinate]) {
        var clean: [RouteCoordinate] = []
        for point in coordinates where point.isValid && clean.last != point { clean.append(point) }
        self.coordinates = clean
        var cumulative = [Double]()
        for (index, point) in clean.enumerated() {
            cumulative.append(index == 0 ? 0 : cumulative[index - 1] + clean[index - 1].distance(to: point))
        }
        cumulativeDistances = cumulative
    }

    func segmentIndex(at distance: Double) -> Int {
        guard coordinates.count > 1 else { return 0 }
        var low = 0
        var high = cumulativeDistances.count - 1
        while low + 1 < high {
            let mid = (low + high) / 2
            if cumulativeDistances[mid] <= distance { low = mid } else { high = mid }
        }
        return min(coordinates.count - 2, low)
    }

    func coordinate(at distance: Double) -> RouteCoordinate? {
        guard let first = coordinates.first else { return nil }
        if distance <= 0 { return first }
        if distance >= totalDistance { return coordinates.last }
        let i = segmentIndex(at: distance)
        let length = cumulativeDistances[i + 1] - cumulativeDistances[i]
        return coordinates[i].interpolated(to: coordinates[i + 1], fraction: length > 0 ? (distance - cumulativeDistances[i]) / length : 0)
    }

    func bearing(at distance: Double) -> Double? {
        guard let start = coordinate(at: distance - 3), let end = coordinate(at: distance + 3), start != end else { return nil }
        let radians = Double.pi / 180
        let a = start.latitude * radians
        let b = end.latitude * radians
        let delta = (end.longitude - start.longitude) * radians
        let east = sin(delta) * cos(b)
        let north = cos(a) * sin(b) - sin(a) * cos(b) * cos(delta)
        return atan2(east, north) / radians
    }

    func nearestDistance(to coordinate: RouteCoordinate, within tolerance: Double) -> Double? {
        guard coordinates.count >= 2, coordinate.isValid else { return nil }
        let longitudeScale = cos(coordinate.latitude * .pi / 180)
        var bestError = tolerance
        var bestDistance: Double?
        for index in 0..<(coordinates.count - 1) {
            let a = coordinates[index]
            let b = coordinates[index + 1]
            let east = longitudeOffset(from: a.longitude, to: b.longitude) * longitudeScale
            let north = b.latitude - a.latitude
            let lengthSquared = east * east + north * north
            guard lengthSquared > 0 else { continue }
            let offsetEast = longitudeOffset(from: a.longitude, to: coordinate.longitude) * longitudeScale
            let offsetNorth = coordinate.latitude - a.latitude
            let fraction = min(1, max(0, (offsetEast * east + offsetNorth * north) / lengthSquared))
            let error = a.interpolated(to: b, fraction: fraction).distance(to: coordinate)
            if error <= bestError {
                bestError = error
                bestDistance = cumulativeDistances[index] + fraction * (cumulativeDistances[index + 1] - cumulativeDistances[index])
            }
        }
        return bestDistance
    }

    private func longitudeOffset(from origin: Double, to longitude: Double) -> Double {
        let offset = longitude - origin
        if offset > 180 { return offset - 360 }
        if offset < -180 { return offset + 360 }
        return offset
    }
}

struct RouteVisualStep {
    let fromDistance: Double
    let toDistance: Double
    let confirmedAt: TimeInterval

    func distance(at now: TimeInterval) -> Double {
        let fraction = min(1, max(0, (now - confirmedAt) / 0.5))
        return fromDistance + (toDistance - fromDistance) * fraction
    }
}

struct RouteDwell: Equatable, Sendable {
    var distance: Double
    var seconds: Double
}

struct RouteProgress: Sendable {
    private(set) var distance: Double = 0
    private(set) var nextStop = 0
    private(set) var dwellRemaining: Double = 0

    mutating func setDwellRemaining(_ seconds: Double) {
        dwellRemaining = seconds.isFinite ? max(0, seconds) : 0
    }

    mutating func advance(seconds: Double, speed: Double, totalDistance: Double, stops: [RouteDwell], stopAtArrival: Bool = false) {
        guard seconds.isFinite, speed.isFinite, seconds > 0, speed > 0 else { return }
        var time = seconds
        while time > 0 {
            if dwellRemaining > 0 {
                let consumed = min(time, dwellRemaining)
                dwellRemaining -= consumed
                time -= consumed
                if time <= 0 { break }
            }
            if nextStop < stops.count, stops[nextStop].distance <= totalDistance {
                let stop = stops[nextStop]
                let travelTime = max(0, stop.distance - distance) / speed
                if travelTime <= time {
                    distance = min(totalDistance, max(distance, stop.distance))
                    time -= travelTime
                    dwellRemaining = max(0, stop.seconds)
                    nextStop += 1
                    if stopAtArrival && dwellRemaining > 0 { return }
                    continue
                }
            }
            distance = min(totalDistance, distance + time * speed)
            time = 0
        }
    }

    func remainingDwell(stops: [RouteDwell]) -> Double {
        dwellRemaining + stops.dropFirst(nextStop).reduce(0) { $0 + max(0, $1.seconds) }
    }
}
