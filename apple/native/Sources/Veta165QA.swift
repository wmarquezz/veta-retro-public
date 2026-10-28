#if VETA_JIT_DEVELOPMENT
import SwiftUI
import Darwin

// Explicit development launch only. Performance sessions require the existing
// isolated-save switch and never select JIT. No normal launch enters this view.
struct Veta165QAView: View {
    @ObservedObject var library: Library
    @State private var game: Game?
    @State private var message = String("QA 165")
    @State private var generation = 0
    var body: some View {
        Group {
            if let game { Veta165QAPlayer(game: game, library: library, generation: generation, restart: { generation += 1 }).id(generation) }
            else { Text(verbatim: message).padding() }
        }.task {
            let env = ProcessInfo.processInfo.environment
            do {
                if env["VETA_PERF165_IMPORT"] == "1" || env["VETA_PERF165_IMPORT"] == "coverage" {
                    let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Veta165Import")
                    let imports: [(String, GameConsole)] = env["VETA_PERF165_IMPORT"] == "coverage"
                        ? [("Super Smash Bros. Melee [GameCube].iso", .gamecube), ("The Legend of Zelda - The Wind Waker [GameCube].iso", .gamecube)]
                        : [("Marvel vs. Capcom 2 [Dreamcast].chd", .dreamcast), ("Mario Kart Double Dash [GameCube].iso", .gamecube)]
                    for (file, console) in imports {
                        try library.importURL(root.appendingPathComponent(file), console: console)
                    }
                    message = String(format: "QA IMPORT PASS · %d", library.games.count)
                } else {
                    guard env["VETA_TV158_QA_PRIMARY"] == "1", let id = env["VETA_PERF165_GAME"],
                          let selected = library.games.first(where: { $0.id == id }),
                          [.dreamcast, .gamecube, .wii, .n64, .threeDS].contains(selected.console) else {
                        message = String("QA requires isolated saves and an explicit game"); return
                    }
                    game = selected
                }
            } catch { message = String("QA ERROR · ") + error.localizedDescription }
        }
    }
}

