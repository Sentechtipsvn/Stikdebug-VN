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
    static func controller(_ clock: ManualClock, dwell: Double = 300, feedbackDelay: Duration = .seconds(3)) async throws -> RoutePlaybackController {
        session.stop(); device.reset()
        let controller = RoutePlaybackController(clock: { clock.value }, automaticTicks: false, commandFeedbackDelay: feedbackDelay)
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
        try await interruptedConnection()
        try await visualMarker()
        try await probeAndHold()
        try await detourReplacement()
        try await detourFromBot()
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
        let endAnchor = try await p.pauseForEditing()
        expect(endAnchor?.coordinate == c, "Draft applied after old route finished still anchors held destination")
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
        try await p.installDraft(updated, anchor: anchor)
        expect(p.state == .paused && session.coordinate!.latitude == b.latitude, "Install stays paused at same coordinate")
        expect(device.recorded.count == commandCount, "Installing draft does not send new movement")
        expect(near(p.progress.dwellRemaining, 270) && p.restName == "Trạm B", "Apply preserves rest at removed current stop")
        var invalid = updated; invalid.legs = []
        do { try await p.installDraft(invalid, anchor: anchor); fatalError("Invalid replacement accepted") } catch { checks += 1 }
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
        expect(p.pausePending && p.displaySpeedKmh == nil, "Pause reports pending immediately while waiting for the submitted coordinate")
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

    static func interruptedConnection() async throws {
        let clock = ManualClock()
        let p = try await controller(clock, feedbackDelay: .milliseconds(50))
        await tick(p, clock, at: 0.2)
        let confirmedDistance = p.progress.distance
        let confirmedPoint = RouteCoordinate(session.coordinate!)

        device.failNextSet(3)
        let gate = device.blockNextSet()
        clock.value = 0.4
        let tickTask = Task { await p.advanceTick(at: clock.value) }
        try await waitUntil("slow connection feedback") { p.pausePending && p.message?.contains("chưa phản hồi") == true }
        expect(p.isSending && p.displaySpeedKmh == nil, "A stalled set reports the delay while the device queue is busy")
        expect(p.progress.distance == confirmedDistance, "A stalled set leaves progress at the last confirmed position")
        expect(device.lastSet?.reconnect == false, "Movement commands do not attempt a new tunnel")
        gate.signal()
        await tickTask.value
        expect(p.canResumeInterruptedRoute && p.progress.distance == confirmedDistance, "Failed set preserves progress for a reconnect")

        device.failNextSet(3)
        p.resume()
        try await waitUntil("failed reconnect") { p.canResumeInterruptedRoute && !p.isSending }
        expect(p.progress.distance == confirmedDistance, "A second connection failure preserves the same progress")

        clock.value = 100
        p.resume()
        try await waitUntil("reconnect and continue") { p.state == .running }
        expect(device.lastSet?.point == confirmedPoint && device.lastSet?.reconnect == true, "Resume sets the last confirmed coordinate with reconnection enabled")
        expect(p.progress.distance == confirmedDistance, "Reconnect does not restart or advance the route")
        await tick(p, clock, at: 100.1)
        expect(near(p.progress.distance, confirmedDistance + 1), "Progress after reconnect excludes disconnected time")
        p.stop()
        try await waitUntil("clear after reconnect") { p.state == .ready && !session.isActive }
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
        store.receiveDestination(.init(name: "Đích mới", coordinate: c, source: "shortcut"), playback: p)
        try store.receiveStop(.init(name: "Giao hàng", coordinate: b), playback: p)
        store.draft.rows[1].dwell = 90
        let restored = LocationWorkspaceStore(defaults: defaults)
        expect(restored.draft == store.draft, "Draft including duration persists after editor disappears")
        expect(p.route!.id == previousRoute && p.state == .running, "Receiving destination and stop keeps live route untouched")
        expect(restored.draft.rows.first?.point?.source == "simulated", "Automatic origin clearly uses simulated coordinate")
        expect(restored.draft.rows.last?.point?.source == "shortcut", "Shared destination retains its Shortcut source")
        expect(!restored.draft.replacesRouteFromSelectedOrigin(whileContinuingRoute: p.hasActiveRoute), "Automatic start continues from the bot")
        let restoredID = store.draft.id
        store.prepareEditor(playback: p)
        expect(store.draft.id == restoredID, "Reopening preserves dirty draft")
        let bookmark = RouteWaypoint(name: "Kho", coordinate: a, source: "bookmark")
        store.setPoint(bookmark, rowID: store.draft.rows[0].id)
        store.acceptAutomaticOrigin(.init(name: "late GPS", coordinate: c))
        expect(store.draft.rows[0].point == bookmark, "Late location callback cannot overwrite chosen bookmark origin")
        store.receiveDestination(.init(name: "Ghim khác", coordinate: b, source: "map"), playback: p)
        expect(store.draft.rows[0].point == bookmark && store.draft.rows.last?.point?.coordinate == b,
               "A second shared pin updates the destination and keeps a manually selected origin")
        expect(store.draft.rows.last?.point?.source == "map", "A manually picked destination keeps its actual source")
        expect(store.draft.replacesRouteFromSelectedOrigin(whileContinuingRoute: p.hasActiveRoute),
               "Explicit origin uses the replacement path instead of rebasing from the bot")
        expect(!store.draft.replacesRouteFromSelectedOrigin(whileContinuingRoute: false),
               "Ordinary planning from a chosen origin can load directly")
        expect(store.draft.rows[1].dwell == 90 && p.state == .running,
               "Accepting a shared destination preserves stops and does not apply or start a route")
        _ = p.interruptForExternalAction()
        session.stop()
        store.discardDraft()
        expect(!store.draft.hasDestination && !store.draft.dirty, "Explicit discard clears draft")
        try p.load(example())
        store.receiveDestination(.init(name: "Đích đã đổi", coordinate: c), playback: p)
        expect(store.draft.rows.count == 3 && store.draft.rows[1].point?.name == "Trạm B", "Sharing destination preserves stops of a prepared route")
        expect(store.draft.rows[1].dwell == 300, "Sharing destination preserves prepared dwell configuration")
    }

    static func probeAndHold() async throws {
        let clock = ManualClock()
        let p = try await controller(clock)
        let selected = RoutePath(coordinates: [a, b, c]).coordinate(at: 3)!
        try p.setProbe(near: .init(latitude: selected.latitude, longitude: selected.longitude + 0.00001))
        expect(near(p.probeDistance!, 3), "Map selection projects onto the route distance")
        do {
            try p.setProbe(near: .init(latitude: 10, longitude: 106.05))
            fatalError("Accepted a probe too far from the route")
        } catch LocationWorkflowError.probeOutsideRoute {
            expect(near(p.probeDistance!, 3), "Rejecting a distant tap preserves the selected probe")
        }
        try p.setProbe(at: 3)
        await tick(p, clock, at: 1)
        expect(p.isHoldingProbe && p.progress.distance == 3, "Playback clamps to the exact probe distance")
        expect(p.progress.nextStop == 0 && p.progress.dwellRemaining == 0, "Probe does not consume a future stop")
        expect(RouteCoordinate(session.coordinate!) == p.probeCoordinate, "Device session holds the acknowledged probe coordinate")
        let firstAcknowledgement = p.lastConfirmedAt
        let oldStarts = device.recorded.filter { $0 == "set-start" }.count
        device.failNextSet(3)
        let gate = device.blockNextSet()
        p.refreshHeldCoordinate()
        try await waitUntil("held set in flight") { device.recorded.filter { $0 == "set-start" }.count > oldStarts }
        p.refreshHeldCoordinate()
        gate.signal()
        try await waitUntil("held set failed") { p.holdUnconfirmed && !p.isSending }
        expect(device.recorded.filter { $0 == "set-start" }.count == oldStarts + 1, "Hold cannot queue another send while the first is blocked")
        expect(p.isHoldingProbe && p.displaySpeedKmh == nil && p.lastConfirmedAt == firstAcknowledgement,
               "A failed resend preserves the last confirmed position and time")
        p.resume()
        expect(p.state == .paused, "A failed hold requires an explicit retry before resuming")
        p.refreshHeldCoordinate()
        try await waitUntil("held set acknowledged") { !p.holdUnconfirmed && !p.isSending }
        expect(device.lastSet?.reconnect == true && device.lastSet?.point == p.probeCoordinate,
               "Retry reconnects and sends the same probe position")
        expect(p.isHoldingProbe && p.progress.distance == 3 && p.lastConfirmedAt! >= firstAcknowledgement!,
               "Retry holds instead of advancing")
        p.resume()
        expect(p.state == .running && p.probeDistance == nil, "Resume consumes the reached probe")
        await tick(p, clock, at: 1.5)
        expect(p.isResting && p.restName == "Trạm B", "Original timed stop remains after the probe")
        p.stop()
        try await waitUntil("clear probe") { p.state == .ready && !session.isActive }
    }

    static func visualMarker() async throws {
        let clock = ManualClock()
        let p = try await controller(clock)
        await tick(p, clock, at: 0.2)
        let confirmed = RouteCoordinate(session.coordinate!)
        clock.value = 0.45
        let displayed = p.visualPose(interpolate: true)!
        expect(p.animatesRouteMarker && near(a.distance(to: displayed.coordinate), 1), "Visual arrow interpolates the confirmed step")
        expect(near(a.distance(to: confirmed), 2) && p.visualPose(interpolate: false)?.coordinate == confirmed,
               "Visual interpolation does not change the acknowledged GPS")
        p.pause()
        expect(!p.animatesRouteMarker && p.visualPose(interpolate: true)?.coordinate == confirmed,
               "A stopped arrow shows the last confirmed point without drift")
        p.stop()
        try await waitUntil("clear visual marker") { p.state == .ready && !session.isActive }
        expect(p.visualPose(interpolate: true) == nil, "Returning to real GPS removes the arrow")
    }

    static func detourReplacement() async throws {
        let clock = ManualClock()
        let p = try await controller(clock)
        let original = p.route!
        var draft = LocationRouteDraft(replacement: .detour, from: original)
        expect(draft.rows.first?.point == nil && draft.rows.last?.point == original.waypoints.last && !draft.originIsAutomatic,
               "Detour retains the destination and waits for a chosen origin")
        let chosen = RouteCoordinate(latitude: 10.00015, longitude: 106)
        draft.rows[0].point = .init(name: "Chosen origin", coordinate: chosen)
        let points = draft.points!
        let new = SavedSimulationRoute(name: "Detour", waypoints: points, legs: [.init(coordinates: [chosen, c], expectedTravelTime: 1)])
        device.failClear(8)
        do {
            try await p.replaceRoute(with: new)
            fatalError("Applied detour even though the device failed to clear simulation")
        } catch LocationWorkflowError.gpsNotRestored {
            expect(p.route == original && session.isActive && p.previousRoute == nil, "Clear failure keeps the old route and held coordinate")
        }
        device.failClear(0)
        try await p.replaceRoute(with: new)
        expect(p.route?.waypoints.first?.coordinate == chosen && p.previousRoute == original, "Confirmed detour uses chosen origin and retains A")
        expect(p.state == .ready && !session.isActive, "Detour is prepared after the old location is cleared")
        try await p.replaceRoute(with: original)
        expect(p.route == original && p.previousRoute == new, "Previous route can be reopened without losing the other branch")
    }

    static func detourFromBot() async throws {
        let clock = ManualClock()
        let p = try await controller(clock)
        let original = p.route!
        let suite = "StikDebugVN.detour.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LocationWorkspaceStore(defaults: defaults)
        await tick(p, clock, at: 0.2)
        let firstPosition = RouteCoordinate(session.coordinate!)
        store.draft = LocationRouteDraft(replacement: .detour, from: original)
        let reopened = LocationWorkspaceStore(defaults: defaults)
        reopened.prepareEditor(playback: p)
        expect(reopened.draft.anchorsDetourToBot && reopened.draft.rows.first?.point?.coordinate == firstPosition,
               "An existing detour with an empty origin automatically uses the confirmed bot position")
        expect(reopened.draft.rows.last?.point == original.waypoints.last && p.state == .running,
               "Opening a detour keeps the old destination and the running route")

        let request = try LocationReceiveRequest.parse(URL(string: "stikdebugvn://receive-location?latitude=10.00015&lng=106")!)
        reopened.receiveDestination(request.point!, playback: p)
        expect(reopened.draft.rows.last?.point == request.point && reopened.draft.rows.first?.point?.coordinate == firstPosition,
               "A received point updates the destination of an existing detour")
        await tick(p, clock, at: 0.4)
        let anchor = try await p.pauseForEditing()!
        expect(anchor.coordinate == RouteCoordinate(session.coordinate!) && anchor.coordinate != firstPosition,
               "Applying a detour uses the position confirmed at pause")
        let points = try reopened.draft.rebased(at: anchor.coordinate, completedIDs: anchor.completedIDs)
        let new = SavedSimulationRoute(name: "Nhánh mới", waypoints: points,
                                       legs: [.init(coordinates: points.map(\.coordinate), expectedTravelTime: 2)])
        let commands = device.recorded
        try await p.installDraft(new, anchor: anchor, keepPrevious: true)
        expect(p.state == .paused && session.isActive && RouteCoordinate(session.coordinate!) == anchor.coordinate,
               "Applying keeps the active simulation at the confirmed start")
        expect(p.previousRoute == original && p.route?.waypoints.last?.coordinate == request.point?.coordinate,
               "The previous route can be restored and the received coordinate becomes the destination")
        expect(device.recorded == commands, "Switching from the bot sends neither a clear nor a movement command")
        do {
            try await p.installDraft(new, anchor: anchor, keepPrevious: true)
            fatalError("Installed a detour using an anchor from an earlier session")
        } catch LocationWorkflowError.simulationOriginUnavailable {
            expect(p.previousRoute == original, "A stale anchor cannot replace the current route or its predecessor")
        }
        p.resume()
        await tick(p, clock, at: 0.6)
        expect(p.state == .running && p.progress.distance > 0, "Continuing moves along the new branch from the held position")
        _ = p.interruptForExternalAction()
    }
}
