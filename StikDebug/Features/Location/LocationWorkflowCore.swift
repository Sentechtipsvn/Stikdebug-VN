import Foundation

enum RestDurationUnit: String, Codable, CaseIterable {
    case seconds, minutes, hours
    var multiplier: Double { self == .hours ? 3600 : self == .minutes ? 60 : 1 }
    var title: String { self == .hours ? "Giờ" : self == .minutes ? "Phút" : "Giây" }
}

enum RestDuration {
    static let maximum = 86_400.0
    static func parse(_ text: String, unit: RestDurationUnit) throws -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 32,
              trimmed.range(of: #"^\d+(?:[.,]\d+)?$"#, options: .regularExpression) != nil,
              let value = Double(trimmed.replacingOccurrences(of: ",", with: ".")), value.isFinite,
              value * unit.multiplier <= maximum else {
            throw NSError(domain: "StikDebugVN.Duration", code: 1, userInfo: [NSLocalizedDescriptionKey: "Nhập số từ 0 giây đến 24 giờ. Có thể dùng dấu phẩy hoặc dấu chấm cho phần thập phân."])
        }
        return (value * unit.multiplier).rounded()
    }

    static func clock(_ seconds: Double) -> String {
        let safe = seconds.isFinite ? min(maximum, max(0, seconds)) : 0
        let value = Int(ceil(safe))
        if value >= 3600 { return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) }
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    static func initialEntry(seconds: Double) -> (String, RestDurationUnit) {
        if seconds > 0 && seconds.truncatingRemainder(dividingBy: 3600) == 0 { return (String(Int(seconds / 3600)), .hours) }
        if seconds.truncatingRemainder(dividingBy: 60) == 0 { return (String(Int(seconds / 60)), .minutes) }
        return (String(Int(seconds)), .seconds)
    }
}

enum SimulationDisplayPhase: String {
    case inactive, ready, starting, moving, resting, paused, holding, stopping, failed
    var title: String {
        switch self {
        case .inactive: return "Chưa mô phỏng"
        case .ready: return "Tuyến đã sẵn sàng"
        case .starting: return "Đang bắt đầu…"
        case .moving: return "Đang di chuyển"
        case .resting: return "Đang nghỉ tại trạm"
        case .paused: return "Đã tạm dừng"
        case .holding: return "Đang giữ vị trí"
        case .stopping: return "Đang tắt mô phỏng…"
        case .failed: return "Mô phỏng bị gián đoạn"
        }
    }
    var showsZeroSpeed: Bool { [.paused, .resting, .holding, .inactive, .ready].contains(self) }
}

struct RouteDraftRow: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var point: RouteWaypoint?
    var dwell: Double = 0
}

enum RouteDraftReplacement: String, Codable, Sendable {
    case newRoute, detour
}

struct LocationRouteDraft: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var rows: [RouteDraftRow] = [.init(), .init()]
    var speedKmh: Double = 30
    var mode: RouteSpeedMode = .fixed
    var vehicle: RouteVehicle? = nil
    var basedOnRouteID: UUID?
    var dirty = false
    var originIsAutomatic = true
    var replacement: RouteDraftReplacement? = nil

    init() {}
    init(route: SavedSimulationRoute) {
        rows = route.waypoints.map { .init(point: $0, dwell: $0.dwellSeconds) }
        speedKmh = route.speedKmh
        mode = route.speedMode
        vehicle = route.vehicle ?? .car
        basedOnRouteID = route.id
        originIsAutomatic = false
    }

    init(replacement: RouteDraftReplacement, from route: SavedSimulationRoute?) {
        if let route { self.init(route: route) } else { self.init() }
        self.replacement = replacement
        rows = [.init(), .init(point: replacement == .detour ? route?.waypoints.last : nil)]
        dirty = true
        originIsAutomatic = false
    }

    var hasDestination: Bool { rows.count >= 2 && rows.last?.point != nil }

    var anchorsDetourToBot: Bool { replacement == .detour && originIsAutomatic }

    func replacesRouteFromSelectedOrigin(whileContinuingRoute: Bool) -> Bool {
        replacement == .newRoute || (!originIsAutomatic && (replacement == .detour || whileContinuingRoute))
    }

    var points: [RouteWaypoint]? {
        guard rows.count >= 2, rows.allSatisfy({ $0.point != nil }) else { return nil }
        return rows.map { row in var point = row.point!; point.dwellSeconds = row.dwell; return point }
    }
    mutating func setDestination(_ point: RouteWaypoint) {
        if rows.count < 2 { rows = [.init(), .init()] }
        rows[rows.count - 1].point = point
        dirty = true
    }
    mutating func addStop(_ point: RouteWaypoint) throws {
        guard hasDestination else { throw LocationWorkflowError.noDestination }
        guard rows.count < 100 else { throw RouteDataError.invalid }
        rows.insert(.init(point: point, dwell: point.dwellSeconds), at: rows.count - 1)
        dirty = true
    }

    func rebased(at coordinate: RouteCoordinate, completedIDs: Set<UUID>) throws -> [RouteWaypoint] {
        guard var selected = points else { throw RouteDataError.invalid }
        selected[0] = .init(name: "Vị trí đang mô phỏng", coordinate: coordinate, source: "simulated")
        let lastIndex = selected.count - 1
        selected = selected.enumerated().filter { index, point in index == 0 || index == lastIndex || !completedIDs.contains(point.id) }.map(\.element)
        guard selected.count >= 2 else { throw RouteDataError.invalid }
        return selected
    }
}

