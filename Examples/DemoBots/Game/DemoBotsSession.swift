import Foundation
import Observation
import SpriteUI
import SwiftUI
import simd

/// Owns one match. The view supplies input; SpriteUI systems simulate the ECS.
@MainActor @Observable
public final class DemoBotsSession {
    public private(set) var phase: DemoBotsPhase = .home
    public internal(set) var levelNumber = 1
    public private(set) var secondsLeft = 180
    public private(set) var badBots = 0
    public private(set) var totalBots = 0
    public private(set) var charge: Float = 100
    public private(set) var beamFraction: Float = 1
    public private(set) var isRecharging = false
    public internal(set) var message = ""
    public var showsPaths = false
    public var soundEnabled = true
    /// Scene tools suppress player input without putting match logic into its
    /// pause-menu phase, so SpriteUI's debugger can advance a complete match frame.
    public private(set) var isInspecting = false
    var botStatuses: [Entity.ID: BotStatus] = [:]
    public internal(set) var hasCheckpoint = false
    public internal(set) var checkpointMessage = ""
    public private(set) var mapDots: [MapDot] = []
    public internal(set) var mapBounds = SIMD4<Float>(128, -1064, 1248, 1704)

    public struct MapDot: Identifiable {
        public let id: Entity.ID
        public let position: SIMD2<Float>
        public let bad: Bool
        public let player: Bool
    }

    @ObservationIgnored var world: World?
    @ObservationIgnored var renderer: SpriteRenderer?
    @ObservationIgnored var player: Entity?
    @ObservationIgnored var bots: [Entity] = []
    @ObservationIgnored var navigation: BotNavigation?
    @ObservationIgnored var camera: Entity?
    @ObservationIgnored var beamLines: [Entity] = []
    @ObservationIgnored var pathLines: [Entity] = []
    @ObservationIgnored var effects: DemoBotsEffects?
    @ObservationIgnored var targetReticle: Entity?
    @ObservationIgnored private var levelPrefabs: [Int: PrefabResource] = [:]
    @ObservationIgnored var moveInput = SIMD2<Float>.zero
    @ObservationIgnored var aimInput = SIMD2<Float>.zero
    @ObservationIgnored var isFiring = false
    @ObservationIgnored var destination: SIMD2<Float>?
    @ObservationIgnored var playerRoute: [SIMD2<Float>] = []
    @ObservationIgnored var playerCharge = PlayerCharge()
    @ObservationIgnored var beam = DebugBeam()
    @ObservationIgnored var remainingTime: Double = 180
    @ObservationIgnored var hudDelay: Float = 0
    @ObservationIgnored var effectDelay: Float = 0
    @ObservationIgnored var elapsed: Float = 0
    @ObservationIgnored var viewSize = CGSize(width: 402, height: 874)

    public private(set) var isLoadingResources = false
    @ObservationIgnored private var clips: [String: AnimationResource] = [:]
    @ObservationIgnored private var activeClips: [Entity.ID: String] = [:]
    @ObservationIgnored private var cureSound: AudioResource?
    @ObservationIgnored private let resourceLibrary = ResourceLibrary()
    private struct InspectionState {
        let phase: DemoBotsPhase
        let wasPaused: Bool
        let timeScale: Double
    }
    @ObservationIgnored private var inspectionState: InspectionState?

    /// Preloads the app's asset catalog once; tests can still load editor scenes
    /// without a GPU or the application asset catalog.
    public func prepareResources() async {
        guard clips.isEmpty, !isLoadingResources else { return }
        isLoadingResources = true
        defer { isLoadingResources = false }
        do {
            let frames = DemoBotsResources.animations.values.flatMap { $0.values.flatMap { $0 } }
            let atlas = try await resourceLibrary.atlas(named: "DemoBots", textureNames: frames)
            var prepared: [String: AnimationResource] = [:]
            for (prefix, directions) in DemoBotsResources.animations {
                for (direction, frames) in directions {
                    let key = "\(prefix):\(direction)"
                    prepared[key] = try atlas.animation(named: key, frames: frames, framesPerSecond: 12)
                }
            }
            cureSound = try await resourceLibrary.audio(named: "cure.wav", in: .module)
            clips = prepared
        } catch { message = "Couldn’t load animation resources: \(error.localizedDescription)" }
    }

    public init() { refreshCheckpointAvailability() }

    public func build(in content: GameViewContent) {
        attach(to: content.world)
        renderer = content.renderer
        content.scene.physics.gravity = .zero
    }

    func attach(to world: World) {
        self.world = world
        world.isPaused = true
        world.root.components.set(DemoBotsRuntime(game: self))
        world.addSystem(DemoBotsLogicSystem.self)
        world.addSystem(SteeringSystem.self)
        world.addSystem(DemoBotsMovementSystem.self)
        world.addSystem(DemoBotsPresentationSystem.self)
        world.addSystem(PlaybackSystem.self)
        world.addSystem(SpatialIndexSystem.self)
        world.addSystem(LifetimeSystem.self)
    }