private struct Veta165QAPlayer: View {
    private let generation: Int
    private let restart: () -> Void
    @StateObject private var session: Emulation
    @State private var revision = 0
    @State private var inputBusy = false
    @State private var rows: [[String: Any]] = []
    @State private var sampleNumber = 0
    @State private var selectedPort = 0
    @State private var qaPeers: [Int: String] = [:]
    @State private var captureNumber = 0
    private var multiplayerQA: Bool { ProcessInfo.processInfo.environment["VETA_PERF165_MULTIPLAYER"] == "1" }
    init(game: Game, library: Library, generation: Int, restart: @escaping () -> Void) {
        self.generation = generation; self.restart = restart
        let plan = GameLaunchPlan.resolve(console: game.console, snapshot: DeviceReadiness.capture().snapshot, preference: .automatic)
        _session = StateObject(wrappedValue: Emulation(game: game, library: library, plan: plan))
    }
    var body: some View {
        GameSurface(session: session, skin: "Clásica", revision: revision).ignoresSafeArea()
            .overlay(alignment: .top) {
                ScrollView(.horizontal) {
                    HStack {
                        if multiplayerQA {
                            ForEach(0..<min(4, Int(veta_max_players(session.game.coreIndex))), id: \.self) { port in
                                Button { selectedPort = port } label: { Text(verbatim: "QA P" + String(port + 1)).padding(8) }
                            }
                        }
                        ForEach(["START", "A", "B", "UP", "DOWN", "LEFT", "RIGHT", "DRIVE", "DRIVE LEFT", "DRIVE RIGHT"] + (session.game.console == .wii ? ["1", "2", "+", "STICK UP", "STICK DOWN", "STICK LEFT", "STICK RIGHT"] : []) + (multiplayerQA ? ["DRIVE ALL"] : []), id: \.self) { name in
                            Button { pulse(name) } label: { Text(verbatim: "QA " + name).padding(8) }
                        }
                        Button { session.close(); restart() } label: { Text(verbatim: "QA REOPEN").padding(8) }
                        Button { captureFrame() } label: { Text(verbatim: "QA CAPTURE").padding(8) }
                    }.buttonStyle(.borderedProminent).disabled(inputBusy || !session.ready)
                }.padding(.top, 48)
            }
            .sheet(isPresented: $session.showMenu, onDismiss: { revision += 1; session.resume() }) {
                PauseView(session: session, leave: { session.close(); session.showMenu = false })
                    .interactiveDismissDisabled()
            }
            .task {
                let name = ProcessInfo.processInfo.environment["VETA_PERF165_RUN"] ?? "unknown"
                guard name.count <= 48, name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }) else { return }
                let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Veta165Perf")
                do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) } catch { return }
                while !Task.isCancelled {
                    if multiplayerQA && session.ready && qaPeers.isEmpty {
                        // Synthetic peers exercise actual controller ports and split-screen
                        // rendering. They do not establish network/multi-phone acceptance.
                        for port in 1..<min(4, Int(veta_max_players(session.game.coreIndex))) {
                            let peer = "qa165-" + UUID().uuidString
                            if ControllerHub.shared.reservePeer(peer) == port { qaPeers[port] = peer }
                            else { ControllerHub.shared.releasePeer(peer) }
                        }
                    }
                    sampleNumber += 1
                    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
                    let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
                    let readback = veta_video_readback_profile()
                    let sharedVideo = veta_shared_video_profile()
                    rows.append(["time": ProcessInfo.processInfo.systemUptime, "cpu": cpu,
                                 "readback": ["profiling": readback.profiling, "enabled": readback.enabled,
                                              "pending": readback.pending, "callbacks": readback.callbacks,
                                              "reads": readback.reads, "deferred": readback.deferred,
                                              "superseded": readback.superseded, "failures": readback.failures,
                                              "readNS": readback.read_ns],
                                 "sharedVideo": ["requested": sharedVideo.requested, "active": sharedVideo.active,
                                                 "publications": sharedVideo.publications, "acquisitions": sharedVideo.acquisitions,
                                                 "fallbacks": sharedVideo.fallbacks, "snapshots": sharedVideo.snapshots,
                                                 "generation": sharedVideo.generation, "sequence": sharedVideo.sequence,
                                                 "allocatedBytes": sharedVideo.allocated_bytes, "retiredBytes": sharedVideo.retired_bytes],
                                 "frames": veta_frame_count(), "thermal": ProcessInfo.processInfo.thermalState.rawValue,
                                 "ready": session.ready, "running": session.running,
                                 "diagnostics": session.diagnostics, "error": session.error ?? "",
                                 "inputMasks": (0..<4).map { veta_input_mask(UInt32($0)) },
                                 "qaPort": selectedPort, "qaSyntheticPeers": qaPeers.count, "qaGeneration": generation,
                                 "jitAvailable": veta_jit_available(), "mode": session.plan.mode.rawValue])
                    if rows.count > 900 { rows.removeFirst() }
                    if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]) {
                        try? data.write(to: root.appendingPathComponent(name + ".json"), options: .atomic)
                    }
                    // Opt-in evidence of the game's own clock, without the QA overlay.
                    // Keep captures in the per-run cache, away from user galleries/saves.
                    if ProcessInfo.processInfo.environment["VETA_PERF165_CLOCK_IMAGES"] == "1",
                       sampleNumber <= 900, sampleNumber % 10 == 0, session.running,
                       let png = GameplayScreenshot.png() {
                        try? png.write(to: root.appendingPathComponent(name + "-frame-" + String(sampleNumber) + ".png"), options: .atomic)
                    }
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { break }
                }
            }
            .onDisappear {
                for peer in qaPeers.values { ControllerHub.shared.releasePeer(peer) }
                qaPeers.removeAll(); session.close()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                if session.ready && !session.showMenu { session.resume() }
            }
    }
    private func captureFrame() {
        guard let png = GameplayScreenshot.png(), let name = ProcessInfo.processInfo.environment["VETA_PERF165_RUN"],
              !name.isEmpty, name.count <= 48, name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }) else { return }
        captureNumber += 1
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Veta165Perf")
        let stem = name + "-capture-" + String(captureNumber)
        try? png.write(to: root.appendingPathComponent(stem + ".png"), options: .atomic)
        let info: [String: Any] = ["time": ProcessInfo.processInfo.systemUptime, "frames": veta_frame_count(), "running": session.running]
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]) { try? data.write(to: root.appendingPathComponent(stem + ".json"), options: .atomic) }
    }
    private func setQAInput(_ state: ControllerInputState, port: Int) {
        if port == 0 { session.setTouches(state.mask); session.setTouchAnalog(0, state.axes[0]) }
        else if let peer = qaPeers[port] { ControllerHub.shared.setRemoteInput(peer, state: state) }
    }
    private func pulse(_ name: String) {
        guard !inputBusy, session.running else { return }
        inputBusy = true
        let directions: [String: UInt16] = ["UP": 16, "DOWN": 32, "LEFT": 64, "RIGHT": 128]
        let driving = name.hasPrefix("DRIVE")
        // Exercise the existing Wii Nunchuk separately from its directional pad;
        // do not rotate production mappings to match one homebrew's assumptions.
        let wiiStick = session.game.console == .wii && name.hasPrefix("STICK ")
        let mask: UInt16 = wiiStick ? 0 : (directions[name] ?? session.game.console.buttonMask(driving ? "A" : name))
        let axes: [String: CGPoint] = ["UP": CGPoint(x: 0, y: -1), "DOWN": CGPoint(x: 0, y: 1), "LEFT": CGPoint(x: -1, y: 0), "RIGHT": CGPoint(x: 1, y: 0)]
        let direction = wiiStick ? String(name.dropFirst(6)) : name == "DRIVE LEFT" ? "LEFT" : name == "DRIVE RIGHT" ? "RIGHT" : name
        let axis = wiiStick || [.gamecube, .n64, .threeDS].contains(session.game.console) ? (axes[direction] ?? .zero) : .zero
        let state = ControllerInputState(mask: mask, axes: [axis, .zero])
        let ports = name == "DRIVE ALL" ? [0] + qaPeers.keys.sorted() : [selectedPort]
        Task {
            // Refresh synthetic peer input within the real 750ms stale-input limit.
            for _ in 0..<(driving ? 15 : 1) {
                guard session.running else { break }
                for port in ports { setQAInput(state, port: port) }
                try? await Task.sleep(nanoseconds: driving ? 200_000_000 : (directions[name] != nil ? 100_000_000 : 350_000_000))
            }
            for port in ports { setQAInput(ControllerInputState(), port: port) }
            inputBusy = false
        }
    }
}
#endif
