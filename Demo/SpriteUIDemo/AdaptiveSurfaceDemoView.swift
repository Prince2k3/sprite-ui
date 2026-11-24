import Observation
import SpriteUI
import SwiftUI

/// Synthetic surface geometry; the world and its follow camera survive every layout change.
@MainActor
struct AdaptiveSurfaceDemoView: View {
    @State private var model = AdaptiveSurfaceDemoModel()
    @State private var preset = AdaptiveSurfacePreset.system
    @State private var widthFraction = 1.0
    @State private var surfaceHeight = 400.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Adaptive surfaces").font(.title2.bold())
                Text(preset == .system
                     ? "SYSTEM · Native geometry reported by this game surface."
                     : "SIMULATED · Synthetic divisions and occlusions, sized from local bounds. No hardware posture detection.")
                    .font(.caption).foregroundStyle(preset == .system ? Color.mint : .orange)
                DisclosureGroup("Optional surface resizing") { sizeControls }
                    .font(.caption)

                GeometryReader { proxy in
                    let size = CGSize(width: max(1, proxy.size.width * widthFraction), height: proxy.size.height)
                    GameView(viewports: model.viewports, surfaceRegions: preset.regions(in: size)) {
                        model.install(in: $0)
                    }
                    .onGameSurfaceChange { model.surfaceDidChange($0) }
                    .gesture(SpatialTapGesture().onEnded { model.move(to: $0.location) })
                    .overlay { AdaptiveSurfaceOverlay(model: model, preset: $preset, size: size) }
                    .frame(width: size.width, height: size.height)
                    .clipped()
                }
                .frame(height: surfaceHeight)

                AdaptiveSurfaceCounters(model: model)
                Text("Cyan outlines: usable regions. Orange: reserved geometry. Use the surface menu inside the arena to select a preset or render every usable region. Tap a pane to move through its camera. Controls hide when no rectangle fits.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Change presets or resize while watching the counters: one world, one player, one follow camera. Rendering extra panes does not add a simulation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .background(.black).preferredColorScheme(.dark)
    }

    private var sizeControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Surface width \(Int(widthFraction * 100))% · height \(Int(surfaceHeight)) pt")
                .font(.caption.monospacedDigit())
            Slider(value: $widthFraction, in: 0.45...1)
                .accessibilityLabel("Surface width")
                .accessibilityIdentifier("adaptive-surface-width")
            Slider(value: $surfaceHeight, in: 240...560)
                .accessibilityLabel("Surface height")
                .accessibilityIdentifier("adaptive-surface-height")
        }
    }
}

private enum AdaptiveSurfacePreset: String, CaseIterable {
    case flat = "Flat", book = "Book", tabletop = "Tabletop", obstructed = "Obstructed", system = "System"

    func regions(in size: CGSize) -> [GameSurfaceGeometry.ReservedRegion]? {
        let width = size.width
        let height = size.height
        switch self {
        case .system:
            return nil // Let the native host supply its regions.
        case .flat:
            return [] // An explicit empty override is a deterministic flat surface.
        case .book:
            let thickness = min(24, width * 0.06)
            return [.init(id: "simulated-book", kind: .division,
                          frame: CGRect(x: (width - thickness) / 2, y: 0, width: thickness, height: height))]
        case .tabletop:
            let thickness = min(24, height * 0.06)
            return [.init(id: "simulated-tabletop", kind: .division,
                          frame: CGRect(x: 0, y: (height - thickness) / 2, width: width, height: thickness))]
        case .obstructed:
            return [.init(id: "simulated-obstruction", kind: .occlusion,
                          frame: CGRect(x: width * 0.32, y: height * 0.28,
                                        width: width * 0.4, height: height * 0.36))]
        }
    }
}

@MainActor
private struct AdaptiveSurfaceOverlay: View {
    let model: AdaptiveSurfaceDemoModel
    @Binding var preset: AdaptiveSurfacePreset
    let size: CGSize
    @State private var hudSize = CGSize.zero
    @State private var controlsSize = CGSize.zero