    public func start(level number: Int = 1) {
        guard let world else { message = "The game is still loading."; return }
        world.isPaused = true
        if let saved = discardInspection() { world.timeScale = saved.timeScale }
        moveInput = .zero; aimInput = .zero; isFiring = false
        destination = nil; playerRoute = []; beam = DebugBeam(); playerCharge = PlayerCharge()
        for entity in world.entities { entity.removeFromParent() }
        bots = []; player = nil; camera = nil; beamLines = []; pathLines = []; activeClips = [:]
        levelNumber = min(max(number, 1), 3)
        do {
            let config = try BotLevelConfiguration.load(levelNumber)
            let level = try loadLevel(levelNumber)
            world.addEntity(level)
            let box: BoundingBox
            switch levelNumber {
            case 1: box = BoundingBox(min: [128, -1064], max: [1376, 640])
            case 2: box = BoundingBox(min: [64, -1152], max: [2848, 1056])
            default: box = BoundingBox(min: [128, -1280], max: [2048, 640])
            }
            navigation = BotNavigation(bounds: box, obstacles: world.polygonObstacles)
            let boundary = Entity(name: "movement-boundary", components: CollisionComponent(shape: .edgeLoop(rectangle: box.size), filter: .init(group: BotCollisionGroups.walls)))
            boundary.position = box.center; world.addEntity(boundary)
            mapBounds = [box.min.x, box.min.y, box.size.x, box.size.y]
            let backdrop = Entity(name: "circuit-backdrop", components: SpriteComponent(color: Color(red: 0.025, green: 0.07, blue: 0.09), size: [20000, 20000]))
            backdrop.transform.zPosition = -200
            world.addEntity(backdrop)
            let spawn = level.findEntity(named: "transporter_coordinate")?.scenePosition ?? box.center
            let hero = makeBot(kind: .player, at: spawn, heading: DemoBotsResources.heading(config.initialPlayerBotOrientation))
            hero.name = "PlayerBot"
            hero.enter(BotMode.active)
            player = hero
            for (index, configuration) in config.taskBotConfigurations.enumerated() {
                let good = configuration.goodPathNodeNames.compactMap { level.findEntity(named: $0)?.scenePosition }
                let bad = configuration.badPathNodeNames.compactMap { level.findEntity(named: $0)?.scenePosition }
                guard !good.isEmpty, !bad.isEmpty else { throw CocoaError(.coderReadCorrupt) }
                let patrol = configuration.startsBad ? bad : good
                let bot = makeBot(kind: configuration.locomotion, at: patrol[0], heading: DemoBotsResources.heading(configuration.initialOrientation))
                bot.name = "\(configuration.locomotion.rawValue)-\(index)"
                var data = bot.components[BotComponent.self]!
                data.isBad = configuration.startsBad; data.corruption = configuration.startsBad ? 100 : 0
                data.goodPatrol = good; data.badPatrol = bad; data.patrol = patrol
                data.waypoint = patrol.count > 1 ? 1 : 0
                data.decisionDelay = Float(index) * 0.035
                bot.components.set(data)
                bot.enter(BotMode.patrol)
                bots.append(bot)
            }
            let camera = Entity(name: "camera", components: CameraComponent(
                target: .entity(hero.id), zoom: preferredZoom, smoothing: 0.12,
                bounds: cameraBounds(for: box), maxShake: 12
            ))
            camera.position = spawn
            world.addEntity(camera); self.camera = camera
            resetPresentation()
            totalBots = bots.count
            remainingTime = config.timeLimit; elapsed = 0; hudDelay = 0; effectDelay = 0
            world.isPaused = false
            phase = .playing; message = "Cure every corrupted bot"
            refreshHUD()
        } catch {
            phase = .home
            message = "Couldn’t load Level \(levelNumber): \(error.localizedDescription)"
        }
    }

