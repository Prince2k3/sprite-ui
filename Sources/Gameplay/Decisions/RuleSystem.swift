/// Facts a ``RuleSystem`` has worked out, each with a grade from 0 (false) to 1 (true).
///
/// Grades between 0 and 1 are "fuzzy": a creature can be 0.7 hungry and 0.4 scared.
/// Combine them with ``all(_:)`` (fuzzy AND) and ``any(_:)`` (fuzzy OR).
public struct Facts<Fact: Hashable & Sendable>: Sendable {
    private var grades: [Fact: Double] = [:]
    /// Facts in the order they were first asserted, so ties break the same way every time.
    private var order: [Fact] = []

    public init() {}

    /// The grade of `fact`, or 0 if it hasn't been asserted.
    public subscript(fact: Fact) -> Double {
        grades[fact] ?? 0
    }

    /// Raises `fact`'s grade by `grade`, up to 1.
    public mutating func assert(_ fact: Fact, grade: Double = 1) {
        guard grade > 0 else { return }
        if grades[fact] == nil { order.append(fact) }
        grades[fact] = min((grades[fact] ?? 0) + grade, 1)
    }

    /// Lowers `fact`'s grade by `grade`, removing it at 0.
    public mutating func retract(_ fact: Fact, grade: Double = 1) {
        guard let current = grades[fact], grade > 0 else { return }
        let lowered = current - grade
        if lowered <= 0 {
            grades[fact] = nil
            order.removeAll { $0 == fact }
        } else {
            grades[fact] = lowered
        }
    }

    /// The lowest grade among `facts`: how true they all are together.
    public func all(_ facts: Fact...) -> Double {
        facts.map { self[$0] }.min() ?? 0
    }

    /// The highest grade among `facts`: how true at least one of them is.
    public func any(_ facts: Fact...) -> Double {
        facts.map { self[$0] }.max() ?? 0
    }

    /// Asserted facts and their grades, in the order they were first asserted.
    public var asserted: [(fact: Fact, grade: Double)] {
        order.map { ($0, grades[$0]!) }
    }

    /// The fact with the highest grade, or `nil` if none is asserted.
    /// Ties go to the fact asserted first.
    public var strongest: Fact? {
        var best: Fact?
        for fact in order where best == nil || grades[fact]! > grades[best!]! { best = fact }
        return best
    }
}

extension Facts: Equatable {
    /// Equal when every fact has the same grade, whatever order they were asserted in.
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.grades == rhs.grades }
}

extension Facts: Hashable {
    public func hash(into hasher: inout Hasher) { hasher.combine(grades) }
}

/// One rule in a ``RuleSystem``: when its condition holds, its action changes the facts.
///
/// ```swift
/// Rule(when: { critter, _ in critter.food < 0.3 }, assert: .hungry)
/// Rule(assert: .scared, gradedBy: { critter, _ in 1 - critter.playerDistance / 150 })
/// Rule(salience: -1, when: { _, facts in facts[.scared] > 0.5 }, retract: .hungry, grade: 0.5)
/// ```
public struct Rule<State, Fact: Hashable & Sendable>: Sendable {
    /// Rules with higher salience are tried first. Equal ones go in list order.
    public var salience: Int
    public let condition: @Sendable (State, Facts<Fact>) -> Bool
    public let action: @Sendable (State, inout Facts<Fact>) -> Void

    /// Runs `then` when `when` is true.
    public init(
        salience: Int = 0,
        when condition: @escaping @Sendable (State, Facts<Fact>) -> Bool,
        then action: @escaping @Sendable (State, inout Facts<Fact>) -> Void
    ) {
        self.salience = salience
        self.condition = condition
        self.action = action
    }

    /// Asserts `fact` with `grade` when `when` is true.
    public init(
        salience: Int = 0,
        when condition: @escaping @Sendable (State, Facts<Fact>) -> Bool,
        assert fact: Fact,
        grade: Double = 1
    ) {
        self.init(salience: salience, when: condition) { _, facts in facts.assert(fact, grade: grade) }
    }

    /// Retracts `grade` of `fact` when `when` is true.
    public init(
        salience: Int = 0,
        when condition: @escaping @Sendable (State, Facts<Fact>) -> Bool,
        retract fact: Fact,
        grade: Double = 1
    ) {
        self.init(salience: salience, when: condition) { _, facts in facts.retract(fact, grade: grade) }
    }

    /// Always asserts `fact` with a grade worked out from the state, clamped to 0...1.
    /// A grade of 0 or less asserts nothing.
    public init(
        salience: Int = 0,
        assert fact: Fact,
        gradedBy grade: @escaping @Sendable (State, Facts<Fact>) -> Double
    ) {
        self.init(salience: salience, when: { _, _ in true }) { state, facts in
            facts.assert(fact, grade: min(max(grade(state, facts), 0), 1))
        }
    }
}

/// Works out facts from a state by running rules.
///
/// Instead of a dictionary of state, rules read your own typed `State`, and facts
/// are your own `Fact` type, usually an enum:
///
/// ```swift
/// enum Mood { case hungry, scared, tired }
///
/// let brain = RuleSystem<Critter, Mood>(
///     Rule(assert: .hungry, gradedBy: { critter, _ in 1 - critter.food }),
///     Rule(assert: .scared, gradedBy: { critter, _ in 1 - critter.playerDistance / 150 }),
///     Rule(when: { _, facts in facts[.scared] > 0.6 }, retract: .hungry)
/// )
/// let mood = brain.evaluate(critter).strongest
/// ```
///
/// ``evaluate(_:startingWith:)`` tries rules from highest salience down and fires
/// the first whose condition holds. Then it starts again from the top, since the
/// facts changed, until no unfired rule's condition holds. Each rule fires at most
/// once per evaluation, so rules that feed each other can't loop forever.
///
/// The system keeps no state between evaluations: it's a pure function from
/// state to facts, safe to share and to call from any system.
public struct RuleSystem<State, Fact: Hashable & Sendable>: Sendable {
    /// The rules, kept in order of salience (highest first, then list order).
    public private(set) var rules: [Rule<State, Fact>]

    public init(_ rules: [Rule<State, Fact>]) {
        self.rules = Self.ordered(rules)
    }

    public init(_ rules: Rule<State, Fact>...) {
        self.init(rules)
    }

    public mutating func add(_ rule: Rule<State, Fact>) {
        rules = Self.ordered(rules + [rule])
    }

    /// Runs the rules against `state` and returns the facts they produce.
    public func evaluate(_ state: State, startingWith facts: Facts<Fact> = Facts()) -> Facts<Fact> {
        var facts = facts
        var fired = [Bool](repeating: false, count: rules.count)
        var searching = true
        while searching {
            searching = false
            for (index, rule) in rules.enumerated() where !fired[index] && rule.condition(state, facts) {
                fired[index] = true
                rule.action(state, &facts)
                searching = true
                break
            }
        }
        return facts
    }

    private static func ordered(_ rules: [Rule<State, Fact>]) -> [Rule<State, Fact>] {
        rules.enumerated()
            .sorted { $0.element.salience != $1.element.salience ? $0.element.salience > $1.element.salience : $0.offset < $1.offset }
            .map(\.element)
    }
}
