#if DEBUG && VETA_JIT_DEVELOPMENT && canImport(UIKit)
import SwiftUI
import UIKit
import QuartzCore
import Darwin

// Diagnostic host only. Ordinary game routing never constructs this type.
// The dynamically loaded core and callback remain resident until process exit.
@MainActor private final class PS2Native165IdleTimerLease {
    private var previous: Bool?
    func acquire() {
        guard previous == nil else { return }
        previous = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
    }
    func release() {
        guard let previous else { return }
        UIApplication.shared.isIdleTimerDisabled = previous
        self.previous = nil
    }
}
@MainActor private final class PS2Native165Session: ObservableObject {
    typealias Callback = @convention(block) (Int32, UnsafePointer<CChar>?) -> Void
    typealias Start = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32, Float, Float,
        UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>, Callback) -> Bool
    typealias VoidCall = @convention(c) () -> Void
    typealias Pause = @convention(c) (Bool) -> Void
    typealias Pad = @convention(c) (UInt32, UInt16, Float, Float, Float, Float) -> Bool
    typealias LoadCheckpoint = @convention(c) (UnsafePointer<CChar>) -> Bool
    typealias Metrics = @convention(c) (UnsafeMutablePointer<CChar>?, Int) -> Int
    @Published var status = "Preparando PS2 nativa…"
    @Published var active = false
    @Published var paused = false
    @Published var counters = ""
    @Published var hasQoSControl = false
    private let idleTimerLease = PS2Native165IdleTimerLease()
    private var attempted = false
    private var handle: UnsafeMutableRawPointer?
    private var callback: Callback?
    private var stopCall: VoidCall?, releaseCall: VoidCall?, pauseCall: Pause?, padCall: Pad?, metricsCall: Metrics?
    private var qosCall: Pause?
    private var checkpointCall: LoadCheckpoint?
    private var checkpointURL: URL?
    private var checkpointHash: String?
    private var checkpointAttempted = false
    @Published private(set) var checkpointLoading = false
    private var pulseTask: Task<Void, Never>?
    private var rows: [[String: Any]] = [], actions: [[String: Any]] = []
    private var events: [[String: Any]] = []
    let game: Game, root: URL
    init(game: Game, root: URL) { self.game = game; self.root = root }
    private func symbol<T>(_ name: String, _ type: T.Type) throws -> T {
        guard let handle, let p = dlsym(handle, name) else {
            throw NSError(domain: "PS2NativeQA", code: 1, userInfo: [NSLocalizedDescriptionKey: "Falta símbolo \(name)"])
        }
        return unsafeBitCast(p, to: type)
    }
    func start(_ view: UIView) {
        guard !attempted, view.bounds.width > 1, view.bounds.height > 1 else { return }
        attempted = true
        do {
            guard PS2Retail165Bootstrap.requested, !veta_jit_available(), !veta_jit_debugger_attached(),
                  ProcessInfo.processInfo.environment["VETA_PS2_RETAIL165_ENGINE"] == "arms" else {
                throw PS2Retail165Contract.Failure.invalidRun
            }
            let run = try PS2Retail165Contract.run(ProcessInfo.processInfo.environment["VETA_PS2_RETAIL165_RUN"])
            let caches = PS2Retail165Contract.systemURL(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].resolvingSymlinksInPath())
            let expected = try PS2Retail165Contract.sessionRoot(caches: caches, run: run)
            guard PS2Retail165Contract.systemURL(root).path == expected.path else { throw PS2Retail165Contract.Failure.unsafePath }
            let bios = try PS2Retail165Contract.stagingRoot(caches: caches, run: run).appendingPathComponent("bios.bin")
            guard try PS2Retail165Contract.regular(bios, inside: caches) == 4*1024*1024 else { throw PS2Retail165Contract.Failure.wrongSize }
            let data = root.appendingPathComponent("NativeData", isDirectory: true)
            try PS2Retail165Contract.safe(data, inside: root)
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            guard let frameworks = Bundle.main.privateFrameworksURL else { throw PS2Retail165Contract.Failure.unsafePath }
            let framework = frameworks.appendingPathComponent("VetaARMSCore.framework")
            handle = dlopen(framework.appendingPathComponent("VetaARMSCore").path, RTLD_NOW | RTLD_LOCAL)
            guard handle != nil else {
                throw NSError(domain: "PS2NativeQA", code: 2, userInfo: [NSLocalizedDescriptionKey: dlerror().map { String(cString: $0) } ?? "No se pudo abrir el motor"])
            }
            let start = try symbol("VetaARMSStart", Start.self)
            stopCall = try symbol("VetaARMSRequestStop", VoidCall.self)
            releaseCall = try symbol("VetaARMSReleaseInputs", VoidCall.self)
            pauseCall = try symbol("VetaARMSSetPaused", Pause.self)
            padCall = try symbol("VetaARMSSetPad", Pad.self)
            metricsCall = try symbol("VetaARMSCopyMetricsJSON", Metrics.self)
            qosCall = try? symbol("VetaARMSSetInteractiveQoS", Pause.self)
            hasQoSControl = qosCall != nil
            if ProcessInfo.processInfo.environment["VETA_PS2_NATIVE165_CHECKPOINT"] == "1" {
                let expectedHash = ProcessInfo.processInfo.environment["VETA_PS2_NATIVE165_CHECKPOINT_SHA256"] ?? ""
                guard expectedHash.utf8.count == 64,
                      expectedHash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
                else { throw PS2Retail165Contract.Failure.wrongHash }
                let checkpoint = try PS2Retail165Contract.stagingRoot(caches: caches, run: run).appendingPathComponent("checkpoint.p2s")
                let count = try PS2Retail165Contract.regular(checkpoint, inside: caches)
                guard count >= 1024, count <= 128*1024*1024 else { throw PS2Retail165Contract.Failure.wrongSize }
                guard try PS2Retail165Contract.hash(checkpoint) == expectedHash else { throw PS2Retail165Contract.Failure.wrongHash }
                checkpointCall = try symbol("VetaARMSQALoadCheckpoint", LoadCheckpoint.self)
                checkpointURL = checkpoint
                checkpointHash = expectedHash
            }
            // The core retains the lease until shutdown, even if SwiftUI has
            // already released this session after leaving the diagnostic view.
            let idleTimerLease = self.idleTimerLease
            callback = { [weak self, idleTimerLease] event, pointer in
                let message = pointer.map { String(cString: $0) } ?? ""
                // The C API guarantees the main queue; copy its ephemeral message now.
                MainActor.assumeIsolated {
                    if event == 4 { idleTimerLease.release() }
                    guard let self else { return }
                    self.events.append(["time": ProcessInfo.processInfo.systemUptime, "event": event, "message": message])
                    switch event {
                    case 1:
                        self.active = true; self.status = "PS2 · intérprete + Metal"
                        self.loadCheckpointIfRequested()
                    case 2: self.paused = true; self.status = "Pausada"
                    case 3: self.paused = false; self.status = "PS2 · intérprete + Metal"
                    case 4:
                        self.active = false; self.checkpointLoading = false; self.status = "Motor detenido"
                    case 5: self.status = "Error: \(message)"
                    case 6:
                        self.checkpointLoading = false; self.paused = true
                        self.status = "Checkpoint QA cargado · pulsa Continuar"
                    case 7:
                        self.checkpointLoading = false; self.paused = true
                        self.status = "Checkpoint QA: \(message)"
                    default: break
                    }
                }
            }
            let disc = root.appendingPathComponent(game.id).appendingPathComponent(game.contentName ?? "game.iso")
            _ = try PS2Retail165Contract.regular(disc, inside: root)
            let scale = view.window?.screen.scale ?? 1
            let accepted = disc.path.withCString { g in bios.path.withCString { b in data.path.withCString { d in
                framework.appendingPathComponent("CoreResources").path.withCString { r in
                    start(Unmanaged.passUnretained(view).toOpaque(), UInt32(view.bounds.width*scale), UInt32(view.bounds.height*scale), Float(scale), 60, g, b, d, r, callback!)
                }
            } } }
            if accepted {
                idleTimerLease.acquire()
            } else { status = "El motor rechazó el arranque" }
        } catch { status = "PS2 QA: \(error.localizedDescription)" }
    }
    private func loadCheckpointIfRequested() {
        guard let checkpointURL, !checkpointAttempted else { return }
        checkpointAttempted = true
        guard let checkpointCall else { status = "Checkpoint QA: API no disponible"; return }
        release(); paused = true; checkpointLoading = true
        status = "Cargando checkpoint QA…"
        actions.append(["name": "Load QA checkpoint", "time": ProcessInfo.processInfo.systemUptime,
                        "sha256": checkpointHash ?? "", "gameID": game.id])
        if !checkpointURL.path.withCString({ checkpointCall($0) }) {
            checkpointLoading = false
            pauseCall?(true)
            status = "Checkpoint QA rechazado; sesión pausada"
            actions.append(["name": "QA checkpoint rejected", "time": ProcessInfo.processInfo.systemUptime])
        }
    }
    func release() { pulseTask?.cancel(); pulseTask = nil; releaseCall?() }
    func pause() { release(); pauseCall?(true) }
    func resume() { guard !checkpointLoading else { return }; pauseCall?(false) }
    func stop() { release(); stopCall?() }
    func setQoS(_ interactive: Bool) {
        guard active, let qosCall else { return }
        actions.append(["name": interactive ? "QoS interactive" : "QoS default", "time": ProcessInfo.processInfo.systemUptime])
        qosCall(interactive)
    }
    func pulse(_ name: String, bit: Int, seconds: Double = 0.18) {
        guard active, !paused, !checkpointLoading else { return }
        release(); _ = padCall?(0, UInt16(1) << bit, 0, 0, 0, 0)
        actions.append(["name": name, "time": ProcessInfo.processInfo.systemUptime, "bit": bit, "seconds": seconds])
        pulseTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: UInt64(seconds*1_000_000_000)) } catch { return }
            self.releaseCall?()
        }
    }
    func collect() async {
        while !Task.isCancelled {
            var buffer = [CChar](repeating: 0, count: 2048)
            var metrics: [String: Any] = [:]
            if let metricsCall {
                let needed = buffer.withUnsafeMutableBufferPointer { metricsCall($0.baseAddress, $0.count) }
                if needed > 0 && needed <= buffer.count {
                    let data = Data(buffer.prefix(needed-1).map { UInt8(bitPattern: $0) })
                    metrics = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                }
            }
            counters = "VS \(metrics["gs_field_count"] ?? 0) · térmica \(ProcessInfo.processInfo.thermalState.rawValue)"
            rows.append(["time": ProcessInfo.processInfo.systemUptime, "metrics": metrics, "status": status,
                         "nativeJIT": veta_jit_available(), "debugger": veta_jit_debugger_attached(),
                         "thermal": ProcessInfo.processInfo.thermalState.rawValue])
            if rows.count > 1200 { rows.removeFirst(rows.count-1200) }
            let report: [String: Any] = ["schema": 1, "mode": "ARMSX2InterpreterMetalQA", "gameID": game.id,
                "scope": "isolated cache; GS fields are not unique images or normal-speed acceptance", "samples": rows, "actions": actions, "events": events,
                "checkpointRequested": checkpointURL != nil, "checkpointSHA256": checkpointHash ?? "", "checkpointLoading": checkpointLoading]
            if let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                try? bytes.write(to: root.appendingPathComponent("metrics.json"), options: .atomic)
            }
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
        }
    }
}

