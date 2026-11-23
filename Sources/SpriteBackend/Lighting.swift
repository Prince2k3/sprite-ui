import ECSCore
import SpriteKit
import SwiftUI

/// A point light at the entity's position. Move it with normal entity transforms
/// or animation playback; rotation does not change its omnidirectional illumination.
/// Materials opt in through their lighting and shadow masks, matched against
/// `categoryBitMask`. Set the entity's z position above shadow receivers and put
/// shadow casters above the surfaces they shadow.
///
/// Pausing a scene freezes motion but preserves illumination. Disabling the entity,
/// any ancestor, or this component's `isEnabled` switches the light off.
/// If no enabled light matches a sprite, SpriteKit draws it normally (unlit).
///
/// ```swift
/// let lamp = Entity(components: LightComponent(color: .orange, intensity: 0.8))
/// lamp.position = [100, 50]
/// lamp.zPosition = 20
/// floor.components[SpriteComponent.self]?.material.lightingBitMask = 1
/// floor.components[SpriteComponent.self]?.material.shadowedBitMask = 1
/// ```
public struct LightComponent: Component, Hashable, Codable, Sendable {
    /// Diffuse/specular color. Alpha is ignored.
    public var color: Color
    /// Nonnegative multiplier for the diffuse RGB color; ambient and shadows are independent.
    /// Nonfinite or negative values render as zero.
    public var intensity: Float
    /// Constant illumination, unaffected by distance or surface normals. Alpha is ignored.
    public var ambientColor: Color
    /// Color blended into shadows, including its alpha.
    public var shadowColor: Color
    /// Distance attenuation exponent. Zero gives constant intensity.
    /// Nonfinite or negative values render as zero.
    public var falloff: Float
    /// Categories matched by each sprite material's lighting and shadow masks.
    public var categoryBitMask: UInt32
    public var isEnabled: Bool

    public init(color: Color = .white, intensity: Float = 1, ambientColor: Color = .black,
                shadowColor: Color = .black.opacity(0.5), falloff: Float = 1,
                categoryBitMask: UInt32 = 1, isEnabled: Bool = true) {
        self.color = color; self.intensity = intensity; self.ambientColor = ambientColor
        self.shadowColor = shadowColor; self.falloff = falloff
        self.categoryBitMask = categoryBitMask; self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey { case color, intensity, ambientColor, shadowColor, falloff, categoryBitMask, isEnabled }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(color: try c.decodeColor(forKey: .color), intensity: try c.decode(Float.self, forKey: .intensity),
                  ambientColor: try c.decodeColor(forKey: .ambientColor), shadowColor: try c.decodeColor(forKey: .shadowColor),
                  falloff: try c.decode(Float.self, forKey: .falloff), categoryBitMask: try c.decode(UInt32.self, forKey: .categoryBitMask),
                  isEnabled: try c.decode(Bool.self, forKey: .isEnabled))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(color: color, forKey: .color); try c.encode(intensity, forKey: .intensity)
        try c.encode(color: ambientColor, forKey: .ambientColor); try c.encode(color: shadowColor, forKey: .shadowColor)
        try c.encode(falloff, forKey: .falloff); try c.encode(categoryBitMask, forKey: .categoryBitMask); try c.encode(isEnabled, forKey: .isEnabled)
    }

    var nativeColor: SKColor {
        let c = ColorCoding.components(of: color)
        let strength = intensity.isFinite ? max(0, intensity) : 0
        return SKColor(red: CGFloat(c[0]) * CGFloat(strength), green: CGFloat(c[1]) * CGFloat(strength), blue: CGFloat(c[2]) * CGFloat(strength), alpha: 1)
    }
}

extension SpriteRenderer {
    static let lightNodeName = "__light"
    static let lightBinding = Binding<LightComponent>(apply: { new, _, node, animator in
        guard let value = new else {
            node.childNode(withName: lightNodeName)?.removeFromParent()
            return
        }
        let light: SKLightNode
        if let existing = node.childNode(withName: lightNodeName) as? SKLightNode { light = existing }
        else {
            light = SKLightNode(); light.name = lightNodeName; node.addChild(light)
        }
        let wasEnabled = light.isEnabled
        configureLight(light, value: value,
                       isActive: animator.renderer.world.entity(withID: animator.entityID)?.isActive ?? false)
        if !wasEnabled && light.isEnabled { animator.renderer.needsLightingRefresh = true }
    })

    private static func configureLight(_ light: SKLightNode, value: LightComponent, isActive: Bool) {
        light.lightColor = value.nativeColor
        light.ambientColor = SKColor(value.ambientColor)
        light.shadowColor = SKColor(value.shadowColor)
        light.falloff = CGFloat(value.falloff.isFinite ? max(0, value.falloff) : 0)
        light.categoryBitMask = value.categoryBitMask
        light.isEnabled = value.isEnabled && isActive
    }

    func synchronizeLightingActivation(_ entity: Entity, node: SKNode) {
        if let light = node.childNode(withName: Self.lightNodeName) as? SKLightNode {
            let enabled = entity.isActive && (entity.components[LightComponent.self]?.isEnabled ?? false)
            if !light.isEnabled && enabled { needsLightingRefresh = true }
            light.isEnabled = enabled
        }
        if let sprite = node.childNode(withName: Self.spriteNodeName) as? SKSpriteNode {
            let mask = entity.isActive ? (entity.components[SpriteComponent.self]?.material.shadowCastBitMask ?? 0) : 0
            if sprite.shadowCastBitMask != mask { needsLightingRefresh = true; sprite.shadowCastBitMask = mask }
        }
    }

    func refreshLightingIfNeeded() {
        guard needsLightingRefresh else { return }
        needsLightingRefresh = false
        // SpriteKit retains stationary-light shadow maps after sprite mask edits,
        // even after a same-frame enable transition. Rebuild only the private
        // light children, once per batch; entity nodes, transforms and actions stay.
        for entity in world.performQuery(EntityQuery(where: .has(LightComponent.self))) {
            guard let parent = node(for: entity), let old = parent.childNode(withName: Self.lightNodeName) as? SKLightNode,
                  old.isEnabled, let value = entity.components[LightComponent.self] else { continue }
            let light = SKLightNode(); light.name = Self.lightNodeName
            Self.configureLight(light, value: value, isActive: entity.isActive)
            old.removeFromParent(); parent.addChild(light)
        }
    }
}
