import Observation
import SpriteUI
import SwiftUI

/// One landscape, two camera passes, and unchanged model-space anchors.
@MainActor
struct ContentView: View {
    @State private var model = ParallaxDemoModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("One landscape · two cameras").font(.headline)
                GameView(viewports: model.viewports) { model.install(in: $0) } attachments: {
                    GameAttachment(id: "model-anchor") {
                        Text("Model anchor").font(.system(size: 9, weight: .bold))
                            .padding(3).background(.black.opacity(0.8), in: Capsule())
                    }
                }
                .overlay {
                    HStack(spacing: 0) {
                        pane("A", color: .cyan)
                        if model.split { pane("B", color: .orange) }
                    }
                    .allowsHitTesting(false).accessibilityHidden(true)
                }
                .frame(height: 220).clipped()
                .accessibilityLabel("Shared star, mountain, and ground landscape through independent cameras")
                .accessibilityIdentifier("parallax-landscape")

                ParallaxDemoActivity(model: model)
                cameraControls(0)
                cameraControls(1)
                    .disabled(!model.split)

                Picker("Background layer", selection: $model.selectedLayer) {
                    Text("Stars").tag(0)
                    Text("Mountains").tag(1)
                    Text("Ground").tag(2)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("parallax-layer")
                HStack {
                    Text("Factor \(model.factors[model.selectedLayer], specifier: "%.2f")")
                        .font(.caption.monospacedDigit()).frame(width: 90, alignment: .leading)
                    Slider(value: Binding(
                        get: { model.factors[model.selectedLayer] },
                        set: { model.setFactor($0) }), in: -0.5...1.5, step: 0.05)
                        .accessibilityLabel("Scroll factor for \(model.layerName)")
                        .accessibilityIdentifier("parallax-factor")
                }
                .frame(minHeight: 44)
                HStack {
                    Toggle("Repeat", isOn: $model.repeats)
                        .accessibilityIdentifier("parallax-repeat")
                    Toggle("Split", isOn: $model.split)
                        .accessibilityIdentifier("parallax-split")
                }
                .font(.subheadline).frame(minHeight: 44)
                Text("0 follows camera translation · 1 stays in world. Zoom scales normally. The cyan child and label stay at the mountain’s model anchor.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
        }
        .background(.black).preferredColorScheme(.dark)
        .onChange(of: model.repeats) { _, _ in model.applyRepeat() }
    }

    private func pane(_ title: String, color: Color) -> some View {
        Rectangle().strokeBorder(color, lineWidth: 1)
            .overlay(alignment: .topLeading) {
                Text(title).font(.caption.bold()).padding(5).background(.black.opacity(0.8))
            }
    }

    private func cameraControls(_ index: Int) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("\(index == 0 ? "A" : "B") x \(model.cameraX[index], specifier: "%.0f")")
                    .font(.caption.monospacedDigit()).frame(width: 78, alignment: .leading)
                Button { model.shiftCamera(index, by: -80) } label: {
                    Image(systemName: "arrow.left").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Move camera \(index == 0 ? "A" : "B") left 80 points")
                Slider(value: Binding(get: { model.cameraX[index] },
                                      set: { model.setCamera(index, x: $0) }), in: -1200...1200)
                    .accessibilityLabel("Camera \(index == 0 ? "A" : "B") horizontal position")
                Button { model.shiftCamera(index, by: 80) } label: {
                    Image(systemName: "arrow.right").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Move camera \(index == 0 ? "A" : "B") right 80 points")
            }
            HStack {
                Text("Zoom \(model.zooms[index], specifier: "%.1f")×")
                    .font(.caption.monospacedDigit()).frame(width: 78, alignment: .leading)
                Slider(value: Binding(get: { model.zooms[index] },
                                      set: { model.setZoom(index, value: $0) }), in: 0.6...2, step: 0.1)
                    .accessibilityLabel("Camera \(index == 0 ? "A" : "B") zoom")
            }
            .frame(minHeight: 32)
        }
        .tint(index == 0 ? .cyan : .orange)
    }
}

