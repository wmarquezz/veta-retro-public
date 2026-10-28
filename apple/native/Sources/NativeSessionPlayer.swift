#if VETA_JIT_DEVELOPMENT
import SwiftUI
import Metal
import QuartzCore
import UniformTypeIdentifiers

final class NativeGameViewController:UIViewController {
    let session:NativeSessionModel
    private let screen=NativeMetalSurface()
    private let localPicture=UIView()
    private let televisionLabel=UILabel()
    private var router:NativeSurfaceRouter?
    private let shell=ConsoleShellView()
    private let deck=TouchDeck()
    private let label=UILabel()
    private let menu=UIButton(type:.system)
    init(session:NativeSessionModel) {self.session=session;super.init(nibName:nil,bundle:nil)}
    required init?(coder:NSCoder) {fatalError()}
    override var prefersHomeIndicatorAutoHidden:Bool {true}
    override func viewDidLoad() {
        super.viewDidLoad();deck.style=ControlStyle(console:session.game.console)
        [shell,localPicture,deck,label,menu].forEach(view.addSubview)
        localPicture.backgroundColor = .black;localPicture.addSubview(televisionLabel)
        televisionLabel.text=L10n.text("Imagen en TV");televisionLabel.textAlignment = .center;televisionLabel.textColor = .white;televisionLabel.isHidden=true
        let router=NativeSurfaceRouter(surface:screen,localHost:localPicture,aspect:session.game.console.aspect);self.router=router
        router.onRoutingChanged={ [weak self] external in self?.televisionLabel.isHidden = !external;self?.view.setNeedsLayout() }
        screen.onDrawableSizeChanged={ [weak session] size,hz in session?.updateDisplay(width:UInt32(size.width),height:UInt32(size.height),hz:hz) }
        label.text="VETA / "+session.game.console.shortName;label.font=UIFont(name:"BarlowCondensed-Bold",size:18)
        menu.setTitle(L10n.text("Menú"),for:.normal);menu.accessibilityIdentifier="standalone-pause"
        menu.addAction(UIAction { [weak session] _ in session?.openMenu() },for:.touchUpInside)
        deck.onInput={ [weak session] in session?.setTouches($0) }
        deck.onAnalog={ [weak session] in session?.setAnalog($0,$1) }
        session.releaseTouches={ [weak deck] in deck?.releaseAll() }
        refresh()
    }
    override func viewDidAppear(_ animated:Bool) {super.viewDidAppear(animated);if let router {ExternalDisplayHub.shared.registerNative(router)};session.prepare(layer:screen.metalLayer)}
    override func viewDidDisappear(_ animated:Bool) {super.viewDidDisappear(animated);if session.phase == .stopped,let router {ExternalDisplayHub.shared.unregisterNative(router)}}
    func refresh() {deck.style=ControlStyle(console:session.game.console);view.backgroundColor=deck.style.background;label.textColor=deck.style.headerInk;menu.tintColor=deck.style.accent;menu.isEnabled = [.running,.paused].contains(session.phase);view.setNeedsLayout()}
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe=view.safeAreaLayoutGuide.layoutFrame
        deck.applySkin(console:session.game.console,landscape:safe.width>safe.height)
        let layout=ConsoleLayout(safe:safe,aspect:session.game.console.aspect,minimumDeck:session.game.console.minimumDeck,overlayLandscape:deck.usesLandscapeOverlay)
        deck.frame=layout.deck;localPicture.frame=layout.screen
        shell.frame=view.bounds;shell.style=deck.style;shell.screenRect=layout.screen;shell.portraitSkinTop=deck.landscape ? nil:layout.toolbar.minY;shell.setNeedsDisplay()
        label.frame=CGRect(x:layout.toolbar.minX+20,y:layout.toolbar.minY,width:210,height:44)
        menu.frame=deck.usesLandscapeOverlay ? layout.toolbar:CGRect(x:layout.toolbar.maxX-94,y:layout.toolbar.minY,width:80,height:44)
        let fullscreen = router?.isExternal != true && !ControllerHub.shared.devices.isEmpty && (UserDefaults.standard.object(forKey:"native.fullscreenWithController") as? Bool ?? true)
        deck.isHidden=fullscreen
        if fullscreen {
            let ratio=session.game.console.aspect,w=min(safe.width,safe.height*ratio),h=w/ratio
            localPicture.frame=CGRect(x:safe.midX-w/2,y:safe.midY-h/2,width:w,height:h);shell.screenRect=localPicture.frame
            menu.frame=CGRect(x:safe.maxX-90,y:safe.minY+4,width:80,height:44);label.isHidden=true
        } else {label.isHidden=deck.usesLandscapeOverlay}
        shell.isHidden=fullscreen || deck.usesLandscapeOverlay
        view.backgroundColor=fullscreen || deck.usesLandscapeOverlay ? .black:deck.style.background
        menu.backgroundColor=deck.usesLandscapeOverlay ? UIColor.black.withAlphaComponent(0.4):.clear
        menu.tintColor=deck.usesLandscapeOverlay ? .white:deck.style.accent
        menu.layer.cornerRadius=8
        televisionLabel.frame=localPicture.bounds;router?.layout()
    }
}
private struct NativeSessionSurface:UIViewControllerRepresentable {
    @ObservedObject var session:NativeSessionModel
    let revision:Int
    func makeUIViewController(context:Context)->NativeGameViewController {NativeGameViewController(session:session)}
    func updateUIViewController(_ view:NativeGameViewController,context:Context) {view.refresh()}
}
struct NativeGameContainer:View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session:NativeSessionModel
    @State private var firmware=false
    @State private var xboxSystemFolder=false
    @State private var controls=false
    @State private var guides=false
    @State private var revision=0
    @State private var confirmExit=false
    @State private var confirmState=false
    @State private var loadingState=false
    @AppStorage("native.skin") private var skin="Clásica"
    init(game:Game,library:Library,plan:GameLaunchPlan? = nil) {
        _session=StateObject(wrappedValue:NativeSessionModel(game:game,library:library,plan:plan))
        _skin=AppStorage(wrappedValue:"Clásica",game.console.preferencePrefix+"skin")
    }
    var body:some View {
        NativeSessionSurface(session:session,revision:revision).ignoresSafeArea().statusBarHidden(true)
            .overlay(alignment:.top) {
                if [.idle,.preparing,.ready,.loading,.stopping,.failed,.stopped].contains(session.phase) {
                    VStack(spacing:12) {
                        Text(session.game.console.name).font(VetaTheme.heading(28))
                        Text(L10n.text(session.status)).font(.footnote).multilineTextAlignment(.center).accessibilityIdentifier("standalone-engine-status")
                        if let notice=session.executionNotice {Text(L10n.text(notice)).font(.footnote).multilineTextAlignment(.center).accessibilityIdentifier("standalone-offline-notice")}
                        #if VETA_EMBEDDED_JIT
                        if session.needsHelper {LocalVPNNotice()}
                        #endif
                        if session.canPrepare || session.canStart {
                            Button("Jugar"){session.play()}.buttonStyle(VetaButton(primary:true)).accessibilityIdentifier("standalone-play")
                        }
                        if session.canPrepare {
                            if session.needsHelper {Button(L10n.format("Activar con %@",JITSession.helperName)){session.activateHelper()}.buttonStyle(VetaButton(primary:true)).accessibilityIdentifier("standalone-activate-jit")}
                            else {Button("Preparar motor"){session.prepareEngine()}.buttonStyle(VetaButton(primary:true)).accessibilityIdentifier("standalone-prepare")}
                        }
                        if session.canImportXboxSystem {
                            Button("Importar sistema Xbox"){xboxSystemFolder=true;firmware=true}.buttonStyle(VetaButton()).accessibilityIdentifier("standalone-xbox-system")
                            Text("Elige la carpeta con flash.bin y xbox_hdd.qcow2. Añade mcpx_1.0.bin salvo con OXOS 0.3.3 verificado; xbox_eeprom.bin es opcional. Se copiarán a VETA.").font(.caption)
                        }
                        if session.game.console == .xbox {Text("Xbox permite una sesión por apertura de VETA. Después de salir del juego, cierra y vuelve a abrir la app para jugar otra vez.").font(.footnote)}
                        if session.canStart {Button("Iniciar juego"){session.start()}.buttonStyle(VetaButton(primary:true)).accessibilityIdentifier("standalone-start")}
                        if session.canInstallFirmware {Button("Instalar firmware PS3"){xboxSystemFolder=false;firmware=true}.buttonStyle(VetaButton()).accessibilityIdentifier("standalone-firmware")}
                        Text("Laboratorio: compatibilidad y rendimiento en evaluación. Las opciones disponibles dependen del motor.").font(.caption)
                        Button("Volver a la biblioteca"){session.stop {if $0 {dismiss()}}}.buttonStyle(VetaButton()).disabled(session.phase == .stopping)
                    }.padding(20).background(VetaTheme.panel,in:RoundedRectangle(cornerRadius:14)).padding(.top,60).padding(.horizontal,20)
                }
            }
            .sheet(isPresented:$session.showMenu,onDismiss:{revision+=1;session.resume()}) {
                NavigationStack {
                    Form {
                        Section(session.game.name) {
                            Text(L10n.text(session.status))
                            if let notice=session.executionNotice {Text(L10n.text(notice)).font(.footnote)}
                            if !session.capabilities.pause {Text("Este motor no permite pausar: el juego continúa mientras el menú está abierto. Los controles quedan desactivados hasta volver al juego.").font(.footnote)}
                            Button(LocalizedStringKey(session.capabilities.pause ? "Continuar":"Volver al juego")){session.showMenu=false}
                            Button {confirmExit=true} label:{Label("Ir a la biblioteca",systemImage:"books.vertical")}.accessibilityIdentifier("standalone-exit")
                        }
                        if session.capabilities.saveStates {
                            Section("Partidas") {
                                Button("Guardar partida"){if session.hasQuickState {loadingState=false;confirmState=true} else {session.saveQuickState()}}.disabled(!session.canUseStates).accessibilityIdentifier("standalone-save")
                                Button("Cargar partida"){loadingState=true;confirmState=true}.disabled(!session.canUseStates || !session.hasQuickState).accessibilityIdentifier("standalone-load")
                                if session.stateBusy {ProgressView()}
                                if let notice=session.stateNotice {Text(L10n.text(notice)).accessibilityIdentifier("standalone-state-notice")}
                                if session.game.console == .xbox {Text("El guardado rápido de Xbox incluye su disco virtual y pertenece a esta instalación.").font(.caption)}
                            }
                        }
                        Section {Button("Guía del juego"){guides=true}}
                        if session.supportsImageFilters {Section {NavigationLink("Imagen del juego"){VideoSettingsView(game:session.game,library:session.library)}.accessibilityIdentifier("standalone-image-settings")}}
                        Section("Controles") {
                            NavigationLink("Skin"){ControllerSkinSettingsView(console:session.game.console)}
                            Button("Personalizar controles"){controls=true}
                            if session.capabilities.input {NavigationLink("Mandos y jugadores"){ControllerSettingsView(console:session.game.console,supportsRumble:session.capabilities.rumble)}}
                            if session.capabilities.remoteControllers {NavigationLink("Jugar juntos"){PlayTogetherView(console:session.game.console)}}
                            if session.capabilities.externalDisplay {NavigationLink("TV y pantalla completa"){ExternalDisplaySettingsView(nativeSurface:true)}}
                        }
                        Section {Text("Este motor administra su propio audio. La TV usa la misma superficie de juego; el teléfono conserva los controles.").font(.footnote)}
                        if session.game.console == .xbox {Section {Text("Xbox permite una sesión por apertura de VETA. Después de salir del juego, cierra y vuelve a abrir la app para jugar otra vez.").font(.footnote)}}
                    }.disabled(session.stateBusy).vetaForm().navigationTitle(session.game.console.name).tint(VetaTheme.mint)
                        .confirmationDialog("¿Salir del juego?",isPresented:$confirmExit,titleVisibility:.visible){Button("Salir",role:.destructive){session.stop {if $0 {session.showMenu=false;dismiss()}}}}
                        .confirmationDialog(LocalizedStringKey(loadingState ? "¿Cargar la partida guardada? Se reemplazará el momento actual.":"¿Reemplazar el guardado rápido?"),isPresented:$confirmState,titleVisibility:.visible) {
                            Button("Confirmar",role:.destructive){if loadingState {session.loadQuickState()} else {session.saveQuickState()}}
                            Button("Cancelar",role:.cancel){}
                        }
                }.interactiveDismissDisabled()
                    .sheet(isPresented:$guides){GameGuidesView(game:session.game,library:session.library)}
                    .sheet(isPresented:$controls,onDismiss:{revision+=1}){ControlsSettings(console:session.game.console)}
            }
            .fileImporter(isPresented:$firmware,allowedContentTypes:xboxSystemFolder ? [.folder]:[.data],allowsMultipleSelection:false) {result in
                switch result {case .success(let urls):if let url=urls.first {if xboxSystemFolder {session.importXboxSystem(url)} else {session.installFirmware(url)}};case .failure(let error):session.error=error.localizedDescription}
            }
            .alert("VETA Retro",isPresented:Binding(get:{session.error != nil},set:{if !$0{session.error=nil}})){Button("Aceptar"){session.error=nil}} message:{Text(L10n.text(session.error ?? ""))}
            .onDisappear {session.stop(reason:"player-disappeared")}
    }
}
#endif
