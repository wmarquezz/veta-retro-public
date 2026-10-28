import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct FastForwardClock {
    private(set) var accumulated=0.0
    mutating func reset(){accumulated=0}
    /// At most four frames per callback. Slow devices drop catch-up time;
    /// this requests up to2x without pretending the core achieved that speed.
    mutating func advance(elapsed:Double,fps:Double,runFrame:()->Void)->Int {
        guard elapsed.isFinite,elapsed>=0,fps.isFinite,fps>0 else{return 0}
        let interval=1/fps;accumulated+=min(elapsed,0.1)*2
        var count=0
        while accumulated+interval*0.000001>=interval,count<4 {runFrame();accumulated-=interval;count+=1}
        if count==4 {accumulated=min(accumulated,interval)}
        return count
    }
}
enum GameplayControlPolicy {
    static func fastForwardAvailable(_ console:GameConsole)->Bool {[.nes,.gb,.gbc,.gba,.snes].contains(console)}
    static func allowedHoldMask(_ console:GameConsole)->UInt16 {
        switch console {case .nes,.gb,.gbc:return 0x0101;case .gba:return 0x0d01;case .snes:return 0x0f03;default:return 0}
    }
    static func heldButtons(_ console:GameConsole)->[(String,UInt16)] {
        let all:[(String,UInt16)]=[("B",1),("Y",2),("A",256),("X",512),("L",1024),("R",2048)]
        return all.filter{allowedHoldMask(console)&$0.1 != 0}
    }
}
enum AudioPlaybackPolicy:String,CaseIterable,Identifiable {
    case exclusive,respectSilent,mix
    var id:String {rawValue}
    static var current:Self {Self(rawValue:UserDefaults.standard.string(forKey:"native.audioPolicy") ?? "") ?? .exclusive}
    var title:String {switch self {case .exclusive:return "Audio exclusivo";case .respectSilent:return "Respetar silencio";case .mix:return "Mezclar con otra música"}}
    var category:AVAudioSession.Category {self == .respectSilent ? .ambient:.playback}
    var options:AVAudioSession.CategoryOptions {self == .mix ? [.mixWithOthers]:[]}
}
struct NESCheat:Codable,Identifiable,Equatable {
    var id=UUID()
    var name:String
    var code:String
    var enabled:Bool
    static func normalized(_ value:String)throws->String {
        let code=value.trimmingCharacters(in:.whitespacesAndNewlines).uppercased()
        guard code.utf8.count<=10,!code.utf8.contains(0),code.withCString({veta_nes_cheat_valid($0)}) else {throw VetaError.message("Usa un código Game Genie NES de 6 u 8 letras, o AAAA:VV hexadecimal. Un código por entrada.")}
        return code
    }
    static func validated(_ list:[Self])throws->[Self] {
        guard list.count<=16,Set(list.map(\.id)).count==list.count else {throw VetaError.message("Puedes guardar hasta 16 trucos NES por juego.")}
        var result=list
        for index in result.indices {
            result[index].name=result[index].name.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !result[index].name.isEmpty,result[index].name.count<=64,result[index].name.utf8.count<=256 else {throw VetaError.message("Escribe un nombre de hasta 64 caracteres para el truco.")}
            result[index].code=try normalized(result[index].code)
        }
        guard Set(result.map(\.code)).count==result.count else {throw VetaError.message("Ese código ya está en la lista de trucos.")}
        return result
    }
    static func install(_ list:[Self])throws {
        let codes=try validated(list).filter(\.enabled).map(\.code)
        let strings=codes.map{strdup($0)!};defer{strings.forEach{free($0)}}
        let pointers:[UnsafePointer<CChar>?]=strings.map{UnsafePointer<CChar>($0)}
        guard pointers.withUnsafeBufferPointer({veta_nes_cheats_replace($0.baseAddress,$0.count)}) else {throw VetaError.message("Los trucos todavía no están disponibles para este motor.")}
    }
}
struct NESCheatStore {
    let url:URL
    private struct File:Codable {let version:Int;let cheats:[NESCheat]}
    func read()throws->[NESCheat] {
        guard FileManager.default.fileExists(atPath:url.path) else{return []}
        let info=try url.resourceValues(forKeys:[.isSymbolicLinkKey,.fileSizeKey])
        guard info.isSymbolicLink != true,(info.fileSize ?? 0)<=65536 else {throw VetaError.message("El archivo de trucos NES no es válido.")}
        let file=try JSONDecoder().decode(File.self,from:Data(contentsOf:url))
        guard file.version==1 else {throw VetaError.message("El archivo de trucos NES no es válido.")}
        return try NESCheat.validated(file.cheats)
    }
    func write(_ cheats:[NESCheat])throws {
        let data=try JSONEncoder().encode(File(version:1,cheats:NESCheat.validated(cheats)))
        try data.write(to:url,options:.atomic)
    }
}
@MainActor enum GameplayScreenshot {
    static func png()->Data? {
        let width=Int(veta_width()),height=Int(veta_height())
        guard width>0,height>0,width<=4096,height<=4096,veta_frame_count()>0,let pixels=veta_video() else{return nil}
        let bytes=Data(bytes:pixels,count:width*height*4)
        guard let provider=CGDataProvider(data:bytes as CFData),let image=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.noneSkipFirst.rawValue).union(.byteOrder32Little),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else{return nil}
        return UIImage(cgImage:image).pngData()
    }
}

