import Foundation

/// Validation and capacity failures from an in-memory transport. Failed operations
/// do not enqueue events, change membership, or consume a random sample.
public enum InMemoryNetworkError: Error, Equatable, Sendable {
    /// Another live transport already owns this identity.
    case duplicatePeer(NetworkPeerID)
    /// The hub's live-peer limit has been reached.
    case peerLimitReached
    /// This transport's connection lifetime has ended.
    case notConnected
    /// The destination is not another live peer in this hub.
    case unknownPeer(NetworkPeerID)
    /// The payload exceeds the delivery mode's byte limit.
    case packetTooLarge(maximumBytes: Int)
    /// The pending message-count or byte budget has been exhausted.
    case messageQueueFull
    /// A connection cannot reserve its connected and disconnected notifications.
    case eventQueueFull
    /// The packet's delivery time would overflow the controlled clock.
    case invalidDeliveryTime
}

/// A deterministic, main-actor byte network for tests and local simulations.
///
/// Retain the hub for the lifetime of its transports. Peers form a full mesh;
/// membership changes immediately, but callbacks run only in `advance(by:)`.
/// Even zero-latency traffic needs an advance. Lifecycle events have no latency.
/// Events without a callback remain queued until a later advance, within the
/// configured budgets. Each connection reserves its eventual disconnect events,
/// so disconnect never silently drops lifecycle notifications under pressure.
///
/// Delivery is ordered by scheduled time, then enqueue order. Reliable packets
/// preserve send order per directed link even when latency changes. Random loss
/// affects only unreliable packets and uses a private, seeded SplitMix64 stream.
/// A transport instance identifies one connection generation: disconnect discards
/// all its pending packets, and reconnecting the same peer ID creates a new one.
@MainActor
public final class InMemoryNetwork {
    /// Maximum reliable payload, in bytes (48 KB).
    public static let maximumReliablePacketSize = 48_000
    /// Maximum unreliable payload, in bytes.
    public static let maximumUnreliablePacketSize = 1_000

    /// Elapsed simulated seconds. Invalid advances leave this unchanged.
    public private(set) var currentTime: TimeInterval = 0
    /// Maximum number of simultaneously connected transports.
    public let maximumPeers: Int
    /// Maximum queued packets across the entire hub, including unread packets.
    public let maximumPendingMessages: Int
    /// Maximum total payload bytes across all queued packets.
    public let maximumPendingBytes: Int
    /// Maximum queued lifecycle events plus reserved disconnect notifications.
    public let maximumPendingEvents: Int
    /// Number of packets still awaiting delivery, including those without callbacks.
    public private(set) var pendingMessageCount = 0
    /// Payload bytes still awaiting delivery.
    public private(set) var pendingByteCount = 0
    /// Queued lifecycle notifications, excluding reserved disconnect notifications.
    public private(set) var pendingEventCount = 0

    /// Delay applied to future sends. Negative or nonfinite values become zero.
    public var latency: TimeInterval {
        get { storedLatency }
        set { storedLatency = newValue.isFinite ? max(0, newValue) : 0 }
    }

    /// Probability of dropping each accepted unreliable send. Finite values are
    /// clamped to 0...1; nonfinite values become zero. Reliable sends never drop.
    public var unreliableLossRate: Double {
        get { storedLossRate }
        set { storedLossRate = newValue.isFinite ? min(1, max(0, newValue)) : 0 }
    }

    private var storedLatency: TimeInterval
    private var storedLossRate: Double
    private var random: InMemoryRandom
    private var members: [InMemoryNetworkTransport] = []
    private var pending: [Delivery] = []
    private var reservedDisconnectEvents = 0
    private var isAdvancing = false

    /// Creates an empty hub with a clock starting at zero. Limits are clamped to
    /// at least one. A connection to N existing peers requires room for 4N events:
    /// two connected notifications and two reserved disconnected notifications
    /// per link. Queue-full sends throw, for both delivery modes, before sampling
    /// loss. Identical accepted sends and seeds produce identical loss decisions.
    public init(latency: TimeInterval = 0, unreliableLossRate: Double = 0,
                seed: UInt64 = 0, maximumPeers: Int = 32,
                maximumPendingMessages: Int = 1_024,
                maximumPendingBytes: Int = 4 * 1_024 * 1_024,
                maximumPendingEvents: Int = 4_096) {
        storedLatency = latency.isFinite ? max(0, latency) : 0
        storedLossRate = unreliableLossRate.isFinite ? min(1, max(0, unreliableLossRate)) : 0
        random = InMemoryRandom(seed: seed)
        self.maximumPeers = max(1, maximumPeers)
        self.maximumPendingMessages = max(1, maximumPendingMessages)
        self.maximumPendingBytes = max(1, maximumPendingBytes)
        self.maximumPendingEvents = max(1, maximumPendingEvents)
    }

