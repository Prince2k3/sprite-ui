@_spi(Backend) import ECSCore
import Foundation

/// Adapts one optional native sensor into the existing action router. The raw
/// calibrated sample, rather than its smoothed output, controls the neutral gate.
@MainActor
final class GameHingeInput {
    private let router: GameInputRouter
    private(set) var configuration: HingeInputConfiguration?
    private var connectedHub: PlayerInputHub?
    private var destination: ObjectIdentifier?
    private var ownerID: UUID?
    private var revision: UInt64 = 0
    private var isStopping = false
    private var armed = false
    private var filtered: Float = 0
    private var lastTime: TimeInterval?

    init(router: GameInputRouter) { self.router = router }

    func configure(_ configuration: HingeInputConfiguration?) {
        guard self.configuration != configuration else { return }
        self.configuration = configuration
        stop()
    }

    /// Releases only this producer. Other virtual controls remain usable.
    func suspend() {
        armed = false; filtered = 0; lastTime = nil
        router.cancel(device: .hinge)
    }

    func stop() {
        guard !isStopping else { return }
        isStopping = true
        defer { isStopping = false }
        revision &+= 1
        let hub = connectedHub, input = router.input
        connectedHub = nil; destination = nil; ownerID = nil
        armed = false; filtered = 0; lastTime = nil
        router.forgetTrackedDevices([.hinge])
        if let hub { hub.disconnect(.hinge) }
        else { input?.cancel(device: .hinge) }
    }

    func poll(_ state: GameHingeState?, at time: TimeInterval) {
        guard !isStopping else { return }
        guard let configuration else { return }
        if destination != router.routingIdentity {
            let oldRevision = revision
            stop()
            guard revision == oldRevision &+ 1, self.configuration == configuration else { return }
            destination = router.routingIdentity
        }
        let generation = revision, identity = router.routingIdentity
        func isCurrent() -> Bool {
            revision == generation && router.routingIdentity == identity && self.configuration == configuration
        }
        // A rejected second host never registers or disconnects the first host's sensor.
        guard router.hub == nil || router.hasBackendLease else { return }
        guard let state else {
            if connectedHub != nil || armed || lastTime != nil { stop() }
            return
        }
        if let hub = router.hub, connectedHub !== hub {
            connectedHub = hub
            hub.connect(.init(id: .hinge, name: "Device hinge", presentations: [
                .hinge: .init(label: "Fold", symbolName: "rectangle.split.2x1")
            ]))
            guard isCurrent(), connectedHub === hub, router.hasBackendLease else { return }
        }
        let owner = connectedHub?.owner(of: .hinge)?.id
        if owner != ownerID {
            ownerID = owner
            armed = false; filtered = 0; lastTime = nil
        }
        guard router.isActive, state.status != .unknown, time.isFinite else { suspend(); return }
        if let previous = lastTime, time < previous { suspend(); return }
        let target = configuration.value(for: state)
        let elapsed = lastTime.map { max(0, time - $0) } ?? 0
        lastTime = time
        if !armed {
            armed = target == 0
            filtered = 0
        } else if target == 0 {
            // A physical neutral is an immediate release and clears core gates.
            filtered = 0
        } else if configuration.smoothing == 0 {
            filtered = target
        } else {
            let blend = Float(1 - exp(-elapsed / configuration.smoothing))
            filtered += (target - filtered) * blend
        }
        guard isCurrent(), connectedHub?.owner(of: .hinge)?.id == owner else { return }
        router.send([(.hinge, .axis(filtered))], device: .hinge)
    }
}
