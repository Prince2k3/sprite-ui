import SpriteUI
import SwiftUI

/// A tour of `withAnimation` on sprites:
/// tap to spring the player there, and use the buttons for the other curves.
struct DemoView: View {
    @State private var scene = DemoScene()
    @State private var completions = 0
    @State private var isPulsing = false
    /// Plain SwiftUI state, animated by the same `withAnimation` calls as the sprites.
    @State private var badgeOffset: CGFloat = 0
    /// Where the dragged entity was when the drag began.
    @State private var dragStart: SIMD2<Float>?

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                GameView { content in
                    scene.build(in: content)
                }
                .gesture(SpatialTapGesture().onEnded { tap in
                    // The scene's origin is the view's center, with +y up.
                    let point: SIMD2<Float> = [
                        Float(tap.location.x - geometry.size.width / 2),
                        Float(geometry.size.height / 2 - tap.location.y),
                    ]
                    withAnimation(.bouncy) {
                        scene.player.position = point
                        badgeOffset = tap.location.x - geometry.size.width / 2
                    } completion: {
                        completions += 1
                    }
                })
                // Only fires when the drag starts on an entity with an InputTargetComponent.
                .simultaneousGesture(DragGesture(minimumDistance: 4).targetedToAnyEntity()
                    .onChanged { value in
                        guard let parent = value.entity.parent else { return }
                        let start = dragStart ?? value.entity.position
                        dragStart = start
                        let offset = value.convert(value.location, to: parent)
                            - value.convert(value.startLocation, to: parent)
                        value.entity.position = start + offset
                    }
                    .onEnded { value in
                        dragStart = nil
                        // Tiles spring back to their slot; the player stays where it's dropped.
                        guard scene.tiles.contains(where: { $0 === value.entity }) else { return }
                        withAnimation(.bouncy) { scene.returnToSlot(value.entity) }
                    })
                .overlay(alignment: .top) {
                    Text("tap anywhere · drag a tile")
                        .font(.caption.bold())
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: .capsule)
                        .offset(x: badgeOffset)
                        .padding(.top, 8)
                }
            }

            readout
            controls
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
    }

    /// Model value vs. what's on screen, sampled every frame.
    private var readout: some View {
        TimelineView(.animation) { _ in
            let model = scene.player.position
            let shown = scene.player.presentation.position
            Grid(alignment: .leading, horizontalSpacing: 12) {
                GridRow {
                    Text("model").foregroundStyle(.secondary)
                    Text(format(model))
                }
                GridRow {
                    Text("presentation").foregroundStyle(.secondary)
                    Text(format(shown))
                }
                GridRow {
                    Text("completions").foregroundStyle(.secondary)
                    Text("\(completions)")
                }
            }
            .font(.footnote.monospacedDigit())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private var controls: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 8) {
            Button("Spin") {
                withAnimation(.easeInOut(duration: 0.6)) {
                    scene.player.transform.rotation += .pi
                }
            }
            Button("Fade") {
                let sprite = scene.player.components[SpriteComponent.self]!
                withAnimation(.linear(duration: 0.4)) {
                    scene.player.components[SpriteComponent.self]?.opacity = sprite.opacity > 0.5 ? 0.2 : 1
                }
            }
            Button("Recolor") {
                withAnimation(.smooth(duration: 0.5)) {
                    scene.player.components[SpriteComponent.self]?.color = DemoScene.palette.randomElement()!
                }
            }
            Button(isPulsing ? "Stop pulse" : "Pulse") {
                isPulsing.toggle()
                if isPulsing {
                    withAnimation(.easeInOut(duration: 0.6).repeatForever()) {
                        scene.ring.transform.scale = [1.6, 1.6]
                    }
                } else {
                    // A plain set cancels the running animation.
                    scene.ring.transform.scale = [1, 1]
                }
            }
            Button("Wave") {
                for (index, tile) in scene.tiles.enumerated() {
                    withAnimation(.easeOut(duration: 0.18).delay(Double(index) * 0.06)) {
                        tile.position.y += 40
                    } completion: {
                        withAnimation(.bouncy(duration: 0.4)) { tile.position.y -= 40 }
                    }
                }
            }
            Button("Shuffle") {
                withAnimation(.spring(duration: 0.6, bounce: 0.25)) {
                    scene.shuffleTiles()
                } completion: {
                    completions += 1
                }
            }
            Button("Interrupt") {
                // A slow move, replaced halfway by a quick one that starts from
                // wherever the player is on screen.
                withAnimation(.linear(duration: 2)) { scene.player.position = [-120, 120] }
                Task {
                    try? await Task.sleep(for: .seconds(0.8))
                    withAnimation(.snappy) { scene.player.position = .zero }
                }
            }
            Button("Reset") {
                withAnimation {
                    scene.reset()
                    badgeOffset = 0
                }
            }
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .padding()
    }

    private func format(_ v: SIMD2<Float>) -> String {
        String(format: "(%6.1f, %6.1f)", v.x, v.y)
    }
}

/// The entities in the demo.
@MainActor
final class DemoScene {
    static let palette: [Color] = [.orange, .pink, .mint, .yellow, .cyan, .purple]

    let player = Entity(
        name: "player",
        components: SpriteComponent(color: .orange, size: [56, 56]), InputTargetComponent()
    )
    let ring = Entity(name: "ring", components: SpriteComponent(color: .white.opacity(0.15), size: [90, 90]))
    let tiles: [Entity] = (0..<6).map { index in
        Entity(
            name: "tile-\(index)",
            components: SpriteComponent(color: palette[index], size: [36, 36]), InputTargetComponent()
        )
    }

    /// Which slot each tile belongs in; changes on shuffle.
    private var assignedSlots: [SIMD2<Float>] = []

    private var tileSlots: [SIMD2<Float>] {
        (0..<tiles.count).map { [Float($0 - tiles.count / 2) * 48 + 24, -180] }
    }

    func build(in content: GameViewContent) {
        ring.transform.zPosition = -1
        content.add(ring)
        content.add(player)
        for tile in tiles { content.add(tile) }
        placeTiles(in: tileSlots)
    }

    func shuffleTiles() {
        placeTiles(in: tileSlots.shuffled())
        for tile in tiles {
            tile.transform.rotation = Float.random(in: -0.4...0.4)
        }
    }

    func reset() {
        player.position = .zero
        player.transform.rotation = 0
        player.components[SpriteComponent.self]?.opacity = 1
        player.components[SpriteComponent.self]?.color = .orange
        placeTiles(in: tileSlots)
        for tile in tiles { tile.transform.rotation = 0 }
    }

    func returnToSlot(_ tile: Entity) {
        guard let index = tiles.firstIndex(where: { $0 === tile }) else { return }
        tile.position = assignedSlots[index]
    }

    private func placeTiles(in slots: [SIMD2<Float>]) {
        assignedSlots = slots
        for (tile, slot) in zip(tiles, slots) { tile.position = slot }
    }
}
