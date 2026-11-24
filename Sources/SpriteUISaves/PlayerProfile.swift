import Foundation
import Gameplay

/// Persistence failures that do not silently replace or discard existing saves.
public enum ProfileSaveError: Error, Equatable, Sendable, LocalizedError {
    case invalidIdentifier, invalidValue, corruptData, identityMismatch, unsupportedVersion(Int)
    case slotExists, slotNotFound, staleRevision, capacityExceeded, unavailableBackup
    case directoryClosed, readOnly, cloudUnavailable, operationInProgress, unknownConflict
    case cloudFailure(String)

    /// A user-facing description suitable for presenting a failed save operation.
    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier: "Provide a nonempty profile, provider, or slot identifier without control characters."
        case .invalidValue: "The save operation contains an invalid value or insufficient currency."
        case .corruptData: "The saved data is damaged or incompatible. It has not been replaced."
        case .identityMismatch: "This profile belongs to a different player, slot, or schema."
        case .unsupportedVersion(let version): "Save version \(version) requires a compatible application or migration."
        case .slotExists: "This save slot already exists. Load it before making changes."
        case .slotNotFound: "No save exists in this slot."
        case .staleRevision: "A newer save exists. Reload before changing it."
        case .capacityExceeded: "The profile exceeds its configured save capacity."
        case .unavailableBackup: "No previous committed save is available."
        case .directoryClosed: "The cloud directory is closed or its account changed. Open it again."
        case .readOnly: "A conflicting save can be inspected but cannot be changed."
        case .cloudUnavailable: "GameSave requires iOS 26 or macOS 26. Local profiles remain available."
        case .operationInProgress: "Wait for the current cloud operation to finish."
        case .unknownConflict: "This conflict choice is no longer available. Refresh the choices."
        case .cloudFailure(let message): message
        }
    }
}

/// An application-owned identity namespace. No authentication or guest/account merging occurs automatically.
public enum PlayerProfileID: Hashable, Codable, Sendable {
    /// A stable guest ID retained by the application.
    case guest(String)
    /// A provider-scoped account ID, such as a Game Center game-player ID.
    case account(provider: String, id: String)

    /// The gameplay owner ID, used by a quest journal. Storage also includes the provider namespace.
    public var subject: String { switch self { case .guest(let id), .account(_, let id): id } }

    func validate() throws {
        try validateSaveID(subject)
        if case .account(let provider, _) = self { try validateSaveID(provider) }
    }
}

/// An application-chosen save slot identifier, hashed before it becomes a filesystem name.
public struct SaveSlotID: Hashable, Codable, Sendable, RawRepresentable {
    /// The stable slot identifier, such as `campaign` or `autosave`.
    public let rawValue: String
    /// Creates a validated slot ID.
    public init(_ value: String) throws { try validateSaveID(value); rawValue = value }
    /// Creates an ID if the raw value is valid.
    public init?(rawValue: String) {
        guard (try? validateSaveID(rawValue)) != nil else { return nil }
        self.rawValue = rawValue
    }
    /// Decodes and validates a slot identifier.
    public init(from decoder: any Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }
    /// Encodes the raw identifier.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(rawValue)
    }
}

/// A profile's locally granted balances and retained claim keys. It is not a server wallet.
public struct ProfileWallet: Equatable, Codable, Sendable {
    /// Balances keyed by application reward identifier.
    public private(set) var balances: [String: Int] = [:]
    /// Claim receipt keys already granted to this wallet.
    public private(set) var appliedClaimIDs: Set<String> = []
    /// Returns a currency's balance, or zero if absent.
    public func balance(for identifier: String) -> Int { balances[identifier] ?? 0 }

    mutating func apply(_ claim: QuestRewardClaim) throws {
        guard !appliedClaimIDs.contains(claim.id) else { return }
        guard appliedClaimIDs.count < 100_000 else { throw ProfileSaveError.capacityExceeded }
        var candidate = balances
        for reward in claim.rewards {
            let (total, overflow) = (candidate[reward.identifier] ?? 0).addingReportingOverflow(reward.amount)
            guard !overflow else { throw ProfileSaveError.invalidValue }
            candidate[reward.identifier] = total
        }
        balances = candidate; appliedClaimIDs.insert(claim.id)
    }

    mutating func spend(_ amount: Int, currency: String) throws {
        try validateSaveID(currency)
        guard amount > 0, amount <= balance(for: currency) else { throw ProfileSaveError.invalidValue }
        balances[currency] = balance(for: currency) - amount
    }

