import SwiftUI
import MultipeerConnectivity
import GameKit
import ImageIO

/// Only the active console's visual control preferences cross the room boundary.
/// Validate the complete snapshot before changing any guest preference.
struct RemoteControllerAppearance: Codable, Equatable {
    var version = 1
    var console: String
    var size: Double
    var opacity: Double
    var height: Double
    var spacing: Double
    var portraitPalette: ControllerSkinPalette
    var landscapePalette: ControllerSkinPalette
    var portraitLayout: ControllerSkinLayout?
    var landscapeLayout: ControllerSkinLayout?
    init(console: GameConsole, defaults: UserDefaults = .standard) {
        self.console = console.rawValue
        let style = ControlStyle(console: console, defaults: defaults)
        size = style.size; opacity = style.opacity; height = style.height; spacing = style.spacing
        let store = ControllerSkinStore(defaults: defaults)
        portraitPalette = store.palette(console: console, orientation: .portrait)
        landscapePalette = store.palette(console: console, orientation: .landscape)
        portraitLayout = store.layout(console: console, orientation: .portrait)
        landscapeLayout = store.layout(console: console, orientation: .landscape)
    }
    func validated(console expected: GameConsole) throws {
        guard version == 1, console == expected.rawValue,
              size.isFinite, (0.85...1.2).contains(size), opacity.isFinite, (0.4...1).contains(opacity),
              height.isFinite, (-0.12...0.12).contains(height), spacing.isFinite, (0.8...1.2).contains(spacing)
        else { throw RemoteProtocolError.invalid }
        try portraitLayout?.validated(console: expected, orientation: .portrait)
        try landscapeLayout?.validated(console: expected, orientation: .landscape)
        guard portraitLayout == nil || portraitLayout?.palette == portraitPalette,
              landscapeLayout == nil || landscapeLayout?.palette == landscapePalette else { throw RemoteProtocolError.invalid }
    }
    func apply(console: GameConsole, defaults: UserDefaults = .standard) throws {
        try validated(console: console)
        let store = ControllerSkinStore(defaults: defaults)
        for (orientation, palette, layout) in [(ControllerSkinOrientation.portrait, portraitPalette, portraitLayout), (.landscape, landscapePalette, landscapeLayout)] {
            store.reset(console: console, orientation: orientation)
            store.setPalette(palette, console: console, orientation: orientation)
            if let layout { try store.save(layout, console: console) }
        }
        let prefix = console.preferencePrefix
        defaults.set(portraitPalette.rawValue, forKey: prefix + "skin")
        defaults.set(size, forKey: prefix + "controlSize"); defaults.set(opacity, forKey: prefix + "controlOpacity")
        defaults.set(height, forKey: prefix + "controlHeight"); defaults.set(spacing, forKey: prefix + "controlSpacing")
    }
}

