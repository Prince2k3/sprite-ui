import Foundation
import SpriteUI
import Testing
@testable import DemoBotsGame

@MainActor @Suite(.serialized) struct DemoBotsCheckpointTests {
    private func fixture(level: Int = 1) throws -> (DemoBotsSession, World) {
        let game = DemoBotsSession()
        let world = World()
        game.attach(to: world)
        game.soundEnabled = false
        game.start(level: level)
        #expect(game.phase == .playing)
        _ = try #require(game.player)
        _ = try #require(game.camera)
        return (game, world)
    }

    private func decode(_ data: Data) throws -> DemoBotsCheckpoint {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try decoder.decode(DemoBotsCheckpoint.self, from: data)
    }

    private func encode(_ checkpoint: DemoBotsCheckpoint) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try encoder.encode(checkpoint)
    }

    private func replace<T: Component>(_ component: T, on id: Entity.ID, in checkpoint: inout DemoBotsCheckpoint) throws {
        let index = try #require(checkpoint.world.entities.firstIndex { $0.id == id })
        checkpoint.world.entities[index].components.removeAll { $0 is T }
        checkpoint.world.entities[index].components.append(component)
    }

    private func expectRejectedWithoutChangingMatch(_ data: Data, game: DemoBotsSession, world: World) throws {
        let snapshot = try WorldSnapshot(entities: [world.root.snapshot()]).jsonData()
        let objects = world.allEntities.map(ObjectIdentifier.init)
        let player = game.player, camera = game.camera
        let phase = game.phase, paused = world.isPaused, scale = world.timeScale
        let move = game.moveInput, aim = game.aimInput, firing = game.isFiring
        let destination = game.destination, route = game.playerRoute
        let charge = game.playerCharge, beam = game.beam
        let remaining = game.remainingTime, elapsed = game.elapsed, message = game.message
        #expect(throws: DemoBotsCheckpointError.self) { try game.restoreCheckpoint(data: data) }
        #expect(try WorldSnapshot(entities: [world.root.snapshot()]).jsonData() == snapshot)
        #expect(world.allEntities.map(ObjectIdentifier.init) == objects)
        #expect(game.player === player && game.camera === camera)
        #expect(game.phase == phase && world.isPaused == paused && world.timeScale == scale)
        #expect(game.moveInput == move && game.aimInput == aim && game.isFiring == firing)
        #expect(game.destination == destination && game.playerRoute == route)
        #expect(game.playerCharge == charge && game.beam == beam)
        #expect(game.remainingTime == remaining && game.elapsed == elapsed && game.message == message)
        #expect(world.root.components[DemoBotsRuntime.self]?.game === game)
    }

    @Test(arguments: [1, 2, 3]) func roundTripRestoresMatchAndStaysPaused(level: Int) throws {
        let (game, world) = try fixture(level: level)
        let player = try #require(game.player)
        let bot = try #require(game.bots.first)
        let camera = try #require(game.camera)
        game.playerCharge = PlayerCharge(value: 42, invulnerability: 0.35, rechargeTime: 1.25)
        game.beam = DebugBeam(remaining: 0.65, cooling: true, active: false)
        game.remainingTime = 73.25
        game.elapsed = 106.75
        game.showsPaths = true
        player.position += [4, -6]
        player.components[SteeringComponent.self]?.velocity = [17, -9]
        player.enter(BotMode.recharging)
        bot.components[BotComponent.self]?.isBad = true
        bot.components[BotComponent.self]?.corruption = 37
        bot.components[BotComponent.self]?.attackCooldown = 0.8
        bot.components[BotComponent.self]?.decisionDelay = 0.17
        bot.components[BotComponent.self]?.route = [bot.position, bot.position + [40, 20]]
        bot.components[SteeringComponent.self]?.velocity = [-43, 21]
        bot.components[SteeringComponent.self]?.goals = [SteeringGoal(.pursue(player.id))]
        bot.enter(BotMode.zapped)
        // Exercise a nonzero machine timer without running simulation or a renderer.
        let stateData = Data(#"{"machine":{"state":"zapped","previousState":"patrol","timeInState":0.175}}"#.utf8)
        bot.components.set(try JSONDecoder().decode(StateMachineComponent<BotMode>.self, from: stateData))
        camera.position = player.position + [35, 40]
        camera.components[CameraComponent.self]?.zoom = 0.78
        camera.components[CameraComponent.self]?.offset = [12, 24]

        let originalPlayerPosition = player.position
        let originalCameraPosition = camera.position
        let originalCameraComponent = camera.components[CameraComponent.self]
        let botEncoder = JSONEncoder()
        botEncoder.outputFormatting = [.sortedKeys]
        let originalBotData = try botEncoder.encode(bot.components[BotComponent.self])
        let originalSteering = bot.components[SteeringComponent.self]
        let originalBounds = game.mapBounds
        let originalObstacles = try #require(game.navigation).obstacles
        let originalBotIDs = game.bots.map(\.id)
        let worldRoot = world.root
        let systems = world.systems.types.map { String(reflecting: $0) }
        let data = try game.checkpointData()
        #expect(game.phase == .playing && !world.isPaused)

        game.start(level: level % 3 + 1)
        game.move([1, 0]); game.aim([0, 1], firing: true)
        game.destination = [900, -400]; game.playerRoute = [[100, 100]]
        try game.restoreCheckpoint(data: data)

        let restoredPlayer = try #require(game.player)
        let restoredBot = try #require(game.bots.first)
        let restoredCamera = try #require(game.camera)
        #expect(game.phase == .paused && world.isPaused)
        #expect(game.levelNumber == level)
        #expect(game.remainingTime == 73.25 && game.secondsLeft == 74)
        #expect(game.elapsed == 106.75)
        #expect(game.playerCharge == PlayerCharge(value: 42, invulnerability: 0.35, rechargeTime: 1.25))
        #expect(game.charge == 42 && game.isRecharging)
        #expect(game.beam == DebugBeam(remaining: 0.65, cooling: true, active: false))
        #expect(game.beamFraction == 0.65 / DebugBeam.capacity)
        #expect(restoredPlayer.id == player.id && restoredPlayer !== player)
        #expect(restoredPlayer.position == originalPlayerPosition)
        #expect(restoredPlayer.components[SteeringComponent.self]?.velocity == [17, -9])
        #expect(restoredPlayer.state(BotMode.self) == .recharging)
        #expect(game.bots.map(\.id) == originalBotIDs)
        #expect(try botEncoder.encode(restoredBot.components[BotComponent.self]) == originalBotData)
        #expect(restoredBot.components[SteeringComponent.self] == originalSteering)
        #expect(restoredBot.state(BotMode.self) == .zapped)
        #expect(restoredBot.timeInState(BotMode.self) == 0.175)
        #expect(restoredCamera.id == camera.id && restoredCamera.position == originalCameraPosition)
        #expect(restoredCamera.components[CameraComponent.self] == originalCameraComponent)
        #expect(restoredCamera.components[CameraComponent.self]?.target == .entity(restoredPlayer.id))
        #expect(game.mapBounds == originalBounds)
        #expect(game.navigation?.obstacles == originalObstacles)
        #expect(game.totalBots == originalBotIDs.count)
        #expect(game.mapDots.count == originalBotIDs.count + 1)
        #expect(game.moveInput == .zero && game.aimInput == .zero && !game.isFiring)
        #expect(game.destination == nil && game.playerRoute.isEmpty)
        #expect(game.effects != nil && !game.beamLines.isEmpty && !game.pathLines.isEmpty)
        #expect(game.beamLines.allSatisfy { $0.world === world })
        #expect(world.root === worldRoot)
        #expect(world.root.components[DemoBotsRuntime.self]?.game === game)
        #expect(world.systems.types.map { String(reflecting: $0) } == systems)
        #expect(world.entities(within: 1, of: restoredPlayer.position).contains { $0 === restoredPlayer })

        for _ in 0..<5 { world.update(deltaTime: 1 / 60) }
        #expect(game.remainingTime == 73.25 && restoredPlayer.position == originalPlayerPosition)
        #expect(restoredBot.timeInState(BotMode.self) == 0.175)
        game.resume()
        world.update(deltaTime: 1 / 60)
        #expect(game.phase == .playing && !world.isPaused && game.remainingTime < 73.25)
    }

    @Test func snapshotExcludesPoolsGuidesAndEffectsAndLoadsIntoFreshWorld() throws {
        let (game, world) = try fixture()
        game.showsPaths = true
        game.bots[0].components[BotComponent.self]?.route = [[400, 0], [500, 0]]
        game.redrawPaths()
        game.spark(at: [300, 0], color: .cyan, count: 8)
        let transient = Entity(name: "test-transient", components: DemoBotsTransient(), TextComponent("Never saved"))
        transient.addChild(Entity(name: "transient-child"))
        world.addEntity(transient)
        let data = try game.checkpointData()
        let saved = try decode(data)
        let persistentIDs = Set(world.entities.filter { !$0.components.has(DemoBotsTransient.self) }.map(\.id))
        #expect(Set(saved.world.entities.map(\.id)) == persistentIDs)
        #expect(!saved.world.entities.contains { $0.id == transient.id })
        #expect(saved.world.entities.contains { $0.name == "movement-boundary" })
        #expect(saved.world.entities.contains { $0.name == "circuit-backdrop" })
        #expect(!saved.world.entities.contains { $0.name.hasPrefix("debug-beam") || $0.name == "navigation-guide" })

        let fresh = DemoBotsSession(); let freshWorld = World(); fresh.attach(to: freshWorld)
        try fresh.restoreCheckpoint(data: data)
        #expect(fresh.phase == .paused && freshWorld.isPaused)
        #expect(fresh.player?.id == game.player?.id)
        let freshPlayer = try #require(fresh.player)
        #expect(fresh.camera?.components[CameraComponent.self]?.target == .entity(freshPlayer.id))
        #expect(freshWorld.root.findEntity(named: "test-transient") == nil)
        #expect(freshWorld.root.findEntity(named: "transient-child") == nil)
        #expect(fresh.effects != nil)
        #expect(fresh.bots.allSatisfy { $0.components[AttachmentComponent.self]?.attachmentID == "bot-status" })
        #expect(fresh.showsPaths && !fresh.soundEnabled)
        // A second save includes just the reconstructed persistent match.
        #expect(try decode(fresh.checkpointData()).world.entityCount == saved.world.entityCount)
    }

    @Test func corruptCheckpointsLeaveTheCurrentMatchCompletelyUntouched() throws {
        let (game, world) = try fixture()
        let goodData = try game.checkpointData()
        let good = try decode(goodData)
        let player = try #require(game.player)
        let camera = try #require(game.camera)
        let bot = try #require(game.bots.first)
        game.move([1, 0]); game.aim([0, 1], firing: true)
        game.destination = [700, 100]; game.playerRoute = [[600, 100]]
        let entityIDs = world.allEntities.map(\.id)
        let entityObjects = world.allEntities.map(ObjectIdentifier.init)
        let before = try game.checkpointData()
        let originalMessage = game.message
        let mutations: [(inout DemoBotsCheckpoint) -> Void] = [
            { $0.version = 999 },
            { $0.format = "unrelated-game" },
            { $0.world.version = 999 },
            { $0.levelNumber = 0 },
            { $0.levelNumber = 4 },
            { $0.remainingTime = -1 },
            { $0.elapsed = .nan },
            { $0.playerCharge.value = 101 },
            { $0.playerCharge.rechargeTime = -1 },
            { $0.beam.remaining = 3 },
            { $0.mapBounds.z = 0 },
            { $0.mapBounds.w = .infinity },
            { $0.playerID = 0 },
            { $0.cameraID = $0.playerID },
            { $0.botIDs.append($0.botIDs[0]) },
            { $0.botIDs = [] },
            { $0.world.entities = [] },
            { $0.world.entities.append($0.world.entities[0]) },
            { checkpoint in
                checkpoint.world.entities.removeAll { $0.id == checkpoint.cameraID }
            },
            { checkpoint in
                let index = checkpoint.world.entities.firstIndex { $0.id == checkpoint.playerID }!
                checkpoint.world.entities[index].components.removeAll { $0 is BotComponent }
            },
            { checkpoint in
                let index = checkpoint.world.entities.firstIndex { $0.id == checkpoint.botIDs[0] }!
                checkpoint.world.entities[index].components.removeAll { $0 is SteeringComponent }
            },
            { checkpoint in
                let index = checkpoint.world.entities.firstIndex { $0[SceneComponent.self] != nil }!
                var transform = checkpoint.world.entities[index][Transform.self]!
                transform.scale = .zero
                checkpoint.world.entities[index].components.removeAll { $0 is Transform }
                checkpoint.world.entities[index].components.append(transform)
            },
            { checkpoint in
                let index = checkpoint.world.entities.firstIndex { $0.id == checkpoint.botIDs[0] }!
                var bot = checkpoint.world.entities[index][BotComponent.self]!
                bot.corruption = 101
                checkpoint.world.entities[index].components.removeAll { $0 is BotComponent }
                checkpoint.world.entities[index].components.append(bot)
            },
            { checkpoint in
                let index = checkpoint.world.entities.firstIndex { $0.id == checkpoint.botIDs[0] }!
                var bot = checkpoint.world.entities[index][BotComponent.self]!
                bot.waypoint = bot.patrol.count
                checkpoint.world.entities[index].components.removeAll { $0 is BotComponent }
                checkpoint.world.entities[index].components.append(bot)
            },
            { checkpoint in
                let index = checkpoint.world.entities.firstIndex { $0.id == checkpoint.cameraID }!
                var camera = checkpoint.world.entities[index][CameraComponent.self]!
                camera.target = .entity(checkpoint.botIDs[0])
                checkpoint.world.entities[index].components.removeAll { $0 is CameraComponent }
                checkpoint.world.entities[index].components.append(camera)
            }
        ]
        var rejected = [Data(), Data("not JSON".utf8), Data("{}".utf8), Data(goodData.dropLast(8))]
        for mutate in mutations {
            var checkpoint = good
            mutate(&checkpoint)
            rejected.append(try encode(checkpoint))
        }
        for badData in rejected {
            #expect(throws: (any Error).self) { try game.restoreCheckpoint(data: badData) }
            #expect(try game.checkpointData() == before)
            #expect(game.player === player && game.camera === camera && game.bots[0] === bot)
            #expect(world.allEntities.map(\.id) == entityIDs)
            #expect(world.allEntities.map(ObjectIdentifier.init) == entityObjects)
            #expect(game.phase == .playing && !world.isPaused)
            #expect(game.moveInput == [1, 0] && game.aimInput == [0, 1] && game.isFiring)
            #expect(game.destination == [700, 100] && game.playerRoute == [[600, 100]])
            #expect(game.message == originalMessage)
        }
    }

    @Test func invalidMovementPrerequisitesRejectBeforeReplacingAnyEntities() throws {
        let (game, world) = try fixture()
        game.move([1, 0]); game.aim([0, 1], firing: true)
        game.destination = [700, 100]; game.playerRoute = [[600, 100]]
        let good = try decode(game.checkpointData())
        let changes: [(inout CharacterControllerComponent) -> Void] = [
            { $0.isEnabled = false },
            { $0.shape = .circle(radius: 0) },
            { $0.shape = .edgeChain([[0, 0], [10, 0]]) },
            { $0.shape = .edgeLoop(rectangle: [10, 10]) },
            { $0.skinWidth = 0 },
            { $0.skinWidth = -1 },
            { $0.skinWidth = .nan },
            { $0.skinWidth = .infinity },
            { $0.maxSlides = 0 },
            { $0.maxSlides = 65 },
            { $0.maxRecoveryIterations = 0 },
            { $0.maxRecoveryIterations = 129 },
            { $0.offset = [.nan, 0] },
            { $0.offset = [0, .infinity] }
        ]
        // Both the player and task bots must satisfy the same movement contract.
        for id in [good.playerID, try #require(good.botIDs.first)] {
            let actor = try #require(good.world.entities.first { $0.id == id })
            let controller = try #require(actor[CharacterControllerComponent.self])
            for change in changes {
                var checkpoint = good, invalid = controller
                change(&invalid)
                try replace(invalid, on: id, in: &checkpoint)
                try expectRejectedWithoutChangingMatch(encode(checkpoint), game: game, world: world)
            }
            var dynamic = good
            try replace(PhysicsBodyComponent(shape: .circle(radius: 25), isDynamic: true), on: id, in: &dynamic)
            try expectRejectedWithoutChangingMatch(encode(dynamic), game: game, world: world)

            for scale: SIMD2<Float> in [[0, 1], [1, 0], [1e-30, 1e-30], [1e30, 1e30]] {
                var checkpoint = good
                var transform = try #require(actor[Transform.self])
                transform.rotation = 0.45; transform.scale = scale
                try replace(transform, on: id, in: &checkpoint)
                try expectRejectedWithoutChangingMatch(encode(checkpoint), game: game, world: world)
            }
            // Finite offsets can still overflow when composed with a valid scale.
            var overflowing = good, offset = controller
            var transform = try #require(actor[Transform.self])
            transform.scale = [2, 2]
            offset.offset = [.greatestFiniteMagnitude, .greatestFiniteMagnitude]
            try replace(transform, on: id, in: &overflowing)
            try replace(offset, on: id, in: &overflowing)
            try expectRejectedWithoutChangingMatch(encode(overflowing), game: game, world: world)
        }
    }

    @Test func invalidLiveWorldRootRejectsRestoreWithoutChangingMatchOrInput() throws {
        let (game, world) = try fixture()
        let data = try game.checkpointData()
        game.move([1, 0]); game.aim([0, 1], firing: true)
        game.destination = [700, 100]; game.playerRoute = [[600, 100]]
        let original = world.root.transform
        defer { world.root.transform = original; world.root.isEnabled = true }
        for transform in [
            Transform(rotation: 0.45, scale: [0, 1]),
            Transform(scale: [1e-30, 1e-30]),
            Transform(scale: [1e30, 1e30]),
            Transform(rotation: .nan)
        ] {
            world.root.transform = transform
            try expectRejectedWithoutChangingMatch(data, game: game, world: world)
        }
        world.root.transform = original
        world.root.isEnabled = false
        try expectRejectedWithoutChangingMatch(data, game: game, world: world)
    }

    @Test func validRotatedAffineControllersKeepTheirMovementConfiguration() throws {
        let (game, world) = try fixture()
        let good = try decode(game.checkpointData())
        let rootTransform = Transform(translation: [4, 7], rotation: 0.2, scale: [-1, 2])
        world.root.transform = rootTransform
        for scale: SIMD2<Float> in [[2, 2], [-1, 2]] {
            var checkpoint = good
            let actor = try #require(good.world.entities.first { $0.id == good.playerID })
            var transform = try #require(actor[Transform.self])
            transform.rotation = 0.45; transform.scale = scale
            var controller = try #require(actor[CharacterControllerComponent.self])
            controller.offset = [2, -3]
            controller.skinWidth = 0.02; controller.maxSlides = 64; controller.maxRecoveryIterations = 128
            try replace(transform, on: good.playerID, in: &checkpoint)
            try replace(controller, on: good.playerID, in: &checkpoint)
            try game.restoreCheckpoint(data: encode(checkpoint))
            let player = try #require(game.player)
            #expect(world.root.transform == rootTransform)
            #expect(player.rotation == transform.rotation && player.scale == transform.scale)
            #expect(player.components[CharacterControllerComponent.self] == controller)
            _ = try player.moveCharacter(by: .zero)
            #expect(player.rotation == transform.rotation && player.scale == transform.scale)
            #expect(game.phase == .paused && world.isPaused)
        }
    }

    @Test func optionalSettingsMayBeAbsentAndHeldBeamDoesNotResumeFiring() throws {
        let (game, _) = try fixture()
        game.beam = DebugBeam(remaining: 1.25, cooling: false, active: true)
        var checkpoint = try decode(game.checkpointData())
        checkpoint.showsPaths = nil; checkpoint.soundEnabled = nil
        game.showsPaths = true; game.soundEnabled = false
        try game.restoreCheckpoint(data: encode(checkpoint))
        #expect(game.showsPaths && !game.soundEnabled)
        #expect(game.beam.remaining == 1.25 && !game.beam.cooling && !game.beam.active)
        #expect(!game.isFiring && game.phase == .paused)
    }

    @Test func cameraRebindsWhenSavedPlayerIDCollidesWithTheWorldRoot() throws {
        let (source, _) = try fixture()
        var checkpoint = try decode(source.checkpointData())
        let game = DemoBotsSession(); let world = World(); game.attach(to: world)
        let playerIndex = try #require(checkpoint.world.entities.firstIndex { $0.id == checkpoint.playerID })
        let cameraIndex = try #require(checkpoint.world.entities.firstIndex { $0.id == checkpoint.cameraID })
        checkpoint.playerID = world.root.id
        checkpoint.world.entities[playerIndex].id = world.root.id
        var camera = try #require(checkpoint.world.entities[cameraIndex][CameraComponent.self])
        camera.target = .entity(world.root.id)
        checkpoint.world.entities[cameraIndex].components.removeAll { $0 is CameraComponent }
        checkpoint.world.entities[cameraIndex].components.append(camera)

        try game.restoreCheckpoint(data: encode(checkpoint))
        let player = try #require(game.player)
        #expect(player.id != world.root.id)
        #expect(player.world === world && player !== world.root)
        #expect(game.camera?.components[CameraComponent.self]?.target == .entity(player.id))
        #expect(world.root.components[DemoBotsRuntime.self]?.game === game)
        #expect(game.phase == .paused && world.isPaused)
    }

    @Test func fileWrappersSaveLoadAndReportFailuresWithoutLosingMatch() throws {
        let (game, world) = try fixture(level: 3)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("checkpoint.json")
        game.remainingTime = 62.5
        game.saveCheckpoint(to: url)
        #expect(game.hasCheckpoint && game.checkpointMessage == "Checkpoint saved.")
        #expect(game.message == game.checkpointMessage)
        let savedData = try Data(contentsOf: url)
        game.start(level: 1)
        game.loadCheckpoint(from: url)
        #expect(game.levelNumber == 3 && game.remainingTime == 62.5)
        #expect(game.phase == .paused && world.isPaused)
        #expect(game.checkpointMessage == "Checkpoint loaded. Resume when ready.")

        game.resume()
        let player = game.player
        let state = try game.checkpointData()
        let phase = game.phase
        game.loadCheckpoint(from: directory.appendingPathComponent("missing.json"))
        #expect(game.message.hasPrefix("Couldn’t load checkpoint:"))
        #expect(game.checkpointMessage == game.message)
        #expect(game.player === player && game.phase == phase && !world.isPaused)
        #expect(try game.checkpointData() == state)
        // An invalid match cannot replace an existing good save.
        game.home()
        game.saveCheckpoint(to: url)
        #expect(game.message.hasPrefix("Couldn’t save checkpoint:"))
        #expect(try Data(contentsOf: url) == savedData)
    }

    @Test func absentWorldAndHomeCannotProduceCheckpointData() throws {
        let game = DemoBotsSession()
        #expect(throws: (any Error).self) { try game.checkpointData() }
        #expect(throws: (any Error).self) { try game.restoreCheckpoint(data: Data("{}".utf8)) }
        let world = World(); game.attach(to: world)
        #expect(throws: (any Error).self) { try game.checkpointData() }
    }
}
