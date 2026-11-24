import Foundation
import ECSCore
import Testing

private enum InMemoryObservation: Equatable {
    case connected(NetworkPeerID, String)
    case disconnected(NetworkPeerID)
    case received(Data, NetworkPeerID)
    case failed(String)

    init(_ event: NetworkTransportEvent) {
        switch event {
        case .connected(let peer): self = .connected(peer.id, peer.displayName)
        case .disconnected(let peer): self = .disconnected(peer)
        case .received(let data, let peer): self = .received(data, peer)
        case .failed(let reason): self = .failed(reason)
        }
    }
}

@MainActor private final class InMemoryEventLog {
    var events: [InMemoryObservation] = []
    var received: [Data] {
        events.compactMap { if case .received(let data, _) = $0 { return data }; return nil }
    }

    func attach(to transport: InMemoryNetworkTransport) {
        transport.onEvent = { [weak self] in self?.events.append(InMemoryObservation($0)) }
    }
}

private func memoryPeer(_ name: String) -> NetworkPeer {
    NetworkPeer(id: NetworkPeerID(rawValue: name), displayName: name.uppercased())
}

@MainActor @Suite struct InMemoryNetworkTests {
    @Test func connectionsAreDeferredSymmetricAndInJoinOrder() throws {
        let hub = InMemoryNetwork()
        let a = try hub.connect(memoryPeer("a"))
        let b = try hub.connect(memoryPeer("b"))
        let c = try hub.connect(memoryPeer("c"))
        var trace: [String] = []
        for transport in [a, b, c] {
            let name = transport.localPeer.id.rawValue
            transport.onEvent = { event in
                if case .connected(let peer) = event { trace.append("\(name):\(peer.id.rawValue)") }
            }
        }
        #expect(trace.isEmpty)
        #expect(a.connectedPeers.map(\.id) == [b.localPeer.id, c.localPeer.id])
        #expect(b.connectedPeers.map(\.id) == [a.localPeer.id, c.localPeer.id])
        #expect(c.connectedPeers.map(\.id) == [a.localPeer.id, b.localPeer.id])
        hub.advance(by: 0)
        #expect(trace == ["a:b", "b:a", "a:c", "c:a", "b:c", "c:b"])
        #expect(hub.pendingEventCount == 0)
        hub.advance(by: 0)
        #expect(trace.count == 6)
    }

    @Test func lateCallbacksRetainConnectionsAndPackets() throws {
        let hub = InMemoryNetwork()
        let a = try hub.connect(memoryPeer("a"))
        let b = try hub.connect(memoryPeer("b"))
        let payload = Data("claimed-sender:c".utf8)
        try a.send(payload, to: b.localPeer.id, reliably: true)
        hub.advance(by: 1)
        #expect(hub.pendingEventCount == 2)
        #expect(hub.pendingMessageCount == 1)
        #expect(hub.pendingByteCount == payload.count)
        let log = InMemoryEventLog()
        log.attach(to: b)
        #expect(log.events.isEmpty)
        hub.advance(by: 0)
        #expect(log.events == [.connected(a.localPeer.id, "A"), .received(payload, a.localPeer.id)])
        #expect(hub.pendingMessageCount == 0 && hub.pendingByteCount == 0)
        #expect(hub.pendingEventCount == 1)
    }

    @Test func zeroLatencyStillRequiresAdvance() throws {
        let hub = InMemoryNetwork()
        let a = try hub.connect(memoryPeer("a"))
        let b = try hub.connect(memoryPeer("b"))
        let log = InMemoryEventLog()
        log.attach(to: b)
        hub.advance(by: 0)
        log.events.removeAll()
        try a.send(Data([7]), to: b.localPeer.id, reliably: true)
        #expect(log.events.isEmpty)
        hub.advance(by: 0)
        #expect(log.events == [.received(Data([7]), a.localPeer.id)])
        #expect(hub.currentTime == 0)
    }

    @Test func latencyUsesOnlyControlledTime() throws {
        let hub = InMemoryNetwork(latency: 0.5)
        let a = try hub.connect(memoryPeer("a"))
        let b = try hub.connect(memoryPeer("b"))
        let log = InMemoryEventLog()
        log.attach(to: b)
        hub.advance(by: 0)
        #expect(log.events == [.connected(a.localPeer.id, "A")])
        try a.send(Data([1]), to: b.localPeer.id, reliably: true)
        hub.advance(by: 0.25)
        #expect(log.received.isEmpty && hub.pendingMessageCount == 1)
        hub.advance(by: 0.25)
        #expect(log.received == [Data([1])])
        #expect(hub.currentTime == 0.5)
    }

