import SpriteUI
import SwiftUI

@MainActor
struct ContentView: View {
    @State private var layout = SurfaceLayout.book
    @State private var surface = GameSurfaceGeometry(size: .zero)

    var body: some View {
        VStack(spacing: 12) {
            Picker("Surface fixture", selection: $layout) {
                ForEach(SurfaceLayout.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            GeometryReader { proxy in
                GameView(surfaceRegions: layout.regions(in: proxy.size)) { content in
                    content.add(Entity(components: SpriteComponent(color: .cyan, size: [32, 32])))
                }
                .onGameSurfaceChange { surface = $0 }
                .overlay { SurfaceOutline(geometry: surface) }
            }
            .frame(height: 320)
            Text("\(surface.usableRegions().count) usable; \(surface.usableRegions(includingInactive: true).count) including inactive")
                .font(.caption)
            Text("Fixtures replace native regions. Native restores host reporting.")
                .font(.caption)
        }
        .padding().background(.black).preferredColorScheme(.dark)
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
