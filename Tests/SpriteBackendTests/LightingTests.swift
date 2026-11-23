import ECSCore
import Foundation
import SpriteKit
import SwiftUI
import Testing
@testable import SpriteBackend

@MainActor @Suite struct LightingTests {
    func light(_ renderer: SpriteRenderer, _ entity: Entity) throws -> SKLightNode {
        try #require(renderer.node(for: entity)?.childNode(withName: "__light") as? SKLightNode)
    }
    func sprite(_ renderer: SpriteRenderer, _ entity: Entity) throws -> SKSpriteNode {
        try #require(renderer.node(for: entity)?.childNode(withName: "__sprite") as? SKSpriteNode)
    }
    func normal(_ value: UInt8 = 128) -> TextureResource {
        TextureResource(image: SpriteImage(width: 2, height: 1, pixels: [value, 128, 255, 255, 128, 128, 255, 255]))
    }
    func closeColor(_ a: Color, _ b: Color) -> Bool {
        zip(ColorCoding.components(of: a), ColorCoding.components(of: b)).allSatisfy { abs($0 - $1) < 0.00001 }
    }
    func color(_ c: SKColor) -> Color {
        #if canImport(UIKit)
        Color(uiColor: c)
        #else
        Color(nsColor: c)
        #endif
    }

