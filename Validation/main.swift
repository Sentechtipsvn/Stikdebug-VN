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
expect(try LocationLinkParser.parse("https://maps.apple.com/place?coordinate=10.87139%2C106.73716&name=Ghim") == .coordinate(a, "Ghim"), "Apple Maps shared pin")
expect(try LocationLinkParser.parse("https://maps.apple.com/search?query=10.87139%2C106.73716&center=10.5%2C106.5") == .coordinate(a, nil), "Apple Maps search pin wins over the map center")
expect(try LocationLinkParser.parse("https://www.google.com/maps/search/?api=1&query=10.87139%2C106.73716") == .coordinate(a, nil), "Google query coordinates")
expect(try LocationLinkParser.parse("https://www.google.com/maps/place/Example/data=!3d10.87139!4d106.73716") == .coordinate(a, nil), "Google explicit marker")
expect(try LocationLinkParser.parse("Ghim\nhttps://www.google.com/maps/place/10.87139,+106.73716/@10.5,106.5,16z") == .coordinate(a, nil), "Google coordinate pin wins over the map center")
expect(try LocationLinkParser.parse("Tên địa điểm\nhttps://maps.apple.com/?coordinate=10.87139,106.73716") == .coordinate(a, nil), "Shared text and URL")
if case .unresolvedURL = try LocationLinkParser.parse("https://maps.app.goo.gl/a1b2c3") { expect(true, "Opaque short link requires network") }
else { expect(false, "Short link token must not become coordinates") }
if case .unresolvedURL = try LocationLinkParser.parse("https://www.google.com/maps/@10.87139,106.73716,15z") { expect(true, "Viewport not destination") }
else { expect(false, "Viewport must not silently become destination") }
if case .unresolvedURL = try LocationLinkParser.parse("https://maps.apple.com/frame?center=10.87139,106.73716") { expect(true, "Apple map center is not a pin") }
else { expect(false, "Apple map center must not silently become a destination") }
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

expect(try RestDuration.parse("5", unit: .minutes) == 300, "Five minutes")
expect(try RestDuration.parse("1,5", unit: .minutes) == 90, "Vietnam decimal comma")
expect(try RestDuration.parse("1.5", unit: .minutes) == 90, "Decimal dot")
expect(try RestDuration.parse(" 0 ", unit: .hours) == 0, "Zero skips rest")
expect(try RestDuration.parse("24", unit: .hours) == 86400, "Upper duration boundary")
expect(try RestDuration.parse("0.5", unit: .seconds) == 1, "Duration rounds to second precision")
for input in ["", "-1", "+5", "NaN", "inf", "1e3", "5 phút", "1,2.3", "999999999999999999999999999999999999"] {
    expectThrows("Invalid rest input: \(input)") { _ = try RestDuration.parse(input, unit: .minutes) }
}
expectThrows("Duration above 24h") { _ = try RestDuration.parse("24.01", unit: .hours) }
expect(RestDuration.clock(300) == "05:00" && RestDuration.clock(3601) == "01:00:01", "Readable rest clock")
expect(RestDuration.clock(.nan) == "00:00" && RestDuration.clock(-1) == "00:00", "Clock invalid values safe")
expect(RestDuration.initialEntry(seconds: 90).1 == .seconds, "Duration editor keeps exact saved value")
expect(RestDuration.initialEntry(seconds: 300).1 == .minutes, "Duration editor defaults to minutes")
var arrival = RouteProgress()
arrival.advance(seconds: 2, speed: 10, totalDistance: 100, stops: [.init(distance: 5, seconds: 300)], stopAtArrival: true)
expect(arrival.distance == 5 && arrival.dwellRemaining == 300, "Live arrival starts full duration after acknowledgement")
arrival.setDwellRemaining(150)
expect(arrival.remainingDwell(stops: [.init(distance: 5, seconds: 300)]) == 150, "Remaining dwell does not count visited stop twice")

