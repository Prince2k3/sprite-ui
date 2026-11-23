import ECSCore
import Foundation
import Testing

@Suite struct ManipulationComponentTests {
    private static let customConfiguration = ManipulationComponent(
        operations: [.translation, .rotation],
        translationAxes: .y,
        translationBounds: .init(center: [3, -2], size: [20, 12]),
        translationSnap: [2, 3],
        rotationSnap: .pi / 8,
        scaleRange: 0.5...3,
        physicsRelease: .restoreVelocity
    )

    @Test func defaultsAllowAllChannelsWithoutSnappingOrBounds() {
        let configuration = ManipulationComponent()
        #expect(configuration.isEnabled)
        #expect(configuration.operations == [.translation, .rotation, .scale])
        #expect(configuration.translationAxes == [.x, .y])
        #expect(configuration.translationBounds == nil)
        #expect(configuration.translationSnap == nil)
        #expect(configuration.rotationSnap == nil)
        #expect(configuration.scaleRange == 0.25...4)
        #expect(configuration.physicsRelease == .stop)
    }

    @Test(arguments: Array(UInt8(0)...UInt8(7)), Array(UInt8(0)...UInt8(7)))
    func onlyChannelsPermittedByBothConfigurationAndRequestChange(
        configuredMask: UInt8, requestedMask: UInt8
    ) throws {
        let configured = ManipulationComponent.Operations(rawValue: configuredMask)
        let requested = ManipulationComponent.Operations(rawValue: requestedMask)
        let initial = Transform(translation: [3, -4], rotation: 0.25, scale: [-1, 2], zPosition: 7)
        let proposed = Transform(translation: [12, 15], rotation: 1.25, scale: [-1.5, 3], zPosition: 99)
        let result = try #require(ManipulationComponent(operations: configured).constrained(
            proposed, relativeTo: initial, operations: requested
        ))

        #expect(result.translation == (
            configured.contains(.translation) && requested.contains(.translation) ? [12, 15] : [3, -4]
        ))
        #expect(result.rotation == (
            configured.contains(.rotation) && requested.contains(.rotation) ? 1.25 : 0.25
        ))
        #expect(result.scale == (
            configured.contains(.scale) && requested.contains(.scale) ? [-1.5, 3] : [-1, 2]
        ))
        #expect(result.zPosition == 7)
    }

    @Test func changingEveryGestureChannelPreservesInitialDrawOrder() throws {
        let initial = Transform(zPosition: -12)
        let proposed = Transform(translation: [8, 9], rotation: 0.5, scale: [2, 2], zPosition: 100)
        let result = try #require(ManipulationComponent().constrained(proposed, relativeTo: initial))
        #expect(result == Transform(translation: [8, 9], rotation: 0.5, scale: [2, 2], zPosition: -12))
    }

    @Test(arguments: [ManipulationComponent.TranslationAxes.x, .y, [], .all])
    func locksPreserveParentLocalCoordinatesEvenOutsideBounds(
        axes: ManipulationComponent.TranslationAxes
    ) throws {
        let configuration = ManipulationComponent(
            operations: .translation,
            translationAxes: axes,
            translationBounds: .init(min: [-2, -2], max: [2, 2]),
            translationSnap: [2, 2]
        )
        // Rotating/scaling the child does not rotate the parent's permitted axes.
        let initial = Transform(translation: [3, -7], rotation: .pi / 2, scale: [2, 1])
        var proposed = initial
        proposed.translation = [1.4, 1.4]
        let result = try #require(configuration.constrained(proposed, relativeTo: initial))
        #expect(result.translation.x == (axes.contains(.x) ? 2 : 3))
        #expect(result.translation.y == (axes.contains(.y) ? 2 : -7))
        #expect(result.rotation == initial.rotation)
        #expect(result.scale == initial.scale)
    }

    @Test func boundsWinWhenTheNearestGridPointIsOutsideTheAllowedRegion() throws {
        let configuration = ManipulationComponent(
            translationBounds: .init(min: [-9, -9], max: [9, 9]),
            translationSnap: [10, 10]
        )
        let result = try #require(configuration.constrained(
            Transform(translation: [8, -8]), relativeTo: .identity
        ))
        // Clamping before snapping would incorrectly put the origin at [10, -10].
        #expect(result.translation == [9, -9])
    }

    @Test func translationGridUsesTheParentOriginAndIndependentAxisSteps() throws {
        let configuration = ManipulationComponent(translationSnap: [4, 6])
        let initial = Transform(translation: [3, 3])
        let result = try #require(configuration.constrained(
            Transform(translation: [5, -7]), relativeTo: initial
        ))
        #expect(result.translation == [4, -6])
    }

    @Test(arguments: [Float(-2.7), -0.7, 0.7, 2.7])
    func rotationSnapsToAbsoluteRadiansRatherThanAnOffsetFromTheInitialAngle(angle: Float) throws {
        let configuration = ManipulationComponent(operations: .rotation, rotationSnap: 0.5)
        let result = try #require(configuration.constrained(
            Transform(rotation: angle), relativeTo: Transform(rotation: 0.2)
        ))
        let expected: Float = angle < -1 ? -2.5 : angle < 0 ? -0.5 : angle < 1 ? 0.5 : 2.5
        #expect(abs(result.rotation - expected) < 0.00001)
    }

    @Test(arguments: [Float(0.1), 1.5, 10])
    func oneUniformFactorKeepsEveryLocalMagnitudeInRangeAndPreservesReflection(factor: Float) throws {
        let configuration = ManipulationComponent(scaleRange: 0.5...4)
        let initial = Transform(scale: [-2, 1])
        let result = try #require(configuration.constrained(
            Transform(scale: initial.scale * factor), relativeTo: initial
        ))
        let expected: SIMD2<Float> = factor < 1 ? [-1, 0.5] : factor > 2 ? [-4, 2] : [-3, 1.5]
        #expect(result.scale == expected)
        #expect(result.scale.x / result.scale.y == -2)
        #expect(configuration.scaleRange.contains(abs(result.scale.x)))
        #expect(configuration.scaleRange.contains(abs(result.scale.y)))
    }

    private enum InvalidConfiguration: CaseIterable, Sendable {
        case disabled, reversedXBounds, reversedYBounds, nonfiniteBounds
        case zeroXGrid, zeroYGrid, negativeGrid, nonfiniteGrid
        case zeroRotationStep, negativeRotationStep, nonfiniteRotationStep
        case zeroScaleMinimum, negativeScaleMinimum, infiniteScaleMaximum

        var value: ManipulationComponent {
            var configuration = ManipulationComponent()
            switch self {
            case .disabled: configuration.isEnabled = false
            case .reversedXBounds: configuration.translationBounds = .init(min: [2, 0], max: [1, 1])
            case .reversedYBounds: configuration.translationBounds = .init(min: [0, 2], max: [1, 1])
            case .nonfiniteBounds: configuration.translationBounds = .init(min: [-1, -1], max: [.infinity, 1])
            case .zeroXGrid: configuration.translationSnap = [0, 1]
            case .zeroYGrid: configuration.translationSnap = [1, 0]
            case .negativeGrid: configuration.translationSnap = [-1, 1]
            case .nonfiniteGrid: configuration.translationSnap = [1, .nan]
            case .zeroRotationStep: configuration.rotationSnap = 0
            case .negativeRotationStep: configuration.rotationSnap = -0.5
            case .nonfiniteRotationStep: configuration.rotationSnap = .infinity
            case .zeroScaleMinimum: configuration.scaleRange = 0...4
            case .negativeScaleMinimum: configuration.scaleRange = -1...4
            case .infiniteScaleMaximum: configuration.scaleRange = 0.25...(.infinity)
            }
            return configuration
        }
    }

    @Test(arguments: InvalidConfiguration.allCases)
    private func invalidOrDisabledConfigurationRejectsTheWholeProposedPose(
        invalid: InvalidConfiguration
    ) {
        let initial = Transform(translation: [1, 2], rotation: 0.25, scale: [1, 2], zPosition: 3)
        let proposed = Transform(translation: [5, 6], rotation: 1, scale: [2, 4], zPosition: 9)
        #expect(invalid.value.constrained(proposed, relativeTo: initial) == nil)
    }

    @Test(arguments: [Float.nan, .infinity, -.infinity])
    func nonfiniteInitialOrProposedTransformIsRejected(value: Float) {
        let configuration = ManipulationComponent()
        // Check each scalar separately: an invalid field must not be masked by
        // another invalid field or by a channel that the request does not select.
        let invalidTransforms = [
            Transform(translation: [value, 0]), Transform(translation: [0, value]),
            Transform(rotation: value), Transform(scale: [value, 1]),
            Transform(scale: [1, value]), Transform(zPosition: value),
        ]
        for invalid in invalidTransforms {
            #expect(configuration.constrained(.identity, relativeTo: invalid) == nil)
            #expect(configuration.constrained(invalid, relativeTo: .identity) == nil)
            #expect(configuration.constrained(invalid, relativeTo: .identity, operations: []) == nil)
        }
    }

    @Test func zeroScaleNonuniformScaleAndChangesOfReflectionAreRejected() {
        let configuration = ManipulationComponent()
        let zeroScales: [SIMD2<Float>] = [[0, 1], [1, 0], [0, 0]]
        for scale in zeroScales {
            #expect(configuration.constrained(Transform(scale: scale), relativeTo: Transform(scale: scale)) == nil)
            #expect(configuration.constrained(Transform(scale: scale), relativeTo: .identity) == nil)
        }
        let nonuniformOrReflectedScales: [SIMD2<Float>] = [[1, 2], [-1, 1], [1, -1], [-1, -1]]
        for scale in nonuniformOrReflectedScales {
            #expect(configuration.constrained(Transform(scale: scale), relativeTo: .identity) == nil)
        }
    }

    @Test func impossibleAspectRatioIsRejectedRatherThanClampingAxesIndependently() {
        let configuration = ManipulationComponent(scaleRange: 1...4)
        let initial = Transform(scale: [-10, 1])
        #expect(configuration.constrained(Transform(scale: [-20, 2]), relativeTo: initial) == nil)
    }

    @Test func codableRoundTripsDefaultsAndEveryCustomizedField() throws {
        var disabled = Self.customConfiguration
        disabled.isEnabled = false
        for configuration in [ManipulationComponent(), Self.customConfiguration, disabled] {
            let data = try JSONEncoder().encode(configuration)
            let restored = try JSONDecoder().decode(ManipulationComponent.self, from: data)
            #expect(restored == configuration)
        }
    }

    @MainActor @Test func cloningCopiesConfigurationByValueWithoutARenderer() throws {
        ManipulationComponent.registerComponent()
        let original = Entity(components: Self.customConfiguration)
        let copy = original.clone()
        #expect(copy.id != original.id)
        #expect(copy.components[ManipulationComponent.self] == Self.customConfiguration)

        var changed = try #require(copy.components[ManipulationComponent.self])
        changed.translationBounds?.min.x = -100
        changed.operations = .scale
        changed.physicsRelease = .stop
        copy.components.set(changed)
        #expect(copy.components[ManipulationComponent.self] == changed)
        #expect(original.components[ManipulationComponent.self] == Self.customConfiguration)
    }

    @MainActor @Test func explicitlyRegisteredConfigurationSurvivesJSONSnapshotAndRestore() throws {
        ManipulationComponent.registerComponent()
        let world = World()
        let entity = Entity(name: "manipulated", components: Self.customConfiguration)
        entity.transform = Transform(translation: [3, -2], rotation: 0.5, scale: [-2, 1], zPosition: 4)
        world.addEntity(entity)
        let snapshot = world.snapshot()
        entity.components[ManipulationComponent.self]?.isEnabled = false

        let decoded = try WorldSnapshot(data: snapshot.jsonData())
        let saved = try #require(decoded.entities.first)
        #expect(saved[ManipulationComponent.self] == Self.customConfiguration)
        let firstCopy = saved.makeEntity(), secondCopy = saved.makeEntity()
        firstCopy.components[ManipulationComponent.self]?.translationSnap = nil
        #expect(secondCopy.components[ManipulationComponent.self] == Self.customConfiguration)
        #expect(saved[ManipulationComponent.self] == Self.customConfiguration)

        let restoredWorld = World()
        let restored = try #require(restoredWorld.restore(decoded)[entity.id])
        #expect(restored.components[ManipulationComponent.self] == Self.customConfiguration)
        #expect(restored.transform == entity.transform)
    }
}
