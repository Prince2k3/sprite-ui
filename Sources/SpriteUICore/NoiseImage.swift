import Gameplay
import SpriteBackend

extension SpriteImage {
    /// Colors a noise map with `gradient`, one pixel per sample.
    public init(_ map: NoiseMap, gradient: NoiseGradient = .grayscale, smoothsScaling: Bool = true) {
        self.init(
            width: map.sampleCount.x, height: map.sampleCount.y,
            pixels: map.rgbaPixels(using: gradient), smoothsScaling: smoothsScaling
        )
    }
}
