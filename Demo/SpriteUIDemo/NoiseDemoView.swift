import SpriteUI
import SwiftUI

/// The Noise milestone: a `Noise` recipe sampled into a `NoiseMap`, colored with a
/// `NoiseGradient` and drawn as a `SpriteImage`. Drag to pan across the field.
struct NoiseDemoView: View {
    @State private var scene = NoiseScene()
    @State private var dragStart: SIMD2<Double>?

    var body: some View {
        VStack(spacing: 0) {
            GameView { content in
                scene.build(in: content)
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { scene.resize(to: $0) }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let start = dragStart ?? scene.offset
                    dragStart = start
                    scene.pan(from: start, by: value.translation)
                }
                .onEnded { _ in dragStart = nil })
            .overlay(alignment: .top) {
                Text(scene.caption)
                    .font(.caption.bold().monospacedDigit())
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: .capsule)
                    .padding(.top, 8)
            }

            VStack(spacing: 10) {
                Picker("Kind", selection: $scene.kind) {
                    ForEach(NoiseScene.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("Scale").font(.footnote)
                    Slider(value: $scene.frequency, in: 0.5...8)
                    Text(scene.frequency, format: .number.precision(.fractionLength(1)))
                        .font(.footnote.monospacedDigit()).frame(width: 32)
                }

                HStack {
                    Toggle("Terrain", isOn: $scene.terrainColors)
                    Toggle("Terraces", isOn: $scene.terraces)
                    Toggle("Warp", isOn: $scene.warped)
                    Button("Reseed") { scene.seed &+= 1 }
                }
                .toggleStyle(.button)
                .buttonStyle(.bordered)
                .tint(.orange)
                .font(.footnote)
            }
            .padding()
        }
        .onChange(of: scene.kind) { scene.redraw() }
        .onChange(of: scene.frequency) { scene.redraw() }
        .onChange(of: scene.terrainColors) { scene.redraw() }
        .onChange(of: scene.terraces) { scene.redraw() }
        .onChange(of: scene.warped) { scene.redraw() }
        .onChange(of: scene.seed) { scene.redraw() }
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}

// MARK: Scene

@MainActor
@Observable
final class NoiseScene {
    enum Kind: String, CaseIterable {
        case perlin = "Perlin", billow = "Billow", ridged = "Ridged", voronoi = "Voronoi", mix = "Mix"
    }

    /// Pixels across the image; rows follow the view's shape.
    static let columns = 96

    // Reactions live in the view's `onChange`, not `didSet` (see MazeScene).
    var kind = Kind.perlin
    var frequency = 3.0
    var terrainColors = true
    var terraces = false
    var warped = false
    var seed: Int32 = 1
    private(set) var offset: SIMD2<Double> = .zero
    private(set) var caption = ""

    @ObservationIgnored private let canvas = Entity(name: "noise")
    @ObservationIgnored private var viewSize = CGSize(width: 400, height: 600)

    func build(in content: GameViewContent) {
        content.add(canvas)
        redraw()
    }

    func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0, size != viewSize else { return }
        viewSize = size
        redraw()
    }

    /// Drags the field with the finger: a full view width moves one unit of noise space.
    func pan(from start: SIMD2<Double>, by translation: CGSize) {
        let unit = Double(viewSize.width)
        offset = start - [Double(translation.width) / unit, -Double(translation.height) / unit]
        redraw()
    }

    var noise: Noise {
        let f = frequency
        var noise: Noise
        switch kind {
        case .perlin: noise = .perlin(frequency: f, octaves: 5, seed: seed)
        case .billow: noise = .billow(frequency: f, octaves: 5, seed: seed)
        case .ridged: noise = .ridged(frequency: f, octaves: 5, seed: seed)
        case .voronoi: noise = .voronoi(frequency: f, includesDistance: true, seed: seed).remapped(scale: 0.5)
        case .mix:
            // Rolling hills where a slow selector is low, ridges where it's high.
            noise = Noise.billow(frequency: f, octaves: 4, seed: seed).remapped(scale: 0.4, bias: -0.2)
                .blended(with: .ridged(frequency: f, octaves: 5, seed: seed &+ 1),
                         by: Noise.perlin(frequency: f / 4, octaves: 2, seed: seed &+ 2).remapped(scale: 2.5))
        }
        if warped { noise = noise.turbulent(frequency: f, power: 0.4 / f, roughness: 3, seed: seed &+ 9) }
        if terraces { noise = noise.terraced(peaks: [-1, -0.4, 0, 0.3, 0.6, 1]) }
        return noise
    }

    func redraw() {
        let aspect = Double(viewSize.height / viewSize.width)
        let rows = max(Int((Double(Self.columns) * aspect).rounded()), 1)
        let size = SIMD2(1.0, aspect)
        let clock = ContinuousClock()
        let start = clock.now
        let map = NoiseMap(noise, origin: offset - size / 2, size: size, sampleCount: [Self.columns, rows])
        let elapsed = start.duration(to: clock.now)
        let image = SpriteImage(map, gradient: terrainColors ? .terrain : .grayscale)
        canvas.components.set(SpriteComponent(
            image: image, size: [Float(viewSize.width), Float(viewSize.height)]
        ))
        let ms = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
        caption = "\(Self.columns)×\(rows) samples · \(Int(ms.rounded())) ms · drag to pan"
    }
}
