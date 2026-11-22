/// Component values as currently shown on screen.
///
/// Inside `withAnimation`, `entity.components` holds targets immediately, while the
/// renderer moves toward them over time. `entity.presentation` reads what's on screen
/// right now. It matches the model value when nothing is animating or no renderer is attached.
///
/// ```swift
/// withAnimation(.linear(duration: 1)) { ball.position = [100, 0] }
/// ball.position               // [100, 0]
/// ball.presentation.position  // somewhere between the start and [100, 0]
/// ```
@MainActor
public struct PresentationValues {
    unowned let entity: Entity

    public subscript<T: Component>(type: T.Type) -> T? {
        entity.world?.presentationValue(of: type, for: entity) ?? entity.components[type]
    }

    public var transform: Transform { self[Transform.self] ?? .identity }
    public var position: SIMD2<Float> { transform.translation }
}

extension Entity {
    /// Component values as currently shown on screen. See ``PresentationValues``.
    public var presentation: PresentationValues { PresentationValues(entity: self) }
}
