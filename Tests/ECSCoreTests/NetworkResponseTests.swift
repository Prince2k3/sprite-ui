import Foundation
@testable import ECSCore
import Testing

@MainActor private final class ResponseTransport: NetworkTransport {
    let base: InMemoryNetworkTransport
    var sent: [Data] = []
    init(_ base: InMemoryNetworkTransport) { self.base = base }
    var localPeer: NetworkPeer { base.localPeer }
    var connectedPeers: [NetworkPeer] { base.connectedPeers }
    var onEvent: (@MainActor (NetworkTransportEvent) -> Void)? { get { base.onEvent } set { base.onEvent = newValue } }
    func send(_ data: Data, to peer: NetworkPeerID, reliably: Bool) throws { sent.append(data); try base.send(data, to: peer, reliably: reliably) }
    func disconnect() { base.disconnect() }
}
@MainActor private final class ResponseRig {
    let hub = InMemoryNetwork()
    let hostWorld = World(), clientWorld = World()
    let host: NetworkSession, client: NetworkSession
    let hostTransport: ResponseTransport, clientTransport: InMemoryNetworkTransport
    init() throws {
        hostTransport = ResponseTransport(try hub.connect(.init(id: .init(rawValue: "host"), displayName: "Host")))
        clientTransport = try hub.connect(.init(id: .init(rawValue: "client"), displayName: "Client"))
        host = .init(world: hostWorld, transport: hostTransport, role: .host)
        client = .init(world: clientWorld, transport: clientTransport, role: .client(host: hostTransport.localPeer.id))
        try host.start(); try client.start(); tick()
    }
    func tick(_ count: Int = 8) { for _ in 0..<count { hub.advance(by: 0.1); hostWorld.update(deltaTime: 0.1); clientWorld.update(deltaTime: 0.1) } }
    func close() { host.stop(); client.stop() }
}
@MainActor @Suite struct NetworkResponseTests {
    @Test func onlyTheHostCanRespondToJoinedPeersWithoutEditingTheWorld() throws {
        let rig = try ResponseRig(); defer { rig.close() }
        var results: [Data] = [], senders: [NetworkPeerID] = []
        let token = rig.clientWorld.subscribe(to: NetworkEvents.ResponseReceived.self) { results.append($0.data); senders.append($0.sender) }; defer { token.cancel() }
        try rig.host.sendResponse(Data([1, 2, 3]), to: rig.client.localPeer.id); rig.tick()
        #expect(results == [Data([1, 2, 3])] && senders == [rig.host.localPeer.id])
        #expect(rig.clientWorld.entities.isEmpty && rig.client.state == .connected)
        #expect(throws: NetworkSessionError.notHost) { try rig.client.sendResponse(Data(), to: rig.host.localPeer.id) }
        #expect(throws: NetworkSessionError.notConnected) { try rig.host.sendResponse(Data(), to: .init(rawValue: "unknown")) }
    }
    @Test func responseLimitsIncludeTheUnreliableEnvelope() throws {
        let rig = try ResponseRig(); defer { rig.close() }
        #expect(throws: NetworkSessionError.packetTooLarge) { try rig.host.sendResponse(Data(repeating: 0, count: 4097), to: rig.client.localPeer.id) }
        #expect(throws: NetworkSessionError.packetTooLarge) { try rig.host.sendResponse(Data(repeating: 0, count: 1000), to: rig.client.localPeer.id, reliably: false) }
        #expect(rig.host.state == .connected)
        try rig.host.sendResponse(Data(repeating: 0, count: 10), to: rig.client.localPeer.id, reliably: false)
    }
    @Test func retiredHostResponsesCannotEnterARestartedJoin() throws {
        let rig = try ResponseRig(); defer { rig.close() }; var responses = 0
        let token = rig.clientWorld.subscribe(to: NetworkEvents.ResponseReceived.self) { _ in responses += 1 }; defer { token.cancel() }
        try rig.host.sendResponse(Data([7]), to: rig.client.localPeer.id); rig.tick()
        let old = try #require(rig.hostTransport.sent.first { (try? JSONDecoder().decode(ReplicationPacket.self, from: $0).kind) == .response })
        rig.host.stop(); rig.client.stop(); try rig.host.start(); try rig.client.start(); rig.tick()
        try rig.hostTransport.send(old, to: rig.client.localPeer.id, reliably: true); rig.tick()
        #expect(responses == 1 && rig.client.state == .connected)
        try rig.host.sendResponse(Data([8]), to: rig.client.localPeer.id); rig.tick(); #expect(responses == 2)
    }
    @Test func differentUnreliableStreamsAreDeliveredWithoutAGlobalRevisionFilter() throws {
        let rig = try ResponseRig(); defer { rig.close() }; var results: [UInt8] = []
        let token = rig.clientWorld.subscribe(to: NetworkEvents.ResponseReceived.self) { if let first = $0.data.first { results.append(first) } }; defer { token.cancel() }
        rig.hub.latency = 1; try rig.host.sendResponse(Data([1]), to: rig.client.localPeer.id, reliably: false)
        rig.hub.latency = 0; try rig.host.sendResponse(Data([2]), to: rig.client.localPeer.id, reliably: false)
        rig.tick(15); #expect(results == [2, 1])
    }
    @Test func responsesCannotBeSentReentrantlyInsideACommandCallback() throws {
        let rig = try ResponseRig(); defer { rig.close() }; var error: NetworkSessionError?
        let token = rig.hostWorld.subscribe(to: NetworkEvents.CommandReceived.self) { _ in
            do { try rig.host.sendResponse(Data(), to: rig.client.localPeer.id) } catch let caught as NetworkSessionError { error = caught } catch {}
        }; defer { token.cancel() }
        try rig.client.sendCommand(Data([1])); rig.tick()
        #expect(error == .reentrantOperation && rig.host.isAttached(to: rig.hostWorld))
    }
}