    /// Joins a peer and queues symmetric connection events in join order.
    /// Throws on a duplicate live ID or exhausted peer/event capacity. Admission
    /// is atomic: a rejected join leaves all existing transports unchanged.
    public func connect(_ peer: NetworkPeer) throws -> InMemoryNetworkTransport {
        guard !members.contains(where: { $0.localPeer.id == peer.id }) else {
            throw InMemoryNetworkError.duplicatePeer(peer.id)
        }
        guard members.count < maximumPeers else { throw InMemoryNetworkError.peerLimitReached }
        let eventSpace = maximumPendingEvents - pendingEventCount - reservedDisconnectEvents
        guard members.count <= eventSpace / 4 else { throw InMemoryNetworkError.eventQueueFull }

        let transport = InMemoryNetworkTransport(peer: peer, network: self)
        for member in members {
            enqueue(.connected(peer), to: member)
            enqueue(.connected(member.localPeer), to: transport)
            reservedDisconnectEvents += 2
        }
        members.append(transport)
        return transport
    }

    /// Moves the clock forward and delivers the events already queued at entry
    /// whose scheduled times have arrived. Missing callbacks retain events.
    /// Sends or connection events created by callbacks wait for another advance;
    /// nested advances are ignored, preventing reentrant delivery. Negative,
    /// nonfinite, or overflowing advances are ignored, including their deliveries.
    public func advance(by seconds: TimeInterval) {
        guard !isAdvancing, seconds.isFinite, seconds >= 0,
              (currentTime + seconds).isFinite else { return }
        currentTime += seconds
        isAdvancing = true
        defer { isAdvancing = false }

        // Snapshot tickets, not payloads: callbacks can cancel packets and
        // reuse the freed budget without keeping canceled Data alive in a batch.
        let ready = pending.enumerated()
            .filter { $0.element.time <= currentTime }
            .sorted {
                if $0.element.time != $1.element.time { return $0.element.time < $1.element.time }
                return $0.offset < $1.offset
            }
            .map { $0.element.ticket }
        var blocked: Set<ObjectIdentifier> = []
        for ticket in ready {
            guard let index = pending.firstIndex(where: { $0.ticket === ticket }) else { continue }
            let delivery = pending[index]
            let recipient = ObjectIdentifier(delivery.recipient)
            guard !blocked.contains(recipient) else { continue }
            guard let callback = delivery.recipient.onEvent else {
                // Installing this callback from another recipient's event must
                // not allow a later reliable packet to pass the skipped one.
                blocked.insert(recipient)
                continue
            }
            pending.remove(at: index)
            if delivery.sender != nil {
                pendingMessageCount -= 1
                pendingByteCount -= delivery.byteCount
            } else {
                pendingEventCount -= 1
            }
            callback(delivery.event)
        }
    }

    fileprivate func peers(for transport: InMemoryNetworkTransport) -> [NetworkPeer] {
        guard members.contains(where: { $0 === transport }) else { return [] }
        return members.filter { $0 !== transport }.map(\.localPeer)
    }