    func loadLevel(_ number: Int) throws -> Entity {
        if let prefab = levelPrefabs[number] { return prefab.instantiate() }
        let levelURL = try DemoBotsResources.url("Level\(number)", extension: "sks")
        let level = try SceneLoader().load(contentsOf: levelURL)
        // The original editor scenes use uncentered coordinates; their patrol
        // markers and obstacle locations are expressed in that same space.
        level.position = .zero
        level.visit { entity in entity.components.remove(PhysicsBodyComponent.self) }
        for (name, z): (String, Float) in [("board", -100), ("shadows", -50), ("obstacles", -25), ("characters", 0), ("above_characters", 1000), ("top", 1100)] {
            level.findEntity(named: name)?.transform.zPosition = z
        }
        if let obstacleLayer = level.findEntity(named: "obstacles") {
            for entity in obstacleLayer.children {
                guard let sprite = entity.components[SpriteComponent.self], let size = sprite.size else { continue }
                entity.components.set(PolygonObstacleComponent(rectangle: size))
                entity.components.set(CollisionComponent(shape: .rectangle(size: size), filter: .init(group: BotCollisionGroups.walls)))
                if sprite.imageName == nil { entity.components[SpriteComponent.self]?.opacity = 0 }
            }
        }
        let prefab = PrefabResource(root: level, name: "Level\(number)")
        levelPrefabs[number] = prefab
        return prefab.instantiate()
    }

    /// Runtime callbacks and cosmetic leases belong to the current world, not
    /// to a checkpoint. Rebind them after the SDK restores persistent entities.
    func finishRestoringCheckpoint() {
        if let saved = discardInspection() { world?.timeScale = saved.timeScale }
        world?.isPaused = true
        phase = .paused
        moveInput = .zero; aimInput = .zero; isFiring = false
        destination = nil; playerRoute = []
        totalBots = bots.count
        resetPresentation()
        for entity in [player].compactMap({ $0 }) + bots {
            if let info = entity.components[BotComponent.self] {
                let velocity = entity.components[SteeringComponent.self]?.velocity ?? .zero
                updateLook(entity, info: info, moving: simd_length_squared(velocity) > 1)
            }
        }
        refreshHUD()
    }

    var preferredZoom: Float { viewSize.width > viewSize.height ? 0.9 : 0.62 }
    func cameraBounds(for box: BoundingBox) -> CameraComponent.Bounds {
        // Let the camera see past the board edge so a corner spawn stays clear
        // of the HUD and thumbsticks instead of pinning the hero underneath them.
        let viewport = SIMD2(Float(viewSize.width), Float(viewSize.height)) / preferredZoom
        let margin = simd_max(viewport / 2 - SIMD2(repeating: 80), .zero)
        return .init(min: box.min - margin, max: box.max + margin)
    }
    public func resize(_ size: CGSize) {
        viewSize = size
        camera?.components[CameraComponent.self]?.zoom = preferredZoom
        if let navigation { camera?.components[CameraComponent.self]?.bounds = cameraBounds(for: navigation.bounds) }
    }
    public func move(_ direction: SIMD2<Float>) {
        guard phase == .playing, !isInspecting else { return }
        moveInput = simd_length(direction) > 1 ? simd_normalize(direction) : direction
        if simd_length_squared(direction) > 0.01 { destination = nil; playerRoute = [] }
    }
    public func aim(_ direction: SIMD2<Float>, firing: Bool) {
        guard phase == .playing, !isInspecting else { isFiring = false; return }
        aimInput = direction; isFiring = firing
    }
    public func sendPlayer(toView point: CGPoint) {
        guard phase == .playing, !isInspecting, let renderer, let player, let navigation else { return }
        let goal = renderer.scenePoint(fromView: point)
        guard navigation.isWalkable(goal), recoverNavigationStart(player, navigation: navigation) else { return }
        destination = goal
        playerRoute = navigation.path(from: player.position, to: goal)
    }
    public func pause() {
        if let saved = discardInspection() {
            world?.isPaused = true
            world?.timeScale = saved.timeScale
        }
        guard phase == .playing else { return }
        phase = .paused; world?.isPaused = true; stopMotion()
    }
    public func resume() {
        if isInspecting { endInspection() }
        guard phase == .paused else { return }
        phase = .playing
        world?.isPaused = false
        for bot in bots { bot.components[BotComponent.self]?.decisionDelay = 0 }
    }
    public func home() {
        world?.isPaused = true
        if let saved = discardInspection() { world?.timeScale = saved.timeScale }
        phase = .home; world?.isPaused = true; stopMotion()
    }

    /// Opens scene tooling from gameplay or the pause menu. Pause is initially
    /// preserved in the world, while the match phase allows systems to run during
    /// a debug step or an explicit Resume in the tools. Bot steering is retained.
    public func beginInspection() {
        guard !isInspecting, !isLoadingResources, phase == .playing || phase == .paused, let world else { return }
        inspectionState = InspectionState(phase: phase, wasPaused: world.isPaused, timeScale: world.timeScale)
        world.isPaused = true
        isInspecting = true; phase = .playing
        clearPlayerInput()
        for bot in bots { bot.components[BotComponent.self]?.decisionDelay = 0 }
    }

