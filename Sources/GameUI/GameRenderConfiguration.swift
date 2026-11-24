import CoreGraphics
import Foundation
import Observation

/// Immutable quality limits for render targets and native frame presentation.
/// Pixel limits estimate allocated targets, not total GPU memory consumption.
public struct GameRenderConfiguration: Hashable, Codable, Sendable {
    /// Requested fraction of native display resolution, clamped to 0.1...1.
    public let resolutionScale: Double
    /// Requested presentation rate, clamped to 15...240 to respect the engine's delta cap.
    /// This preference does not change the world's clocks.
    public let preferredFramesPerSecond: Int
    /// Combined drawable, pane, and reserved presentation pixel budget, clamped to 64...268,435,456.
    public let maximumRenderPixels: Int
    /// Maximum width or height of any render target, clamped to 1...16,384.
    public let maximumTextureDimension: Int
    /// Whether resolving an environment may lower resolution and presentation rate.
    public let adaptsToSystemPressure: Bool

    /// Creates limits, clamping finite values and replacing nonfinite resolution scales with one.
    /// The minimum presentation rate is 15 FPS; lower rates would exceed the engine's delta cap.
    public init(resolutionScale: Double = 1, preferredFramesPerSecond: Int = 60,
                maximumRenderPixels: Int = 16_777_216, maximumTextureDimension: Int = 8192,
                adaptsToSystemPressure: Bool = false) {
        self.resolutionScale = resolutionScale.isFinite ? min(1, max(0.1, resolutionScale)) : 1
        self.preferredFramesPerSecond = min(240, max(15, preferredFramesPerSecond))
        self.maximumRenderPixels = min(268_435_456, max(64, maximumRenderPixels))
        self.maximumTextureDimension = min(16_384, max(1, maximumTextureDimension))
        self.adaptsToSystemPressure = adaptsToSystemPressure
    }

    /// Decodes limits using the same validation as the explicit initializer.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(resolutionScale: try values.decode(Double.self, forKey: .resolutionScale),
                  preferredFramesPerSecond: try values.decode(Int.self, forKey: .preferredFramesPerSecond),
                  maximumRenderPixels: try values.decode(Int.self, forKey: .maximumRenderPixels),
                  maximumTextureDimension: try values.decode(Int.self, forKey: .maximumTextureDimension),
                  adaptsToSystemPressure: try values.decode(Bool.self, forKey: .adaptsToSystemPressure))
    }

    /// Returns pressure-adjusted limits without ever raising a caller's quality or frame-rate caps.
    /// Serious pressure caps scale at 0.75 and FPS at 30; critical caps them at 0.5 and 20.
    /// Low Power Mode caps FPS at 30. Repeated resolution against the same environment is idempotent.
    public func resolved(in environment: GameRenderEnvironment) -> Self {
        guard adaptsToSystemPressure else { return self }
        let scaleCap: Double
        let framesCap: Int
        switch environment.thermalState {
        case .nominal, .fair: (scaleCap, framesCap) = (1, 240)
        case .serious: (scaleCap, framesCap) = (0.75, 30)
        case .critical: (scaleCap, framesCap) = (0.5, 20)
        }
        return Self(resolutionScale: min(resolutionScale, scaleCap),
                    preferredFramesPerSecond: min(preferredFramesPerSecond,
                        environment.isLowPowerModeEnabled ? min(framesCap, 30) : framesCap),
                    maximumRenderPixels: maximumRenderPixels,
                    maximumTextureDimension: maximumTextureDimension,
                    adaptsToSystemPressure: adaptsToSystemPressure)
    }

    private enum CodingKeys: String, CodingKey {
        case resolutionScale, preferredFramesPerSecond, maximumRenderPixels
        case maximumTextureDimension, adaptsToSystemPressure
    }
}

/// An immutable system-pressure snapshot that can also be supplied by tests.
public struct GameRenderEnvironment: Hashable, Codable, Sendable {
    /// Thermal pressure levels used to resolve rendering preferences.
    public enum ThermalState: String, Hashable, Codable, Sendable {
        /// The system is operating normally.
        case nominal
        /// The system is warm; rendering preferences remain unchanged.
        case fair
        /// The system requests reduced rendering work.
        case serious
        /// The system requests the strongest rendering reduction.
        case critical
    }

    /// Thermal pressure at the time of the snapshot.
    public let thermalState: ThermalState
    /// Whether the system has enabled Low Power Mode.
    public let isLowPowerModeEnabled: Bool

    /// Creates a snapshot without reading mutable system state.
    public init(thermalState: ThermalState = .nominal, isLowPowerModeEnabled: Bool = false) {
        self.thermalState = thermalState
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
    }

    /// Reads the current process's thermal and power state on the main actor.
    @MainActor public static var current: Self {
        let process = ProcessInfo.processInfo
        let thermal: ThermalState
        switch process.thermalState {
        case .nominal: thermal = .nominal
        case .fair: thermal = .fair
        case .serious: thermal = .serious
        case .critical: thermal = .critical
        @unknown default: thermal = .critical
        }
        return Self(thermalState: thermal, isLowPowerModeEnabled: process.isLowPowerModeEnabled)
    }
}