    @Test func legacySpritesStayUnlitAndCastNoShadows() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let entity = Entity(components: SpriteComponent(color: .white, size: [20, 20]))
        world.addEntity(entity); world.addEntity(Entity(components: LightComponent()))
        let node = try sprite(renderer, entity)
        #expect(node.lightingBitMask == 0 && node.shadowCastBitMask == 0 && node.shadowedBitMask == 0 && node.normalTexture == nil)
    }

    @Test func lightSettingsReachTheBackendAndUpdateInPlace() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let config = LightComponent(color: Color(.sRGB, red: 0.8, green: 0.4, blue: 0.2), intensity: 0.5,
                                    ambientColor: .gray, shadowColor: .purple.opacity(0.4), falloff: 2, categoryBitMask: 4)
        let entity = Entity(components: config); entity.position = [30, 40]; entity.zPosition = 15; world.addEntity(entity)
        let node = try light(renderer, entity)
        #expect(node.isEnabled && node.falloff == 2 && node.categoryBitMask == 4)
        #expect(closeColor(color(node.lightColor), Color(.sRGB, red: 0.4, green: 0.2, blue: 0.1)))
        #expect(closeColor(color(node.ambientColor), .gray) && closeColor(color(node.shadowColor), .purple.opacity(0.4)))
        #expect(node.parent?.position == CGPoint(x: 30, y: 40) && node.parent?.zPosition == 15)
        entity.components[LightComponent.self]?.intensity = 0
        entity.components[LightComponent.self]?.categoryBitMask = 8
        entity.components[LightComponent.self]?.isEnabled = false; renderer.flush()
        #expect(try light(renderer, entity) === node && !node.isEnabled && node.categoryBitMask == 8)
        #expect(closeColor(color(node.lightColor), .black) && closeColor(color(node.ambientColor), .gray))
    }

    @Test func invalidIntensityAndFalloffRenderAsZeroWithoutChangingTheModel() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let entity = Entity(components: LightComponent(intensity: -.infinity, falloff: .nan)); world.addEntity(entity)
        let node = try light(renderer, entity)
        #expect(node.falloff == 0 && closeColor(color(node.lightColor), .black))
        #expect(entity.components[LightComponent.self]?.falloff.isNaN == true)
        entity.components[LightComponent.self]?.intensity = -2
        entity.components[LightComponent.self]?.falloff = -3; renderer.flush()
        #expect(node.falloff == 0 && closeColor(color(node.lightColor), .black))
    }

    @Test func masksAndNormalMapsUpdateAndClearWithoutReplacingTheSprite() throws {
        let world = World(), renderer = SpriteRenderer(world: world), first = normal(), second = normal(64)
        let material = SpriteMaterial(normalMap: first, lightingBitMask: 2, shadowCastBitMask: 4, shadowedBitMask: 8)
        let entity = Entity(components: SpriteComponent(material: material, size: [20, 20])); world.addEntity(entity)
        let node = try sprite(renderer, entity)
        #expect(node.normalTexture === first.nativeTexture)
        #expect(node.lightingBitMask == 2 && node.shadowCastBitMask == 4 && node.shadowedBitMask == 8)
        entity.components[SpriteComponent.self]?.material.normalMap = second; renderer.flush()
        #expect(try sprite(renderer, entity) === node && node.normalTexture === second.nativeTexture)
        entity.components[SpriteComponent.self]?.material = SpriteMaterial(); renderer.flush()
        #expect(node.normalTexture == nil && node.lightingBitMask == 0 && node.shadowCastBitMask == 0 && node.shadowedBitMask == 0)
    }

    @Test func customShadersOverrideIlluminationAndRemovalRestoresIt() throws {
        let world = World(), renderer = SpriteRenderer(world: world), map = normal()
        let entity = Entity(components: SpriteComponent(material: SpriteMaterial(normalMap: map, lightingBitMask: 3,
                                                    shadowCastBitMask: 2, shadowedBitMask: 1), size: [20, 20]))
        world.addEntity(entity); let node = try sprite(renderer, entity)
        entity.components[SpriteComponent.self]?.material.shader = .spriteEffects; renderer.flush()
        #expect(node.shader != nil && node.lightingBitMask == 0 && node.normalTexture === map.nativeTexture)
        #expect(node.shadowCastBitMask == 2 && node.shadowedBitMask == 1)
        #expect(entity.components[SpriteComponent.self]?.material.lightingBitMask == 3)
        entity.components[SpriteComponent.self]?.material.shader = nil; renderer.flush()
        #expect(node.shader == nil && node.lightingBitMask == 3)
    }

    @Test func disabledAncestorsSwitchOffLightsAndOccludersImmediately() throws {
        let world = World(), renderer = SpriteRenderer(world: world), parent = Entity()
        let entity = Entity(components: LightComponent(), SpriteComponent(material: SpriteMaterial(shadowCastBitMask: 1), size: [10, 10]))
        parent.addChild(entity); parent.isEnabled = false; world.addEntity(parent)
        let lamp = try light(renderer, entity), shape = try sprite(renderer, entity)
        #expect(!lamp.isEnabled && shape.shadowCastBitMask == 0)
        parent.isEnabled = true
        #expect(lamp.isEnabled && shape.shadowCastBitMask == 1)
        world.isPaused = true; #expect(lamp.isEnabled && shape.shadowCastBitMask == 1)
        parent.isEnabled = false; #expect(!lamp.isEnabled && shape.shadowCastBitMask == 0)
        entity.components[LightComponent.self]?.isEnabled = false
        entity.components[SpriteComponent.self]?.material.shadowCastBitMask = 4
        renderer.flush(); parent.isEnabled = true
        #expect(!lamp.isEnabled && shape.shadowCastBitMask == 4)
        world.root.isEnabled = false; #expect(!lamp.isEnabled && shape.shadowCastBitMask == 0)
    }

    @Test func stationaryLightsRefreshAfterBatchedMaskEditsButNotEveryFrame() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let lamp = Entity(components: LightComponent())
        let a = Entity(components: SpriteComponent(material: SpriteMaterial(shadowCastBitMask: 1), size: [10, 10]))
        let b = a.clone(); world.addEntity(lamp); world.addEntity(a); world.addEntity(b); renderer.flush()
        let parent = try #require(renderer.node(for: lamp)), original = try light(renderer, lamp)
        let position = parent.position
        a.components[SpriteComponent.self]?.material.shadowCastBitMask = 0
        b.components[SpriteComponent.self]?.material.shadowedBitMask = 1
        renderer.flush()
        let refreshed = try light(renderer, lamp)
        #expect(refreshed !== original && original.scene == nil && parent.position == position && refreshed.isEnabled)
        renderer.flush()
        a.components[SpriteComponent.self]?.color = .red; renderer.flush()
        #expect(try light(renderer, lamp) === refreshed)
        b.isEnabled = false; renderer.flush()
        #expect(try light(renderer, lamp) !== refreshed && renderer.node(for: lamp) === parent)
    }

    @Test func reenablingALightRefreshesMasksChangedWhileItWasDormant() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let lamp = Entity(components: LightComponent()), caster = Entity(components: SpriteComponent(material: SpriteMaterial(shadowCastBitMask: 1), size: [10, 10]))
        world.addEntity(lamp); world.addEntity(caster); renderer.flush()
        let previous = try light(renderer, lamp)
        lamp.isEnabled = false; caster.components[SpriteComponent.self]?.material.shadowCastBitMask = 0; renderer.flush()
        #expect(!previous.isEnabled)
        lamp.isEnabled = true; renderer.flush()
        #expect(try light(renderer, lamp) !== previous && light(renderer, lamp).isEnabled)
        #expect(try sprite(renderer, caster).shadowCastBitMask == 0)
    }

    @Test func removingLightComponentsAndEntitiesLeavesNoIlluminationNodes() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let entity = Entity(components: LightComponent()); world.addEntity(entity)
        let old = try light(renderer, entity)
        entity.components.remove(LightComponent.self); renderer.flush()
        #expect(old.parent == nil && renderer.node(for: entity)?.childNode(withName: "__light") == nil)
        entity.components.set(LightComponent()); renderer.flush()
        let replacement = try light(renderer, entity)
        #expect(replacement !== old)
        entity.removeFromParent(); #expect(renderer.node(for: entity) == nil && replacement.scene == nil)
    }

    @Test func clonesOwnLightSettingsAndShareImmutableNormalMaps() throws {
        let world = World(), renderer = SpriteRenderer(world: world), map = normal()
        let original = Entity(components: LightComponent(), SpriteComponent(material: SpriteMaterial(normalMap: map, lightingBitMask: 1), size: [10, 10]))
        let copy = original.clone(); world.addEntity(original); world.addEntity(copy)
        copy.components[LightComponent.self]?.intensity = 0.25
        copy.components[SpriteComponent.self]?.material.lightingBitMask = 2; renderer.flush()
        #expect(original.components[LightComponent.self]?.intensity == 1)
        #expect(try light(renderer, original) !== light(renderer, copy))
        #expect(try sprite(renderer, original).normalTexture === sprite(renderer, copy).normalTexture)
        #expect(try sprite(renderer, original).lightingBitMask == 1 && sprite(renderer, copy).lightingBitMask == 2)
    }

    @Test func poolReleaseSwitchesOffLightsAndAcquireReusesEntityNodes() throws {
        let world = World(), renderer = SpriteRenderer(world: world), map = normal()
        let base = SpriteMaterial(normalMap: map, lightingBitMask: 1, shadowCastBitMask: 1)
        let template = Entity(components: LightComponent(), SpriteComponent(material: base, size: [10, 10]))
        let pool = try EntityPool(prefab: PrefabResource(root: template), scene: world, capacity: 2, prewarm: 2,
            onAcquire: { $0.components.set(LightComponent()); $0.components[SpriteComponent.self]?.material = base })
        let a = try #require(try pool.acquire()), b = try #require(try pool.acquire())
        renderer.flush()
        let lamp = try light(renderer, a), shape = try sprite(renderer, a), parent = try #require(renderer.node(for: a))
        a.components[LightComponent.self]?.categoryBitMask = 8
        a.components[SpriteComponent.self]?.material.normalMap = nil; renderer.flush()
        #expect(try light(renderer, b).categoryBitMask == 1 && sprite(renderer, b).normalTexture === map.nativeTexture)
        try pool.release(a)
        #expect(!lamp.isEnabled && shape.shadowCastBitMask == 0)
        let reused = try #require(try pool.acquire())
        renderer.flush()
        let active = try light(renderer, reused)
        #expect(reused === a && active.isEnabled && active.categoryBitMask == 1)
        #expect(try sprite(renderer, reused) === shape && renderer.node(for: reused) === parent)
        #expect(shape.normalTexture === map.nativeTexture && shape.shadowCastBitMask == 1)
    }

    @Test func frameAndTransformPlaybackKeepMaterialLighting() throws {
        let world = World(), renderer = SpriteRenderer(world: world), first = normal(), second = normal(64)
        let clip = try AnimationResource.group([.init(frames: [first, second], framesPerSecond: 4), .move(to: [100, 30], duration: 1)])
        let entity = Entity(components: LightComponent(), SpriteComponent(texture: first,
            material: SpriteMaterial(normalMap: first, lightingBitMask: 1, shadowCastBitMask: 2)))
        world.addEntity(entity); try entity.playAnimation(clip)
        world.update(deltaTime: 0.3); renderer.flush()
        let node = try sprite(renderer, entity)
        #expect(node.texture === second.nativeTexture && node.normalTexture === first.nativeTexture)
        #expect(node.lightingBitMask == 1 && node.shadowCastBitMask == 2)
        #expect(try light(renderer, entity).parent?.position == CGPoint(x: 30, y: 9))
    }

    @Test func oldMaterialJSONDefaultsToNoLighting() throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(SpriteMaterial())) as? [String: Any])
        for key in ["normalMap", "lightingBitMask", "shadowCastBitMask", "shadowedBitMask"] { object[key] = nil }
        let material = try JSONDecoder().decode(SpriteMaterial.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(material.normalMap == nil && material.lightingBitMask == 0 && material.shadowCastBitMask == 0 && material.shadowedBitMask == 0)
    }

    @Test func snapshotsAndPrefabsKeepLightsNormalPixelsAndMasks() async throws {
        let world = World(), renderer = SpriteRenderer(world: world), map = normal()
        let original = LightComponent(color: .orange, intensity: 0.7, ambientColor: .gray, shadowColor: .black.opacity(0.8), falloff: 1.5, categoryBitMask: 8)
        let root = Entity(name: "lamp", components: original, SpriteComponent(material: SpriteMaterial(normalMap: map,
                                    lightingBitMask: 8, shadowCastBitMask: 8, shadowedBitMask: 8), size: [20, 20]))
        world.addEntity(root); world.restore(try WorldSnapshot(data: world.snapshot().jsonData()))
        let restored = try #require(world.entities.first), config = try #require(restored.components[LightComponent.self])
        #expect(config.intensity == 0.7 && config.categoryBitMask == 8 && closeColor(config.color, original.color))
        #expect(closeColor(config.ambientColor, original.ambientColor) && closeColor(config.shadowColor, original.shadowColor))
        #expect(try light(renderer, restored).falloff == 1.5 && sprite(renderer, restored).lightingBitMask == 8)
        #expect(restored.components[SpriteComponent.self]?.material.normalMap?.image == map.image)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".prefab")
        defer { try? FileManager.default.removeItem(at: url) }
        try PrefabResource(root: restored).write(to: url)
        let prefab = try await ResourceLibrary().prefab(contentsOf: url), copy = prefab.instantiate()
        #expect(copy.components[LightComponent.self]?.categoryBitMask == 8 && copy.components[SpriteComponent.self]?.material.shadowedBitMask == 8)
    }

    @Test func archivedSceneLightsAndNormalMappedSpritesLoadWithTheirHierarchy() throws {
        let scene = SKScene(size: CGSize(width: 200, height: 200)); scene.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        let group = SKNode(); group.name = "rig"; group.position = CGPoint(x: 10, y: 20); scene.addChild(group)
        let lamp = SKLightNode(); lamp.name = "lamp"; lamp.position = CGPoint(x: 30, y: 40); lamp.zPosition = 20
        lamp.lightColor = .orange; lamp.ambientColor = .gray; lamp.shadowColor = .black.withAlphaComponent(0.75)
        lamp.categoryBitMask = 4; lamp.falloff = 1.6; lamp.isEnabled = false; group.addChild(lamp)
        let target = SKSpriteNode(color: .white, size: CGSize(width: 20, height: 20)); target.name = "surface"
        target.normalTexture = normal().nativeTexture; target.lightingBitMask = 4; target.shadowCastBitMask = 8; target.shadowedBitMask = 2
        group.addChild(target)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sks")
        defer { try? FileManager.default.removeItem(at: url) }
        try NSKeyedArchiver.archivedData(withRootObject: scene, requiringSecureCoding: false).write(to: url)
        let loaded = try SceneLoader().load(contentsOf: url)
        let entity = try #require(loaded.findEntity(named: "lamp")), component = try #require(entity.components[LightComponent.self])
        #expect(entity.parent?.name == "rig" && entity.position == [30, 40] && entity.zPosition == 20)
        #expect(!component.isEnabled && component.categoryBitMask == 4 && abs(component.falloff - 1.6) < 0.0001)
        #expect(closeColor(component.color, color(lamp.lightColor)) && closeColor(component.ambientColor, color(lamp.ambientColor)))
        let surface = try #require(loaded.findEntity(named: "surface")?.components[SpriteComponent.self])
        #expect(surface.material.normalMap?.image.pixels == normal().image.pixels)
        #expect(surface.material.lightingBitMask == 4 && surface.material.shadowCastBitMask == 8 && surface.material.shadowedBitMask == 2)
        let world = World(), renderer = SpriteRenderer(world: world); world.addEntity(loaded)
        #expect(try !light(renderer, entity).isEnabled)
    }
}
