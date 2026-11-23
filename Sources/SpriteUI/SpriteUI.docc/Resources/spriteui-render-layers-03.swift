import Observation
import SpriteUI
import SwiftUI

private extension RenderLayer {
    static let map = RenderLayer(rawValue: 1 << 1)
}

/// Two presentations of the same moving bodies, driven by one GameView.
@MainActor
struct ContentView: View {
    @State private var model = RenderLayersDemoModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("One world, two looks").font(.title3.bold())
                Text("Tap a square or diamond in either pane to select it.")
                    .font(.caption).foregroundStyle(.secondary)

                GameView(viewports: model.viewports) { model.install(in: $0) } attachments: {
                    GameAttachment(id: "selected") { context in
                        Text(context.entity.parent?.parent?.name ?? "Selected")
                            .font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 3)
                            .background(.yellow, in: Capsule()).foregroundStyle(.black)
                    }
                }
                .gesture(SpatialTapGesture().targetedToAnyEntity().onEnded {
                    model.select($0.entity, in: $0.viewportID)
                })
                .overlay {
                    HStack(spacing: 0) {
                        paneFrame("WORLD", color: .cyan)
                        paneFrame("MAP · TAP TO SELECT", color: .mint)
                    }
                    .allowsHitTesting(false).accessibilityHidden(true)
                }
                .frame(height: 280).clipped()
                .accessibilityLabel("World and interactive map showing the same bouncing objects")
                .accessibilityIdentifier("layers-arena")

                RenderLayersActivity(model: model)

                Toggle("Hide world squares", isOn: $model.hideWorldArt)
                    .accessibilityIdentifier("layers-hide-world")
                Toggle("Hide both objects", isOn: $model.hideObjects)
                    .accessibilityIdentifier("layers-hide-objects")
                Text("Hiding changes the view. Movement and bounces continue.")
                    .font(.caption).foregroundStyle(.secondary)

                Text("Map camera shows").font(.subheadline.bold())
                Picker("Map camera shows", selection: $model.mapMask) {
                    ForEach(RenderLayersMapMask.allCases, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("layers-camera-mask")
                Toggle("Limit map pane to world squares", isOn: $model.restrictMap)
                    .accessibilityIdentifier("layers-viewport-mask")
                Text("The pane can only narrow its camera’s choice. Map only + this limit leaves the pane empty.")
                    .font(.caption).foregroundStyle(.secondary)
                RenderLayersSelection(model: model)
            }
            .padding(12)
        }
        .background(.black).preferredColorScheme(.dark)
        .onChange(of: model.hideWorldArt) { _, _ in model.applyVisibility() }
        .onChange(of: model.hideObjects) { _, _ in model.applyVisibility() }
        .onChange(of: model.mapMask) { _, _ in model.applyVisibility() }
    }

    private func paneFrame(_ title: String, color: Color) -> some View {
        Rectangle().strokeBorder(color.opacity(0.8), lineWidth: 1)
            .overlay(alignment: .topLeading) {
                Text(title).font(.system(size: 10, weight: .bold))
                    .padding(5).background(.black.opacity(0.85))
            }
    }
}

private enum RenderLayersMapMask: String, CaseIterable {
    case map = "Map only", both = "Both", none = "Nothing"

    var layers: RenderLayer {
        switch self {
        case .map: .map
        case .both: [.default, .map]
        case .none: .none
        }
    }
}

/// Keep per-frame observation outside GameView's configuration evaluation.
@MainActor
private struct RenderLayersActivity: View {
    let model: RenderLayersDemoModel
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Bounces \(model.contacts) · Time \(model.elapsed, specifier: "%.1f")s")
            Text("One world · \(model.updates) updates · Travel \(model.distance, specifier: "%.0f") pt")
        }
        .font(.caption.monospacedDigit())
        .accessibilityIdentifier("layers-activity")
    }
}

@MainActor
private struct RenderLayersSelection: View {
    let model: RenderLayersDemoModel
    var body: some View {
        Text("Last picks · World: \(model.selections["world"] ?? "tap a square") · Map: \(model.selections["map"] ?? "tap a diamond")")
            .font(.caption).foregroundStyle(.secondary)
            .accessibilityIdentifier("layers-selection")
    }
}

@MainActor @Observable
private final class RenderLayersDemoModel {
    var hideWorldArt = false
    var hideObjects = false
    var mapMask = RenderLayersMapMask.map
    var restrictMap = false
    var contacts = 0
    var updates = 0
    var elapsed: TimeInterval = 0
    var distance: Float = 0
    var selections: [String: String] = [:]
    @ObservationIgnored private let worldCamera = Entity(name: "World camera", components:
        CameraComponent(smoothing: 0, cullingMask: .default))
    @ObservationIgnored private let mapCamera = Entity(name: "Map camera", components:
        CameraComponent(smoothing: 0, cullingMask: .map))
    @ObservationIgnored private var bodies: [Entity] = []
    @ObservationIgnored private var worldArt: [Entity] = []
    @ObservationIgnored private var subscriptions: [EventSubscription] = []
    @ObservationIgnored private var anchors: [String: Entity] = [:]
    @ObservationIgnored private var previousPositions: [Entity.ID: SIMD2<Float>] = [:]
    @ObservationIgnored private var renderer: SpriteRenderer?

