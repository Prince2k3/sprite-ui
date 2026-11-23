import SpriteUI
import SwiftUI

@MainActor
private final class SplitScene {
    // Create cameras before computing the viewport array so IDs stay stable.
    let firstCamera = Entity(name: "P1 camera", components: CameraComponent(smoothing: 0))
    let secondCamera = Entity(name: "P2 camera", components: CameraComponent(smoothing: 0))

    var viewports: [GameViewport] {
        [GameViewport(id: "p1", camera: firstCamera.id,
                      frame: .init(x: 0, y: 0, width: 0.5, height: 1)),
         GameViewport(id: "p2", camera: secondCamera.id,
                      frame: .init(x: 0.5, y: 0, width: 0.5, height: 1))]
    }

    func install(in content: GameViewContent) {
        let first = Entity(name: "P1", components: SpriteComponent(color: .cyan, size: [32, 32]))
        let second = Entity(name: "P2", components: SpriteComponent(color: .orange, size: [32, 32]))
        first.position = [-100, 40]
        second.position = [100, 40]
        firstCamera.position = first.position
        secondCamera.position = second.position
        content.add(first); content.add(second)
        content.add(firstCamera); content.add(secondCamera)
        let beacon = Entity(components: SpriteComponent(color: .mint, size: [24, 48]))
        beacon.position = [0, 75]
        content.add(beacon)
        for x in stride(from: -360, through: 360, by: 60) {
            let line = Entity(components: SpriteComponent(color: .white.opacity(0.15), size: [1, 440]))
            line.position = [Float(x), 0]; line.zPosition = -10; content.add(line)
        }
    }
}

@MainActor
struct ContentView: View {
    @State private var scene = SplitScene()

    var body: some View {
        VStack(spacing: 8) {
            Text("P1 · cyan camera     |     P2 · orange camera").font(.caption.bold())
            GameView(viewports: scene.viewports) { scene.install(in: $0) }
                .frame(height: 360)
                .overlay {
                    Rectangle().fill(.white.opacity(0.7)).frame(width: 1)
                        .allowsHitTesting(false)
                }
            Text("One world, two camera views. Both players already exist in the same scene.")
                .font(.caption)
        }
        .padding(10).background(.black).preferredColorScheme(.dark)
    }
}
