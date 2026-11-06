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

struct LocationRouteDraft: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var rows: [RouteDraftRow] = [.init(), .init()]
    var speedKmh: Double = 30
    var mode: RouteSpeedMode = .fixed
    var basedOnRouteID: UUID?
    var dirty = false
    var originIsAutomatic = true

    init() {}
    init(route: SavedSimulationRoute) {
        rows = route.waypoints.map { .init(point: $0, dwell: $0.dwellSeconds) }
        speedKmh = route.speedKmh
        mode = route.speedMode
        basedOnRouteID = route.id
        originIsAutomatic = false
    }

    var hasDestination: Bool { rows.count >= 2 && rows.last?.point != nil }
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
    var errorDescription: String? {
        switch self {
        case .noDestination: return "Hãy chọn điểm đến trước khi thêm điểm dừng."
        case .invalidRequest: return "Yêu cầu vị trí không hợp lệ. Hãy chia sẻ một địa điểm hoặc mở phím tắt không có đầu vào để tạo tuyến."
        case .busy: return "Đang xử lý lệnh vị trí. Vui lòng chờ một chút rồi thử lại."
        }
    }
}

struct LocationReceiveRequest: Identifiable, Equatable {
    let id: UUID
    let input: String?
    var isCompose: Bool { input == nil }

    init(input: String?) { id = UUID(); self.input = input }

    static func parse(_ url: URL) throws -> Self {
        guard url.scheme?.lowercased() == "stikdebugvn", url.user == nil, url.password == nil, url.port == nil, (url.path.isEmpty || url.path == "/"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(), ["receive-location", "create-route"].contains(host) else { throw LocationWorkflowError.invalidRequest }
        let items = components.queryItems ?? []
        for name in ["input", "lat", "lon", "name"] {
            guard items.filter({ $0.name == name }).count <= 1 else { throw LocationWorkflowError.invalidRequest }
        }
        if host == "create-route" { return Self(input: nil) }
        if let text = items.first(where: { $0.name == "input" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            guard text.count <= 16_384 else { throw LocationWorkflowError.invalidRequest }
            return Self(input: text)
        }
        let lat = items.first(where: { $0.name == "lat" })?.value
        let lon = items.first(where: { $0.name == "lon" })?.value
        if lat != nil || lon != nil {
            guard let lat, let lon, LocationLinkParser.coordinatePair(lat + "," + lon) != nil else { throw LocationWorkflowError.invalidRequest }
            return Self(input: lat + "," + lon)
        }
        return Self(input: nil)
    }
}
