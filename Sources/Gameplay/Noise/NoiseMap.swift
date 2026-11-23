/// A grid of samples from a ``Noise`` field.
///
/// Row 0 is the bottom of the sampled area (lowest y), matching scene space.
///
/// ```swift
/// let map = NoiseMap(.perlin(frequency: 4, seed: 3), size: [1, 1], sampleCount: [128, 128])
/// let height = map[64, 64]
/// ```
public struct NoiseMap: Hashable, Codable, Sendable {
    /// The corner of the sampled area with the lowest x and y, in noise space.
    public let origin: SIMD2<Double>
    /// The width and height of the sampled area, in noise space.
    public let size: SIMD2<Double>
    /// Columns and rows.
    public let sampleCount: SIMD2<Int>
    /// Whether opposite edges were blended so the map tiles without seams.
    public let isSeamless: Bool
    /// Samples row by row, starting with the bottom row.
    public private(set) var values: [Float]

    /// Samples `noise` over the rectangle at `origin` with `size`.
    ///
    /// - Parameter seamless: Blends each sample with ones a whole map away, so the
    ///   left edge matches the right and the top matches the bottom. Seamless maps
    ///   look a little smoother and take four times as long to make.
    public init(
        _ noise: Noise,
        origin: SIMD2<Double> = .zero,
        size: SIMD2<Double> = [1, 1],
        sampleCount: SIMD2<Int> = [64, 64],
        seamless: Bool = false
    ) {
        let columns = max(sampleCount.x, 1), rows = max(sampleCount.y, 1)
        self.origin = origin
        self.size = size
        self.sampleCount = [columns, rows]
        self.isSeamless = seamless
        let step = size / SIMD2(Double(columns), Double(rows))
        var values = [Float](repeating: 0, count: columns * rows)
        values.withUnsafeMutableBufferPointer { buffer in
            for row in 0..<rows {
                let v = Double(row) / Double(rows)
                let y = origin.y + Double(row) * step.y
                for column in 0..<columns {
                    let u = Double(column) / Double(columns)
                    let x = origin.x + Double(column) * step.x
                    let value: Double
                    if seamless {
                        // Bilinear blend with copies shifted back a whole map, so
                        // at u = 1 we're sampling exactly what u = 0 sampled.
                        let a = noise.value(at: [x, y])
                        let b = noise.value(at: [x - size.x, y])
                        let c = noise.value(at: [x, y - size.y])
                        let d = noise.value(at: [x - size.x, y - size.y])
                        let bottom = a * (1 - u) + b * u
                        let top = c * (1 - u) + d * u
                        value = bottom * (1 - v) + top * v
                    } else {
                        value = noise.value(at: [x, y])
                    }
                    buffer[row * columns + column] = Float(value)
                }
            }
        }
        self.values = values
    }

    /// The sample in `column` and `row`, wrapping around the edges.
    public subscript(column: Int, row: Int) -> Float {
        get {
            let c = ((column % sampleCount.x) + sampleCount.x) % sampleCount.x
            let r = ((row % sampleCount.y) + sampleCount.y) % sampleCount.y
            return values[r * sampleCount.x + c]
        }
        set {
            let c = ((column % sampleCount.x) + sampleCount.x) % sampleCount.x
            let r = ((row % sampleCount.y) + sampleCount.y) % sampleCount.y
            values[r * sampleCount.x + c] = newValue
        }
    }

    /// The smallest and largest samples.
    public var range: ClosedRange<Float> {
        guard let low = values.min(), let high = values.max() else { return 0...0 }
        return low...high
    }

    /// Stretches the samples so they fill `target` exactly.
    public mutating func normalize(to target: ClosedRange<Float> = -1...1) {
        let current = range
        let span = current.upperBound - current.lowerBound
        guard span > 0 else { return }
        let scale = (target.upperBound - target.lowerBound) / span
        for i in values.indices {
            values[i] = target.lowerBound + (values[i] - current.lowerBound) * scale
        }
    }

    /// Colors every sample with `gradient`, giving 8-bit RGBA pixels with the top
    /// row first, as image APIs expect.
    public func rgbaPixels(using gradient: NoiseGradient) -> [UInt8] {
        let columns = sampleCount.x, rows = sampleCount.y
        var pixels = [UInt8](repeating: 0, count: columns * rows * 4)
        pixels.withUnsafeMutableBufferPointer { buffer in
            for row in 0..<rows {
                let source = (rows - 1 - row) * columns
                for column in 0..<columns {
                    let color = gradient.color(at: values[source + column])
                    let i = (row * columns + column) * 4
                    for channel in 0..<4 {
                        buffer[i + channel] = UInt8((min(max(color[channel], 0), 1) * 255).rounded())
                    }
                }
            }
        }
        return pixels
    }
}

/// Maps noise values to colors.
///
/// Colors are linear RGBA in 0...1. Values between stops are blended; values past
/// the ends take the end color.
public struct NoiseGradient: Hashable, Codable, Sendable {
    public struct Stop: Hashable, Codable, Sendable {
        public var value: Float
        public var color: SIMD4<Float>

        public init(_ value: Float, _ color: SIMD4<Float>) {
            self.value = value
            self.color = color
        }
    }

    /// Stops in order of value.
    public let stops: [Stop]

    public init(_ stops: [Stop]) {
        self.stops = stops.sorted { $0.value < $1.value }
    }

    /// The color for `value`.
    public func color(at value: Float) -> SIMD4<Float> {
        guard let first = stops.first, let last = stops.last else { return [0, 0, 0, 1] }
        if value <= first.value { return first.color }
        if value >= last.value { return last.color }
        var i = 1
        while stops[i].value < value { i += 1 }
        let low = stops[i - 1], high = stops[i]
        let span = high.value - low.value
        let t = span > 0 ? (value - low.value) / span : 1
        return low.color + (high.color - low.color) * t
    }

    /// Black at -1 to white at 1.
    public static let grayscale = NoiseGradient([.init(-1, [0, 0, 0, 1]), .init(1, [1, 1, 1, 1])])

    /// Deep water, shallows, sand, grass, rock and snow.
    public static let terrain = NoiseGradient([
        .init(-1, [0.02, 0.07, 0.25, 1]),
        .init(-0.25, [0.08, 0.30, 0.60, 1]),
        .init(-0.05, [0.85, 0.80, 0.55, 1]),
        .init(0.05, [0.30, 0.62, 0.22, 1]),
        .init(0.45, [0.18, 0.40, 0.15, 1]),
        .init(0.65, [0.45, 0.40, 0.36, 1]),
        .init(0.85, [0.95, 0.95, 0.97, 1]),
    ])
}