/// A completed frame's geometry, target-budget estimates, and presentation counters.
/// Statistics describe rendering; they do not control world simulation clocks.
public struct GameRenderStatistics: Equatable, Sendable {
    /// Canvas size in logical points, independent of render resolution.
    public let logicalSize: CGSize
    /// Canvas size in integer render pixels.
    public let drawableSize: CGSize
    /// Number of nonempty viewports rendered in this frame.
    public let renderedViewportCount: Int
    /// Combined pixels allocated for the drawable, panes, and reserved presentation copies.
    public let renderPixels: Int
    /// Estimated target bytes, normally four per pixel; excludes other GPU allocations.
    public let estimatedRenderTargetBytes: Int
    /// Actual resolution relative to native display resolution.
    public let effectiveResolutionScale: Double
    /// Requested native presentation rate; does not change simulation timing.
    public let preferredFramesPerSecond: Int
    /// The render frame's sequence number.
    public let frameNumber: UInt64
    /// Number of presentation frames delivered so far.
    public let presentationFrameCount: UInt64
    /// Number of presentation frames dropped so far.
    public let droppedPresentationFrames: UInt64

    /// Creates a snapshot, defaulting all frame counters to zero and estimated bytes to pixels times four.
    /// An overflowing default byte estimate saturates at the corresponding integer limit.
    public init(logicalSize: CGSize, drawableSize: CGSize, renderedViewportCount: Int,
                renderPixels: Int, estimatedRenderTargetBytes: Int? = nil,
                effectiveResolutionScale: Double, preferredFramesPerSecond: Int,
                frameNumber: UInt64 = 0, presentationFrameCount: UInt64 = 0,
                droppedPresentationFrames: UInt64 = 0) {
        self.logicalSize = logicalSize
        self.drawableSize = drawableSize
        self.renderedViewportCount = renderedViewportCount
        self.renderPixels = renderPixels
        let bytes = renderPixels.multipliedReportingOverflow(by: 4)
        self.estimatedRenderTargetBytes = estimatedRenderTargetBytes
            ?? (bytes.overflow ? (renderPixels < 0 ? Int.min : Int.max) : bytes.partialValue)
        self.effectiveResolutionScale = effectiveResolutionScale
        self.preferredFramesPerSecond = preferredFramesPerSecond
        self.frameNumber = frameNumber
        self.presentationFrameCount = presentationFrameCount
        self.droppedPresentationFrames = droppedPresentationFrames
    }
}

/// An observable, main-actor destination for optional render statistics.
@MainActor @Observable public final class GameRenderMonitor {
    /// Whether the renderer may publish new statistics. Disabling retains the latest snapshot.
    public var isEnabled = true
    /// The most recently recorded snapshot, or nil before recording or after clearing.
    public private(set) var latest: GameRenderStatistics?

    /// Creates an enabled monitor with no recorded frame.
    public init() {}

    func record(_ stats: GameRenderStatistics) {
        guard isEnabled else { return }
        latest = stats
    }

    /// Discards the latest snapshot without changing whether recording is enabled.
    public func clear() { latest = nil }
}

/// Pure target allocation planning. Point geometry remains owned by the caller.
/// This budget includes targets only, not a guarantee about total GPU memory.
struct GameRenderPlan {
    let drawableSize: CGSize
    let panePixelRects: [CGRect]
    let totalRenderPixels: Int
    let effectiveResolutionScale: Double
    let isValid: Bool

    /// Compatibility for offscreen callers that already own a target. Its pixel
    /// aspect ratio may differ from the logical scene; native hosts always use
    /// the bounded configuration initializer below before allocating anything.
    init(logicalSize: CGSize, existingDrawableSize: CGSize, viewportRects: [CGRect]) {
        guard logicalSize.width.isFinite, logicalSize.height.isFinite,
              logicalSize.width > 0, logicalSize.height > 0,
              existingDrawableSize.width.isFinite, existingDrawableSize.height.isFinite,
              existingDrawableSize.width >= 1, existingDrawableSize.height >= 1,
              existingDrawableSize.width <= 16_384, existingDrawableSize.height <= 16_384 else {
            self = Self(emptyPaneCount: viewportRects.count)
            return
        }
        drawableSize = existingDrawableSize
        panePixelRects = viewportRects.map {
            Self.pixelRect(Self.clip($0, to: logicalSize), logicalSize: logicalSize, pixelSize: existingDrawableSize)
        }
        totalRenderPixels = panePixelRects.reduce(Self.area(CGRect(origin: .zero, size: drawableSize))) {
            Self.add($0, Self.area($1))
        }
        effectiveResolutionScale = Double(existingDrawableSize.width / logicalSize.width)
        isValid = true
    }

