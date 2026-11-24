import SwiftUI
@preconcurrency import GameKit

private struct GameCenterServicesEnvironmentKey: EnvironmentKey {
    static let defaultValue: GameCenterServices? = nil
}

extension EnvironmentValues {
    /// The app-scoped services installed by `View.gameCenter(_:)`.
    public var gameCenterServices: GameCenterServices? {
        get { self[GameCenterServicesEnvironmentKey.self] }
        set { self[GameCenterServicesEnvironmentKey.self] = newValue }
    }
}

extension View {
    /// Installs the shared environment and one presentation host. Apply once to
    /// a stable parent view; present destinations through the services object.
    /// No authentication or matchmaking starts just because a view appears.
    public func gameCenter(_ services: GameCenterServices) -> some View {
        modifier(GameCenterServicesModifier(services: services))
    }
}

@MainActor
private struct GameCenterServicesModifier: ViewModifier {
    let services: GameCenterServices
    func body(content: Content) -> some View {
        content
            .environment(\.gameCenterServices, services)
            .sheet(isPresented: Binding(get: { services.destination != nil }, set: { if !$0 { services.dismiss() } })) {
                GameCenterServicesSheet(services: services)
            }
            .onChange(of: services.multiplayer.authenticationState, initial: true) { _, _ in services.authenticationDidChange() }
            .onChange(of: services.multiplayer.localPeer?.id) { _, _ in services.authenticationDidChange() }
            .onChange(of: services.multiplayer.matchmakingState) { _, _ in services.matchmakingDidChange() }
            .onDisappear { services.shutdown() }
    }
}

/// Ready-made entry buttons for an app's menu. Install `.gameCenter(services)`
/// on a parent, then use this view or call `services.present(_:)` yourself.
@MainActor
public struct GameCenterServicesView: View {
    private let services: GameCenterServices
    public init(services: GameCenterServices) { self.services = services }
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(services.isPreview ? "Game services · local preview" : "Game Center").font(.headline)
            Text(services.localPlayer?.displayName ?? "Sign in to use your Game Center account")
                .font(.subheadline).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 8) {
                Button("Sign in") { services.present(.signIn) }
                Button("Real-time match") { services.present(.matchmaking) }
                Button("Turn-based games") { services.present(.turnBased) }
                Button("Achievements") { services.present(.achievements) }
                Button("Leaderboards") { services.present(.leaderboards) }
                Button("Activities") { services.present(.activities) }
                    .disabled(!services.isPreview && !GameCenterActivities.isSupported)
                Button("Challenges") { services.present(.challenges) }
                    .disabled(!services.isPreview && !GameCenterActivities.isSupported)
                Button("Setup help") { services.present(.setup) }
            }.buttonStyle(.bordered)
            if let error = services.lastError { Text(error.localizedDescription).font(.caption).foregroundStyle(.red) }
        }
    }
}

@MainActor
private struct GameCenterServicesSheet: View {
    let services: GameCenterServices
    var body: some View {
        Group {
            switch services.destination {
            case .signIn:
                if services.isPreview {
                    message(title: "Local preview", text: "Preview services use a local identity. No Game Center sign-in is needed.")
                } else { GameCenterAuthenticationView(multiplayer: services.multiplayer) }
            case .matchmaking:
                if services.isPreview {
                    message(title: "Local preview", text: "Real-time Game Center matchmaking needs two signed-in accounts. Use InMemoryNetwork to preview entity replication without an account.")
                } else { GameCenterMatchmakingView(multiplayer: services.multiplayer, request: services.matchRequest) }
            case .turnBased:
                GameCenterTurnBasedMatchmakingView(service: services.turnBased, request: .init())
            case .activities:
                GameCenterActivitiesView(services: services)
            case .challenges:
                GameCenterChallengesView(services: services)
            case .achievements, .leaderboards, .leaderboard, .activityDefinition, .challengeOverview, .challengeDefinition:
                if services.isPreview {
                    message(title: "Local preview", text: "Preview progress, scores, activities, and challenge attempts stay on this device. Native invitations and friend challenges require configured Game Center resources and an account.")
                } else if let destination = services.destination {
                    let revision = services.presentationRevision
                    GameCenterDashboardPresentation(destination: destination) { services.finishPresentation(revision: revision) } failed: {
                        services.finishPresentation(revision: revision, error: GameCenterServiceError.unavailable)
                    }
                    .id(revision)
                }
            case .setup:
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Game Center setup").font(.title2.bold())
                        Text("Bundle ID: \(Bundle.main.bundleIdentifier ?? "Missing")").textSelection(.enabled)
                        Text("1. Enable Game Center in your app target’s Signing & Capabilities, using your development team.")
                        Text("2. Configure the matching app and Game Center app version in App Store Connect. Enable compatible versions for multiplayer.")
                        Text("3. Create achievement and leaderboard identifiers there, or test their GameKit configuration in Xcode.")
                        Text("Activities and challenges additionally require iOS/macOS 26+, configured definitions, and early application routing for incoming activities. Native multi-account verification is separate from previews.")
                        Text("4. For a sandboxed Mac app, permit incoming and outgoing network connections.")
                        Text("5. Run the bundled check-game-center-setup.py tool against the built app to inspect its signed entitlements. Server configuration requires a separate check in App Store Connect.")
                        Text("Preview mode tests local behavior. Verify live services in a signed build using your Game Center test accounts.").foregroundStyle(.secondary)
                        Button("Done") { services.dismiss() }.buttonStyle(.borderedProminent)
                    }.padding()
                }
            case nil: EmptyView()
            }
        }.frame(minWidth: 320, minHeight: 240)
    }
    private func message(title: String, text: String) -> some View {
        VStack(spacing: 16) {
            Text(title).font(.headline)
            Text(text).multilineTextAlignment(.center)
            Button("Done") { services.dismiss() }
        }.padding()
    }
}

