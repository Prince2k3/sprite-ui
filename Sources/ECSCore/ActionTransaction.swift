/// The context a component change was made in. Backends read it to decide how to animate.
@MainActor
public final class ActionTransaction {
    public let animation: ActionAnimation?
    private let completion: (() -> Void)?

    private var pending = 0
    private var sealed = false
    private var finished = false

    static var stack: [ActionTransaction] = []
    static var awaitingSeal: [ActionTransaction] = []

    /// The innermost active `withAnimation` call, if any.
    public static var current: ActionTransaction? { stack.last }

    init(animation: ActionAnimation?, completion: (() -> Void)?) {
        self.animation = animation
        self.completion = completion
    }

    /// Runs `body` with a new transaction on top of the stack.
    public static func perform<Result>(
        _ animation: ActionAnimation?,
        completion: (() -> Void)?,
        _ body: () throws -> Result
    ) rethrows -> Result {
        let transaction = ActionTransaction(animation: animation, completion: completion)
        stack.append(transaction)
        defer {
            stack.removeLast()
            if completion != nil { awaitingSeal.append(transaction) }
        }
        return try body()
    }

    /// The animation to use, or `nil` to set values directly.
    public var effectiveAnimation: ActionAnimation? {
        guard let animation, animation.duration > 0 || animation.delay > 0 else { return nil }
        return animation
    }

    // MARK: Backend bookkeeping

    /// Whether another completion-sealing pass is needed. A completion may enqueue
    /// another transaction without changing a component immediately.
    @_spi(Backend)
    public static var hasPendingSeals: Bool { !awaitingSeal.isEmpty }

    /// A backend started a finite action on behalf of this transaction.
    @_spi(Backend)
    public func beginAction() {
        pending += 1
    }

    /// An action started with ``beginAction()`` finished, was replaced, or was dropped.
    @_spi(Backend)
    public func endAction() {
        pending -= 1
        fireIfDone()
    }

    /// Cancels the completion when a backend discards an entity's old lifetime
    /// (for example, pool release). Other actions in the transaction may finish,
    /// but its completion must not mutate a reused entity.
    @_spi(Backend)
    public func cancelCompletion() { finished = true }

    /// Called by a backend once it has turned all pending changes into actions.
    /// Transactions that started nothing complete now.
    @_spi(Backend)
    public static func sealPending() {
        guard !awaitingSeal.isEmpty else { return }
        let ready = awaitingSeal
        awaitingSeal.removeAll()
        for transaction in ready {
            transaction.sealed = true
            transaction.fireIfDone()
        }
    }

    private func fireIfDone() {
        guard sealed, pending <= 0, !finished else { return }
        // Animations that repeat forever never finish, so their completion never runs.
        if let animation = effectiveAnimation, !animation.isFinite { return }
        finished = true
        completion?()
    }
}