    /// Reserves zero to three presentation copies. A nil selection copies the canvas;
    /// an unavailable or empty selected pane reserves no presentation pixels.
    init(logicalSize: CGSize, displayScale: CGFloat, viewportRects: [CGRect],
         configuration: GameRenderConfiguration, presentationViewportIndex: Int? = nil,
         presentationCopies: Int = 0) {
        guard logicalSize.width.isFinite, logicalSize.height.isFinite,
              logicalSize.width > 0, logicalSize.height > 0,
              displayScale.isFinite, displayScale > 0 else {
            self = Self(emptyPaneCount: viewportRects.count)
            return
        }
        let longSide = max(logicalSize.width, logicalSize.height)
        // Multiply the factors in an order that avoids intermediate overflow or
        // underflow when a huge canvas has a tiny scale (or vice versa).
        let requestedLongSide = longSide > 1
            ? (longSide * configuration.resolutionScale) * displayScale
            : (longSide * displayScale) * configuration.resolutionScale
        var pixels = Int(max(1, min(CGFloat(configuration.maximumTextureDimension),
                                    requestedLongSide.rounded(.down))))
        let clipped = viewportRects.map { Self.clip($0, to: logicalSize) }
        let copies = min(3, max(0, presentationCopies))

        while true {
            let width = max(1, Int((CGFloat(pixels) * (logicalSize.width / longSide)).rounded(.down)))
            let height = max(1, Int((CGFloat(pixels) * (logicalSize.height / longSide)).rounded(.down)))
            let size = CGSize(width: width, height: height)
            let panes = clipped.map { Self.pixelRect($0, logicalSize: logicalSize, pixelSize: size) }
            let canvasPixels = width * height
            var total = canvasPixels
            for pane in panes { total = Self.add(total, Self.area(pane)) }
            let presentationPixels: Int
            if let index = presentationViewportIndex {
                presentationPixels = panes.indices.contains(index) ? Self.area(panes[index]) : 0
            } else {
                presentationPixels = canvasPixels
            }
            // Each individual target is at most 16,384 squared; three copies
            // cannot overflow Int on the supported 64-bit platforms.
            total = Self.add(total, presentationPixels * copies)
            if total <= configuration.maximumRenderPixels {
                drawableSize = size
                panePixelRects = panes
                totalRenderPixels = total
                // Use the long axis, whose integer size controls the global scale.
                let scale = (CGFloat(pixels) / longSide) / displayScale
                if scale.isFinite {
                    effectiveResolutionScale = Double(scale)
                } else {
                    let reordered = (CGFloat(pixels) / displayScale) / longSide
                    effectiveResolutionScale = reordered.isFinite ? Double(reordered) : .greatestFiniteMagnitude
                }
                isValid = true
                return
            }
            guard pixels > 1 else {
                self = Self(emptyPaneCount: viewportRects.count)
                return
            }
            // A quadratic estimate skips oversized candidates. Always reduce by
            // at least one: independently rounded pane areas need not be monotone.
            let reduction = sqrt(Double(configuration.maximumRenderPixels) / Double(total))
            pixels = max(1, min(pixels - 1, Int((Double(pixels) * reduction).rounded(.down))))
        }
    }

    private init(emptyPaneCount: Int) {
        drawableSize = .zero
        panePixelRects = Array(repeating: .zero, count: emptyPaneCount)
        totalRenderPixels = 0
        effectiveResolutionScale = 0
        isValid = false
    }

    private static func clip(_ rect: CGRect, to size: CGSize) -> CGRect {
        guard !rect.isNull, !rect.isInfinite,
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.size.width.isFinite, rect.size.height.isFinite,
              rect.size.width > 0, rect.size.height > 0 else { return .zero }
        let left = max(0, rect.origin.x), top = max(0, rect.origin.y)
        // Positive endpoint overflow clips to the finite canvas edge safely.
        let right = min(size.width, rect.origin.x + rect.width)
        let bottom = min(size.height, rect.origin.y + rect.height)
        guard right > left, bottom > top else { return .zero }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    private static func pixelRect(_ rect: CGRect, logicalSize: CGSize, pixelSize: CGSize) -> CGRect {
        guard !rect.isEmpty else { return .zero }
        // Normalize before multiplying: point-to-pixel scale itself may overflow.
        let left = min(pixelSize.width, max(0, (rect.minX / logicalSize.width * pixelSize.width).rounded()))
        let top = min(pixelSize.height, max(0, (rect.minY / logicalSize.height * pixelSize.height).rounded()))
        let right = min(pixelSize.width, max(left, (rect.maxX / logicalSize.width * pixelSize.width).rounded()))
        let bottom = min(pixelSize.height, max(top, (rect.maxY / logicalSize.height * pixelSize.height).rounded()))
        guard right > left, bottom > top else { return .zero }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    private static func area(_ rect: CGRect) -> Int { Int(rect.width) * Int(rect.height) }

    private static func add(_ lhs: Int, _ rhs: Int) -> Int {
        let sum = lhs.addingReportingOverflow(rhs)
        return sum.overflow ? Int.max : sum.partialValue
    }
}
