import ECSCore
import SpriteKit
import SwiftUI

#if canImport(UIKit)
typealias DrawingFont = UIFont
#else
typealias DrawingFont = NSFont
#endif

/// A portable system font or a PostScript font name installed by the app.
/// Missing named fonts use the platform system font. Sizes are in scene points.
public enum TextFont: Hashable, Codable, Sendable {
    public enum Weight: String, Codable, Sendable { case regular, medium, semibold, bold }
    case system(size: Float = 24, weight: Weight = .regular)
    case named(String, size: Float)

    public var size: Float {
        get { switch self { case .system(let size, _), .named(_, let size): size } }
        set { switch self {
        case .system(_, let weight): self = .system(size: newValue, weight: weight)
        case .named(let name, _): self = .named(name, size: newValue)
        } }
    }

    @MainActor var native: DrawingFont {
        let size = max(0.01, drawingSize(self.size))
        switch self {
        case .named(let name, _): return DrawingFont(name: name, size: size) ?? DrawingFont.systemFont(ofSize: size)
        case .system(_, let weight):
            let native: DrawingFont.Weight = switch weight { case .regular: .regular; case .medium: .medium; case .semibold: .semibold; case .bold: .bold }
            return DrawingFont.systemFont(ofSize: size, weight: native)
        }
    }
}

/// World-space text. Unlike a SwiftUI attachment, it follows the camera's zoom,
/// participates in render groups, and can be saved, cloned and pooled.
/// Text bounds provide implicit hit testing; add a CollisionComponent to override
/// them. Text never creates a physics body. Use child entities to layer labels
/// over shapes or sprites with independent transforms and z ordering.
///
/// Transform and opacity changes animate with withAnimation. Layout and font edits
/// take effect immediately. Colors are saved as resolved sRGB values.
///
/// ```swift
/// let caption = Entity(components: TextComponent("Checkpoint", font: .system(size: 20, weight: .bold)))
/// caption.components[TextComponent.self]?.text = "Checkpoint reached"
/// ```
public struct TextComponent: Component, Hashable, Codable, Sendable {
    public enum HorizontalAlignment: String, Codable, Sendable { case left, center, right }
    public enum VerticalAlignment: String, Codable, Sendable { case baseline, center, top, bottom }
    public enum LineBreak: String, Codable, Sendable { case wordWrap, characterWrap, clip, truncateHead, truncateTail, truncateMiddle }

    public var text: String
    public var font: TextFont
    public var color: Color
    /// Clamped to 0...1 by the renderer. Nonfinite values render as zero.
    public var opacity: Float
    public var horizontalAlignment: HorizontalAlignment
    public var verticalAlignment: VerticalAlignment
    /// A positive wrapping width in scene points. Nil or nonpositive means unconstrained.
    public var maxWidth: Float?
    /// Zero means unlimited. Negative values are treated as zero.
    public var numberOfLines: Int
    public var lineBreak: LineBreak
    public var blendMode: SpriteBlendMode

    public init(_ text: String, font: TextFont = .system(), color: Color = .white,
                horizontalAlignment: HorizontalAlignment = .center, verticalAlignment: VerticalAlignment = .center,
                maxWidth: Float? = nil, numberOfLines: Int = 1, lineBreak: LineBreak = .wordWrap,
                opacity: Float = 1, blendMode: SpriteBlendMode = .alpha) {
        self.text = text; self.font = font; self.color = color; self.opacity = opacity
        self.horizontalAlignment = horizontalAlignment; self.verticalAlignment = verticalAlignment
        self.maxWidth = maxWidth; self.numberOfLines = numberOfLines; self.lineBreak = lineBreak; self.blendMode = blendMode
    }

