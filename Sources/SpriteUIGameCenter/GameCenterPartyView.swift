import Foundation
import SwiftUI

/// Optional lobby controls. The game prepares a world through services.party before marking ready.
/// Place under one stable gameCenter host; switching from this view to gameplay does not leave the party.
@MainActor public struct GameCenterPartyView: View {
    private let services: GameCenterServices
    @State private var task: Task<Void, Never>?
    @State private var operation: UUID?
    @State private var message: String?
    /// Creates a stopped menu; appearance never authenticates, matches, readies, or starts gameplay.
    public init(services: GameCenterServices) { self.services = services }
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Activity party").font(.title2.bold())
            Text("Party: \(services.party.state.rawValue)")
            if let code = services.party.activity?.partyCode { Text("Party code: \(code)").monospaced() }
            if services.party.state == .idle || services.party.state == .failed || services.party.state == .interrupted {
                Button(services.party.interruption == nil ? "Match current activity" : "Rejoin activity") {
                    guard operation == nil else { return }
                    let id = UUID(); operation = id
                    task = Task { @MainActor in
                        defer { if operation == id { operation = nil; task = nil } }
                        do { try await services.party.findMatch(); if !Task.isCancelled { message = nil } }
                        catch { if !Task.isCancelled { message = error.localizedDescription } }
                    }
                }.disabled(operation != nil)
            }
            if let interruption = services.party.interruption { Text("Interrupted: \(interruption.reason.rawValue). Retry explicitly or return to your menu.").font(.footnote) }
            if services.party.state == .interrupted || services.party.state == .failed { Button("Return to game menu") { services.party.leave() } }
            if let offer = services.party.recoveryOffer { Text("Recovery checkpoint: \(offer.id.uuidString.prefix(8)) · sequence \(offer.sequence)").font(.caption) }
            ForEach(services.party.members) { member in
                HStack {
                    Text(member.peer.displayName)
                    if member.id == services.party.hostPeerID { Text("Host").font(.caption) }
                    Spacer()
                    Text(member.isReady ? "Ready" : "Preparing")
                }
            }
            if services.party.state == .lobby {
                let ready = services.party.members.first(where: { $0.id == services.localPlayer?.id })?.isReady ?? false
                Button(ready ? "Not ready" : "Ready for prepared world") { apply { try services.party.setReady(!ready) } }
                Button("Start prepared game") { apply { try services.party.startSession() } }.disabled(!services.party.canStart)
            }
            if services.party.isActive { Button("Leave party") { services.party.leave() } }
            if let error = services.party.lastError { Text(error.localizedDescription).font(.footnote).foregroundStyle(.red) }
            if let message { Text(message).font(.footnote) }
        }
        .onDisappear { operation = nil; task?.cancel(); task = nil }
    }
    private func apply(_ action: () throws -> Void) {
        do { try action(); message = nil } catch { message = error.localizedDescription }
    }
}
