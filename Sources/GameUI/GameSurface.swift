@_spi(Backend) import SpriteBackend
import ECSCore
import SwiftUI

@MainActor @Observable
final class GameSurfaceState {
    var geometry = GameSurfaceGeometry(size: .zero)
}

private struct GameSurfaceEnvironmentKey: EnvironmentKey {
    static let defaultValue = GameSurfaceGeometry(size: .zero)
}

extension EnvironmentValues {
    /// Local surface geometry for SwiftUI content hosted inside a GameView,
    /// including its attachments. Outside a GameView this is an empty surface.
    public var gameSurfaceGeometry: GameSurfaceGeometry {
        get { self[GameSurfaceEnvironmentKey.self] }
        set { self[GameSurfaceEnvironmentKey.self] = newValue }
    }
}

struct GameSurfacePreferenceKey: PreferenceKey {
    static let defaultValue = GameSurfaceGeometry(size: .zero)
    static func reduce(value: inout GameSurfaceGeometry, nextValue: () -> GameSurfaceGeometry) {
        value = nextValue()
    }
}

extension View {
    /// Observes geometry reported by one descendant GameView. Place this on that
    /// GameView before combining several hosts; all frames use its local points.
    /// The initial empty geometry can arrive before native layout completes.
    public func onGameSurfaceChange(_ action: @escaping @MainActor (GameSurfaceGeometry) -> Void) -> some View {
        onPreferenceChange(GameSurfacePreferenceKey.self) { geometry in
            MainActor.assumeIsolated { action(geometry) }
        }
    }
}

extension GameHost {
    /// Coalesces reentrant changes against the last delivered geometry. A nested
    /// metadata update must not erase a pending layout change or context invalidation.
    func updateSurfaceGeometry(_ geometry: GameSurfaceGeometry) {
        guard surfaceState.geometry != geometry else { return }
        surfaceState.geometry = geometry
        renderer.setSurfaceGeometry(geometry)
        renderer.size = geometry.size
        guard !isUpdatingSurface else { return }
        isUpdatingSurface = true
        defer { isUpdatingSurface = false }
        while publishedSurfaceGeometry != surfaceState.geometry {
            let previous = publishedSurfaceGeometry
            let candidate = surfaceState.geometry
            let layoutChanged = previous.size != candidate.size || previous.safeBounds != candidate.safeBounds
                || previous.usableRegions() != candidate.usableRegions()
            if layoutChanged { cancelInputs(preservingHinge: true) }
            // A cancellation callback may supersede either layout or metadata.
            // Keep the old delivered geometry until the newest candidate settles.
            guard candidate == surfaceState.geometry else { continue }
            if layoutChanged { attachmentStore.surfaceDidChange() }
            publishedSurfaceGeometry = candidate
            world.publish(GameSurfaceEvents.DidChange(scene: world, previous: previous, geometry: candidate))
        }
    }
}

extension GameSKView {
    /// Queries the containing view, never a global screen or device-size table.
    func synchronizeSurfaceGeometry() {
        guard let host else { return }
#if os(macOS)
        let scale = window?.backingScaleFactor ?? 1
        let insets = safeAreaInsets
        let safe = GameSurfaceGeometry.Insets(top: insets.top, left: insets.left,
                                             bottom: insets.bottom, right: insets.right)
        let regions = host.surfaceRegions ?? []
#else
        let scale = traitCollection.displayScale
        let insets = safeAreaInsets
        let safe = GameSurfaceGeometry.Insets(top: insets.top, left: insets.left,
                                             bottom: insets.bottom, right: insets.right)
        let regions = host.surfaceRegions ?? nativeReservedRegions()
#endif
        host.updateSurfaceGeometry(GameSurfaceGeometry(size: bounds.size, displayScale: scale,
                                                       safeAreaInsets: safe, reservedRegions: regions))
    }

#if !os(macOS)
    private func nativeReservedRegions() -> [GameSurfaceGeometry.ReservedRegion] {
        if #available(iOS 27.1, tvOS 27.1, visionOS 27.1, *) {
            var live: Set<AnyHashable> = []
            let result = [UIView.ReservedRegion.Kind.occlusion, .division].flatMap { kind in
                reservedRegions(kind: kind, options: .includeInactive).map { region in
                    let key = AnyHashable(region.id)
                    live.insert(key)
                    if nativeRegionIDs[key] == nil { nativeRegionIDs[key] = UUID().uuidString }
                    // UIKit's frame already includes margins. It is measured in
                    // this view's points, including possible partial overlaps.
                    return GameSurfaceGeometry.ReservedRegion(id: nativeRegionIDs[key]!,
                        kind: kind == .occlusion ? .occlusion : .division,
                        frame: region.frame.offsetBy(dx: -bounds.minX, dy: -bounds.minY), isActive: region.isActive)
                }
            }
            nativeRegionIDs = nativeRegionIDs.filter { live.contains($0.key) }
            return result
        }
        return []
    }
#endif
}
