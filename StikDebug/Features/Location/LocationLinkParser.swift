import Foundation

enum LocationInputResult: Equatable {
    case coordinate(RouteCoordinate, String?)
    case search(String)
    case multiple([RouteCoordinate])
    case unresolvedURL(URL)
}

enum LocationInputError: LocalizedError {
    case invalid
    case unsupportedHost
    case noExactCoordinate

    var errorDescription: String? {
        switch self {
        case .invalid: return "Không đọc được vị trí. Hãy dán link bản đồ hoặc tọa độ dạng vĩ độ, kinh độ."
        case .unsupportedHost: return "Link này chưa được hỗ trợ. Hãy dùng link Apple Maps, Google Maps hoặc tọa độ."
        case .noExactCoordinate: return "Link chưa cung cấp tọa độ điểm đến rõ ràng. Hãy chọn lại điểm trên bản đồ hoặc dán tọa độ."
        }
    }
}

enum LocationLinkParser {
    static func coordinatePair(_ text: String) -> RouteCoordinate? {
        let pattern = #"^\s*([-+]?(?:\d+(?:\.\d*)?|\.\d+))\s*[,;\n]\s*([-+]?(?:\d+(?:\.\d*)?|\.\d+))\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let a = Range(match.range(at: 1), in: text), let b = Range(match.range(at: 2), in: text),
              let lat = Double(text[a]), let lon = Double(text[b]) else { return nil }
        let coordinate = RouteCoordinate(latitude: lat, longitude: lon)
        return coordinate.isValid ? coordinate : nil
    }

    static func sharedCoordinatePair(_ text: String) -> RouteCoordinate? {
        if let point = coordinatePair(text) { return point }
        let part = #"(\d{1,3})\s*[°º]\s*(\d{1,2})\s*['′]\s*(\d{1,2}(?:\.\d+)?)\s*["″]\s*"#
        let pattern = #"^\s*"# + part + #"([NS])\s*[,;]?\s*"# + part + #"([EW])\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }

        func value(at index: Int) -> Double? {
            func group(_ i: Int) -> Substring? {
                Range(match.range(at: i), in: text).map { text[$0] }
            }
            guard let degrees = group(index).flatMap({ Double($0) }),
                  let minutes = group(index + 1).flatMap({ Double($0) }),
                  let seconds = group(index + 2).flatMap({ Double($0) }),
                  let direction = group(index + 3)?.uppercased(), minutes < 60, seconds < 60 else { return nil }
            let decimal = degrees + minutes / 60 + seconds / 3600
            return direction == "S" || direction == "W" ? -decimal : decimal
        }
        guard let latitude = value(at: 1), let longitude = value(at: 5) else { return nil }
        let point = RouteCoordinate(latitude: latitude, longitude: longitude)
        return point.isValid ? point : nil
    }

    static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return false }
        return ["maps.apple.com", "maps.apple", "maps.app.goo.gl", "goo.gl", "maps.google.com", "maps.google.com.vn", "google.com", "www.google.com", "google.com.vn", "www.google.com.vn"].contains(host)
            || host.hasSuffix(".maps.apple")
    }

    static func parse(_ raw: String, depth: Int = 0) throws -> LocationInputResult {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 16_384 else { throw LocationInputError.invalid }
        if let point = sharedCoordinatePair(text) { return .coordinate(point, nil) }
        if text.lowercased().hasPrefix("geo:") {
            if let point = coordinatePair(String(text.dropFirst(4)).components(separatedBy: "?")[0]) { return .coordinate(point, nil) }
            throw LocationInputError.invalid
        }
        // Accept text from a share sheet containing a name followed by one map URL.
        let detector = try? NSRegularExpression(pattern: #"https?://[^\s<>]+"#, options: .caseInsensitive)
        let matches = detector?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []
        if matches.isEmpty {
            if text.contains("://") || text.range(of: #"^[\s\d.,;+\-]+$"#, options: .regularExpression) != nil { throw LocationInputError.invalid }
            return .search(text)
        }
        guard matches.count == 1, let range = Range(matches[0].range, in: text),
              var components = URLComponents(string: String(text[range])) else { throw LocationInputError.invalid }
        if components.scheme?.lowercased() == "http" { components.scheme = "https" }
        guard let url = components.url, isAllowed(url) else { throw LocationInputError.unsupportedHost }
        let query = components.queryItems ?? []
        func value(_ names: [String]) -> String? {
            for name in names {
                if let v = query.first(where: { $0.name.lowercased() == name })?.value, !v.isEmpty { return v }
            }
            return nil
        }
        if depth < 3, let nested = value(["link", "deep_link_id"]), nested.hasPrefix("https://") {
            return try parse(nested, depth: depth + 1)
        }
        let host = url.host?.lowercased() ?? ""
        let isApple = host == "maps.apple.com" || host == "maps.apple" || host.hasSuffix(".maps.apple")
        let title = value(["name", "q"])
        if let explicit = value(isApple ? ["coordinate", "ll", "query", "q"] : ["query", "q"]), let point = coordinatePair(explicit) {
            return .coordinate(point, title.flatMap { coordinatePair($0) == nil ? $0 : nil })
        }
        if let lat = value(["lat", "latitude"]), let lon = value(["lon", "lng", "longitude"]), let point = coordinatePair(lat + "," + lon) {
            return .coordinate(point, title)
        }
        // A directions link can contain several explicit points. Let the person choose.
        let directionNames = ["origin", "saddr", "waypoints", "destination", "daddr"]
        var directionPoints: [RouteCoordinate] = []
        for name in directionNames {
            for item in query where item.name.lowercased() == name {
                for part in (item.value ?? "").components(separatedBy: "|") {
                    if let point = coordinatePair(part), directionPoints.last != point { directionPoints.append(point) }
                }
            }
        }
        if directionPoints.count > 1 { return .multiple(directionPoints) }
        if let point = directionPoints.first { return .coordinate(point, title) }
        if !isApple {
            let decoded = url.absoluteString.removingPercentEncoding ?? url.absoluteString
            let pattern = #"!3d([-+]?\d+(?:\.\d+)?)!4d([-+]?\d+(?:\.\d+)?)"#
            if let regex = try? NSRegularExpression(pattern: pattern) {
                var points: [RouteCoordinate] = []
                for match in regex.matches(in: decoded, range: NSRange(decoded.startIndex..., in: decoded)) {
                    if let a = Range(match.range(at: 1), in: decoded), let b = Range(match.range(at: 2), in: decoded),
                       let point = coordinatePair(String(decoded[a]) + "," + String(decoded[b])), !points.contains(point) { points.append(point) }
                }
                if points.count > 1 { return .multiple(points) }
                if let point = points.first { return .coordinate(point, title) }
            }
            let segments = components.path.split(separator: "/")
            if segments.count >= 3, segments[0] == "maps", segments[1] == "place",
               let point = coordinatePair(segments[2].replacingOccurrences(of: "+", with: " ")) {
                return .coordinate(point, title)
            }
        }
        // Never interpret a viewport (@lat,lon), a place ID, a token, or street numbers as an exact destination.
        if let address = value(isApple ? ["address", "query", "q", "name"] : ["query", "q"]), coordinatePair(address) == nil {
            return .search(address)
        }
        return .unresolvedURL(url)
    }
}
