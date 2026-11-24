import ECSCore
import Foundation
@preconcurrency import GameKit

/// Live Apple services or an explicitly local, account-free preview identity.
/// Preview data never reaches Game Center and is not a multiplayer server.
public enum GameCenterServicesMode: Hashable, Sendable {
    case live
    case preview(player: NetworkPeer)
}

/// Service failures expressed without exposing GameKit objects.
public enum GameCenterServiceError: Error, Equatable, Sendable, LocalizedError {
    case notAuthenticated, unavailable, invalidIdentifier, invalidValue, invalidData
    case accountChanged, cancelled, operationInProgress, notFound, notYourTurn
    case matchEnded, staleMatch, capacityExceeded
    case activityEnded, attemptUncertain
    case gameCenter(String)

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated: "Sign in to Game Center first."
        case .unavailable: "This service is not available in the current environment."
        case .invalidIdentifier: "Provide a nonempty Game Center identifier without control characters."
        case .invalidValue: "The value is outside this service's supported range."
        case .invalidData: "The saved game data is invalid or incompatible."
        case .accountChanged: "The Game Center account changed during the operation."
        case .cancelled: "The service operation was cancelled."
        case .operationInProgress: "Wait for the current operation to finish."
        case .notFound: "The requested game, achievement, or leaderboard was not found."
        case .notYourTurn: "Wait for your turn before changing this match."
        case .matchEnded: "This match has already ended."
        case .staleMatch: "The match changed. Reload it before submitting your turn."
        case .capacityExceeded: "This operation exceeds the configured data limit."
        case .activityEnded: "Start or accept a current activity before changing or finishing it."
        case .attemptUncertain: "This attempt may already have been reported. Do not retry it automatically."
        case .gameCenter(let message): message
        }
    }
}

@MainActor
final class GameCenterServiceContext {
    struct Operation {
        let player: NetworkPeer
        let generation: UInt64
    }
    let mode: GameCenterServicesMode
    private var generation: UInt64 = 0
    var isPreview: Bool { if case .preview = mode { true } else { false } }

    init(mode: GameCenterServicesMode) { self.mode = mode }

    func begin() throws -> Operation {
        try Task.checkCancellation()
        let player: NetworkPeer
        switch mode {
        case .preview(let value): player = value
        case .live:
            let native = GKLocalPlayer.local
            guard native.isAuthenticated else { throw GameCenterServiceError.notAuthenticated }
            player = NetworkPeer(id: .init(rawValue: native.gamePlayerID), displayName: native.displayName)
        }
        try validateGameCenterIdentifier(player.id.rawValue)
        return Operation(player: player, generation: generation)
    }

    func validate(_ operation: Operation) throws {
        try Task.checkCancellation()
        guard operation.generation == generation else { throw GameCenterServiceError.cancelled }
        let current = try begin()
        guard operation.player.id == current.player.id else { throw GameCenterServiceError.accountChanged }
    }

    func invalidate() { generation &+= 1 }
}

func validateGameCenterIdentifier(_ value: String) throws {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          value.utf8.count <= 256, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
        throw GameCenterServiceError.invalidIdentifier
    }
}

func gameCenterServiceFailure(_ error: any Error) -> GameCenterServiceError {
    if let error = error as? GameCenterServiceError { return error }
    if error is CancellationError { return .cancelled }
    return .gameCenter(error.localizedDescription)
}
