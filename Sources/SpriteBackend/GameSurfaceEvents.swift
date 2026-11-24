import ECSCore

/// Events describing the presentation surface rather than simulated game state.
public enum GameSurfaceEvents {
    /// A host's local bounds, scale, safe area, or reserved regions changed.
    /// The host updates its geometry and cancels affected captures before delivery.
    public struct DidChange: Event {
        /// The world presented by the host.
        public let scene: World
        /// The previously reported geometry, initially an empty surface.
        public let previous: GameSurfaceGeometry
        /// The new geometry in local, top-left points.
        public let geometry: GameSurfaceGeometry
        /// Creates a surface change notification.
        public init(scene: World, previous: GameSurfaceGeometry, geometry: GameSurfaceGeometry) {
            self.scene = scene; self.previous = previous; self.geometry = geometry
        }
    }
}