private final class PS2Native165MetalView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var ready: ((UIView) -> Void)?
    override func layoutSubviews() { super.layoutSubviews(); if window != nil { ready?(self) } }
}
private struct PS2Native165Surface: UIViewRepresentable {
    let session: PS2Native165Session
    func makeUIView(context: Context) -> PS2Native165MetalView {
        let view = PS2Native165MetalView(); view.backgroundColor = .black
        view.ready = { [weak session] view in session?.start(view) }; return view
    }
    func updateUIView(_ uiView: PS2Native165MetalView, context: Context) {}
}
struct PS2Native165QAView: View {
    @StateObject private var session: PS2Native165Session
    @Environment(\.scenePhase) private var phase
    init(game: Game, root: URL) { _session = StateObject(wrappedValue: PS2Native165Session(game: game, root: root)) }
    private func control(_ name: String, _ bit: Int, _ seconds: Double = 0.18) -> some View {
        Button(name) { session.pulse(name, bit: bit, seconds: seconds) }
            .accessibilityLabel("QA "+name).disabled(!session.active || session.paused)
    }
    var body: some View {
        VStack(spacing: 8) {
            Text(session.status).font(.caption)
            PS2Native165Surface(session: session).aspectRatio(4/3, contentMode: .fit)
            Text(session.counters).font(.caption.monospaced())
            HStack { control("START", 12); control("Cruz", 4); control("Círculo", 5); control("Cuadrado", 6); control("Triángulo", 7) }
            HStack { control("Izquierda", 2); control("Arriba", 0); control("Abajo", 1); control("Derecha", 3) }
            HStack { control("Izquierda 2 s", 2, 2); control("Derecha 2 s", 3, 2) }
            HStack {
                Button("Pausar") { session.pause() }
                Button("Continuar") { session.resume() }.disabled(session.checkpointLoading)
                Button("Detener") { session.stop() }
            }
        }.buttonStyle(.bordered).padding().task { await session.collect() }
            .overlay(alignment: .top) {
                if session.hasQoSControl {
                    HStack {
                        Button("QoS normal") { session.setQoS(false) }
                        Button("QoS interactiva") { session.setQoS(true) }
                    }.buttonStyle(.bordered).offset(y: -44)
                }
            }
            .onDisappear { session.stop() }
            .onChange(of: phase) { value in if value != .active { session.pause() } }
    }
}
#endif