@MainActor
private func triggerDashboard(_ destination: GameCenterDestination, finished: @escaping @MainActor () -> Void) {
    let completion = { @Sendable in DispatchQueue.main.async { finished() } }
    switch destination {
    case .activityDefinition(let id):
        if #available(iOS 26, macOS 26, *) { GKAccessPoint.shared.trigger(gameActivityDefinitionID: id, handler: completion) }
        else { finished() }
    case .challengeDefinition(let id):
        if #available(iOS 26, macOS 26, *) { GKAccessPoint.shared.trigger(challengeDefinitionID: id, handler: completion) }
        else { finished() }
    case .challengeOverview:
        if #available(iOS 26, macOS 26, *) { GKAccessPoint.shared.triggerForChallenges(handler: completion) }
        else { finished() }
    case .achievements: GKAccessPoint.shared.trigger(state: .achievements, handler: completion)
    case .leaderboard(let id): GKAccessPoint.shared.trigger(leaderboardID: id, playerScope: .global, timeScope: .allTime, handler: completion)
    default: GKAccessPoint.shared.trigger(state: .leaderboards, handler: completion)
    }
}

#if os(iOS)
import UIKit
@MainActor
private struct GameCenterDashboardPresentation: UIViewControllerRepresentable {
    let destination: GameCenterDestination
    let finished: @MainActor () -> Void
    let failed: @MainActor () -> Void
    func makeUIViewController(context: Context) -> DashboardHost { DashboardHost(destination: destination, finished: finished, failed: failed) }
    func updateUIViewController(_ controller: DashboardHost, context: Context) {}

    final class DashboardHost: UIViewController {
        let destination: GameCenterDestination
        let finished: @MainActor () -> Void
        let failed: @MainActor () -> Void
        var triggered = false
        init(destination: GameCenterDestination, finished: @escaping @MainActor () -> Void, failed: @escaping @MainActor () -> Void) {
            self.destination = destination; self.finished = finished; self.failed = failed
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !triggered else { return }; triggered = true
            guard let window = view.window, GKLocalPlayer.local.isAuthenticated,
                  !GKAccessPoint.shared.isPresentingGameCenter else { failed(); return }
            GKAccessPoint.shared.parentWindow = window
            triggerDashboard(destination, finished: finished)
        }
    }
}
#elseif os(macOS)
import AppKit
@MainActor
private struct GameCenterDashboardPresentation: NSViewControllerRepresentable {
    let destination: GameCenterDestination
    let finished: @MainActor () -> Void
    let failed: @MainActor () -> Void
    func makeNSViewController(context: Context) -> DashboardHost { DashboardHost(destination: destination, finished: finished, failed: failed) }
    func updateNSViewController(_ controller: DashboardHost, context: Context) {}

    final class DashboardHost: NSViewController {
        let destination: GameCenterDestination
        let finished: @MainActor () -> Void
        let failed: @MainActor () -> Void
        var triggered = false
        init(destination: GameCenterDestination, finished: @escaping @MainActor () -> Void, failed: @escaping @MainActor () -> Void) {
            self.destination = destination; self.finished = finished; self.failed = failed
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { nil }
        override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 320)) }
        override func viewDidAppear() {
            super.viewDidAppear()
            guard !triggered else { return }; triggered = true
            guard let window = view.window, GKLocalPlayer.local.isAuthenticated,
                  !GKAccessPoint.shared.isPresentingGameCenter else { failed(); return }
            GKAccessPoint.shared.parentWindow = window
            triggerDashboard(destination, finished: finished)
        }
    }
}
#endif
