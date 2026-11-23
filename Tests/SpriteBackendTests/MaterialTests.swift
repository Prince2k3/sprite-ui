import ECSCore
import Foundation
import SpriteKit
import SwiftUI
import Testing
@testable import SpriteBackend

@MainActor @Suite struct MaterialTests {
    func sprite(_ renderer: SpriteRenderer, _ entity: Entity) throws -> SKSpriteNode {
        try #require(renderer.node(for: entity)?.childNode(withName: "__sprite") as? SKSpriteNode)
    }
    func texture() -> TextureResource { TextureResource(image: SpriteImage(width: 1, height: 1, pixels: [255, 255, 255, 255])) }

    @Test func legacyFieldsAndMaterialHaveOneSourceOfTruth() {
        var component = SpriteComponent(imageName: "hero", tint: .red, tintAmount: 0.3, opacity: 0.5)
        #expect(component.material.tint == .red && component.material.tintAmount == 0.3 && component.material.opacity == 0.5)
        component.material.tint = .blue; component.material.opacity = 0.8
        #expect(component.color == .blue && component.opacity == 0.8)
        component.colorBlendFactor = 0.2
        #expect(component.material.tintAmount == 0.2 && component.material.blendMode == .alpha)
        let solid = SpriteComponent(color: .green, size: [10, 10])
        #expect(solid.material.tint == .green && solid.material.tintAmount == 1)
    }

    @Test func typedOverridesResetToDefaultsAndRejectInvalidEdits() throws {
        var material = SpriteMaterial(shader: .spriteEffects)
        #expect(material.parameter(named: "a_flash") == .float(0))
        try material.setParameter(.float(0.6), named: "a_flash")
        #expect(material.parameter(named: "a_flash") == .float(0.6))
        #expect(throws: ShaderError.typeMismatch("a_flash")) { try material.setParameter(.vector2([1, 2]), named: "a_flash") }
        #expect(throws: ShaderError.nonFiniteValue("a_flash")) { try material.setParameter(.float(.nan), named: "a_flash") }
        #expect(throws: ShaderError.unknownParameter("a_unknown")) { try material.setParameter(.float(1), named: "a_unknown") }
        #expect(material.parameter(named: "a_flash") == .float(0.6))
        try material.setParameter(nil, named: "a_flash")
        #expect(material.parameters.isEmpty && material.parameter(named: "a_flash") == .float(0))
        try material.setParameter(.float(1), named: "a_flash")
        material.shader = nil
        #expect(material.parameters.isEmpty && material.parameter(named: "a_flash") == nil)
    }

    @Test func schemasRejectReservedNamesAndNonFiniteDefaults() throws {
        #expect(throws: ShaderError.emptySource) { try ShaderResource(source: " \n ") }
        #expect(throws: ShaderError.invalidName("u_time")) { try ShaderResource(source: "x", parameters: ["u_time": .float(0)]) }
        #expect(throws: ShaderError.invalidName("a_bad-name")) { try ShaderResource(source: "x", parameters: ["a_bad-name": .float(0)]) }
        #expect(throws: ShaderError.nonFiniteValue("a_v")) { try ShaderResource(source: "x", parameters: ["a_v": .vector3([0, .infinity, 0])]) }
        #expect(throws: ShaderError.invalidName("u_texture")) { try ShaderResource(source: "x", textures: ["u_texture": texture()]) }
    }

    @Test func numericAttributesArePerSpriteWhileCodeAndSamplersAreShared() throws {
        let shader = try ShaderResource(source: "void main() { gl_FragColor = texture2D(u_mask, a_uv) * vec4(a_rgb, a_amount) * a_color; }",
            parameters: ["a_amount": .float(0.25), "a_uv": .vector2([0.2, 0.4]), "a_rgb": .vector3([1, 0.5, 0]), "a_color": .vector4([1, 1, 1, 1])],
            textures: ["u_mask": texture()])
        let world = World(), renderer = SpriteRenderer(world: world)
        var material = SpriteMaterial(shader: shader)
        let a = Entity(components: SpriteComponent(texture: texture(), material: material))
        try material.setParameter(.float(0.9), named: "a_amount")
        let b = Entity(components: SpriteComponent(texture: texture(), material: material))
        world.addEntity(a); world.addEntity(b)
        let na = try sprite(renderer, a), nb = try sprite(renderer, b)
        #expect(na.shader === nb.shader)
        #expect(na.value(forAttributeNamed: "a_amount")?.floatValue == 0.25)
        #expect(nb.value(forAttributeNamed: "a_amount")?.floatValue == 0.9)
        #expect(na.value(forAttributeNamed: "a_uv")?.vectorFloat2Value == [0.2, 0.4])
        #expect(na.value(forAttributeNamed: "a_rgb")?.vectorFloat3Value == [1, 0.5, 0])
        #expect(na.value(forAttributeNamed: "a_color")?.vectorFloat4Value == [1, 1, 1, 1])
        #expect(na.shader?.uniformNamed("u_mask")?.textureValue === shader.textures["u_mask"]?.nativeTexture)
        #expect(na.value(forAttributeNamed: "a_amount") !== nb.value(forAttributeNamed: "a_amount"))
    }

