#if VETA_JIT_DEVELOPMENT
import SwiftUI
import WebKit
import AVFoundation
import GameController

@MainActor final class PS2WebSession: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    let game:Game
    let library:Library
    @Published var status="Preparando PlayStation 2…"
    @Published var running=false
    @Published var showMenu=false
    @Published var busy=false
    @Published var error:String?
    @Published var hasQuick=false
    @Published var recoveredState=false
    @Published private(set) var ready=false
    @Published private(set) var startPending=false
    private var restoredAuto=false
    private var interruptedBeforeStart=false
    @Published private(set) var metrics=""
    private(set) var qaTelemetry:[String:Any]=[:]
    private var server:PS2WebServer?
    var manualSaveStore: NativeSaveStore? { server?.manualSaveStore }
    private var backgroundTask:UIBackgroundTaskIdentifier = .invalid
    private var started=false,stopped=false
    private var touches:UInt16=0
    private var analog:[CGPoint]=[.zero,.zero]
    private var previousInputs:[ControllerInputState]=[]
    var releaseTouches:(()->Void)?
    lazy var web:WKWebView = {
        let configuration=WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback=[]
        configuration.allowsInlineMediaPlayback=true
        configuration.userContentController.add(self,name:"veta")
        let view=WKWebView(frame:.zero,configuration:configuration)
        view.navigationDelegate=self;view.isOpaque=false;view.backgroundColor = .black
        view.scrollView.isScrollEnabled=false;view.accessibilityIdentifier="ps2-web-screen"
        return view
    }()
    static var assetDirectoryName:String {
        #if DEBUG
        let env=ProcessInfo.processInfo.environment
        if env["VETA_PS2_WEB_QA"] == "1", env["VETA_PS2_WEB_VARIANT"] == "gp16" { return "PS2Wasm-gp16" }
        #endif
        return "PS2Wasm"
    }
    static var assets:URL? {
        guard let js=Bundle.main.url(forResource:"Play",withExtension:"js",subdirectory:assetDirectoryName),
              FileManager.default.fileExists(atPath:js.deletingLastPathComponent().appendingPathComponent("Play.wasm").path) else{return nil}
        return js.deletingLastPathComponent()
    }
    init(game:Game,library:Library){self.game=game;self.library=library;super.init()}
    func start() {
        guard !started else{return};started=true
        Task {
            do {
                guard let assets=Self.assets else{throw VetaError.message("El motor sin conexión no está incluido.")}
                let disc=library.romURL(game)
                // The web engine reads a logical ISO stream. CSO sectors are
                // expanded on demand by the local server, never as a second ROM.
                let size=try await Task.detached(priority:.userInitiated) {
                    try PS2DiscReader(url:disc).logicalSize
                }.value
                let storage:URL
                if ProcessInfo.processInfo.environment["VETA_PS2_WEB_QA"] == "1" {
                    let run=ProcessInfo.processInfo.environment["VETA_PS2_WEB_QA_RUN"] ?? "default"
                    guard run.count<=32,run.utf8.allSatisfy({(48...57).contains($0)||(65...90).contains($0)||(97...122).contains($0)||$0==45}) else{throw VetaError.message("Nombre de archivo inválido en la biblioteca.")}
                    storage=FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("VetaPS2Web160QA-"+run).appendingPathComponent(game.id)
                } else {storage=library.directory(game.id).appendingPathComponent("engines/play-web-v1")}
                // Play selects its image decoder from this name. The transport
                // has already expanded CSO, so expose ISO rather than decode twice.
                let logicalName=disc.pathExtension.lowercased()=="cso" ? "game.iso":disc.lastPathComponent
                let values:[String:Any]=["name":logicalName,"size":size,
                    "qa":ProcessInfo.processInfo.environment["VETA_PS2_WEB_QA"] == "1",
                    "qaDiscCache":ProcessInfo.processInfo.environment["VETA_PS2_WEB_QA"] == "1" && ProcessInfo.processInfo.environment["VETA_PS2_WEB_DISC_CACHE"] == "1",
                    "play":L10n.text("Jugar"),"loading":L10n.text("Cargando juego…"),
                    "failure":L10n.text("La sesión encontró un error. Vuelve a la biblioteca e inténtalo de nuevo.")]
                let json=try JSONSerialization.data(withJSONObject:values,options:[.sortedKeys])
                let html=PS2WebClient.page.replacingOccurrences(of:"__CONFIG__",with:String(decoding:json,as:UTF8.self).replacingOccurrences(of:"<",with:"\\u003c"))
                let server=PS2WebServer(html:Data(html.utf8),assets:assets,disc:disc,storage:storage,gameID:game.id,stateFormat:"play-505dac7-vmzip-timing-v1")
                self.server=server
                let url=try await server.start()
                guard !stopped else{server.stop();return}
                try activateAudio()
                ControllerHub.shared.configure(console:.ps2,maxPlayers:2)
                web.load(URLRequest(url:url))
            } catch {report(error,"No se pudo iniciar la sesión local. Vuelve a la biblioteca e inténtalo de nuevo.");status=L10n.text("No se pudo iniciar el juego.")}
        }
    }
    func userContentController(_ userContentController:WKUserContentController,didReceive message:WKScriptMessage) {
        guard let value=message.body as? [String:Any] else{return}
        if ProcessInfo.processInfo.environment["VETA_PS2_WEB_QA"] == "1", let telemetry=value["qaTelemetry"] as? [String:Any] {qaTelemetry=telemetry}
        if let failure=value["error"] as? String {startPending=false;print("VETA_PS2_WEB_ERROR \(failure)");if ProcessInfo.processInfo.environment["VETA_PS2_WEB_QA"] == "1" {metrics="error:\(failure)"};error=L10n.text("La sesión encontró un error. Vuelve a la biblioteca e inténtalo de nuevo.");running=false;status=L10n.text("No se pudo iniciar el juego.");return}
        if let phase=value["phase"] as? String,ProcessInfo.processInfo.environment["VETA_PS2_WEB_QA"] == "1" {metrics="phase:\(phase)"}
        if value["stage"] as? String == "ready" {ready=true;status=L10n.text("Toca Jugar para comenzar.")}
        if value["stage"] as? String == "running" {startPending=false;restoredAuto=value["restoredAuto"] as? Bool == true;UIApplication.shared.isIdleTimerDisabled=true;running=true;status="";var updated=game;updated.lastPlayed=Date();library.update(updated);if value["paused"] as? Bool == true || interruptedBeforeStart || UIApplication.shared.applicationState != .active {interruptedBeforeStart=false;openMenu();if UIApplication.shared.applicationState == .background {backgroundSave()}}}
        if let quick=value["quick"] as? Bool {hasQuick=quick}
        if value["recovered"] as? Bool == true {recoveredState=true}
        if let frames=value["frames"] as? Int {
            metrics="frames:\(frames);fps:\(value["fps"] ?? 0);colors:\(value["colors"] ?? 0);paused:\(value["paused"] ?? false);audio:\(value["audio"] ?? "unknown");playerX:\(value["playerX"] ?? -1);playerPixels:\(value["playerPixels"] ?? 0);jitPool:\(veta_jit_available() ? 1:0);restoredAuto:\(restoredAuto ? 1:0);mode:webAssembly"
            web.accessibilityValue=metrics
        }
    }
    private func report(_ failure:Error,_ message:String){guard !stopped else{return};startPending=false;print("VETA_PS2_WEB_ERROR \(failure.localizedDescription)");error=L10n.text(message)}
    func webView(_ webView:WKWebView,didFailProvisionalNavigation navigation:WKNavigation!,withError error:Error){guard !stopped else{return};report(error,"No se pudo iniciar la sesión local. Vuelve a la biblioteca e inténtalo de nuevo.")}
    func webViewWebContentProcessDidTerminate(_ webView:WKWebView){startPending=false;ready=false;error=L10n.text("La sesión se cerró. Vuelve a la biblioteca para abrir el juego.");running=false}
    // Public WKWebView evaluation supplies WebKit's client-script gesture scope.
    // Invoke the existing HTML listener synchronously; its audio resume stays
    // before its first await. Completion is only a request, never engine success.
    static let nativeStartScript = #"""
    (() => {
      const button = document.getElementById('start');
      if (!button || typeof button.onclick !== 'function') throw Error('PS2 start button unavailable');
      if (button.disabled) throw Error('PS2 runtime not ready');
      if (button.hidden) return {requested:false, reason:'already-started'};
      button.click();
      return {requested:true, hidden:button.hidden,
        active:navigator.userActivation ? navigator.userActivation.isActive : null};
    })()
    """#
    func play() {
        guard ready, !running, !stopped, !startPending, !busy,
              UIApplication.shared.applicationState == .active else { return }
        do { try activateAudio() }
        catch { report(error, "No se pudo activar el audio del juego."); return }
        startPending = true
        // Keep this directly on the native button action, with no Task/await.
        web.evaluateJavaScript(Self.nativeStartScript) { [weak self] value, failure in
            guard let self, !self.stopped else { return }
            if let failure {
                self.report(failure, "No se pudo iniciar desde el mando. Toca Jugar dentro de la imagen.")
            } else {
                print("VETA_PS2_NATIVE_START_REQUEST \(String(describing: value))")
                // Existing HTML running/error messages own the result. The HTML
                // startup timeout also remains authoritative during disc loading.
            }
        }
    }
    private func invoke(_ expression:String)async throws {
        guard ready,!stopped else{throw VetaError.message("El juego todavía no está listo.")}
        _ = try await web.callAsyncJavaScript("return await window.veta.\(expression)",arguments:[:],in:nil,contentWorld:.page)
    }
    func setTouches(_ mask:UInt16){touches=mask;sendInputs()}
    func setAnalog(_ index:Int,_ value:CGPoint){if analog.indices.contains(index){analog[index]=value};sendInputs()}
    func sendInputs() {
        guard ready,!stopped else{return}
        let values=Array(ControllerHub.shared.inputs(console:.ps2,touchMask:touches,touchAnalog:analog,running:running && !showMenu && !busy && UIApplication.shared.applicationState == .active).prefix(2))
        guard values != previousInputs else{return};previousInputs=values
        let payload=values.map {v -> [Int] in
            [Int(v.mask)]+v.axes.flatMap{p in [Int(max(-1,min(1,p.x))*32767),Int(max(-1,min(1,p.y))*32767)]}
        }
        guard let data=try? JSONSerialization.data(withJSONObject:payload) else{return}
        web.evaluateJavaScript("window.veta?.input(\(String(decoding:data,as:UTF8.self)))",completionHandler:nil)
    }
    private func release(){releaseTouches?();touches=0;analog=[.zero,.zero];previousInputs=[];sendInputs()}
    private func activateAudio() throws {let audio=AVAudioSession.sharedInstance(),policy=AudioPlaybackPolicy.current;try audio.setCategory(policy.category,mode:.default,options:policy.options);try audio.setActive(true)}
    func becameActive(){guard ready,!stopped else{return};do{try activateAudio()}catch{print("VETA_PS2_AUDIO_RECOVERY \(error.localizedDescription)")}}
    func interrupt(){if ready {web.evaluateJavaScript("window.veta?.interrupt()",completionHandler:nil)};if running {openMenu()} else {interruptedBeforeStart=true}}
    func openMenu(){guard running,!busy else{return};showMenu=true;UIApplication.shared.isIdleTimerDisabled=false;release();Task {do{try await invoke("pause(true)")}catch{report(error,"No se pudo pausar el juego.")}}}
    func resume(){guard ready,!busy,!stopped,UIApplication.shared.applicationState == .active else{return};Task {do{try activateAudio();try await invoke("pause(false)");UIApplication.shared.isIdleTimerDisabled=true;running=true;previousInputs=[];sendInputs()}catch{showMenu=true;report(error,"No se pudo continuar el juego.")}}}
    func state(load:Bool) {
        guard !busy else{return};busy=true;release()
        Task {
            defer{busy=false}
            do {try await invoke(load ? "load('quick')":"save('quick')");hasQuick=true;status=L10n.text(load ? "Partida cargada":"Partida guardada")}
            catch {report(error,load ? "No se pudo cargar la partida guardada.":"No se pudo guardar la partida.")}
        }
    }
    func manualState(_ slot: String, load: Bool) async throws {
        guard NativeSaveStore.manualSlots.contains(slot), let server, !busy, running else {
            throw VetaError.message("El juego todavía no está listo.")
        }
        busy = true; release()
        defer { busy = false }
        try await invoke("pause(true)")
        if !load {
            let configuration = WKSnapshotConfiguration()
            configuration.snapshotWidth = 480
            let image = try await web.takeSnapshot(configuration: configuration)
            guard let preview = image.jpegData(compressionQuality: 0.85), preview.count <= 512*1024 else {
                throw VetaError.message("No se pudo obtener el estado.")
            }
            try await server.stageManualPreview(preview, slot: slot)
        }
        do {
            try await invoke("\(load ? "load" : "save")('\(slot)')")
            status = L10n.text(load ? "Partida cargada" : "Partida guardada")
        } catch {
            try? await server.stageManualPreview(nil, slot: slot)
            throw VetaError.message(load ? "No se pudo cargar la partida guardada." : "No se pudo guardar la partida.")
        }
    }
    func exit(_ completed:@escaping()->Void) {
        guard !busy else{return};busy=true;release()
        Task {
            do {if running {try await invoke("save('auto')")};stop();completed()}
            catch {report(error,"No se pudo guardar la partida.");busy=false}
        }
    }
    func backgroundSave() {
        guard running,!stopped,!busy else{return}
        openMenu();busy=true
        backgroundTask=UIApplication.shared.beginBackgroundTask(withName:"VETA PS2 save") { [weak self] in
            Task {@MainActor in self?.endBackgroundTask()}
        }
        Task {
            defer{busy=false;endBackgroundTask()}
            do {try await invoke("save('auto')");status=L10n.text("Partida guardada")}
            catch {report(error,"No se pudo guardar la partida.")}
        }
    }
    private func endBackgroundTask(){guard backgroundTask != .invalid else{return};UIApplication.shared.endBackgroundTask(backgroundTask);backgroundTask = .invalid}
    func stop(){guard !stopped else{return};stopped=true;startPending=false;ready=false;running=false;endBackgroundTask();UIApplication.shared.isIdleTimerDisabled=false;try? AVAudioSession.sharedInstance().setActive(false,options:.notifyOthersOnDeactivation);releaseTouches?();web.stopLoading();web.configuration.userContentController.removeScriptMessageHandler(forName:"veta");web.navigationDelegate=nil;web.loadHTMLString("",baseURL:nil);server?.stop();server=nil}
}

@MainActor private final class WebSurfaceRouter:ExternalSurfaceRouting {
    let surface:UIView
    private weak var local:UIView?
    private weak var external:UIView?
    let aspect:CGFloat=4/3
    var televisionPixelLimit=CGSize(width:1920,height:1080)
    var televisionScale:CGFloat=1
    var changed:((Bool)->Void)?
    var isExternal:Bool{external != nil}
    init(surface:UIView,local:UIView){self.surface=surface;self.local=local;route(to:nil)}
    func route(to host:UIView?){let change=external !== host;external=host;guard let target=host ?? local else{return};if surface.superview !== target {surface.removeFromSuperview();target.addSubview(surface)};layout();if change{changed?(host != nil)}}
    func layout(){guard let host=external ?? local else{return};surface.frame=TVImageGeometry.frame(in:host.bounds,aspect:aspect,scale:external == nil ? 1:televisionScale)}
}

@MainActor private final class PS2WebViewController:UIViewController {
    let session:PS2WebSession
    private let picture=UIView(),shell=ConsoleShellView(),deck=TouchDeck(),label=UILabel(),tvLabel=UILabel(),menu=UIButton(type:.system),play=UIButton(type:.system)
    private var router:WebSurfaceRouter?
    private var timer:Timer?
    init(session:PS2WebSession){self.session=session;super.init(nibName:nil,bundle:nil)}
    required init?(coder:NSCoder){fatalError()}
    override var prefersHomeIndicatorAutoHidden:Bool{true}
    override func viewDidLoad(){
        super.viewDidLoad();[shell,picture,deck,label,menu,play].forEach(view.addSubview)
        picture.backgroundColor = .black;picture.addSubview(tvLabel);tvLabel.text=L10n.text("Imagen en TV");tvLabel.textColor = .white;tvLabel.textAlignment = .center;tvLabel.isHidden=true
        let router=WebSurfaceRouter(surface:session.web,local:picture);self.router=router
        router.changed={[weak self] external in self?.tvLabel.isHidden = !external;self?.view.setNeedsLayout()}
        deck.onInput={[weak session] in session?.setTouches($0)};deck.onAnalog={[weak session] in session?.setAnalog($0,$1)}
        session.releaseTouches={[weak deck] in deck?.releaseAll()}
        label.text="VETA / PS2";label.accessibilityIdentifier="ps2-web-metrics";label.font=UIFont(name:"BarlowCondensed-Bold",size:18)
        menu.setTitle(L10n.text("Menú"),for:.normal);menu.accessibilityIdentifier="ps2-web-pause"
        menu.addAction(UIAction{[weak session] _ in session?.openMenu()},for:.touchUpInside)
        play.accessibilityIdentifier="ps2-web-play"
        play.backgroundColor=UIColor(hex:0xa0efcf);play.tintColor=UIColor(hex:0x122c29)
        play.titleLabel?.font = .systemFont(ofSize:18,weight:.bold);play.layer.cornerRadius=10
        play.addAction(UIAction{[weak session] _ in session?.play()},for:.touchUpInside)
        timer=Timer.scheduledTimer(withTimeInterval:1/30,repeats:true){[weak session] _ in Task{@MainActor in session?.sendInputs()}}
        session.start();refresh()
    }
    override func viewDidAppear(_ animated:Bool){super.viewDidAppear(animated);if let router{ExternalDisplayHub.shared.registerNative(router)}}
    override func viewDidDisappear(_ animated:Bool){super.viewDidDisappear(animated);if isBeingDismissed || navigationController?.isBeingDismissed == true {cleanup()}}
    func cleanup(){timer?.invalidate();timer=nil;if let router{ExternalDisplayHub.shared.unregisterNative(router)}}
    func refresh(){label.accessibilityValue=session.metrics;deck.style=ControlStyle(console:.ps2);menu.isEnabled=session.running && !session.busy;play.setTitle(L10n.text(session.startPending ? "Iniciando…" : session.ready ? "Jugar" : "Preparando…"),for:.normal);play.isEnabled=session.ready && !session.startPending && !session.busy;play.isHidden=session.running;view.setNeedsLayout()}
    override func viewDidLayoutSubviews(){
        super.viewDidLayoutSubviews();let safe=view.safeAreaLayoutGuide.layoutFrame
        deck.applySkin(console:.ps2,landscape:safe.width>safe.height)
        let layout=ConsoleLayout(safe:safe,aspect:4/3,minimumDeck:GameConsole.ps2.minimumDeck,overlayLandscape:deck.usesLandscapeOverlay)
        deck.frame=layout.deck;picture.frame=layout.screen;shell.frame=view.bounds;shell.style=deck.style;shell.screenRect=layout.screen;shell.portraitSkinTop=deck.landscape ? nil:layout.toolbar.minY;shell.setNeedsDisplay()
        let playWidth=min(CGFloat(200),max(CGFloat(0),layout.screen.width-24))
        play.frame=CGRect(x:layout.screen.midX-playWidth/2,y:layout.screen.maxY-60,width:playWidth,height:48)
        label.frame=CGRect(x:layout.toolbar.minX+20,y:layout.toolbar.minY,width:180,height:44);label.textColor=deck.style.headerInk;label.isHidden=deck.usesLandscapeOverlay
        menu.frame=deck.usesLandscapeOverlay ? layout.toolbar:CGRect(x:layout.toolbar.maxX-94,y:layout.toolbar.minY,width:80,height:44);menu.tintColor=deck.usesLandscapeOverlay ? .white:deck.style.accent;menu.backgroundColor=deck.usesLandscapeOverlay ? UIColor.black.withAlphaComponent(0.4):.clear;menu.layer.cornerRadius=8
        shell.isHidden=deck.usesLandscapeOverlay;view.backgroundColor=deck.usesLandscapeOverlay ? .black:deck.style.background;tvLabel.frame=picture.bounds;router?.layout()
    }
}
private struct PS2WebSurface:UIViewControllerRepresentable {
    @ObservedObject var session:PS2WebSession
    func makeUIViewController(context:Context)->PS2WebViewController{PS2WebViewController(session:session)}
    func updateUIViewController(_ controller:PS2WebViewController,context:Context){controller.refresh()}
    static func dismantleUIViewController(_ controller:PS2WebViewController,coordinator:()){controller.cleanup()}
}
struct PS2WebGameContainer:View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session:PS2WebSession
    @State private var confirmLoad=false
    @State private var confirmExit=false
    @State private var showGallery=false
    init(game:Game,library:Library){_session=StateObject(wrappedValue:PS2WebSession(game:game,library:library))}
    #if DEBUG
    init(session:PS2WebSession){_session=StateObject(wrappedValue:session)}
    #endif
    var body:some View {
        PS2WebSurface(session:session).ignoresSafeArea().statusBarHidden(true)
            .overlay(alignment:.top){VStack {
                if !session.ready && session.error == nil {ProgressView(L10n.text(session.status))}
                if session.recoveredState && !session.running {Text("Se recuperó una copia anterior de la partida porque la más reciente estaba dañada.").font(.footnote)}
            }.padding().background((!session.ready || (session.recoveredState && !session.running)) ? VetaTheme.panel:Color.clear,in:RoundedRectangle(cornerRadius:12)).padding(.top,55)}
            .sheet(isPresented:$session.showMenu,onDismiss:{session.resume()}) {
                NavigationStack {Form {
                    Section(session.game.name){Button("Continuar"){session.showMenu=false};Button("Ir a la biblioteca"){confirmExit=true}.accessibilityIdentifier("ps2-web-exit")}
                    Section("Partidas") {
                        Button("Galería de partidas") { showGallery = true }.accessibilityIdentifier("ps2-web-gallery")
                        Button("Guardar partida"){session.state(load:false)}.accessibilityIdentifier("ps2-web-save")
                        Button("Cargar partida"){confirmLoad=true}.disabled(!session.hasQuick).accessibilityIdentifier("ps2-web-load")
                        if session.recoveredState {Text("Se recuperó una copia anterior de la partida porque la más reciente estaba dañada.").font(.footnote)}
                        Text("Este modo conserva sus propias partidas y no reemplaza las del modo de máximo rendimiento.").font(.footnote)
                        if !session.status.isEmpty{Text(L10n.text(session.status)).accessibilityIdentifier("ps2-web-status")}
                    }
                    Section("Controles"){NavigationLink("Skin"){ControllerSkinSettingsView(console:.ps2)};NavigationLink("Mandos y jugadores"){ControllerSettingsView(console:.ps2,supportsRumble:false)};NavigationLink("TV y pantalla completa"){ExternalDisplaySettingsView(nativeSurface:true)}}
                }.disabled(session.busy).interactiveDismissDisabled(session.busy).vetaForm().navigationTitle("PlayStation 2").tint(VetaTheme.mint)
                    .confirmationDialog("¿Cargar la partida guardada?",isPresented:$confirmLoad){Button("Cargar partida"){session.state(load:true)}.accessibilityIdentifier("ps2-web-confirm-load")}
                    .confirmationDialog("¿Salir del juego?",isPresented:$confirmExit){Button("Guardar y salir"){session.exit{dismiss()}}.accessibilityIdentifier("ps2-web-confirm-exit")}
                    .sheet(isPresented: $showGallery) {
                        if let store = session.manualSaveStore {
                            SaveGalleryView(gameName: session.game.name, store: store,
                                            save: { try await session.manualState($0, load: false) },
                                            load: { try await session.manualState($0, load: true) },
                                            allowedSlots: NativeSaveStore.manualSlots)
                        }
                    }
                }
            }
            .alert("VETA Retro",isPresented:Binding(get:{session.error != nil},set:{if !$0{session.error=nil}})) {
                Button("Aceptar"){session.error=nil}
                Button("Volver a la biblioteca"){session.stop();dismiss()}
            } message:{Text(session.error ?? "")}
            .onReceive(NotificationCenter.default.publisher(for:UIApplication.willResignActiveNotification)){_ in session.interrupt()}
            .onReceive(NotificationCenter.default.publisher(for:UIApplication.didBecomeActiveNotification)){_ in session.becameActive()}
            .onReceive(NotificationCenter.default.publisher(for:UIApplication.didEnterBackgroundNotification)){_ in session.backgroundSave()}
            .onReceive(NotificationCenter.default.publisher(for:AVAudioSession.interruptionNotification)){note in
                if (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue {session.interrupt()}
            }
            .onReceive(NotificationCenter.default.publisher(for:NSNotification.Name.GCControllerDidDisconnect)){_ in session.openMenu()}
            .onDisappear{session.stop()}
    }
}
#endif
