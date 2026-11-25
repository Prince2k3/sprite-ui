# API reference

Look up a type when you know what you want to build. Each symbol page describes
its properties, methods, and parameters. If you are learning the library, start
with <doc:getting-started> or <doc:spriteui-tutorials> instead.

## Topics

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

### Engine profiling

- ``SpriteUI/EngineProfiler``
- ``SpriteUI/EngineProfileConfiguration``
- ``SpriteUI/EngineProfileCapture``
- ``SpriteUI/EngineProfileFrame``
- ``SpriteUI/EngineProfileSummary``

### Classes

- <doc:/documentation/SpriteUI/ActionTransaction>
- <doc:/documentation/SpriteUI/AnimationPlaybackController>
- <doc:/documentation/SpriteUI/AudioPlaybackController>

### Protocols

- <doc:/documentation/SpriteUI/EntityState>
- <doc:/documentation/SpriteUI/Event>
- <doc:/documentation/SpriteUI/GameModel>
- <doc:/documentation/SpriteUI/GameState>
- <doc:/documentation/SpriteUI/RandomDistribution>
- <doc:/documentation/SpriteUI/SpatialIndex>
- <doc:/documentation/SpriteUI/WorldObserver>

### Structures

- <doc:/documentation/SpriteUI/ActionAnimation>
- <doc:/documentation/SpriteUI/AdjacencyGraph>
- <doc:/documentation/SpriteUI/AnimationMarker>
- <doc:/documentation/SpriteUI/Animator>
- <doc:/documentation/SpriteUI/AudioComponent>
- <doc:/documentation/SpriteUI/BoundingBox>
- <doc:/documentation/SpriteUI/CharacterContact>
- <doc:/documentation/SpriteUI/CharacterMovementResult>
- <doc:/documentation/SpriteUI/CircleObstacle>
- <doc:/documentation/SpriteUI/CollisionFilter>
- <doc:/documentation/SpriteUI/CollisionGroup>
- <doc:/documentation/SpriteUI/CollisionHit>
- <doc:/documentation/SpriteUI/CollisionQueryFilter>
- <doc:/documentation/SpriteUI/ContactEffectComponent>
- <doc:/documentation/SpriteUI/CostMap>
- <doc:/documentation/SpriteUI/DecisionBranch>
- <doc:/documentation/SpriteUI/DecisionTree>
- <doc:/documentation/SpriteUI/EngineProfileNetwork>
- <doc:/documentation/SpriteUI/EngineProfileQueries>
- <doc:/documentation/SpriteUI/EngineProfileSystem>
- <doc:/documentation/SpriteUI/EngineProfileWorkload>
- <doc:/documentation/SpriteUI/EntityReferenceRemapping>
- <doc:/documentation/SpriteUI/EntityTargetGesture>
- <doc:/documentation/SpriteUI/Facts>
- <doc:/documentation/SpriteUI/GameCoordinateSpace>
- <doc:/documentation/SpriteUI/GameViewAttachments>
- <doc:/documentation/SpriteUI/GaussianDistribution>
- <doc:/documentation/SpriteUI/GraphEdge>
- <doc:/documentation/SpriteUI/GridPoint>
- <doc:/documentation/SpriteUI/GridSpace>
- <doc:/documentation/SpriteUI/LifetimeComponent>
- <doc:/documentation/SpriteUI/LifetimeSystem>
- <doc:/documentation/SpriteUI/MaskLayer>
- <doc:/documentation/SpriteUI/Minimax>
- <doc:/documentation/SpriteUI/MonteCarloTreeSearch>
- <doc:/documentation/SpriteUI/Noise>
- <doc:/documentation/SpriteUI/NoiseGradient>
- <doc:/documentation/SpriteUI/NoiseMap>
- <doc:/documentation/SpriteUI/ObstacleGraph>
- <doc:/documentation/SpriteUI/PhysicsSimulationSettings>
- <doc:/documentation/SpriteUI/PlaybackOptions>
- <doc:/documentation/SpriteUI/PlaybackSystem>
- <doc:/documentation/SpriteUI/PolygonObstacle>
- <doc:/documentation/SpriteUI/PolygonObstacleComponent>
- <doc:/documentation/SpriteUI/QuadTree>
- <doc:/documentation/SpriteUI/QueryPredicate>
- <doc:/documentation/SpriteUI/Rule>
- <doc:/documentation/SpriteUI/RuleSystem>
- <doc:/documentation/SpriteUI/SceneComponent>
- <doc:/documentation/SpriteUI/SceneDebugComponent>
- <doc:/documentation/SpriteUI/SceneDebugEntity>
- <doc:/documentation/SpriteUI/SceneLoader>
- <doc:/documentation/SpriteUI/SceneUserDataComponent>
- <doc:/documentation/SpriteUI/ScoredMove>
- <doc:/documentation/SpriteUI/SeededGenerator>
- <doc:/documentation/SpriteUI/ShuffleBag>
- <doc:/documentation/SpriteUI/SpatialCategories>
- <doc:/documentation/SpriteUI/SpatialHash>
- <doc:/documentation/SpriteUI/SpatialIndexComponent>
- <doc:/documentation/SpriteUI/SpriteImage>
- <doc:/documentation/SpriteUI/StateMachineComponent>
- <doc:/documentation/SpriteUI/StateMachineSystem>
- <doc:/documentation/SpriteUI/StateTransition>
- <doc:/documentation/SpriteUI/SteeringGoal>
- <doc:/documentation/SpriteUI/SteeringObstacleComponent>
- <doc:/documentation/SpriteUI/SystemTiming>
- <doc:/documentation/SpriteUI/TextureAtlasResource>
- <doc:/documentation/SpriteUI/TransformConstraint>
- <doc:/documentation/SpriteUI/VectorPath>
- <doc:/documentation/SpriteUI/Wander>
- <doc:/documentation/SpriteUI/WeightedDistribution>