    /// Closes tools without carrying held input or debugger speed changes into
    /// gameplay. A won/lost match remains terminal even if it ended in the tools.
    public func endInspection() {
        guard let saved = discardInspection() else { return }
        world?.isPaused = true
        world?.timeScale = saved.timeScale
        clearPlayerInput()
        if phase == .playing {
            phase = saved.phase
            world?.isPaused = saved.wasPaused
        }
    }

    private func discardInspection() -> InspectionState? {
        let saved = inspectionState
        // Cancel queued/priming steps synchronously. Waiting for SwiftUI to
        // detach on its next update could otherwise advance a paused match after Close.
        if saved != nil { renderer?.setDebugController(nil) }
        inspectionState = nil; isInspecting = false
        return saved
    }

    private func clearPlayerInput() {
        moveInput = .zero; aimInput = .zero; isFiring = false
        destination = nil; playerRoute = []
        player?.components[SteeringComponent.self]?.goals = []
        player?.components[SteeringComponent.self]?.velocity = .zero
        hideBeam()
    }
    func stopMotion() {
        moveInput = .zero; aimInput = .zero; isFiring = false
        for entity in bots + [player].compactMap({ $0 }) {
            entity.components[SteeringComponent.self]?.goals = []
            entity.components[SteeringComponent.self]?.velocity = .zero
        }
        hideBeam()
    }

    func makeBot(kind: BotKind, at point: SIMD2<Float>, heading: Float) -> Entity {
        let entity = BotPrefabs.make(kind: kind)
        entity.components.set(BotComponent(kind: kind, heading: heading, previousPosition: point))
        entity.position = point
        world?.addEntity(entity)
        return entity
    }

    func beforeSteering(deltaTime: Float) {
        guard phase == .playing, let player, let navigation else { return }
        let dt = max(deltaTime, 0)
        elapsed += dt; effectDelay = max(0, effectDelay - dt)
        remainingTime = max(0, remainingTime - Double(dt))
        playerCharge.advance(dt)
        if playerCharge.recharging { player.enter(BotMode.recharging) }
        else { player.enter(BotMode.active) }
        var data = player.components[BotComponent.self]!
        data.previousPosition = player.position
        data.hitFlash = max(0, data.hitFlash - dt)
        if simd_length_squared(aimInput) > 0.04 { data.heading = atan2(aimInput.y, aimInput.x) }
        else if isFiring, let target = nearestBad(to: player.position, range: 300, visible: true) {
            let delta = target.position - player.position
            data.heading = atan2(delta.y, delta.x)
        } else if simd_length_squared(moveInput) > 0.04 { data.heading = atan2(moveInput.y, moveInput.x) }
        player.components.set(data)
        var steering = player.components[SteeringComponent.self]!
        steering.maxSpeed = 210
        if playerCharge.recharging {
            steering.goals = [SteeringGoal(.reachSpeed(0))]
        } else if simd_length_squared(moveInput) > 0.01 {
            steering.maxSpeed = 210 * simd_length(moveInput)
            steering.goals = [SteeringGoal(.seek(.point(player.position + moveInput * 180)))]
        } else if destination != nil {
            advanceRoute(&playerRoute, from: player.scenePosition, navigation: navigation)
            if let next = playerRoute.first, playerRoute.count > 1 || simd_distance(next, player.scenePosition) > 10 {
                let goal: SteeringBehavior = playerRoute.count == 1 ? .arrive(.point(next), slowingRadius: 70) : .seek(.point(next))
                steering.goals = [SteeringGoal(goal)]
            } else { destination = nil; playerRoute = []; steering.goals = [SteeringGoal(.reachSpeed(0))] }
        } else { steering.goals = [SteeringGoal(.reachSpeed(0))] }
        player.components.set(steering)
        beam.advance(pressed: isFiring && !playerCharge.recharging, deltaTime: dt)
        applyBeam(deltaTime: dt)
        for bot in bots {
            guard var info = bot.components[BotComponent.self] else { continue }
            info.previousPosition = bot.position
            info.attackCooldown = max(0, info.attackCooldown - dt)
            info.hitFlash = max(0, info.hitFlash - dt)
            info.decisionDelay -= dt
            if bot.state(BotMode.self) == .zapped && bot.timeInState(BotMode.self) < 0.3 {
                bot.components[SteeringComponent.self]?.goals = [SteeringGoal(.reachSpeed(0))]
            } else if info.decisionDelay <= 0 {
                info.decisionDelay = 0.3
                decide(bot, info: &info, player: player, navigation: navigation)
            }
            if bot.state(BotMode.self) != .zapped || bot.timeInState(BotMode.self) >= 0.3 {
                advanceBotRoute(bot, info: &info)
            }
            bot.components.set(info)
        }
        if remainingTime <= 0 { finish(won: false) }
    }

