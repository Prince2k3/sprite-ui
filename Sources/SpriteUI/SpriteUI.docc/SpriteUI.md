# ``SpriteUI``

Build 2D games with entities, reusable gameplay algorithms, a SpriteKit renderer, and a SwiftUI host.

## Overview

SpriteUI gives your game a data model that you can update, inspect, clone, and save. Add components to an ``SpriteUI/Entity``, attach the entity to a ``SpriteUI/World``, and present that world with ``SpriteUI/GameView``. Systems advance game rules each frame; the renderer translates component changes into visuals, physics, and audio.

Start with <doc:getting-started> for a small scene that needs no assets. Then choose a guide by the work you need to do, or follow <doc:spriteui-tutorials> for a guided sequence.

### Choose an entry point

| You want to… | Start here |
| --- | --- |
| Install the package and display a scene | <doc:getting-started> |
| Choose engine-only, Game Center, or standalone gameplay products | <doc:package-products-and-dependencies> |
| Organize hierarchies, activation, shared state, and events | <doc:entity-and-scene-lifecycle> |
| Run frame logic and handle targeted gestures | <doc:systems-and-input> |
| Run fixed custom ticks, interpolate kinematic art, and buffer input | <doc:fixed-step-simulation-and-interpolation> |
| Record fixed input and inspect replay with diagnostic checksums | <doc:input-recording-and-replay> |
| Drag, rotate, and scale entities with automatic gestures or buttons | <doc:manipulating-entities> |
| Map on-screen controls, keyboard, pointer, and gamepads to actions | <doc:input-actions-and-controllers> |
| Assign devices to players, adapt prompts, and request controller feedback | <doc:player-input-sessions-and-feedback> |
| Start with local achievements, scores, and typed saved turns, then opt into native screens | <doc:game-center-services> |
| Play an integrated two-player DemoBots repair round | <doc:demobots-cooperative-multiplayer> |
| Select player scopes and bound entity replication traffic | <doc:replication-interest-and-bandwidth> |
| Validate shots and interactions against bounded historical views | <doc:multiplayer-interactions-and-lag-compensation> |
| Predict owned kinematic movement and reconcile host corrections | <doc:multiplayer-prediction-and-reconciliation> |
| Recover a checkpoint through an explicit fresh party match | <doc:multiplayer-recovery-and-rejoining> |
| Match an activity party and hand off prepared worlds | <doc:activity-party-matchmaking-and-handoff> |
| Route activity invitations and report each native challenge attempt | <doc:game-center-activities-and-challenges> |
| Define quests, claim reward receipts, and run seasonal leagues | <doc:quests-and-leagues> |
| Persist profiles and rewards, then opt into cloud saves | <doc:player-profiles-and-cloud-saves> |
| Synchronize a small host-authoritative match offline or through Game Center | <doc:game-center-sessions-and-replication> |
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

Use `import SpriteUI` for the complete SDK. The umbrella re-exports `SpriteUICore`, `SpriteUIGameCenter`, and `SpriteUISaves`, and this archive presents their public APIs together under SpriteUI. Choose <doc:package-products-and-dependencies> for a smaller dependency graph.

| Layer | Responsibility | Representative APIs |
| --- | --- | --- |
| ECSCore | Entities, components, queries, scheduling, snapshots, and network sessions | ``SpriteUI/Entity``, ``SpriteUI/World``, ``SpriteUI/System`` |
| Gameplay | Value-oriented algorithms independent of a world or renderer | ``SpriteUI/Agent2D``, ``SpriteUI/Graph``, ``SpriteUI/NavigationMesh`` |
| GameplayECS | Components and systems that connect gameplay algorithms to entities | ``SpriteUI/SteeringComponent``, ``SpriteUI/PathFollowSystem`` |
| SpriteBackend | Rendering, resources, playback, collision, physics, and diagnostics | ``SpriteUI/SpriteRenderer``, ``SpriteUI/ResourceLibrary`` |
| GameUI | SwiftUI scene hosting, gestures, and attachments | ``SpriteUI/GameView``, ``SpriteUI/GameAttachment`` |
| SpriteUICore | Engine aggregate, noise-image, tile-map, and replay integration; no Game Center target | ``SpriteUI/SpriteImage``, ``SpriteUI/TileMapComponent`` |
| SpriteUIGameCenter | Optional Game Center services, native UI, and progression reporting | ``SpriteUI/GameCenterServices``, ``SpriteUI/GameCenterProgression`` |
| SpriteUISaves | Optional typed profiles, wallet transactions, and GameSave integration | ``SpriteUI/PlayerProfileStore``, ``SpriteUI/CloudSaveDirectory`` |
| SpriteUI | Convenience aggregate for the engine, Game Center, and saves | ``SpriteUI/World``, ``SpriteUI/GameCenterServices`` |

Entities, worlds, systems, and scene interaction belong on the main actor. Pure gameplay values can be computed separately where their API permits, then applied to a world on the main actor. Keep app state, per-entity data, and frame simulation in their respective owners; the guides show how those owners meet.

## Topics

### Library guides