/// Insert into the classic player's pause Form. All transient controls are
/// released by Emulation.pause/close; settings chosen here arm the next resume.
struct GameplayToolsSection:View {
    @ObservedObject var emulation:Emulation
    let shareScreenshot:(URL)->Void
    let showCheats:()->Void
    @State private var audioPolicy=AudioPlaybackPolicy.current
    var body:some View {
        Section("Herramientas de juego") {
            if emulation.supportsFastForward {Button("Continuar a 2× (sin sonido)"){emulation.resumeFastForward()}.accessibilityIdentifier("gameplay-fast-forward")}
            if emulation.fastForward {Button("Volver a velocidad normal"){emulation.setFastForward(false)}}
            if !GameplayControlPolicy.heldButtons(emulation.game.console).isEmpty {
                Menu("Mantener botones al continuar") {
                    ForEach(GameplayControlPolicy.heldButtons(emulation.game.console),id:\.0) {name,mask in
                        Toggle(name,isOn:Binding(get:{emulation.heldButtons&mask != 0},set:{emulation.setHeldButtons($0 ? emulation.heldButtons|mask:emulation.heldButtons & ~mask)}))
                    }
                    Button("Liberar todos los botones"){emulation.setHeldButtons(0)}
                }
                Text("Los botones mantenidos se liberan al pausar, salir o interrumpirse el juego.").font(.caption)
            }
            Button("Compartir captura PNG") {do {shareScreenshot(try emulation.captureScreenshot())}catch{emulation.error=error.localizedDescription}}.accessibilityIdentifier("gameplay-screenshot")
            if emulation.game.console == .nes {Button("Trucos NES"){showCheats()}.accessibilityIdentifier("gameplay-cheats")}
            Picker("Comportamiento del audio",selection:$audioPolicy) {ForEach(AudioPlaybackPolicy.allCases){Text(LocalizedStringKey($0.title)).tag($0)}}
                .onChange(of:audioPolicy){value in UserDefaults.standard.set(value.rawValue,forKey:"native.audioPolicy")}
        }
    }
}
struct GameplayScreenshotShare:Identifiable {let id=UUID();let url:URL}
struct GameplayShareSheet:UIViewControllerRepresentable {
    let url:URL
    func makeUIViewController(context:Context)->UIActivityViewController {UIActivityViewController(activityItems:[url],applicationActivities:nil)}
    func updateUIViewController(_ view:UIActivityViewController,context:Context){}
}
struct NESCheatsView:View {
    @ObservedObject var emulation:Emulation
    @Environment(\.dismiss) private var dismiss
    @State private var items:[NESCheat]=[]
    @State private var name=""
    @State private var code=""
    @State private var issue:String?
    private func save(_ next:[NESCheat]) {do{try emulation.applyNESCheats(next);items=next}catch{issue=error.localizedDescription}}
    var body:some View {
        NavigationStack {
            Form {
                Section {Text("Los trucos cambian el comportamiento del juego y pueden afectar las partidas. Desactívalos para volver al comportamiento normal.").font(.footnote)}
                Section("Trucos guardados") {
                    ForEach(items) {item in
                        Toggle(isOn:Binding(get:{items.first(where:{$0.id==item.id})?.enabled ?? false},set:{value in var next=items;if let i=next.firstIndex(where:{$0.id==item.id}){next[i].enabled=value;save(next)}})) {VStack(alignment:.leading){Text(verbatim:item.name);Text(verbatim:item.code).font(.caption.monospaced())}}
                    }.onDelete{indices in var next=items;next.remove(atOffsets:indices);save(next)}
                }
                Section("Agregar truco") {
                    TextField("Nombre del truco",text:$name)
                    TextField("Game Genie o AAAA:VV",text:$code).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    Button("Guardar truco") {do {let next=try NESCheat.validated(items+[NESCheat(name:name,code:code,enabled:false)]);try emulation.applyNESCheats(next);items=next;name="";code=""}catch{issue=error.localizedDescription}}
                    Text("Los códigos nuevos se guardan desactivados. Actívalos cuando quieras probarlos.").font(.caption)
                }
            }.vetaForm().tint(VetaTheme.mint).navigationTitle("Trucos NES").navigationBarTitleDisplayMode(.inline)
                .toolbar{ToolbarItem(placement:.confirmationAction){Button("Listo"){dismiss()}}}
                .onAppear{do{items=try emulation.nesCheats()}catch{issue=error.localizedDescription}}
                .alert("VETA Retro",isPresented:Binding(get:{issue != nil},set:{if !$0{issue=nil}})){Button("Aceptar"){issue=nil}}message:{Text(L10n.text(issue ?? ""))}
        }
    }
}
