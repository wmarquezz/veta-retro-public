#if VETA_JIT_DEVELOPMENT
import SwiftUI
import WebKit
import AVFoundation
import GameController

/// Integration candidate only. The launch plan must opt in with
/// VETA_DREAMCAST_WEB165=1; native/JIT choices keep their existing paths.
@MainActor final class DreamcastWebSession: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    let game: Game
    let library: Library
    @Published private(set) var ready = false
    @Published private(set) var running = false
    @Published private(set) var paused = true
    @Published private(set) var busy = false
    @Published private(set) var startPending = false
    @Published private(set) var terminalExitStarted = false
    @Published var showMenu = false
    @Published var error: String?
    @Published private(set) var status = L10n.text("Preparando Dreamcast…")
    @Published private(set) var metrics = ""
    private var started = false, stopped = false, interruptedBeforeStart = false
    private var server: DreamcastWebServer?
    private var origin: URL?
    private var touches: UInt16 = 0
    private var analog: [CGPoint] = [.zero, .zero]
    private var previousInputs: [ControllerInputState] = []
    private var inputInFlight = false
    private var desiredPaused = true
    private var pauseWorker: Task<Void, Never>?
    private var startWatchdog: Task<Void, Never>?
    var releaseTouches: (() -> Void)?
    static var assets: URL? { DreamcastWebAssets.directory() }
    static var enabled: Bool { DreamcastWebLaunchPolicy.enabled }

    lazy var web: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsInlineMediaPlayback = true
        configuration.userContentController.add(self, name: "vetaWebJIT")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self; view.isOpaque = false; view.backgroundColor = .black
        view.scrollView.isScrollEnabled = false; view.accessibilityIdentifier = "dreamcast-web-screen"
        return view
    }()
    init(game: Game, library: Library) { self.game = game; self.library = library; super.init() }
    func start() {
        guard !started, !stopped else { return }; started = true
        Task {
            do {
                guard Self.enabled, let assets = DreamcastWebLaunchPolicy.assetCandidate() else { throw DreamcastWebAssets.failure("El motor Dreamcast de prueba no está disponible.") }
                let system = library.root.appendingPathComponent("System")
                try DreamcastWebLaunchPolicy.preflightWeb(gameID: game.id, disc: library.romURL(game),
                    gameDirectory: library.stateDirectory(game), nativeSaveDirectory: library.file(game, "CoreSaves"),
                    system: system, assets: assets)
                let store = try DreamcastWebVMUStore(gameID: game.id, gameDirectory: library.stateDirectory(game),
                                                       nativeSaveDirectory: library.file(game, "CoreSaves"), nativeSystem: system)
                let server = DreamcastWebServer(assets: assets, disc: library.romURL(game), system: system, persistentStore: store)
                self.server = server
                let url = try await server.start()
                guard !stopped else { server.stop(); return }
                origin = url
                try activateAudio()
                ControllerHub.shared.configure(console: .dreamcast, maxPlayers: 4)
                web.load(URLRequest(url: url))
            } catch { report(error.localizedDescription) }
        }
    }
    private func report(_ message: String) {
        guard !stopped else { return }
        error = L10n.text(message)
    }
    // Public WKWebView evaluation enters WebKit's client-script user-gesture
    // scope. Keep the h4 HTML button/listener intact as the manual fallback.
    static let nativeStartScript = #"""
    (() => {
      const button = document.getElementById('boot');
      if (!button) throw Error('Dreamcast start button unavailable');
      if (button.disabled) throw Error('Dreamcast runtime not ready');
      if (button.hidden) return {requested:false, reason:'already-started'};
      button.click();
      return {requested:true, hidden:button.hidden,
        active:navigator.userActivation ? navigator.userActivation.isActive : null};
    })()
    """#
    func play() {
        guard ready, !running, !stopped, !startPending,
              UIApplication.shared.applicationState == .active else { return }
        do { try activateAudio() } catch { report("No se pudo activar el audio del juego."); return }
        startPending = true
        // No Task/await or synthetic DOM gesture before this public API call.
        web.evaluateJavaScript(Self.nativeStartScript) { [weak self] value, failure in
            guard let self, !self.stopped else { return }
            if let failure {
                self.startPending = false
                print("VETA_DC_NATIVE_START_FAILED \(failure.localizedDescription)")
                self.report("No se pudo iniciar desde el mando. Toca Jugar dentro de la imagen.")
            } else {
                print("VETA_DC_NATIVE_START_REQUEST \(String(describing: value))")
                // A successful evaluation is not evidence that the engine or
                // audio started. Only the existing h4 messages change running.
            }
        }
        startWatchdog?.cancel()
        startWatchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard let self, !self.stopped, !self.running, self.startPending else { return }
            self.startPending = false
            self.report("Dreamcast aún no confirma el inicio. Prueba Jugar dentro de la imagen o vuelve a la biblioteca.")
        }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !stopped, message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.host == origin?.host,
              message.frameInfo.securityOrigin.port == origin?.port,
              let value = message.body as? [String: Any], let stage = value["stage"] as? String else { return }
        switch stage {
        case "awaiting-user-start":
            ready = true; status = "Toca Jugar para comenzar."
            web.evaluateJavaScript("window.vetaDreamcast.ready()", completionHandler: nil)
        case "main-started":
            startPending = false; startWatchdog?.cancel(); startWatchdog = nil
            running = true; paused = false; desiredPaused = false; status = ""
            web.evaluateJavaScript("window.vetaDreamcast.started()", completionHandler: nil)
            var updated = game; updated.lastPlayed = Date(); library.update(updated)
            if interruptedBeforeStart || UIApplication.shared.applicationState != .active { openMenu() }
            else { UIApplication.shared.isIdleTimerDisabled = true }
        case "failed":
            startPending = false; startWatchdog?.cancel(); startWatchdog = nil
            running = false; paused = true; UIApplication.shared.isIdleTimerDisabled = false
            release(); report("La sesión Dreamcast se detuvo. Vuelve a la biblioteca para abrir el juego.")
            print("VETA_DC_WEB_FAILED \(value["error"] ?? "unknown")")
        case "adapter-interrupted": interrupt()
        case "api-rejection":
            print("VETA_DC_WEB_API_REJECTION \(value["errorDetails"] ?? "unknown")")
        case "running", "paused", "pause-verified", "resumed":
            let audio = value["audio"] as? [String: Any]
            metrics = "frames:\(value["frames"] ?? 0);paused:\(paused);mode:webAssembly;audio:\(audio?["state"] ?? "unreported");audioReady:\(audio?["ready"] ?? false);audioFailed:\(audio?["failed"] ?? false)"
            web.accessibilityValue = metrics
        default: break
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Only the private local document can navigate. CSP also constrains all
        // subresource requests, including dynamically compiled WASM workers.
        guard let url = navigationAction.request.url, let origin,
              url.scheme == origin.scheme, url.host == origin.host, url.port == origin.port,
              url.path == origin.path, url.query == nil, url.fragment == nil,
              navigationAction.targetFrame?.isMainFrame == true else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report("No se pudo iniciar Dreamcast. Vuelve a la biblioteca e inténtalo de nuevo.")
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        running = false; paused = true; UIApplication.shared.isIdleTimerDisabled = false; release()
        report("La sesión se cerró. Vuelve a la biblioteca para abrir el juego.")
    }
    func setTouches(_ mask: UInt16) { touches = mask; sendInputs() }
    func setAnalog(_ index: Int, _ value: CGPoint) {
        if analog.indices.contains(index) { analog[index] = value }; sendInputs()
    }
    func sendInputs() {
        guard ready, running, !stopped, !inputInFlight else { return }
        let active = !paused && !showMenu && !busy && UIApplication.shared.applicationState == .active
        let values = ControllerHub.shared.inputs(console: .dreamcast, touchMask: touches, touchAnalog: analog, running: active)
        guard values != previousInputs, values.count == 4 else { return }
        previousInputs = values
        func axis(_ value: CGFloat) -> Int { value.isFinite ? Int(max(-1, min(1, value)) * 32767) : 0 }
        let payload = values.map { [Int($0.mask), axis($0.axes.first?.x ?? 0), axis($0.axes.first?.y ?? 0)] }
        guard let json = try? JSONSerialization.data(withJSONObject: payload) else { return }
        inputInFlight = true
        web.evaluateJavaScript("window.vetaDreamcast.input(\(String(decoding: json, as: UTF8.self)))") { [weak self] _, failure in
            guard let self else { return }; self.inputInFlight = false
            if failure != nil { self.previousInputs = [] }
        }
    }
    private func release() {
        touches = 0; analog = [.zero, .zero]; previousInputs = []
        releaseTouches?()
        if ready, !stopped { web.evaluateJavaScript("window.vetaDreamcast.interrupt()", completionHandler: nil) }
    }
    private func activateAudio() throws {
        let audio = AVAudioSession.sharedInstance(), policy = AudioPlaybackPolicy.current
        try audio.setCategory(policy.category, mode: .default, options: policy.options); try audio.setActive(true)
    }
    func becameActive() {
        guard !stopped else { return }
        do { try activateAudio() } catch { report("No se pudo recuperar el audio del juego.") }
        // Do not resume a paused game behind the user's menu.
    }
    func interrupt() {
        interruptedBeforeStart = !running
        release(); openMenu()
    }
    func openMenu() {
        guard !stopped else { return }
        showMenu = true; UIApplication.shared.isIdleTimerDisabled = false; release()
        if running { requestPause(true) }
    }
    func resume() {
        guard running, !stopped, !terminalExitStarted else { return }
        guard UIApplication.shared.applicationState == .active else { desiredPaused = true; showMenu = true; return }
        requestPause(false)
    }
    /// Serializes pause/resume across sheet dismissal and OS interruptions.
    /// h4 reports operation failure as a result object, so the JS adapter checks
    /// it explicitly; completing a JS call alone never certifies a pause.
    private func requestPause(_ value: Bool) {
        guard !terminalExitStarted else { return }
        desiredPaused = value
        guard pauseWorker == nil else { return }
        busy = true
        pauseWorker = Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false; self.pauseWorker = nil; self.previousInputs = [] }
            while !self.stopped {
                let target = self.desiredPaused
                do {
                    if !target { try self.activateAudio() }
                    _ = try await self.web.callAsyncJavaScript("return await window.vetaDreamcast.pause(paused)", arguments: ["paused": target], in: nil, contentWorld: .page)
                    guard !self.stopped else { return }
                    self.paused = target
                    UIApplication.shared.isIdleTimerDisabled = !target && UIApplication.shared.applicationState == .active
                } catch {
                    self.desiredPaused = true; self.paused = true; self.showMenu = true
                    UIApplication.shared.isIdleTimerDisabled = false
                    self.report("No se pudo cambiar la pausa. Vuelve a la biblioteca si no responde."); return
                }
                if target == self.desiredPaused { return }
            }
        }
    }
    /// Normal exit must finish the VMU terminal close and verified host write
    /// before destroying WKWebView. Failures keep this session available to retry.
    func finish() async -> Bool {
        guard !stopped else { return true }
        if let pending = pauseWorker { await pending.value }
        guard !busy else { return false }
        if !running { stop(); return true }
        terminalExitStarted = true; busy = true; desiredPaused = true; showMenu = true; release()
        defer { busy = false }
        do {
            _ = try await web.callAsyncJavaScript("""
                const result = await window.vetaWebJIT.closePersistent();
                if (!result || result.ok !== true || result.stdioFlushVerified !== true || result.terminal !== true)
                    throw Error(result?.error || 'VMU close/readback not confirmed');
                return result;
                """, arguments: [:], in: nil, contentWorld: .page)
            guard !stopped else { return true }
            stop(); return true
        } catch {
            paused = true; desiredPaused = true
            UIApplication.shared.isIdleTimerDisabled = false
            report("No se pudo confirmar el guardado de la tarjeta Dreamcast. Reintenta salir; la copia anterior se conserva.")
            print("VETA_DC_VMU_CLOSE_FAILED \(error.localizedDescription)")
            return false
        }
    }
    func stop() {
        guard !stopped else { return }
        release(); stopped = true; running = false; paused = true; desiredPaused = true
        startWatchdog?.cancel(); startWatchdog = nil; startPending = false
        pauseWorker?.cancel(); pauseWorker = nil
        UIApplication.shared.isIdleTimerDisabled = false
        // Normal menu exit calls finish() first. OS/process teardown cannot await
        // VMU closure; it preserves the last confirmed host package.
        web.stopLoading(); web.configuration.userContentController.removeScriptMessageHandler(forName: "vetaWebJIT")
        web.navigationDelegate = nil; web.loadHTMLString("", baseURL: nil)
        server?.stop(); server = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

@MainActor private final class DreamcastWebSurfaceRouter: ExternalSurfaceRouting {
    let surface: UIView
    private weak var local: UIView?
    private weak var requestedExternal: UIView?
    private weak var activeHost: UIView?
    let aspect: CGFloat = 4 / 3
    var televisionPixelLimit = CGSize(width: 1920, height: 1080)
    var televisionScale: CGFloat = 1
    var changed: ((Bool) -> Void)?
    var allowsExternal = false { didSet { reconcile() } }
    init(surface: UIView, local: UIView) { self.surface = surface; self.local = local; reconcile() }
    func route(to host: UIView?) { requestedExternal = host; reconcile() }
    private func reconcile() {
        let external = allowsExternal ? requestedExternal : nil
        guard let host = external ?? local else { return }
        if activeHost !== host { surface.removeFromSuperview(); host.addSubview(surface); activeHost = host; changed?(external != nil) }
        layout()
    }
    func layout() {
        guard let host = activeHost else { return }
        surface.frame = TVImageGeometry.frame(in: host.bounds, aspect: aspect, scale: host === local ? 1 : televisionScale)
    }
}

@MainActor private final class DreamcastWebViewController: UIViewController {
    let session: DreamcastWebSession
    private let picture = UIView(), shell = ConsoleShellView(), deck = TouchDeck(), label = UILabel(), tvLabel = UILabel(), menu = UIButton(type: .system), play = UIButton(type: .system)
    private var router: DreamcastWebSurfaceRouter?
    private var timer: Timer?
    init(session: DreamcastWebSession) { self.session = session; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override func viewDidLoad() {
        super.viewDidLoad(); [shell, picture, deck, label, menu, play].forEach(view.addSubview)
        picture.backgroundColor = .black; picture.addSubview(tvLabel)
        tvLabel.text = L10n.text("Imagen en TV"); tvLabel.textColor = .white; tvLabel.textAlignment = .center; tvLabel.isHidden = true
        let router = DreamcastWebSurfaceRouter(surface: session.web, local: picture); self.router = router
        router.changed = { [weak self] external in self?.tvLabel.isHidden = !external; self?.view.setNeedsLayout() }
        deck.onInput = { [weak session] in session?.setTouches($0) }; deck.onAnalog = { [weak session] in session?.setAnalog($0, $1) }
        session.releaseTouches = { [weak deck] in deck?.releaseAll() }
        label.text = "VETA / DREAMCAST"; label.accessibilityIdentifier = "dreamcast-web-metrics"; label.font = UIFont(name: "BarlowCondensed-Bold", size: 18)
        menu.setTitle(L10n.text("Menú"), for: .normal); menu.accessibilityIdentifier = "dreamcast-web-pause"
        menu.addAction(UIAction { [weak session] _ in session?.openMenu() }, for: .touchUpInside)
        play.accessibilityIdentifier = "dreamcast-web-play"
        play.backgroundColor = UIColor(hex: 0xa0efcf); play.tintColor = UIColor(hex: 0x122c29)
        play.titleLabel?.font = .systemFont(ofSize: 18, weight: .bold); play.layer.cornerRadius = 10
        play.addAction(UIAction { [weak session] _ in session?.play() }, for: .touchUpInside)
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak session] _ in Task { @MainActor in session?.sendInputs() } }
        session.start(); refresh()
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); if let router { ExternalDisplayHub.shared.registerNative(router) } }
    func cleanup() { timer?.invalidate(); timer = nil; if let router { ExternalDisplayHub.shared.unregisterNative(router) } }
    func refresh() {
        label.accessibilityValue = session.metrics; deck.style = ControlStyle(console: .dreamcast)
        play.setTitle(L10n.text(session.startPending ? "Iniciando…" : session.ready ? "Jugar" : "Preparando…"), for: .normal)
        play.isEnabled = session.ready && !session.startPending
        play.isHidden = session.running
        router?.allowsExternal = session.running; view.setNeedsLayout()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews(); let safe = view.safeAreaLayoutGuide.layoutFrame
        deck.applySkin(console: .dreamcast, landscape: safe.width > safe.height)
        let layout = ConsoleLayout(safe: safe, aspect: 4 / 3, minimumDeck: GameConsole.dreamcast.minimumDeck, overlayLandscape: deck.usesLandscapeOverlay)
        deck.frame = layout.deck; picture.frame = layout.screen; shell.frame = view.bounds; shell.style = deck.style; shell.screenRect = layout.screen
        let playWidth = min(CGFloat(200), max(CGFloat(0), layout.screen.width - 24))
        play.frame = CGRect(x: layout.screen.midX - playWidth / 2, y: layout.screen.maxY - 60, width: playWidth, height: 48)
        shell.portraitSkinTop = deck.landscape ? nil : layout.toolbar.minY; shell.setNeedsDisplay()
        label.frame = CGRect(x: layout.toolbar.minX + 20, y: layout.toolbar.minY, width: 180, height: 44); label.textColor = deck.style.headerInk; label.isHidden = deck.usesLandscapeOverlay
        menu.frame = deck.usesLandscapeOverlay ? layout.toolbar : CGRect(x: layout.toolbar.maxX - 94, y: layout.toolbar.minY, width: 80, height: 44)
        menu.tintColor = deck.usesLandscapeOverlay ? .white : deck.style.accent; menu.backgroundColor = deck.usesLandscapeOverlay ? UIColor.black.withAlphaComponent(0.4) : .clear; menu.layer.cornerRadius = 8
        shell.isHidden = deck.usesLandscapeOverlay; view.backgroundColor = deck.usesLandscapeOverlay ? .black : deck.style.background
        tvLabel.frame = picture.bounds; router?.layout()
    }
}
private struct DreamcastWebSurface: UIViewControllerRepresentable {
    @ObservedObject var session: DreamcastWebSession
    func makeUIViewController(context: Context) -> DreamcastWebViewController { DreamcastWebViewController(session: session) }
    func updateUIViewController(_ controller: DreamcastWebViewController, context: Context) { controller.refresh() }
    static func dismantleUIViewController(_ controller: DreamcastWebViewController, coordinator: ()) { controller.cleanup() }
}
struct DreamcastWebGameContainer: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: DreamcastWebSession
    @State private var confirmExit = false
    init(game: Game, library: Library) { _session = StateObject(wrappedValue: DreamcastWebSession(game: game, library: library)) }
    var body: some View {
        DreamcastWebSurface(session: session).ignoresSafeArea().statusBarHidden(true)
            .sheet(isPresented: $session.showMenu, onDismiss: { session.resume() }) {
                NavigationStack { Form {
                    Section(session.game.name) {
                        Button("Continuar") { session.showMenu = false }.disabled(session.busy || session.terminalExitStarted)
                        Button("Ir a la biblioteca") { confirmExit = true }.accessibilityIdentifier("dreamcast-web-exit")
                        Text("Las partidas del juego se conservan al salir desde este menú. Cerrar VETA a la fuerza puede perder los cambios de esta sesión.").font(.footnote)
                    }
                    Section("Controles") {
                        NavigationLink("Skin") { ControllerSkinSettingsView(console: .dreamcast) }
                        NavigationLink("Controles") { ControlsSettings(console: .dreamcast) }
                        NavigationLink("Mandos y jugadores") { ControllerSettingsView(console: .dreamcast, supportsRumble: false) }
                        NavigationLink("Jugar juntos") { PlayTogetherView(console: .dreamcast) }
                        NavigationLink("TV y pantalla completa") { ExternalDisplaySettingsView(nativeSurface: true) }
                    }
                }.interactiveDismissDisabled(session.busy || session.terminalExitStarted).vetaForm().navigationTitle("Dreamcast").tint(VetaTheme.mint)
                    .confirmationDialog("¿Salir del juego?", isPresented: $confirmExit) {
                        Button("Salir") { Task { if await session.finish() { dismiss() } } }.accessibilityIdentifier("dreamcast-web-confirm-exit")
                        Button("Cancelar", role: .cancel) {}
                    }
                }
            }
            .alert("VETA Retro", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
                Button("Aceptar") { session.error = nil }
                Button("Volver a la biblioteca") { Task { if await session.finish() { dismiss() } } }
            } message: { Text(session.error ?? "") }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in session.interrupt() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in session.becameActive() }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
                if (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue { session.interrupt() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name.GCControllerDidDisconnect)) { _ in session.openMenu() }
            .onDisappear { session.stop() }
    }
}
#endif