    private enum CodingKeys: String, CodingKey { case text, font, color, opacity, horizontalAlignment, verticalAlignment, maxWidth, numberOfLines, lineBreak, blendMode }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(try c.decode(String.self, forKey: .text), font: try c.decode(TextFont.self, forKey: .font),
                  color: try c.decodeColor(forKey: .color), horizontalAlignment: try c.decode(HorizontalAlignment.self, forKey: .horizontalAlignment),
                  verticalAlignment: try c.decode(VerticalAlignment.self, forKey: .verticalAlignment), maxWidth: try c.decodeIfPresent(Float.self, forKey: .maxWidth),
                  numberOfLines: try c.decode(Int.self, forKey: .numberOfLines), lineBreak: try c.decode(LineBreak.self, forKey: .lineBreak),
                  opacity: try c.decode(Float.self, forKey: .opacity), blendMode: try c.decode(SpriteBlendMode.self, forKey: .blendMode))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text); try c.encode(font, forKey: .font); try c.encode(color: color, forKey: .color)
        try c.encode(opacity, forKey: .opacity); try c.encode(horizontalAlignment, forKey: .horizontalAlignment)
        try c.encode(verticalAlignment, forKey: .verticalAlignment); try c.encodeIfPresent(maxWidth, forKey: .maxWidth)
        try c.encode(numberOfLines, forKey: .numberOfLines); try c.encode(lineBreak, forKey: .lineBreak); try c.encode(blendMode, forKey: .blendMode)
    }
}

extension TextComponent.HorizontalAlignment {
    var native: SKLabelHorizontalAlignmentMode { switch self { case .left: .left; case .center: .center; case .right: .right } }
}
extension TextComponent.VerticalAlignment {
    var native: SKLabelVerticalAlignmentMode { switch self { case .baseline: .baseline; case .center: .center; case .top: .top; case .bottom: .bottom } }
}
extension TextComponent.LineBreak {
    var native: NSLineBreakMode { switch self {
    case .wordWrap: .byWordWrapping; case .characterWrap: .byCharWrapping; case .clip: .byClipping
    case .truncateHead: .byTruncatingHead; case .truncateTail: .byTruncatingTail; case .truncateMiddle: .byTruncatingMiddle
    } }
}

extension SpriteRenderer {
    static let textNodeName = "__text"
    static let textBinding = Binding<TextComponent>(apply: { new, old, node, animator in
        let existing = node.childNode(withName: textNodeName) as? SKLabelNode
        guard let value = new else {
            if let existing { animator.cancel("text.opacity", on: existing); existing.removeFromParent() }; return
        }
        let label = existing ?? SKLabelNode()
        if existing == nil { label.name = textNodeName; node.addChild(label) }
        let previous = existing == nil ? nil : old
        if previous?.text != value.text || previous?.font != value.font || previous?.color != value.color {
            // Private system font names are not reliably resolvable by SKLabelNode.
            // Supply the resolved font itself, preserving portable .system values.
            let font = value.font.native
            label.fontSize = drawingSize(value.font.size)
            label.fontColor = SKColor(value.color); label.colorBlendFactor = 0
            let text = value.font.size.isFinite && value.font.size > 0 ? value.text : ""
            if case .named(let name, _) = value.font, !font.fontName.hasPrefix("."), DrawingFont(name: name, size: font.pointSize) != nil {
                label.attributedText = nil; label.fontName = font.fontName; label.text = text
            } else {
                // macOS SpriteKit can trap rebuilding bounds when fontName is
                // nil, even with an attributed font. Keep a resolvable fallback;
                // the attributed font still controls the rendered glyphs.
                label.fontName = "HelveticaNeue"
                label.attributedText = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: SKColor(value.color)])
            }
        }
        if previous?.horizontalAlignment != value.horizontalAlignment { label.horizontalAlignmentMode = value.horizontalAlignment.native }
        if previous?.verticalAlignment != value.verticalAlignment { label.verticalAlignmentMode = value.verticalAlignment.native }
        if previous == nil || previous?.maxWidth != value.maxWidth { label.preferredMaxLayoutWidth = drawingSize(value.maxWidth ?? 0) }
        if previous?.numberOfLines != value.numberOfLines { label.numberOfLines = max(0, value.numberOfLines) }
        if previous?.lineBreak != value.lineBreak { label.lineBreakMode = value.lineBreak.native }
        if previous?.blendMode != value.blendMode { label.blendMode = value.blendMode.native }
        if previous?.opacity != value.opacity {
            let animator = existing == nil ? Animator(renderer: animator.renderer, entityID: animator.entityID, transaction: nil) : animator
            animateDrawingOpacity(value.opacity, on: label, key: "text.opacity", animator: animator)
        }
    }, present: { node, model in
        var value = model
        if let label = node.childNode(withName: textNodeName) as? SKLabelNode { value.opacity = Float(label.alpha) }
        return value
    })
}
