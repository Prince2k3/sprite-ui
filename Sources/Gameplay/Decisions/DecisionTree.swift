/// An answer to one of a ``DecisionTree``'s questions: a flag, a number or a word.
///
/// Write answers as literals: `true`, `42`, `0.5` or `"night"`.
public enum DecisionValue: Hashable, Codable, Sendable {
    case bool(Bool)
    case number(Double)
    case text(String)

    /// The value as a number, or `nil` for flags and text.
    public var number: Double? {
        if case .number(let value) = self { value } else { nil }
    }
}

extension DecisionValue: ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral
{
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .text(value) }
}

extension DecisionValue: CustomStringConvertible {
    public var description: String {
        switch self {
        case .bool(let value): "\(value)"
        case .number(let value): formatNumber(value)
        case .text(let value): "\"\(value)\""
        }
    }
}

/// What the world looks like right now, keyed by question, for ``DecisionTree/decide(_:)``.
///
/// ```swift
/// let answers: DecisionAnswers = ["canSeePlayer": true, "distance": 42, "health": 0.3]
/// ```
public typealias DecisionAnswers = [String: DecisionValue]

/// Which answers a branch of a ``DecisionTree`` question accepts.
///
/// A literal matches that exact answer: `.when(true, ...)`, `.when("night", ...)`.
public enum DecisionCondition: Hashable, Codable, Sendable {
    /// Exactly this answer.
    case equals(DecisionValue)
    /// Any of these answers.
    case oneOf(Set<DecisionValue>)
    /// A number from `lower` (included) up to `upper` (not included).
    /// A `nil` bound is unbounded.
    case range(lower: Double?, upper: Double?)

    /// A number less than `limit`.
    public static func below(_ limit: Double) -> Self { .range(lower: nil, upper: limit) }
    /// A number of at least `limit`.
    public static func atLeast(_ limit: Double) -> Self { .range(lower: limit, upper: nil) }
    /// A number in `range`.
    public static func within(_ range: Range<Double>) -> Self {
        .range(lower: range.lowerBound, upper: range.upperBound)
    }

    /// Whether `answer` takes this branch.
    public func matches(_ answer: DecisionValue) -> Bool {
        switch self {
        case .equals(let value):
            return answer == value
        case .oneOf(let values):
            return values.contains(answer)
        case .range(let lower, let upper):
            guard let number = answer.number else { return false }
            if let lower, number < lower { return false }
            if let upper, number >= upper { return false }
            return true
        }
    }
}

extension DecisionCondition: ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral
{
    public init(booleanLiteral value: Bool) { self = .equals(.bool(value)) }
    public init(integerLiteral value: Int) { self = .equals(.number(Double(value))) }
    public init(floatLiteral value: Double) { self = .equals(.number(value)) }
    public init(stringLiteral value: String) { self = .equals(.text(value)) }
}

extension DecisionCondition: CustomStringConvertible {
    public var description: String {
        switch self {
        case .equals(let value):
            return value.description
        case .oneOf(let values):
            return values.map(\.description).sorted().joined(separator: " or ")
        case .range(let lower?, let upper?):
            return "\(formatNumber(lower)) ..< \(formatNumber(upper))"
        case .range(let lower?, nil):
            return "≥ \(formatNumber(lower))"
        case .range(nil, let upper?):
            return "< \(formatNumber(upper))"
        case .range(nil, nil):
            return "any number"
        }
    }
}

/// One step of a ``DecisionTree``: an action, a question, or a random pick.
///
/// Build trees with ``action(_:)``, ``ask(_:_:otherwise:)`` and ``random(_:)``:
///
/// ```swift
/// let guardTree = DecisionTree<Move>(
///     .ask("canSeePlayer",
///         .when(true, .ask("distance",
///             .when(.below(60), .action(.attack)),
///             otherwise: .action(.chase))),
///         otherwise: .random([(3, .action(.patrol)), (1, .action(.rest))]))
/// )
/// ```
public indirect enum DecisionNode<Action: Hashable & Sendable>: Hashable, Sendable {
    /// The decision: do this.
    case action(Action)
    /// Look up `attribute` in the answers and take the first branch that matches
    /// it, or `otherwise` when none does or the answer is missing.
    case question(attribute: String, branches: [DecisionBranch<Action>], otherwise: DecisionNode<Action>?)
    /// Pick one choice at random, in proportion to its weight.
    case weighted([WeightedChoice])

    /// A choice in a ``weighted(_:)`` node.
    public struct WeightedChoice: Hashable, Sendable {
        public var weight: Double
        public var node: DecisionNode<Action>

        public init(weight: Double, node: DecisionNode<Action>) {
            self.weight = weight
            self.node = node
        }
    }

    /// Asks about `attribute`, taking the first branch whose condition matches.
    public static func ask(
        _ attribute: String,
        _ branches: DecisionBranch<Action>...,
        otherwise: DecisionNode<Action>? = nil
    ) -> Self {
        .question(attribute: attribute, branches: branches, otherwise: otherwise)
    }

    /// Picks one node at random, in proportion to its weight, like
    /// `GKDecisionNode.createBranch(weight:attribute:)`.
    public static func random(_ choices: [(Double, DecisionNode<Action>)]) -> Self {
        .weighted(choices.map { WeightedChoice(weight: $0.0, node: $0.1) })
    }
}

/// A branch of a question: the node to visit when the answer matches `condition`.
public struct DecisionBranch<Action: Hashable & Sendable>: Hashable, Sendable {
    public var condition: DecisionCondition
    public var node: DecisionNode<Action>