    func decide(_ bot: Entity, info: inout BotComponent, player: Entity, navigation: BotNavigation) {
        guard recoverNavigationStart(bot, navigation: navigation) else { info.route = []; return }
        let red = bots.filter { $0.id != bot.id && $0.components[BotComponent.self]?.isBad == true }
        let good = bots.filter { $0.id != bot.id && $0.components[BotComponent.self]?.isBad == false }
        let targets = playerCharge.recharging ? good : good + [player]
        let target = targets.min { simd_distance_squared(bot.position, $0.position) < simd_distance_squared(bot.position, $1.position) }
        let threat = red.min { simd_distance_squared(bot.position, $0.position) < simd_distance_squared(bot.position, $1.position) }
        let intent = BotBrain.intent(for: BotPerception(bad: info.isBad, corruption: info.corruption,
            threatDistance: threat.map { simd_distance(bot.position, $0.position) } ?? .infinity,
            targetDistance: target.map { simd_distance(bot.position, $0.position) } ?? .infinity))
        var destination: SIMD2<Float>
        let mode: BotMode
        switch intent {
        case .hunt:
            mode = .hunt; destination = target?.position ?? bot.position
        case .flee:
            mode = .flee
            let danger = info.isBad ? player.position : (threat?.position ?? player.position)
            let delta = bot.position - danger
            let heading = simd_length_squared(delta) > 0.1 ? simd_normalize(delta) : SIMD2<Float>(1, 0)
            destination = simd_clamp(bot.position + heading * 220, navigation.bounds.min + SIMD2(repeating: 50), navigation.bounds.max - SIMD2(repeating: 50))
            if !navigation.isClear(from: bot.position, to: destination), let patrol = info.patrol.max(by: { simd_distance($0, danger) < simd_distance($1, danger) }) { destination = patrol }
        case .patrol:
            mode = .patrol
            guard !info.patrol.isEmpty else { return }
            if simd_distance(bot.position, info.patrol[info.waypoint]) < 50 { info.waypoint = (info.waypoint + 1) % info.patrol.count }
            destination = info.patrol[info.waypoint]
        }
        bot.enter(mode)
        // Patrol routes keep their remaining corners. Moving hunt/flee goals
        // replan only after a meaningful change or loss of segment clearance.
        let reusable = info.route.last.map { simd_distance($0, destination) < 20 } == true &&
            info.route.first.map { navigation.isClear(from: bot.scenePosition, to: $0) } == true
        if !reusable { info.route = navigation.path(from: bot.scenePosition, to: destination) }
        var steering = bot.components[SteeringComponent.self]!
        steering.maxSpeed = info.isBad ? (mode == .hunt ? 155 : 115) : 140
        steering.maxForce = 700
        // Keep safety goals independent from the switchable navigation group.
        steering.goals = [
            .group("navigation", []),
            SteeringGoal(.separate(radius: 65), weight: 1.2),
            SteeringGoal(.avoidObstacles(lookAhead: 0.18), weight: 1.5)
        ]
        bot.components.set(steering)
    }

    func advanceBotRoute(_ bot: Entity, info: inout BotComponent) {
        if let navigation { advanceRoute(&info.route, from: bot.scenePosition, navigation: navigation) }
        let next = info.route.first
        let goal: SteeringBehavior
        if let next, info.route.count > 1 || simd_distance(bot.scenePosition, next) > 8 {
            goal = info.route.count == 1 ? .arrive(.point(next), slowingRadius: 65) : .seek(.point(next))
        } else { goal = .reachSpeed(0) }
        guard var steering = bot.components[SteeringComponent.self],
              let index = steering.goals.firstIndex(where: { $0.name == "navigation" }) else { return }
        steering.goals[index].behavior = .group([SteeringGoal(goal)])
        bot.components.set(steering)
    }

    /// Proximity alone cannot skip a tight corner: first prove the next leg
    /// has the same clearance as the planned route.
    func advanceRoute(_ route: inout [SIMD2<Float>], from point: SIMD2<Float>, navigation: BotNavigation) {
        while route.count > 1 && simd_distance(point, route[0]) < 12 && navigation.isClear(from: point, to: route[1]) {
            route.removeFirst()
        }
    }

    /// Swept movement can stop inside the planner's extra one-point margin.
    /// Recover only that tiny gap with the actual character controller. Deep
    /// overlaps/invalid starts still fail; pathfinding never projects through walls.
    @discardableResult func recoverNavigationStart(_ actor: Entity, navigation: BotNavigation) -> Bool {
        let start = actor.scenePosition
        if navigation.isWalkable(start) { return true }
        var candidates: [SIMD2<Float>] = []
        for polygon in navigation.padded where polygon.contains(start) || polygon.distance(to: start) < 2 {
            let boundary = polygon.closestPoint(to: start)
            let delta = boundary - start
            if simd_length_squared(delta) > 0.000001 {
                candidates.append(boundary + simd_normalize(delta) * 0.25)
            }
        }
        // The board edge uses the same padding as the obstacle graph.
        let margin = SIMD2<Float>(repeating: navigation.clearance + 0.25)
        candidates.append(simd_clamp(start, navigation.bounds.min + margin, navigation.bounds.max - margin))
        for point in candidates.sorted(by: { simd_distance_squared(start, $0) < simd_distance_squared(start, $1) })
            where simd_distance_squared(start, point) <= 4 && navigation.isWalkable(point) {
            guard let result = try? actor.moveCharacter(by: point - actor.scenePosition), !result.isOverlapping else { continue }
            if navigation.isWalkable(actor.scenePosition) { return true }
        }
        return false
    }