- <doc:getting-started>
- <doc:package-products-and-dependencies>
- <doc:entity-and-scene-lifecycle>
- <doc:systems-and-input>
- <doc:fixed-step-simulation-and-interpolation>
- <doc:input-recording-and-replay>
- <doc:input-actions-and-controllers>
- <doc:player-input-sessions-and-feedback>
- <doc:game-center-services>
- <doc:game-center-activities-and-challenges>
- <doc:activity-party-matchmaking-and-handoff>
- <doc:multiplayer-recovery-and-rejoining>
- <doc:multiplayer-prediction-and-reconciliation>
- <doc:multiplayer-interactions-and-lag-compensation>
- <doc:replication-interest-and-bandwidth>
- <doc:demobots-cooperative-multiplayer>
- <doc:quests-and-leagues>
- <doc:player-profiles-and-cloud-saves>
- <doc:game-center-sessions-and-replication>
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

### Fixed simulation and interpolation

- ``SpriteUI/FixedStepConfiguration``
- ``SpriteUI/FixedStepState``
- ``SpriteUI/TransformInterpolationComponent``
- ``SpriteUI/FixedInputBuffer``
- ``SpriteUI/FixedInputSample``
- ``SpriteUI/WorldEvents``

### Input recording and replay

- ``SpriteUI/InputRecording``
- ``SpriteUI/InputRecordingFrame``
- ``SpriteUI/InputRecordingChecksum``
- ``SpriteUI/InputRecordingError``
- ``SpriteUI/InputRecorder``
- ``SpriteUI/InputReplayController``
- ``SpriteUI/InputReplayError``
- ``SpriteUI/InputReplayWorldStateError``

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

### Basic Game Center services

- ``SpriteUI/GameCenterServices``
- ``SpriteUI/GameCenterServicesMode``
- ``SpriteUI/GameCenterDestination``
- ``SpriteUI/GameCenterServiceError``
- ``SpriteUI/GameCenterServicesView``
- ``SpriteUI/GameCenterAchievements``
- ``SpriteUI/GameCenterAchievement``
- ``SpriteUI/GameCenterLeaderboards``
- ``SpriteUI/GameCenterLeaderboardEntry``
- ``SpriteUI/GameCenterLeaderboardResults``
- ``SpriteUI/GameCenterTurnBasedMatches``
- ``SpriteUI/GameCenterTurnBasedMatch``
- ``SpriteUI/GameCenterTurnBasedParticipant``
- ``SpriteUI/GameCenterTurnBasedStatus``
- ``SpriteUI/GameCenterTurnBasedParticipantStatus``
- ``SpriteUI/GameCenterTurnBasedOutcome``
- ``SpriteUI/InMemoryTurnBasedStore``
- ``SpriteUI/GameCenterTurnBasedMatchmakingView``

### Multiplayer recovery

- ``SpriteUI/NetworkRecoveryCheckpoint``
- ``SpriteUI/NetworkRecoveryDescriptor``
- ``SpriteUI/NetworkRecoveryError``
- ``SpriteUI/GameCenterRecoveryConfiguration``
- ``SpriteUI/GameCenterPartyInterruption``
- ``SpriteUI/GameCenterInterruptionReason``

### Activity parties

- ``SpriteUI/GameCenterParty``
- ``SpriteUI/GameCenterPartyState``
- ``SpriteUI/GameCenterPartyMember``
- ``SpriteUI/GameCenterPartyPreview``
- ``SpriteUI/GameCenterPartyView``

### Activities and challenges

- ``SpriteUI/GameCenterActivities``
- ``SpriteUI/GameCenterActivityDefinition``
- ``SpriteUI/GameCenterActivity``
- ``SpriteUI/GameCenterActivityState``
- ``SpriteUI/GameCenterActivityScore``
- ``SpriteUI/GameCenterActivityRequest``
- ``SpriteUI/GameCenterActivityCompletion``
- ``SpriteUI/GameCenterChallenges``
- ``SpriteUI/GameCenterChallengeDefinition``
- ``SpriteUI/GameCenterChallengeAttempt``
- ``SpriteUI/GameCenterChallengeAttemptStatus``
- ``SpriteUI/GameCenterActivitiesView``
- ``SpriteUI/GameCenterChallengesView``

### Quests and leagues

- ``SpriteUI/QuestDefinition``
- ``SpriteUI/QuestObjective``
- ``SpriteUI/QuestEvent``
- ``SpriteUI/QuestJournal``
- ``SpriteUI/QuestStatus``
- ``SpriteUI/QuestProgress``
- ``SpriteUI/QuestReward``
- ``SpriteUI/QuestRewardClaim``
- ``SpriteUI/QuestJournalComponent``
- ``SpriteUI/QuestEvents``
- ``SpriteUI/ProgressionWindow``
- ``SpriteUI/ProgressionError``
- ``SpriteUI/LeagueTier``
- ``SpriteUI/LeagueParticipant``
- ``SpriteUI/LeagueRules``
- ``SpriteUI/LeagueResult``
- ``SpriteUI/LeagueSeason``
- ``SpriteUI/LeagueStanding``
- ``SpriteUI/LeaguePlacement``
- ``SpriteUI/GameCenterProgression``
- ``SpriteUI/GameCenterQuestMapping``
- ``SpriteUI/GameCenterLeagueMapping``

