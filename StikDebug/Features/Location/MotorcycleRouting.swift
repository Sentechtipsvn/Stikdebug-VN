import Foundation
import Security

enum MotorcycleRoutingError: LocalizedError {
    case missingKey, invalidKey, keyStorage, offline, unavailable, quota, noRoute

    var errorDescription: String? {
        switch self {
        case .missingKey: return "Nhập khóa API Geoapify để tính tuyến xe máy."
        case .invalidKey: return "Khóa Geoapify không hợp lệ hoặc chưa được cấp quyền định tuyến."
        case .keyStorage: return "Không cập nhật được khóa Geoapify trong Keychain."
        case .offline: return "Không kết nối được Geoapify. Kiểm tra Internet rồi tính lại."
        case .unavailable: return "Dịch vụ tính tuyến xe máy chưa phản hồi. Vui lòng thử lại."
        case .quota: return "Geoapify đang giới hạn lượt tính tuyến. Vui lòng thử lại sau."
        case .noRoute: return "Chưa tính được tuyến xe máy qua các điểm đã chọn. Hãy kiểm tra các ghim trên bản đồ."
        }
    }
}

enum MotorcycleRoutingKey {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.sentechtipsvn.stikdebugvn.routing",
        kSecAttrAccount as String: "geoapify"
    ]

    static func load() -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String) throws -> String {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.range(of: #"^[A-Za-z0-9_-]{8,128}$"#, options: .regularExpression) != nil else {
            throw MotorcycleRoutingError.invalidKey
        }
        let data = Data(key.utf8)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw MotorcycleRoutingError.keyStorage }
        } else if status != errSecSuccess {
            throw MotorcycleRoutingError.keyStorage
        }
        return key
    }

    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MotorcycleRoutingError.keyStorage }
    }
}

enum MotorcycleRouting {
    private static let session = URLSession(configuration: .ephemeral)

    static func calculate(waypoints: [RouteWaypoint], key: String) async throws -> [RouteLegData] {
        let request = try request(waypoints: waypoints, key: key)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: RejectRedirects())
        } catch {
            try Task.checkCancellation()
            throw MotorcycleRoutingError.offline
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw MotorcycleRoutingError.unavailable }
        switch http.statusCode {
        case 200: return try decode(data, legCount: waypoints.count - 1)
        case 401, 403: throw MotorcycleRoutingError.invalidKey
        case 429: throw MotorcycleRoutingError.quota
        case 400, 404, 422: throw MotorcycleRoutingError.noRoute
        default: throw MotorcycleRoutingError.unavailable
        }
    }

    static func request(waypoints: [RouteWaypoint], key: String) throws -> URLRequest {
        guard !key.isEmpty else { throw MotorcycleRoutingError.missingKey }
        guard (2...100).contains(waypoints.count), waypoints.allSatisfy({ $0.coordinate.isValid }) else {
            throw RouteDataError.invalid
        }
        let points = waypoints.map { "\($0.coordinate.latitude),\($0.coordinate.longitude)" }.joined(separator: "|")
        var url = URLComponents()
        url.scheme = "https"
        url.host = "api.geoapify.com"
        url.path = "/v1/routing"
        url.queryItems = [
            .init(name: "waypoints", value: points),
            .init(name: "mode", value: "motorcycle"),
            .init(name: "intermediate_waypoint_mode", value: "stopover"),
            .init(name: "format", value: "geojson"),
            .init(name: "apiKey", value: key)
        ]
        guard let endpoint = url.url else { throw RouteDataError.invalid }
        return URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
    }

    static func decode(_ data: Data, legCount: Int) throws -> [RouteLegData] {
        guard data.count <= 20_000_000,
              let result = try? JSONDecoder().decode(Response.self, from: data),
              let route = result.features.first, route.geometry.type == "MultiLineString",
              route.geometry.coordinates.count == legCount, route.properties.legs.count == legCount else {
            throw MotorcycleRoutingError.noRoute
        }
        return try zip(route.geometry.coordinates, route.properties.legs).map { line, leg in
            guard line.count >= 2, leg.time.isFinite, leg.time >= 0 else { throw MotorcycleRoutingError.noRoute }
            let points = try line.map { values in
                guard values.count >= 2 else { throw MotorcycleRoutingError.noRoute }
                let point = RouteCoordinate(latitude: values[1], longitude: values[0])
                guard point.isValid else { throw MotorcycleRoutingError.noRoute }
                return point
            }
            return RouteLegData(coordinates: points, expectedTravelTime: leg.time)
        }
    }

    private struct Response: Decodable {
        struct Feature: Decodable {
            struct Geometry: Decodable {
                let type: String
                let coordinates: [[[Double]]]
            }
            struct Properties: Decodable {
                struct Leg: Decodable { let time: Double }
                let legs: [Leg]
            }
            let geometry: Geometry
            let properties: Properties
        }
        let features: [Feature]
    }

    private final class RejectRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