/// Full input snapshots, never deltas: a lost packet cannot leave a key held indefinitely.
struct RemoteInputPacket: Codable, Equatable {
    enum Kind: String, Codable { case hello, welcome, input, goodbye }
    let version: Int
    let kind: Kind
    let session: UUID
    let console: String
    let slot: Int
    let sequence: UInt64
    let mask: UInt16
    let axes: [Int16]
    var appearance: RemoteControllerAppearance? = nil
    static let maximumBytes = 512
    static let maximumWelcomeBytes = 32768
    func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= (kind == .welcome ? Self.maximumWelcomeBytes : Self.maximumBytes) else { throw RemoteProtocolError.invalid }
        return data
    }
    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumWelcomeBytes else { throw RemoteProtocolError.invalid }
        let packet = try JSONDecoder().decode(Self.self, from: data)
        guard packet.version == 1, (1..<4).contains(packet.slot), GameConsole(rawValue: packet.console) != nil, packet.axes.count == 4, !packet.axes.contains(Int16.min) else { throw RemoteProtocolError.invalid }
        guard packet.kind == .welcome || (data.count <= maximumBytes && packet.appearance == nil) else { throw RemoteProtocolError.invalid }
        if let appearance = packet.appearance, let console = GameConsole(rawValue: packet.console) { try appearance.validated(console: console) }
        return packet
    }
    var state: ControllerInputState {
        ControllerInputState(mask: ControllerInputState.neutralized(mask), axes: [CGPoint(x: Double(axes[0]) / 32767, y: Double(axes[1]) / 32767), CGPoint(x: Double(axes[2]) / 32767, y: Double(axes[3]) / 32767)])
    }
}
enum RemoteProtocolError: Error { case invalid }
struct RemoteInputGate {
    let session: UUID
    let console: String
    private(set) var claims: [String: Int] = [:]
    private var sequences: [String: UInt64] = [:]
    private var arrivals: [String: TimeInterval] = [:]
    init(session: UUID, console: String) { self.session = session; self.console = console }
    mutating func claim(peer: String, slot: Int) -> Bool {
        guard (1..<4).contains(slot), claims[peer] == nil, !claims.values.contains(slot) else { return false }
        claims[peer] = slot; return true
    }
    mutating func accept(_ packet: RemoteInputPacket, from peer: String, now: TimeInterval) -> ControllerInputState? {
        guard packet.kind == .input, packet.version == 1, packet.session == session, packet.console == console,
              claims[peer] == packet.slot, packet.axes.count == 4, !packet.axes.contains(Int16.min),
              packet.sequence > (sequences[peer] ?? 0), now.isFinite else { return nil }
        sequences[peer] = packet.sequence; arrivals[peer] = now
        return packet.state
    }
    mutating func disconnect(_ peer: String) { claims.removeValue(forKey: peer); sequences.removeValue(forKey: peer); arrivals.removeValue(forKey: peer) }
    func isFresh(_ peer: String, now: TimeInterval) -> Bool { arrivals[peer].map { now >= $0 && now - $0 < 0.75 } ?? false }
}

