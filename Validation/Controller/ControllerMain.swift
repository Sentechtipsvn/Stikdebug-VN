import Foundation
import CoreLocation

final class ManualClock { var value: Double = 0 }

@main
@MainActor
struct ControllerValidation {
    static var checks = 0
    static let a = RouteCoordinate(latitude: 10, longitude: 106)
    static let b = RouteCoordinate(latitude: 10.00005, longitude: 106)
    static let c = RouteCoordinate(latitude: 10.00010, longitude: 106)
    static let session = LocationSimulationSession.shared
    static let device = FakeDevice.shared

    static func expect(_ value: Bool, _ message: String) {
        checks += 1
        if !value { fatalError("FAIL: \(message)") }
    }
    static func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.001 }
    static func waitUntil(_ label: String, _ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        fatalError("Timed out: \(label)")
    }
    static func example(_ dwell: Double = 300) -> SavedSimulationRoute {
        SavedSimulationRoute(name: "A → Trạm B → C", waypoints: [
            .init(name: "A", coordinate: a), .init(name: "Trạm B", coordinate: b, dwellSeconds: dwell), .init(name: "C", coordinate: c)
        ], legs: [.init(coordinates: [a, b], expectedTravelTime: 1), .init(coordinates: [b, c], expectedTravelTime: 1)], speedKmh: 36)
    }
    static func controller(_ clock: ManualClock, dwell: Double = 300) async throws -> RoutePlaybackController {
        session.stop(); device.reset()
        let controller = RoutePlaybackController(clock: { clock.value }, automaticTicks: false)
        try controller.load(example(dwell))
        expect(controller.phase == .ready && controller.displaySpeedKmh == 0, "Prepared route has zero current speed")
        controller.start()
        try await waitUntil("start") { controller.state == .running }
        expect(controller.phase == .moving && controller.displaySpeedKmh == 36, "Acknowledged start reports moving")
        return controller
    }
    static func tick(_ controller: RoutePlaybackController, _ clock: ManualClock, at time: Double) async {
        clock.value = time
        await controller.advanceTick(at: time)
    }
    static func main() async throws {
        try Data("test-only".utf8).write(to: PairingFileStore.prepareURL())
        defer { try? FileManager.default.removeItem(at: PairingFileStore.prepareURL()); session.stop() }
        try await countdownAndCompletion()
        try await suspensionAndSkip()
        try await editAtRest()
        try await commandOrdering()
        try await workspacePersistence()
        print("PASS: \(checks) production controller/session/workspace checks (device boundary simulated)")
    }
    static func countdownAndCompletion() async throws {
        let clock = ManualClock()
        let p = try await controller(clock)
        await tick(p, clock, at: 1)
        expect(p.phase == .resting && p.restName == "Trạm B", "Arrival shows named rest")
        expect(p.displaySpeedKmh == 0 && p.speedKmh == 36, "Rest current speed is zero; configured speed retained")
        expect(near(p.progress.dwellRemaining, 300), "Full five minutes start at arrival acknowledgement")
        let stoppedAt = session.coordinate!
        await tick(p, clock, at: 61)
        expect(near(p.progress.dwellRemaining, 240), "Countdown follows monotonic deadline")
        expect(session.coordinate!.latitude == stoppedAt.latitude, "Rest does not move")
        expect(device.recorded.filter { $0 == "set-done" }.count == 2, "Countdown does not send movement commands")
        p.pause()
        expect(p.phase == .paused && p.displaySpeedKmh == 0, "Manual pause shows zero speed")
        expect(near(p.progress.dwellRemaining, 240), "Pause freezes remaining rest")
        await tick(p, clock, at: 1061)
        expect(near(p.progress.dwellRemaining, 240), "Paused rest does not expire while clock advances")
        p.resume()
        await tick(p, clock, at: 1181)
        expect(near(p.progress.dwellRemaining, 120), "Resume uses remaining duration")
        await tick(p, clock, at: 1301)
        expect(p.progress.dwellRemaining == 0 && p.phase == .moving, "Rest expires automatically")
        expect(session.coordinate!.latitude == stoppedAt.latitude, "Rest expiry itself cannot teleport")
        await tick(p, clock, at: 1302)
        expect(p.state == .finished && p.displaySpeedKmh == 0, "Arrival holds destination with zero speed")
        expect(session.isActive && session.coordinate!.latitude == c.latitude, "End preserves exact destination")
        expect(p.statusTitle.contains("Đã đến"), "End title distinguishes completion from manual pause")
        p.stop()
        try await waitUntil("clear") { p.state == .ready && !p.isSending }
        expect(!session.isActive && session.coordinate == nil, "Return to real GPS clears active session only after acknowledgement")
        expect(p.message == "Đã tắt mô phỏng.", "Clear success message follows backend success")
    }
    static func suspensionAndSkip() async throws {
        let clock = ManualClock()
        let p = try await controller(clock)
        await tick(p, clock, at: 1)
        let distance = p.progress.distance
        await tick(p, clock, at: 1000)
        expect(p.state == .running && p.progress.dwellRemaining == 0, "Suspended rest expires by deadline")
        expect(p.progress.distance == distance, "Suspension during rest cannot catch up movement")
        await tick(p, clock, at: 1000.1)
        expect(p.progress.distance > distance && p.progress.distance < p.totalDistance, "After suspension movement restarts from held coordinate")
        await tick(p, clock, at: 1010)
        expect(p.state == .paused, "Long interruption while moving pauses safely")
        expect(p.displaySpeedKmh == 0, "Interrupted movement shows zero speed")
        let nextClock = ManualClock()
        _ = p.interruptForExternalAction()
        let q = try await controller(nextClock)
        await tick(q, nextClock, at: 1)
        q.skipRest()
        expect(q.progress.dwellRemaining == 0 && q.phase == .moving, "Skip rest goes to moving")
        expect(q.progress.nextStop == 1, "Skipped stop will not repeat")
        await tick(q, nextClock, at: 2)
        expect(q.state == .finished, "Skip continues route")
        let zeroClock = ManualClock()
        _ = q.interruptForExternalAction()
        let zero = try await controller(zeroClock, dwell: 0)
        await tick(zero, zeroClock, at: 1)
        expect(zero.progress.dwellRemaining == 0 && zero.progress.distance > a.distance(to: b), "Zero duration passes through stop")
        _ = zero.interruptForExternalAction()
    }
    static func editAtRest() async throws {
        let clock = ManualClock()
        let p = try await controller(clock)
        await tick(p, clock, at: 1)
        clock.value = 31
        var draft = p.remainingDraft()
        expect(draft.rows.count == 2 && draft.rows.last?.point?.name == "C", "Editor keeps only remaining original stops")
        let newStop = RouteWaypoint(name: "Trạm mới", coordinate: .init(latitude: 10.000075, longitude: 106), dwellSeconds: 7)
        try draft.addStop(newStop)
        expect(p.state == .running, "Drafting does not pause or replace live route")
        let anchor = try await p.pauseForEditing()!
        expect(p.state == .paused && near(anchor.remainingRest, 270), "Apply pauses and captures remaining rest")
        expect(anchor.coordinate == b && anchor.completedIDs.contains(p.route!.waypoints[1].id), "Apply anchors exact current position and visited IDs")
        let points = try draft.rebased(at: anchor.coordinate, completedIDs: anchor.completedIDs)
        let updated = SavedSimulationRoute(name: "Đã sửa", waypoints: points, legs: [
            .init(coordinates: [b, newStop.coordinate], expectedTravelTime: 1), .init(coordinates: [newStop.coordinate, c], expectedTravelTime: 1)
        ], speedKmh: 36)
        let commandCount = device.recorded.count
        try p.installDraft(updated, anchor: anchor)
        expect(p.state == .paused && session.coordinate!.latitude == b.latitude, "Install stays paused at same coordinate")
        expect(device.recorded.count == commandCount, "Installing draft does not send new movement")
        expect(near(p.progress.dwellRemaining, 270) && p.restName == "Trạm B", "Apply preserves rest at removed current stop")
        var invalid = updated; invalid.legs = []
        do { try p.installDraft(invalid, anchor: anchor); fatalError("Invalid replacement accepted") } catch { checks += 1 }
        expect(p.route?.id == updated.id && p.state == .paused, "Rejected draft preserves old active route")
        clock.value = 1000; p.resume()
        await tick(p, clock, at: 1270)
        expect(p.progress.distance == 0 && p.progress.dwellRemaining == 0, "Inherited rest expires without movement")
        await tick(p, clock, at: 1270.5)
        expect(p.restName == "Trạm mới" && near(p.progress.dwellRemaining, 7), "New stop receives its own duration")
        _ = p.interruptForExternalAction()
    }
    static func commandOrdering() async throws {
        let clock = ManualClock()
        let p = try await controller(clock)
        let gate = device.blockNextSet()
        clock.value = 0.2
        let tickTask = Task { await p.advanceTick(at: clock.value) }
        try await waitUntil("set in flight") { p.isSending }
        p.pause()
        expect(p.state == .running, "Pause waits for already submitted coordinate")
        gate.signal(); await tickTask.value
        expect(p.state == .paused && near(p.progress.distance, 2), "Pause commits acknowledged position before holding")
        p.resume()
        let blocker = device.blockNextSet()
        clock.value = 0.4
        let oldTick = Task { await p.advanceTick(at: clock.value) }
        try await waitUntil("second set in flight") { p.isSending }
        p.stop()
        expect(p.state == .stopping, "Stop accepted even during coordinate command")
        blocker.signal(); await oldTick.value
        try await waitUntil("stop serial ordering") { p.state == .ready && !p.isSending }
        expect(device.recorded.last == "clear" && !session.isActive, "Clear executes after old movement; old callback cannot revive session")
        let failClock = ManualClock()
        let q = try await controller(failClock)
        device.failNextSet(9)
        await tick(q, failClock, at: 0.2)
        expect(q.state == .failed && q.displaySpeedKmh == nil, "Failed movement is not reported as moving")
        device.failClear(8)
        q.stop()
        try await waitUntil("failed clear") { q.state == .failed && !q.isSending }
        expect(session.isActive && q.message!.contains("Chưa tắt được"), "Failed clear never claims real GPS restored")
        device.failClear(0)
        q.stop()
        try await waitUntil("retry clear") { q.state == .ready && !q.isSending }
        expect(!session.isActive, "Retry clears failed session")
        try await q.replaceWithPin(a)
        expect(session.isActive && q.phase == .holding && q.displaySpeedKmh == 0, "Incoming pin reports held location")
        expect(q.route == nil, "Replacing with pin ends previous route")
        q.stop()
        try await waitUntil("pin clear") { !session.isActive && !q.isSending }
    }
    static func workspacePersistence() async throws {
        let suite = "StikDebugVN.validation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LocationWorkspaceStore(defaults: defaults)
        let clock = ManualClock()
        let p = try await controller(clock)
        await tick(p, clock, at: 0.2)
        let previousRoute = p.route!.id
        store.receiveDestination(.init(name: "Đích mới", coordinate: c), playback: p)
        try store.receiveStop(.init(name: "Giao hàng", coordinate: b), playback: p)
        store.draft.rows[1].dwell = 90
        let restored = LocationWorkspaceStore(defaults: defaults)
        expect(restored.draft == store.draft, "Draft including duration persists after editor disappears")
        expect(p.route!.id == previousRoute && p.state == .running, "Receiving destination and stop keeps live route untouched")
        expect(restored.draft.rows.first?.point?.source == "simulated", "Automatic origin clearly uses simulated coordinate")
        let restoredID = store.draft.id
        store.prepareEditor(playback: p)
        expect(store.draft.id == restoredID, "Reopening preserves dirty draft")
        let bookmark = RouteWaypoint(name: "Kho", coordinate: a, source: "bookmark")
        store.setPoint(bookmark, rowID: store.draft.rows[0].id)
        store.acceptAutomaticOrigin(.init(name: "late GPS", coordinate: c))
        expect(store.draft.rows[0].point == bookmark, "Late location callback cannot overwrite chosen bookmark origin")
        _ = p.interruptForExternalAction()
        session.stop()
        store.discardDraft()
        expect(!store.draft.hasDestination && !store.draft.dirty, "Explicit discard clears draft")
    }
}
