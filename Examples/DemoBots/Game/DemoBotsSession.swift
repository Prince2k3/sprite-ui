import Foundation
import Observation
import SpriteUI
import SwiftUI
import simd

/// Owns one match. The view supplies input; SpriteUI systems simulate the ECS.
@MainActor @Observable
public final class DemoBotsSession {
    public private(set) var phase: DemoBotsPhase = .home
    public private(set) var levelNumber = 1
    public private(set) var secondsLeft = 180
    public private(set) var badBots = 0
    public private(set) var totalBots = 0
    public private(set) var charge: Float = 100
    public private(set) var beamFraction: Float = 1
    public private(set) var isRecharging = false
    public private(set) var message = ""
    public var showsPaths = false
    public var soundEnabled = true
    public private(set) var mapDots: [MapDot] = []
    public private(set) var mapBounds = SIMD4<Float>(128, -1064, 1248, 1704)

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

    public init() {}

    public func build(in content: GameViewContent) {
        attach(to: content.world)
        renderer = content.renderer
        content.renderer.gravity = .zero
    }

    func attach(to world: World) {
        self.world = world
        world.root.components.set(DemoBotsRuntime(game: self))
        world.addSystem(DemoBotsLogicSystem.self)
        world.addSystem(SteeringSystem.self)
        world.addSystem(DemoBotsPresentationSystem.self)
        world.addSystem(SpatialIndexSystem.self)
        world.addSystem(LifetimeSystem.self)
    }

