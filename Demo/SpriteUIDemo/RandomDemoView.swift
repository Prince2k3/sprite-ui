import SpriteUI
import SwiftUI

/// The Random milestone: one seeded `world.random` drives four kinds of randomness.
/// The same seed always lays out the same scene; "Replay" proves it.
struct RandomDemoView: View {
    @State private var scene = RandomScene()
    @State private var seed: UInt64 = 42

    var body: some View {
        VStack(spacing: 0) {
            GameView { content in
                scene.build(in: content)
                scene.roll(seed: seed)
            }
            .overlay(alignment: .top) { labels }

            controls
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
    }

    private var labels: some View {
        VStack {
            HStack {
                caption("uniform")
                Spacer()
                caption("gaussian")
            }
            Spacer()
            caption("shuffle bag · no repeats")
            Spacer()
            caption("weighted loot · 70 / 25 / 5")
                .padding(.bottom, 4)
        }
        .padding(8)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption.bold())
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.ultraThinMaterial, in: .capsule)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Text("seed \(seed)")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
            HStack {
                Button("New seed") {
                    seed = UInt64.random(in: 0...9999)
                    withAnimation(.spring(duration: 0.6, bounce: 0.2)) { scene.roll(seed: seed) }
                }
                Button("Replay") {
                    // Same seed: everything lands exactly where it was.
                    scene.scatter()
                    withAnimation(.spring(duration: 0.6, bounce: 0.2)) { scene.roll(seed: seed) }
                }
                Button("Draw more") {
                    // Keeps drawing from the world's stream instead of reseeding.
                    withAnimation(.snappy) { scene.drawMore() }
                }
            }
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .padding()
    }
}

/// Entities for the Random demo. All randomness comes from `world.random`.
@MainActor
final class RandomScene {
    static let colors: [Color] = [.orange, .pink, .mint, .yellow, .cyan, .purple]

    enum Loot: CaseIterable { case common, rare, legendary }

    private var world: World?
    private let uniformDots = (0..<70).map { _ in RandomScene.dot(.white) }
    private let gaussianDots = (0..<70).map { _ in RandomScene.dot(.cyan) }
    private let bagTiles = (0..<12).map { _ in
        Entity(components: SpriteComponent(color: .gray, size: [24, 24]))
    }
    private let lootBars: [Entity] = [Color.gray, .blue, .orange].map {
        Entity(components: SpriteComponent(color: $0, size: [60, 1]))
    }

    private let gaussian = GaussianDistribution(mean: 0, standardDeviation: 28)
    private var bag = ShuffleBag(RandomScene.colors)
    private let loot = WeightedDistribution([Loot.common: 70, .rare: 25, .legendary: 5])

    private static func dot(_ color: Color) -> Entity {
        Entity(components: SpriteComponent(color: color.opacity(0.8), size: [6, 6]))
    }

    func build(in content: GameViewContent) {
        world = content.world
        for entity in uniformDots + gaussianDots + bagTiles + lootBars { content.add(entity) }
        for (index, bar) in lootBars.enumerated() {
            bar.position = [Float(index - 1) * 80, -230]
        }
    }

    /// Reseeds the world and redraws everything from that seed.
    func roll(seed: UInt64) {
        world?.random = SeededGenerator(seed: seed)
        bag = ShuffleBag(Self.colors)
        drawMore()
    }

    /// Draws a fresh layout from wherever the world's generator is now.
    func drawMore() {
        guard let world else { return }

        // Uniform: anywhere in the left square.
        for dot in uniformDots {
            dot.position = [
                Float.random(in: -170 ... -30, using: &world.random),
                Float.random(in: 80...220, using: &world.random),
            ]
        }

        // Gaussian: clustered around the right square's center.
        for dot in gaussianDots {
            dot.position = [
                100 + Float(gaussian.next(using: &world.random)),
                150 + Float(gaussian.next(using: &world.random)),
            ]
        }

        // Shuffle bag: every color once before any repeats, never twice in a row.
        for (index, tile) in bagTiles.enumerated() {
            tile.position = [Float(index) * 28 - 154, -40]
            tile.components[SpriteComponent.self]?.color = bag.next(using: &world.random)
        }

        // Weighted: 200 drops, bar height = count.
        var counts = [Loot: Int]()
        for _ in 0..<200 { counts[loot.next(using: &world.random), default: 0] += 1 }
        for (bar, kind) in zip(lootBars, Loot.allCases) {
            let height = Float(max(counts[kind, default: 0], 1))
            bar.transform.scale = [1, height]
            bar.position.y = -250 + height / 2
        }
    }

    /// Throws the dots to the middle so "Replay" visibly re-lands them.
    func scatter() {
        for dot in uniformDots + gaussianDots { dot.position = [0, 150] }
    }
}
