import XCTest
import MultipeerConnectivity
@testable import VetaNative

final class ControllerNetworkTests: XCTestCase {
    func testStableSlotsDoNotReorderWhenOneControllerLeaves() {
        var slots = PlayerSlots()
        XCTAssertEqual(slots.assign("a", maximum: 4), 0)
        XCTAssertEqual(slots.assign("b", maximum: 4), 1)
        XCTAssertEqual(slots.assign("c", maximum: 4), 2)
        slots.remove("b")
        XCTAssertEqual(slots.assign("c", maximum: 4), 2)
        XCTAssertEqual(slots.assign("d", maximum: 4), 1)
        XCTAssertFalse(slots.move("d", to: 2, maximum: 4))
        XCTAssertFalse(slots.move("d", to: 4, maximum: 4))
        XCTAssertEqual(slots.assign("remote:e", maximum: 4, first: 1), 3)
        XCTAssertNil(slots.assign("remote:f", maximum: 4, first: 1))
    }
    func testOppositeDirectionsAndInvalidAxesAreNeutral() {
        XCTAssertEqual(ControllerInputState.neutralized(0xf0 | 0x100), 0x100)
        XCTAssertEqual(ControllerInputState.axis(CGPoint(x: 0.08, y: 0)), .zero)
        XCTAssertEqual(ControllerInputState.axis(CGPoint(x: CGFloat.nan, y: 0)), .zero)
        let diagonal = ControllerInputState.axis(CGPoint(x: 1, y: 1))
        XCTAssertEqual(hypot(diagonal.x, diagonal.y), 1, accuracy: 0.0001)
    }
    func testPacketRejectsOversizeMalformedVersionAndAxisRange() throws {
        let room = UUID()
        let valid = RemoteInputPacket(version: 1, kind: .input, session: room, console: "nes", slot: 1, sequence: 1, mask: 0x100, axes: [32767, 0, 0, 0])
        XCTAssertEqual(try RemoteInputPacket.decode(valid.encoded()), valid)
        XCTAssertThrowsError(try RemoteInputPacket.decode(Data(repeating: 0x41, count: 513)))
        XCTAssertThrowsError(try RemoteInputPacket.decode(Data("{}".utf8)))
        for invalid in [
            RemoteInputPacket(version: 2, kind: .input, session: room, console: "nes", slot: 1, sequence: 1, mask: 0, axes: [0, 0, 0, 0]),
            RemoteInputPacket(version: 1, kind: .input, session: room, console: "nes", slot: 0, sequence: 1, mask: 0, axes: [0, 0, 0, 0]),
            RemoteInputPacket(version: 1, kind: .input, session: room, console: "nes", slot: 1, sequence: 1, mask: 0, axes: [Int16.min, 0, 0, 0]),
            RemoteInputPacket(version: 1, kind: .input, session: room, console: "invalid", slot: 1, sequence: 1, mask: 0, axes: [0, 0, 0, 0])
        ] { XCTAssertThrowsError(try RemoteInputPacket.decode(invalid.encoded())) }
    }
    func testHostRejectsSpoofReplayStaleRoomAndDuplicateSlot() {
        let room = UUID()
        var gate = RemoteInputGate(session: room, console: "nes")
        XCTAssertTrue(gate.claim(peer: "guest", slot: 1))
        XCTAssertFalse(gate.claim(peer: "other", slot: 1))
        XCTAssertFalse(gate.claim(peer: "host-spoof", slot: 0))
        func packet(_ sequence: UInt64, room: UUID, slot: Int = 1) -> RemoteInputPacket { .init(version: 1, kind: .input, session: room, console: "nes", slot: slot, sequence: sequence, mask: 0x100, axes: [0, 0, 0, 0]) }
        XCTAssertNil(gate.accept(packet(1, room: room), from: "unknown", now: 1))
        XCTAssertNil(gate.accept(packet(1, room: UUID()), from: "guest", now: 1))
        XCTAssertNil(gate.accept(packet(1, room: room, slot: 2), from: "guest", now: 1))
        XCTAssertNotNil(gate.accept(packet(2, room: room), from: "guest", now: 1))
        XCTAssertNil(gate.accept(packet(2, room: room), from: "guest", now: 1.1))
        XCTAssertNil(gate.accept(packet(1, room: room), from: "guest", now: 1.1))
        XCTAssertTrue(gate.isFresh("guest", now: 1.7))
        XCTAssertFalse(gate.isFresh("guest", now: 1.8))
        gate.disconnect("guest")
        XCTAssertNil(gate.accept(packet(3, room: room), from: "guest", now: 2))
        XCTAssertTrue(gate.claim(peer: "replacement", slot: 1))
    }
    @MainActor func testMappingsKeepConsoleMeaningAndNoUnsupportedBits() {
        for console in GameConsole.allCases { XCTAssertEqual(ControllerHub.defaults(for: console).count, 12) }
        XCTAssertEqual(ControllerHub.defaults(for: .ps2).prefix(4), ["B", "A", "Y", "X"])
        XCTAssertEqual(ControllerHub.defaults(for: .megaDrive).prefix(4), ["B", "A", "Y", "X"])
        XCTAssertEqual(GameConsole.nes.buttonMask("—"), 0)
    }
    @MainActor func testTouchLayoutResizeReleasesHeldInput() {
        let deck = TouchDeck(frame: CGRect(x: 0, y: 0, width: 390, height: 320))
        var released = false
        deck.onInput = { if $0 == 0 { released = true } }
        deck.layoutIfNeeded()
        XCTAssertTrue(released)
        for console in GameConsole.allCases {
            deck.style = ControlStyle(console: console); deck.layoutIfNeeded()
            for rect in deck.zones.values { XCTAssertTrue(rect.width > 0 && rect.height > 0) }
        }
    }
}