    var viewports: [GameViewport] {
        [GameViewport(id: "world", camera: worldCamera.id,
                      frame: .init(x: 0, y: 0, width: 0.5, height: 1)),
         GameViewport(id: "map", camera: mapCamera.id,
                      frame: .init(x: 0.5, y: 0, width: 0.5, height: 1),
                      cullingMask: restrictMap ? .default : nil)]
    }

    func install(in content: GameViewContent) {
        renderer = content.renderer
        content.renderer.backgroundColor = .black
        let room = Entity(name: "Shared arena", components:
            PhysicsBodyComponent(shape: .edgeLoop(rectangle: [130, 210]), friction: 0,
                                 restitution: 1, categoryBitMask: 1, collisionBitMask: 2))
        // Untagged decoration is neutral and can appear through either camera.
        for y in [Float(-105), 105] {
            let line = Entity(components: SpriteComponent(color: .gray, size: [130, 1]))
            line.position = [0, y]; room.addChild(line)
        }
        for x in [Float(-65), 65] {
            let line = Entity(components: SpriteComponent(color: .gray, size: [1, 210]))
            line.position = [x, 0]; room.addChild(line)
        }
        content.add(room)
        for index in 0..<2 {
            // The physical parent has no layer restriction. Each child chooses its art.
            let body = Entity(name: index == 0 ? "Comet" : "Kite", components:
                PhysicsBodyComponent(shape: .circle(radius: 14), friction: 0, restitution: 1,
                                     linearDamping: 0, affectedByGravity: false, allowsRotation: false,
                                     categoryBitMask: 2, collisionBitMask: 1, contactTestBitMask: 1,
                                     velocity: index == 0 ? [43, 61] : [-37, -53]))
            body.position = index == 0 ? [-30, -45] : [30, 45]
            let square = Entity(name: "World square", components:
                SpriteComponent(color: index == 0 ? .cyan : .orange, size: [28, 28]),
                VisibilityComponent(layers: .default),
                CollisionComponent(shape: .rectangle(size: [44, 44])), InputTargetComponent())
            let icon = Entity(name: "Map diamond", components:
                VisibilityComponent(layers: .map),
                CollisionComponent(shape: .circle(radius: 22)), InputTargetComponent())
            // Keep the label upright while the diamond is rotated.
            let iconArt = Entity(components: SpriteComponent(color: index == 0 ? .mint : .yellow, size: [12, 12]))
            iconArt.rotation = .pi / 4
            icon.addChild(iconArt)
            body.addChild(square); body.addChild(icon)
            bodies.append(body); worldArt.append(square)
            previousPositions[body.id] = body.position
            content.add(body)
        }
        content.add(worldCamera); content.add(mapCamera)
        applyVisibility()
        subscriptions = [
            content.subscribe(to: PhysicsEvents.ContactBegan.self) { [weak self] _ in self?.contacts += 1 },
            content.subscribe(to: WorldEvents.Update.self) { [weak self] event in
                guard let self else { return }
                updates += 1; elapsed += event.deltaTime
                for body in bodies {
                    let old = previousPositions[body.id] ?? body.position
                    let delta = body.position - old
                    distance += (delta.x * delta.x + delta.y * delta.y).squareRoot()
                    previousPositions[body.id] = body.position
                }
            }
        ]
    }

    func applyVisibility() {
        for body in bodies {
            // .all permits both child layers; isVisible gates the whole subtree.
            body.components.set(VisibilityComponent(layers: .all, isVisible: !hideObjects))
        }
        for art in worldArt { art.components[VisibilityComponent.self]?.isVisible = !hideWorldArt }
        mapCamera.components[CameraComponent.self]?.cullingMask = mapMask.layers
    }

    func select(_ entity: Entity, in viewportID: String?) {
        guard let viewportID, let renderer,
              renderer.isVisible(entity, inViewport: viewportID),
              let body = entity.parent, bodies.contains(where: { $0 === body }) else { return }
        selections[viewportID] = body.name
        let anchor = anchors[viewportID] ?? Entity(components:
            AttachmentComponent(id: "selected", offset: [0, -29], viewportID: viewportID))
        anchor.removeFromParent()
        // Descending from selected art makes its visibility also gate the label.
        entity.addChild(anchor)
        anchors[viewportID] = anchor
    }
}