    func hasLineOfSight(from start: SIMD2<Float>, to end: SIMD2<Float>) -> Bool {
        world?.raycast(from: start, to: end, filter: .init(mask: BotCollisionGroups.walls)).isEmpty == true
    }

    func actors(near position: SIMD2<Float>, radius: Float, excluding: Set<Entity.ID> = []) -> [Entity] {
        world?.overlaps(shape: .circle(radius: radius), transform: .init(tx: position.x, ty: position.y),
                        filter: .init(mask: BotCollisionGroups.actors, excluding: excluding)).map(\.entity) ?? []
    }

    func nearestBad(to position: SIMD2<Float>, range: Float, visible: Bool) -> Entity? {
        actors(near: position, radius: range).filter {
            $0.components[BotComponent.self]?.isBad == true && simd_distance(position, $0.position) <= range &&
                (!visible || hasLineOfSight(from: position, to: $0.position))
        }.min { simd_distance_squared(position, $0.position) < simd_distance_squared(position, $1.position) }
    }

    func applyBeam(deltaTime dt: Float) {
        guard beam.active, let player, let info = player.components[BotComponent.self] else { hideBeam(); return }
        let direction = SIMD2<Float>(cos(info.heading), sin(info.heading))
        let target = actors(near: player.position, radius: 300, excluding: [player.id]).filter { bot in
            guard bot.components[BotComponent.self]?.isBad == true else { return false }
            let delta = bot.position - player.position
            let distance = simd_length(delta)
            return distance <= 300 && (distance < 50 || simd_dot(delta / max(distance, 1), direction) >= cos(.pi / 8)) &&
                hasLineOfSight(from: player.position, to: bot.position)
        }.min { simd_distance_squared(player.position, $0.position) < simd_distance_squared(player.position, $1.position) }
        let origin = player.position + SIMD2<Float>(0, 60)
        var end = target.map { $0.position + SIMD2<Float>(0, 50) } ?? (origin + direction * 300)
        if target == nil, let hit = world?.raycast(from: player.position, to: player.position + direction * 300,
                                                  filter: .init(mask: BotCollisionGroups.walls)).first {
            // Query in the ground plane, then lift the drawn beam to emitter height.
            end = hit.position + SIMD2<Float>(0, 60)
        }
        let jitter = SIMD2<Float>(-direction.y, direction.x) * sin(elapsed * 90) * 7
        var path = VectorPath()
        path.move(to: origin); path.addLine(to: (origin + end) / 2 + jitter); path.addLine(to: end)
        for line in beamLines {
            line.isEnabled = true
            line.components[ShapeComponent.self]?.geometry = .path(path)
        }
        if let target, let reticle = targetReticle {
            let tracking = TransformConstraintComponent([
                TransformConstraint(.follow(.entity(target.id), offset: [0, 2], offsetSpace: .scene))
            ])
            if reticle.components[TransformConstraintComponent.self] != tracking { reticle.components.set(tracking) }
            reticle.isEnabled = true
        } else { targetReticle?.isEnabled = false }
        guard let target, var bot = target.components[BotComponent.self] else { return }
        bot.corruption = max(0, bot.corruption - 90 * dt)
        target.components.set(bot)
        target.enter(BotMode.zapped)
        if effectDelay <= 0 {
            effectDelay = 0.13
            spark(at: end, color: .cyan, count: 5)
        }
        if bot.corruption <= 0 { cure(target) }
    }
    func hideBeam() {
        for line in beamLines { line.isEnabled = false }
        targetReticle?.isEnabled = false
    }

    func cure(_ entity: Entity, cascade: Bool = true) {
        guard var info = entity.components[BotComponent.self], info.isBad else { return }
        info.isBad = false; info.corruption = 0; info.patrol = info.goodPatrol
        info.waypoint = 0; info.decisionDelay = 0; info.attackCooldown = 2
        entity.components.set(info); entity.enter(BotMode.patrol)
        spark(at: entity.position + [0, 45], color: .green, count: 28)
        effects?.caption("REPAIRED", color: .green, at: entity.scenePosition + [0, 100])
        if soundEnabled { playTone("cure", at: entity.position) }
        if info.kind == .flying, cascade {
            blast(at: entity.position, beneficial: true)
            for neighbor in bots where neighbor !== entity && simd_distance(neighbor.position, entity.position) < 145 {
                cure(neighbor, cascade: false)
            }
        }
    }