/// Exercises Apple's real encrypted transport, not the packet validator alone.
/// A single simulator may not advertise to itself; in that case this bounded test
/// fails rather than reporting a fabricated two-device acceptance.
@MainActor private final class NearbyTransportProbe: NSObject, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    let token = UUID().uuidString
    let hostPeer = MCPeerID(displayName: "VETA-Test-Host")
    let guestPeer = MCPeerID(displayName: "VETA-Test-Guest")
    let host: MCSession
    let guest: MCSession
    let room = UUID()
    let connectedExpectation: XCTestExpectation
    let roundTripExpectation: XCTestExpectation
    let disconnectedExpectation: XCTestExpectation
    var advertiser: MCNearbyServiceAdvertiser?
    var browser: MCNearbyServiceBrowser?
    var gate: RemoteInputGate
    var connected = false
    var completed = false
    var cleared = false
    var failure: String?
    var hostInput = ControllerInputState()
    private var invited = false
    init(connected: XCTestExpectation, roundTrip: XCTestExpectation, disconnected: XCTestExpectation) {
        host = MCSession(peer: hostPeer, securityIdentity: nil, encryptionPreference: .required)
        guest = MCSession(peer: guestPeer, securityIdentity: nil, encryptionPreference: .required)
        gate = RemoteInputGate(session: room, console: "nes")
        connectedExpectation = connected; roundTripExpectation = roundTrip; disconnectedExpectation = disconnected
        super.init(); host.delegate = self; guest.delegate = self
    }
    func start() {
        advertiser = MCNearbyServiceAdvertiser(peer: hostPeer, discoveryInfo: ["probe": token], serviceType: "veta-play")
        browser = MCNearbyServiceBrowser(peer: guestPeer, serviceType: "veta-play")
        advertiser?.delegate = self; browser?.delegate = self
        advertiser?.startAdvertisingPeer(); browser?.startBrowsingForPeers()
    }
    func stop() { advertiser?.stopAdvertisingPeer(); browser?.stopBrowsingForPeers(); guest.disconnect(); host.disconnect() }
    private func fail(_ error: Error) {
        failure = error.localizedDescription
        if !connected { connectedExpectation.fulfill() }
    }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            guard info?["probe"] == self.token, peerID == self.hostPeer, !self.invited else { return }
            self.invited = true; browser.invitePeer(peerID, to: self.guest, withContext: Data(self.token.utf8), timeout: 15)
        }
    }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) { Task { @MainActor in self.fail(error) } }
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) { Task { @MainActor in self.fail(error) } }
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in invitationHandler(peerID == self.guestPeer && context == Data(self.token.utf8), self.host) }
    }
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            if session === self.host, state == .connected, !self.connected {
                guard self.gate.claim(peer: "guest", slot: 1) else { return }
                self.connected = true; self.connectedExpectation.fulfill()
                let welcome = RemoteInputPacket(version: 1, kind: .welcome, session: self.room, console: "nes", slot: 1, sequence: 0, mask: 0, axes: [0, 0, 0, 0])
                if let data = try? welcome.encoded() { try? session.send(data, toPeers: [peerID], with: .reliable) }
            } else if session === self.host, state == .notConnected, self.connected, !self.cleared {
                self.gate.disconnect("guest"); self.hostInput = ControllerInputState(); self.cleared = true; self.disconnectedExpectation.fulfill()
            }
        }
    }
    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            guard let packet = try? RemoteInputPacket.decode(data), packet.session == self.room else { return }
            if session === self.guest, peerID == self.hostPeer, packet.kind == .welcome {
                let input = RemoteInputPacket(version: 1, kind: .input, session: self.room, console: "nes", slot: 1, sequence: 1, mask: 0x180, axes: [16384, -8192, 0, 0])
                if let bytes = try? input.encoded() { try? session.send(bytes, toPeers: [peerID], with: .reliable) }
            } else if session === self.host, peerID == self.guestPeer, let state = self.gate.accept(packet, from: "guest", now: ProcessInfo.processInfo.systemUptime) {
                self.hostInput = state
                // Echo only after the host-authority gate accepted the snapshot.
                try? session.send(data, toPeers: [peerID], with: .reliable)
            } else if session === self.guest, peerID == self.hostPeer, packet.kind == .input, packet.sequence == 1, packet.mask == 0x180, !self.completed {
                self.completed = true; self.roundTripExpectation.fulfill()
            }
        }
    }
    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) { stream.close() }
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) { progress.cancel() }
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension ControllerNetworkTests {
    @MainActor func testEncryptedNearbyTransportRoundTripAndDisconnect() async throws {
        let connected = expectation(description: "Encrypted MCSession connected")
        let roundTrip = expectation(description: "Host validated and echoed input")
        let disconnected = expectation(description: "Disconnect clears host slot and keys")
        let probe = NearbyTransportProbe(connected: connected, roundTrip: roundTrip, disconnected: disconnected)
        defer { probe.stop() }
        XCTAssertEqual(probe.host.encryptionPreference, .required)
        XCTAssertEqual(probe.guest.encryptionPreference, .required)
        probe.start()
        await fulfillment(of: [connected], timeout: 20)
        XCTAssertNil(probe.failure)
        guard probe.connected else { return }
        await fulfillment(of: [roundTrip], timeout: 10)
        guard probe.completed else { return }
        XCTAssertEqual(probe.hostInput.mask, 0x180)
        XCTAssertEqual(probe.hostInput.axes[0].x, 16384.0 / 32767, accuracy: 0.0001)
        probe.guest.disconnect()
        await fulfillment(of: [disconnected], timeout: 10)
        XCTAssertTrue(probe.gate.claims.isEmpty)
        XCTAssertEqual(probe.hostInput, ControllerInputState())
    }
}
