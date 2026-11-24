import SwiftUI
@preconcurrency import GameKit

/// Present in a SwiftUI sheet. The Sign In button starts authentication;
/// merely constructing or displaying the view never starts Game Center login.
@MainActor
public struct GameCenterAuthenticationView: View {
    private let multiplayer: GameCenterMultiplayer
    @Environment(\.dismiss) private var dismiss

    public init(multiplayer: GameCenterMultiplayer) { self.multiplayer = multiplayer }

    public var body: some View {
        ZStack {
            if let controller = multiplayer.authenticationController {
                GameCenterControllerView(controller: controller)
                    .id(ObjectIdentifier(controller))
            } else {
                VStack(spacing: 16) {
                    Text("Game Center").font(.headline)
                    switch multiplayer.authenticationState {
                    case .unauthenticated:
                        Text("Sign in to play multiplayer games.")
                        Button("Sign In") { multiplayer.authenticate() }
                    case .authenticating:
                        ProgressView("Signing in…")
                    case .authenticated:
                        Text(multiplayer.localPeer?.displayName ?? "Signed in")
                        Button("Done") { dismiss() }
                    case .failed(let message):
                        Text(message)
                        Button("Try Again") { multiplayer.authenticate() }
                    }
                    if multiplayer.authenticationState != .authenticated {
                        Button("Cancel", role: .cancel) {
                            multiplayer.cancelAuthentication()
                            dismiss()
                        }
                    }
                }
                .padding()
                .multilineTextAlignment(.center)
            }
        }
        .onDisappear { multiplayer.cancelAuthentication() }
    }
}

/// Present in a SwiftUI sheet after signing in. Find Match and Accept Invitation
/// are explicit user actions; the view never starts matchmaking on appearance.
/// Observe the coordinator's `.ready` state to dismiss the sheet and create the
/// NetworkSession. Dismissing a ready sheet leaves the transport connected.
@MainActor
public struct GameCenterMatchmakingView: View {
    private let multiplayer: GameCenterMultiplayer
    private let request: GameCenterMatchRequest
    @State private var actionError: String?
    @Environment(\.dismiss) private var dismiss

    public init(multiplayer: GameCenterMultiplayer, request: GameCenterMatchRequest = .init()) {
        self.multiplayer = multiplayer
        self.request = request
    }

    public var body: some View {
        ZStack {
            if let controller = multiplayer.matchmakingController,
               multiplayer.matchmakingState == .matchmaking {
                #if os(macOS)
                GameCenterMacMatchmakerView(controller: controller) {
                    multiplayer.matchmakingPresentationFailed(controller)
                }
                .id(ObjectIdentifier(controller))
                #else
                GameCenterControllerView(controller: controller)
                    .id(ObjectIdentifier(controller))
                #endif
            } else {
                VStack(spacing: 16) {
                    Text("Game Center Multiplayer").font(.headline)
                    if let actionError { Text(actionError) }
                    switch multiplayer.matchmakingState {
                    case .idle, .failed:
                        if case .failed(let message) = multiplayer.matchmakingState { Text(message) }
                        if multiplayer.hasPendingInvite {
                            Text("Invitation from \(multiplayer.pendingInviterName ?? "a player")")
                            Button("Accept Invitation") { perform { try multiplayer.acceptPendingInvite() } }
                            Button("Decline Invitation") { multiplayer.declinePendingInvite() }
                        }
                        Button("Find Match") { perform { try multiplayer.findMatch(request) } }
                            .disabled(multiplayer.authenticationState != .authenticated)
                        if multiplayer.authenticationState != .authenticated { Text("Sign in to Game Center first.") }
                    case .matchmaking:
                        ProgressView("Finding players…")
                    case .waitingForPlayers:
                        ProgressView("Waiting for all players to connect…")
                    case .ready:
                        Text("Match ready")
                        Button("Done") { dismiss() }
                    }
                    if multiplayer.matchmakingState != .ready {
                        Button("Cancel", role: .cancel) {
                            multiplayer.cancelMatchmaking()
                            dismiss()
                        }
                    }
                }
                .padding()
                .multilineTextAlignment(.center)
            }
        }
        .onDisappear { multiplayer.cancelMatchmaking() }
    }

    private func perform(_ action: () throws -> Void) {
        actionError = nil
        do { try action() } catch { actionError = error.localizedDescription }
    }
}

#if os(iOS)
import UIKit

private struct GameCenterControllerView: UIViewControllerRepresentable {
    let controller: UIViewController
    func makeUIViewController(context: Context) -> UIViewController { controller }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
#elseif os(macOS)
import AppKit

private struct GameCenterControllerView: NSViewControllerRepresentable {
    let controller: NSViewController
    func makeNSViewController(context: Context) -> NSViewController { controller }
    func updateNSViewController(_ nsViewController: NSViewController, context: Context) {}
}

/// GameKit requires GKDialogController to present matchmaking on macOS. The
/// hosting view supplies its own window, never an unrelated application's key
/// window, and dismisses only the dialog instance that it created.
private struct GameCenterMacMatchmakerView: NSViewControllerRepresentable {
    let controller: GKMatchmakerViewController
    let onFailure: @MainActor () -> Void

    func makeNSViewController(context: Context) -> GameCenterMacMatchmakerHost {
        GameCenterMacMatchmakerHost(controller: controller, onFailure: onFailure)
    }

    func updateNSViewController(_ nsViewController: GameCenterMacMatchmakerHost, context: Context) {}

    static func dismantleNSViewController(_ nsViewController: GameCenterMacMatchmakerHost, coordinator: ()) {
        nsViewController.dismissDialog()
    }
}

private final class GameCenterMacMatchmakerHost: NSViewController {
    private let controller: GKMatchmakerViewController
    private let onFailure: @MainActor () -> Void
    private let dialog = GKDialogController()
    private var presented = false

    init(controller: GKMatchmakerViewController, onFailure: @escaping @MainActor () -> Void) {
        self.controller = controller
        self.onFailure = onFailure
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 320))
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !presented else { return }
        dialog.parentWindow = view.window
        presented = dialog.present(controller)
        if !presented {
            // Avoid mutating observable view state during an AppKit callback.
            let onFailure = onFailure
            DispatchQueue.main.async { onFailure() }
        }
    }

    func dismissDialog() {
        guard presented else { return }
        presented = false
        dialog.dismiss(self)
    }

    override func viewWillDisappear() {
        dismissDialog()
        super.viewWillDisappear()
    }
}
#endif