    var body: some View {
        // A native geometry callback can arrive after SwiftUI lays out a new size.
        // Hide old placements during that interval, allowing native pixel rounding.
        if let geometry = model.surface,
           abs(geometry.bounds.width - size.width) <= 1 / geometry.displayScale,
           abs(geometry.bounds.height - size.height) <= 1 / geometry.displayScale {
            // Keep settings reachable before allocating space to the passive HUD.
            let controlsRect = geometry.placement(of: controlsSize, anchor: [1, 1])
            let hudRect = hudPlacement(in: geometry, avoiding: controlsRect)
            ZStack(alignment: .topLeading) {
                ForEach(Array(geometry.usableRegions().enumerated()), id: \.offset) { index, rect in
                    Rectangle()
                        .strokeBorder(.cyan.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
                        .overlay(alignment: .center) {
                            Text("REGION \(index + 1)").font(.caption2.bold())
                                .foregroundStyle(.cyan.opacity(0.6))
                        }
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                ForEach(geometry.reservedRegions, id: \.id) { region in
                    Rectangle()
                        .fill(.orange.opacity(region.isActive ? 0.35 : 0.1))
                        .overlay { Rectangle().strokeBorder(.orange, lineWidth: 1) }
                        .frame(width: region.frame.width, height: region.frame.height)
                        .position(x: region.frame.midX, y: region.frame.midY)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                AdaptiveSurfaceHUD(model: model, preset: preset)
                    .padding(8)
                    .frame(width: max(1, min(188, geometry.largestUsableRegion.width)))
                    .fixedSize(horizontal: false, vertical: true)
                    .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { hudSize = $0 }
                    .position(x: hudRect?.midX ?? 0, y: hudRect?.midY ?? 0)
                    .opacity(hudSize == .zero || hudRect == nil ? 0 : 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(hudSize == .zero || hudRect == nil)

                AdaptiveSurfaceControls(model: model, preset: $preset,
                                        vertical: geometry.largestUsableRegion.width < 200)
                    .fixedSize()
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { controlsSize = $0 }
                    .position(x: controlsRect?.midX ?? 0, y: controlsRect?.midY ?? 0)
                    .opacity(controlsRect == nil ? 0 : 1)
                    .allowsHitTesting(controlsRect != nil)
                    .accessibilityHidden(controlsRect == nil)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
    }

    private func hudPlacement(in geometry: GameSurfaceGeometry, avoiding controls: CGRect?) -> CGRect? {
        guard hudSize.width > 0, hudSize.height > 0 else { return nil }
        let anchors: [SIMD2<Double>] = [[0, 0], [1, 0], [0, 1], [1, 1], [0.5, 0.5]]
        for anchor in anchors {
            if let rect = geometry.placement(of: hudSize, anchor: anchor),
               controls.map({ !$0.intersects(rect) }) ?? true { return rect }
        }
        return nil
    }
}

/// Observe per-frame values here, without reevaluating GameView's configuration.
@MainActor
private struct AdaptiveSurfaceHUD: View {
    let model: AdaptiveSurfaceDemoModel
    let preset: AdaptiveSurfacePreset

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(preset == .system ? "SYSTEM · NATIVE" : "SIMULATED · \(preset.rawValue.uppercased())")
                .fontWeight(.bold).foregroundStyle(preset == .system ? Color.mint : .orange)
            Text("ONE SHARED WORLD").fontWeight(.bold).foregroundStyle(.cyan)
            Text("Updates \(model.updates)")
            Text("Time \(model.sceneTime, specifier: "%.1f")s")
            Text(model.isPatrolling ? "Patrol · camera follows" : "Tap a pane to move")
        }
        .font(.caption2.monospacedDigit())
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("adaptive-surface-hud")
    }
}

@MainActor
private struct AdaptiveSurfaceControls: View {
    @Bindable var model: AdaptiveSurfaceDemoModel
    @Binding var preset: AdaptiveSurfacePreset
    let vertical: Bool

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
        layout {
            Menu {
                Picker("Surface geometry", selection: $preset) {
                    ForEach(AdaptiveSurfacePreset.allCases, id: \.self) { preset in
                        Text(preset == .system ? "System · Native" : "\(preset.rawValue) · Simulated").tag(preset)
                    }
                }
                .accessibilityIdentifier("adaptive-surface-preset")
                Toggle("Render every usable region", isOn: $model.showsAllRegions)
                    .accessibilityIdentifier("adaptive-surface-all-regions")
            } label: {
                Image(systemName: "rectangle.split.2x1").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Surface settings, \(preset.rawValue)")
            .accessibilityIdentifier("adaptive-surface-settings")
            Button { model.isPatrolling.toggle() } label: {
                Image(systemName: model.isPatrolling ? "pause.fill" : "play.fill")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(model.isPatrolling ? "Pause patrol" : "Start patrol")
            Button { model.stop() } label: {
                Image(systemName: "stop.fill").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Stop movement")
            Button { model.goHome() } label: {
                Image(systemName: "house.fill").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Move to world origin")
        }
        .padding(4).buttonStyle(.plain).foregroundStyle(.cyan)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("adaptive-surface-controls")
    }
}

@MainActor
private struct AdaptiveSurfaceCounters: View {
    let model: AdaptiveSurfaceDemoModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("World installs \(model.installations) · Updates \(model.updates) · Rendered \(model.finishedFrames)")
            Text("Geometry changes \(model.geometryChanges) · Usable regions \(model.surface?.usableRegions().count ?? 0)")
            Text("Scene time \(model.sceneTime, specifier: "%.1f")s · Player (\(model.playerPosition.x, specifier: "%.0f"), \(model.playerPosition.y, specifier: "%.0f"))")
            Text(model.lastInput)
        }
        .font(.caption.monospacedDigit())
        .accessibilityIdentifier("adaptive-surface-counters")
    }
}

@MainActor @Observable
private final class AdaptiveSurfaceDemoModel {
    var showsAllRegions = false
    var isPatrolling = true
    var surface: GameSurfaceGeometry?
    var installations = 0
    var updates = 0
    var finishedFrames = 0
    var geometryChanges = 0
    var sceneTime: TimeInterval = 0
    var playerPosition = SIMD2<Float>.zero
    var lastInput = "Patrol is running. Tap a usable pane to set a destination."
    @ObservationIgnored private let player = Entity(name: "Adaptive player", components:
        SpriteComponent(color: .cyan, size: [26, 26]))
    @ObservationIgnored private let camera = Entity(name: "Adaptive follow camera", components:
        CameraComponent(target: .named("Adaptive player"), smoothing: 0.18))
    @ObservationIgnored private var content: GameViewContent?
    @ObservationIgnored private var subscriptions: [EventSubscription] = []
    @ObservationIgnored private var destination = SIMD2<Float>.zero

    var viewports: [GameViewport] {
        if showsAllRegions, let surface {
            // Keep one unavailable declaration when nothing fits. An empty array
            // intentionally means the library's legacy full-surface viewport.
            return (0..<max(1, surface.usableRegions().count)).map {
                GameViewport(id: "pane-\($0)", camera: camera.id, region: .usable($0))
            }
        }
        return [GameViewport(id: "play", camera: camera.id, region: .largestUsable)]
    }

    func install(in content: GameViewContent) {
        installations += 1
        self.content = content
        surface = content.surfaceGeometry
        content.renderer.backgroundColor = .black
        for x in stride(from: -1_200, through: 1_200, by: 80) {
            let line = Entity(components: SpriteComponent(color: .white.opacity(0.12), size: [1, 2_400]))
            line.position = [Float(x), 0]; line.zPosition = -10; content.add(line)
        }
        for y in stride(from: -1_200, through: 1_200, by: 80) {
            let line = Entity(components: SpriteComponent(color: .white.opacity(0.12), size: [2_400, 1]))
            line.position = [0, Float(y)]; line.zPosition = -10; content.add(line)
        }
        for index in 0..<12 {
            let angle = Float(index) * .pi / 6
            let marker = Entity(components: SpriteComponent(color: .mint.opacity(0.7), size: [12, 12]))
            marker.position = [cos(angle) * 240, sin(angle) * 160]
            content.add(marker)
        }
        let origin = Entity(components: TextComponent("WORLD ORIGIN", font: .system(size: 12), color: .white))
        origin.position = [0, -32]; content.add(origin)
        content.add(player)
        content.add(camera)
        subscriptions = [
            content.subscribe(to: WorldEvents.Update.self) { [weak self] event in
                self?.step(deltaTime: event.deltaTime)
            },
            content.subscribe(to: RenderingEvents.DidUpdate.self) { [weak self] _ in
                self?.finishedFrames += 1
            }
        ]
    }

    func surfaceDidChange(_ geometry: GameSurfaceGeometry) {
        surface = geometry
        geometryChanges += 1
    }

    func move(to point: CGPoint) {
        guard let content, let viewport = content.viewport(at: point),
              let target = content.scenePoint(fromView: point, inViewport: viewport.id) else {
            lastInput = "No usable interactive viewport at that point."
            return
        }
        isPatrolling = false
        destination = target
        lastInput = "Tap → \(viewport.id) → world (\(Int(target.x)), \(Int(target.y)))"
    }

    func stop() {
        isPatrolling = false
        destination = player.position
        lastInput = "Stopped; the world clock continues."
    }

    func goHome() {
        isPatrolling = false
        destination = .zero
        lastInput = "Moving to world origin with the same follow camera."
    }

    private func step(deltaTime: TimeInterval) {
        updates += 1
        sceneTime += deltaTime
        if isPatrolling {
            let angle = Float(sceneTime) * 0.4
            destination = [cos(angle) * 180, sin(angle) * 120]
        }
        let offset = destination - player.position
        let distance = sqrt(offset.x * offset.x + offset.y * offset.y)
        if distance > 0 {
            player.position += offset * min(1, Float(max(0, deltaTime)) * 130 / distance)
        }
        playerPosition = player.position
    }
}
