import AVFoundation
import ECSCore
import Foundation
import ImageIO
import Observation
import SpriteKit
import SwiftUI
import Testing
@testable import SpriteBackend

@MainActor
final class TestAudioVoice: AudioVoice {
    var playing = false
    var rate = 1.0
    var time = 0.0
    var volume: Float = 1
    var pan: Float = 0
    var stopCount = 0
    func synchronize(time: Double, playing: Bool, rate: Double, volume: Float, pan: Float, looping: Bool) throws {
        self.time = time; self.playing = playing; self.rate = rate; self.volume = volume; self.pan = pan
    }
    func stop() { playing = false; stopCount += 1 }
}

@MainActor
private final class PlaybackObservationCounter { var count = 0 }

@MainActor
private final class LoadGate {
    var started = false
    var calls = 0
    var pending: CheckedContinuation<Void, Never>?
    var observers: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        calls += 1
        await withCheckedContinuation { continuation in
            pending = continuation; started = true
            for observer in observers { observer.resume() }; observers = []
        }
    }
    func wait() async { if !started { await withCheckedContinuation { observers.append($0) } } }
    func release() { pending?.resume(); pending = nil }
}

private func resourceWAV() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
    var data = Data()
    func word<T: FixedWidthInteger>(_ value: T) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
    data.append(Data("RIFF".utf8)); word(UInt32(36 + 16000)); data.append(Data("WAVEfmt ".utf8))
    word(UInt32(16)); word(UInt16(1)); word(UInt16(1)); word(UInt32(8000)); word(UInt32(16000)); word(UInt16(2)); word(UInt16(16))
    data.append(Data("data".utf8)); word(UInt32(16000)); data.append(Data(repeating: 0, count: 16000))
    try data.write(to: url); return url
}

