import Observation
import SpriteUI
import SwiftUI

@MainActor @Observable
private final class LandscapeScene {
    var x: Float = 0
    let camera = Entity(name: "Landscape camera", components: CameraComponent(smoothing: 0))

    func install(in content: GameViewContent) {
        content.renderer.backgroundColor = .black
        let factors: [Float] = [0.12, 0.45, 1]
        for index in 0..<3 {
            let size: SIMD2<Float> = index == 0 ? [256, 512] : index == 1 ? [256, 256] : [128, 192]
            let layer = Entity(name: ["Stars", "Mountains", "Ground"][index], components:
                SpriteComponent(image: ParallaxDemoTiles.image(index), size: size),
                ParallaxComponent(scrollFactor: [factors[index], 1]))
            layer.position = [0, index == 2 ? -140 : 0]
            layer.zPosition = Float(index - 3)
            content.add(layer)
        }
        content.add(camera)
    }

    func move(to value: Float) {
        x = value
        camera.position = [value, 0]
    }
}

@MainActor
struct ContentView: View {
    @State private var scene = LandscapeScene()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shift only the sprite").font(.headline)
            GameView(viewports: [GameViewport(id: "landscape", camera: scene.camera.id)]) {
                scene.install(in: $0)
            }
            .frame(height: 260).clipped()
            .accessibilityLabel("Stars, mountains, and ground viewed through one camera")
            Text("Camera x \(scene.x, specifier: "%.0f")").font(.caption.monospacedDigit())
            Slider(value: Binding(get: { scene.x }, set: { scene.move(to: $0) }), in: -1200...1200)
                .accessibilityLabel("Camera horizontal position")
                .frame(minHeight: 44)
            Text("Move a little to compare depths. Move far enough and the finite tiles leave the view.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(10).background(.black).preferredColorScheme(.dark)
    }
}

/// Deterministic RGBA pixels. Periodic horizontal functions meet at tile edges.
private enum ParallaxDemoTiles {
    static func image(_ layer: Int) -> SpriteImage {
        let width = layer == 2 ? 128 : 256
        let height = layer == 0 ? 512 : layer == 1 ? 256 : 192
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let rgba: [UInt8]
                switch layer {
                case 0:
                    // Integer lattice repeats vertically and horizontally.
                    let star = (x * 73 + y * 151) % 997 < 3
                    rgba = star ? [205, 225, 255, 255] : [12, 20, 43, 255]
                case 1:
                    let phase = Float(x) / Float(width) * 2 * .pi
                    let ridge = 112 + Int(36 * cos(phase) + 18 * cos(3 * phase))
                    rgba = y >= ridge ? [55, 72, 116, 255] : [0, 0, 0, 0]
                default:
                    let grass = y < 9
                    let fleck = (x % 16 == 4 && y % 18 == 8)
                    rgba = grass ? [106, 184, 153, 255] : fleck ? [62, 88, 100, 255] : [28, 47, 64, 255]
                }
                let offset = (y * width + x) * 4
                for channel in 0..<4 { pixels[offset + channel] = rgba[channel] }
            }
        }
        return SpriteImage(width: width, height: height, pixels: pixels, smoothsScaling: false)
    }
}