let inputs = [
    "https://maps.apple.com/?ll=10.87139,106.73716&q=Kho Sếp & quán + café #1",
    "Quán A\nhttps://maps.app.goo.gl/aBc?x=1&y=2",
    "10.87139,106.73716", "123 Đỗ Mười, Thủ Đức", "%2C & + / ? = #"
]
for input in inputs {
    var url = URLComponents(string: "stikdebugvn://receive-location")!
    url.queryItems = [.init(name: "input", value: input)]
    expect(try LocationReceiveRequest.parse(url.url!).input == input, "Shortcut payload decoded exactly once: \(input)")
}
expect(try LocationReceiveRequest.parse(URL(string: "stikdebugvn://create-route")!).isCompose, "Home shortcut opens editor")
expect(try LocationReceiveRequest.parse(URL(string: "stikdebugvn://receive-location?lat=10&lon=106")!).input == "10,106", "Receiver supports direct coordinate parameters")
for invalid in ["stikdebug://receive-location?input=x", "stikdebugvn://simulate-location?input=x", "stikdebugvn://receive-location?input=x&input=y", "stikdebugvn://receive-location?lat=91&lon=106", "stikdebugvn://receive-location?lat=10", "stikdebugvn://user@receive-location?input=x", "stikdebugvn://receive-location:123/?input=x"] {
    expectThrows("Invalid receive URL: \(invalid)") { _ = try LocationReceiveRequest.parse(URL(string: invalid)!) }
}
var huge = URLComponents(string: "stikdebugvn://receive-location")!
huge.queryItems = [.init(name: "input", value: String(repeating: "x", count: 16385))]
expectThrows("Oversized receive input") { _ = try LocationReceiveRequest.parse(huge.url!) }

var draft = LocationRouteDraft()
expect(draft.originIsAutomatic && !draft.hasDestination, "New draft automatically requests origin")
expectThrows("Cannot add stop before destination") { try draft.addStop(.init(name: "Trạm", coordinate: a)) }
draft.setDestination(.init(name: "Đích", coordinate: b))
draft.rows[0].point = .init(name: "Điểm đi", coordinate: a)
let visited = RouteWaypoint(name: "Đã qua", coordinate: a, dwellSeconds: 300)
try draft.addStop(visited)
try draft.addStop(.init(name: "Sắp đến", coordinate: b, dwellSeconds: 90))
expect(draft.rows.count == 4 && draft.rows.last?.point?.name == "Đích", "Shared stops insert before destination")
expect(draft.points?[1].dwellSeconds == 300 && draft.points?[2].dwellSeconds == 90, "Draft retains exact dwell per stop")
let rebased = try draft.rebased(at: middle, completedIDs: [visited.id])
expect(rebased.count == 3 && rebased[0].coordinate == middle && rebased[1].name == "Sắp đến", "Editing removes visited stops and anchors current position")
expect(rebased.last?.name == "Đích", "Editing retains destination")
expect(try JSONDecoder().decode(LocationRouteDraft.self, from: JSONEncoder().encode(draft)) == draft, "Draft persistence round trip")
expect(LocationRouteDraft(route: saved).originIsAutomatic == false, "Opening saved route retains its selected origin")
expect(LocationRouteDraft(route: saved).vehicle == .car, "Older saved routes use car routing when recalculated")
expect(try JSONDecoder().decode(SavedSimulationRoute.self, from: JSONEncoder().encode(saved)).vehicle == nil,
       "Legacy route decodes without a vehicle field")

let motorcyclePoints = [
    RouteWaypoint(name: "Start", coordinate: a),
    RouteWaypoint(name: "Stop", coordinate: middle, dwellSeconds: 90),
    RouteWaypoint(name: "End", coordinate: b)
]
let motorcycleRequest = try MotorcycleRouting.request(waypoints: motorcyclePoints, key: "test-only")
let requestURL = URLComponents(url: motorcycleRequest.url!, resolvingAgainstBaseURL: false)!
let query = Dictionary(uniqueKeysWithValues: requestURL.queryItems!.compactMap { item in item.value.map { (item.name, $0) } })
expect(requestURL.scheme == "https" && requestURL.host == "api.geoapify.com", "Motorcycle requests target the HTTPS routing provider")
expect(query["mode"] == "motorcycle" && query["intermediate_waypoint_mode"] == "stopover", "Motorcycle mode requests ordered stops")
expect(query["waypoints"] == motorcyclePoints.map { "\($0.coordinate.latitude),\($0.coordinate.longitude)" }.joined(separator: "|"),
       "Only ordered coordinates are sent to the route provider")
