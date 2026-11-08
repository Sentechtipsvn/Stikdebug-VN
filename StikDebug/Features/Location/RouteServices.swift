import Foundation
import MapKit
import Combine

@MainActor
final class RouteLibraryStore: ObservableObject {
    static let shared = RouteLibraryStore()
    @Published private(set) var routes: [SavedSimulationRoute] = []
    @Published private(set) var loadError: String?

    private struct Archive: Codable {
        var schemaVersion = 1
        var routes: [SavedSimulationRoute]
    }
    private var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StikDebugVN", isDirectory: true).appendingPathComponent("SavedRoutes.json")
    }

    private init() {
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let data = try Data(contentsOf: fileURL)
                routes = try Self.decode(data)
            }
        } catch { loadError = error.localizedDescription }
    }

    func save(_ route: SavedSimulationRoute) throws {
        var next = routes
        var route = try route.validated()
        route.updatedAt = Date()
        if let index = next.firstIndex(where: { $0.id == route.id }) { next[index] = route }
        else { next.insert(route, at: 0) }
        try persist(next)
    }

    func delete(_ route: SavedSimulationRoute) throws { try persist(routes.filter { $0.id != route.id }) }

    func importFile(_ url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 20_000_000 else { throw RouteDataError.tooLarge }
        let incoming = try Self.decode(Data(contentsOf: url))
        var next = routes
        for var route in incoming {
            if next.contains(where: { $0.id == route.id }) { route.id = UUID() }
            next.append(route)
        }
        try persist(next)
    }

    func exportURL(for route: SavedSimulationRoute) throws -> URL {
        let data = try JSONEncoder().encode(Archive(routes: [try route.validated()]))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RouteExports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("StikDebug-VN-\(route.id.uuidString).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func decode(_ data: Data) throws -> [SavedSimulationRoute] {
        guard data.count <= 20_000_000 else { throw RouteDataError.tooLarge }
        let archive = try JSONDecoder().decode(Archive.self, from: data)
        guard archive.schemaVersion == 1 else { throw RouteDataError.unsupportedVersion }
        return try archive.routes.map { try $0.validated() }
    }

    private func persist(_ next: [SavedSimulationRoute]) throws {
        let data = try JSONEncoder().encode(Archive(routes: next))
        guard data.count <= 20_000_000 else { throw RouteDataError.tooLarge }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if loadError != nil && FileManager.default.fileExists(atPath: fileURL.path) {
            let backup = fileURL.deletingLastPathComponent().appendingPathComponent("SavedRoutes-backup-\(UUID().uuidString).json")
            try FileManager.default.copyItem(at: fileURL, to: backup)
        }
        try data.write(to: fileURL, options: .atomic)
        routes = next
        loadError = nil
    }
}

@MainActor
enum VNRoutePlanner {
    static func calculate(waypoints: [RouteWaypoint], speedKmh: Double, mode: RouteSpeedMode,
                          vehicle: RouteVehicle, motorcycleKey: String?) async throws -> SavedSimulationRoute {
        guard (2...100).contains(waypoints.count) else { throw RouteDataError.invalid }
        let legs: [RouteLegData]
        switch vehicle {
        case .car:
            legs = try await carLegs(through: waypoints)
        case .motorcycle:
            guard let motorcycleKey else { throw MotorcycleRoutingError.missingKey }
            legs = try await MotorcycleRouting.calculate(waypoints: waypoints, key: motorcycleKey)
        }
        var route = SavedSimulationRoute(name: "\(waypoints[0].name) → \(waypoints[waypoints.count - 1].name)", waypoints: waypoints,
                                         legs: legs, speedKmh: speedKmh, speedMode: mode, vehicle: vehicle)
        if mode == .road {
            let coordinates = route.coordinates
            let ways = (try? await fetchOpenStreetMapWays(for: coordinates.map(\.clCoordinate))) ?? []
            try Task.checkCancellation()
            let duration = legs.reduce(0) { $0 + $1.expectedTravelTime }
            let fallback = max(1, duration > 0 ? RoutePath(coordinates: coordinates).totalDistance / duration : 13.4)
            route.roadSpeeds = zip(coordinates, coordinates.dropFirst()).map {
                max(1, nearestSpeedLimit(forSegmentFrom: $0.0.clCoordinate, to: $0.1.clCoordinate, using: ways) ?? fallback)
            }
        }
        return try route.validated()
    }

    private static func carLegs(through waypoints: [RouteWaypoint]) async throws -> [RouteLegData] {
        var legs: [RouteLegData] = []
        for index in 0..<(waypoints.count - 1) {
            try Task.checkCancellation()
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: waypoints[index].coordinate.clCoordinate))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: waypoints[index + 1].coordinate.clCoordinate))
            request.transportType = .automobile
            let directions = MKDirections(request: request)
            let response: MKDirections.Response
            do {
                response = try await withTaskCancellationHandler(operation: { try await directions.calculate() }, onCancel: { directions.cancel() })
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw NSError(domain: "StikDebugVN.Route", code: 1, userInfo: [NSLocalizedDescriptionKey: "Không tính được chặng \(index + 1): \(waypoints[index].name) → \(waypoints[index + 1].name). \(error.localizedDescription)"])
            }
            guard let route = response.routes.first else { throw RouteDataError.invalid }
            var coordinates = [CLLocationCoordinate2D](repeating: .init(), count: route.polyline.pointCount)
            route.polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: coordinates.count))
            legs.append(.init(coordinates: coordinates.map(RouteCoordinate.init), expectedTravelTime: route.expectedTravelTime))
        }
        return legs
    }
}

private final class MapRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private var redirects = 0
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        completionHandler(redirects <= 6 && request.url.map(LocationLinkParser.isAllowed) == true ? request : nil)
    }
}

enum LocationInputResolver {
    static func resolve(_ raw: String) async throws -> LocationInputResult {
        let initial = try LocationLinkParser.parse(raw)
        guard case .unresolvedURL(let url) = initial else { return initial }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        let guardDelegate = MapRedirectGuard()
        let session = URLSession(configuration: config, delegate: guardDelegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (_, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let final = response.url, LocationLinkParser.isAllowed(final),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw LocationInputError.noExactCoordinate }
        let result = try LocationLinkParser.parse(final.absoluteString)
        if case .unresolvedURL = result { throw LocationInputError.noExactCoordinate }
        return result
    }
}
