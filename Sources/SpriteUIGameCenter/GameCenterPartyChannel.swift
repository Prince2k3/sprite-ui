import ECSCore
import Foundation

struct GameCenterPartyPacket: Codable {
    enum Kind: String, Codable { case hello, status, launch, ack, play, cancel, checkpoint, synchronized, recovered }
    var version = 2
    let kind: Kind
    let definition: String
    let code: String
    let roster: [NetworkPeerID]
    var revision: UInt64 = 0
    var compatibility: String?
    var ready = false
    var launch: UUID?
    var recovery: NetworkRecoveryDescriptor? = nil
}

/// Keeps lobby control ownership while NetworkSession exclusively owns the inner callback.
@MainActor final class GameCenterPartyChannel: NetworkTransport {
    static let prefix = Data("SpriteUI.party.1\0".utf8)
    let base: any NetworkTransport
    private let initialPeers: Set<NetworkPeerID>
    var localPeer: NetworkPeer { base.localPeer }
    var connectedPeers: [NetworkPeer] { base.connectedPeers }
    var onEvent: (@MainActor (NetworkTransportEvent) -> Void)? { didSet { drain() } }
    var control: ((Data, NetworkPeerID) -> Void)?
    var ended: ((String) -> Void)?
    private var queued: [NetworkTransportEvent] = []
    private var bytes = 0
    private var closed = false
    init(_ base: any NetworkTransport) throws {
        guard base.onEvent == nil else { throw NetworkSessionError.transportInUse }
        self.base = base
        initialPeers = Set(base.connectedPeers.map(\.id))
        base.onEvent = { [weak self] event in self?.receive(event) }
    }
    func send(_ data: Data, to peer: NetworkPeerID, reliably: Bool) throws {
        guard !closed else { throw GameCenterError.disconnected }
        try base.send(data, to: peer, reliably: reliably)
    }
    func sendControl(_ packet: GameCenterPartyPacket, to peer: NetworkPeerID) throws {
        let data = try JSONEncoder().encode(packet)
        guard data.count <= 4096 else { throw GameCenterServiceError.capacityExceeded }
        try send(Self.prefix + data, to: peer, reliably: true)
    }
    func disconnect() { close(); base.disconnect() }
    func close() { closed = true; base.onEvent = nil; onEvent = nil; control = nil; ended = nil; queued = []; bytes = 0 }
    private func receive(_ event: NetworkTransportEvent) {
        guard !closed else { return }
        switch event {
        case .failed(let reason): ended?(reason)
        case .disconnected: ended?("A required party member left.")
        case .connected(let peer):
            if !initialPeers.contains(peer.id) { ended?("The party roster changed.") }
        case .received(let data, let sender):
            guard connectedPeers.contains(where: { $0.id == sender }) else { return }
            if data.starts(with: Self.prefix) {
                let payload = data.dropFirst(Self.prefix.count)
                guard payload.count <= 4096 else { ended?("A lobby packet exceeded its limit."); return }
                control?(Data(payload), sender)
            } else if let onEvent { onEvent(event) }
            else {
                guard data.count <= 48_000, queued.count < 64, bytes + data.count <= 196_608 else {
                    ended?("The party handoff buffer is full."); return
                }
                queued.append(event); bytes += data.count
            }
        }
    }
    private func drain() {
        guard let onEvent else { return }
        let events = queued; queued = []; bytes = 0
        for event in events where !closed { onEvent(event) }
    }
}
