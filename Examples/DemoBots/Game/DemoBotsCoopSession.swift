import Foundation
import Observation
import SpriteUI
import SwiftUI
import simd

struct CoopActor: Component, Codable {
    enum Kind: String, Codable { case player, bot }
    var kind: Kind
    var corruption: Int
}
struct CoopRound: Component, Codable {
    var cured = 0
    var total = 4
    var seconds = 120
    var finished = false
}
private struct CoopRecovery: Codable { let version: Int; let remaining: Double }
private struct CoopRuntime: Component { weak var game: DemoBotsCoopSession? }
private struct CoopRulesSystem: System {
    static var phase: SystemPhase { .fixedSimulation }
    static var dependencies: [SystemDependency] { [.after(NetworkMovementSystem2D.self)] }
    init(world: World) {}
    mutating func update(context: UpdateContext) { context.world.root.components[CoopRuntime.self]?.game?.simulateHost(in: context.world, dt: context.deltaTime) }
}

/// A two-player open-floor DemoBots round using party handoff, prediction, historical beams, scoped replication, and explicit recovery.
/// The campaign remains separate. Preview mode runs both real SDK coordinators locally without accounts or native matchmaking.
@MainActor @Observable public final class DemoBotsCoopSession {
    public let isPreview: Bool
    public let usesArtwork: Bool
    public let services: GameCenterServices
    public private(set) var message = "Start local co-op, or explicitly sign in and join a Game Center activity party."
    public private(set) var score = 0
    public private(set) var cured = 0
    public private(set) var secondsLeft = 120
    public private(set) var finished = false
    public private(set) var pendingActions = 0
    public private(set) var corrections: UInt64 = 0
    public private(set) var hasRecoveryPoint = false
    public private(set) var busy = false
    public private(set) var confirmedBeams = 0
    public private(set) var phase = "menu"
    public var partyCode = "1234-5678"
    public var previewPartnerMoves = true
    public var previewPartnerFires = false
    /// One-way delay in the local fixture; native Game Center delivery is unaffected.
    public var previewLatency: TimeInterval = 0
    /// Loss affects unreliable poses and movement only, never reliable handoff or final receipts.
    public var previewLossRate = 0.0
    /// Deterministically varies local packet delay from half to one-and-a-half times the base delay.
    public var previewJitter = false
    /// Pending packets observed during the most recent local-fixture advance.
    public private(set) var previewPendingPackets = 0
    /// Pending payload bytes observed during the most recent local-fixture advance.
    public private(set) var previewPendingBytes = 0
    private var previewClock = 0.0
    public var statistics: [NetworkPeerReplicationStatistics] { hostSession?.replicationStatistics ?? services.networkSession?.replicationStatistics ?? [] }
    public var canControl: Bool {
        guard phase == "playing", !finished, !busy else { return false }
        if services.networkSession?.isHost == true { return true }
        return movement?.status == .running && interaction?.status == .running
    }
    var localWorld = World()
    var partnerWorld: World?
    var partner: GameCenterServices?
    private var fixture: GameCenterPartyPreview?
    private weak var displayWorld: World?
    private weak var displayRenderer: SpriteRenderer?
    private var displayed: [NetworkEntityID: Entity] = [:]
    private var displayCamera: Entity?
    private var displaySize = CGSize(width: 402, height: 260)
    private var interest: NetworkSpatialInterest?
    private var hostMovements: [NetworkMovementController2D] = []
    private var hostInteractions: [NetworkInteractionController2D] = []
    private var movement: NetworkMovementController2D?
    private var interaction: NetworkInteractionController2D?
    private var visual: Entity?
    private var subscriptions: [EventSubscription] = []
    private var operation: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var held = SIMD2<Float>.zero
    private var facing = SIMD2<Float>(1, 0)
    private var remaining = 120.0
    private var elapsed = 0.0
    private var hostBeamCooldown = 0.0
    private var partnerBeamCooldown = 0.0
    private var checkpoint: NetworkRecoveryCheckpoint?
    private var approved: NetworkRecoveryDescriptor?
    private let rules = KinematicMovement2D(maximumSpeed: 150, bounds: .init(center: .zero, size: [660, 440]))
    private let hitRules = NetworkInteractionRules2D(rayRange: 300, interactionRange: 70)
    private static let route = "dev.spriteui.demobots.coop"
    private static let compatibility = "demobots-coop-v1"
    private var allServices: [GameCenterServices] { [services] + (partner.map { [$0] } ?? []) }
    private var hostServices: GameCenterServices? { allServices.first { service in guard let id = service.localPlayer?.id else { return false }; return id == service.party.hostPeerID } }
    private var hostSession: NetworkSession? { hostServices?.networkSession }
    private var hostWorld: World? { if hostServices === services { localWorld } else { partnerWorld } }

