import ECSCore
import SwiftUI

@MainActor @Observable
final class GameHingeStore {
    var state: GameHingeState?
    var hasCurrentSample = false
}

private struct GameHingeEnvironmentKey: EnvironmentKey {
    static let defaultValue: GameHingeState? = nil
}

extension EnvironmentValues {
    /// The last observed hinge of this GameView's hierarchy, or nil when unavailable.
    /// Native readings require a physical hinge with an OS-supported sensor.
    /// Available inside the host's SwiftUI attachments; use the callback for an external HUD.
    public var gameHingeState: GameHingeState? {
        get { self[GameHingeEnvironmentKey.self] }
        set { self[GameHingeEnvironmentKey.self] = newValue }
    }
}

struct GameHingePreferenceKey: PreferenceKey {
    static let defaultValue: GameHingeState? = nil
    static func reduce(value: inout GameHingeState?, nextValue: () -> GameHingeState?) { value = nextValue() }
}

extension View {
    /// Observes optional native hinge state from one descendant GameView. Angle is
    /// in radians; use reserved surface regions for layout, rather than hinge angle.
    /// Requires supported physical hinge hardware; devices without it report nil.
    public func onGameHingeChange(_ action: @escaping @MainActor (GameHingeState?) -> Void) -> some View {
        onPreferenceChange(GameHingePreferenceKey.self) { state in
            MainActor.assumeIsolated { action(state) }
        }
    }
}

extension GameHost {
    func invalidateHingeSample() {
        hingeStore.hasCurrentSample = false
        nativeInputSession?.hinge.suspend()
    }

    func updateHingeState(_ state: GameHingeState?) {
        hingeStore.hasCurrentSample = true
        guard hingeStore.state != state else {
            // A fresh identical sample can establish neutral after resumption.
            nativeInputSession?.refresh()
            return
        }
        hingeStore.state = state
        guard !isUpdatingHinge else { return }
        isUpdatingHinge = true
        defer { isUpdatingHinge = false }
        while publishedHingeState != hingeStore.state {
            let previous = publishedHingeState, candidate = hingeStore.state
            nativeInputSession?.refresh()
            guard candidate == hingeStore.state else { continue }
            publishedHingeState = candidate
            world.publish(GameHingeEvents.DidChange(scene: world, previous: previous, state: candidate))
        }
    }
}

extension GameSKView {
    func startHingeObservation() {
#if !os(macOS)
        if #available(iOS 27.1, tvOS 27.1, visionOS 27.1, *), hingeObservation == nil {
            hingeObservationRevision &+= 1
            let revision = hingeObservationRevision
            let interaction = UIHingeInteraction { [weak self] interaction, update in
                guard let self, self.hingeObservationRevision == revision, interaction.isEnabled else { return }
                let state = update.hinge.flatMap { hinge -> GameHingeState? in
                    let status: GameHingeState.Status
                    switch hinge.status {
                    case .closed: status = .closed
                    case .partiallyOpen: status = .partiallyOpen
                    case .fullyOpen: status = .fullyOpen
                    case .unknown: status = .unknown
                    @unknown default: status = .unknown
                    }
                    return GameHingeState(angle: Double(hinge.angle), status: status)
                }
                self.host?.updateHingeState(state)
            }
            interaction.isEnabled = false
            hingeObservation = interaction
            addInteraction(interaction)
        }
#endif
        updateHingeObservationActivity()
    }

    func updateHingeObservationActivity() {
#if !os(macOS)
        if #available(iOS 27.1, tvOS 27.1, visionOS 27.1, *), let interaction = hingeObservation as? UIHingeInteraction {
            let active = host?.isPresentationActive == true && window != nil
            if !active || !interaction.isEnabled { host?.invalidateHingeSample() }
            if interaction.isEnabled != active { interaction.isEnabled = active }
        }
#endif
        if window == nil { host?.updateHingeState(nil) }
    }

    /// Re-enabling asks UIKit for a current sample, including an unchanged angle.
    /// A cached neutral from before focus/scope loss cannot arm the action adapter.
    func refreshHingeObservation() {
#if !os(macOS)
        if #available(iOS 27.1, tvOS 27.1, visionOS 27.1, *),
           host?.isPresentationActive == true, window != nil,
           let interaction = hingeObservation as? UIHingeInteraction {
            interaction.isEnabled = false
            interaction.isEnabled = true
        }
#endif
    }

    func stopHingeObservation() {
#if !os(macOS)
        hingeObservationRevision &+= 1
        if let interaction = hingeObservation {
            removeInteraction(interaction)
            hingeObservation = nil
        }
#endif
        host?.updateHingeState(nil)
    }
}
