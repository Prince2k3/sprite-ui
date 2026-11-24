import SpriteUI
import SwiftUI

@MainActor
struct ContentView: View {
    @State private var scene = SurfaceScene()
    @State private var layout = SurfaceLayout.book
    @State private var surface = GameSurfaceGeometry(size: .zero)

    var body: some View {
        VStack(spacing: 12) {
            Picker("Surface fixture", selection: $layout) {
                ForEach(SurfaceLayout.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            GeometryReader { proxy in
                GameView(viewports: scene.viewports, surfaceRegions: layout.regions(in: proxy.size)) {
                    scene.install(in: $0)
                } update: { content in
                    // Reading here observes surface changes without rebuilding the world.
                    scene.beacon.isEnabled = content.surfaceGeometry.largestUsableRegion.width >= 120
                }
                .onGameSurfaceChange { surface = $0 }
                .overlay { SurfaceOutline(geometry: surface) }
            }
            .frame(height: 320)
            Text("\(surface.usableRegions().count) usable regions · P1 cyan · P2 orange")
                .font(.caption)
            Text("Clear hides P2's pane; its entity and camera remain in the shared world.")
                .font(.caption)
        }
        .padding().background(.black).preferredColorScheme(.dark)
    }
}

@MainActor
private final class SurfaceScene {
    let first = Entity(name: "P1", components: SpriteComponent(color: .cyan, size: [32, 32]))
    let second = Entity(name: "P2", components: SpriteComponent(color: .orange, size: [32, 32]))
    let firstCamera = Entity(components: CameraComponent(target: .named("P1"), smoothing: 0))
    let secondCamera = Entity(components: CameraComponent(target: .named("P2"), smoothing: 0))
    let beacon = Entity(components: SpriteComponent(color: .mint, size: [20, 48]))

    var viewports: [GameViewport] {
        [GameViewport(id: "p1", camera: firstCamera.id, region: .usable(0)),
         GameViewport(id: "p2", camera: secondCamera.id, region: .usable(1))]
    }

    func install(in content: GameViewContent) {
        first.position = [-80, 0]; second.position = [80, 0]
        firstCamera.position = first.position; secondCamera.position = second.position
        beacon.position = [0, 60]
        for entity in [first, second, firstCamera, secondCamera, beacon] { content.add(entity) }
    }
}

private enum SurfaceLayout: String, CaseIterable {
    case native = "Native", clear = "Clear", book = "Book", tabletop = "Tabletop", inactive = "Inactive"

    func regions(in size: CGSize) -> [GameSurfaceGeometry.ReservedRegion]? {
        switch self {
        case .native: return nil
        case .clear: return []
        case .book, .inactive:
            return [.init(id: "demo-spine", kind: .division,
                          frame: CGRect(x: max(0, size.width / 2 - 10), y: 0,
                                        width: 20, height: size.height),
                          isActive: self != .inactive)]
        case .tabletop:
            return [.init(id: "demo-fold", kind: .division,
                          frame: CGRect(x: 0, y: max(0, size.height / 2 - 10),
                                        width: size.width, height: 20))]
        }
    }
}

@MainActor
private struct SurfaceOutline: View {
    let geometry: GameSurfaceGeometry

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(geometry.reservedRegions, id: \.id) { region in
                Rectangle()
                    .fill(region.isActive ? Color.red.opacity(0.5) : Color.yellow.opacity(0.25))
                    .frame(width: region.frame.width, height: region.frame.height)
                    .position(x: region.frame.midX, y: region.frame.midY)
            }
            ForEach(Array(geometry.usableRegions().enumerated()), id: \.offset) { item in
                Rectangle().strokeBorder(.mint, lineWidth: 2)
                    .overlay(alignment: .topLeading) {
                        Text("Usable \(item.offset)").font(.caption2).padding(4)
                    }
                    .frame(width: item.element.width, height: item.element.height)
                    .position(x: item.element.midX, y: item.element.midY)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