    @Test func switchingAndRemovingShadersDropsOldAttributes() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let entity = Entity(components: SpriteComponent(texture: texture(), material: SpriteMaterial(shader: .spriteEffects)))
        world.addEntity(entity)
        let node = try sprite(renderer, entity)
        try entity.components[SpriteComponent.self]?.material.setParameter(.float(1), named: "a_flash")
        renderer.flush(); #expect(node.value(forAttributeNamed: "a_flash")?.floatValue == 1)
        try entity.components[SpriteComponent.self]?.material.setParameter(nil, named: "a_flash")
        renderer.flush(); #expect(node.value(forAttributeNamed: "a_flash")?.floatValue == 0)
        let replacement = try ShaderResource(source: "void main() { gl_FragColor = SKDefaultShading() * a_v; }", parameters: ["a_v": .float(0.5)])
        entity.components[SpriteComponent.self]?.material.shader = replacement
        renderer.flush()
        #expect(node.attributeValues.keys.sorted() == ["a_v"] && node.shader === replacement.nativeShader)
        entity.components[SpriteComponent.self]?.material.shader = nil
        renderer.flush(); #expect(node.shader == nil && node.attributeValues.isEmpty)
        entity.components.remove(SpriteComponent.self); renderer.flush()
        #expect(renderer.node(for: entity)?.childNode(withName: "__sprite") == nil)
    }

    @Test func allBlendModesUpdateTheExistingSprite() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let entity = Entity(components: SpriteComponent(color: .red, size: [10, 10])); world.addEntity(entity)
        let node = try sprite(renderer, entity)
        for mode in SpriteBlendMode.allCases {
            entity.components[SpriteComponent.self]?.material.blendMode = mode; renderer.flush()
            #expect(try sprite(renderer, entity) === node && node.blendMode == mode.native)
            let imported = SceneLoader.spriteComponent(from: node)
            #expect(imported.material.blendMode == mode)
        }
    }

    @Test func animatedTexturesKeepTheirShaderAndIndependentOverrides() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let a = texture(), b = texture()
        let clip = try AnimationResource(frames: [a, b], framesPerSecond: 4)
        let entity = Entity(components: SpriteComponent(texture: a, material: SpriteMaterial(shader: .spriteEffects)))
        world.addEntity(entity)
        let controller = try entity.playAnimation(clip)
        try entity.components[SpriteComponent.self]?.material.setParameter(.float(0.75), named: "a_flash")
        world.update(deltaTime: 0.3); renderer.flush()
        let node = try sprite(renderer, entity)
        #expect(controller.currentTime == 0.3 && node.texture === b.nativeTexture)
        #expect(node.shader === ShaderResource.spriteEffects.nativeShader)
        #expect(node.value(forAttributeNamed: "a_flash")?.floatValue == 0.75)
    }

    @Test func clonedEntitiesShareResourcesButOwnMaterialParameters() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let original = Entity(components: SpriteComponent(texture: texture(), material: SpriteMaterial(shader: .spriteEffects)))
        let clone = original.clone()
        world.addEntity(original); world.addEntity(clone)
        try clone.components[SpriteComponent.self]?.material.setParameter(.float(1), named: "a_flash"); renderer.flush()
        #expect(original.components[SpriteComponent.self]?.material.parameter(named: "a_flash") == .float(0))
        let a = try sprite(renderer, original), b = try sprite(renderer, clone)
        #expect(a.shader === b.shader && a.texture === b.texture)
        #expect(a.value(forAttributeNamed: "a_flash")?.floatValue == 0 && b.value(forAttributeNamed: "a_flash")?.floatValue == 1)
    }

    @Test func pooledNodesReapplyResetMaterialsWithoutLeakingAttributes() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let base = SpriteMaterial(shader: .spriteEffects)
        let root = Entity(components: SpriteComponent(texture: texture(), material: base))
        let pool = try EntityPool(prefab: PrefabResource(root: root), scene: world, capacity: 2, prewarm: 2,
                                  onAcquire: { $0.components[SpriteComponent.self]?.material = base })
        let a = try #require(try pool.acquire()), b = try #require(try pool.acquire())
        let node = try sprite(renderer, a)
        try a.components[SpriteComponent.self]?.material.setParameter(.float(1), named: "a_flash"); renderer.flush()
        #expect(try sprite(renderer, b).value(forAttributeNamed: "a_flash")?.floatValue == 0)
        try pool.release(a)
        let again = try #require(try pool.acquire())
        #expect(again === a && renderer.node(for: again)?.childNode(withName: "__sprite") === node)
        #expect(node.value(forAttributeNamed: "a_flash")?.floatValue == 0)
        #expect(node.shader === ShaderResource.spriteEffects.nativeShader)
    }

    @Test func snapshotsAndPrefabFilesPreserveMaterialsAndSamplerPixels() async throws {
        SpriteRenderer.registerComponents()
        let shader = try ShaderResource(source: "void main() { gl_FragColor = texture2D(u_mask, v_tex_coord) * a_amount; }",
                                       parameters: ["a_amount": .float(0)], textures: ["u_mask": texture()])
        var material = SpriteMaterial(tint: Color(.sRGB, red: 0.2, green: 0.5, blue: 0.8), tintAmount: 0.2,
                                      opacity: 0.4, blendMode: .screen, shader: shader)
        try material.setParameter(.float(0.6), named: "a_amount")
        let world = World(), renderer = SpriteRenderer(world: world)
        world.addEntity(Entity(components: SpriteComponent(texture: texture(), material: material)))
        let snapshot = try WorldSnapshot(data: world.snapshot().jsonData())
        world.restore(snapshot)
        let entity = try #require(world.entities.first), node = try sprite(renderer, entity)
        let restored = try #require(entity.components[SpriteComponent.self]?.material)
        #expect(restored.shader == shader && restored.parameters == material.parameters)
        #expect(restored.blendMode == material.blendMode && restored.opacity == material.opacity && restored.tintAmount == material.tintAmount)
        #expect(restored.shader?.textures["u_mask"]?.image == shader.textures["u_mask"]?.image)
        for (a, b) in zip(ColorCoding.components(of: restored.tint), ColorCoding.components(of: material.tint)) { #expect(abs(a - b) < 0.00001) }
        #expect(node.blendMode == .screen && node.value(forAttributeNamed: "a_amount")?.floatValue == 0.6)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".prefab")
        defer { try? FileManager.default.removeItem(at: url) }
        try PrefabResource(root: entity).write(to: url)
        let loaded = try await ResourceLibrary().prefab(contentsOf: url).instantiate()
        #expect(loaded.components[SpriteComponent.self]?.material.shader == shader)
        #expect(loaded.components[SpriteComponent.self]?.material.parameters == material.parameters)
    }

    @Test func oldSpriteSnapshotsDefaultToAlphaWithNoShader() throws {
        let data = try JSONEncoder().encode(SpriteComponent(color: .red, size: [10, 20], opacity: 0.6))
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]); object["material"] = nil
        let old = try JSONDecoder().decode(SpriteComponent.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.material.shader == nil && old.material.blendMode == .alpha && old.opacity == 0.6 && old.colorBlendFactor == 1)
    }

    @Test func decodedMaterialOverridesAreValidated() throws {
        var material = SpriteMaterial(shader: .spriteEffects)
        try material.setParameter(.float(0.3), named: "a_flash")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(material)) as? [String: Any])
        object["parameters"] = ["a_flash": ["vector2": ["_0": [1, 2]]]]
        #expect(throws: ShaderError.typeMismatch("a_flash")) {
            try JSONDecoder().decode(SpriteMaterial.self, from: JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test func shaderLoadsCoalesceAndCacheKeysIncludeParameterSchemas() async throws {
        let library = ResourceLibrary()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".fsh")
        defer { try? FileManager.default.removeItem(at: url) }
        try "void main() { gl_FragColor = SKDefaultShading() * a_v; }".write(to: url, atomically: true, encoding: .utf8)
        async let a = library.shader(contentsOf: url, parameters: ["a_v": .float(0)])
        async let b = library.shader(contentsOf: url, parameters: ["a_v": .float(0)])
        let (first, second) = try await (a, b)
        #expect(first == second && first.nativeShader === second.nativeShader && library.cachedResourceCount == 1)
        let other = try await library.shader(contentsOf: url, parameters: ["a_v": .vector4([1, 1, 1, 1])])
        #expect(other != first && library.cachedResourceCount == 2)
        library.removeAllCachedResources()
        #expect(library.cachedResourceCount == 0)
        let reloaded = try await library.shader(contentsOf: url, parameters: ["a_v": .float(0)])
        #expect(reloaded != first && first.nativeShader.source == reloaded.source)
    }

    @Test func failedShaderLoadsCanBeRetried() async throws {
        let library = ResourceLibrary()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".fsh")
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: ResourceLoadingError.unreadable(url)) { try await library.shader(contentsOf: url) }
        try " ".write(to: url, atomically: true, encoding: .utf8)
        await #expect(throws: ShaderError.emptySource) { try await library.shader(contentsOf: url) }
        try "void main() { gl_FragColor = SKDefaultShading(); }".write(to: url, atomically: true, encoding: .utf8)
        #expect(try await library.shader(contentsOf: url).source.contains("void main"))
        #expect(library.cachedResourceCount == 1)
    }
}