    func resolveMovement(deltaTime: Float) {
        guard phase == .playing, let player else { return }
        let dt = max(deltaTime, 0)
        for entity in [player] + bots {
            guard var info = entity.components[BotComponent.self], var steering = entity.components[SteeringComponent.self] else { continue }
            let proposed = entity.position
            entity.position = info.previousPosition
            do {
                let movement = try entity.moveCharacter(by: proposed - info.previousPosition)
                if !movement.contacts.isEmpty {
                    steering.velocity = (movement.displacement - movement.recoveryTranslation) / max(dt, 0.001)
                }
            } catch {
                // A rejected controller configuration leaves the last safe pose.
                steering.velocity = .zero
            }
            let delta = entity.position - info.previousPosition
            if info.kind != .player && simd_length_squared(delta) > 0.5 { info.heading = atan2(delta.y, delta.x) }
            entity.components.set(info); entity.components.set(steering)
        }
    }

    func afterSteering(deltaTime: Float) {
        guard phase == .playing, let player else { return }
        let dt = max(deltaTime, 0)
        effects?.advance(dt)
        for entity in [player] + bots {
            guard let info = entity.components[BotComponent.self] else { continue }
            updateLook(entity, info: info, moving: simd_distance_squared(entity.position, info.previousPosition) > 0.05)
        }
        for bot in bots {
            guard var info = bot.components[BotComponent.self], info.isBad, info.attackCooldown <= 0, bot.state(BotMode.self) != .zapped else { continue }
            let victims = bots.filter { $0.components[BotComponent.self]?.isBad == false } + (playerCharge.recharging ? [] : [player])
            guard let victim = victims.first(where: { simd_distance(bot.position, $0.position) < 68 && hasLineOfSight(from: bot.position, to: $0.position) }) else { continue }
            info.attackCooldown = info.kind == .flying ? 3 : 1.5
            bot.components.set(info)
            if info.kind == .flying {
                blast(at: bot.position, beneficial: false)
                for entity in victims where simd_distance(entity.position, bot.position) < 145 { damage(entity, amount: 35) }
            } else { damage(victim, amount: 25) }
        }
        if bots.allSatisfy({ $0.components[BotComponent.self]?.isBad == false }) { finish(won: true) }
        hudDelay -= dt
        if hudDelay <= 0 { hudDelay = 0.1; refreshHUD(); redrawPaths() }
    }

    func damage(_ entity: Entity, amount: Float) {
        if entity === player {
            if playerCharge.hit(amount) {
                entity.components[BotComponent.self]?.hitFlash = 0.5
                camera?.components[CameraComponent.self]?.shake(0.3)
                spark(at: entity.position, color: .red, count: 12)
                effects?.caption("−\(Int(amount))", color: .red, at: entity.scenePosition + [0, 100])
            }
        } else if var info = entity.components[BotComponent.self], !info.isBad {
            info.corruption = min(100, info.corruption + amount * 2)
            info.hitFlash = 0.3
            if info.corruption >= 100 {
                info.isBad = true; info.patrol = info.badPatrol; info.waypoint = 0
                info.decisionDelay = 0
                spark(at: entity.position, color: .red, count: 20)
            }
            entity.components.set(info)
        }
    }

    func updateLook(_ entity: Entity, info: BotComponent, moving: Bool) {
        let mode = entity.state(BotMode.self) ?? .patrol
        let animation = DemoBotsResources.animationKey(for: info, mode: mode, moving: moving)
        let key = "\(animation.prefix):\(animation.direction)"
        if activeClips[entity.id] != key, let clip = clips[key], let body = entity.findEntity(named: "body") {
            _ = try? body.playAnimation(clip, options: .init(repeatMode: .forever))
            activeClips[entity.id] = key
        }
        entity.transform.zPosition = 100 - entity.position.y / 10000
        if let body = entity.findEntity(named: "body"), var sprite = body.components[SpriteComponent.self] {
            let original = sprite
            let textureSize = sprite.texture?.size ?? sprite.image.map { SIMD2(Float($0.width), Float($0.height)) } ?? sprite.size ?? [120, 120]
            try? sprite.material.setParameter(.vector2([1 / max(textureSize.x, 1), 1 / max(textureSize.y, 1)]), named: "a_texelSize")
            try? sprite.material.setParameter(.float(mode == .zapped ? 2 : 0), named: "a_outlineWidth")
            try? sprite.material.setParameter(.float(min(1, info.hitFlash * 4)), named: "a_flash")
            try? sprite.material.setParameter(.color(info.hitFlash > 0 ? .red : .cyan), named: "a_effectColor")
            if sprite != original { body.components.set(sprite) }
        }
    }

