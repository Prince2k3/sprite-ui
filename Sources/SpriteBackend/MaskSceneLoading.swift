import ECSCore
import SpriteKit
import SwiftUI

extension SceneLoader {
    /// Imports detached artwork without turning mask nodes into entity children.
    static func maskLayer(from node: SKNode) throws -> MaskLayer {
        func unsupported(_ reason: String) -> SceneLoadingError {
            .unsupportedMask("\(node.name ?? String(describing: type(of: node))): \(reason)")
        }

        var layers: [MaskLayer] = []
        if node is SKCropNode {
            throw unsupported("nested crop nodes")
        } else if let sprite = node as? SKSpriteNode {
            guard sprite.shader == nil else { throw unsupported("custom sprite shaders") }
            guard sprite.blendMode == .alpha else { throw unsupported("non-alpha sprite blending") }
            let size = unscaledSize(of: sprite)
            let anchor = SIMD2(Float(sprite.anchorPoint.x), Float(sprite.anchorPoint.y))
            let colorAlpha = Float(ColorCoding.components(of: Color(sprite.color))[3])
            if let texture = sprite.texture {
                guard sprite.centerRect == CGRect(x: 0, y: 0, width: 1, height: 1) else {
                    throw unsupported("nine-slice texture stretching")
                }
                guard sprite.colorBlendFactor <= 0 || colorAlpha == 1 else {
                    throw unsupported("texture tint with nonopaque alpha")
                }
                guard let image = spriteImage(texture) else { throw unsupported("unreadable texture pixels") }
                layers.append(MaskLayer(.texture(TextureResource(image: image, name: textureName(texture)),
                                                 size: size, anchorPoint: anchor)))
            } else {
                let rect = CGRect(x: -CGFloat(anchor.x * size.x), y: -CGFloat(anchor.y * size.y),
                                  width: CGFloat(size.x), height: CGFloat(size.y))
                layers.append(MaskLayer(.shape(.path(VectorPath(CGPath(rect: rect, transform: nil)))), opacity: colorAlpha))
            }
        } else if let shape = node as? SKShapeNode {
            guard shape.fillShader == nil, shape.strokeShader == nil else { throw unsupported("custom shape shaders") }
            guard shape.fillTexture == nil, shape.strokeTexture == nil else { throw unsupported("shape textures") }
            guard shape.glowWidth <= 0 else { throw unsupported("shape glow") }
            guard shape.blendMode == .alpha else { throw unsupported("non-alpha shape blending") }
            if let path = shape.path {
                let fillAlpha = Float(ColorCoding.components(of: Color(shape.fillColor))[3])
                let strokeAlpha = Float(ColorCoding.components(of: Color(shape.strokeColor))[3])
                if fillAlpha > 0 {
                    layers.append(MaskLayer(.shape(.path(VectorPath(path))), opacity: fillAlpha))
                }
                if strokeAlpha > 0, shape.lineWidth > 0 {
                    let stroke = path.copy(strokingWithWidth: shape.lineWidth, lineCap: shape.lineCap,
                                           lineJoin: shape.lineJoin, miterLimit: shape.miterLimit)
                    layers.append(MaskLayer(.shape(.path(VectorPath(stroke))), opacity: strokeAlpha))
                }
            }
        } else if let effect = node as? SKEffectNode, !(node is SKScene) {
            guard !effect.shouldEnableEffects else { throw unsupported("active effect nodes") }
            guard effect.shader == nil else { throw unsupported("custom effect shaders") }
            guard effect.blendMode == .alpha else { throw unsupported("non-alpha effect blending") }
        } else if type(of: node) != SKNode.self {
            throw unsupported("unsupported node type \(type(of: node))")
        }

        for child in node.children {
            layers.append(try maskLayer(from: child))
        }
        return MaskLayer(layers.isEmpty ? .empty : .group(layers), transform: Transform(
            translation: [Float(node.position.x), Float(node.position.y)],
            rotation: Float(node.zRotation), scale: [Float(node.xScale), Float(node.yScale)],
            zPosition: Float(node.zPosition)
        ), opacity: node.isHidden ? 0 : Float(node.alpha))
    }
}