expectThrows("Missing motorcycle key stops before networking") {
    _ = try MotorcycleRouting.request(waypoints: motorcyclePoints, key: "")
}
let motorcycleFixture = Data("""
    {"type":"FeatureCollection","features":[{
      "geometry":{"type":"MultiLineString","coordinates":[
        [[\(a.longitude),\(a.latitude)],[\(middle.longitude),\(middle.latitude)]],
        [[\(middle.longitude),\(middle.latitude)],[\(b.longitude),\(b.latitude)]]
      ]},
      "properties":{"legs":[{"time":140},{"time":180}]}
    }]}
    """.utf8)
let motorcycleLegs = try MotorcycleRouting.decode(motorcycleFixture, legCount: 2)
expect(motorcycleLegs.map(\.coordinates) == [[a, middle], [middle, b]], "GeoJSON decodes lon/lat and preserves each stop")
expect(motorcycleLegs.map(\.expectedTravelTime) == [140, 180], "Motorcycle leg times use the matching geometry")
expectThrows("A response missing an intermediate leg is rejected") {
    _ = try MotorcycleRouting.decode(motorcycleFixture, legCount: 3)
}
let motorcycleRoute = try SavedSimulationRoute(name: "Motorcycle", waypoints: motorcyclePoints, legs: motorcycleLegs, vehicle: .motorcycle).validated()
let restoredMotorcycleRoute = try JSONDecoder().decode(SavedSimulationRoute.self, from: JSONEncoder().encode(motorcycleRoute))
expect(LocationRouteDraft(route: restoredMotorcycleRoute).vehicle == .motorcycle &&
       restoredMotorcycleRoute.waypoints[1].dwellSeconds == 90, "Saved motorcycle route retains profile and stop duration")
expect(SimulationDisplayPhase.resting.showsZeroSpeed && SimulationDisplayPhase.paused.showsZeroSpeed && SimulationDisplayPhase.holding.showsZeroSpeed, "Stationary statuses have zero simulated speed")
expect(!SimulationDisplayPhase.failed.showsZeroSpeed && !SimulationDisplayPhase.starting.showsZeroSpeed, "Unknown backend state does not invent a speed")
for missing in ["stikdebugvn://receive-location", "stikdebugvn://receive-location?input=%20"] {
    expectThrows("Shared link without input reports an error") {
        _ = try LocationReceiveRequest.parse(URL(string: missing)!)
    }
}
let day: TimeInterval = 24 * 3600
let now = Date(timeIntervalSince1970: 2_000_000_000)
let expiry = now.addingTimeInterval(7 * day)
let reminders = SigningExpirySchedule.dates(expiry: expiry, enabledAt: now, now: now)
expect(reminders.count == 8 && reminders.first == expiry.addingTimeInterval(-day), "Expiry reminders start 24 hours before signing expiry")
expect(reminders.last == expiry.addingTimeInterval(-3 * 3600), "Last reminder is 3 hours before expiry")
expect(zip(reminders, reminders.dropFirst()).allSatisfy { $0.1.timeIntervalSince($0.0) == 3 * 3600 }, "Expiry reminder cadence is 3 hours")
let late = expiry.addingTimeInterval(-3600)
let lateReminders = SigningExpirySchedule.dates(expiry: expiry, enabledAt: late, now: late)
expect(lateReminders == [late.addingTimeInterval(5)], "Enabling late gives one reminder before expiration")
expect(SigningExpirySchedule.dates(expiry: expiry, enabledAt: late, now: late.addingTimeInterval(10)).isEmpty, "Reopening after a reminder does not recreate it")
expect(SigningExpirySchedule.dates(expiry: expiry, enabledAt: now, now: expiry).isEmpty, "No reminders after expiration")
let renewed = expiry.addingTimeInterval(7 * day)
expect(SigningExpirySchedule.dates(expiry: renewed, enabledAt: late, now: late).first == renewed.addingTimeInterval(-day), "Renewal moves reminders to the new period")
print("PASS: \(checks) route/location/duration/receiver/draft/signing reminder checks")