    private enum CodingKeys: String, CodingKey { case balances, appliedClaimIDs }
    init() {}
    /// Decodes and validates balances and claim-key limits.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        balances = try c.decode([String: Int].self, forKey: .balances)
        let ids = try c.decode([String].self, forKey: .appliedClaimIDs)
        guard ids.count <= 100_000, Set(ids).count == ids.count, balances.values.allSatisfy({ $0 >= 0 }) else {
            throw ProfileSaveError.corruptData
        }
        for id in balances.keys { try validateSaveID(id) }
        appliedClaimIDs = Set(ids)
    }
    /// Encodes claim keys in stable order.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(balances, forKey: .balances); try c.encode(appliedClaimIDs.sorted(), forKey: .appliedClaimIDs)
    }
}

/// One typed player/slot revision, committed by `PlayerProfileStore`.
/// The application state must use value semantics for rollback-safe transaction closures.
public struct PlayerProfile<State: Codable & Sendable>: Sendable {
    /// The immutable storage owner.
    public let player: PlayerProfileID
    /// The immutable save slot.
    public let slot: SaveSlotID
    /// The application's payload schema version after migration.
    public let schemaVersion: Int
    /// The current persisted revision; saving uses it as a compare-and-swap precondition.
    public internal(set) var revision: UUID
    /// The previous revision from which this one was committed.
    public internal(set) var parentRevision: UUID?
    /// The explicit time supplied for the last commit.
    public internal(set) var savedAt: Date
    /// The game's typed state.
    public var state: State
    /// Wallet changes are made through profile transaction methods.
    public private(set) var wallet: ProfileWallet

    init(player: PlayerProfileID, slot: SaveSlotID, schemaVersion: Int, revision: UUID = UUID(),
         parentRevision: UUID? = nil, savedAt: Date, state: State, wallet: ProfileWallet = .init()) {
        self.player = player; self.slot = slot; self.schemaVersion = schemaVersion
        self.revision = revision; self.parentRevision = parentRevision; self.savedAt = savedAt
        self.state = state; self.wallet = wallet
    }

    /// Claims a quest and applies its rewards to the wallet as one candidate change.
    /// Call within `PlayerProfileStore.update` to persist both in one atomic slot replacement.
    /// Restoring older saves or selecting a cloud conflict is not a distributed anti-duplication guarantee.
    @discardableResult
    public mutating func claimQuestReward(_ id: String, in journalPath: WritableKeyPath<State, QuestJournal>, at date: Date) throws -> QuestRewardClaim {
        var journal = state[keyPath: journalPath]
        guard journal.playerID == player.subject else { throw ProfileSaveError.identityMismatch }
        let claim = try journal.claim(id, at: date)
        var candidate = wallet
        try candidate.apply(claim)
        state[keyPath: journalPath] = journal; wallet = candidate
        return claim
    }

    /// Spends positive currency units in the candidate profile, failing without overdrawing.
    public mutating func spend(_ amount: Int, currency: String) throws { try wallet.spend(amount, currency: currency) }
}

extension PlayerProfile: Equatable where State: Equatable {}

/// A typed payload schema with explicit, sequential, raw-JSON migration steps.
public struct ProfileSaveSchema<State: Codable & Sendable>: Sendable {
    /// The version written by this game build.
    public let version: Int
    private let migrations: [Int: @Sendable (Data) throws -> Data]
    /// Creates a schema. Step `n` transforms version n's JSON payload into version n+1.
    /// Future schemas and missing steps fail without modifying the original file.
    public init(version: Int = 1, migrations: [Int: @Sendable (Data) throws -> Data] = [:]) throws {
        guard (1...1_000).contains(version), migrations.keys.allSatisfy({ $0 > 0 && $0 < version }) else {
            throw ProfileSaveError.invalidValue
        }
        self.version = version; self.migrations = migrations
    }
    func decode(_ data: Data, version savedVersion: Int, maximumBytes: Int) throws -> State {
        guard savedVersion > 0, savedVersion <= version else { throw ProfileSaveError.unsupportedVersion(savedVersion) }
        var payload = data
        for step in savedVersion..<version {
            guard let migrate = migrations[step] else { throw ProfileSaveError.unsupportedVersion(step) }
            payload = try migrate(payload)
            guard payload.count <= maximumBytes else { throw ProfileSaveError.capacityExceeded }
        }
        return try JSONDecoder().decode(State.self, from: payload)
    }
}

func validateSaveID(_ value: String) throws {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= 256,
          !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
        throw ProfileSaveError.invalidIdentifier
    }
}
