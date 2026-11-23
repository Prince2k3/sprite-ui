import ECSCore
import SpriteKit
import SwiftUI
import Testing
@testable import SpriteBackend

@MainActor @Suite struct DrawingPlaybackTests {
    @Test func fadingCapturesAndSeeksTextOpacityWithoutChangingItsLayout() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let entity = Entity(components: TextComponent("A wrapped caption", font: .system(size: 18), maxWidth: 80, numberOfLines: 0, opacity: 0.8))
        world.addEntity(entity)
        let controller = try entity.playAnimation(.fade(to: 0, duration: 2))
        try controller.seek(to: 1); renderer.flush()
        let text = try #require(entity.components[TextComponent.self])
        let label = try #require(renderer.node(for: entity)?.childNode(withName: "__text") as? SKLabelNode)
        #expect(abs(text.opacity - 0.4) < 0.0001 && abs(label.alpha - 0.4) < 0.0001)
        #expect(text.text == "A wrapped caption" && text.maxWidth == 80 && text.font.size == 18)
        #expect(label.action(forKey: "text.opacity") == nil)
    }

    @Test func fadeKeepsItsChosenComponentWhenANewVisualAppears() throws {
        let world = World(), entity = Entity(components: ShapeComponent(.circle(radius: 10), fill: .cyan, opacity: 0.8))
        world.addEntity(entity)
        let controller = try entity.playAnimation(.fade(to: 0, duration: 2))
        entity.components.set(TextComponent("Added later"))
        entity.components.set(SpriteComponent(color: .red, size: [10, 10]))
        try controller.seek(to: 1)
        #expect(abs((entity.components[ShapeComponent.self]?.opacity ?? -1) - 0.4) < 0.0001)
        #expect(entity.components[TextComponent.self]?.opacity == 1 && entity.components[SpriteComponent.self]?.opacity == 1)
        entity.components.remove(ShapeComponent.self); world.update(deltaTime: 0.1)
        #expect(controller.state == .failed)
        #expect(entity.components[TextComponent.self]?.opacity == 1 && entity.components[SpriteComponent.self]?.opacity == 1)
    }

    @Test func existingSpriteFadePriorityIsPreserved() throws {
        let entity = Entity(components: SpriteComponent(color: .red, size: [10, 10]), TextComponent("Label"), ShapeComponent(.circle(radius: 10)))
        let controller = try entity.playAnimation(.fade(to: 0, duration: 1))
        try controller.seek(to: 0.5)
        #expect(entity.components[SpriteComponent.self]?.opacity == 0.5)
        #expect(entity.components[TextComponent.self]?.opacity == 1 && entity.components[ShapeComponent.self]?.opacity == 1)
    }

    @Test func playbackCancelsOnlyTheSelectedVisualOpacityAction() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let entity = Entity(components: TextComponent("Label"), ShapeComponent(.circle(radius: 10), fill: .cyan))
        world.addEntity(entity)
        withAnimation(.linear(duration: 10)) {
            entity.components[TextComponent.self]?.opacity = 0.2
            entity.components[ShapeComponent.self]?.opacity = 0.3
            entity.position = [40, 0]
        }
        renderer.flush()
        let root = try #require(renderer.node(for: entity)), label = try #require(root.childNode(withName: "__text")), shape = try #require(root.childNode(withName: "__shape"))
        #expect(label.action(forKey: "text.opacity") != nil && shape.action(forKey: "shape.opacity") != nil)
        _ = try entity.playAnimation(.fade(to: 0.5, duration: 2)); renderer.flush()
        #expect(label.action(forKey: "text.opacity") == nil && shape.action(forKey: "shape.opacity") != nil)
        #expect(root.action(forKey: "transform.position") != nil)
    }

    @Test func absentDrawablesFailBeforeReplacingPlayback() throws {
        let entity = Entity()
        #expect(throws: PlaybackError.missingVisual) { try entity.playAnimation(.fade(to: 0, duration: 1)) }
        entity.components.set(TextComponent("Keep fading"))
        let controller = try entity.playAnimation(.fade(to: 0, duration: 1))
        // Rejecting an invalid follow-up leaves the running clip intact.
        #expect(throws: PlaybackError.missingVisual) {
            entity.components.remove(TextComponent.self)
            try entity.playAnimation(.fade(to: 0, duration: 1))
        }
        #expect(controller.state == .playing)
    }
}
