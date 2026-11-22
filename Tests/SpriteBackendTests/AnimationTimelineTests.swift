@_spi(Backend) import ECSCore
import Foundation
import SpriteKit
import SwiftUI
import Testing
@testable import SpriteBackend

@MainActor @Suite struct AnimationTimelineTests {
    func fixture() -> (World, Entity) {
        let world = World(), entity = Entity(components: SpriteComponent(color: .orange, size: [20, 20]))
        world.addEntity(entity); return (world, entity)
    }
    func close(_ a: Float, _ b: Float) -> Bool { abs(a - b) < 0.0001 }

    @Test func resourceCapturesIndependentSourcesAndKeepsUntouchedFields() throws {
        let (world, a) = fixture(), b = Entity(); b.position = [100, 0]; world.addEntity(b)
        a.transform.zPosition = 7; a.scale = [2, 3]
        let resource = try AnimationResource.move(to: [200, 0], duration: 2)
        let first = try a.playAnimation(resource), second = try b.playAnimation(resource)
        world.update(deltaTime: 1)
        #expect(a.position == [100, 0] && b.position == [150, 0])
        #expect(a.scale == [2, 3] && a.zPosition == 7 && first !== second)
    }
    @Test func sequentialSourcesAndDelaysSampleIdenticallyAfterSeeking() throws {
        let (world, entity) = fixture()
        let resource = try AnimationResource.sequence([
            .move(to: [10, 0], duration: 1), .wait(1), .move(to: [30, 0], duration: 1)
        ]).delayed(by: 1)
        let controller = try entity.playAnimation(resource)
        #expect(resource.duration == 4)
        for (time, x): (Double, Float) in [(0.5, 0), (1.5, 5), (2.5, 10), (3.5, 20), (4, 30)] {
            try controller.seek(to: time); #expect(close(entity.position.x, x))
        }
        try controller.seek(to: 1.5); world.update(deltaTime: 2)
        #expect(close(entity.position.x, 20))
    }
    @Test func parallelPropertiesHoldShorterTracksAndUseCurves() throws {
        let (world, entity) = fixture()
        let resource = try AnimationResource.group([
            .move(to: [100, 0], duration: 2, curve: .easeIn),
            .rotate(to: .pi * 4, duration: 1), .scale(to: [3, 2], duration: 2), .fade(to: 0, duration: 1)
        ])
        _ = try entity.playAnimation(resource); world.update(deltaTime: 1)
        #expect(close(entity.position.x, 12.5) && close(entity.rotation, .pi * 4))
        #expect(entity.scale == [2, 1.5] && entity.components[SpriteComponent.self]?.opacity == 0)
        world.update(deltaTime: 0.5)
        #expect(close(entity.rotation, .pi * 4) && entity.components[SpriteComponent.self]?.opacity == 0)
    }
    @Test func independentClipsCoexistAndOverlappingClipsReplaceWholeGroups() throws {
        let (world, entity) = fixture()
        let first = try entity.playAnimation(.group([.move(to: [10, 0], duration: 2), .rotate(to: 2, duration: 2)]))
        let opacity = try entity.playAnimation(.fade(to: 0, duration: 2))
        world.update(deltaTime: 1)
        let replacement = try entity.playAnimation(.move(to: [25, 0], duration: 2))
        #expect(first.state == .stopped && opacity.state == .playing && replacement.state == .playing)
        world.update(deltaTime: 0.5)
        #expect(close(entity.position.x, 10) && close(entity.rotation, 1))
        #expect(close(entity.components[SpriteComponent.self]!.opacity, 0.25))
    }
    @Test func spriteFramesComposeWithMovementAndRestoreTheirOriginalLookWhenRewound() throws {
        let (world, entity) = fixture(), frames = try PlaybackTests().clip()
        let original = SpriteImage(width: 1, height: 1, pixels: [0, 0, 255, 255])
        entity.components.set(SpriteComponent(image: original))
        let resource = try AnimationResource.group([frames.delayed(by: 1), .move(to: [20, 0], duration: 2)])
        let controller = try entity.playAnimation(resource)
        world.update(deltaTime: 1.5)
        #expect(entity.components[SpriteComponent.self]?.texture == frames.frames[1] && entity.position == [15, 0])
        try controller.seek(to: 0)
        #expect(entity.components[SpriteComponent.self]?.texture == nil && entity.components[SpriteComponent.self]?.image == original)
    }
    @Test func finiteRepetitionUsesDeterministicChainedSourcesAndControllerLoopsReset() throws {
        let (world, entity) = fixture()
        let repeated = try AnimationResource.sequence([
            .move(from: .zero, to: [10, 0], duration: 1), .move(to: .zero, duration: 1)
        ]).repeated(2)
        let controller = try entity.playAnimation(repeated, options: .init(repeatMode: .count(2)))
        #expect(repeated.duration == 4)
        try controller.seek(to: 3.5); #expect(entity.position == [5, 0])
        world.update(deltaTime: 1); #expect(entity.position == [5, 0] && controller.completedIterations == 1)
        world.update(deltaTime: 3.5); #expect(controller.state == .completed && entity.position == .zero)
    }
    @Test func seekingPreservesPauseStateAndEndCompletesOnlyOnPlayback() throws {
        let (world, entity) = fixture()
        let controller = try entity.playAnimation(.move(to: [10, 0], duration: 1), options: .init(startsPaused: true))
        var completions = 0
        let token = world.subscribe(to: PlaybackEvents.Completed.self) { _ in completions += 1 }
        try controller.seek(to: 1); world.update(deltaTime: 2)
        #expect(entity.position == [10, 0] && controller.state == .paused && completions == 0)
        controller.resume(); world.update(deltaTime: 0); world.update(deltaTime: 1)
        #expect(controller.state == .completed && completions == 1)
        #expect(throws: PlaybackError.terminalController) { try controller.seek(to: 0) }
        withExtendedLifetime(token) {}
    }
    @Test func invalidSeeksAndResourcesLeaveExistingPlaybackUnchanged() throws {
        let (world, entity) = fixture()
        _ = world
        let controller = try entity.playAnimation(.move(to: [10, 0], duration: 1))
        for time in [-1.0, .nan, .infinity, 1.01] {
            #expect(throws: PlaybackError.invalidSeek) { try controller.seek(to: time) }
        }
        #expect(throws: ResourceLoadingError.invalidAnimation) { try AnimationResource.group([.move(to: [1, 0], duration: 1), .move(to: [2, 0], duration: 1)]) }
        #expect(throws: ResourceLoadingError.invalidAnimation) { try AnimationResource.move(to: [.nan, 0], duration: 1) }
        #expect(throws: ResourceLoadingError.invalidAnimation) { try AnimationResource.wait(0) }
        #expect(throws: ResourceLoadingError.invalidAnimation) { try AnimationResource.sequence([]) }
        #expect(throws: ResourceLoadingError.invalidAnimation) { try AnimationResource.fade(to: 2, duration: 1) }
        #expect(throws: ResourceLoadingError.invalidAnimation) { try AnimationResource.wait(1).repeated(Int.max) }
        #expect(throws: ResourceLoadingError.invalidAnimation) { try AnimationResource.wait(1).addingMarker("late", at: 2) }
        #expect(controller.state == .playing && controller.currentTime == 0)
    }
    @Test func dynamicPhysicsRejectsTransformClipsBeforeReplacingAnExistingClip() throws {
        let (world, entity) = fixture()
        let first = try entity.playAnimation(.fade(to: 0, duration: 1))
        entity.components.set(PhysicsBodyComponent(shape: .circle(radius: 4)))
        #expect(throws: PlaybackError.dynamicPhysicsBody) { try entity.playAnimation(.move(to: [10, 0], duration: 1)) }
        #expect(first.state == .playing)
        entity.components[PhysicsBodyComponent.self]?.isDynamic = false
        let move = try entity.playAnimation(.move(to: [10, 0], duration: 1))
        entity.components[PhysicsBodyComponent.self]?.isDynamic = true; world.update(deltaTime: 0.5)
        #expect(move.state == .failed && move.error == .dynamicPhysicsBody && entity.position == .zero)
    }
    @Test func invalidCustomCurveFailsWithoutPartiallyWritingParallelProperties() throws {
        let (world, entity) = fixture()
        let resource = try AnimationResource.group([
            .move(to: [10, 0], duration: 1), .rotate(to: 2, duration: 1, curve: .custom { _ in .nan })
        ])
        let controller = try entity.playAnimation(resource); world.update(deltaTime: 0.5)
        #expect(controller.state == .failed && controller.error == .invalidAnimationValue)
        #expect(entity.position == .zero && entity.rotation == 0)
    }
    @Test func pauseSpeedAndHierarchySuspensionShareOneClock() throws {
        let (world, entity) = fixture()
        let controller = try entity.playAnimation(.move(to: [100, 0], duration: 4), options: .init(speed: 2))
        world.timeScale = 0.5; world.update(deltaTime: 1); #expect(entity.position == [25, 0])
        entity.isEnabled = false; world.update(deltaTime: 1); #expect(controller.elapsedTime == 1)
        entity.isEnabled = true; world.isPaused = true; world.update(deltaTime: 1)
        #expect(controller.elapsedTime == 1 && !controller.isPlaying)
        try controller.seek(to: 2); #expect(entity.position == [50, 0])
        world.isPaused = false; controller.pause(); world.update(deltaTime: 1); #expect(controller.elapsedTime == 2)
        controller.resume(); world.update(deltaTime: 1); #expect(entity.position == [75, 0])
    }
    @Test func markersCrossedByALargeStepAreOrderedAcrossLoopBoundariesAndCompletionIsLast() throws {
        let (world, entity) = fixture()
        let resource = try AnimationResource.wait(1).addingMarker("start", at: 0).addingMarker("hit", at: 0.5).addingMarker("end", at: 1)
        var events: [String] = []
        let markers = world.subscribe(to: PlaybackEvents.MarkerReached.self) { events.append("\($0.iteration):\($0.marker.name)") }
        let completion = world.subscribe(to: PlaybackEvents.Completed.self) { _ in events.append("done") }
        _ = try entity.playAnimation(resource, options: .init(repeatMode: .count(2)))
        world.update(deltaTime: 2); world.update(deltaTime: 1)
        #expect(events == ["0:start", "0:hit", "0:end", "1:start", "1:hit", "1:end", "done"])
        withExtendedLifetime([markers, completion]) {}
    }
    @Test func seeksNeverFireMarkersAndEqualTimeMarkersPreserveCompositionOrder() throws {
        let (world, entity) = fixture()
        let a = try AnimationResource.wait(1).addingMarker("a", at: 0.5)
        let b = try AnimationResource.wait(1).addingMarker("b", at: 0.5)
        let resource = try AnimationResource.group([a, b]).addingMarker("c", at: 0.5)
        var names: [String] = []
        let token = world.subscribe(to: PlaybackEvents.MarkerReached.self) { names.append($0.marker.name) }
        let controller = try entity.playAnimation(resource)
        try controller.seek(to: 0.75); #expect(names.isEmpty)
        try controller.seek(to: 0.25); world.update(deltaTime: 0.5)
        #expect(names == ["a", "b", "c"])
        withExtendedLifetime(token) {}
    }
    @Test(arguments: ["pause", "seek", "stop", "remove", "reactivate"])
    func markerReentrancyCancelsRemainingOldFrameEvents(action: String) throws {
        let (world, entity) = fixture()
        let resource = try AnimationResource.wait(1).addingMarker("first", at: 0.25).addingMarker("last", at: 1)
        let controller = try entity.playAnimation(resource)
        var names: [String] = [], completed = 0
        let token = world.subscribe(to: PlaybackEvents.MarkerReached.self) { event in
            names.append(event.marker.name)
            switch action {
            case "pause": controller.pause()
            case "seek": try? controller.seek(to: 0.5)
            case "stop": controller.stop()
            case "remove": entity.removeFromParent()
            default: entity.isEnabled = false; entity.isEnabled = true
            }
        }
        let end = world.subscribe(to: PlaybackEvents.Completed.self) { _ in completed += 1 }
        world.update(deltaTime: 1)
        #expect(names == ["first"] && completed == 0)
        withExtendedLifetime([token, end]) {}
    }
    @Test func poolReuseInsideAMarkerCannotCompleteOrAdvanceTheNextLease() throws {
        let world = World(), template = Entity(components: SpriteComponent(color: .red, size: [10, 10]))
        let pool = try EntityPool(prefab: PrefabResource(root: template), scene: world, capacity: 1)
        let entity = try #require(try pool.acquire())
        let resource = try AnimationResource.wait(1).addingMarker("recycle", at: 0.25)
        let old = try entity.playAnimation(resource)
        var next: AnimationPlaybackController?, completions = 0
        let token = world.subscribe(to: PlaybackEvents.MarkerReached.self) { _ in
            do {
                try pool.release(entity)
                let reused = try #require(try pool.acquire())
                next = try reused.playAnimation(.wait(2))
            } catch { Issue.record(error) }
        }
        let end = world.subscribe(to: PlaybackEvents.Completed.self) { _ in completions += 1 }
        world.update(deltaTime: 1)
        #expect(old.state == .stopped && completions == 0 && next?.elapsedTime == 0)
        world.update(deltaTime: 0.5); #expect(next?.elapsedTime == 0.5)
        withExtendedLifetime([token, end]) {}
    }
    @Test func hugeMarkerFanoutFailsExplicitlyInsteadOfHanging() throws {
        let (world, entity) = fixture()
        let resource = try AnimationResource.wait(1).addingMarker("tick", at: 0.5)
        let controller = try entity.playAnimation(resource, options: .init(repeatMode: .forever))
        world.update(deltaTime: 1_000_000)
        #expect(controller.state == .failed && controller.error == .markerEventLimitExceeded)
        let counted = try entity.playAnimation(resource, options: .init(repeatMode: .count(Int.max)))
        world.update(deltaTime: 0.75); #expect(counted.state == .playing)
    }
    @Test func rendererCancelsNativeActionsAndDoesNotDoubleEaseControllerSamples() throws {
        let (world, entity) = fixture(), renderer = SpriteRenderer(world: world)
        withAnimation(.linear(duration: 5)) { entity.position = [100, 0] }; renderer.flush()
        let node = try #require(renderer.node(for: entity)); #expect(node.hasActions())
        let controller = try entity.playAnimation(.move(to: [200, 0], duration: 1))
        #expect(node.action(forKey: "transform.position") == nil)
        try withAnimation(.linear(duration: 5)) { try controller.seek(to: 0.5) }
        renderer.flush()
        #expect(entity.position == [100, 0] && node.position.x == 100 && !node.hasActions())
        withAnimation(.linear(duration: 5)) { entity.rotation = 1; entity.position = [300, 0] }
        renderer.flush()
        #expect(node.action(forKey: "transform.position") == nil && node.action(forKey: "transform.rotation") != nil)
        world.update(deltaTime: 0.25); renderer.flush()
        #expect(entity.position == [150, 0])
    }
    @Test func audioSeekUsesTheSamePublicClockAndDoesNotCompleteWhilePaused() throws {
        let (world, entity) = fixture(), voice = TestAudioVoice()
        world.addSystem(PlaybackSystem.self)
        let audio = AudioPlaybackController(entity: entity, resource: AudioResource(name: "test", duration: 2, data: Data()),
            options: .init(startsPaused: true), volume: 1, isPositional: false, voice: voice)
        entity.addPlayback(audio); audio.synchronize()
        try audio.seek(to: 1); #expect(voice.time == 1 && !voice.playing && audio.state == .paused)
        audio.resume(); world.update(deltaTime: 0.5)
        #expect(audio.currentTime == 1.5 && voice.playing)
    }
    @Test(arguments: [0.1, 0.3, 0.7]) func finiteCompletionKeepsExactIterationCount(duration: Double) throws {
        let (world, entity) = fixture()
        let controller = try entity.playAnimation(.wait(duration), options: .init(repeatMode: .count(9)))
        world.update(deltaTime: duration * 10)
        #expect(controller.state == .completed && controller.completedIterations == 9)
    }
    @Test func replacementCallbacksCanStartANewerClipWithoutRevivingTheReplacedController() throws {
        let (world, entity) = fixture()
        let original = try entity.playAnimation(.move(to: [10, 0], duration: 1))
        var newest: AnimationPlaybackController?
        let token = world.subscribe(to: PlaybackEvents.Stopped.self) { event in
            if event.controller === original { newest = try? entity.playAnimation(.move(to: [30, 0], duration: 1)) }
        }
        let replaced = try entity.playAnimation(.move(to: [20, 0], duration: 1))
        world.update(deltaTime: 0.5)
        #expect(replaced.state == .stopped && newest?.state == .playing && entity.position == [15, 0])
        withExtendedLifetime(token) {}
    }
    @Test func playbackPreparedBeforeAttachmentKeepsItsFirstFrameMarkersAndCompletion() throws {
        let world = World(), renderer = SpriteRenderer(world: world), entity = Entity()
        let controller = try entity.playAnimation(AnimationResource.wait(1).addingMarker("start", at: 0).addingMarker("end", at: 1))
        #expect(!controller.isPlaying)
        var markers: [String] = [], completions = 0
        let start = world.subscribe(to: PlaybackEvents.MarkerReached.self) { markers.append($0.marker.name) }
        let end = world.subscribe(to: PlaybackEvents.Completed.self) { _ in completions += 1 }
        world.addEntity(entity); #expect(controller.isPlaying)
        world.update(deltaTime: 1)
        #expect(markers == ["start", "end"] && completions == 1 && controller.state == .completed)
        withExtendedLifetime([start, end]) {}; withExtendedLifetime(renderer) {}
    }
}
