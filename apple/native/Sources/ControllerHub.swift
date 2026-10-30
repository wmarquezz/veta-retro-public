import SwiftUI
import GameController
import CoreHaptics

struct ControllerInputState: Equatable {
    var mask: UInt16 = 0
    var axes: [CGPoint] = [.zero, .zero]
    static func neutralized(_ value: UInt16) -> UInt16 {
        var mask = value
        if mask & 0x30 == 0x30 { mask &= ~0x30 }
        if mask & 0xc0 == 0xc0 { mask &= ~0xc0 }
        return mask
    }
    static func axis(_ value: CGPoint, deadzone: CGFloat = 0.14) -> CGPoint {
        guard value.x.isFinite, value.y.isFinite else { return .zero }
        let length = hypot(value.x, value.y)
        guard length > deadzone else { return .zero }
        let magnitude = min(1, (length - deadzone) / (1 - deadzone))
        return CGPoint(x: value.x / length * magnitude, y: value.y / length * magnitude)
    }
}

enum ControllerDisplayPolicy {
    static func fullscreen(ports: [Int], maximumPlayers: Int, enabled: Bool, phoneIsControl: Bool) -> Bool {
        enabled && !phoneIsControl && maximumPlayers > 0 && ports.contains(0)
    }
    static func frame(safe: CGRect, aspect: CGFloat) -> CGRect {
        guard aspect.isFinite, aspect > 0 else { return safe }
        let width = min(safe.width, safe.height * aspect), height = width / aspect
        return CGRect(x:safe.midX-width/2,y:safe.midY-height/2,width:width,height:height)
    }
}

/// Allocation survives enumeration changes; a disconnect frees only its own port.
struct PlayerSlots {
    private(set) var owners: [String: Int] = [:]
    mutating func assign(_ owner: String, maximum: Int, first: Int = 0) -> Int? {
        if let existing = owners[owner], existing < maximum { return existing }
        guard let port = (max(0, first)..<max(first, min(4, maximum))).first(where: { !owners.values.contains($0) }) else { return nil }
        owners[owner] = port; return port
    }
    mutating func move(_ owner: String, to port: Int, maximum: Int) -> Bool {
        guard (0..<min(4, maximum)).contains(port), !owners.contains(where: { $0.key != owner && $0.value == port }) else { return false }
        owners[owner] = port; return true
    }
    mutating func remove(_ owner: String) { owners.removeValue(forKey: owner) }
    mutating func trim(maximum: Int) { owners = owners.filter { $0.value < maximum } }
}