    public func start(level number: Int = 1) {
        guard let world else { message = "The game is still loading."; return }
        moveInput = .zero; aimInput = .zero; isFiring = false
        destination = nil; playerRoute = []; beam = DebugBeam(); playerCharge = PlayerCharge()
        for entity in world.entities { entity.removeFromParent() }
        bots = []; player = nil; camera = nil; beamLines = []; pathLines = []
        levelNumber = min(max(number, 1), 3)
        do {
            let config = try BotLevelConfiguration.load(levelNumber)
            let levelURL = try DemoBotsResources.url("Level\(levelNumber)", extension: "sks")
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
                    if sprite.imageName == nil { entity.components[SpriteComponent.self]?.opacity = 0 }
                }
            }
            world.addEntity(level)
            let box: BoundingBox
            switch levelNumber {
            case 1: box = BoundingBox(min: [128, -1064], max: [1376, 640])
            case 2: box = BoundingBox(min: [64, -1152], max: [2848, 1056])
            default: box = BoundingBox(min: [128, -1280], max: [2048, 640])
            }
            navigation = BotNavigation(bounds: box, obstacles: world.polygonObstacles)
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
            for i in 0..<4 {
                let line = Entity(name: "debug-beam-\(i)", components: SpriteComponent(color: i % 2 == 0 ? .cyan : .white, size: [1, 1], opacity: 0))
                line.transform.zPosition = 500
                world.addEntity(line); beamLines.append(line)
            }
            totalBots = bots.count
            remainingTime = config.timeLimit; elapsed = 0; hudDelay = 0; effectDelay = 0
            phase = .playing; message = "Cure every corrupted bot"
            refreshHUD()
        } catch {
            phase = .home
            message = "Couldn’t load Level \(levelNumber): \(error.localizedDescription)"
        }
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
        guard phase == .playing else { return }
        moveInput = simd_length(direction) > 1 ? simd_normalize(direction) : direction
        if simd_length_squared(direction) > 0.01 { destination = nil; playerRoute = [] }
    }
    public func aim(_ direction: SIMD2<Float>, firing: Bool) {
        guard phase == .playing else { isFiring = false; return }
        aimInput = direction; isFiring = firing
    }
    public func sendPlayer(toView point: CGPoint) {
        guard phase == .playing, let renderer, let player, let navigation else { return }
        let goal = renderer.scenePoint(fromView: point)
        guard navigation.bounds.contains(goal), !navigation.padded.contains(where: { $0.contains(goal) }) else { return }
        destination = goal
        playerRoute = navigation.path(from: player.position, to: goal)
    }
    public func pause() {
        guard phase == .playing else { return }
        phase = .paused; stopMotion()
    }
    public func resume() {
        guard phase == .paused else { return }
        phase = .playing
        for bot in bots { bot.components[BotComponent.self]?.decisionDelay = 0 }
    }
    public func home() {
        phase = .home; stopMotion()
    }
    func stopMotion() {
        moveInput = .zero; aimInput = .zero; isFiring = false
        for entity in bots + [player].compactMap({ $0 }) {
            entity.components[SteeringComponent.self]?.goals = []
            entity.components[SteeringComponent.self]?.velocity = .zero
        }
        for line in beamLines { line.components[SpriteComponent.self]?.opacity = 0 }
    }

    func makeBot(kind: BotKind, at point: SIMD2<Float>, heading: Float) -> Entity {
        let data = BotComponent(kind: kind, heading: heading, previousPosition: point)
        let entity = Entity(components: data, SteeringComponent(maxSpeed: 210, maxForce: 900, radius: 25), SpatialIndexComponent())
        entity.position = point
        let body = Entity(name: "body", components: SpriteComponent(imageName: "PlayerBot", size: [120, 120]))
        body.position = [0, 25]; entity.addChild(body)
        let shadow = Entity(name: "shadow", components: SpriteComponent(imageName: kind == .player ? "PlayerBotShadow" : "GroundBotShadow", size: [80, 32], opacity: 0.6))
        shadow.position = [0, -8]; shadow.transform.zPosition = -1; entity.addChild(shadow)
        let barBack = Entity(name: "charge-background", components: SpriteComponent(color: .black.opacity(0.65), size: [54, 6]))
        barBack.position = [0, 86]; entity.addChild(barBack)
        let bar = Entity(name: "charge", components: SpriteComponent(color: .green, size: [50, 3]))
        bar.position = [0, 86]; bar.transform.zPosition = 1; entity.addChild(bar)
        world?.addEntity(entity)
        return entity
    }

    func beforeSteering(deltaTime: Float) {
        guard phase == .playing, let player, let navigation else { return }
        let dt = min(max(deltaTime, 0), 1 / 15)
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
            while playerRoute.count > 1 && simd_distance(player.position, playerRoute[0]) < 32 { playerRoute.removeFirst() }
            if let next = playerRoute.first, simd_distance(next, player.position) > 10 {
                steering.goals = [SteeringGoal(.arrive(.point(next), slowingRadius: playerRoute.count == 1 ? 70 : 10))]
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
            bot.components.set(info)
        }
        if remainingTime <= 0 { finish(won: false) }
    }

    func decide(_ bot: Entity, info: inout BotComponent, player: Entity, navigation: BotNavigation) {
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
        let path = navigation.path(from: bot.position, to: destination)
        info.route = path
        var steering = bot.components[SteeringComponent.self]!
        steering.maxSpeed = info.isBad ? (mode == .hunt ? 155 : 115) : 140
        steering.maxForce = 700
        let next = path.dropFirst().first ?? bot.position
        steering.goals = [
            .group("navigation", [SteeringGoal(.arrive(.point(next), slowingRadius: 30))]),
            SteeringGoal(.separate(radius: 65), weight: 1.2),
            SteeringGoal(.avoidObstacles(lookAhead: 0.18), weight: 1.5)
        ]
        bot.components.set(steering)
    }

    func nearestBad(to position: SIMD2<Float>, range: Float, visible: Bool) -> Entity? {
        bots.filter {
            $0.components[BotComponent.self]?.isBad == true && simd_distance(position, $0.position) <= range &&
                (!visible || navigation?.isClear(from: position, to: $0.position) == true)
        }.min { simd_distance_squared(position, $0.position) < simd_distance_squared(position, $1.position) }
    }

    func applyBeam(deltaTime dt: Float) {
        guard beam.active, let player, let info = player.components[BotComponent.self] else { hideBeam(); return }
        let direction = SIMD2<Float>(cos(info.heading), sin(info.heading))
        let target = bots.filter { bot in
            guard bot.components[BotComponent.self]?.isBad == true else { return false }
            let delta = bot.position - player.position
            let distance = simd_length(delta)
            return distance <= 300 && (distance < 50 || simd_dot(delta / max(distance, 1), direction) >= cos(.pi / 8)) &&
                navigation?.isClear(from: player.position, to: bot.position) == true
        }.min { simd_distance_squared(player.position, $0.position) < simd_distance_squared(player.position, $1.position) }
        let origin = player.position + SIMD2<Float>(0, 60)
        var end = target.map { $0.position + SIMD2<Float>(0, 50) } ?? (origin + direction * 300)
        if target == nil, let navigation {
            // Empty beams stop at walls too.
            for distance in stride(from: Float(10), through: 300, by: 10) {
                if !navigation.isClear(from: player.position, to: player.position + direction * distance) {
                    end = origin + direction * max(0, distance - 10); break
                }
            }
        }
        for (index, line) in beamLines.enumerated() {
            let fractionA = Float(index / 2) / 2
            let fractionB = Float(index / 2 + 1) / 2
            let jitter = SIMD2<Float>(-direction.y, direction.x) * sin(elapsed * 90) * 7
            let middle = (origin + end) / 2 + jitter
            let a = fractionA == 0 ? origin : middle
            let b = fractionB == 1 ? end : middle
            let vector = b - a
            line.position = (a + b) / 2; line.transform.rotation = atan2(vector.y, vector.x)
            line.components[SpriteComponent.self]?.size = [simd_length(vector), index % 2 == 0 ? 10 : 3]
            line.components[SpriteComponent.self]?.opacity = index % 2 == 0 ? 0.35 : 1
        }
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
    func hideBeam() { for line in beamLines { line.components[SpriteComponent.self]?.opacity = 0 } }

    func cure(_ entity: Entity, cascade: Bool = true) {
        guard var info = entity.components[BotComponent.self], info.isBad else { return }
        info.isBad = false; info.corruption = 0; info.patrol = info.goodPatrol
        info.waypoint = 0; info.decisionDelay = 0; info.attackCooldown = 2
        entity.components.set(info); entity.enter(BotMode.patrol)
        spark(at: entity.position + [0, 45], color: .green, count: 28)
        if soundEnabled { playTone("cure", at: entity.position) }
        if info.kind == .flying, cascade {
            blast(at: entity.position, beneficial: true)
            for neighbor in bots where neighbor !== entity && simd_distance(neighbor.position, entity.position) < 145 {
                cure(neighbor, cascade: false)
            }
        }
    }

    func afterSteering(deltaTime: Float) {
        guard phase == .playing, let player, let navigation else { return }
        let dt = min(max(deltaTime, 0), 1 / 15)
        for entity in [player] + bots {
            guard var info = entity.components[BotComponent.self], var steering = entity.components[SteeringComponent.self] else { continue }
            let proposed = entity.position
            entity.position = navigation.move(from: info.previousPosition, toward: proposed)
            let delta = entity.position - info.previousPosition
            // Remove the blocked velocity component, allowing a tangential slide.
            if simd_distance_squared(entity.position, proposed) > 0.1 { steering.velocity = delta / max(dt, 0.001) }
            if info.kind != .player && simd_length_squared(delta) > 0.5 { info.heading = atan2(delta.y, delta.x) }
            info.animationTime += dt
            entity.components.set(info); entity.components.set(steering)
            updateLook(entity, info: info, moving: simd_length_squared(delta) > 0.05)
        }
        for bot in bots {
            guard var info = bot.components[BotComponent.self], info.isBad, info.attackCooldown <= 0, bot.state(BotMode.self) != .zapped else { continue }
            let victims = bots.filter { $0.components[BotComponent.self]?.isBad == false } + (playerCharge.recharging ? [] : [player])
            guard let victim = victims.first(where: { simd_distance(bot.position, $0.position) < 68 && navigation.isClear(from: bot.position, to: $0.position) }) else { continue }
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
        let texture = DemoBotsResources.texture(for: info, mode: mode, moving: moving)
        if let body = entity.findEntity(named: "body"), body.components[SpriteComponent.self]?.imageName != texture {
            body.components[SpriteComponent.self]?.imageName = texture
        }
        entity.transform.zPosition = 100 - entity.position.y / 10000
        let amount = info.kind == .player ? playerCharge.value : (info.isBad ? info.corruption : 100 - info.corruption)
        let bar = entity.findEntity(named: "charge")
        bar?.components[SpriteComponent.self]?.size = [50 * max(0.01, amount / 100), 3]
        bar?.components[SpriteComponent.self]?.color = info.kind == .player ? .cyan : (info.isBad ? .red : .green)
    }

    func spark(at position: SIMD2<Float>, color: Color, count: Int) {
        world?.addEntity(.oneShot(particles: .sparks(color: color), count: count, at: position))
    }
    func blast(at position: SIMD2<Float>, beneficial: Bool) {
        var particles = ParticleEmitterComponent.puff(color: beneficial ? .green : .red)
        particles.speed = 150; particles.lifetime = 0.8; particles.particleSize = [28, 28]
        world?.addEntity(.oneShot(particles: particles, count: 60, at: position + [0, 25]))
    }
    func playTone(_ name: String, at position: SIMD2<Float>) {
        guard let url = Bundle.module.url(forResource: name, withExtension: "wav") else { return }
        world?.addEntity(.oneShot(sound: AudioComponent(url: url, volume: 0.3), at: position))
    }
    func finish(won: Bool) {
        guard phase == .playing else { return }
        phase = won ? .won : .lost
        stopMotion(); refreshHUD()
    }
    func refreshHUD() {
        secondsLeft = max(0, Int(ceil(remainingTime)))
        badBots = bots.filter { $0.components[BotComponent.self]?.isBad == true }.count
        charge = playerCharge.value; beamFraction = beam.remaining / DebugBeam.capacity
        isRecharging = playerCharge.recharging
        mapDots = ([player].compactMap { $0 } + bots).map {
            MapDot(id: $0.id, position: $0.position, bad: $0.components[BotComponent.self]?.isBad == true, player: $0 === player)
        }
    }
    func redrawPaths() {
        for entity in pathLines { entity.removeFromParent() }; pathLines = []
        guard showsPaths else { return }
        for bot in bots {
            let route = bot.components[BotComponent.self]?.route ?? []
            guard route.count > 1 else { continue }
            for (a, b) in zip(route, route.dropFirst()) {
                let delta = b - a
                let line = Entity(components: SpriteComponent(color: .yellow.opacity(0.6), size: [simd_length(delta), 2]))
                line.position = (a + b) / 2; line.transform.rotation = atan2(delta.y, delta.x)
                line.transform.zPosition = 300; world?.addEntity(line); pathLines.append(line)
            }
        }
    }
}
