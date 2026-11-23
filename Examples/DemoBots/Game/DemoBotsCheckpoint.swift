import Foundation
import SpriteUI

/// Match metadata accompanies SpriteUI's persistent entity trees. Presentation
/// pools and guides are deliberately rebuilt instead of serialized.
struct DemoBotsCheckpoint: Codable {
    var format = "SpriteUI.DemoBots.Checkpoint"
    var version = 1
    var levelNumber: Int
    var remainingTime: Double
    var elapsed: Float
    var playerCharge: PlayerCharge
    var beam: DebugBeam
    var mapBounds: SIMD4<Float>
    var playerID: Entity.ID
    var botIDs: [Entity.ID]
    var cameraID: Entity.ID
    var world: WorldSnapshot
    var showsPaths: Bool?
    var soundEnabled: Bool?

    /// Checks everything used by rebinding or navigation before touching a match.
    /// In particular, snapshots normally tolerate missing/unknown components;
    /// a playable DemoBots checkpoint must still contain its required components.
    @MainActor func validate(rootTransform: AffineTransform2D = .identity, rootIsEnabled: Bool = true) throws -> BoundingBox {
        guard format == "SpriteUI.DemoBots.Checkpoint", version == 1, world.version == 1 else {
            throw DemoBotsCheckpointError.unsupportedVersion
        }
        guard rootIsEnabled, rootTransform.inverted() != nil,
              (1...3).contains(levelNumber),
              remainingTime.isFinite, (0...1_000_000).contains(remainingTime),
              elapsed.isFinite, (0...100_000_000).contains(elapsed),
              playerCharge.value.isFinite, (0...100).contains(playerCharge.value),
              playerCharge.invulnerability.isFinite, playerCharge.invulnerability >= 0,
              playerCharge.rechargeTime.isFinite, playerCharge.rechargeTime >= 0,
              beam.remaining.isFinite, (0...DebugBeam.capacity).contains(beam.remaining),
              (0..<4).allSatisfy({ mapBounds[$0].isFinite }),
              abs(mapBounds.x) <= 1_000_000, abs(mapBounds.y) <= 1_000_000,
              mapBounds.z > 0, mapBounds.w > 0,
              mapBounds.z <= 16_384, mapBounds.w <= 16_384,
              !botIDs.isEmpty, Set(botIDs).count == botIDs.count,
              !botIDs.contains(playerID), !botIDs.contains(cameraID), playerID != cameraID
        else { throw DemoBotsCheckpointError.invalidData }

        var nodes: [Entity.ID: EntitySnapshot] = [:]
        func visit(_ node: EntitySnapshot, depth: Int) throws {
            guard depth < 64, nodes.count < 20_000,
                  node.id > 0, node.id < Entity.ID.max - 1_000_000,
                  nodes.updateValue(node, forKey: node.id) == nil,
                  Set(node.components.map { ObjectIdentifier(type(of: $0)) }).count == node.components.count,
                  let transform = node[Transform.self],
                  transform.translation.x.isFinite, transform.translation.y.isFinite,
                  transform.rotation.isFinite, transform.zPosition.isFinite,
                  transform.scale.x.isFinite, transform.scale.y.isFinite
            else { throw DemoBotsCheckpointError.invalidData }
            if let polygon = node[PolygonObstacleComponent.self] {
                guard polygon.points.count >= 3,
                      Set(polygon.points).count >= 3,
                      polygon.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite })
                else { throw DemoBotsCheckpointError.invalidData }
            }
            for child in node.children { try visit(child, depth: depth + 1) }
        }
        for root in world.entities { try visit(root, depth: 0) }
        let rootIDs = Set(world.entities.map(\.id))
        let actors = Set(botIDs + [playerID])
        guard actors.isSubset(of: rootIDs), rootIDs.contains(cameraID),
              Set(nodes.values.filter { $0[BotComponent.self] != nil }.map(\.id)) == actors,
              world.entities.contains(where: { $0[SceneComponent.self] != nil }),
              world.entities.filter({ $0.name == "movement-boundary" && $0[CollisionComponent.self] != nil }).count == 1,
              world.entities.filter({ $0.name == "circuit-backdrop" && $0[SpriteComponent.self] != nil }).count == 1,
              let camera = nodes[cameraID]?[CameraComponent.self],
              camera.target == .entity(playerID), camera.isActive,
              camera.zoom.isFinite, camera.zoom > 0,
              camera.smoothing.isFinite, camera.smoothing >= 0,
              camera.offset.x.isFinite, camera.offset.y.isFinite,
              camera.trauma.isFinite, camera.traumaDecay.isFinite, camera.maxShake.isFinite
        else { throw DemoBotsCheckpointError.invalidData }
        if let bounds = camera.bounds {
            guard bounds.min.x.isFinite, bounds.min.y.isFinite,
                  bounds.max.x.isFinite, bounds.max.y.isFinite,
                  bounds.max.x >= bounds.min.x, bounds.max.y >= bounds.min.y
            else { throw DemoBotsCheckpointError.invalidData }
        }
        for id in actors {
            guard let actor = nodes[id], actor.isEnabled,
                  let bot = actor[BotComponent.self], (bot.kind == .player) == (id == playerID),
                  bot.corruption.isFinite, (0...100).contains(bot.corruption),
                  bot.heading.isFinite, abs(bot.heading) <= 1_000_000, bot.decisionDelay.isFinite,
                  bot.attackCooldown.isFinite, bot.attackCooldown >= 0,
                  bot.hitFlash.isFinite, bot.hitFlash >= 0,
                  bot.previousPosition.x.isFinite, bot.previousPosition.y.isFinite,
                  [bot.patrol, bot.goodPatrol, bot.badPatrol, bot.route].joined().allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
                  bot.waypoint >= 0,
                  bot.patrol.isEmpty ? bot.waypoint == 0 : bot.waypoint < bot.patrol.count,
                  id == playerID || (!bot.patrol.isEmpty && !bot.goodPatrol.isEmpty && !bot.badPatrol.isEmpty),
                  let steering = actor[SteeringComponent.self],
                  steering.velocity.x.isFinite, steering.velocity.y.isFinite,
                  steering.maxSpeed.isFinite, steering.maxSpeed >= 0,
                  steering.maxForce.isFinite, steering.maxForce >= 0,
                  steering.mass.isFinite, steering.mass > 0,
                  steering.radius.isFinite, steering.radius >= 0,
                  actor[SpatialIndexComponent.self] != nil,
                  let state = actor[StateMachineComponent<BotMode>.self],
                  state.machine.timeInState.isFinite, state.machine.timeInState >= 0,
                  actor[CollisionComponent.self]?.shape.isValid == true,
                  let controller = actor[CharacterControllerComponent.self], controller.isEnabled,
                  controller.shape.isValid, !controller.shape.isEdge,
                  controller.skinWidth.isFinite, controller.skinWidth > 0,
                  (1...64).contains(controller.maxSlides),
                  (1...128).contains(controller.maxRecoveryIterations),
                  controller.offset.x.isFinite, controller.offset.y.isFinite,
                  actor[PhysicsBodyComponent.self]?.isDynamic != true,
                  let transform = actor[Transform.self],
                  actor.children.contains(where: { $0.name == "body" && $0[SpriteComponent.self] != nil })
            else { throw DemoBotsCheckpointError.invalidData }
            // Match moveCharacter's affine prerequisites, including its offset
            // pose. Rotation, reflection and nonuniform scale remain supported.
            // All actors are roots, so their parent is the live world root,
            // which world.restore deliberately leaves untouched.
            let pose = rootTransform * transform.matrix
            let offsetPose = pose * AffineTransform2D(tx: controller.offset.x, ty: controller.offset.y)
            guard pose.inverted() != nil, offsetPose.inverted() != nil else {
                throw DemoBotsCheckpointError.invalidData
            }
        }
        return BoundingBox(min: [mapBounds.x, mapBounds.y],
                           max: [mapBounds.x + mapBounds.z, mapBounds.y + mapBounds.w])
    }
}

