# ``SpriteUI``

Build 2D games with entities, reusable gameplay algorithms, a SpriteKit renderer, and a SwiftUI host.

## Overview

SpriteUI gives your game a data model that you can update, inspect, clone, and save. Add components to an ``SpriteUI/Entity``, attach the entity to a ``SpriteUI/World``, and present that world with ``SpriteUI/GameView``. Systems advance game rules each frame; the renderer translates component changes into visuals, physics, and audio.

Start with <doc:getting-started> for a small scene that needs no assets. Then choose a guide by the work you need to do, or follow <doc:spriteui-tutorials> for a guided sequence.

### Choose an entry point

| You want to… | Start here |
| --- | --- |
| Install the package and display a scene | <doc:getting-started> |
| Organize hierarchies, activation, shared state, and events | <doc:entity-and-scene-lifecycle> |
| Run frame logic and handle targeted gestures | <doc:systems-and-input> |
| Drag, rotate, and scale entities with automatic gestures or buttons | <doc:manipulating-entities> |
| Map on-screen controls, keyboard, pointer, and gamepads to actions | <doc:input-actions-and-controllers> |
| Assign devices to players, adapt prompts, and request controller feedback | <doc:player-input-sessions-and-feedback> |
| Render one world through player cameras and a minimap | <doc:viewports-and-split-screen> |
| Bound render-target work and share completed game frames | <doc:bounded-rendering-and-read-only-presentation> |
| Fit cameras and controls around safe areas and reserved regions | <doc:adaptive-game-surfaces> |
| Observe a live hinge or bind it to an explicitly assigned player action | <doc:hinge-input-and-effects> |
| Give cameras different art while hidden objects keep simulating | <doc:render-layers-and-camera-visibility> |
| Scroll and repeat decorative backgrounds independently per camera | <doc:parallax-and-repeating-backgrounds> |
| Replace levels while preserving players and cameras | <doc:scene-transitions-and-level-management> |
| Plan routes and move characters | <doc:gameplay-and-movement> |
| Load assets and assemble visual content | <doc:rendering-and-resources> |
| Save progress and inspect a running scene | <doc:saving-and-debugging> |

### Understand the package layers

Use `import SpriteUI` for the complete SDK. The umbrella re-exports the package's five implementation modules, and this archive presents their public APIs together under SpriteUI.

| Layer | Responsibility | Representative APIs |
| --- | --- | --- |
| ECSCore | Entities, components, queries, scheduling, events, and snapshots | ``SpriteUI/Entity``, ``SpriteUI/World``, ``SpriteUI/System`` |
| Gameplay | Value-oriented algorithms independent of a world or renderer | ``SpriteUI/Agent2D``, ``SpriteUI/Graph``, ``SpriteUI/NavigationMesh`` |
| GameplayECS | Components and systems that connect gameplay algorithms to entities | ``SpriteUI/SteeringComponent``, ``SpriteUI/PathFollowSystem`` |
| SpriteBackend | Rendering, resources, playback, collision, physics, and diagnostics | ``SpriteUI/SpriteRenderer``, ``SpriteUI/ResourceLibrary`` |
| GameUI | SwiftUI scene hosting, entity gestures, and attachments | ``SpriteUI/GameView``, ``SpriteUI/GameAttachment`` |
| SpriteUI | One import for the SDK, plus noise-image and tile-map integration | ``SpriteUI/SpriteImage``, ``SpriteUI/TileMapComponent`` |

Entities, worlds, systems, and scene interaction belong on the main actor. Pure gameplay values can be computed separately where their API permits, then applied to a world on the main actor. Keep app state, per-entity data, and frame simulation in their respective owners; the guides show how those owners meet.

## Topics

### Library guides

- <doc:getting-started>
- <doc:entity-and-scene-lifecycle>
- <doc:systems-and-input>
- <doc:input-actions-and-controllers>
- <doc:player-input-sessions-and-feedback>
- <doc:viewports-and-split-screen>
- <doc:bounded-rendering-and-read-only-presentation>
- <doc:adaptive-game-surfaces>
- <doc:hinge-input-and-effects>
- <doc:render-layers-and-camera-visibility>
- <doc:parallax-and-repeating-backgrounds>
- <doc:scene-transitions-and-level-management>
- <doc:manipulating-entities>
- <doc:gameplay-and-movement>
- <doc:rendering-and-resources>
- <doc:saving-and-debugging>

### Guided tutorials

- <doc:spriteui-tutorials>

### Entities and scene state

- ``SpriteUI/Entity``
- ``SpriteUI/Component``
- ``SpriteUI/ComponentSet``
- ``SpriteUI/World``
- ``SpriteUI/Transform``
- ``SpriteUI/AffineTransform2D``
- ``SpriteUI/EntityQuery``
- ``SpriteUI/PresentationValues``

### Levels and transitions

- ``SpriteUI/LevelCoordinator``
- ``SpriteUI/LevelContext``
- ``SpriteUI/LevelTransition``
- ``SpriteUI/LevelLoadingError``
- ``SpriteUI/LevelEvents``

### Frame logic and interaction