### Functions

- <doc:/documentation/SpriteUI/withAnimation(_:)>
- <doc:/documentation/SpriteUI/withAnimation(_:_:)>
- <doc:/documentation/SpriteUI/withAnimation(_:_:completion:)>
- <doc:/documentation/SpriteUI/withAnimation(_:completion:)>

### Type Aliases

- <doc:/documentation/SpriteUI/DecisionAnswers>
- <doc:/documentation/SpriteUI/PhysicsShape>

### Enumerations

- <doc:/documentation/SpriteUI/CharacterMovementError>
- <doc:/documentation/SpriteUI/CollisionGeometry>
- <doc:/documentation/SpriteUI/CollisionQueryMode>
- <doc:/documentation/SpriteUI/CollisionShape>
- <doc:/documentation/SpriteUI/ComponentEvents>
- <doc:/documentation/SpriteUI/ConstraintOffsetSpace>
- <doc:/documentation/SpriteUI/ConstraintSpace>
- <doc:/documentation/SpriteUI/ConstraintTarget>
- <doc:/documentation/SpriteUI/DecisionCondition>
- <doc:/documentation/SpriteUI/DecisionNode>
- <doc:/documentation/SpriteUI/DecisionValue>
- <doc:/documentation/SpriteUI/EntityPoolError>
- <doc:/documentation/SpriteUI/EntityTransformError>
- <doc:/documentation/SpriteUI/GameAttachmentBuilder>
- <doc:/documentation/SpriteUI/GameOutcome>
- <doc:/documentation/SpriteUI/MaskContent>
- <doc:/documentation/SpriteUI/PathEvents>
- <doc:/documentation/SpriteUI/PhysicsEvents>
- <doc:/documentation/SpriteUI/PhysicsJointConstraint>
- <doc:/documentation/SpriteUI/PhysicsJointStatus>
- <doc:/documentation/SpriteUI/PlaybackError>
- <doc:/documentation/SpriteUI/PlaybackEvents>
- <doc:/documentation/SpriteUI/PlaybackRepeatMode>
- <doc:/documentation/SpriteUI/PlaybackState>
- <doc:/documentation/SpriteUI/PlaybackStopReason>
- <doc:/documentation/SpriteUI/PlayerInputError>
- <doc:/documentation/SpriteUI/PostProcessEffect>
- <doc:/documentation/SpriteUI/RenderingEvents>
- <doc:/documentation/SpriteUI/ResourceLoadingError>
- <doc:/documentation/SpriteUI/SceneLoadingError>
- <doc:/documentation/SpriteUI/SceneValue>
- <doc:/documentation/SpriteUI/ShaderError>
- <doc:/documentation/SpriteUI/ShaderValue>
- <doc:/documentation/SpriteUI/ShapeGeometry>
- <doc:/documentation/SpriteUI/SpriteBlendMode>
- <doc:/documentation/SpriteUI/StateMachineEvents>
- <doc:/documentation/SpriteUI/SteeringBehavior>
- <doc:/documentation/SpriteUI/SteeringTarget>
- <doc:/documentation/SpriteUI/SystemSchedulingError>
- <doc:/documentation/SpriteUI/TextFont>
- <doc:/documentation/SpriteUI/TransformConstraintBehavior>
- <doc:/documentation/SpriteUI/TransformConstraintStatus>
- <doc:/documentation/SpriteUI/VisibilityEvents>

### Extended Modules

- <doc:/documentation/SpriteUI/Swift>
- <doc:/documentation/SpriteUI/SwiftUICore>
