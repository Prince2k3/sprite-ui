import ECSCore
import Foundation
@testable import SpriteBackend
import SpriteKit
import Testing

/// A short mono 16-bit WAV of silence, written to a temporary file.
private func makeWAV(seconds: Double, sampleRate: Int = 8000) throws -> URL {
    let samples = Int(Double(sampleRate) * seconds)
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + samples * 2))
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
    append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
    data.append(contentsOf: Array("data".utf8)); append(UInt32(samples * 2))
    data.append(Data(count: samples * 2))
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
    try data.write(to: url)
    return url
}

@Suite struct ParticleEmitterModelTests {
    @Test func burstCountsUp() {
        var emitter = ParticleEmitterComponent()
        #expect(emitter.burstID == 0)
        emitter.burst(12)
        emitter.burst(5)
        #expect(emitter.burstID == 2 && emitter.burstCount == 5)
        emitter.burst(0)                 // nothing to throw out: ignored
        #expect(emitter.burstID == 2)
    }

    @Test func lifetimeIncludesTheRange() {
        #expect(ParticleEmitterComponent(lifetime: 1, lifetimeRange: 0.5).maximumLifetime == 1.25)
        #expect(ParticleEmitterComponent.sparks().blendMode == .add)
        #expect(ParticleEmitterComponent.smoke().isEmitting)
    }
}

@MainActor @Suite struct ParticleRenderingTests {
    @Test func streamingMakesAnEmitterNode() throws {
        let world = World()
        let renderer = SpriteRenderer(world: world)
        let entity = Entity(components: ParticleEmitterComponent.smoke())
        world.addEntity(entity)
        renderer.flush()
        let stream = try #require(renderer.node(for: entity)?.childNode(withName: "__emitter") as? SKEmitterNode)
        #expect(stream.particleBirthRate == 25)
        #expect(stream.targetNode === renderer)

        entity.components[ParticleEmitterComponent.self]?.isEmitting = false
        renderer.flush()
        #expect(stream.particleBirthRate == 0)
        entity.components[ParticleEmitterComponent.self]?.isEmitting = true
        entity.components[ParticleEmitterComponent.self]?.speed = 77
        renderer.flush()
        #expect(stream.particleBirthRate == 25 && stream.particleSpeed == 77)

        // Removed: stops making particles and goes once the last ones are gone.
        entity.components[ParticleEmitterComponent.self] = nil
        renderer.flush()
        #expect(stream.particleBirthRate == 0)
        #expect(renderer.node(for: entity)?.childNode(withName: "__emitter") == nil)
    }

    @Test func eachBurstAddsAOneShotEmitter() throws {
        let world = World()
        let renderer = SpriteRenderer(world: world)
        let entity = Entity(components: ParticleEmitterComponent.sparks())
        world.addEntity(entity)
        renderer.flush()
        let node = try #require(renderer.node(for: entity))
        #expect(node.children.isEmpty)       // not streaming, no burst yet

        entity.components[ParticleEmitterComponent.self]?.burst(20)
        renderer.flush()
        entity.components[ParticleEmitterComponent.self]?.burst(8)
        renderer.flush()
        let bursts = node.children.compactMap { $0 as? SKEmitterNode }.filter { $0.name == "__burst" }
        #expect(bursts.map(\.numParticlesToEmit) == [20, 8])
        #expect(bursts.allSatisfy { $0.targetNode === renderer && $0.particleBlendMode == .add })
    }

    @Test func burstSetBeforeAddingStillFires() throws {
        let world = World()
        let renderer = SpriteRenderer(world: world)
        var emitter = ParticleEmitterComponent.puff()
        emitter.burst(6)
        let entity = Entity(components: emitter)
        world.addEntity(entity)
        renderer.flush()
        let burst = try #require(renderer.node(for: entity)?.childNode(withName: "__burst") as? SKEmitterNode)
        #expect(burst.numParticlesToEmit == 6)
    }
}

@MainActor @Suite struct LifetimeTests {
    @Test func entitiesGoWhenTheirTimeIsUp() {
        let world = World()
        world.addSystem(LifetimeSystem.self)
        let short = Entity(components: LifetimeComponent(0.5))
        let long = Entity(components: LifetimeComponent(2))
        let child = Entity(components: LifetimeComponent(0.2))
        long.addChild(child)
        world.addEntity(short)
        world.addEntity(long)

        world.update(deltaTime: 0.3)
        #expect(short.world === world && child.world == nil)
        #expect(abs((short.components[LifetimeComponent.self]?.remaining ?? 0) - 0.2) < 1e-5)
        world.update(deltaTime: 0.3)
        #expect(short.world == nil && long.world === world)
    }

    @Test func oneShotLastsAsLongAsItsEffect() throws {
        let entity = Entity.oneShot(particles: .sparks(), count: 9, at: [10, 20])
        #expect(entity.position == [10, 20])
        let emitter = try #require(entity.components[ParticleEmitterComponent.self])
        #expect(emitter.burstCount == 9 && emitter.burstID == 1)
        let lifetime = try #require(entity.components[LifetimeComponent.self])
        #expect(abs(lifetime.remaining - (emitter.maximumLifetime + 0.1)) < 1e-5)
    }