    @Test func reliableOrderSurvivesLatencyChangesWithoutBlockingOtherLinks() throws {
        let hub = InMemoryNetwork(latency: 2)
        let a = try hub.connect(memoryPeer("a"))
        let b = try hub.connect(memoryPeer("b"))
        let aLog = InMemoryEventLog(), bLog = InMemoryEventLog()
        aLog.attach(to: a); bLog.attach(to: b)
        try a.send(Data([1]), to: b.localPeer.id, reliably: true)
        hub.latency = 0
        try a.send(Data([2]), to: b.localPeer.id, reliably: true)
        try b.send(Data([9]), to: a.localPeer.id, reliably: true)
        hub.advance(by: 0)
        #expect(aLog.received == [Data([9])])
        #expect(bLog.received.isEmpty)
        hub.advance(by: 2)
        #expect(bLog.received == [Data([1]), Data([2])])
    }

    @Test func unreliableLossHasStableSeededSequence() throws {
        func run(seed: UInt64) throws -> [UInt8] {
            let hub = InMemoryNetwork(unreliableLossRate: 0.5, seed: seed)
            let a = try hub.connect(memoryPeer("a"))
            let b = try hub.connect(memoryPeer("b"))
            let log = InMemoryEventLog()
            log.attach(to: b)
            for value in UInt8(0)..<16 {
                try a.send(Data([value]), to: b.localPeer.id, reliably: false)
            }
            try a.send(Data([255]), to: b.localPeer.id, reliably: true)
            hub.advance(by: 0)
            return log.received.compactMap(\.first)
        }
        let sequence = try run(seed: 0)
        #expect(sequence == [0, 3, 7, 9, 11, 12, 13, 14, 15, 255])
        #expect(try run(seed: 0) == sequence)
        #expect(try run(seed: 1) != sequence)
    }

    @Test func completeLossOnlyDropsUnreliablePackets() throws {
        let hub = InMemoryNetwork(unreliableLossRate: 1)
        let a = try hub.connect(memoryPeer("a"))
        let b = try hub.connect(memoryPeer("b"))
        let log = InMemoryEventLog()
        log.attach(to: b)
        for _ in 0..<20 { try a.send(Data([0]), to: b.localPeer.id, reliably: false) }
        #expect(hub.pendingMessageCount == 0 && hub.pendingByteCount == 0)
        try a.send(Data([1]), to: b.localPeer.id, reliably: true)
        hub.advance(by: 0)
        #expect(log.received == [Data([1])])
    }

