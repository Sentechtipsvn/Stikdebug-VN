import Foundation
import Combine

@MainActor
final class LocationWorkspaceStore: ObservableObject {
    static let shared = LocationWorkspaceStore()
    @Published var draft: LocationRouteDraft { didSet { flush() } }
    @Published var incoming: LocationReceiveRequest?
    @Published var selectedPin: RouteWaypoint?
    private let defaults: UserDefaults
    private static let key = "vn.location.routeDraft.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), data.count <= 1_000_000,
           let decoded = try? JSONDecoder().decode(LocationRouteDraft.self, from: data),
           (2...100).contains(decoded.rows.count), decoded.speedKmh.isFinite, (1...300).contains(decoded.speedKmh),
           Set(decoded.rows.map(\.id)).count == decoded.rows.count,
           decoded.rows.allSatisfy({ $0.dwell.isFinite && (0...86400).contains($0.dwell) && ($0.point?.coordinate.isValid ?? true) }) {
            draft = decoded
        } else { draft = LocationRouteDraft() }
    }

    func flush() {
        if let data = try? JSONEncoder().encode(draft) { defaults.set(data, forKey: Self.key) }
    }

    func prepareEditor(playback: RoutePlaybackController) {
        if draft.dirty {
            if draft.replacement == .detour, (draft.originIsAutomatic || draft.rows.first?.point == nil),
               let origin = playback.simulatedRouteOrigin {
                useBotAsOrigin(origin)
            }
            return
        }
        if playback.hasActiveRoute { draft = playback.remainingDraft() }
        else if let route = playback.route, playback.state != .finished { draft = LocationRouteDraft(route: route) }
        else { draft = LocationRouteDraft() }
    }

    func receiveDestination(_ point: RouteWaypoint, playback: RoutePlaybackController) {
        prepareEditor(playback: playback)
        draft.setDestination(point)
        useSimulationAsOriginIfAutomatic()
    }

    func receiveStop(_ point: RouteWaypoint, playback: RoutePlaybackController) throws {
        prepareEditor(playback: playback)
        try draft.addStop(point)
        useSimulationAsOriginIfAutomatic()
    }

    func useSimulationAsOriginIfAutomatic() {
        guard draft.originIsAutomatic, draft.replacement != .detour, let coordinate = LocationSimulationSession.shared.coordinate,
              LocationSimulationSession.shared.isActive, !draft.rows.isEmpty else { return }
        draft.rows[0].point = .init(name: "Vị trí đang mô phỏng", coordinate: RouteCoordinate(coordinate), source: "simulated")
    }

    func useBotAsOrigin(_ point: RouteWaypoint) {
        guard !draft.rows.isEmpty else { return }
        var updated = draft
        updated.rows[0].point = point
        updated.originIsAutomatic = true
        updated.dirty = true
        draft = updated
    }

    func setPoint(_ point: RouteWaypoint, rowID: UUID) {
        guard let index = draft.rows.firstIndex(where: { $0.id == rowID }) else { return }
        draft.rows[index].point = point
        if index == 0 { draft.originIsAutomatic = false }
        draft.dirty = true
    }

    func acceptAutomaticOrigin(_ point: RouteWaypoint) {
        guard draft.originIsAutomatic, !draft.rows.isEmpty else { return }
        draft.rows[0].point = point
    }

    func didApply(_ route: SavedSimulationRoute) {
        draft = LocationRouteDraft(route: route)
        draft.dirty = false
    }

    func discardDraft() { draft = LocationRouteDraft() }
}