    /// Creates a stopped match. Neither mode authenticates or matches on construction/appearance.
    public init(preview: Bool = true, usesArtwork: Bool = true) {
        isPreview = preview; self.usesArtwork = usesArtwork
        services = preview ? .preview(player: .init(id: .init(rawValue: "coop-b"), displayName: "You")) : .init()
        if preview { partner = .preview(player: .init(id: .init(rawValue: "coop-a"), displayName: "Teammate")) }
        for service in allServices {
            try? service.activities.configureRoutes([Self.route])
            if preview { try? service.activities.configurePreview([.init(id: Self.route, title: "DemoBots co-op", supportsPartyCode: true)]) }
            service.party.recoveryConfiguration = .init(matchmakingTimeout: 15, resynchronizationTimeout: 10)
        }
    }
    isolated deinit { operation?.cancel(); for token in subscriptions { token.cancel() }; services.shutdown(); partner?.shutdown() }

    /// Attaches only local presentation. Network worlds remain independently advanced by advance(deltaTime:).
    public func buildDisplay(in content: GameViewContent) {
        displayWorld = content.world; displayRenderer = content.renderer; content.renderer.gravity = .zero
        content.add(Entity(name: "coop-floor", components: SpriteComponent(color: Color(red: 0.025, green: 0.12, blue: 0.1), size: [740, 540])))
        for x in stride(from: -350, through: 350, by: 50) {
            let line = Entity(components: SpriteComponent(color: .mint.opacity(0.12), size: [1, 500])); line.position = [Float(x), 0]; content.add(line)
        }
        for y in stride(from: -250, through: 250, by: 50) {
            let line = Entity(components: SpriteComponent(color: .mint.opacity(0.12), size: [700, 1])); line.position = [0, Float(y)]; content.add(line)
        }
        let camera = Entity(name: "coop-camera", components: CameraComponent(zoom: 0.6, smoothing: 0)); content.add(camera); displayCamera = camera; resizeDisplay(displaySize)
    }
    public func resizeDisplay(_ size: CGSize) { displaySize = size; displayCamera?.components[CameraComponent.self]?.zoom = Float(max(0.1, min(size.width / 740, size.height / 540))) }
    /// Starts a complete local party or a native configured activity party after explicit authentication.
    public func start() {
        run { [self] in
            clearRuntime(); allServices.forEach { $0.party.leave() }
            if isPreview {
                let fixture = try GameCenterPartyPreview(players: allServices.compactMap(\.localPlayer), latency: previewLatency, unreliableLossRate: previewLossRate, seed: 42); self.fixture = fixture; previewClock = 0
                for service in allServices { try service.party.configurePreview(fixture) }
            } else { guard services.isAuthenticated else { throw GameCenterServiceError.notAuthenticated } }
            for service in allServices {
                _ = try await service.activities.load()
                if service.activities.activity?.state == .active || service.activities.activity?.state == .paused { try service.activities.discard() }
                _ = try await service.activities.start(definitionID: Self.route, partyCode: partyCode)
            }
            try await matchBoth()
            checkpoint = nil; approved = nil; hasRecoveryPoint = false; remaining = 120; elapsed = 0; confirmedBeams = 0
            localWorld = World(); partnerWorld = isPreview ? World() : nil
            try prepareWorlds(recovery: nil)
            message = isPreview ? "Local party prepared. Waiting for the baseline and fresh action epochs." : "Prepared. Wait for the other player; the host starts when both are ready."
            if isPreview { try await readyAndStart() }
        }
    }
    /// Explicitly accepts a queued configured co-op invitation; never replaces an active round automatically.
    public func acceptInvitation(_ requestID: UUID) {
        guard !isPreview, !services.party.isActive else { return }
        run { [self] in
            guard let request = services.activities.pendingRequests.first(where: { $0.id == requestID }), request.activity.definitionID == Self.route else { throw GameCenterServiceError.invalidData }
            _ = try services.activities.accept(request: requestID)
            try await services.party.findMatch(); try Task.checkCancellation()
            clearRuntime(); localWorld = World(); partnerWorld = nil; remaining = 120; elapsed = 0; finished = false
            checkpoint = nil; approved = nil; hasRecoveryPoint = false
            try prepareWorlds(recovery: nil)
            message = "Invitation accepted and world prepared. The host starts after both players ready."
        }
    }
    /// Explicit host launch for a native party; readiness is prepared separately on each device.
    public func startPreparedRound() { do { try services.party.startSession() } catch { message = error.localizedDescription } }
    private func matchBoth() async throws {
        if let partner {
            async let a: Void = services.party.findMatch(); async let b: Void = partner.party.findMatch(); _ = try await (a, b)
        } else { try await services.party.findMatch() }
        try Task.checkCancellation()
    }
    private func world(for service: GameCenterServices) -> World { service === services ? localWorld : partnerWorld! }
    private func schema() throws -> NetworkReplicationSchema {
        var schema = NetworkReplicationSchema()
        try schema.register(CoopActor.self, named: "coop-actor-v1") { value in guard (0...100).contains(value.corruption) else { throw NetworkSessionError.invalidState } }
        try schema.register(CoopRound.self, named: "coop-round-v1") { value in
            guard value.total == 4, (0...4).contains(value.cured), (0...120).contains(value.seconds), value.finished == (value.cured == 4 || value.seconds == 0) else { throw NetworkSessionError.invalidState }
        }
        return schema
    }
    private func prepareWorlds(recovery: NetworkRecoveryDescriptor?) throws {
        for service in allServices {
            guard service.party.members.count == 2 else { throw GameCenterServiceError.invalidData }
            let world = world(for: service); world.fixedStep = .init()
            let isHost = service.localPlayer?.id == service.party.hostPeerID
            var policy = NetworkReplicationPolicy.all
            if isHost {
                let interest = try NetworkSpatialInterest(world: world, radius: 450, exitMargin: 50); self.interest = interest; policy = interest.policy
                if recovery == nil { populate(world, players: service.party.members.map(\.peer)) }
                world.root.components.set(CoopRuntime(game: self)); try world.systems.add(CoopRulesSystem.self)
            }
            if let recovery {
                try service.party.prepareRecovery(in: world, accepting: recovery, compatibilityID: Self.compatibility, schema: schema(),
                    replicationPolicy: policy, replicationBudget: isHost ? .init(bytesPerSecond: 12_000) : nil)
            } else {
                try service.party.prepare(in: world, compatibilityID: Self.compatibility, schema: schema(),
                    replicationPolicy: policy, replicationBudget: isHost ? .init(bytesPerSecond: 12_000) : nil)
            }
            if isHost { rebuildHostProxies(in: world); try updateObservers(in: world) }
            try service.party.setReady(true)
        }
    }
    private func populate(_ world: World, players: [NetworkPeer]) {
        for (index, peer) in players.sorted(by: { $0.id < $1.id }).enumerated() {
            let player = Entity(name: "player-\(index)", components: CoopActor(kind: .player, corruption: 0), SynchronizationComponent(owner: peer.id, components: ["transform", "coop-actor-v1"]))
            player.position = [-230, index == 0 ? 90 : -90]; world.addEntity(player)
        }
        for index in 0..<4 {
            let bot = Entity(name: "bot-\(index)", components: CoopActor(kind: .bot, corruption: 100), SynchronizationComponent(components: ["transform", "coop-actor-v1"]))
            bot.position = [Float(index % 2) * 150, Float(index / 2) * 190 - 95]; world.addEntity(bot)
        }
        world.addEntity(Entity(name: "round", components: CoopRound(), SynchronizationComponent(components: ["coop-round-v1"])))
    }
    private func rebuildHostProxies(in world: World) {
        for entity in world.entities {
            if let actor = entity.components[CoopActor.self] {
                entity.components.set(NetworkInteractionBodyComponent(shape: .circle(radius: actor.kind == .player ? 14 : 20), isTarget: actor.kind == .bot && actor.corruption > 0, blocksRays: actor.kind == .bot && actor.corruption > 0))
                entity.components.set(NetworkInterestComponent(priority: actor.kind == .player ? .critical : .normal))
            } else if entity.components.has(CoopRound.self) { entity.components.set(NetworkInterestComponent(isAlwaysRelevant: true, priority: .critical)) }
        }
    }
    private func updateObservers(in world: World) throws {
        for player in world.entities where player.components[CoopActor.self]?.kind == .player {
            if let owner = player.components[SynchronizationComponent.self]?.owner { try interest?.setObserver(at: player.position, for: owner) }
        }
    }
    private func readyAndStart() async throws {
        guard let hostServices else { throw GameCenterServiceError.notFound }
        try await pumpPreview { hostServices.party.canStart }
        try hostServices.party.startSession()
    }
    // Preparation progresses a controlled clock instead of assuming zero-latency packet delivery.
    private func pumpPreview(until ready: () -> Bool) async throws {
        for _ in 0..<900 {
            try Task.checkCancellation()
            if ready() { return }
            advance(deltaTime: 1.0 / 60)
            await Task.yield()
        }
        throw GameCenterServiceError.timedOut
    }
    /// Advances each headless world exactly once; the display's GameView advances its separate local presentation world.
    public func advance(deltaTime: TimeInterval) {
        guard deltaTime.isFinite, deltaTime >= 0, deltaTime <= 0.25 else { return }
        previewClock += deltaTime
        let baseDelay = previewLatency.isFinite ? min(0.5, max(0, previewLatency)) : 0
        fixture?.latency = baseDelay * (previewJitter ? 1 + 0.5 * sin(previewClock * 7) : 1)
        fixture?.unreliableLossRate = previewLossRate
        fixture?.advance(by: deltaTime)
        previewPendingPackets = fixture?.pendingMessageCount ?? 0; previewPendingBytes = fixture?.pendingByteCount ?? 0
        if let partnerWorld { partnerWorld.update(deltaTime: deltaTime) }; localWorld.update(deltaTime: deltaTime)
        guard !busy else { return }
        do {
            let states = allServices.map { $0.party.state }
            if allServices.contains(where: { $0.networkSession?.state == .failed || $0.networkSession?.state == .stopped }) { throw NetworkSessionError.notConnected }
            if states.allSatisfy({ $0 == .playing }) {
                try attachControllers()
                let round = localWorld.entities.compactMap { $0.components[CoopRound.self] }.first
                if let round { cured = round.cured; score = round.cured * 100; secondsLeft = round.seconds; finished = round.finished }
                phase = finished ? (cured == 4 ? "won" : "lost") : "playing"
                if isPreview, previewPartnerFires, let hostWorld, let hostID = hostServices?.localPlayer?.id, partnerBeamCooldown <= 0 {
                    try fireOnHost(in: hostWorld, owner: hostID); partnerBeamCooldown = 0.7
                }
            } else if states.contains(.interrupted) || states.contains(.failed) {
                stopControllers(); held = .zero; phase = "interrupted"; message = "Connection interrupted. Rejoin the approved round explicitly, or leave."
            } else { phase = states.first == .idle ? "menu" : states.first?.rawValue ?? "menu" }
            syncDisplay()
        } catch { stopControllers(); held = .zero; phase = "failed"; message = error.localizedDescription }
    }
    private func attachControllers() throws {
        guard let hostSession, let hostWorld else {
            // A native client sees only its own service and cannot access the remote host world.
            try attachLocalClient(); return
        }
        if hostMovements.isEmpty {
            for actor in hostWorld.entities where actor.components[CoopActor.self]?.kind == .player {
                guard let owner = actor.components[SynchronizationComponent.self]?.owner, owner != hostSession.localPeer.id else { continue }
                hostMovements.append(try .host(in: hostWorld, session: hostSession, entity: actor, rules: rules))
                hostInteractions.append(try .host(in: hostWorld, session: hostSession, entity: actor, rules: hitRules, configuration: .init(cooldown: 0.35), validateAction: { [weak self] _, _ in
                    guard let self, self.hostWorld?.entities.first(where: { $0.components.has(CoopRound.self) })?.components[CoopRound.self]?.finished == false else { throw NetworkInteractionRejection.invalidIntent }
                }))
            }
            subscriptions.append(hostWorld.subscribe(to: NetworkInteractionEvents.Resolved.self) { [weak self] event in
                guard event.isAuthority, case .accepted(let outcome) = event.result.resolution, outcome.kind == .hit, let id = outcome.contact?.id else { return }
                self?.cure(id, in: hostWorld)
            })
        }
        try attachLocalClient()
        for controller in hostMovements + (movement.map { [$0] } ?? []) where controller.status == .failed { throw NetworkSessionError.transport(controller.lastError ?? "Movement failed") }
        for controller in hostInteractions + (interaction.map { [$0] } ?? []) where controller.status == .failed { throw NetworkSessionError.transport(controller.lastError ?? "Interaction failed") }
    }
    private func attachLocalClient() throws {
        guard let session = services.networkSession, !session.isHost, session.state == .connected,
              let owner = services.localPlayer?.id,
              let actor = localWorld.entities.first(where: { $0.components[SynchronizationComponent.self]?.owner == owner }) else { return }
        if movement == nil {
            let visual = Entity(name: "local-predicted-player"); localWorld.addEntity(visual); self.visual = visual
            let id = actor.components[SynchronizationComponent.self]!.id
            movement = try .client(in: localWorld, session: session, entityID: id, visual: visual, rules: rules)
            interaction = try .client(in: localWorld, session: session, entityID: id, rules: hitRules, configuration: .init(cooldown: 0.35))
            subscriptions.append(localWorld.subscribe(to: NetworkInteractionEvents.Predicted.self) { [weak self] event in
                guard let self, case .ray(let direction) = event.command.intent,
                      let origin = self.interaction?.latestView?.state.bodies.first(where: { $0.id == event.entityID })?.position else { return }
                self.drawBeam(from: origin, to: origin + direction * self.hitRules.rayRange)
            })
            subscriptions.append(localWorld.subscribe(to: NetworkInteractionEvents.Resolved.self) { [weak self] event in
                guard !event.isAuthority else { return }; self?.confirmedBeams += 1
                if case .rejected(let reason) = event.result.resolution { self?.message = "Beam refused: \(reason.rawValue)" }
                if case .accepted(let outcome) = event.result.resolution {
                    self?.message = "Beam confirmed: \(outcome.kind.rawValue)."
                    if outcome.kind == .hit, let contact = outcome.contact { self?.confirmedEffect(at: contact.position) }
                }
            })
        }
        if movement?.status == .running { try movement?.setInput(canControl ? held : .zero) }
        pendingActions = interaction?.pendingActionCount ?? 0; corrections = movement?.correctionCount ?? 0
    }
    fileprivate func simulateHost(in world: World, dt: TimeInterval) {
        guard hostServices?.party.state == .playing, !busy, world.entities.first(where: { $0.components.has(CoopRound.self) })?.components[CoopRound.self]?.finished == false else { return }
        remaining = max(0, remaining - dt); elapsed += dt; hostBeamCooldown = max(0, hostBeamCooldown - dt); partnerBeamCooldown = max(0, partnerBeamCooldown - dt)
        let localHost = services.networkSession?.isHost == true
        if let hostID = hostServices?.localPlayer?.id, let player = world.entities.first(where: { $0.components[SynchronizationComponent.self]?.owner == hostID }) {
            let direction: SIMD2<Float> = localHost ? held : previewPartnerMoves ? [Float(sin(elapsed * 0.8)) * 0.6, 0] : .zero
            if let next = try? rules.step(.init(position: player.position), direction: direction, deltaTime: dt) { player.position = next.position }
        }
        for (index, bot) in world.entities.filter({ $0.components[CoopActor.self]?.kind == .bot }).sorted(by: { $0.name < $1.name }).enumerated() where bot.components[CoopActor.self]!.corruption > 0 {
            bot.position.y = Float(index / 2) * 190 - 95 + Float(sin(elapsed * 0.7 + Double(index))) * 30
        }
        if let roundEntity = world.entities.first(where: { $0.components.has(CoopRound.self) }), var round = roundEntity.components[CoopRound.self] {
            round.seconds = Int(ceil(remaining)); round.finished = round.cured == 4 || remaining == 0
            if roundEntity.components[CoopRound.self]?.seconds != round.seconds || roundEntity.components[CoopRound.self]?.finished != round.finished { roundEntity.components.set(round) }
        }
        try? updateObservers(in: world)
    }
    /// Sets held movement; callers clear it on release, interruption, or focus loss.
    public func move(_ direction: SIMD2<Float>) {
        do { try rules.validate(direction: direction); held = canControl ? direction : .zero; if simd_length_squared(held) > 0.01 { facing = simd_normalize(held) } }
        catch { message = error.localizedDescription }
    }
    /// Fires an assisted beam from the exact issued view, falling back to facing when no target is in range.
    public func fire() {
        guard canControl else { return }
        do {
            if let interaction, interaction.status == .running, let view = interaction.latestView {
                let id = interaction.entityID; let direction = aim(in: view.state, source: id)
                try interaction.perform(.ray(direction: direction)); message = "Beam predicted; waiting for host confirmation."
            } else if services.networkSession?.isHost == true, let world = hostWorld, let owner = services.localPlayer?.id { try fireOnHost(in: world, owner: owner) }
        } catch { message = error.localizedDescription }
    }
    private func aim(in scene: NetworkInteractionScene2D, source: NetworkEntityID) -> SIMD2<Float> {
        guard let origin = scene.bodies.first(where: { $0.id == source })?.position else { return facing }
        let target = scene.bodies.filter { $0.id != source && $0.isTarget && simd_distance($0.position, origin) <= hitRules.rayRange }.sorted { simd_distance_squared($0.position, origin) < simd_distance_squared($1.position, origin) }.first
        guard let target, simd_distance_squared(target.position, origin) > 0.001 else { return facing }
        return simd_normalize(target.position - origin)
    }
    private func fireOnHost(in world: World, owner: NetworkPeerID) throws {
        guard let source = world.entities.first(where: { $0.components[SynchronizationComponent.self]?.owner == owner }),
              let sourceID = source.components[SynchronizationComponent.self]?.id else { return }
        if services.localPlayer?.id == owner { guard hostBeamCooldown <= 0 else { return }; hostBeamCooldown = 0.35 }
        let bodies = world.entities.compactMap { entity -> HistoricalCollisionBody2D<NetworkEntityID>? in
            guard let marker = entity.components[NetworkInteractionBodyComponent.self], let sync = entity.components[SynchronizationComponent.self] else { return nil }
            return .init(id: sync.id, incarnation: marker.incarnation, shape: marker.shape, position: entity.position, isTarget: marker.isTarget, blocksRays: marker.blocksRays)
        }
        let scene = NetworkInteractionScene2D(bodies: bodies)
        let direction = aim(in: scene, source: sourceID)
        if services.localPlayer?.id == owner { drawBeam(from: source.position, to: source.position + direction * hitRules.rayRange) }
        if let hit = try scene.raycast(from: sourceID, direction: direction, range: hitRules.rayRange), hit.isTarget {
            cure(hit.id, in: world)
            if services.localPlayer?.id == owner { confirmedEffect(at: hit.position) }
        }
    }
    private func cure(_ id: NetworkEntityID, in world: World) {
        guard world.entities.first(where: { $0.components.has(CoopRound.self) })?.components[CoopRound.self]?.finished == false, let bot = hostSession?.entity(withNetworkID: id), var state = bot.components[CoopActor.self], state.kind == .bot, state.corruption > 0 else { return }
        state.corruption = max(0, state.corruption - 50); bot.components.set(state)
        if state.corruption == 0 {
            bot.components[NetworkInteractionBodyComponent.self]?.isTarget = false; bot.components[NetworkInteractionBodyComponent.self]?.blocksRays = false
            if let entity = world.entities.first(where: { $0.components.has(CoopRound.self) }), var round = entity.components[CoopRound.self] {
                round.cured += 1; round.finished = round.cured == 4 || round.seconds == 0; entity.components.set(round)
            }
        }
    }
    private func drawBeam(from start: SIMD2<Float>, to end: SIMD2<Float>) {
        guard let displayWorld else { return }
        let delta = end - start
        let beam = Entity(name: "coop-beam", components: SpriteComponent(color: .cyan, size: [simd_length(delta), 3]), LifetimeComponent(0.12))
        beam.position = (start + end) / 2; beam.transform.rotation = atan2(delta.y, delta.x); beam.transform.zPosition = 5; displayWorld.addEntity(beam)
    }
    private func confirmedEffect(at position: SIMD2<Float>) {
        displayWorld?.addEntity(.oneShot(particles: .puff(color: .mint), count: 12, sound: AudioComponent(named: "cure.wav", bundle: .module), at: position))
    }
    /// Saves one approved host checkpoint on an explicit action. No old score or pending effects are replayed automatically.
    public func saveRecoveryPoint() {
        do {
            guard let hostServices else { throw NetworkSessionError.notHost }
            let checkpoint = try hostServices.party.recoveryCheckpoint(applicationState: JSONEncoder().encode(CoopRecovery(version: 1, remaining: remaining)))
            try checkpoint.write(to: recoveryURL()); self.checkpoint = checkpoint; approved = checkpoint.descriptor; hasRecoveryPoint = true
            message = "Host recovery point saved. Interrupt, then explicitly rejoin and resume it."
        } catch { message = error.localizedDescription }
    }
    private func recoveryURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("DemoBotsCoop", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true); return base.appendingPathComponent("approved-round.json")
    }
    /// Stops input/controllers and interrupts the current party. No foreground retry is implied.
    public func interrupt() {
        operation?.cancel(); generation &+= 1; busy = false; held = .zero; stopControllers()
        services.party.interrupt(); partner?.party.interrupt(); phase = "interrupted"; message = "Interrupted. Rejoin explicitly or leave."
    }
    /// Matches the original activity/roster again, offers the host-approved checkpoint, and explicitly prepares fresh worlds.
    public func rejoinSavedRound() {
        run { [self] in
            stopControllers(); held = .zero
            let saved: NetworkRecoveryCheckpoint?
            if isPreview || services.localPlayer?.id == approved?.hostPeerID {
                let file = try NetworkRecoveryCheckpoint(contentsOf: recoveryURL())
                guard file.descriptor == approved else { throw NetworkRecoveryError.incompatibleCheckpoint }; saved = file
            } else { saved = nil }
            try await matchBoth()
            if let saved, let hostServices { try hostServices.party.offerRecovery(saved); checkpoint = saved }
            if isPreview { try await pumpPreview { self.services.party.recoveryOffer != nil } }
            guard let descriptor = services.party.recoveryOffer else { message = "Fresh party matched. Accept the host's recovery offer when it arrives."; return }
            try await prepareRecovery(descriptor)
        }
    }
    /// Native clients explicitly accept the current offered descriptor after validating the game's compatibility ID.
    public func acceptRecoveryOffer() {
        run { [self] in
            guard let descriptor = services.party.recoveryOffer else { throw NetworkRecoveryError.invalidCheckpoint }
            try await prepareRecovery(descriptor)
        }
    }
    private func prepareRecovery(_ descriptor: NetworkRecoveryDescriptor) async throws {
        guard descriptor.compatibilityID == Self.compatibility else { throw NetworkRecoveryError.incompatibleCheckpoint }
        if let checkpoint {
            let payload = try JSONDecoder().decode(CoopRecovery.self, from: checkpoint.applicationState)
            guard payload.version == 1, payload.remaining.isFinite, (0...120).contains(payload.remaining) else { throw NetworkRecoveryError.invalidCheckpoint }
            remaining = payload.remaining; elapsed = 120 - payload.remaining
        }
        clearRuntime(); localWorld = World(); partnerWorld = isPreview ? World() : nil; finished = false
        try prepareWorlds(recovery: descriptor)
        if isPreview { try await readyAndStart() }
        message = "Approved round prepared. Wait for every returning baseline before input resumes."
    }
    private func stopControllers() {
        hostMovements.forEach { $0.stop() }; hostInteractions.forEach { $0.stop() }; movement?.stop(); interaction?.stop()
        hostMovements = []; hostInteractions = []; movement = nil; interaction = nil
        for token in subscriptions { token.cancel() }; subscriptions = []; pendingActions = 0
    }
    private func clearRuntime() { stopControllers(); interest?.removeAllObservers(); interest = nil; visual = nil; held = .zero; facing = [1, 0]; hostBeamCooldown = 0; partnerBeamCooldown = 0 }
    /// Returns to the co-op menu and releases coordinators. It never changes the separate campaign save.
    public func leave() { operation?.cancel(); operation = nil; generation &+= 1; busy = false; clearRuntime(); services.shutdown(); partner?.shutdown(); fixture = nil; previewPendingPackets = 0; previewPendingBytes = 0; phase = "menu"; message = "Co-op stopped. Start explicitly." }
    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; generation &+= 1; let token = generation
        operation = Task { @MainActor [weak self] in
            do { try Task.checkCancellation(); guard self?.generation == token else { return }; try await work(); try Task.checkCancellation() }
            catch { if self?.generation == token { self?.message = error.localizedDescription; self?.phase = "failed" } }
            if self?.generation == token { self?.busy = false; self?.operation = nil }
        }
    }
    private func syncDisplay() {
        guard let displayWorld else { return }
        let entities = localWorld.entities.filter { $0.components.has(CoopActor.self) }
        let keep = Set(entities.compactMap { $0.components[SynchronizationComponent.self]?.id })
        for id in Array(displayed.keys) where !keep.contains(id) { displayed.removeValue(forKey: id)?.removeFromParent() }
        for entity in entities {
            guard let id = entity.components[SynchronizationComponent.self]?.id, let state = entity.components[CoopActor.self] else { continue }
            let color: Color = state.kind == .player ? .cyan : state.corruption > 0 ? .orange : .mint
            let art = state.kind == .player ? "PlayerBotIdle" : state.corruption > 0 ? "GroundBotBadWalk" : "GroundBotGoodWalk"
            let frame = DemoBotsResources.animations[art]?["0"]?.first
            if displayed[id] == nil {
                let sprite = usesArtwork && frame != nil ? SpriteComponent(imageName: frame!, size: [50, 50]) : SpriteComponent(color: color, size: [28, 28])
                let visual = Entity(name: entity.name, components: sprite); displayWorld.addEntity(visual); displayed[id] = visual
            }
            let isLocal = entity.components[SynchronizationComponent.self]?.owner == services.localPlayer?.id
            let position = isLocal ? (visual?.position ?? entity.position) : entity.position
            if displayed[id]?.position != position { displayed[id]?.position = position }
            if usesArtwork, let frame {
                if displayed[id]?.components[SpriteComponent.self]?.imageName != frame { displayed[id]?.components[SpriteComponent.self]?.imageName = frame }
            } else if displayed[id]?.components[SpriteComponent.self]?.color != color { displayed[id]?.components[SpriteComponent.self]?.color = color }
        }
    }
}
