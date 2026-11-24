@_spi(Backend) import ECSCore
import Foundation
@testable import GameUI
import Metal
@_spi(Backend) import SpriteBackend
import SpriteKit
import SwiftUI
import Testing

private struct ReplayRenderCounter: Component, Codable, Equatable {
    var value = 0
}

private let replayRenderIncrement = InputAction("increment", kind: .axis)

@MainActor private final class ReplayRenderProbe {
    var replay: InputReplayController?
    var fixedCalls = 0
    var simulationCalls = 0
    var presentationCalls = 0
    var deltas: [TimeInterval] = []
    var unscaledDeltas: [TimeInterval] = []
    var debugSteps: [Bool] = []
    var errors: [String] = []
}

private struct ReplayRenderRuntime: Component {
    let probe: ReplayRenderProbe
}

@MainActor private struct ReplayRenderFixedSystem: System {
    static var phase: SystemPhase { .fixedSimulation }
    init(world: World) {}

    mutating func update(context: UpdateContext) {
        guard let probe = context.world.root.components[ReplayRenderRuntime.self]?.probe else { return }
        probe.fixedCalls += 1
        probe.deltas.append(context.deltaTime)
        probe.unscaledDeltas.append(context.unscaledDeltaTime)
        probe.debugSteps.append(context.world.isDebugStepping)
        do {
            let sample: FixedInputSample
            if let replay = probe.replay {
                sample = try replay.sample(for: context)
            } else {
                sample = FixedInputSample(values: [replayRenderIncrement: .axis(1)])
            }
            for entity in context.entities(matching: EntityQuery(where: .has(ReplayRenderCounter.self))) {
                entity.components[ReplayRenderCounter.self]?.value += Int(sample.value(for: replayRenderIncrement).scalar)
            }
            try probe.replay?.finishTick(context)
        } catch {
            probe.errors.append(String(describing: error))
        }
    }
}

@MainActor private struct ReplayRenderSimulationSystem: System {
    init(world: World) {}
    mutating func update(context: UpdateContext) {
        context.world.root.components[ReplayRenderRuntime.self]?.probe.simulationCalls += 1
    }
}

@MainActor private struct ReplayRenderPresentationSystem: System {
    static var phase: SystemPhase { .presentation }
    init(world: World) {}
    mutating func update(context: UpdateContext) {
        context.world.root.components[ReplayRenderRuntime.self]?.probe.presentationCalls += 1
    }
}

@MainActor @Suite struct InputReplayRenderingTests {
    @MainActor private final class Fixture {
        struct NativeState {
            let actionPosition: CGPoint
            let bodyPosition: CGPoint
            let modelBodyPosition: SIMD2<Float>
        }

        let world = World()
        let probe = ReplayRenderProbe()
        let counter = Entity(components: ReplayRenderCounter())
        let actionActor = Entity(components: SpriteComponent(color: Color.red, size: [4, 4]))
        let body = Entity(components: PhysicsBodyComponent(shape: .circle(radius: 4),
            linearDamping: 0, affectedByGravity: false, velocity: [60, 0]))
        let scene: SpriteRenderer
        let frames: ViewportFrameRenderer
        let output: any MTLTexture

        init() throws {
            let device = try #require(MTLCreateSystemDefaultDevice())
            world.fixedStep = .init(stepsPerSecond: 20)
            world.physics.gravity = .zero
            world.root.components.set(ReplayRenderRuntime(probe: probe))
            world.addSystem(ReplayRenderFixedSystem.self)
            world.addSystem(ReplayRenderSimulationSystem.self)
            world.addSystem(ReplayRenderPresentationSystem.self)
            scene = SpriteRenderer(world: world, size: CGSize(width: 128, height: 128))
            actionActor.position.y = 20
            body.position.y = -20
            world.addEntity(counter)
            world.addEntity(actionActor)
            world.addEntity(body)
            frames = try ViewportFrameRenderer(scene: scene, device: device)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: 128, height: 128, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = [.renderTarget, .shaderRead]
            output = try #require(device.makeTexture(descriptor: descriptor))
        }

        func frame(_ time: TimeInterval, updatesScene: Bool = true) throws {
            let command = try #require(frames.commandQueue.makeCommandBuffer())
            try frames.encodeFrame(atTime: time, logicalSize: CGSize(width: 128, height: 128),
                into: output, commandBuffer: command, updatesScene: updatesScene)
            command.commit()
            command.waitUntilCompleted()
            try #require(command.status == .completed, "GPU error: \(String(describing: command.error))")
        }

        func primeNativeMotion() throws {
            // Warm the actual SKRenderer before installing a long-running action.
            try frame(100)
            let node = try #require(scene.node(for: actionActor))
            node.run(.moveBy(x: 600, y: 0, duration: 10), withKey: "native-motion")
            try frame(100.05)
            try frame(100.10)
            let physicsNode = try #require(scene.node(for: body))
            try #require(physicsNode.physicsBody != nil)
            try #require(node.action(forKey: "native-motion") != nil)
            try #require(node.position.x > 0 && physicsNode.position.x > 0 && body.position.x > 0,
                         "Native action and physics must move before testing that pause freezes them.")
            try #require(world.fixedStepState.tick > 0 && probe.fixedCalls > 0)
            try #require(probe.simulationCalls > 0 && probe.presentationCalls > 0)
            try #require(probe.errors.isEmpty)
        }