enum DemoBotsCheckpointError: LocalizedError {
    case noMatch, invalidData, unsupportedVersion

    var errorDescription: String? {
        switch self {
        case .noMatch: "Start a match before saving a checkpoint."
        case .invalidData: "The checkpoint does not contain a valid DemoBots match."
        case .unsupportedVersion: "This checkpoint format is not supported."
        }
    }
}

extension DemoBotsSession {
    private static func registerCheckpointComponents() {
        SpriteRenderer.registerComponents()
        AttachmentComponent.registerComponent()
        BotComponent.registerComponent()
        SteeringComponent.registerComponent()
        SpatialIndexComponent.registerComponent()
        StateMachineComponent<BotMode>.registerComponent()
        PolygonObstacleComponent.registerComponent()
    }

    /// Encodes a match without changing its pause state or held input.
    public func checkpointData() throws -> Data {
        guard let world, let player, let camera,
              phase == .playing || phase == .paused else { throw DemoBotsCheckpointError.noMatch }
        Self.registerCheckpointComponents()
        let checkpoint = DemoBotsCheckpoint(
            levelNumber: levelNumber, remainingTime: remainingTime, elapsed: elapsed,
            playerCharge: playerCharge, beam: beam, mapBounds: mapBounds,
            playerID: player.id, botIDs: bots.map(\.id), cameraID: camera.id,
            world: world.snapshot(including: { !$0.components.has(DemoBotsTransient.self) }),
            showsPaths: showsPaths, soundEnabled: soundEnabled)
        _ = try checkpoint.validate(rootTransform: world.root.sceneTransformMatrix,
                                    rootIsEnabled: world.root.isEnabledInHierarchy)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Steering goals may legitimately use an infinite panic distance.
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try encoder.encode(checkpoint)
    }