@MainActor @Suite struct ResourceLibraryTests {
    func texture(_ color: [UInt8] = [255, 0, 0, 255]) -> TextureResource {
        TextureResource(image: SpriteImage(width: 1, height: 1, pixels: color))
    }
    @Test func concurrentWaitersShareOneLoad() async throws {
        let cache = ResourceCache<Int>(), gate = LoadGate()
        let first = Task { try await cache.value(for: "one") { await gate.hold(); return 7 } }
        await gate.wait()
        let second = Task { try await cache.value(for: "one") { Issue.record("duplicate load"); return 9 } }
        gate.release()
        #expect(try await first.value == 7)
        #expect(try await second.value == 7)
        #expect(gate.calls == 1 && cache.count == 1)
    }
    @Test func cancelledWaiterDoesNotCancelSharedLoad() async throws {
        let cache = ResourceCache<Int>(), gate = LoadGate()
        let first = Task { try await cache.value(for: "one") { await gate.hold(); return 7 } }
        await gate.wait(); first.cancel()
        let second = Task { try await cache.value(for: "one") { return 9 } }
        gate.release()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(try await second.value == 7)
        #expect(cache.count == 1)
    }
    @Test func clearingDuringALoadDoesNotOverwriteTheNewCache() async throws {
        let cache = ResourceCache<Int>(), gate = LoadGate()
        let old = Task { try await cache.value(for: "one") { await gate.hold(); return 1 } }
        await gate.wait(); cache.removeAll()
        #expect(try await cache.value(for: "one") { 2 } == 2)
        gate.release()
        #expect(try await old.value == 1)
        #expect(try await cache.value(for: "one") { 3 } == 2)
    }
    @Test func failedLoadsCanBeRetried() async throws {
        let cache = ResourceCache<Int>()
        await #expect(throws: ResourceLoadingError.self) { try await cache.value(for: "x") { throw ResourceLoadingError.notFound("x") } }
        #expect(cache.count == 0)
        #expect(try await cache.value(for: "x") { 4 } == 4)
    }
    @Test func fileResourcesAreValidatedCachedAndReusableAfterEviction() async throws {
        let library = ResourceLibrary()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        let image = try #require(texture().nativeTexture?.cgImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); #expect(CGImageDestinationFinalize(destination))
        defer { try? FileManager.default.removeItem(at: url) }
        let a = try await library.texture(contentsOf: url)
        let b = try await library.texture(contentsOf: url)
        #expect(a == b && a.size == [1, 1])
        library.removeAllCachedResources()
        let c = try await library.texture(contentsOf: url)
        #expect(c != a && a.nativeTexture != nil)
        let missing = url.appendingPathExtension("missing")
        await #expect(throws: ResourceLoadingError.self) { try await library.texture(contentsOf: missing) }
        await #expect(throws: ResourceLoadingError.self) { try await library.texture(named: UUID().uuidString) }
    }
    @Test func audioIsCachedAndMissingOrInvalidFilesThrow() async throws {
        let library = ResourceLibrary(), url = try resourceWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        let a = try await library.audio(contentsOf: url), b = try await library.audio(contentsOf: url)
        #expect(a == b && abs(a.duration - 1) < 0.001)
        let junk = url.appendingPathExtension("junk")
        try Data("not audio".utf8).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }
        await #expect(throws: ResourceLoadingError.self) { try await library.audio(contentsOf: junk) }
        await #expect(throws: ResourceLoadingError.self) { try await library.audio(named: UUID().uuidString) }
    }
    @Test func atlasesPreserveExplicitClipOrderAndRejectInvalidClips() throws {
        let a = texture(), b = texture([0, 255, 0, 255])
        let atlas = try TextureAtlasResource(name: "hero", textures: ["a": a, "b": b])
        let clip = try atlas.animation(frames: ["b", "a"], framesPerSecond: 4)
        #expect(clip.frames == [b, a] && clip.duration == 0.5)
        #expect(throws: ResourceLoadingError.self) { try atlas.texture(named: "missing") }
        #expect(throws: ResourceLoadingError.self) { try atlas.animation(frames: []) }
        #expect(throws: ResourceLoadingError.self) { try atlas.animation(frames: ["a"], framesPerSecond: .nan) }
    }
    @Test func invalidResourcePixelDimensionsThrowInsteadOfOverflowing() {
        let json = "{\"width\":\(Int.max),\"height\":2,\"pixels\":\"\"}"
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(SpriteImage.self, from: Data(json.utf8)) }
    }

    @Test func resourcesShareNativeTexturesAndSnapshotTheirPixels() throws {
        let resource = texture(); let world = World(); let renderer = SpriteRenderer(world: world)
        let a = Entity(components: SpriteComponent(texture: resource)), b = Entity(components: SpriteComponent(texture: resource))
        world.addEntity(a); world.addEntity(b)
        let na = try #require(renderer.node(for: a)?.childNode(withName: "__sprite") as? SKSpriteNode)
        let nb = try #require(renderer.node(for: b)?.childNode(withName: "__sprite") as? SKSpriteNode)
        #expect(na.texture === nb.texture)
        let data = try JSONEncoder().encode(a.components[SpriteComponent.self]!)
        let copy = try JSONDecoder().decode(SpriteComponent.self, from: data)
        #expect(copy.texture == resource && copy.texture?.image == resource.image)
        #expect(copy.texture?.nativeTexture?.size() == CGSize(width: 1, height: 1))
    }
}

@MainActor @Suite struct PlaybackTests {
    func clip() throws -> AnimationResource {
        try AnimationResource(frames: [
            TextureResource(image: SpriteImage(width: 1, height: 1, pixels: [255, 0, 0, 255])),
            TextureResource(image: SpriteImage(width: 1, height: 1, pixels: [0, 255, 0, 255])),
        ], framesPerSecond: 2)
    }
    func fixture() -> (World, Entity) { let world = World(), entity = Entity(); world.addEntity(entity); return (world, entity) }

