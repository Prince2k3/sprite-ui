import Foundation

/// Failures in local quest and league rules. No operation partially applies on failure.
public enum ProgressionError: Error, Equatable, Sendable {
    case invalidDefinition, invalidValue, invalidSave, capacityExceeded
    case unknownQuest, notAvailable, notComplete, alreadyClaimed
    case unknownParticipant, seasonClosed, seasonNotEnded
}

/// A half-open interval, including its start and excluding its end.
public struct ProgressionWindow: Hashable, Codable, Sendable {
    /// The first eligible instant.
    public let start: Date
    /// The first ineligible instant.
    public let end: Date

    /// Creates a finite, nonempty time window.
    public init(start: Date, end: Date) throws {
        guard start.timeIntervalSinceReferenceDate.isFinite,
              end.timeIntervalSinceReferenceDate.isFinite, start < end else {
            throw ProgressionError.invalidDefinition
        }
        self.start = start; self.end = end
    }

    /// Returns whether the supplied instant belongs to this interval.
    public func contains(_ date: Date) -> Bool { start <= date && date < end }

    private enum CodingKeys: String, CodingKey { case start, end }
    /// Decodes and validates the time window.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(start: c.decode(Date.self, forKey: .start), end: c.decode(Date.self, forKey: .end))
    }
}

func validateProgressionID(_ value: String) throws {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          value.utf8.count <= 256,
          !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
        throw ProgressionError.invalidDefinition
    }
}