@MainActor final class PlayTogether: NSObject, ObservableObject {
    static let shared = PlayTogether()
    @Published private(set) var status = "Sin sesión compartida"
    @Published private(set) var isHosting = false
    @Published private(set) var isClient = false
    @Published private(set) var isJoining = false
    @Published private(set) var nearby: [MCPeerID] = []
    @Published private(set) var pendingInvitation: String?
    @Published private(set) var assignedSlot: Int?
    @Published private(set) var remoteImage: UIImage?
    @Published private(set) var console: GameConsole = .nes
    // Additional iPhones are controllers only; do not spend host time encoding previews.
    let shareVideo = false
    private let peer = MCPeerID(displayName: "VETA-" + String(UUID().uuidString.prefix(5)))
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var invitation: ((Bool, MCSession?) -> Void)?
    private var invitationExpiry: Task<Void, Never>?
    private var joinExpiry: Task<Void, Never>?
    private var hostPeer: MCPeerID?
    private var peerKeys: [MCPeerID: String] = [:]
    private var match: GKMatch?
    private var hostPlayer: GKPlayer?
    private var gate: RemoteInputGate?
    private var room: UUID?
    private var sequence: UInt64 = 0
    private var localState = ControllerInputState()
    private var heartbeat: Timer?
    private var lastVideo: TimeInterval = 0
    private var lastReceivedVideo: UInt64 = 0
    private var videoSequence: UInt64 = 0
    var onlineConfigured: Bool { FeatureAccess.onlineMultiplayerEnabled }
    private override init() { super.init() }
    private func makeSession() {
        let session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self; self.session = session
    }
    func hostNearby(console: GameConsole) {
        stop(); self.console = console
        ControllerHub.shared.configure(console: console, maxPlayers: console.maximumPlayers)
        guard ControllerHub.shared.maximumPlayers >= 2 else { status = "Este motor tiene un solo jugador local; no ofrece una segunda plaza para invitados."; return }
        guard ControllerHub.shared.guestCapacity > 0 else { status = "Todos los jugadores están asignados a mandos. Libera una plaza para invitar otro iPhone."; return }
        isHosting = true
        room = UUID(); gate = RemoteInputGate(session: room!, console: console.rawValue)
        makeSession()
        advertiser = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: ["version": "1", "console": console.rawValue], serviceType: "veta-play")
        advertiser?.delegate = self; advertiser?.startAdvertisingPeer()
        status = "Sala abierta. Abre el juego en este iPhone; los invitados controlan otros jugadores."
    }
    func browseNearby() {
        stop(); makeSession()
        browser = MCNearbyServiceBrowser(peer: peer, serviceType: "veta-play")
        browser?.delegate = self; browser?.startBrowsingForPeers(); status = "Buscando una sala VETA cercana…"
    }
    func join(_ target: MCPeerID) {
        guard let session, let browser, !isJoining, !isClient, !isHosting else { return }
        hostPeer = target; isJoining = true
        status = "Esperando aprobación del anfitrión…"
        browser.invitePeer(target, to: session, withContext: Data("VETA1".utf8), timeout: 60)
        joinExpiry?.cancel()
        joinExpiry = Task { @MainActor [weak self, weak session] in
            do { try await Task.sleep(nanoseconds: 65_000_000_000) } catch { return }
            guard !Task.isCancelled, let self, let session, self.session === session, self.isJoining else { return }
            self.stop(); self.status = "La sala rechazó la invitación o no está disponible."
        }
    }
    func approveInvitation(_ accept: Bool) {
        // Consume the response before invoking framework code: one decision per request.
        let respond = invitation
        invitation = nil; pendingInvitation = nil
        invitationExpiry?.cancel(); invitationExpiry = nil
        respond?(accept, accept ? session : nil)
    }
    private func welcome(peerID: String, send: (Data) -> Void) {
        guard isHosting, let room, let slot = gate?.claims[peerID] ?? ControllerHub.shared.reservePeer(peerID) else { status = "No hay plaza libre para otro jugador."; return }
        if gate?.claims[peerID] == nil, gate?.claim(peer: peerID, slot: slot) != true { ControllerHub.shared.releasePeer(peerID); return }
        let packet = RemoteInputPacket(version: 1, kind: .welcome, session: room, console: console.rawValue, slot: slot, sequence: 0, mask: 0, axes: [0, 0, 0, 0], appearance: RemoteControllerAppearance(console: console))
        if let data = try? packet.encoded() { send(data); status = L10n.format("Jugador %lld conectado · %@",slot+1,console.name) }
    }
    private func receive(_ data: Data, peerID: String, fromHost: Bool) {
        if data.starts(with: Data("VTV1".utf8)) { receiveVideo(data, fromHost: fromHost); return }
        guard let packet = try? RemoteInputPacket.decode(data) else { return }
        if isHosting {
            if packet.kind == .hello {
                welcome(peerID: peerID) { data in
                    if let target = self.peerKeys.first(where: { $0.value == peerID })?.key, let session = self.session { try? session.send(data, toPeers: [target], with: .reliable) }
                    else if let match = self.match, let player = match.players.first(where: { $0.gamePlayerID == peerID }) { try? match.send(data, to: [player], dataMode: .reliable) }
                }
                return
            }
            if packet.kind == .goodbye, packet.session == room, gate?.claims[peerID] == packet.slot { disconnected(peerID); return }
            if let input = gate?.accept(packet, from: peerID, now: ProcessInfo.processInfo.systemUptime) { ControllerHub.shared.setRemoteInput(peerID, state: input) }
        } else if fromHost, packet.kind == .welcome, let console = GameConsole(rawValue: packet.console) {
            guard !isClient, room == nil || room == packet.session else { return }
            if let appearance = packet.appearance { do { try appearance.apply(console: console) } catch { return } }
            room = packet.session; self.console = console; assignedSlot = packet.slot
            isClient = true; isJoining = false; joinExpiry?.cancel(); joinExpiry = nil; sequence = 0; status = L10n.format("Eres jugador %lld · %@",packet.slot+1,console.name)
            startHeartbeat()
        }
    }
    private func sendHello() {
        let packet = RemoteInputPacket(version: 1, kind: .hello, session: UUID(), console: console.rawValue, slot: 1, sequence: 0, mask: 0, axes: [0, 0, 0, 0])
        guard let data = try? packet.encoded() else { return }
        if let hostPeer, let session { try? session.send(data, toPeers: [hostPeer], with: .reliable) }
        else if let match, let hostPlayer { try? match.send(data, to: [hostPlayer], dataMode: .reliable) }
    }
    private func disconnected(_ peerID: String) {
        gate?.disconnect(peerID); ControllerHub.shared.releasePeer(peerID)
        if !isHosting { stop(); status = "Se perdió la conexión con el anfitrión." }
    }
    func setClientMask(_ value: UInt16) { localState.mask = value; sendInput() }
    func setClientAnalog(_ index: Int, _ value: CGPoint) {
        guard (0..<2).contains(index), value.x.isFinite, value.y.isFinite else { return }
        localState.axes[index] = CGPoint(x: max(-1, min(1, value.x)), y: max(-1, min(1, value.y))); sendInput()
    }
    func releaseClientInput() { localState = ControllerInputState(); sendInput() }
    private func startHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in Task { @MainActor in self?.sendInput() } }
    }
    private func sendInput() {
        guard isClient, let room, let assignedSlot, sequence < UInt64.max else { return }
        sequence += 1
        let axes = localState.axes.flatMap { [Int16(max(-1, min(1, $0.x)) * 32767), Int16(max(-1, min(1, $0.y)) * 32767)] }
        let packet = RemoteInputPacket(version: 1, kind: .input, session: room, console: console.rawValue, slot: assignedSlot, sequence: sequence, mask: localState.mask, axes: axes)
        guard let data = try? packet.encoded() else { return }
        if let hostPeer, let session { try? session.send(data, toPeers: [hostPeer], with: .unreliable) }
        else if let match, let hostPlayer { try? match.send(data, to: [hostPlayer], dataMode: .unreliable) }
    }
    func stop() {
        releaseClientInput(); heartbeat?.invalidate(); heartbeat = nil
        advertiser?.stopAdvertisingPeer(); browser?.stopBrowsingForPeers()
        approveInvitation(false)
        joinExpiry?.cancel(); joinExpiry = nil; isJoining = false
        session?.disconnect(); match?.disconnect()
        if let gate { for id in gate.claims.keys { ControllerHub.shared.releasePeer(id) } }
        advertiser = nil; browser = nil; session = nil; match = nil; hostPeer = nil; hostPlayer = nil
        peerKeys.removeAll(); gate = nil; room = nil; isHosting = false; isClient = false; assignedSlot = nil; nearby = []
        localState = ControllerInputState(); remoteImage = nil; lastReceivedVideo = 0; videoSequence = 0; status = "Sin sesión compartida"
    }
    /// Low bandwidth preview only. No claim of latency-equivalent remote play or remote audio.
    func publishFrame(_ image: CGImage) {
        guard isHosting, shareVideo, let gate, !gate.claims.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastVideo >= 0.2 else { return }; lastVideo = now
        let scale = min(1, 320 / CGFloat(max(image.width, image.height)))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let preview = UIGraphicsImageRenderer(size: size, format: format).image { _ in UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpeg = preview.jpegData(compressionQuality: 0.45), jpeg.count <= 48000, videoSequence < UInt64.max else { return }
        videoSequence += 1
        var data = Data("VTV1".utf8); var number = videoSequence.bigEndian
        withUnsafeBytes(of: &number) { data.append(contentsOf: $0) }; data.append(jpeg)
        if let session, !session.connectedPeers.isEmpty { try? session.send(data, toPeers: session.connectedPeers, with: .reliable) }
        else if let match { try? match.sendData(toAllPlayers: data, with: .reliable) }
    }
    private func receiveVideo(_ data: Data, fromHost: Bool) {
        guard isClient, fromHost, data.count > 12, data.count <= 48012 else { return }
        let number = data[4..<12].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard number > lastReceivedVideo else { return }
        let jpeg = data.subdata(in: 12..<data.count)
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 320, height <= 320,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        lastReceivedVideo = number; remoteImage = UIImage(cgImage: image)
    }
    func startOnline(console: GameConsole) {
        ControllerHub.shared.configure(console: console, maxPlayers: console.maximumPlayers)
        guard ControllerHub.shared.maximumPlayers >= 2 else { status = "Este motor no ofrece varias plazas locales."; return }
        guard onlineConfigured else { status = "Game Center requiere habilitar la capacidad y configurar la app en App Store Connect. No está activado en esta compilación."; return }
        stop(); self.console = console
        guard GKLocalPlayer.local.isAuthenticated else {
            GKLocalPlayer.local.authenticateHandler = { [weak self] controller, error in
                Task { @MainActor in
                    if let controller { self?.present(controller) }
                    else if let error { self?.status = error.localizedDescription }
                    else { self?.status = "Game Center conectado. Pulsa Buscar partida para continuar." }
                }
            }; return
        }
        let request = GKMatchRequest(); request.playerGroup = Int(console.coreIndex) + 1200; request.minPlayers = 2; request.maxPlayers = min(4, ControllerHub.shared.guestCapacity + 1)
        guard request.maxPlayers >= 2, let controller = GKMatchmakerViewController(matchRequest: request) else { status = "Este motor no ofrece varias plazas locales."; return }
        controller.matchmakerDelegate = self; present(controller)
    }
    private func present(_ controller: UIViewController) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }), var root = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        while let presented = root.presentedViewController { root = presented }; root.present(controller, animated: true)
    }
}