    func spark(at position: SIMD2<Float>, color: Color, count: Int) {
        effects?.burst(.sparks(color: color), count: count, at: position)
    }
    func blast(at position: SIMD2<Float>, beneficial: Bool) {
        var particles = ParticleEmitterComponent.puff(color: beneficial ? .green : .red)
        particles.speed = 150; particles.lifetime = 0.8; particles.particleSize = [28, 28]
        effects?.burst(particles, count: 60, at: position + [0, 25], blast: true)
    }
    func playTone(_ name: String, at position: SIMD2<Float>) {
        guard name == "cure", let cureSound, let world else { return }
        let emitter = Entity(name: "cure sound", components: LifetimeComponent(Float(cureSound.duration + 0.1)), DemoBotsTransient())
        emitter.position = position; world.addEntity(emitter)
        _ = try? emitter.playAudio(cureSound, volume: 0.3, isPositional: true)
    }
    func finish(won: Bool) {
        guard phase == .playing else { return }
        phase = won ? .won : .lost
        world?.isPaused = true
        stopMotion(); refreshHUD()
    }
    func refreshHUD() {
        secondsLeft = max(0, Int(ceil(remainingTime)))
        badBots = bots.filter { $0.components[BotComponent.self]?.isBad == true }.count
        charge = playerCharge.value; beamFraction = beam.remaining / DebugBeam.capacity
        isRecharging = playerCharge.recharging
        botStatuses = Dictionary(uniqueKeysWithValues: ([player].compactMap { $0 } + bots).map { entity in
            let info = entity.components[BotComponent.self]!
            let value = info.kind == .player ? playerCharge.value : (info.isBad ? info.corruption : 100 - info.corruption)
            return (entity.id, BotStatus(charge: max(0, min(1, value / 100)), isBad: info.isBad,
                isPlayer: info.kind == .player, isRecharging: info.kind == .player && playerCharge.recharging))
        })
        mapDots = ([player].compactMap { $0 } + bots).map {
            MapDot(id: $0.id, position: $0.position, bad: $0.components[BotComponent.self]?.isBad == true, player: $0 === player)
        }
    }
    func resetPresentation() {
        for entity in world?.entities ?? [] where entity.components.has(DemoBotsTransient.self) { entity.removeFromParent() }
        beamLines = []; pathLines = []; activeClips = [:]; targetReticle = nil
        guard let world else { return }
        effects = try? DemoBotsEffects(world: world)
        for (index, width): (Int, Float) in [(0, 10), (1, 3)] {
            let line = Entity(name: "debug-beam-\(index)", components: DemoBotsTransient(), ShapeComponent(.path(VectorPath()),
                stroke: index == 0 ? .cyan : .white, lineWidth: width, glowWidth: index == 0 ? 5 : 0,
                lineCap: .round, lineJoin: .round, opacity: index == 0 ? 0.4 : 1, blendMode: .add))
            line.zPosition = 500; line.isEnabled = false
            world.addEntity(line); beamLines.append(line)
        }
        let reticle = Entity(name: "beam-target", components: DemoBotsTransient(), ShapeComponent(.ellipse(size: [84, 34]),
            stroke: .cyan, lineWidth: 3, glowWidth: 2, blendMode: .add))
        reticle.zPosition = 450; reticle.isEnabled = false
        world.addEntity(reticle); targetReticle = reticle
        redrawPaths()
    }

    func redrawPaths() {
        guard let world else { return }
        let actors = [player].compactMap { $0 } + bots
        while pathLines.count < actors.count {
            let line = Entity(name: "navigation-guide", components: DemoBotsTransient(),
                ShapeComponent(.path(VectorPath()), stroke: .yellow.opacity(0.6), lineWidth: 2, lineCap: .round, lineJoin: .round))
            line.zPosition = 300; world.addEntity(line); pathLines.append(line)
        }
        for (index, line) in pathLines.enumerated() {
            guard actors.indices.contains(index) else { line.isEnabled = false; continue }
            let actor = actors[index]
            let route = actor === player ? playerRoute : actor.components[BotComponent.self]?.route ?? []
            line.isEnabled = showsPaths && !route.isEmpty
            guard line.isEnabled else { continue }
            var path = VectorPath(); path.move(to: actor.scenePosition)
            for point in route { path.addLine(to: point) }
            let geometry = ShapeGeometry.path(path)
            if line.components[ShapeComponent.self]?.geometry != geometry { line.components[ShapeComponent.self]?.geometry = geometry }
        }
    }
}