    @Test func sharedClipHasIndependentPositionsAndCompletesOnce() throws {
        let resource = try clip(), (world, a) = fixture(), b = Entity(); world.addEntity(b)
        let first = try a.playAnimation(resource), second = try b.playAnimation(resource)
        second.pause()
        var completions = 0
        let token = world.subscribe(to: PlaybackEvents.Completed.self, on: a) { _ in completions += 1 }
        world.update(deltaTime: 0.5)
        #expect(a.components[SpriteComponent.self]?.texture == resource.frames[1])
        #expect(first.currentTime == 0.5 && second.currentTime == 0)
        world.update(deltaTime: 0.5); world.update(deltaTime: 1)
        #expect(first.state == .completed && completions == 1)
        #expect(a.components[SpriteComponent.self]?.texture == resource.frames.last)
        first.resume(); #expect(first.state == .completed)
        _ = token
    }
    @Test func scenePauseTimeScaleAndIndividualPauseCompose() throws {
        let (world, entity) = fixture()
        let controller = try entity.playAnimation(clip(), options: .init(repeatMode: .forever, speed: 2))
        world.timeScale = 0.5; world.update(deltaTime: 0.25)
        #expect(controller.currentTime == 0.25)
        world.isPaused = true; world.update(deltaTime: 100)
        #expect(!controller.isPlaying && controller.currentTime == 0.25)
        controller.pause(); world.isPaused = false; world.update(deltaTime: 1)
        #expect(controller.state == .paused && controller.currentTime == 0.25)
        controller.resume(); world.timeScale = 0; world.update(deltaTime: 1)
        #expect(controller.currentTime == 0.25)
        world.timeScale = 1; world.update(deltaTime: 0.25)
        #expect(controller.currentTime == 0.75)
    }
    @Test func playingObservationRespondsToScenePause() throws {
        let (world, entity) = fixture()
        let controller = try entity.playAnimation(clip())
        let counter = PlaybackObservationCounter()
        withObservationTracking { _ = controller.isPlaying } onChange: {
            MainActor.assumeIsolated { counter.count += 1 }
        }
        world.isPaused = true
        #expect(counter.count == 1 && !controller.isPlaying)
    }

    @Test func countedAndForeverLoopsCarryLargeSteps() throws {
        let (world, entity) = fixture(), resource = try clip()
        let counted = try entity.playAnimation(resource, options: .init(repeatMode: .count(3)))
        world.update(deltaTime: 2.25)
        #expect(counted.completedIterations == 2 && counted.currentTime == 0.25)
        world.update(deltaTime: 0.75)
        #expect(counted.state == .completed && counted.completedIterations == 3)
        let forever = try entity.playAnimation(resource, options: .init(repeatMode: .forever))
        world.update(deltaTime: 100.25)
        #expect(forever.state == .playing && forever.completedIterations == 100 && forever.currentTime == 0.25)
    }
    @Test func enormousLoopCountsSaturateWithoutTrapping() throws {
        let (world, entity) = fixture()
        let resource = try AnimationResource(frames: [TextureResource(image: SpriteImage(width: 1, height: 1, pixels: [255, 0, 0, 255]))], framesPerSecond: 1e30)
        let controller = try entity.playAnimation(resource, options: .init(repeatMode: .forever))
        world.update(deltaTime: 1)
        #expect(controller.state == .playing && controller.completedIterations == Int.max)
    }