extension PlayTogether: MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate, MCSessionDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in
            guard self.advertiser === advertiser, self.isHosting, self.invitation == nil, ControllerHub.shared.guestCapacity > 0, context == Data("VETA1".utf8), (self.session?.connectedPeers.count ?? 0) < 3 else { invitationHandler(false, nil); return }
            self.invitation = invitationHandler; self.pendingInvitation = peerID.displayName
            self.invitationExpiry?.cancel()
            self.invitationExpiry = Task { @MainActor [weak self, weak advertiser] in
                do { try await Task.sleep(nanoseconds: 45_000_000_000) } catch { return }
                guard !Task.isCancelled, let self, let advertiser, self.advertiser === advertiser else { return }
                self.approveInvitation(false)
            }
        }
    }
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) { Task { @MainActor in self.status = error.localizedDescription } }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in if info?["version"] == "1", !self.nearby.contains(peerID) { self.nearby.append(peerID) } }
    }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) { Task { @MainActor in self.nearby.removeAll { $0 == peerID } } }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) { Task { @MainActor in self.status = error.localizedDescription } }
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            guard session === self.session else { return }
            if state == .connected {
                let key = self.peerKeys[peerID] ?? UUID().uuidString; self.peerKeys[peerID] = key
                if self.isHosting { self.welcome(peerID: key) { data in try? session.send(data, toPeers: [peerID], with: .reliable) } }
                else if peerID == self.hostPeer { self.sendHello() }
            } else if state == .notConnected {
                if let key = self.peerKeys.removeValue(forKey: peerID), self.isHosting || peerID == self.hostPeer { self.disconnected(key) }
                else if peerID == self.hostPeer { self.stop(); self.status = "La sala rechazó la invitación o no está disponible." }
            }
        }
    }
    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard data.count <= 48012 else { return }
        Task { @MainActor in
            guard session === self.session, session.connectedPeers.contains(peerID) else { return }
            let key = self.peerKeys[peerID] ?? UUID().uuidString; self.peerKeys[peerID] = key
            self.receive(data, peerID: key, fromHost: peerID == self.hostPeer)
        }
    }
    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) { stream.close() }
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) { progress.cancel() }
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
extension PlayTogether: GKMatchmakerViewControllerDelegate, GKMatchDelegate {
    nonisolated func matchmakerViewControllerWasCancelled(_ viewController: GKMatchmakerViewController) { Task { @MainActor in viewController.dismiss(animated: true) } }
    nonisolated func matchmakerViewController(_ viewController: GKMatchmakerViewController, didFailWithError error: Error) { Task { @MainActor in viewController.dismiss(animated: true); self.status = error.localizedDescription } }
    nonisolated func matchmakerViewController(_ viewController: GKMatchmakerViewController, didFind match: GKMatch) {
        Task { @MainActor in
            viewController.dismiss(animated: true); self.match = match; match.delegate = self
            let players = (match.players + [GKLocalPlayer.local]).sorted { $0.gamePlayerID < $1.gamePlayerID }
            self.hostPlayer = players.first; self.isHosting = players.first == GKLocalPlayer.local
            if self.isHosting {
                self.room = UUID(); self.gate = RemoteInputGate(session: self.room!, console: self.console.rawValue)
                for player in match.players { self.welcome(peerID: player.gamePlayerID) { data in try? match.send(data, to: [player], dataMode: .reliable) } }
                self.status = L10n.format("Eres anfitrión. Abre un juego de %@.",self.console.name)
            } else { self.status = "Conectando con el anfitrión…"; self.sendHello() }
        }
    }
    nonisolated func match(_ match: GKMatch, didReceive data: Data, fromRemotePlayer player: GKPlayer) { guard data.count <= 48012 else { return }; Task { @MainActor in guard match === self.match else { return }; self.receive(data, peerID: player.gamePlayerID, fromHost: player == self.hostPlayer) } }
    nonisolated func match(_ match: GKMatch, player: GKPlayer, didChange state: GKPlayerConnectionState) { Task { @MainActor in if state == .disconnected, self.isHosting || player == self.hostPlayer { self.disconnected(player.gamePlayerID) } } }
    nonisolated func match(_ match: GKMatch, didFailWithError error: Error?) { Task { @MainActor in self.stop(); self.status = error?.localizedDescription ?? "La partida terminó." } }
}