### Player profiles and cloud saves

- ``SpriteUI/PlayerProfileID``
- ``SpriteUI/SaveSlotID``
- ``SpriteUI/PlayerProfile``
- ``SpriteUI/PlayerProfileStore``
- ``SpriteUI/ProfileSaveSchema``
- ``SpriteUI/ProfileWallet``
- ``SpriteUI/ProfileSaveError``
- ``SpriteUI/ProfileSaveLocation``
- ``SpriteUI/ProfileSlotSummary``
- ``SpriteUI/ProfileSlotHealth``
- ``SpriteUI/CloudSaveDirectory``
- ``SpriteUI/CloudSaveStatus``
- ``SpriteUI/CloudSaveVersion``
- ``SpriteUI/CloudSavePreviewVersion``

### Replication relevance and traffic

- ``SpriteUI/NetworkReplicationPriority``
- ``SpriteUI/NetworkRelevance``
- ``SpriteUI/NetworkReplicationPolicy``
- ``SpriteUI/NetworkReplicationBudget``
- ``SpriteUI/NetworkPeerReplicationStatistics``
- ``SpriteUI/NetworkInterestComponent``
- ``SpriteUI/NetworkSpatialInterest``
- ``SpriteUI/NetworkSpatialInterestError``

### Multiplayer interactions

- ``SpriteUI/NetworkInteractionConfiguration``
- ``SpriteUI/NetworkInteractionError``
- ``SpriteUI/NetworkInteractionViewReference``
- ``SpriteUI/NetworkInteractionView``
- ``SpriteUI/NetworkInteractionCommand``
- ``SpriteUI/NetworkInteractionRejection``
- ``SpriteUI/NetworkInteractionResolution``
- ``SpriteUI/NetworkInteractionResult``
- ``SpriteUI/NetworkInteractionDecision``
- ``SpriteUI/NetworkInteractionAuthority``
- ``SpriteUI/NetworkInteractionClient``
- ``SpriteUI/HistoricalCollisionError``
- ``SpriteUI/HistoricalCollisionBody2D``
- ``SpriteUI/HistoricalCollisionHit2D``
- ``SpriteUI/HistoricalCollisionScene2D``
- ``SpriteUI/NetworkInteractionBodyComponent``
- ``SpriteUI/NetworkInteractionRules2D``
- ``SpriteUI/NetworkInteractionIntent2D``
- ``SpriteUI/NetworkInteractionOutcome2D``
- ``SpriteUI/NetworkInteractionScene2D``
- ``SpriteUI/NetworkInteractionControllerStatus``
- ``SpriteUI/NetworkInteractionEvents``
- ``SpriteUI/NetworkInteractionController2D``
- ``SpriteUI/NetworkInteractionSystem2D``

### Multiplayer prediction

- ``SpriteUI/NetworkPrediction``
- ``SpriteUI/NetworkInputAuthority``
- ``SpriteUI/NetworkPredictionConfiguration``
- ``SpriteUI/NetworkPredictionStream``
- ``SpriteUI/NetworkInputCommand``
- ``SpriteUI/NetworkAuthoritativeState``
- ``SpriteUI/NetworkReconciliation``
- ``SpriteUI/NetworkPredictionError``
- ``SpriteUI/KinematicState2D``
- ``SpriteUI/KinematicMovement2D``
- ``SpriteUI/KinematicMovementError``
- ``SpriteUI/NetworkMovementController2D``
- ``SpriteUI/NetworkMovementPresentationConfiguration``
- ``SpriteUI/NetworkMovementStatus``
- ``SpriteUI/NetworkMovementError``
- ``SpriteUI/NetworkMovementSystem2D``
- ``SpriteUI/NetworkMovementPresentationSystem2D``

### Network sessions and Game Center

- ``SpriteUI/NetworkSession``
- ``SpriteUI/NetworkTransport``
- ``SpriteUI/NetworkTransportEvent``
- ``SpriteUI/NetworkPeer``
- ``SpriteUI/NetworkPeerID``
- ``SpriteUI/NetworkEntityID``
- ``SpriteUI/SynchronizationComponent``
- ``SpriteUI/NetworkReplicationSchema``
- ``SpriteUI/NetworkSessionConfiguration``
- ``SpriteUI/NetworkSessionError``
- ``SpriteUI/NetworkReplicationSystem``
- ``SpriteUI/NetworkEvents``
- ``SpriteUI/InMemoryNetwork``
- ``SpriteUI/InMemoryNetworkTransport``
- ``SpriteUI/InMemoryNetworkError``
- ``SpriteUI/GameCenterMultiplayer``
- ``SpriteUI/GameCenterTransport``
- ``SpriteUI/GameCenterMatchRequest``
- ``SpriteUI/GameCenterAuthenticationState``
- ``SpriteUI/GameCenterMatchmakingState``
- ``SpriteUI/GameCenterAuthenticationView``
- ``SpriteUI/GameCenterMatchmakingView``
- ``SpriteUI/GameCenterError``

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