    /// Invalid data throws before any entity, input, clock or match state changes.
    /// A successful restore always waits at the pause menu for explicit Resume.
    public func restoreCheckpoint(data: Data) throws {
        guard let world else { throw DemoBotsCheckpointError.noMatch }
        Self.registerCheckpointComponents()
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        let checkpoint = try decoder.decode(DemoBotsCheckpoint.self, from: data)
        let bounds = try checkpoint.validate(rootTransform: world.root.sceneTransformMatrix,
                                              rootIsEnabled: world.root.isEnabledInHierarchy)

        // Navigation is derived from the saved hierarchy before destructive restore.
        // No resource loading or other throwing work follows world.restore.
        var obstacles: [PolygonObstacle] = []
        func collect(_ node: EntitySnapshot, parent: AffineTransform2D) throws {
            let pose = parent * (node[Transform.self] ?? .identity).matrix
            guard [pose.a, pose.b, pose.c, pose.d, pose.tx, pose.ty].allSatisfy(\.isFinite),
                  abs(pose.tx) <= 1_000_000, abs(pose.ty) <= 1_000_000
            else { throw DemoBotsCheckpointError.invalidData }
            if let polygon = node[PolygonObstacleComponent.self] {
                // PolygonObstacle requires three corners even after near-duplicate
                // cleanup. A collapsed/overflowed saved transform must throw here.
                var points: [SIMD2<Float>] = []
                func distanceSquared(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
                    let d = a - b
                    return d.x * d.x + d.y * d.y
                }
                for point in polygon.points.map({ pose.apply(to: $0) }) {
                    guard point.x.isFinite, point.y.isFinite else { throw DemoBotsCheckpointError.invalidData }
                    if points.last.map({ distanceSquared($0, point) > 1e-12 }) ?? true { points.append(point) }
                }
                if points.count > 1, distanceSquared(points[0], points[points.count - 1]) <= 1e-12 { points.removeLast() }
                guard points.count >= 3 else { throw DemoBotsCheckpointError.invalidData }
                obstacles.append(PolygonObstacle(points: points))
            }
            for child in node.children { try collect(child, parent: pose) }
        }
        for root in checkpoint.world.entities { try collect(root, parent: world.root.sceneTransformMatrix) }
        let navigation = BotNavigation(bounds: bounds, obstacles: obstacles)

        world.isPaused = true
        let restored = world.restore(checkpoint.world)
        player = restored[checkpoint.playerID]!
        bots = checkpoint.botIDs.map { restored[$0]! }
        camera = restored[checkpoint.cameraID]!
        self.navigation = navigation
        levelNumber = checkpoint.levelNumber
        remainingTime = checkpoint.remainingTime
        elapsed = checkpoint.elapsed
        playerCharge = checkpoint.playerCharge
        beam = checkpoint.beam
        beam.active = false
        mapBounds = checkpoint.mapBounds
        if let setting = checkpoint.showsPaths { showsPaths = setting }
        if let setting = checkpoint.soundEnabled { soundEnabled = setting }
        hudDelay = 0; effectDelay = 0
        world.updateSpatialIndex()
        finishRestoringCheckpoint()
    }

    static func checkpointFileURL() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: false)
            .appendingPathComponent("DemoBots", isDirectory: true)
            .appendingPathComponent("checkpoint.json", isDirectory: false)
    }

    func refreshCheckpointAvailability() {
        do { hasCheckpoint = FileManager.default.fileExists(atPath: try Self.checkpointFileURL().path) }
        catch { hasCheckpoint = false }
    }

    public func saveCheckpoint() {
        do { saveCheckpoint(to: try Self.checkpointFileURL()) }
        catch { reportCheckpointFailure(error, action: "save") }
    }

    public func loadCheckpoint() {
        do { loadCheckpoint(from: try Self.checkpointFileURL()) }
        catch { reportCheckpointFailure(error, action: "load") }
    }

    // Explicit locations let headless tests exercise atomic I/O in isolation.
    func saveCheckpoint(to url: URL) {
        do {
            let data = try checkpointData()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            hasCheckpoint = true
            checkpointMessage = "Checkpoint saved."
            message = checkpointMessage
        } catch { reportCheckpointFailure(error, action: "save") }
    }

    func loadCheckpoint(from url: URL) {
        do {
            try restoreCheckpoint(data: Data(contentsOf: url))
            hasCheckpoint = true
            checkpointMessage = "Checkpoint loaded. Resume when ready."
            message = checkpointMessage
        } catch { reportCheckpointFailure(error, action: "load") }
    }

    private func reportCheckpointFailure(_ error: any Error, action: String) {
        checkpointMessage = "Couldn’t \(action) checkpoint: \(error.localizedDescription)"
        message = checkpointMessage
    }
}