        func nativeState() throws -> NativeState {
            let node = try #require(scene.node(for: actionActor))
            let physicsNode = try #require(scene.node(for: body))
            return NativeState(actionPosition: node.position, bodyPosition: physicsNode.position,
                               modelBodyPosition: body.position)
        }

        func expectNativeFrozen(_ before: NativeState) throws {
            let current = try nativeState()
            #expect(abs(current.actionPosition.x - before.actionPosition.x) < 0.0001)
            #expect(abs(current.actionPosition.y - before.actionPosition.y) < 0.0001)
            #expect(abs(current.bodyPosition.x - before.bodyPosition.x) < 0.0001)
            #expect(abs(current.bodyPosition.y - before.bodyPosition.y) < 0.0001)
            #expect(abs(current.modelBodyPosition.x - before.modelBodyPosition.x) < 0.0001)
            #expect(abs(current.modelBodyPosition.y - before.modelBodyPosition.y) < 0.0001)
            let node = try #require(scene.node(for: actionActor))
            #expect(node.action(forKey: "native-motion") != nil)
            #expect(scene.physicsWorld.speed == 0)
            #expect(scene.node(for: world.root)?.isPaused == true)
            #expect(world.isPaused && !world.isDebugStepping)
        }

        func expectPassiveCapture() throws {
            let clock = world.fixedStepState
            let fixedCalls = probe.fixedCalls
            let frameNumber = frames.frameNumber
            for _ in 0..<3 {
                let image = try frames.capturePresentation()
                #expect(image.width == 128 && image.height == 128)
                #expect(image.pixels.count == 128 * 128 * 4)
            }
            #expect(world.fixedStepState == clock)
            #expect(probe.fixedCalls == fixedCalls)
            #expect(frames.frameNumber == frameNumber)
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Metal device unavailable"))
    func pausedWorldStepRunsOnlyOneFixedTickWithoutAdvancingNativeMotion() throws {
        let f = try Fixture()
        try f.primeNativeMotion()
        f.world.isPaused = true
        f.world.timeScale = 3
        let native = try f.nativeState()
        let before = f.world.fixedStepState
        let counter = try #require(f.counter.components[ReplayRenderCounter.self]).value
        let fixedCalls = f.probe.fixedCalls
        let simulationCalls = f.probe.simulationCalls
        let presentationCalls = f.probe.presentationCalls
        var updates = 0
        var renderedUpdates = 0
        var fixedTicks: [UInt64] = []
        let update = f.world.subscribe(to: WorldEvents.Update.self) { _ in updates += 1 }
        let rendered = f.world.subscribe(to: RenderingEvents.DidUpdate.self) { _ in renderedUpdates += 1 }
        let fixed = f.world.subscribe(to: WorldEvents.FixedUpdate.self) { event in
            fixedTicks.append(event.tick)
            #expect(event.deltaTime == 0.05 && event.unscaledDeltaTime == 0.05)
            #expect(!f.world.isDebugStepping && f.scene.physicsWorld.speed == 0)
        }
        defer { update.cancel(); rendered.cancel(); fixed.cancel() }

        for index in 1...3 {
            try #require(f.world.stepFixedSimulation())
            #expect(f.world.fixedStepState.tick == before.tick + UInt64(index))
            #expect(f.world.fixedStepState.ticksThisFrame == 1)
            #expect(f.world.fixedStepState.interpolationAlpha == 0)
            #expect(f.counter.components[ReplayRenderCounter.self]?.value == counter + index)
            #expect(f.probe.fixedCalls == fixedCalls + index)
            #expect(f.probe.deltas.last == 0.05 && f.probe.unscaledDeltas.last == 0.05)
            #expect(f.probe.debugSteps.last == false)
            #expect(f.probe.simulationCalls == simulationCalls)
            #expect(f.probe.presentationCalls == presentationCalls)
            #expect(updates == 0 && renderedUpdates == 0)
            try f.expectNativeFrozen(native)
        }
        #expect(fixedTicks == (1...3).map { before.tick + UInt64($0) })
        #expect(abs(f.world.fixedStepState.simulationTime - before.simulationTime - 0.15) < 0.000_001)

        let steppedClock = f.world.fixedStepState
        for time in [TimeInterval(200), 201, 202] {
            try f.frame(time)
            try f.expectPassiveCapture()
            try f.expectNativeFrozen(native)
            #expect(f.world.fixedStepState == steppedClock)
        }
        #expect(f.probe.fixedCalls == fixedCalls + 3 && fixedTicks.count == 3)
        #expect(f.probe.simulationCalls == simulationCalls)
        #expect(f.probe.presentationCalls == presentationCalls)
        #expect(updates == 0 && f.probe.errors.isEmpty)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Metal device unavailable"))
    func pausedReplayStepConsumesOneFrameAndRenderingCannotConsumeTheNext() throws {
        let f = try Fixture()
        try f.primeNativeMotion()
        let initial = ReplayRenderCounter(value: 10)
        let first = ReplayRenderCounter(value: 11)
        let second = ReplayRenderCounter(value: 10)
        let configuration = try #require(f.world.fixedStep)
        let archive = try InputRecording(configuration: configuration,
            initialState: JSONEncoder().encode(initial), frames: [
                .init(tick: 1, input: .init(values: [replayRenderIncrement: .axis(1)]),
                      checksum: InputRecordingChecksum(data: JSONEncoder().encode(first))),
                .init(tick: 2, input: .init(values: [replayRenderIncrement: .axis(-1)]),
                      checksum: InputRecordingChecksum(data: JSONEncoder().encode(second)))
            ])
        let counter = f.counter
        var checksumCalls = 0
        let replay = InputReplayController(world: f.world, input: InputController(),
            captureState: {
                try JSONEncoder().encode(#require(counter.components[ReplayRenderCounter.self]))
            }, restoreState: { data in
                counter.components.set(try JSONDecoder().decode(ReplayRenderCounter.self, from: data))
            }, checksum: {
                checksumCalls += 1
                return try JSONEncoder().encode(#require(counter.components[ReplayRenderCounter.self]))
            })
        f.probe.replay = replay
        let primedTick = f.world.fixedStepState.tick
        try replay.setPlaybackSpeed(3)
        try replay.startPlayback(archive, paused: true)
        #expect(f.counter.components[ReplayRenderCounter.self] == initial)
        #expect(replay.state == .paused && f.world.isPaused && f.world.timeScale == 3)
        let native = try f.nativeState()
        let initialTick = f.world.fixedStepState.tick
        #expect(initialTick == primedTick && initialTick > 0)
        let fixedCalls = f.probe.fixedCalls
        let simulationCalls = f.probe.simulationCalls
        let presentationCalls = f.probe.presentationCalls
        var updates = 0
        var fixedTicks: [UInt64] = []
        let update = f.world.subscribe(to: WorldEvents.Update.self) { _ in updates += 1 }
        let fixed = f.world.subscribe(to: WorldEvents.FixedUpdate.self) { event in
            fixedTicks.append(event.tick)
            #expect(event.deltaTime == configuration.stepDuration)
            #expect(event.unscaledDeltaTime == configuration.stepDuration)
            #expect(!f.world.isDebugStepping && f.scene.physicsWorld.speed == 0)
        }
        defer { update.cancel(); fixed.cancel() }

        // Even a full native update/render while initially paused cannot sample input.
        try f.frame(200)
        try f.expectPassiveCapture()
        #expect(f.world.fixedStepState.tick == initialTick && checksumCalls == 0)
        #expect(f.counter.components[ReplayRenderCounter.self] == initial)
        try f.expectNativeFrozen(native)

        try replay.step()
        #expect(replay.state == .paused)
        #expect(f.counter.components[ReplayRenderCounter.self] == first)
        #expect(f.world.fixedStepState.tick == initialTick + 1)
        #expect(f.probe.fixedCalls == fixedCalls + 1 && checksumCalls == 1)
        try f.expectNativeFrozen(native)
        let firstClock = f.world.fixedStepState
        for time in [TimeInterval(201), 202, 203] {
            try f.frame(time)
            // Also exercise the exact encoder's drawing-only path.
            try f.frame(time, updatesScene: false)
            try f.expectPassiveCapture()
            try f.expectNativeFrozen(native)
            #expect(f.world.fixedStepState == firstClock)
            #expect(f.counter.components[ReplayRenderCounter.self] == first)
            #expect(replay.state == .paused && checksumCalls == 1)
            #expect(f.probe.fixedCalls == fixedCalls + 1)
        }

        try replay.step()
        #expect(replay.state == .finished && f.world.isPaused)
        #expect(replay.divergence == nil && replay.lastError == nil)
        #expect(f.counter.components[ReplayRenderCounter.self] == second)
        #expect(f.world.fixedStepState.tick == initialTick + 2)
        #expect(f.probe.fixedCalls == fixedCalls + 2 && checksumCalls == 2)
        #expect(fixedTicks == [initialTick + 1, initialTick + 2])
        #expect(f.probe.deltas.suffix(2).allSatisfy { $0 == configuration.stepDuration })
        #expect(f.probe.unscaledDeltas.suffix(2).allSatisfy { $0 == configuration.stepDuration })
        #expect(f.probe.debugSteps.suffix(2).allSatisfy { !$0 })
        #expect(replay.recording == archive)
        let finishedClock = f.world.fixedStepState
        try f.frame(300)
        try f.expectPassiveCapture()
        try f.expectNativeFrozen(native)
        #expect(throws: InputReplayError.invalidState) { try replay.step() }
        #expect(f.world.fixedStepState == finishedClock && checksumCalls == 2)
        #expect(f.probe.fixedCalls == fixedCalls + 2)
        #expect(f.probe.simulationCalls == simulationCalls)
        #expect(f.probe.presentationCalls == presentationCalls)
        #expect(updates == 0 && f.probe.errors.isEmpty)
        #expect(replay.state == .finished && replay.recording == archive)
    }
}