    fileprivate func send(_ data: Data, from sender: InMemoryNetworkTransport,
                          to peer: NetworkPeerID, reliably: Bool) throws {
        guard members.contains(where: { $0 === sender }) else { throw InMemoryNetworkError.notConnected }
        guard let recipient = members.first(where: { $0.localPeer.id == peer && $0 !== sender }) else {
            throw InMemoryNetworkError.unknownPeer(peer)
        }
        let maximumSize = reliably ? Self.maximumReliablePacketSize : Self.maximumUnreliablePacketSize
        guard data.count <= maximumSize else {
            throw InMemoryNetworkError.packetTooLarge(maximumBytes: maximumSize)
        }
        guard pendingMessageCount < maximumPendingMessages,
              data.count <= maximumPendingBytes - pendingByteCount else {
            throw InMemoryNetworkError.messageQueueFull
        }
        var time = currentTime + latency
        guard time.isFinite else { throw InMemoryNetworkError.invalidDeliveryTime }
        if reliably {
            // Computing this from the bounded queue avoids an ever-growing map
            // of historical links and retains order when latency decreases.
            for delivery in pending where delivery.reliably && delivery.sender === sender
                && delivery.recipient === recipient {
                time = max(time, delivery.time)
            }
        } else if random.nextUnitInterval() < unreliableLossRate {
            return
        }
        pending.append(Delivery(event: .received(data, from: sender.localPeer.id),
                                recipient: recipient, sender: sender, time: time,
                                reliably: reliably, byteCount: data.count))
        pendingMessageCount += 1
        pendingByteCount += data.count
    }

    fileprivate func disconnect(_ transport: InMemoryNetworkTransport) {
        guard let index = members.firstIndex(where: { $0 === transport }) else { return }
        members.remove(at: index)
        pending.removeAll { delivery in
            guard delivery.sender != nil,
                  delivery.sender === transport || delivery.recipient === transport else { return false }
            pendingMessageCount -= 1
            pendingByteCount -= delivery.byteCount
            return true
        }
        for member in members {
            reservedDisconnectEvents -= 2
            enqueue(.disconnected(transport.localPeer.id), to: member)
            enqueue(.disconnected(member.localPeer.id), to: transport)
        }
    }

    private func enqueue(_ event: NetworkTransportEvent, to recipient: InMemoryNetworkTransport) {
        pending.append(Delivery(event: event, recipient: recipient, sender: nil,
                                time: currentTime, reliably: false, byteCount: 0))
        pendingEventCount += 1
    }

    private final class Delivery {
        // Keeping a ticket alive prevents identity reuse after cancellation.
        final class Ticket {}
        let ticket = Ticket()
        let event: NetworkTransportEvent
        let recipient: InMemoryNetworkTransport
        let sender: InMemoryNetworkTransport?
        let time: TimeInterval
        let reliably: Bool
        let byteCount: Int

        init(event: NetworkTransportEvent, recipient: InMemoryNetworkTransport,
             sender: InMemoryNetworkTransport?, time: TimeInterval, reliably: Bool, byteCount: Int) {
            self.event = event
            self.recipient = recipient
            self.sender = sender
            self.time = time
            self.reliably = reliably
            self.byteCount = byteCount
        }
    }
}

/// One hub-issued connection lifetime. Its peer identity is immutable and cannot
/// be supplied by a packet. Instances can only be created by `InMemoryNetwork`.
@MainActor
public final class InMemoryNetworkTransport: NetworkTransport {
    /// The identity assigned when this transport joined its hub.
    public let localPeer: NetworkPeer
    /// Other live members in join order; empty after this transport disconnects.
    public var connectedPeers: [NetworkPeer] { network?.peers(for: self) ?? [] }
    /// Event handler. Assigning it never invokes callbacks; advance the hub to
    /// receive queued events, including notifications from before installation.
    public var onEvent: (@MainActor (NetworkTransportEvent) -> Void)?

    private weak var network: InMemoryNetwork?

    fileprivate init(peer: NetworkPeer, network: InMemoryNetwork) {
        localPeer = peer
        self.network = network
    }

    /// Queues a bounded payload to another live peer. Validation/capacity errors
    /// throw synchronously without emitting `.failed`. Reliable sends never
    /// suffer simulated loss; unreliable sends may succeed while being dropped.
    public func send(_ data: Data, to peer: NetworkPeerID, reliably: Bool) throws {
        guard let network else { throw InMemoryNetworkError.notConnected }
        try network.send(data, from: self, to: peer, reliably: reliably)
    }

    /// Ends this lifetime immediately, discards its pending incoming/outgoing
    /// packets, and queues symmetric disconnect events. Repeated calls do nothing.
    /// Queued lifecycle notifications remain available on the old transport;
    /// reconnecting its peer ID never transfers callbacks or packets to the new one.
    public func disconnect() {
        network?.disconnect(self)
    }
}

/// Local PRNG keeps ECSCore independent of Gameplay and system randomness.
private struct InMemoryRandom {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func nextUnitInterval() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        value ^= value >> 31
        return Double(value >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }
}