    @Test func disconnectCancelsBothDirectionsAndReconnectUsesFreshLifetime() throws {
        let hub = InMemoryNetwork(latency: 1)
        let a = try hub.connect(memoryPeer("a"))
        let oldB = try hub.connect(memoryPeer("b"))
        let c = try hub.connect(memoryPeer("c"))
        let aLog = InMemoryEventLog(), oldLog = InMemoryEventLog(), cLog = InMemoryEventLog()
        aLog.attach(to: a); oldLog.attach(to: oldB); cLog.attach(to: c)
        hub.advance(by: 0)
        try a.send(Data([1]), to: oldB.localPeer.id, reliably: true)
        try oldB.send(Data([2]), to: a.localPeer.id, reliably: true)
        try c.send(Data([3]), to: oldB.localPeer.id, reliably: false)
        try c.send(Data([4]), to: a.localPeer.id, reliably: true)
        oldB.disconnect()
        oldB.disconnect()
        #expect(oldB.connectedPeers.isEmpty)
        #expect(hub.pendingMessageCount == 1 && hub.pendingByteCount == 1)
        let newB = try hub.connect(memoryPeer("b"))
        let newLog = InMemoryEventLog()
        newLog.attach(to: newB)
        try a.send(Data([5]), to: newB.localPeer.id, reliably: true)
        try newB.send(Data([6]), to: a.localPeer.id, reliably: true)
        #expect(throws: InMemoryNetworkError.notConnected) {
            try oldB.send(Data([7]), to: a.localPeer.id, reliably: true)
        }
        hub.advance(by: 1)
        #expect(aLog.received == [Data([4]), Data([6])])
        #expect(oldLog.received.isEmpty)
        #expect(newLog.received == [Data([5])])
        #expect(newLog.events.first == .connected(a.localPeer.id, "A"))
        #expect(!newLog.events.contains(.disconnected(a.localPeer.id)))
        #expect(aLog.events.suffix(3) == [
            .connected(newB.localPeer.id, "B"), .received(Data([4]), c.localPeer.id),
            .received(Data([6]), newB.localPeer.id)
        ])
        #expect(hub.pendingMessageCount == 0 && hub.pendingByteCount == 0)
    }

    @Test func disconnectedTransportRetainsLifecycleEventsForLateCallback() throws {
        let hub = InMemoryNetwork()
        let a = try hub.connect(memoryPeer("a"))
        let b = try hub.connect(memoryPeer("b"))
        b.disconnect()
        let log = InMemoryEventLog()
        log.attach(to: b)
        hub.advance(by: 0)
        #expect(log.events == [.connected(a.localPeer.id, "A"), .disconnected(a.localPeer.id)])
        #expect(b.connectedPeers.isEmpty)
    }

    @Test func duplicateUnknownAndSelfPeersFailAtomically() throws {
        let hub = InMemoryNetwork()
        let a = try hub.connect(memoryPeer("a"))
        #expect(throws: InMemoryNetworkError.duplicatePeer(a.localPeer.id)) {
            _ = try hub.connect(NetworkPeer(id: a.localPeer.id, displayName: "Imposter"))
        }
        #expect(throws: InMemoryNetworkError.unknownPeer(a.localPeer.id)) {
            try a.send(Data(), to: a.localPeer.id, reliably: true)
        }
        let absent = NetworkPeerID(rawValue: "absent")
        #expect(throws: InMemoryNetworkError.unknownPeer(absent)) {
            try a.send(Data(), to: absent, reliably: true)
        }
        #expect(a.localPeer.displayName == "A")
        #expect(a.connectedPeers.isEmpty)
        #expect(hub.pendingMessageCount == 0 && hub.pendingEventCount == 0)
    }

    @Test(arguments: [true, false]) func packetSizeBoundaries(reliably: Bool) throws {
        let hub = InMemoryNetwork()
        let a = try hub.connect(memoryPeer("a"))
        let b = try hub.connect(memoryPeer("b"))
        let limit = reliably ? 48_000 : 1_000
        #expect(throws: InMemoryNetworkError.packetTooLarge(maximumBytes: limit)) {
            try a.send(Data(repeating: 0, count: limit + 1), to: b.localPeer.id, reliably: reliably)
        }
        let data = Data(repeating: 1, count: limit)
        try a.send(data, to: b.localPeer.id, reliably: reliably)
        try a.send(Data(), to: b.localPeer.id, reliably: reliably)
        #expect(hub.pendingMessageCount == 2 && hub.pendingByteCount == limit)
        let log = InMemoryEventLog()
        log.attach(to: b)
        hub.advance(by: 0)
        #expect(log.received == [data, Data()])
    }

    @Test func messageCountBudgetIncludesZeroLengthAndUnreadPackets() throws {
        let hub = InMemoryNetwork(maximumPendingMessages: 2)
        let a = try hub.connect(memoryPeer("a"))
        let b = try hub.connect(memoryPeer("b"))
        try a.send(Data(), to: b.localPeer.id, reliably: true)
        try b.send(Data(), to: a.localPeer.id, reliably: false)
        hub.advance(by: 0)
        #expect(throws: InMemoryNetworkError.messageQueueFull) {
            try a.send(Data(), to: b.localPeer.id, reliably: true)
        }
        #expect(hub.pendingMessageCount == 2 && hub.pendingByteCount == 0)
        let log = InMemoryEventLog()
        log.attach(to: b)
        hub.advance(by: 0)
        #expect(hub.pendingMessageCount == 1)
        try a.send(Data(), to: b.localPeer.id, reliably: false)
        #expect(hub.pendingMessageCount == 2)
    }

    @Test func byteBudgetIsGlobalAndReleasedOnDisconnect() throws {
        let hub = InMemoryNetwork(maximumPendingBytes: 3)
        let a = try hub.connect(memoryPeer("a"))
        let b = try hub.connect(memoryPeer("b"))
        try a.send(Data([1, 2]), to: b.localPeer.id, reliably: true)
        #expect(throws: InMemoryNetworkError.messageQueueFull) {
            try b.send(Data([3, 4]), to: a.localPeer.id, reliably: false)
        }
        try b.send(Data([3]), to: a.localPeer.id, reliably: true)
        #expect(hub.pendingByteCount == 3)
        b.disconnect()
        #expect(hub.pendingByteCount == 0 && hub.pendingMessageCount == 0)
        let replacement = try hub.connect(memoryPeer("b"))
        try replacement.send(Data([1, 2, 3]), to: a.localPeer.id, reliably: true)
        #expect(hub.pendingByteCount == 3)
    }

    @Test func peerBudgetIsReleasedAfterDisconnect() throws {
        let hub = InMemoryNetwork(maximumPeers: 2)
        let a = try hub.connect(memoryPeer("a"))
        let b = try hub.connect(memoryPeer("b"))
        #expect(throws: InMemoryNetworkError.peerLimitReached) { _ = try hub.connect(memoryPeer("c")) }
        b.disconnect()
        let c = try hub.connect(memoryPeer("c"))
        #expect(a.connectedPeers.map(\.id) == [c.localPeer.id])
    }

    @Test func lifecycleBudgetReservesDisconnectAndBoundsUndrainedReconnects() throws {
        let hub = InMemoryNetwork(maximumPendingEvents: 4)
        let a = try hub.connect(memoryPeer("a"))
        let b = try hub.connect(memoryPeer("b"))
        #expect(hub.pendingEventCount == 2)
        #expect(throws: InMemoryNetworkError.eventQueueFull) { _ = try hub.connect(memoryPeer("c")) }
        #expect(a.connectedPeers.map(\.id) == [b.localPeer.id])
        b.disconnect()
        #expect(hub.pendingEventCount == 4)
        #expect(throws: InMemoryNetworkError.eventQueueFull) { _ = try hub.connect(memoryPeer("b")) }
        let aLog = InMemoryEventLog(), bLog = InMemoryEventLog()
        aLog.attach(to: a); bLog.attach(to: b)
        hub.advance(by: 0)
        #expect(aLog.events == [.connected(b.localPeer.id, "B"), .disconnected(b.localPeer.id)])
        #expect(bLog.events == [.connected(a.localPeer.id, "A"), .disconnected(a.localPeer.id)])
        #expect(hub.pendingEventCount == 0)
        let replacement = try hub.connect(memoryPeer("b"))
        #expect(replacement.localPeer.id == b.localPeer.id)
    }

    @Test func invalidClockChangesDoNotDeliverOrPoisonTime() throws {
        let hub = InMemoryNetwork()
        let a = try hub.connect(memoryPeer("a"))
        let b = try hub.connect(memoryPeer("b"))
        let log = InMemoryEventLog()
        log.attach(to: b)
        for value in [-1.0, Double.nan, Double.infinity, -Double.infinity] { hub.advance(by: value) }
        #expect(hub.currentTime == 0 && log.events.isEmpty)
        hub.advance(by: .greatestFiniteMagnitude)
        #expect(hub.currentTime == .greatestFiniteMagnitude)
        log.events.removeAll()
        hub.advance(by: .greatestFiniteMagnitude)
        #expect(hub.currentTime == .greatestFiniteMagnitude && log.events.isEmpty)
        hub.latency = .greatestFiniteMagnitude
        #expect(throws: InMemoryNetworkError.invalidDeliveryTime) {
            try a.send(Data([1]), to: b.localPeer.id, reliably: true)
        }
        #expect(hub.pendingMessageCount == 0)
        hub.latency = 0
        try a.send(Data([2]), to: b.localPeer.id, reliably: true)
        hub.advance(by: 0)
        #expect(log.received == [Data([2])])
    }

    @Test func invalidConfigurationIsSanitized() {
        let hub = InMemoryNetwork(latency: .nan, unreliableLossRate: .infinity,
                                  maximumPeers: 0, maximumPendingMessages: -1,
                                  maximumPendingBytes: 0, maximumPendingEvents: -1)
        #expect(hub.latency == 0 && hub.unreliableLossRate == 0)
        #expect(hub.maximumPeers == 1 && hub.maximumPendingMessages == 1)
        #expect(hub.maximumPendingBytes == 1 && hub.maximumPendingEvents == 1)
        for value in [-1.0, Double.nan, Double.infinity, -Double.infinity] {
            hub.latency = value
            #expect(hub.latency == 0)
        }
        hub.unreliableLossRate = 2
        #expect(hub.unreliableLossRate == 1)
        hub.unreliableLossRate = -1
        #expect(hub.unreliableLossRate == 0)
        hub.unreliableLossRate = .nan
        #expect(hub.unreliableLossRate == 0)
    }

    @Test func callbacksCannotRecursivelyDeliverOrAdvanceTheClock() throws {
        let hub = InMemoryNetwork()
        let a = try hub.connect(memoryPeer("a"))
        let b = try hub.connect(memoryPeer("b"))
        a.onEvent = { _ in }; b.onEvent = { _ in }
        hub.advance(by: 0)
        var values: [Data] = []
        var sendFailed = false
        b.onEvent = { event in
            guard case .received(let data, _) = event else { return }
            values.append(data)
            if data == Data([1]) {
                do { try a.send(Data([2]), to: b.localPeer.id, reliably: true) }
                catch { sendFailed = true }
                hub.advance(by: 100)
                #expect(values == [Data([1])])
            }
        }
        try a.send(Data([1]), to: b.localPeer.id, reliably: true)
        hub.advance(by: 0)
        #expect(!sendFailed && hub.currentTime == 0)
        #expect(values == [Data([1])] && hub.pendingMessageCount == 1)
        hub.advance(by: 0)
        #expect(values == [Data([1]), Data([2])])
    }

    @Test func disconnectDuringDeliveryCancelsRemainingSnapshotPackets() throws {
        let hub = InMemoryNetwork()
        let a = try hub.connect(memoryPeer("a"))
        let b = try hub.connect(memoryPeer("b"))
        a.onEvent = { _ in }; b.onEvent = { _ in }
        hub.advance(by: 0)
        var values: [Data] = []
        var replacement: InMemoryNetworkTransport?
        var reconnectFailed = false
        b.onEvent = { event in
            guard case .received(let data, _) = event else { return }
            values.append(data)
            b.disconnect()
            do {
                replacement = try hub.connect(memoryPeer("b"))
                try a.send(Data([3]), to: b.localPeer.id, reliably: true)
            } catch { reconnectFailed = true }
        }
        try a.send(Data([1]), to: b.localPeer.id, reliably: true)
        try a.send(Data([2]), to: b.localPeer.id, reliably: true)
        hub.advance(by: 0)
        #expect(!reconnectFailed && values == [Data([1])])
        #expect(hub.pendingMessageCount == 1)
        let newLog = InMemoryEventLog()
        newLog.attach(to: try #require(replacement))
        hub.advance(by: 0)
        #expect(newLog.received == [Data([3])])
        #expect(values == [Data([1])])
    }

    @Test func installingCallbackMidAdvanceDoesNotPassEarlierReliablePacket() throws {
        let hub = InMemoryNetwork()
        let a = try hub.connect(memoryPeer("a"))
        let b = try hub.connect(memoryPeer("b"))
        a.onEvent = { _ in }; b.onEvent = { _ in }
        hub.advance(by: 0)
        b.onEvent = nil
        let bLog = InMemoryEventLog()
        a.onEvent = { _ in bLog.attach(to: b) }
        try a.send(Data([1]), to: b.localPeer.id, reliably: true)
        try b.send(Data([9]), to: a.localPeer.id, reliably: true)
        try a.send(Data([2]), to: b.localPeer.id, reliably: true)
        hub.advance(by: 0)
        #expect(bLog.received.isEmpty)
        hub.advance(by: 0)
        #expect(bLog.received == [Data([1]), Data([2])])
    }

    @Test func releasingHubEndsItsTransports() throws {
        var hub: InMemoryNetwork? = InMemoryNetwork()
        weak var weakHub = hub
        let a = try #require(hub).connect(memoryPeer("a"))
        let b = try #require(hub).connect(memoryPeer("b"))
        hub = nil
        #expect(weakHub == nil && a.connectedPeers.isEmpty && b.connectedPeers.isEmpty)
        #expect(throws: InMemoryNetworkError.notConnected) {
            try a.send(Data(), to: b.localPeer.id, reliably: true)
        }
        a.disconnect()
    }
}
