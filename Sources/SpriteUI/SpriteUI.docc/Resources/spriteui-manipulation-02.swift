import Observation
import SpriteUI
import SwiftUI

@MainActor @Observable
final class ManipulationTutorialScene {
    let free = Entity(name: "Free", components:
        SpriteComponent(color: .cyan, size: [48, 32]),
        InputTargetComponent(), ManipulationComponent())
    let child = Entity(name: "Rail", components:
        SpriteComponent(color: .mint, size: [28, 28]),
        InputTargetComponent(), ManipulationComponent(
            translationAxes: .x,
            translationBounds: .init(min: [-80, -20], max: [80, 20]),
            translationSnap: [20, 20], rotationSnap: .pi / 12))

    func install(in content: GameViewContent) {
        free.position = [-75, 95]
        content.add(free)
        let parent = Entity(components: ShapeComponent(
            .rectangle(size: [200, 60]), fill: .mint.opacity(0.08), stroke: .mint))
        parent.rotation = .pi / 6
        parent.scale = [1.1, 1.1]
        for x in stride(from: -80, through: 80, by: 20) {
            let mark = Entity(components: SpriteComponent(color: .mint.opacity(0.3), size: [1, 60]))
            mark.position.x = Float(x)
            parent.addChild(mark)
        }
        child.position = [-40, 0]
        parent.addChild(child)
        content.add(parent)
    }
}

@MainActor
struct ContentView: View {
    @State private var scene = ManipulationTutorialScene()

    var body: some View {
        VStack(spacing: 10) {
            GameView { scene.install(in: $0) }
                .frame(minWidth: 300, minHeight: 320)
            Text("Cyan: free. Mint: local X only, 20-point grid, 15° rotation steps.")
                .font(.caption)
        }
        .padding()
    }
}