    public init(_ condition: DecisionCondition, _ node: DecisionNode<Action>) {
        self.condition = condition
        self.node = node
    }

    /// Visit `node` when the answer matches `condition`.
    public static func when(_ condition: DecisionCondition, _ node: DecisionNode<Action>) -> Self {
        Self(condition, node)
    }
}

extension DecisionNode: Codable where Action: Codable {}
extension DecisionNode.WeightedChoice: Codable where Action: Codable {}
extension DecisionBranch: Codable where Action: Codable {}

/// Picks an action by asking questions about the world, in place of `GKDecisionTree`.
///
/// Build one by hand from ``DecisionNode``s, or learn one from examples with
/// ``init(learningFrom:actions:maxDepth:)``. Then ask it what to do:
///
/// ```swift
/// let move = guardTree.decide(["canSeePlayer": true, "distance": 42], using: &rng)
/// ```
///
/// Trees are plain values. When `Action` is `Codable`, so is the tree, so you
/// can tune one in a file or ship a learned one with the game.
public struct DecisionTree<Action: Hashable & Sendable>: Hashable, Sendable {
    public var root: DecisionNode<Action>

    public init(_ root: DecisionNode<Action>) {
        self.root = root
    }

    /// The action for `answers`, or `nil` if a question has no matching branch
    /// and no `otherwise`. Random nodes draw from `generator`.
    public func decide(_ answers: DecisionAnswers, using generator: inout some RandomNumberGenerator) -> Action? {
        var node = root
        while true {
            switch node {
            case .action(let action):
                return action
            case .question(let attribute, let branches, let otherwise):
                let answer = answers[attribute]
                if let answer, let branch = branches.first(where: { $0.condition.matches(answer) }) {
                    node = branch.node
                } else if let otherwise {
                    node = otherwise
                } else {
                    return nil
                }
            case .weighted(let choices):
                guard let next = Self.pick(choices, using: &generator) else { return nil }
                node = next
            }
        }
    }

    /// The action for `answers`, drawing any random picks from the system generator.
    public func decide(_ answers: DecisionAnswers) -> Action? {
        var generator = SystemRandomNumberGenerator()
        return decide(answers, using: &generator)
    }

    /// Every action the tree can reach.
    public var actions: [Action] {
        var found: [Action] = []
        var seen = Set<Action>()
        func visit(_ node: DecisionNode<Action>) {
            switch node {
            case .action(let action):
                if seen.insert(action).inserted { found.append(action) }
            case .question(_, let branches, let otherwise):
                branches.forEach { visit($0.node) }
                if let otherwise { visit(otherwise) }
            case .weighted(let choices):
                choices.forEach { visit($0.node) }
            }
        }
        visit(root)
        return found
    }

    private static func pick(
        _ choices: [DecisionNode<Action>.WeightedChoice],
        using generator: inout some RandomNumberGenerator
    ) -> DecisionNode<Action>? {
        let total = choices.reduce(0) { $0 + max($1.weight, 0) }
        guard total > 0 else { return choices.first?.node }
        var roll = generator.nextUnit() * total
        for choice in choices where choice.weight > 0 {
            roll -= choice.weight
            if roll < 0 { return choice.node }
        }
        return choices.last { $0.weight > 0 }?.node
    }
}

extension DecisionTree: Codable where Action: Codable {}

extension DecisionTree: CustomStringConvertible {
    /// The tree drawn as indented text, one branch per line:
    ///
    /// ```
    /// canSeePlayer?
    /// ├─ true → distance?
    /// │  ├─ < 60 → attack
    /// │  └─ otherwise → chase
    /// └─ otherwise → random
    ///    ├─ 75% → patrol
    ///    └─ 25% → rest
    /// ```
    public var description: String {
        var lines: [String] = []
        Self.describe(root, label: nil, prefix: "", childPrefix: "", into: &lines)
        return lines.joined(separator: "\n")
    }

    private static func describe(
        _ node: DecisionNode<Action>,
        label: String?,
        prefix: String,
        childPrefix: String,
        into lines: inout [String]
    ) {
        let lead = prefix + (label.map { "\($0) → " } ?? "")
        switch node {
        case .action(let action):
            lines.append(lead + "\(action)")
        case .question(let attribute, let branches, let otherwise):
            lines.append(lead + "\(attribute)?")
            var children = branches.map { ($0.condition.description, $0.node) }
            if let otherwise { children.append(("otherwise", otherwise)) }
            describeChildren(children, childPrefix: childPrefix, into: &lines)
        case .weighted(let choices):
            lines.append(lead + "random")
            let total = choices.reduce(0) { $0 + max($1.weight, 0) }
            let children = choices.map { choice in
                let share = total > 0 ? max(choice.weight, 0) / total * 100 : 0
                return ("\(formatNumber((share * 10).rounded() / 10))%", choice.node)
            }
            describeChildren(children, childPrefix: childPrefix, into: &lines)
        }
    }

    private static func describeChildren(
        _ children: [(String, DecisionNode<Action>)],
        childPrefix: String,
        into lines: inout [String]
    ) {
        for (index, (label, child)) in children.enumerated() {
            let isLast = index == children.count - 1
            describe(
                child,
                label: label,
                prefix: childPrefix + (isLast ? "└─ " : "├─ "),
                childPrefix: childPrefix + (isLast ? "   " : "│  "),
                into: &lines
            )
        }
    }
}

/// Whole numbers without ".0", others with up to three decimals.
func formatNumber(_ value: Double) -> String {
    if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
    let rounded = (value * 1000).rounded() / 1000
    return "\(rounded)"
}