    @Test func rendererRemovesOneShotsByItself() {
        let world = World()
        let renderer = SpriteRenderer(world: world)
        let effect = Entity.oneShot(particles: .sparks(), at: .zero)
        world.addEntity(effect)
        renderer.update(0)
        renderer.update(1.0 / 15)
        #expect(effect.world === world)
        for frame in 2...20 { renderer.update(Double(frame) / 15) }
        #expect(effect.world == nil)
    }
}

@MainActor @Suite struct ContactEffectTests {
    private func contact(_ impulse: Float, _ a: Entity, _ b: Entity) -> PhysicsEvents.ContactBegan {
        PhysicsEvents.ContactBegan(entityA: a, entityB: b, point: [5, 6], normal: [0, 1], impulse: impulse)
    }

    @Test func softHitsDoNothing() {
        let effect = ContactEffectComponent(count: 10, minimumImpulse: 2)
        let a = Entity(), b = Entity()
        #expect(effect.effect(for: contact(1.9, a, b)) == nil)
        #expect(ContactEffectComponent(particles: nil).effect(for: contact(10, a, b)) == nil)
        let spark = effect.effect(for: contact(2, a, b))
        #expect(spark?.position == [5, 6])
        #expect(spark?.components[ParticleEmitterComponent.self]?.burstCount == 10)
    }

    @Test func harderHitsThrowOutMore() {
        let effect = ContactEffectComponent(count: 10, minimumImpulse: 2)
        let a = Entity(), b = Entity()
        func count(_ effect: ContactEffectComponent, _ impulse: Float) -> Int {
            let entity = effect.effect(for: contact(impulse, a, b))
            return entity?.components[ParticleEmitterComponent.self]?.burstCount ?? 0
        }
        let soft = count(effect, 2), hard = count(effect, 8), harder = count(effect, 80)
        #expect(soft < hard && hard == harder && hard == 20)
        #expect(count(ContactEffectComponent(count: 10, minimumImpulse: 2, scalesWithImpulse: false), 80) == 10)
    }

    @Test func rendererAddsEffectsForPublishedContacts() {
        let world = World()
        let renderer = SpriteRenderer(world: world)
        let crate = Entity(name: "crate", components: ContactEffectComponent(minimumImpulse: 1))
        let floor = Entity(name: "floor")
        world.addEntity(crate)
        world.addEntity(floor)
        world.publish(contact(5, crate, floor), from: [crate, floor])
        world.publish(contact(0.5, crate, floor), from: [crate, floor])
        let effects = world.entities.filter { $0.name == "one-shot" }
        #expect(effects.count == 1)
        #expect(effects.first?.position == [5, 6])
        _ = renderer
    }
}

@MainActor @Suite struct AudioTests {
    @Test func findsFilesAndReadsTheirLength() throws {
        let url = try makeWAV(seconds: 0.25)
        defer { try? FileManager.default.removeItem(at: url) }
        let sound = AudioComponent(url: url, volume: 0.5)
        #expect(abs((sound.duration ?? 0) - 0.25) < 0.01)
        #expect(AudioComponent(named: "no-such-sound").url == nil)
        #expect(AudioComponent(named: "no-such-sound").duration == nil)
    }

    @Test func playCountsUp() {
        var sound = AudioComponent(url: nil)
        sound.play()
        sound.play()
        #expect(sound.playCount == 2)
    }

    @Test func eachPlayAddsAnAudioNode() throws {
        let url = try makeWAV(seconds: 0.1)
        defer { try? FileManager.default.removeItem(at: url) }
        let world = World()
        let renderer = SpriteRenderer(world: world)
        let coin = Entity(components: AudioComponent(url: url))
        world.addEntity(coin)
        renderer.flush()
        let node = try #require(renderer.node(for: coin))
        #expect(node.children.isEmpty)       // nothing played yet

        coin.components[AudioComponent.self]?.play()
        renderer.flush()
        coin.components[AudioComponent.self]?.play()
        renderer.flush()
        coin.components[AudioComponent.self]?.volume = 0.3   // not a new play
        renderer.flush()
        #expect(node.children.filter { $0.name == "__sound" && $0 is SKAudioNode }.count == 2)
    }

    @Test func loopsFollowIsPlaying() throws {
        let url = try makeWAV(seconds: 0.1)
        defer { try? FileManager.default.removeItem(at: url) }
        let world = World()
        let renderer = SpriteRenderer(world: world)
        let engine = Entity(components: AudioComponent(url: url, isLooping: true))
        world.addEntity(engine)
        renderer.flush()
        let loop = try #require(renderer.node(for: engine)?.childNode(withName: "__audio") as? SKAudioNode)
        #expect(loop.autoplayLooped)

        engine.components[AudioComponent.self]?.isPlaying = false
        renderer.flush()
        #expect(renderer.node(for: engine)?.childNode(withName: "__audio") === loop)
        engine.components[AudioComponent.self] = nil
        renderer.flush()
        #expect(renderer.node(for: engine)?.childNode(withName: "__audio") == nil)
    }
}
