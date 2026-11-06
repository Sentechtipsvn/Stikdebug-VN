import Foundation

var checks = 0
func expect(_ condition: Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
    checks += 1
    if !condition { fatalError("FAIL: \(message)", file: file, line: line) }
}
func expectThrows(_ message: String, _ operation: () throws -> Void) {
    checks += 1
    do { try operation(); fatalError("FAIL: \(message)") } catch {}
}

let a = RouteCoordinate(latitude: 10.87139, longitude: 106.73716)
let commands = SimulationCommandToken()
let firstCommand = commands.begin()
expect(commands.isCurrent(firstCommand), "Current resend accepted")
commands.invalidate()
expect(!commands.isCurrent(firstCommand), "Stop rejects queued old resend")
let nextCommand = commands.begin()
expect(commands.isCurrent(nextCommand), "New resend accepted after stop")
expect(!commands.isCurrent(firstCommand), "Previous session cannot overwrite new position")
let b = RouteCoordinate(latitude: 10.81483, longitude: 106.71086)
expect(a.isValid, "Vietnam coordinate valid")
expect(!RouteCoordinate(latitude: .nan, longitude: 0).isValid, "NaN rejected")
expect(!RouteCoordinate(latitude: 91, longitude: 0).isValid, "Latitude bounded")
expect(!RouteCoordinate(latitude: 0, longitude: 181).isValid, "Longitude bounded")
expect(a.distance(to: a) == 0, "Zero distance")
let path = RoutePath(coordinates: [a, a, b])
expect(path.coordinates.count == 2, "Adjacent duplicates removed")
expect(path.totalDistance > 6000 && path.totalDistance < 8000, "Plausible Vietnam distance")
expect(path.coordinate(at: -5) == a, "Start clamp")
expect(path.coordinate(at: path.totalDistance + 5) == b, "End clamp")
let middle = path.coordinate(at: path.totalDistance / 2)!
expect(abs(middle.latitude - (a.latitude + b.latitude) / 2) < 0.000001, "Distance interpolation")
let dateline = RouteCoordinate(latitude: 0, longitude: 179).interpolated(to: .init(latitude: 0, longitude: -179), fraction: 0.5)
expect(abs(dateline.longitude) == 180, "Antimeridian uses shortest segment")

var progress = RouteProgress()
let stops = [RouteDwell(distance: 50, seconds: 3)]
progress.advance(seconds: 6, speed: 10, totalDistance: 100, stops: stops)
expect(progress.distance == 50 && progress.dwellRemaining == 2, "Dwell consumes remaining tick time")
progress.advance(seconds: 4, speed: 10, totalDistance: 100, stops: stops)
expect(progress.distance == 70 && progress.dwellRemaining == 0, "Dwell completes before movement")
progress.advance(seconds: 1, speed: 20, totalDistance: 100, stops: stops)
expect(progress.distance == 90, "New speed keeps previous progress")
progress.advance(seconds: 10, speed: 20, totalDistance: 100, stops: stops)
expect(progress.distance == 100, "Progress never overshoots destination")
progress.advance(seconds: .nan, speed: 1, totalDistance: 100, stops: stops)
expect(progress.distance == 100, "Invalid time ignored")
var multipleStops = RouteProgress()
multipleStops.advance(seconds: 30, speed: 10, totalDistance: 100, stops: [.init(distance: 25, seconds: 2), .init(distance: 50, seconds: 5)])
expect(multipleStops.distance == 100 && multipleStops.nextStop == 2, "Multiple stops in one advancement")

expect(LocationLinkParser.coordinatePair("10.87139, 106.73716") == a, "Coordinate pair")
expect(LocationLinkParser.coordinatePair("10.87139;106.73716") == a, "Semicolon coordinate pair")
expect(LocationLinkParser.coordinatePair("90.1, 106") == nil, "Invalid coordinate is not swapped")
expect(LocationLinkParser.coordinatePair("street 10, house 20") == nil, "Street numbers not coordinates")
expect(try LocationLinkParser.parse("https://maps.apple.com/?ll=10.87139,106.73716&q=Nh%C3%A0") == .coordinate(a, "Nhà"), "Apple Maps coordinate and label")
expect(try LocationLinkParser.parse("https://www.google.com/maps/search/?api=1&query=10.87139%2C106.73716") == .coordinate(a, nil), "Google query coordinates")
expect(try LocationLinkParser.parse("https://www.google.com/maps/place/Example/data=!3d10.87139!4d106.73716") == .coordinate(a, nil), "Google explicit marker")
expect(try LocationLinkParser.parse("Tên địa điểm\nhttps://maps.apple.com/?coordinate=10.87139,106.73716") == .coordinate(a, nil), "Shared text and URL")
if case .unresolvedURL = try LocationLinkParser.parse("https://maps.app.goo.gl/a1b2c3") { expect(true, "Opaque short link requires network") }
else { expect(false, "Short link token must not become coordinates") }
if case .unresolvedURL = try LocationLinkParser.parse("https://www.google.com/maps/@10.87139,106.73716,15z") { expect(true, "Viewport not destination") }
else { expect(false, "Viewport must not silently become destination") }
expect(try LocationLinkParser.parse("https://www.google.com/maps/dir/?api=1&origin=10.87139,106.73716&destination=10.81483,106.71086") == .multiple([a, b]), "Direction endpoints require selection")
expect(try LocationLinkParser.parse("123 Đường số 7") == .search("123 Đường số 7"), "Search text preserved")
expectThrows("Foreign host rejected") { _ = try LocationLinkParser.parse("https://example.com/?q=10,106") }
expectThrows("Lookalike host rejected") { _ = try LocationLinkParser.parse("https://maps.apple.com.example.com/?ll=10,106") }
expectThrows("Credentials rejected") { _ = try LocationLinkParser.parse("https://user@maps.apple.com/?ll=10,106") }
expectThrows("Invalid numeric input rejected") { _ = try LocationLinkParser.parse("91,181") }

let saved = SavedSimulationRoute(name: "Kiểm tra", waypoints: [.init(name: "A", coordinate: a), .init(name: "B", coordinate: b)], legs: [.init(coordinates: [a, b], expectedTravelTime: 1200)])
let encoded = try JSONEncoder().encode(saved.validated())
let decoded = try JSONDecoder().decode(SavedSimulationRoute.self, from: encoded).validated()
expect(decoded == saved, "Route round trip preserves geometry and configuration")
var broken = saved
broken.speedKmh = .infinity
expectThrows("Invalid saved speed rejected") { _ = try broken.validated() }
broken = saved
broken.legs[0].coordinates = [a]
expectThrows("Truncated geometry rejected") { _ = try broken.validated() }
broken = saved
broken.waypoints[1].id = broken.waypoints[0].id
expectThrows("Duplicate waypoint IDs rejected") { _ = try broken.validated() }
print("PASS: \(checks) route and location checks")