@MainActor final class ControllerHub: ObservableObject {
    static let shared = ControllerHub()
    struct Device: Identifiable {
        let id: String
        let name: String
        let port: Int
        let controller: GCController
    }
    @Published private(set) var devices: [Device] = []
    @Published private(set) var remotePlayers: [String: Int] = [:]
    @Published private(set) var maximumPlayers = 2
    @Published var controllerRumble = UserDefaults.standard.object(forKey: "native.controllerRumble") as? Bool ?? true {
        didSet { UserDefaults.standard.set(controllerRumble, forKey: "native.controllerRumble"); if !controllerRumble { stopRumble() } }
    }
    @Published var phoneRumble = UserDefaults.standard.object(forKey: "native.phoneGameRumble") as? Bool ?? true {
        didSet { UserDefaults.standard.set(phoneRumble, forKey: "native.phoneGameRumble"); if !phoneRumble { stopRumble() } }
    }
    private var slots = PlayerSlots()
    private var controllers: [String: GCController] = [:]
    private var remoteInputs: [String: (ControllerInputState, TimeInterval)] = [:]
    private var observers: [NSObjectProtocol] = []
    private var rumbleEngines: [String: CHHapticEngine] = [:]
    private var rumblePlayers: [String: CHHapticPatternPlayer] = [:]
    private var lastRumble: [String: TimeInterval] = [:]
    private var console: GameConsole = .nes
    var guestCapacity: Int { (1..<maximumPlayers).filter { !slots.owners.values.contains($0) }.count }
    static let physicalButtons = ["A", "B", "X", "Y", "L1", "R1", "L2", "R2", "Options", "Menu", "L3", "R3"]
    private init() {
        for name in [NSNotification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reconcile() }
            })
        }
        reconcile()
    }
    func configure(console: GameConsole, maxPlayers: Int) {
        self.console = console; maximumPlayers = max(1, min(4, maxPlayers))
        for (id, port) in slots.owners where id.hasPrefix("remote:") && port >= maximumPlayers {
            slots.remove(id); remoteInputs.removeValue(forKey: id)
        }
        reconcile()
    }
    private func reconcile() {
        let connected = GCController.controllers().filter { $0.extendedGamepad != nil }
        let ids = Set(connected.map { "pad:\(ObjectIdentifier($0))" })
        for id in Array(controllers.keys) where !ids.contains(id) {
            slots.remove(id); controllers.removeValue(forKey: id)
            try? rumblePlayers.removeValue(forKey: id)?.stop(atTime: 0)
            rumbleEngines.removeValue(forKey: id)?.stop(completionHandler: nil)
        }
        for controller in connected {
            let id = "pad:\(ObjectIdentifier(controller))"
            controllers[id] = controller
            _ = slots.assign(id, maximum: 4)
        }
        refreshDevices()
    }
    private func refreshDevices() {
        devices = controllers.compactMap { id, controller in
            guard let port = slots.owners[id] else { controller.playerIndex = .indexUnset; return nil }
            controller.playerIndex = GCControllerPlayerIndex(rawValue: port) ?? .indexUnset
            return Device(id: id, name: controller.vendorName ?? controller.productCategory, port: port, controller: controller)
        }.sorted { $0.port < $1.port }
        remotePlayers = slots.owners.filter { $0.key.hasPrefix("remote:") }
    }
    func moveController(_ id: String, to port: Int) {
        if slots.move(id, to: port, maximum: maximumPlayers) { refreshDevices() }
    }
    func reservePeer(_ peer: String) -> Int? {
        let id = "remote:" + peer
        // Host phone owns player 1; guests never overwrite it.
        let port = slots.assign(id, maximum: maximumPlayers, first: 1)
        refreshDevices(); return port
    }
    func setRemoteInput(_ peer: String, state: ControllerInputState) {
        let id = "remote:" + peer
        guard slots.owners[id] != nil, state.axes.count == 2 else { return }
        remoteInputs[id] = (state, ProcessInfo.processInfo.systemUptime)
    }
    func releasePeer(_ peer: String) {
        let id = "remote:" + peer
        slots.remove(id); remoteInputs.removeValue(forKey: id); refreshDevices()
    }
    func isConnected(port:Int)->Bool {
        (0..<maximumPlayers).contains(port) && (port==0 || devices.contains{$0.port==port} || remotePlayers.values.contains(port))
    }
    func releaseAll() { remoteInputs.removeAll(); stopRumble() }
    private func stopRumble() {
        for player in rumblePlayers.values { try? player.stop(atTime: 0) }
        rumblePlayers.removeAll(); lastRumble.removeAll()
    }
    static func defaults(for console: GameConsole) -> [String] {
        #if VETA_JIT_DEVELOPMENT
        if console.isStandaloneEngine {return ["B","A","Y","X","L","R","L2","R2","SELECT","START","L3","R3"]}
        #endif
        switch console {
        case .n64: return ["A", "B", "C←", "C↑", "L", "R", "Z", "R", "START", "START", "Z", "R"]
        case .gamecube: return ["A", "B", "X", "Y", "L", "Z", "L", "R", "START", "START", "L", "R"]
        case .dreamcast: return ["A", "B", "X", "Y", "L", "R", "L", "R", "START", "START", "L", "R"]
        case .wii: return ["A", "B", "C", "Z", "−", "+", "SHAKE", "SHAKE", "2", "1", "HOME", "HOME"]
        case .ps1, .ps2, .psp, .threeDS: return ["B", "A", "Y", "X", "L", "R", "L2", "R2", "SELECT", "START", "L3", "R3"]
        case .megaDrive, .saturn: return ["B", "A", "Y", "X", "Z", "C", "L", "R", "SELECT", "START", "L3", "R3"]
        default: return ["A", "B", console.fourButtons ? "Y" : "B", "X", "L", "R", "L2", "R2", "SELECT", "START", "L3", "R3"]
        }
    }
    private func mappingKey(_ device: Device, console: GameConsole) -> String { "native.mapping.\(console.rawValue).\(device.name)" }
    func mapping(_ device: Device, console: GameConsole) -> [String] {
        let saved = UserDefaults.standard.stringArray(forKey: mappingKey(device, console: console))
        return saved?.count == 12 ? saved! : Self.defaults(for: console)
    }
    func remap(_ device: Device, console: GameConsole, index: Int, action: String) {
        guard (0..<12).contains(index), action == "—" || console.buttonMask(action) != 0 else { return }
        var values = mapping(device, console: console); values[index] = action
        UserDefaults.standard.set(values, forKey: mappingKey(device, console: console)); objectWillChange.send()
    }
    func resetMapping(_ device: Device, console: GameConsole) {
        UserDefaults.standard.removeObject(forKey: mappingKey(device, console: console)); objectWillChange.send()
    }
    static func input(pad: GCExtendedGamepad, console: GameConsole, mapping: [String]) -> ControllerInputState {
        var result = ControllerInputState()
        let buttons = [pad.buttonA, pad.buttonB, pad.buttonX, pad.buttonY, pad.leftShoulder, pad.rightShoulder, pad.leftTrigger, pad.rightTrigger, pad.buttonOptions, pad.buttonMenu, pad.leftThumbstickButton, pad.rightThumbstickButton]
        for (button, action) in zip(buttons, mapping) where button?.isPressed == true { result.mask |= console.buttonMask(action) }
        let dpad = [(pad.dpad.up.isPressed || (console.analogSticks == 0 && pad.leftThumbstick.yAxis.value > 0.5), 4), (pad.dpad.down.isPressed || (console.analogSticks == 0 && pad.leftThumbstick.yAxis.value < -0.5), 5), (pad.dpad.left.isPressed || (console.analogSticks == 0 && pad.leftThumbstick.xAxis.value < -0.5), 6), (pad.dpad.right.isPressed || (console.analogSticks == 0 && pad.leftThumbstick.xAxis.value > 0.5), 7)]
        for (down, bit) in dpad where down { result.mask |= UInt16(1 << bit) }
        for (i, stick) in [pad.leftThumbstick, pad.rightThumbstick].enumerated() where i < console.analogSticks {
            result.axes[i] = ControllerInputState.axis(CGPoint(x: CGFloat(stick.xAxis.value), y: -CGFloat(stick.yAxis.value)))
        }
        if console == .n64 {
            let x = pad.rightThumbstick.xAxis.value, y = pad.rightThumbstick.yAxis.value
            for (pressed, action) in [(x < -0.5,"C←"),(x > 0.5,"C→"),(y > 0.5,"C↑"),(y < -0.5,"C↓")] where pressed { result.mask |= console.buttonMask(action) }
        }
        return result
    }
    func inputs(console: GameConsole, touchMask: UInt16, touchAnalog: [CGPoint], running: Bool) -> [ControllerInputState] {
        var result = Array(repeating: ControllerInputState(), count: 4)
        guard running else { return result }
        result[0].mask = touchMask
        for i in 0..<min(2, touchAnalog.count) { result[0].axes[i] = touchAnalog[i] }
        for device in devices {
            guard device.port < maximumPlayers, let pad = device.controller.extendedGamepad else { continue }
            let physical = Self.input(pad: pad, console: console, mapping: mapping(device, console: console))
            result[device.port].mask |= physical.mask
            for i in 0..<2 where physical.axes[i] != .zero { result[device.port].axes[i] = physical.axes[i] }

        }
        let now = ProcessInfo.processInfo.systemUptime
        for (peer, entry) in remoteInputs where now - entry.1 < 0.75 {
            if let port = slots.owners[peer], port < maximumPlayers { result[port] = entry.0 }
        }
        for i in 0..<4 { result[i].mask = ControllerInputState.neutralized(result[i].mask) }
        return result
    }
    func applyRumble(port: Int, strong: UInt16, weak: UInt16) {
        let device = devices.first(where: { $0.port == port })
        let id: String
        if let device {
            guard controllerRumble, device.controller.haptics != nil else { return }
            id=device.id
        } else {
            // Only local player 1 uses the phone. Never redirect another
            // player's feedback or an unsupported controller to this handset.
            guard port == 0,phoneRumble,CHHapticEngine.capabilitiesForHardware().supportsHaptics else {return}
            id="veta-phone-guest-rumble"
        }
        let strength = Float(max(strong, weak)) / 65535
        if strength == 0 { try? rumblePlayers.removeValue(forKey: id)?.stop(atTime: 0); lastRumble.removeValue(forKey:id); return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - (lastRumble[id] ?? 0) >= 0.12 else { return }
        lastRumble[id] = now
        do {
            if rumbleEngines[id] == nil {
                if let device {rumbleEngines[id]=device.controller.haptics?.createEngine(withLocality:.default)}
                else {rumbleEngines[id]=try CHHapticEngine()}
            }
            guard let engine = rumbleEngines[id] else { return }
            try engine.start()
            try? rumblePlayers[id]?.stop(atTime: 0)
            let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: strength), CHHapticEventParameter(parameterID: .hapticSharpness, value: strong > weak ? 0.2 : 0.8)], relativeTime: 0, duration: 0.15)
            let player = try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: []))
            rumblePlayers[id] = player; try player.start(atTime: 0)
        } catch { rumbleEngines.removeValue(forKey: id) }
    }
}