- ``SpriteUI/System``
- ``SpriteUI/SystemCollection``
- ``SpriteUI/SystemDependency``
- ``SpriteUI/SystemPhase``
- ``SpriteUI/UpdateContext``
- ``SpriteUI/EventSubscription``
- ``SpriteUI/InputTargetComponent``
- ``SpriteUI/EntityTargetValue``

### Direct manipulation

- ``SpriteUI/ManipulationComponent``
- ``SpriteUI/ManipulationSession``
- ``SpriteUI/ManipulationEvents``

### Input actions and controllers

- ``SpriteUI/InputController``
- ``SpriteUI/InputAction``
- ``SpriteUI/InputActionKind``
- ``SpriteUI/InputActionMap``
- ``SpriteUI/InputBinding``
- ``SpriteUI/InputControl``
- ``SpriteUI/InputDevice``
- ``SpriteUI/InputValue``
- ``SpriteUI/InputActionState``
- ``SpriteUI/InputActionPhase``
- ``SpriteUI/InputActionEvent``
- ``SpriteUI/InputSubscription``
- ``SpriteUI/GamepadButton``
- ``SpriteUI/GamepadAxis``

### Player input sessions and feedback

- ``SpriteUI/PlayerInputHub``
- ``SpriteUI/PlayerInputSession``
- ``SpriteUI/InputDeviceInfo``
- ``SpriteUI/InputControlPresentation``
- ``SpriteUI/InputPrompt``
- ``SpriteUI/InputDeviceEvent``
- ``SpriteUI/InputDeviceSubscription``
- ``SpriteUI/ControllerFeedback``
- ``SpriteUI/InputFeedbackResult``
- ``SpriteUI/InputFeedbackProvider``

### Gameplay and movement

- ``SpriteUI/Agent2D``
- ``SpriteUI/AgentGoal``
- ``SpriteUI/AgentPath``
- ``SpriteUI/SteeringComponent``
- ``SpriteUI/SteeringSystem``
- ``SpriteUI/PathComponent``
- ``SpriteUI/PathFollowSystem``
- ``SpriteUI/SpatialIndexSystem``
- ``SpriteUI/Graph``
- ``SpriteUI/GridGraph``
- ``SpriteUI/NavigationMesh``
- ``SpriteUI/StateMachine``

### Scene hosting and SwiftUI content

- ``SpriteUI/GameView``
- ``SpriteUI/GameViewContent``
- ``SpriteUI/GameAttachment``
- ``SpriteUI/AttachmentComponent``
- ``SpriteUI/AttachmentContext``

### Rendering quality and read-only presentation

- ``SpriteUI/GameRenderConfiguration``
- ``SpriteUI/GameRenderEnvironment``
- ``SpriteUI/GameRenderMonitor``
- ``SpriteUI/GameRenderStatistics``
- ``SpriteUI/GamePresentationSource``
- ``SpriteUI/GamePresentationView``

### Adaptive game surfaces

- ``SpriteUI/GameSurfaceGeometry``
- ``SpriteUI/GameSurfaceRegion``
- ``SpriteUI/GameSurfaceEvents``

### Hinge input and effects

- ``SpriteUI/GameHingeState``
- ``SpriteUI/GameHingeEvents``
- ``SpriteUI/HingeInputConfiguration``

### Drawing and resource reuse

- ``SpriteUI/SpriteRenderer``
- ``SpriteUI/SpriteComponent``
- ``SpriteUI/SpriteMaterial``
- ``SpriteUI/ShaderResource``
- ``SpriteUI/TextComponent``
- ``SpriteUI/ShapeComponent``
- ``SpriteUI/ResourceLibrary``
- ``SpriteUI/TextureResource``
- ``SpriteUI/AnimationResource``
- ``SpriteUI/AudioResource``
- ``SpriteUI/PlaybackController``
- ``SpriteUI/PrefabResource``
- ``SpriteUI/EntityPool``

### Cameras, effects, and collision

- ``SpriteUI/GameViewport``
- ``SpriteUI/ViewportRect``
- ``SpriteUI/CameraComponent``
- ``SpriteUI/ParallaxComponent``
- ``SpriteUI/RepeatingBackgroundComponent``
- ``SpriteUI/RenderLayer``
- ``SpriteUI/VisibilityComponent``
- ``SpriteUI/TransformConstraintComponent``
- ``SpriteUI/MaskComponent``
- ``SpriteUI/RenderGroupComponent``
- ``SpriteUI/LightComponent``
- ``SpriteUI/ParticleEmitterComponent``
- ``SpriteUI/TileMapComponent``
- ``SpriteUI/CollisionComponent``
- ``SpriteUI/CharacterControllerComponent``
- ``SpriteUI/PhysicsBodyComponent``
- ``SpriteUI/PhysicsJointComponent``

### Persistence and diagnostics

- ``SpriteUI/ComponentRegistry``
- ``SpriteUI/EntitySnapshot``
- ``SpriteUI/WorldSnapshot``
- ``SpriteUI/EntityReferencingComponent``
- ``SpriteUI/SceneDebugController``
- ``SpriteUI/SceneDebugOptions``
- ``SpriteUI/SceneDebugSnapshot``
