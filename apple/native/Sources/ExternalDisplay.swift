import SwiftUI
import AVKit

enum TVImageMode:String,CaseIterable,Identifiable {
    case automatic,pixels,smooth,sharpSmooth,xbr,spatial
    var id:String {rawValue}
    var title:String {switch self {case .automatic:return "Automático";case .pixels:return "Píxeles originales";case .smooth:return "Suavizado";case .sharpSmooth:return "Suavizado nítido";case .xbr:return "Bordes suaves · xBR";case .spatial:return "Reconstrucción · MetalFX"}}
    func filter(for console:GameConsole?,inherited:VideoFilter)->VideoFilter {
        switch self {case .automatic:return [GameConsole.n64,.ps1,.ps2,.psp,.dreamcast,.saturn,.ds,.threeDS,.gamecube,.wii].contains(where:{$0 == console}) ? .spatial:(console == nil ? inherited:.xbr);case .pixels:return .pixels;case .smooth:return .smooth;case .sharpSmooth:return .sharpSmooth;case .xbr:return .xbr;case .spatial:return .spatial}
    }
}
enum TVRenderQuality:String,CaseIterable,Identifiable {
    case balanced,fullHD,maximum
    var id:String {rawValue}
    var title:String {switch self {case .balanced:return "Equilibrada · 720p";case .fullHD:return "Alta · 1080p";case .maximum:return "Máxima disponible"}}
    var pixelLimit:CGSize {switch self {case .balanced:return CGSize(width:1280,height:720);case .fullHD:return CGSize(width:1920,height:1080);case .maximum:return CGSize(width:3840,height:2160)}}
}
enum TVImageGeometry {
    static func frame(in bounds:CGRect,aspect:CGFloat,scale:CGFloat)->CGRect {
        guard bounds.width>0,bounds.height>0,aspect.isFinite,aspect>0 else{return .zero}
        let factor=scale.isFinite ? min(1,max(0.5,scale)):1
        let width=min(bounds.width,bounds.height*aspect)*factor,height=width/aspect
        return CGRect(x:bounds.midX-width/2,y:bounds.midY-height/2,width:width,height:height)
    }
}
@MainActor final class ExternalDisplayHub: ObservableObject {
    static let shared = ExternalDisplayHub()
    @Published private(set) var connected = false
    @Published var enabled = UserDefaults.standard.object(forKey: "native.externalDisplay") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "native.externalDisplay"); reconcile() }
    }
    @Published var hidePhonePicture = UserDefaults.standard.bool(forKey: "native.hidePhonePicture") {
        didSet { UserDefaults.standard.set(hidePhonePicture, forKey: "native.hidePhonePicture") }
    }
    @Published var imageMode=TVImageMode(rawValue:UserDefaults.standard.string(forKey:"native.tvImageMode") ?? "") ?? .automatic {
        didSet {UserDefaults.standard.set(imageMode.rawValue,forKey:"native.tvImageMode");reconcile()}
    }
    @Published var imageScale:Double = {
        let value=UserDefaults.standard.object(forKey:"native.tvImageScale") as? Double ?? 1
        return value.isFinite ? min(1,max(0.5,value)):1
    }() {
        didSet {UserDefaults.standard.set(imageScale,forKey:"native.tvImageScale");reconcile()}
    }
    @Published var renderQuality=TVRenderQuality(rawValue:UserDefaults.standard.string(forKey:"native.tvRenderQuality") ?? "") ?? .fullHD {
        didSet {UserDefaults.standard.set(renderQuality.rawValue,forKey:"native.tvRenderQuality");reconcile()}
    }
    @Published private(set) var renderDiagnostics=""
    private var lastDiagnosticsTime:TimeInterval=0
    private var console:GameConsole?
    private var windows: [ObjectIdentifier: UIWindow] = [:]
    private var scenes: [ObjectIdentifier: UIWindowScene] = [:]
    private var observers: [NSObjectProtocol] = []
    private var aspect: CGFloat = 4 / 3
    private var presentation = VideoPresentation()
    private var isNintendoDS = false
    func configurePresentation(_ value:VideoPresentation, aspect:CGFloat, isNintendoDS:Bool = false,console:GameConsole? = nil) {self.console=console;presentation=value;self.isNintendoDS=isNintendoDS;configure(aspect:aspect)}
    #if VETA_JIT_DEVELOPMENT
    private weak var nativeRouter:(any ExternalSurfaceRouting)?
    func registerNative(_ router:any ExternalSurfaceRouting) {if nativeRouter !== router {nativeRouter?.route(to:nil);nativeRouter=router};configure(aspect:router.aspect)}
    func unregisterNative(_ router:any ExternalSurfaceRouting) {guard nativeRouter === router else{return};router.route(to:nil);nativeRouter=nil;reconcile()}
    #endif
    private init() {
        for name in [UIScreen.didConnectNotification, UIScreen.didDisconnectNotification, UIScene.didActivateNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.reconcile() } })
        }
        reconcile()
    }
    func attach(_ scene: UIWindowScene) {
        scenes[ObjectIdentifier(scene.screen)] = scene; reconcile()
    }
    func detach(_ scene: UIWindowScene) {
        let id = ObjectIdentifier(scene.screen)
        scenes.removeValue(forKey: id); windows.removeValue(forKey: id)?.isHidden = true; reconcile()
    }
    func configure(aspect: CGFloat) { self.aspect = max(0.1, aspect); reconcile() }
    private func reconcile() {
        let screens = UIScreen.screens.filter { $0 != .main }
        connected = !screens.isEmpty
        let ids = Set(screens.map(ObjectIdentifier.init))
        for id in Array(windows.keys) where !ids.contains(id) || !enabled { windows.removeValue(forKey: id)?.isHidden = true }
        #if VETA_JIT_DEVELOPMENT
        if !enabled || screens.isEmpty {nativeRouter?.route(to:nil)}
        #endif
        guard enabled else { return }
        for screen in screens {
            let id = ObjectIdentifier(screen)
            if windows[id] == nil {
                guard let scene = scenes[id] ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.screen == screen && $0.session.role == .windowExternalDisplayNonInteractive }) else { continue }
                let window = UIWindow(windowScene: scene)
                let controller = ExternalGameViewController(); controller.aspect = aspect
                window.rootViewController = controller; window.backgroundColor = .black; window.isHidden = false
                windows[id] = window
            }
            if let controller = windows[id]?.rootViewController as? ExternalGameViewController { controller.aspect = aspect; controller.screen.isNintendoDS=isNintendoDS;controller.screen.isNintendo3DS=console == .threeDS; var tvPresentation=presentation;tvPresentation.filter=imageMode.filter(for:console,inherited:presentation.filter);controller.screen.applyPresentation(tvPresentation);controller.imageScale=CGFloat(imageScale);controller.pixelLimit=renderQuality.pixelLimit; controller.view.setNeedsLayout() }
        }
        #if VETA_JIT_DEVELOPMENT
        var routed=false
        for screen in screens {
            guard let controller=windows[ObjectIdentifier(screen)]?.rootViewController as? ExternalGameViewController else{continue}
            controller.nativeMode=nativeRouter != nil
            controller.nativeRouter = routed ? nil:nativeRouter
            if let router=controller.nativeRouter {controller.loadViewIfNeeded();router.televisionPixelLimit=renderQuality.pixelLimit;router.televisionScale=CGFloat(imageScale);router.route(to:controller.view);routed=true}
            controller.view.setNeedsLayout()
        }
        if !routed {nativeRouter?.route(to:nil)}
        #endif
    }
    func presentFrame() {
        #if VETA_JIT_DEVELOPMENT
        guard nativeRouter == nil else{return}
        #endif
        guard enabled else { return }
        for window in windows.values { (window.rootViewController as? ExternalGameViewController)?.screen.presentFrame() }
        let now=ProcessInfo.processInfo.systemUptime
        if now-lastDiagnosticsTime>=1 {
            lastDiagnosticsTime=now
            let nextDiagnostics=windows.values.compactMap{($0.rootViewController as? ExternalGameViewController)?.screen.enhancementStatus}.first ?? ""
            // An unchanged diagnostic must not invalidate the phone's controller
            // layout every second, including when no external screen is connected.
            if renderDiagnostics != nextDiagnostics { renderDiagnostics=nextDiagnostics }
        }
    }
    func endGame() {
        presentation = .init(); isNintendoDS=false;console=nil;renderDiagnostics=""
        #if VETA_JIT_DEVELOPMENT
        nativeRouter?.route(to:nil);nativeRouter=nil
        #endif
        for window in windows.values { window.isHidden = true }
        windows.removeAll()
    }
}
/// Registered only for the external noninteractive role; SwiftUI owns the phone scene.
final class VetaExternalSceneDelegate: UIResponder, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        ExternalDisplayHub.shared.attach(scene)
    }
    func sceneDidDisconnect(_ scene: UIScene) {
        if let scene = scene as? UIWindowScene { ExternalDisplayHub.shared.detach(scene) }
    }
}
final class ExternalGameViewController: UIViewController {
    let screen = MetalScreen()
    var aspect: CGFloat = 4 / 3
    var imageScale:CGFloat = 1
    var pixelLimit=CGSize(width:1920,height:1080)
    #if VETA_JIT_DEVELOPMENT
    var nativeMode=false
    weak var nativeRouter:(any ExternalSurfaceRouting)?
    #endif
    override func viewDidLoad() { super.viewDidLoad(); view.backgroundColor = .black; screen.isPrimaryDisplay = false; screen.isUserInteractionEnabled = false; view.addSubview(screen) }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        #if VETA_JIT_DEVELOPMENT
        screen.isHidden=nativeMode
        if nativeMode {nativeRouter?.layout();return}
        #endif
        screen.contentScaleFactor=view.window?.screen.scale ?? UIScreen.main.scale
        screen.frame = TVImageGeometry.frame(in:view.bounds,aspect:aspect,scale:imageScale)
        screen.autoResizeDrawable=false
        let size=screen.bounds.size,scale=screen.contentScaleFactor
        if size.width>0,size.height>0 {
            let factor=min(scale,pixelLimit.width/size.width,pixelLimit.height/size.height)
            screen.drawableSize=CGSize(width:max(1,(size.width*factor).rounded(.down)),height:max(1,(size.height*factor).rounded(.down)))
        }
    }
}
struct AirPlayRouteButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView { let view = AVRoutePickerView(); view.prioritizesVideoDevices = true; return view }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
struct ExternalDisplaySettingsView: View {
    var nativeSurface=false
    @ObservedObject private var display = ExternalDisplayHub.shared
    var body: some View {
        Form {
            Section {
                Toggle("Juego a pantalla completa en TV", isOn: $display.enabled)
                if nativeSurface {Text("Al conectar una TV, el teléfono conserva los controles y la imagen se muestra solo en la pantalla externa.").font(.footnote)}
                else {Toggle("Usar iPhone solo como control", isOn: $display.hidePhonePicture)}
                Text(LocalizedStringKey(display.connected ? "Pantalla externa conectada" : "Conecta una pantalla por cable o activa Duplicar pantalla en el Centro de control."))
            }
            Section("Imagen en TV") {
                if !nativeSurface {
                    Picker("Filtro en TV",selection:$display.imageMode) {
                        ForEach(TVImageMode.allCases) {Text(LocalizedStringKey($0.title)).tag($0)}
                    }.accessibilityIdentifier("tv-image-filter")
                    Text("Automático usa xBR para pixel art y MetalFX espacial para gráficos 3D. Las pantallas DS y 3DS se procesan por separado. Solo cambia la imagen de la TV.").font(.footnote)
                }
                Picker("Definición en TV",selection:$display.renderQuality) {
                        ForEach(TVRenderQuality.allCases) {Text(LocalizedStringKey($0.title)).tag($0)}
                    }.accessibilityIdentifier("tv-render-quality")
                Text("Una definición mayor puede reducir la fluidez y aumentar la temperatura. La resolución interna depende de cada motor; AirPlay puede limitar la salida.").font(.footnote)
                if !nativeSurface && !display.renderDiagnostics.isEmpty {Text(display.renderDiagnostics).font(.caption).accessibilityIdentifier("tv-render-diagnostics")}
                Picker("Tamaño en TV",selection:$display.imageScale) {
                    Text("100 %").tag(1.0);Text("85 %").tag(0.85);Text("70 %").tag(0.7);Text("50 %").tag(0.5)
                }.accessibilityIdentifier("tv-image-size")
                Text("Reducir el tamaño deja bordes negros y conserva la proporción. Estos ajustes no añaden detalle al juego original.").font(.footnote)
            }
            Section("AirPlay") {
                Text("Para enviar imagen y sonido, abre el Centro de control del iPhone y toca Duplicar pantalla (dos rectángulos). Después selecciona tu TV.").font(.footnote)
                AirPlayRouteButton().frame(height: 44)
                Text("El selector AirPlay de abajo puede conectar solo el audio; no sustituye Duplicar pantalla.").font(.footnote)
                Text("La TV debe admitir AirPlay o usar un receptor compatible. La transmisión inalámbrica puede añadir retraso. El sonido sigue la salida de audio de iOS.").font(.footnote)
            }
            Section { Text("Los controles permanecen en el teléfono. La imagen conserva la proporción de la consola, con bandas cuando corresponda.").font(.footnote) }
        }.vetaForm().tint(VetaTheme.mint).navigationTitle("TV y pantalla completa").navigationBarTitleDisplayMode(.inline)
    }
}