enum LocationWorkflowError: LocalizedError {
    case noDestination
    case invalidRequest
    case busy
    case simulationOriginUnavailable
    case gpsNotRestored
    case probeOutsideRoute
    case probeAlreadyPassed
    var errorDescription: String? {
        switch self {
        case .noDestination: return "Hãy chọn điểm đến trước khi thêm điểm dừng."
        case .invalidRequest: return "Yêu cầu vị trí không hợp lệ. Hãy chia sẻ một địa điểm hoặc mở phím tắt không có đầu vào để tạo tuyến."
        case .busy: return "Đang xử lý lệnh vị trí. Vui lòng chờ một chút rồi thử lại."
        case .simulationOriginUnavailable: return "Chưa xác nhận được vị trí bot. Hãy kết nối lại hoặc chọn điểm đi khác."
        case .gpsNotRestored: return "Thiết bị chưa xác nhận đã tắt mô phỏng. Kiểm tra kết nối rồi thử lại."
        case .probeOutsideRoute: return "Mốc nằm ngoài tuyến. Hãy chọn một vị trí trên phần đường màu xanh."
        case .probeAlreadyPassed: return "Bot đã đi qua mốc này. Hãy chọn mốc phía trước."
        }
    }
}

struct LocationReceiveRequest: Identifiable, Equatable {
    let id: UUID
    let input: String?
    let isCompose: Bool
    let point: RouteWaypoint?

    private init(input: String? = nil, isCompose: Bool = false, point: RouteWaypoint? = nil) {
        id = UUID()
        self.input = input
        self.isCompose = isCompose
        self.point = point
    }

    init(shortcutCoordinate: RouteCoordinate) {
        self.init(input: "\(shortcutCoordinate.latitude),\(shortcutCoordinate.longitude)",
                  point: .init(name: "Tọa độ được chia sẻ", coordinate: shortcutCoordinate, source: "shortcut"))
    }

    private static func endpoint(_ url: URL) -> URLComponents? {
        guard url.scheme?.lowercased() == "stikdebugvn", url.user == nil, url.password == nil, url.port == nil, (url.path.isEmpty || url.path == "/"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(), ["receive-location", "create-route"].contains(host) else { return nil }
        return components
    }

    static func recovery(for url: URL) -> Self? {
        guard endpoint(url)?.host?.lowercased() == "receive-location" else { return nil }
        return Self()
    }

    static func parse(_ url: URL) throws -> Self {
        guard let components = endpoint(url) else { throw LocationWorkflowError.invalidRequest }
        let items = components.queryItems ?? []
        func value(_ keys: [String]) throws -> String? {
            let matches = items.filter { keys.contains($0.name.lowercased()) }
            guard matches.count <= 1 else { throw LocationWorkflowError.invalidRequest }
            return matches.first.map { ($0.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        func coordinate(in text: String) -> RouteCoordinate? {
            if let point = LocationLinkParser.sharedCoordinatePair(text) { return point }
            // A URL action can encode an already encoded coordinate token again.
            return text.removingPercentEncoding.flatMap(LocationLinkParser.sharedCoordinatePair)
        }
        let name: String? = try value(["name"]).flatMap { $0.isEmpty ? nil : String($0.prefix(120)) }
        func request(_ text: String, at coordinate: RouteCoordinate?) -> Self {
            let point = coordinate.map {
                RouteWaypoint(name: name ?? "Tọa độ được chia sẻ", coordinate: $0, source: "shortcut")
            }
            return Self(input: text, point: point)
        }

        let input = try value(["input"])
        let pair = try value(["coordinate", "coordinates", "coords", "ll"])
        let latitude = try value(["lat", "latitude"])
        let longitude = try value(["lon", "lng", "long", "longitude"])
        guard (input?.count ?? 0) <= 16_384, (pair?.count ?? 0) <= 256,
              (latitude?.count ?? 0) <= 128, (longitude?.count ?? 0) <= 128 else {
            throw LocationWorkflowError.invalidRequest
        }
        if latitude != nil || longitude != nil {
            guard let latitude, let longitude else { throw LocationWorkflowError.invalidRequest }
            let text = [latitude, longitude].map { $0.replacingOccurrences(of: ",", with: ".") }.joined(separator: ",")
            guard let point = coordinate(in: text) else { throw LocationWorkflowError.invalidRequest }
            if let pair, coordinate(in: pair) != point { throw LocationWorkflowError.invalidRequest }
            if let input, let other = coordinate(in: input), other != point { throw LocationWorkflowError.invalidRequest }
            return request(text, at: point)
        }
        if let pair {
            guard let point = coordinate(in: pair) else { throw LocationWorkflowError.invalidRequest }
            if let input, let other = coordinate(in: input), other != point { throw LocationWorkflowError.invalidRequest }
            return request(pair, at: point)
        }
        if let input, !input.isEmpty { return request(input, at: coordinate(in: input)) }
        if components.host?.lowercased() == "create-route" { return Self(isCompose: true) }
        throw LocationWorkflowError.invalidRequest
    }
}
