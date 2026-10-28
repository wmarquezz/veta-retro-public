import SwiftUI

private extension GameConsole {
    var usesXboxVideoPresentation:Bool {
        #if VETA_JIT_DEVELOPMENT
        return self == .xbox
        #else
        return false
        #endif
    }
}

enum VideoFilter: String, Codable, CaseIterable, Identifiable {
    case pixels, smooth, crt, lcd, sharpSmooth, xbr, spatial
    var id: String { rawValue }
    var title: String { switch self {case .pixels:return "Píxeles originales";case .smooth:return "Suavizado";case .crt:return "CRT suave";case .lcd:return "Rejilla LCD";case .sharpSmooth:return "Suavizado nítido";case .xbr:return "Bordes suaves · xBR";case .spatial:return "Reconstrucción · MetalFX"} }
    var shaderValue: UInt32 { UInt32(Self.allCases.firstIndex(of:self)!) }
}
enum DSScreenLayout: String, Codable, CaseIterable, Identifiable {
    case stacked, sideBySide, bottomOnly, topOnly, swapped, automatic
    var id: String { rawValue }
    var title: String { switch self {case .stacked:return "Una sobre otra";case .sideBySide:return "Lado a lado";case .bottomOnly:return "Solo pantalla táctil";case .topOnly:return "Solo pantalla superior";case .swapped:return "Táctil arriba";case .automatic:return "Automático"} }
    var shaderValue: UInt32 { UInt32(Self.allCases.firstIndex(of:self)!) }
    var aspect: CGFloat { self == .sideBySide ? 8/3 : [.bottomOnly,.topOnly].contains(self) ? 4/3 : 2/3 }
    func sourcePoint(_ point: CGPoint) -> CGPoint {
        switch self {
        case .stacked,.automatic: return point
        case .sideBySide: return CGPoint(x: point.x < 0.5 ? point.x*2 : (point.x-0.5)*2, y: point.y/2+(point.x<0.5 ? 0:0.5))
        case .bottomOnly:return CGPoint(x:point.x,y:0.5+point.y/2)
        case .topOnly:return CGPoint(x:point.x,y:point.y/2)
        case .swapped:return CGPoint(x:point.x,y:point.y<0.5 ? point.y+0.5:point.y-0.5)
        }
    }
    func touchPoint(_ point: CGPoint) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite, point.x>=0,point.x<=1,point.y>=0,point.y<=1,self != .topOnly else{return nil}
        let mapped=sourcePoint(point)
        return mapped.y>=0.5 ? mapped:nil
    }
}
struct VideoPresentation: Codable, Equatable {
    var filter: VideoFilter = .pixels
    var dsLayout: DSScreenLayout = .automatic
    func validated(for console:GameConsole) -> Self {
        let safeFilter:VideoFilter=console.usesXboxVideoPresentation ? (filter == .xbr ? .xbr:.spatial):(console.isStandaloneEngine ? .pixels:filter)
        return Self(filter:safeFilter,dsLayout:console == .ds ? dsLayout:.stacked)
    }
    /// Resolve orientation for this display only; saved per-game profiles and
    /// the independently routed TV display are never rewritten by rotation.
    func resolved(for console:GameConsole,landscape:Bool)->Self {
        var value=validated(for:console)
        if console == .ds && value.dsLayout == .automatic {value.dsLayout=landscape ? .sideBySide:.stacked}
        return value
    }
}
enum ThreeDSScreenGeometry {
    /// Azahar's frame is 400x480: 400x240 above, 320x240 centered below.
    /// Landscape displays 400+320 pixels across, without stretching either.
    static func sourcePoint(_ point:CGPoint)->CGPoint {
        let split:CGFloat=5/9
        if point.x<split {return CGPoint(x:point.x/split,y:point.y/2)}
        return CGPoint(x:0.1+(point.x-split)/(1-split)*0.8,y:0.5+point.y/2)
    }
    static func touchPoint(_ point:CGPoint)->CGPoint? {
        guard point.x.isFinite,point.y.isFinite,point.x>=5/9,point.x<=1,point.y>=0,point.y<=1 else{return nil}
        return sourcePoint(point)
    }
}
@MainActor struct VideoProfileStore {
    let library: Library
    let game: Game
    private var defaultPresentation:VideoPresentation {game.console.usesXboxVideoPresentation ? .init(filter:.spatial):.init()}
    private var consoleURL:URL {library.root.appendingPathComponent("display-"+game.console.rawValue+".json")}
    func consoleProfile() -> VideoPresentation {guard let info=try? consoleURL.resourceValues(forKeys:[.fileSizeKey,.isSymbolicLinkKey]),info.isSymbolicLink != true,let size=info.fileSize,size<=4096,let data=try? Data(contentsOf:consoleURL),data.count<=4096 else{return defaultPresentation};return (try? JSONDecoder().decode(VideoPresentation.self,from:data))?.validated(for:game.console) ?? defaultPresentation}
    func resolved() -> VideoPresentation {(library.games.first(where:{$0.id==game.id})?.videoPresentation ?? consoleProfile()).validated(for:game.console)}
    func save(_ value:VideoPresentation?,forConsole:Bool)throws {
        if forConsole {try JSONEncoder().encode((value ?? .init()).validated(for:game.console)).write(to:consoleURL,options:.atomic)}
        else {
            guard let index=library.games.firstIndex(where:{$0.id==game.id}) else{throw VetaError.message("El juego ya no está en la biblioteca.")}
            var next=library.games;next[index].videoPresentation=value?.validated(for:game.console)
            try JSONEncoder().encode(next).write(to:library.root.appendingPathComponent("library.json"),options:.atomic);library.games=next
        }
    }
}
extension Emulation {
    var presentation:VideoPresentation {VideoProfileStore(library:library,game:game).resolved()}
    var presentationAspect:CGFloat {game.console == .ds ? presentation.dsLayout.aspect:game.console.aspect}
}
struct VideoSettingsView:View {
    let game:Game
    @ObservedObject var library:Library
    @State private var consoleScope=false
    @State private var presentation=VideoPresentation()
    @State private var message:String?
    var body:some View {
        Form {
            Section {
                Picker("Aplicar a",selection:$consoleScope){Text("Este juego").tag(false);Text("Toda la consola").tag(true)}
                Picker("Filtro de imagen",selection:$presentation.filter){ForEach(game.console.usesXboxVideoPresentation ? [VideoFilter.spatial,.xbr]:VideoFilter.allCases){Text(LocalizedStringKey(game.console.usesXboxVideoPresentation && $0 == .spatial ? "Automático":$0.title)).tag($0)}}.accessibilityIdentifier("video-filter-picker")
                if game.console == .ds {Picker("Pantallas Nintendo DS",selection:$presentation.dsLayout){ForEach(DSScreenLayout.allCases){Text(LocalizedStringKey($0.title)).tag($0)}}}
                Text("Los filtros cambian la presentación, no la resolución interna del motor. Pueden aumentar el consumo. Los cambios se ven al volver al juego.").font(.caption)
                if game.console == .ds {Text("La entrada táctil sigue la posición de la pantalla inferior. En el modo de pantalla superior no hay entrada táctil.").font(.caption)}
            }.listRowBackground(VetaTheme.panel)
            Section {
                Button("Guardar"){perform{try VideoProfileStore(library:library,game:game).save(presentation,forConsole:consoleScope)}}
                Button("Restaurar valores heredados"){perform{try VideoProfileStore(library:library,game:game).save(nil,forConsole:consoleScope);reload()}}
                if let message {Text(L10n.text(message)).font(.caption)}
            }.listRowBackground(VetaTheme.panel)
        }.vetaForm().navigationTitle("Imagen del juego").onAppear{reload()}.onChange(of:consoleScope){_ in reload();message=nil}
    }
    private func reload(){let store=VideoProfileStore(library:library,game:game);presentation=consoleScope ? store.consoleProfile():store.resolved()}
    private func perform(_ action:()throws->Void){do{try action();message="Cambios guardados"}catch{message=error.localizedDescription}}
}
