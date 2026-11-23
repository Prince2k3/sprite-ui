import Observation
import SpriteUI
import SwiftUI

@MainActor @Observable
final class ManipulationTutorialScene {
    let free = Entity(name: "Free", components:
        SpriteComponent(color: .cyan, size: [48, 32]),
        InputTargetComponent(), ManipulationComponent())

    func install(in content: GameViewContent) {
        content.add(free)
    }
}

@MainActor
struct ContentView: View {
    @State private var scene = ManipulationTutorialScene()

    var body: some View {
        VStack(spacing: 10) {
            GameView { scene.install(in: $0) }
                .frame(minWidth: 280, minHeight: 260)
            Text("Drag the cyan sprite. Pinch and rotate with touch or a trackpad.")
                .font(.caption)
        }
        .padding()
    }
}
