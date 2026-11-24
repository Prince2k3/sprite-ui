#if os(iOS) && !targetEnvironment(macCatalyst)
import SwiftUI

@available(iOS 27.0, *)
@available(macCatalyst, unavailable)
@available(macOS, unavailable)
public extension View {
    /// Shows the source on a noninteractive external accessory without another host.
    @MainActor
    func gameExternalDisplay(
        _ source: GamePresentationSource,
        isEnabled: Bool = true,
        onAvailabilityChange: @escaping @MainActor (Bool) -> Void = { _ in }
    ) -> some View {
        sceneAccessory {
            ExternalNonInteractiveAccessory(isEnabled: .constant(isEnabled)) {
                GamePresentationView(source: source)
            }
            .onAvailabilityChange { @Sendable available in
                Task { @MainActor in onAvailabilityChange(available) }
            }
        }
    }
}
#endif