/// Observe frame counters here, keeping per-frame changes out of GameView setup.
@MainActor
private struct ParallaxDemoActivity: View {
    let model: ParallaxDemoModel
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("One world · \(model.updates) updates · \(model.frames) frames")
            Text("Model anchors: \(model.changedAnchors)/\(model.anchorCount) changed")
        }
        .font(.caption.monospacedDigit())
        .accessibilityIdentifier("parallax-anchor-count")
    }
}

@MainActor @Observable
private final class ParallaxDemoModel {
    var split = true
    var repeats = true
    var selectedLayer = 1
    var factors: [Float] = [0.12, 0.45, 1]
    var cameraX: [Float] = [-45, 45]
    var zooms: [Float] = [1, 1]
    var updates = 0
    var frames = 0
    var changedAnchors = 0
    var anchorCount = 0
    @ObservationIgnored private let cameras = [
        Entity(name: "Camera A", components: CameraComponent(smoothing: 0)),
        Entity(name: "Camera B", components: CameraComponent(smoothing: 0))
    ]
    @ObservationIgnored private var layers: [Entity] = []
    @ObservationIgnored private var anchors: [(entity: Entity, position: SIMD2<Float>)] = []
    @ObservationIgnored private var subscriptions: [EventSubscription] = []

    var layerName: String { ["stars", "mountains", "ground"][selectedLayer] }
    var viewports: [GameViewport] {
        var result = [GameViewport(id: "a", camera: cameras[0].id,
                                  frame: split ? .init(x: 0, y: 0, width: 0.5, height: 1) : .full)]
        if split {
            result.append(GameViewport(id: "b", camera: cameras[1].id,
                                       frame: .init(x: 0.5, y: 0, width: 0.5, height: 1)))
        }
        return result
    }

    func install(in content: GameViewContent) {
        content.renderer.backgroundColor = .black
        for index in 0..<3 {
            let size: SIMD2<Float> = index == 0 ? [256, 512] : index == 1 ? [256, 256] : [128, 192]
            let layer = Entity(name: ["Stars", "Mountains", "Ground"][index], components:
                SpriteComponent(image: ParallaxDemoTiles.image(index), size: size),
                ParallaxComponent(scrollFactor: [factors[index], 1]),
                RepeatingBackgroundComponent(axes: index == 0 ? .both : .horizontal,
                                             maximumTileCount: 256, isEnabled: repeats))
            layer.position = [0, index == 2 ? -140 : 0]
            layer.zPosition = Float(index - 3)
            layers.append(layer)
            content.add(layer)
        }
        let marker = Entity(name: "Unshifted child", components:
            SpriteComponent(color: .cyan, size: [8, 18]))
        marker.zPosition = 10
        let label = Entity(components: AttachmentComponent(id: "model-anchor", offset: [0, 22]))
        // Ordinary children and attachments do not inherit the sprite-only offset.
        layers[1].addChild(marker)
        layers[1].addChild(label)
        anchors = (layers + [marker, label]).map { ($0, $0.position) }
        anchorCount = anchors.count
        for index in 0..<2 {
            cameras[index].position = [cameraX[index], 0]
            cameras[index].components[CameraComponent.self]?.zoom = zooms[index]
            content.add(cameras[index])
        }
        subscriptions = [
            content.subscribe(to: WorldEvents.Update.self) { [weak self] _ in self?.updates += 1 },
            content.subscribe(to: RenderingEvents.DidUpdate.self) { [weak self] _ in
                guard let self else { return }
                frames += 1
                changedAnchors = anchors.filter { $0.entity.position != $0.position }.count
            }
        ]
    }

    func setFactor(_ value: Float) {
        factors[selectedLayer] = value
        guard layers.indices.contains(selectedLayer) else { return }
        layers[selectedLayer].components[ParallaxComponent.self]?.scrollFactor = [value, 1]
    }

    func setCamera(_ index: Int, x: Float) {
        cameraX[index] = min(1200, max(-1200, x))
        cameras[index].position = [cameraX[index], 0]
    }

    func shiftCamera(_ index: Int, by delta: Float) { setCamera(index, x: cameraX[index] + delta) }

    func setZoom(_ index: Int, value: Float) {
        zooms[index] = value
        cameras[index].components[CameraComponent.self]?.zoom = value
    }

    func applyRepeat() {
        for layer in layers { layer.components[RepeatingBackgroundComponent.self]?.isEnabled = repeats }
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