    @Test func replacementAndRemovalStopWithoutFalseCompletion() throws {
        let (world, entity) = fixture(), resource = try clip()
        let a = try entity.playAnimation(resource)
        var stopped = 0, completed = 0
        let tokens = [world.subscribe(to: PlaybackEvents.Stopped.self) { _ in stopped += 1 }, world.subscribe(to: PlaybackEvents.Completed.self) { _ in completed += 1 }]
        let b = try entity.playAnimation(resource)
        #expect(a.state == .stopped && stopped == 1)
        entity.removeFromParent()
        #expect(b.state == .stopped && stopped == 2 && completed == 0)
        world.update(deltaTime: 10); #expect(completed == 0)
        _ = tokens
    }
    @Test func completionMayStartAnotherClipWithoutLosingIt() throws {
        let (world, entity) = fixture(), resource = try clip()
        var next: AnimationPlaybackController?
        let token = world.subscribe(to: PlaybackEvents.Completed.self, on: entity) { _ in next = try? entity.playAnimation(resource) }
        _ = try entity.playAnimation(resource)
        world.update(deltaTime: 1)
        #expect(next?.state == .playing && next?.currentTime == 0)
        world.update(deltaTime: 0.5)
        #expect(next?.currentTime == 0.5)
        _ = token
    }
    @Test func reentrantReplacementKeepsOnlyTheNewestClip() throws {
        let (world, entity) = fixture(), resource = try clip()
        _ = try entity.playAnimation(resource)
        var replacement: AnimationPlaybackController?
        var handled = false
        let token = world.subscribe(to: PlaybackEvents.Stopped.self, on: entity) { event in
            if event.reason == .replaced && !handled { handled = true; replacement = try? entity.playAnimation(resource) }
        }
        let outer = try entity.playAnimation(resource)
        #expect(outer.state == .stopped && replacement?.state == .playing)
        world.update(deltaTime: 0.25)
        #expect(replacement?.currentTime == 0.25)
        #expect(entity.components[PlaybackStorage.self]?.controllers.count == 1)
        _ = token
    }
    @Test func invalidOptionsDoNotReplaceAnExistingClip() throws {
        let (world, entity) = fixture()
        _ = world
        let resource = try clip(), original = try entity.playAnimation(resource)
        #expect(throws: PlaybackError.self) { try entity.playAnimation(resource, options: .init(repeatMode: .count(0))) }
        #expect(original.state == .playing)
        original.speed = .nan; #expect(original.speed == 1)
        original.stop(); original.stop(); #expect(original.state == .stopped)
    }
    @Test func audioVoicesOverlapAndSynchronizeImmediatelyWithSceneSettings() throws {
        let old = PlaybackSystem.makeVoice
        defer { PlaybackSystem.makeVoice = old }
        var voices: [TestAudioVoice] = []
        PlaybackSystem.makeVoice = { _ in let voice = TestAudioVoice(); voices.append(voice); return voice }
        let resource = AudioResource(name: "test", duration: 1, data: Data()), (world, entity) = fixture()
        let a = try entity.playAudio(resource), b = try entity.playAudio(resource)
        #expect(voices.count == 2 && voices.allSatisfy(\.playing))
        a.pause(); world.timeScale = 2
        #expect(!voices[0].playing && voices[1].rate == 2)
        world.update(deltaTime: 0.25)
        #expect(a.currentTime == 0 && b.currentTime == 0.5)
        world.isPaused = true
        #expect(!voices[1].playing)
        world.isPaused = false
        #expect(!voices[0].playing && voices[1].playing)
        entity.removeFromParent()
        #expect(voices.allSatisfy { !$0.playing && $0.stopCount == 1 })
    }
    @Test func unsupportedAudioRateFailsExplicitlyOnce() throws {
        let old = PlaybackSystem.makeVoice; defer { PlaybackSystem.makeVoice = old }
        let voice = TestAudioVoice(); PlaybackSystem.makeVoice = { _ in voice }
        let resource = AudioResource(name: nil, duration: 1, data: Data()), (world, entity) = fixture()
        let controller = try entity.playAudio(resource)
        var failed = 0
        let token = world.subscribe(to: PlaybackEvents.Failed.self) { _ in failed += 1 }
        world.timeScale = 0.25
        #expect(controller.state == .failed && controller.error == .unsupportedAudioRate(0.25))
        world.timeScale = 1
        #expect(failed == 1 && !voice.playing)
        _ = token
    }
}
