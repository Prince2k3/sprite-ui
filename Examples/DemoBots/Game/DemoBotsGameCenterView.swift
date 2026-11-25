import SpriteUI
import SwiftUI

/// An explicit test bench for preview services and Xcode-local/native GameKit calls.
@MainActor public struct DemoBotsGameCenterView: View {
    @State private var lab: DemoBotsGameCenterLab
    @State private var native: Bool
    @Environment(\.dismiss) private var dismiss
    /// Selects the service backend only. No sign-in, loads, or reports happen until a button is pressed.
    public init(useNativeServices: Bool = false) {
        _native = State(initialValue: useNativeServices)
        _lab = State(initialValue: DemoBotsGameCenterLab(native: useNativeServices))
    }
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("GAME CENTER TEST LAB").font(.caption.bold()).foregroundStyle(.mint); Spacer(); Button("Close") { lab.close(); dismiss() } }
                Text("Test progress. Keep the campaign separate.").font(.title2.bold())
                Toggle("Use native GameKit", isOn: $native).disabled(lab.busy)
                Text(native ? "Calls reach GameKit. Use the Local Game Center scheme for isolated Xcode testing; a normal scheme uses configured Apple services." : "Offline preview. No Apple account or network connection is required.").font(.footnote).foregroundStyle(.secondary)
                if native {
                    Text("In Xcode: Run → Options → GameKit Configuration → Enable Debug Mode. Then Debug → GameKit → Manage Game Progress on a supported physical device. Simulator previews do not verify this path.").font(.caption)
                    Text(lab.services.localPlayer?.displayName ?? "Not signed in")
                    Button("Sign in to Game Center") { lab.services.present(.signIn) }.disabled(lab.busy)
                }
                Text(lab.message).font(.callout).accessibilityIdentifier("game-center-lab-status")
                Button("Load test data") { lab.load() }.disabled(!lab.canReport)
                GroupBox("Achievement · First Repair") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Progress: \(Int(lab.progress))%").accessibilityIdentifier("game-center-lab-progress")
                        HStack { Button("Report 25%") { lab.reportProgress(25) }; Button("Unlock test achievement") { lab.reportProgress(100) } }
                        Button("Show achievements") { lab.services.present(.achievements) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.disabled(!lab.canReport)
                GroupBox("Leaderboard · Repair Score") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Best loaded score: \(lab.services.leaderboards.lastResults?.localPlayerEntry?.score.description ?? "—")").accessibilityIdentifier("game-center-lab-score")
                        HStack { Button("Submit 100 points") { lab.submitScore(100) }; Button("Submit 50 points") { lab.submitScore(50) } }
                        Button("Show test leaderboard") { lab.services.present(.leaderboard(DemoBotsGameCenterIDs.leaderboard)) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.disabled(!lab.canReport)
                GroupBox("Activity · Repair Test") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Activity: \(lab.services.activities.activity?.state.rawValue ?? "none") · accepted entries: \(lab.acceptedEntryPoints)").accessibilityIdentifier("game-center-lab-activity")
                        Button("Start test activity") { lab.startActivity() }
                        HStack { Button("Finish test activity") { lab.finishActivity() }; Button("Discard test activity") { lab.discardActivity() } }
                        if !native { Button("Simulate activity entry") { lab.simulateEntryPoint() } }
                        ForEach(lab.services.activities.pendingRequests) { request in
                            Button("Enter queued Repair Test") { lab.acceptEntryPoint(request.id) }
                        }
                        Text("Native incoming Repair Test activities appear here after authentication. Co-op has its own entry in Co-op Debug Arena.").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.disabled(!lab.canReport || !lab.supportsActivities)
                GroupBox("Challenge · Repair Challenge") {
                    VStack(alignment: .leading, spacing: 10) {
                        Button("Submit new test attempt") { lab.submitChallengeAttempt() }
                        Button("Show test challenge") { lab.services.present(.challengeDefinition(DemoBotsGameCenterIDs.challenge)) }
                        Text("Each attempt submits 100 points to Repair Score. Native activities/challenges need OS 26+. No test action reports campaign progress.").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.disabled(!lab.canReport || !lab.supportsActivities)
                if let error = lab.services.lastError { Text(error.localizedDescription).foregroundStyle(.orange) }
            }.buttonStyle(.bordered).tint(.mint).padding().frame(maxWidth: 740, alignment: .leading).frame(maxWidth: .infinity)
        }.background(Color.black).preferredColorScheme(.dark)
            .gameCenter(lab.services)
            .onChange(of: native) { _, value in lab.close(); lab = DemoBotsGameCenterLab(native: value) }
            .onDisappear { lab.close() }
    }
}
