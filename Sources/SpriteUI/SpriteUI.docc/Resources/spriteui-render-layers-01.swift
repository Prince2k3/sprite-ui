import SpriteUI
import SwiftUI

private extension RenderLayer {
    // Bit zero is reserved for .default. App-defined layers use bits 1...63.
    static let map = RenderLayer(rawValue: 1 << 1)
}

@MainActor
private final class LayerScene {
    let worldCamera = Entity(components: CameraComponent(smoothing: 0, cullingMask: .default))
    let mapCamera = Entity(components: CameraComponent(smoothing: 0, cullingMask: .map))

    var viewports: [GameViewport] {
        [GameViewport(id: "world", camera: worldCamera.id,
                      frame: .init(x: 0, y: 0, width: 0.5, height: 1)),
         GameViewport(id: "map", camera: mapCamera.id,
                      frame: .init(x: 0.5, y: 0, width: 0.5, height: 1))]
    }

    func install(in content: GameViewContent) {
        content.renderer.backgroundColor = .black
        for index in 0..<2 {
            // No VisibilityComponent means this parent is neutral (.all).
            let object = Entity(name: index == 0 ? "Comet" : "Kite")
            object.position = index == 0 ? [-30, -45] : [30, 45]
            let square = Entity(components:
                SpriteComponent(color: index == 0 ? .cyan : .orange, size: [28, 28]),
                VisibilityComponent(layers: .default))
            let diamond = Entity(components:
                SpriteComponent(color: index == 0 ? .mint : .yellow, size: [12, 12]),
                VisibilityComponent(layers: .map))
            diamond.rotation = .pi / 4
            object.addChild(square); object.addChild(diamond)
            content.add(object)
        }
        content.add(worldCamera); content.add(mapCamera)
    }
}

@MainActor
struct ContentView: View {
    @State private var scene = LayerScene()
    var body: some View {
        VStack(spacing: 12) {
            Text("WORLD                          MAP").font(.caption.bold())
            GameView(viewports: scene.viewports) { scene.install(in: $0) }
                .frame(height: 280)
                .overlay {
                    Rectangle().fill(.gray).frame(width: 1).allowsHitTesting(false)
                }
            Text("The same objects wear squares on the left and diamonds on the right.")
                .font(.caption)
        }
        .padding(12).background(.black).preferredColorScheme(.dark)
    }
}