struct ControllerSettingsView: View {
    let console: GameConsole
    var supportsRumble=true
    @ObservedObject private var hub = ControllerHub.shared
    @AppStorage("native.fullscreenWithController") private var fullScreen = true
    var body: some View {
        Form {
            Section {
                Text("Conecta un mando desde Ajustes → Bluetooth. La disponibilidad de jugadores depende de la consola y del juego.")
                Text("Con un mando para el jugador 1, la imagen se amplía y los controles táctiles se ocultan. Al desconectarlo, vuelven a aparecer.").font(.footnote)
                if [.ds,.threeDS,.wii].contains(console) { Text("Algunos juegos todavía necesitan tocar la pantalla o usar funciones especiales de la consola.").font(.footnote) }
                if console == .n64 { Text("Nintendo 64: el stick derecho controla los cuatro botones C.").font(.footnote) }
                Text(L10n.format("Pantalla táctil: jugador 1 · Hasta %lld jugadores en este motor",hub.maximumPlayers))
                if supportsRumble {
                    Toggle("Vibración del mando", isOn: $hub.controllerRumble)
                    Toggle("Vibración del juego en el iPhone", isOn: $hub.phoneRumble)
                }
                Toggle("Pantalla completa con mando", isOn: $fullScreen).onChange(of: fullScreen) { _ in hub.objectWillChange.send() }
            }
            ForEach(hub.devices) { device in
                Section(device.name) {
                    Picker("Jugador", selection: Binding(get: { device.port }, set: { hub.moveController(device.id, to: $0) })) {
                        ForEach(0..<hub.maximumPlayers, id: \.self) { index in Text(L10n.format("Jugador %lld",index+1)).tag(index) }
                    }
                    ForEach(Array(ControllerHub.physicalButtons.enumerated()), id: \.offset) { index, label in
                        Picker(label, selection: Binding(get: { hub.mapping(device, console: console)[index] }, set: { hub.remap(device, console: console, index: index, action: $0) })) {
                            ForEach(["—", "A", "B", "C", "X", "Y", "Z", "L", "R", "L2", "R2", "L3", "R3", "C↑", "C↓", "C←", "C→", "START", "SELECT", "1", "2", "−", "+", "HOME", "SHAKE"].filter { $0 == "—" || console.buttonMask($0) != 0 }, id: \.self) { Text(L10n.controlName($0)).tag($0) }
                        }
                    }
                    Button("Restablecer botones") { hub.resetMapping(device, console: console) }
                    Text("El mapa se conserva para los mandos de este modelo y esta consola.").font(.caption)
                }
            }
            if hub.devices.isEmpty { Section { Text("No hay mandos compatibles conectados.") } }
            Section { Text("PS4, PS5, Xbox y mandos reconocidos por iOS. Un mando PS3 o genérico solo aparecerá si iOS lo reconoce; no se promete compatibilidad universal.").font(.footnote) }
        }.vetaForm().tint(VetaTheme.mint).navigationTitle("Mandos y jugadores").navigationBarTitleDisplayMode(.inline)
            .onAppear { hub.configure(console: console, maxPlayers: console.maximumPlayers) }
    }
}