/// Uses the same console skin, touch geometry and safe areas as local play.
/// This is a full-screen controller, never a scrollable form containing buttons.
private final class RemoteControllerViewController: UIViewController {
    let console: GameConsole
    var onMenu: (() -> Void)?
    private let deck = TouchDeck()
    private let shell = ConsoleShellView()
    private let guidance = UILabel()
    private let identity = UILabel()
    private let menu = UIButton(type: .system)
    init(console: GameConsole) { self.console = console; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override func viewDidLoad() {
        super.viewDidLoad()
        [shell, guidance, deck, identity, menu].forEach(view.addSubview)
        guidance.numberOfLines = 0; guidance.textAlignment = .center
        guidance.font = .preferredFont(forTextStyle: .body); guidance.adjustsFontForContentSizeCategory = true
        guidance.textColor = .white
        guidance.text = L10n.text("Mira el juego en el iPhone anfitrión o en la TV. Gira este iPhone para usar el mando horizontal.")
        identity.font = .preferredFont(forTextStyle: .headline); identity.adjustsFontSizeToFitWidth = true
        identity.accessibilityIdentifier = "remote-player-status"
        menu.setTitle(L10n.text("Menú"), for: .normal)
        menu.accessibilityIdentifier = "remote-controller-menu"
        menu.addAction(UIAction { [weak self] _ in self?.deck.releaseAll(); PlayTogether.shared.releaseClientInput(); self?.onMenu?() }, for: .touchUpInside)
        deck.onInput = { PlayTogether.shared.setClientMask($0) }
        deck.onAnalog = { PlayTogether.shared.setClientAnalog($0, $1) }
    }
    private var lastRevision: Int?
    func refresh(status: String, revision: Int) {
        loadViewIfNeeded()
        identity.text = L10n.text(status)
        if lastRevision != revision { lastRevision = revision; view.setNeedsLayout() }
        // Frame delivery must not relayout or release a held controller button.
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.safeAreaLayoutGuide.layoutFrame
        let landscape = safe.width > safe.height
        deck.applySkin(console: console, landscape: landscape)
        let layout = ConsoleLayout(safe: safe, aspect: console.aspect, minimumDeck: console.minimumDeck, overlayLandscape: deck.usesLandscapeOverlay, compactDS: deck.customLayout?.usesCompactDSCanvas == true)
        deck.frame = layout.deck
        shell.frame = view.bounds; shell.style = deck.style; shell.screenRect = layout.screen
        shell.portraitSkinTop = landscape ? nil : layout.toolbar.minY; shell.setNeedsDisplay()
        shell.isHidden = deck.usesLandscapeOverlay
        view.backgroundColor = deck.usesLandscapeOverlay ? .black : deck.style.background
        let rail = ControllerSkinGeometry.overlayRail(safe.size)
        let center = deck.usesLandscapeOverlay
            ? CGRect(x: safe.minX + rail + 8, y: safe.minY + 60, width: max(1, safe.width - 2 * rail - 16), height: max(1, safe.height - 120))
            : layout.screen.insetBy(dx: 24, dy: 16)
        guidance.frame = center
        menu.frame = deck.usesLandscapeOverlay ? layout.toolbar : CGRect(x: layout.toolbar.maxX - 94, y: layout.toolbar.minY, width: 88, height: 44)
        menu.backgroundColor = deck.usesLandscapeOverlay ? UIColor(white: 0.16, alpha: 1) : .clear
        menu.tintColor = deck.usesLandscapeOverlay ? .white : deck.style.headerInk; menu.layer.cornerRadius = 8
        identity.isHidden = deck.usesLandscapeOverlay
        identity.frame = CGRect(x: layout.toolbar.minX + 16, y: layout.toolbar.minY, width: max(1, layout.toolbar.width - 120), height: 44)
        identity.textColor = deck.style.headerInk
    }
    func releaseInput() { deck.releaseAll(); PlayTogether.shared.releaseClientInput() }
    override func viewWillDisappear(_ animated: Bool) { releaseInput(); super.viewWillDisappear(animated) }
}
private struct RemoteControllerSurface: UIViewControllerRepresentable {
    let console: GameConsole
    let status: String
    let onMenu: () -> Void
    let revision: Int
    func makeUIViewController(context: Context) -> RemoteControllerViewController { RemoteControllerViewController(console: console) }
    func updateUIViewController(_ view: RemoteControllerViewController, context: Context) {
        view.onMenu = onMenu; view.refresh(status: status, revision: revision)
    }
    static func dismantleUIViewController(_ view: RemoteControllerViewController, coordinator: ()) { view.releaseInput() }
}
private struct RemoteControllerScreen: View {
    @ObservedObject private var room = PlayTogether.shared
    @Environment(\.scenePhase) private var phase
    @State private var showMenu = false
    @State private var showControls = false
    @State private var revision = 0
    @State private var previousIdleTimerDisabled: Bool?
    var body: some View {
        RemoteControllerSurface(console: room.console, status: room.status, onMenu: { showMenu = true }, revision: revision)
            .ignoresSafeArea().statusBarHidden(true)
            .confirmationDialog("Menú", isPresented: $showMenu, titleVisibility: .visible) {
                Button("Skins y controles") { showControls = true }
                Button("Cerrar conexión", role: .destructive) { room.stop() }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text(L10n.text(room.status))
            }
            .sheet(isPresented: $showControls, onDismiss: { revision += 1 }) { ControlsSettings(console: room.console) }
            .onAppear { previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true }
            .onDisappear {
                room.releaseClientInput()
                if let previousIdleTimerDisabled { UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled }
            }
            .onChange(of: phase) { phase in if phase != .active { room.releaseClientInput() } }
    }
}
struct PlayTogetherView: View {
    let console: GameConsole
    @ObservedObject private var room = PlayTogether.shared
    @Environment(\.scenePhase) private var phase
    @State private var previousIdleTimerDisabled: Bool?
    private var keepsScreenAwake: Bool { room.isHosting || room.isClient || room.isJoining }
    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text(L10n.text(room.status)).font(.headline).frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("nearby-status")
                if let pending = room.pendingInvitation {
                    VStack(spacing: 12) {
                        Text(L10n.format("%@ quiere entrar", pending)).font(.headline)
                        Button("Aceptar") { room.approveInvitation(true) }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .frame(minHeight: 44).accessibilityIdentifier("nearby-accept")
                        Button("Rechazar", role: .cancel) { room.approveInvitation(false) }
                            .buttonStyle(.bordered).controlSize(.large)
                            .frame(minHeight: 44).accessibilityIdentifier("nearby-reject")
                    }.frame(maxWidth: .infinity).padding().background(VetaTheme.panel, in: RoundedRectangle(cornerRadius: 12))
                }
                if room.isJoining { ProgressView().accessibilityLabel(Text(L10n.text(room.status))) }
                if room.isClient {
                    Text("Mira el juego en el iPhone anfitrión o en la TV. Gira este iPhone para usar el mando horizontal.")
                } else {
                    Button("Crear sala cercana") { room.hostNearby(console: console) }.buttonStyle(.borderedProminent).disabled(console.maximumPlayers < 2 || room.isJoining || room.isHosting)
                    Button("Usar este iPhone como mando") { room.browseNearby() }.buttonStyle(.bordered).disabled(room.isJoining || room.isHosting)
                    ForEach(room.nearby, id: \.self) { peer in Button(L10n.format("Unirse a %@",peer.displayName)) { room.join(peer) }.disabled(room.isJoining).accessibilityIdentifier("nearby-join") }
                    if room.onlineConfigured {
                        Button("Buscar partida por Game Center") { room.startOnline(console: console) }.buttonStyle(.bordered).disabled(console.maximumPlayers < 2 || room.isJoining || room.isHosting)
                    }
                    if console.maximumPlayers < 2 { Text(L10n.format("%@ tiene una sola plaza local en este motor. Puedes usar este teléfono para unirte a una sala de otra consola.",console.name)).font(.caption) }
                    Text("El anfitrión ejecuta el juego y conserva las partidas. Cada invitado recibe una plaza libre. La consola y el juego deben admitir varios jugadores. Ambos iPhone necesitan VETA; Android todavía no tiene cliente.").font(.footnote)
                }
                Button("Cerrar conexión", role: .destructive) { room.stop() }
            }.padding()
        }.background(VetaTheme.background).tint(VetaTheme.mint).navigationTitle("Jugar juntos").navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(isPresented: Binding(get: { room.isClient }, set: { if !$0 && room.isClient { room.stop() } })) {
                RemoteControllerScreen()
            }
            .onChange(of: phase) { phase in if phase != .active { room.releaseClientInput() } }
            .onAppear {
                previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
                if keepsScreenAwake { UIApplication.shared.isIdleTimerDisabled = true }
            }
            .onChange(of: keepsScreenAwake) { active in
                UIApplication.shared.isIdleTimerDisabled = active || (previousIdleTimerDisabled ?? false)
            }
            .onDisappear {
                room.releaseClientInput()
                if let previousIdleTimerDisabled { UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled }
                previousIdleTimerDisabled = nil
            }
    }
}
