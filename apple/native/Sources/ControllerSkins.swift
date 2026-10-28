import Foundation
import CoreGraphics
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum ControllerSkinOrientation:String,Codable,CaseIterable {case portrait,landscape
    var title:String {self == .portrait ? "Vertical":"Horizontal"}
    var canvas:CGSize {self == .portrait ? CGSize(width:400,height:320):CGSize(width:844,height:320)}
}
enum ControllerSkinPalette:String,Codable,CaseIterable {case studio="Estudio",classic="Clásica",veta="VETA",night="Noche",transparent="Transparente"}
enum ControllerSkinError:Error,LocalizedError {
    case invalid,wrongConsole,wrongOrientation,overlap,tooSmall
    var errorDescription:String? {let key:String = switch self {
    case .invalid:"El diseño no es un archivo VETA válido."
    case .wrongConsole:"Este diseño pertenece a otra consola."
    case .wrongOrientation:"Este diseño pertenece a otra orientación."
    case .overlap:"Los controles se superponen o invaden la pantalla."
    case .tooSmall:"No hay espacio para controles de al menos 44 puntos."
    };return L10n.text(key)}
}
struct ControllerSkinControl:Codable,Equatable {
    var id:String
    var x:Double;var y:Double;var width:Double;var height:Double
    init(id:String,rect:CGRect,canvas:CGSize) {self.id=id;x=rect.minX/canvas.width;y=rect.minY/canvas.height;width=rect.width/canvas.width;height=rect.height/canvas.height}
    func rect(in size:CGSize)->CGRect {CGRect(x:x*size.width,y:y*size.height,width:width*size.width,height:height*size.height)}
}
struct ControllerSkinLayout:Codable,Equatable {
    static let byteLimit=65_536
    var format="veta-controller-layout"
    var version=1
    var console:String
    var orientation:ControllerSkinOrientation
    var palette:ControllerSkinPalette
    var controls:[ControllerSkinControl]
    // Version 1 retains its implicit canvas, including existing 3DS exports.
    // Version 2 changes only the new 3DS portrait canvas, with the same schema.
    // Version 4 explicitly selects the compact DS portrait canvas; v1 is unchanged.
    var usesLandscapeOverlay:Bool {version == 3 && orientation == .landscape}
    var usesCompactThreeDSCanvas:Bool {version == 2 && console == GameConsole.threeDS.rawValue && orientation == .portrait}
    var usesCompactDSCanvas:Bool {version == 4 && console == GameConsole.ds.rawValue && orientation == .portrait}
    var canvas:CGSize {usesCompactDSCanvas ? CGSize(width:400,height:188):usesCompactThreeDSCanvas ? CGSize(width:400,height:240):Self.referenceSize(console:GameConsole(rawValue:console) ?? .nes,orientation:orientation)}
    static func referenceSize(console:GameConsole,orientation:ControllerSkinOrientation)->CGSize {
        orientation == .portrait ? CGSize(width:400,height:max(276,console.minimumDeck)):orientation.canvas
    }
    static func makeDefault(console:GameConsole,orientation:ControllerSkinOrientation,palette:ControllerSkinPalette)->Self {
        var style=ControlStyle(console:console,defaults:nil);style.skin=palette.rawValue
        let compact=console == .threeDS && orientation == .portrait
        let size=compact ? CGSize(width:400,height:240):referenceSize(console:console,orientation:orientation)
        let overlay=orientation == .landscape
        let base=overlay ? TouchDeck.overlayZones(style:style,size:size):TouchDeck.baseZones(style:style,size:size,landscape:false)
        let zones=ControllerSkinGeometry.fitted(base,size:size,orientation:orientation,overlay:overlay)
        return Self(version:overlay ? 3:compact ? 2:1,console:console.rawValue,orientation:orientation,palette:palette,controls:zones.keys.sorted().map {ControllerSkinControl(id:$0,rect:zones[$0]!,canvas:size)})
    }
    func validated(console expected:GameConsole,orientation expectedOrientation:ControllerSkinOrientation)throws {
        guard format == "veta-controller-layout",version == 1 || usesCompactThreeDSCanvas || usesLandscapeOverlay || usesCompactDSCanvas,controls.count<=32 else {throw ControllerSkinError.invalid}
        guard console == expected.rawValue else {throw ControllerSkinError.wrongConsole}
        guard orientation == expectedOrientation else {throw ControllerSkinError.wrongOrientation}
        let allowed=Set(TouchDeck.baseZones(style:ControlStyle(console:expected,defaults:nil),size:canvas,landscape:orientation == .landscape).keys)
        guard Set(controls.map(\.id)) == allowed,controls.count == allowed.count else {throw ControllerSkinError.invalid}
        for c in controls {
            guard [c.x,c.y,c.width,c.height].allSatisfy({$0.isFinite && $0>=0 && $0<=1}),c.width>0,c.height>0,c.x+c.width<=1.000001,c.y+c.height<=1.000001 else {throw ControllerSkinError.invalid}
        }
        try ControllerSkinGeometry.validate(Dictionary(uniqueKeysWithValues:controls.map{($0.id, $0.rect(in:canvas))}),size:canvas,orientation:orientation,overlay:usesLandscapeOverlay)
    }
    func resolved(console:GameConsole,orientation:ControllerSkinOrientation,size:CGSize)throws->[String:CGRect] {
        try validated(console:console,orientation:orientation)
        guard size.width.isFinite,size.height.isFinite,size.width>=44,size.height>=44 else {throw ControllerSkinError.tooSmall}
        var zones:[String:CGRect]=[:]
        for c in controls {
            var scaled=c.rect(in:size)
            if orientation == .landscape {
                let reference=c.rect(in:canvas)
                if usesLandscapeOverlay {
                    let rail=ControllerSkinGeometry.overlayRail(canvas)
                    if reference.maxX<=rail {scaled.origin.x=reference.minX}
                    else if reference.minX>=canvas.width-rail {scaled.origin.x=size.width-(canvas.width-reference.minX)}
                    else {scaled.origin.x=size.width/2+(reference.minX-canvas.width/2)}
                    scaled.origin.y=reference.midY>=canvas.height/2 ? size.height-(canvas.height-reference.minY):reference.minY
                    scaled.size=reference.size
                } else {
                    scaled.origin.x=reference.midX<canvas.width/2 ? reference.minX:size.width-(canvas.width-reference.minX)
                    scaled.size.width=reference.width
                }
            }
            let w=max(44,scaled.width),h=max(44,scaled.height)
            zones[c.id]=CGRect(x:max(0,min(size.width-w,scaled.midX-w/2)),y:max(0,min(size.height-h,scaled.midY-h/2)),width:w,height:h)
        }
        // Never silently move a user's controls onto other controls or the image.
        try ControllerSkinGeometry.validate(zones,size:size,orientation:orientation,overlay:usesLandscapeOverlay)
        return zones
    }
    mutating func move(_ id:String,to center:CGPoint)throws {
        guard center.x.isFinite,center.y.isFinite,let index=controls.firstIndex(where:{$0.id==id}),let console=GameConsole(rawValue:console) else {throw ControllerSkinError.invalid}
        var next=self;let size=canvas,r=controls[index].rect(in:size)
        let rect=CGRect(x:max(0,min(size.width-r.width,center.x-r.width/2)),y:max(0,min(size.height-r.height,center.y-r.height/2)),width:r.width,height:r.height)
        next.controls[index]=ControllerSkinControl(id:id,rect:rect,canvas:size)
        try next.validated(console:console,orientation:orientation);self=next
    }
    func encoded()throws->Data {
        guard let console=GameConsole(rawValue:console) else {throw ControllerSkinError.invalid}
        try validated(console:console,orientation:orientation)
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        let data=try encoder.encode(self);guard data.count<=Self.byteLimit else {throw ControllerSkinError.invalid};return data
    }
    static func decode(_ data:Data,console:GameConsole,orientation:ControllerSkinOrientation)throws->Self {
        guard !data.isEmpty,data.count<=byteLimit,
              let object=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              Set(object.keys)==Set(["format","version","console","orientation","palette","controls"]),
              let items=object["controls"] as? [[String:Any]],items.count<=32,
              items.allSatisfy({Set($0.keys)==Set(["id","x","y","width","height"])}) else {throw ControllerSkinError.invalid}
        let layout=try JSONDecoder().decode(Self.self,from:data)
        try layout.validated(console:console,orientation:orientation);return layout
    }
    static func read(_ url:URL,console:GameConsole,orientation:ControllerSkinOrientation)throws->Self {
        // Fixed schema has no file paths, URLs, images, archives or executable fields.
        guard url.isFileURL else {throw ControllerSkinError.invalid}
        let scoped=url.startAccessingSecurityScopedResource();defer{if scoped {url.stopAccessingSecurityScopedResource()}}
        let handle=try FileHandle(forReadingFrom:url);defer{try? handle.close()}
        let data=try handle.read(upToCount:byteLimit+1) ?? Data()
        return try decode(data,console:console,orientation:orientation)
    }
}
enum ControllerSkinGeometry {
    static func overlayRail(_ size:CGSize)->CGFloat {min(220,max(200,size.width*0.29))}
    static func allowed(_ rect:CGRect,size:CGSize,orientation:ControllerSkinOrientation,overlay:Bool = false)->Bool {
        guard rect.minX>=(-0.001),rect.minY>=(-0.001),rect.maxX<=size.width+0.001,rect.maxY<=size.height+0.001 else{return false}
        if orientation == .landscape {
            if overlay {
                let menu=CGRect(x:size.width/2-44,y:0,width:88,height:44)
                let intersection=rect.intersection(menu)
                if !intersection.isNull && intersection.width>0.01 && intersection.height>0.01 {return false}
                let rail=overlayRail(size)
                return rect.maxX<=rail+0.001 || rect.minX>=size.width-rail-0.001 || rect.minY>=size.height-48.001
            }
            let rail=min(188,size.width/2)
            return rect.maxX<=rail+0.001 || rect.minX>=size.width-rail-0.001
        }
        return true
    }
    static func validate(_ zones:[String:CGRect],size:CGSize,orientation:ControllerSkinOrientation,overlay:Bool = false)throws {
        let names=zones.keys.sorted()
        for (i,name) in names.enumerated() {
            let r=zones[name]!
            guard [r.minX,r.minY,r.width,r.height].allSatisfy(\.isFinite),r.width>=43.999,r.height>=43.999 else {throw ControllerSkinError.tooSmall}
            guard allowed(r,size:size,orientation:orientation,overlay:overlay) else {throw ControllerSkinError.overlap}
            for other in names.prefix(i) {let overlap=r.intersection(zones[other]!);if !overlap.isNull && overlap.width>0.01 && overlap.height>0.01 {throw ControllerSkinError.overlap}}
        }
    }
    // Preserve original positions when valid; repair small-screen collisions by
    // finding the nearest free target. Every drawing and hit test uses this map.
    static func fitted(_ base:[String:CGRect],size:CGSize,orientation:ControllerSkinOrientation,overlay:Bool = false)->[String:CGRect] {
        guard size.width.isFinite,size.height.isFinite,size.width>=44,size.height>=44 else{return [:]}
        var result:[String:CGRect]=[:]
        let ordered=base.keys.sorted {a,b in let aa=base[a]!.width*base[a]!.height,bb=base[b]!.width*base[b]!.height;return aa == bb ? a<b:aa>bb}
        for name in ordered {
            let original=base[name]!,maxW=orientation == .landscape ? (overlay ? overlayRail(size):min(188,size.width/2)):size.width
            let w=min(maxW,max(44,original.width)),h=min(size.height,max(44,original.height))
            let desired=CGRect(x:max(0,min(size.width-w,original.minX)),y:max(0,min(size.height-h,original.minY)),width:w,height:h)
            func free(_ r:CGRect)->Bool {allowed(r,size:size,orientation:orientation,overlay:overlay) && !result.values.contains{let v=r.intersection($0);return !v.isNull && v.width>0.01 && v.height>0.01}}
            if free(desired) {result[name]=desired;continue}
            var best:CGRect?,distance=CGFloat.greatestFiniteMagnitude
            for y in stride(from:CGFloat(0),through:size.height-h,by:4) {for x in stride(from:CGFloat(0),through:size.width-w,by:4) {
                let r=CGRect(x:x,y:y,width:w,height:h),d=pow(r.midX-desired.midX,2)+pow(r.midY-desired.midY,2)
                if d<distance && free(r) {best=r;distance=d}
            }}
            if let best {result[name]=best} else {
                // Extremely constrained windows cannot promise a full 44pt deck.
                // Keep the existing region visible; editor/import validation will
                // reject this geometry instead of accepting an inaccessible file.
                result[name]=desired
            }
        }
        return result
    }
}
struct ControllerSkinStore {
    let defaults:UserDefaults
    private func key(_ console:GameConsole,_ orientation:ControllerSkinOrientation)->String {console.preferencePrefix+"controllerLayout.v1."+orientation.rawValue}
    func palette(console:GameConsole,orientation:ControllerSkinOrientation)->ControllerSkinPalette {
        if let value=defaults.string(forKey:console.preferencePrefix+"skin."+orientation.rawValue),let palette=ControllerSkinPalette(rawValue:value) {return palette}
        // A legacy common preference applies to portrait only. An explicit choice
        // in either orientation always wins and is never reset on launch.
        if orientation == .landscape {return .transparent}
        return ControllerSkinPalette(rawValue:defaults.string(forKey:console.preferencePrefix+"skin") ?? "") ?? .studio
    }
    func layout(console:GameConsole,orientation:ControllerSkinOrientation)->ControllerSkinLayout? {
        guard let data=defaults.data(forKey:key(console,orientation)) else{return nil}
        return try? ControllerSkinLayout.decode(data,console:console,orientation:orientation)
    }
    func save(_ layout:ControllerSkinLayout,console:GameConsole)throws {
        try layout.validated(console:console,orientation:layout.orientation);let data=try layout.encoded()
        defaults.set(data,forKey:key(console,layout.orientation))
        defaults.set(layout.palette.rawValue,forKey:console.preferencePrefix+"skin."+layout.orientation.rawValue)
    }
    func setPalette(_ palette:ControllerSkinPalette,console:GameConsole,orientation:ControllerSkinOrientation) {
        if var layout=layout(console:console,orientation:orientation) {layout.palette=palette;try? save(layout,console:console)}
        defaults.set(palette.rawValue,forKey:console.preferencePrefix+"skin."+orientation.rawValue)
    }
    func reset(console:GameConsole,orientation:ControllerSkinOrientation) {defaults.removeObject(forKey:key(console,orientation))}
}
struct ControllerSkinDocument:FileDocument {
    static var readableContentTypes:[UTType] {[.json]}
    var data:Data
    init(data:Data) {self.data=data}
    init(configuration:ReadConfiguration)throws {guard let data=configuration.file.regularFileContents,data.count<=ControllerSkinLayout.byteLimit else{throw ControllerSkinError.invalid};self.data=data}
    func fileWrapper(configuration:WriteConfiguration)throws->FileWrapper {FileWrapper(regularFileWithContents:data)}
}
// A read-only preview uses the same selection and drawing path as gameplay.
@MainActor struct ConsoleSkinPreview:UIViewRepresentable {
    let console:GameConsole
    let orientation:ControllerSkinOrientation
    var palette:ControllerSkinPalette? = nil
    var revision:Int = 0
    func makeUIView(context:Context)->ConsoleSkinPreviewCanvas {ConsoleSkinPreviewCanvas()}
    func updateUIView(_ view:ConsoleSkinPreviewCanvas,context:Context) {view.apply(console:console,orientation:orientation,palette:palette)}
}
@MainActor final class ConsoleSkinPreviewCanvas:UIView {
    let deck=TouchDeck()
    private var canvas=CGSize(width:400,height:320)
    override init(frame:CGRect) {super.init(frame:frame);isUserInteractionEnabled=false;clipsToBounds=true;addSubview(deck)}
    required init?(coder:NSCoder){fatalError()}
    func apply(console:GameConsole,orientation:ControllerSkinOrientation,palette:ControllerSkinPalette?) {
        if let palette {
            var style=ControlStyle(console:console,defaults:nil);style.skin=palette.rawValue
            deck.style=style;deck.landscape=orientation == .landscape
            deck.customLayout=palette == .studio ? StudioSkins.variant(console:console,orientation:orientation)?.layout:ControllerSkinLayout.makeDefault(console:console,orientation:orientation,palette:palette)
            deck.customArtwork=palette == .studio ? StudioSkins.image(console:console,orientation:orientation):nil
        } else {deck.applySkin(console:console,landscape:orientation == .landscape)}
        canvas=deck.customLayout?.canvas ?? ControllerSkinLayout.makeDefault(console:console,orientation:orientation,palette:ControllerSkinPalette(rawValue:deck.style.skin) ?? .studio).canvas
        backgroundColor=UIColor(white:0.06,alpha:1);setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews();deck.transform = .identity;deck.bounds=CGRect(origin:.zero,size:canvas)
        deck.center=CGPoint(x:bounds.midX,y:bounds.midY)
        let scale=min(bounds.width/canvas.width,bounds.height/canvas.height)
        deck.transform=CGAffineTransform(scaleX:scale,y:scale)
    }
}
@MainActor enum ActiveConsoleSkin {
    static func name(console:GameConsole,orientation:ControllerSkinOrientation,library:PersonalSkinLibrary = .shared)->String {
        if let id=library.selectedID(console:console,orientation:orientation),library.selected(console:console,orientation:orientation) != nil,let skin=try? library.load(id) {return skin.name}
        return L10n.text(ControllerSkinStore(defaults:library.defaults).palette(console:console,orientation:orientation).rawValue)
    }
}
@MainActor struct SkinsByConsoleView:View {
    @ObservedObject private var library=PersonalSkinLibrary.shared
    @State private var revision=0
    var body:some View {
        ScrollView {
            LazyVStack(alignment:.leading,spacing:18) {
                Text("Los skins incluidos ya están cargados. Mira el diseño activo de cada consola y toca para cambiarlo.").font(.subheadline).foregroundStyle(.secondary)
                ForEach(GameConsole.chronological) {console in
                    NavigationLink {ControllerSkinSettingsView(console:console)} label:{
                        VStack(alignment:.leading,spacing:12) {
                            HStack {Text(console.name).font(.headline);Spacer();Image(systemName:"chevron.right").font(.subheadline)}
                            HStack(alignment:.top,spacing:12) {
                                ForEach(ControllerSkinOrientation.allCases,id:\.self) {orientation in
                                    VStack(alignment:.leading,spacing:6) {
                                        ConsoleSkinPreview(console:console,orientation:orientation,revision:revision+library.revision).frame(height:100).clipShape(RoundedRectangle(cornerRadius:10)).accessibilityHidden(true)
                                        Text(LocalizedStringKey(orientation.title)).font(.caption).foregroundStyle(.secondary)
                                        Text(ActiveConsoleSkin.name(console:console,orientation:orientation)).font(.subheadline.weight(.semibold))
                                    }.frame(maxWidth:.infinity,alignment:.leading)
                                }
                            }
                        }.padding(14).background(Color.secondary.opacity(0.10),in:RoundedRectangle(cornerRadius:18))
                    }.buttonStyle(.plain).accessibilityIdentifier("skins-console-"+console.rawValue)
                }
            }.padding()
        }.navigationTitle("Mis skins por consola").navigationBarTitleDisplayMode(.inline)
            .onAppear{revision+=1}
    }
}
struct ControllerSkinSettingsView:View {
    let console:GameConsole
    @ObservedObject private var library=PersonalSkinLibrary.shared
    @State private var orientation:ControllerSkinOrientation = .portrait
    @State private var palette:ControllerSkinPalette = .studio
    @State private var revision=0
    @State private var editing=false
    @State private var editingStudio:PersonalSkin?
    @State private var automaticConfirmation=false
    private let store=ControllerSkinStore(defaults:.standard)
    private var personalActive:Bool {library.selected(console:console,orientation:orientation) != nil}
    var body:some View {
        Form {
            Section {
                Picker("Orientación",selection:$orientation){ForEach(ControllerSkinOrientation.allCases,id:\.self){Text(LocalizedStringKey($0.title)).tag($0)}}.pickerStyle(.segmented)
                    .accessibilityIdentifier("skin-orientation")
                ConsoleSkinPreview(console:console,orientation:orientation,revision:revision+library.revision)
                    .frame(height:orientation == .portrait ? 220:150).clipShape(RoundedRectangle(cornerRadius:12)).accessibilityHidden(true)
                Label(L10n.format("Activo: %@",ActiveConsoleSkin.name(console:console,orientation:orientation)),systemImage:"checkmark.circle.fill")
                    .foregroundStyle(.primary).accessibilityIdentifier("active-skin-name")
            } header:{Text(console.name)} footer:{Text("Esta es la apariencia que usarás al jugar en la orientación elegida.")}
            Section("Skins incluidos") {
                ForEach(ControllerSkinPalette.allCases,id:\.self) {choice in
                    Button {
                        store.setPalette(choice,console:console,orientation:orientation)
                        library.useOriginal(console:console,orientation:orientation);reload()
                    } label:{
                        HStack(spacing:12) {
                            ConsoleSkinPreview(console:console,orientation:orientation,palette:choice).frame(width:110,height:76).clipShape(RoundedRectangle(cornerRadius:8)).accessibilityHidden(true)
                            Text(LocalizedStringKey(choice.rawValue)).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName:!personalActive && palette == choice ? "checkmark.circle.fill":"circle")
                                .font(.title2).foregroundStyle(!personalActive && palette == choice ? Color.accentColor:Color.secondary)
                        }.frame(maxWidth:.infinity,minHeight:76,alignment:.leading)
                            .padding(.vertical,4).padding(.horizontal,8)
                            .background(!personalActive && palette == choice ? Color.accentColor.opacity(0.12):Color.clear,in:RoundedRectangle(cornerRadius:12))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("included-skin-"+choice.rawValue)
                        .accessibilityAddTraits(!personalActive && palette == choice ? .isSelected:[])
                        .accessibilityValue(!personalActive && palette == choice ? L10n.text("Seleccionado"):L10n.text("Disponible"))
                }
            }
            Section {
                NavigationLink("Mis skins personalizados") {PersonalSkinCollectionView(console:console,initialOrientation:orientation)}
                    .accessibilityIdentifier("personal-skins")
                Button("Editar posiciones de los controles"){
                    if let id=library.selectedID(console:console,orientation:orientation),personalActive,let skin=try? library.load(id) {editingStudio=skin}
                    else if palette == .studio,let skin=StudioSkins.skin(console:console) {var copy=skin;copy.id=UUID().uuidString;editingStudio=copy}
                    else {editing=true}
                }.accessibilityIdentifier("skin-edit-positions")
                Button("Usar posiciones automáticas"){automaticConfirmation=true}.disabled(personalActive || palette == .studio)
            }
            Section {Text("Cada orientación conserva su propio estilo y distribución. Los diseños VETA JSON incluyen posiciones, no imágenes ni skins de otras apps.").font(.footnote);Text("Un diseño personalizado reemplaza los ajustes generales de tamaño, separación y altura. Las posiciones automáticas vuelven a usar esos ajustes.").font(.footnote)}
        }.navigationTitle("Skins y controles").navigationBarTitleDisplayMode(.inline)
        .onAppear{reload()}.onChange(of:orientation){_ in reload()}
        .confirmationDialog("¿Usar posiciones automáticas en esta orientación?",isPresented:$automaticConfirmation,titleVisibility:.visible){Button("Usar posiciones automáticas",role:.destructive){store.reset(console:console,orientation:orientation);reload()}}
        .sheet(isPresented:$editing,onDismiss:{reload()}) {NavigationStack {ControllerSkinEditorView(console:console,orientation:orientation,store:store)}}
        .sheet(item:$editingStudio,onDismiss:{reload()}) {skin in NavigationStack {PersonalSkinEditorView(console:console,skin:skin,initialOrientation:orientation)}}
    }
    private func reload(){palette=store.palette(console:console,orientation:orientation);revision+=1}
}
struct ControllerSkinEditorView:View {
    let console:GameConsole
    let orientation:ControllerSkinOrientation
    let store:ControllerSkinStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft:ControllerSkinLayout
    @State private var selected:String?
    @State private var error:String?
    @State private var importing=false
    @State private var exporting=false
    @State private var document=ControllerSkinDocument(data:Data())
    @State private var resetConfirmation=false
    init(console:GameConsole,orientation:ControllerSkinOrientation,store:ControllerSkinStore) {
        self.console=console;self.orientation=orientation;self.store=store
        _draft=State(initialValue:store.layout(console:console,orientation:orientation) ?? .makeDefault(console:console,orientation:orientation,palette:store.palette(console:console,orientation:orientation)))
    }
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                Text("Arrastra un control o selecciónalo y usa las flechas. Las áreas marcadas son las mismas que responden al tocar durante el juego.").font(.footnote)
                SkinEditorCanvas(layout:$draft,selected:$selected,error:$error).aspectRatio(draft.canvas.width/draft.canvas.height,contentMode:.fit).accessibilityIdentifier("skin-layout-preview")
                Picker("Control",selection:Binding(get:{selected ?? draft.controls.first?.id ?? ""},set:{selected=$0})) {ForEach(draft.controls,id:\.id){Text(LocalizedStringKey($0.id)).tag($0.id)}}
                HStack {nudge("arrow.left",x:-4,y:0);nudge("arrow.up",x:0,y:-4);nudge("arrow.down",x:0,y:4);nudge("arrow.right",x:4,y:0)}
                HStack {Text("Ancho");Spacer();resizeButton("minus",width:-4,height:0);Text("\(Int(selectedRect.width))").monospacedDigit();resizeButton("plus",width:4,height:0)}
                HStack {Text("Alto");Spacer();resizeButton("minus",width:0,height:-4);Text("\(Int(selectedRect.height))").monospacedDigit();resizeButton("plus",width:0,height:4)}
                if let error {Text(error).foregroundStyle(.red).font(.footnote).accessibilityIdentifier("skin-layout-error")}
                Text("Las áreas táctiles miden al menos 44 puntos en el lienzo de referencia. Si una ventana más pequeña no permite este diseño, VETA usa la distribución estándar.").font(.footnote)
                HStack {Button("Importar diseño JSON"){importing=true};Spacer();Button("Exportar diseño JSON"){do {document=ControllerSkinDocument(data:try draft.encoded());exporting=true}catch{self.error=error.localizedDescription}}}
                Button("Restablecer posiciones",role:.destructive){resetConfirmation=true}
            }.padding()
        }.navigationTitle("Editar controles")
        .toolbar {ToolbarItem(placement:.cancellationAction){Button("Cancelar"){dismiss()}};ToolbarItem(placement:.confirmationAction){Button("Guardar"){do {try store.save(draft,console:console);dismiss()}catch{self.error=error.localizedDescription}}.accessibilityIdentifier("skin-layout-save")}}
        .confirmationDialog("¿Restablecer las posiciones de esta orientación?",isPresented:$resetConfirmation,titleVisibility:.visible){Button("Restablecer posiciones",role:.destructive){draft = .makeDefault(console:console,orientation:orientation,palette:draft.palette);error=nil}}
        .fileImporter(isPresented:$importing,allowedContentTypes:[.json]) {result in do {draft=try ControllerSkinLayout.read(result.get(),console:console,orientation:orientation);selected=nil;error=nil}catch{self.error=error.localizedDescription}}
        .fileExporter(isPresented:$exporting,document:document,contentType:.json,defaultFilename:"VETA-\(console.rawValue)-\(orientation.rawValue)"){result in if case .failure(let failure)=result {error=failure.localizedDescription}}
    }
    private var selectedID:String {selected ?? draft.controls.first?.id ?? ""}
    private var selectedRect:CGRect {draft.controls.first{$0.id==selectedID}?.rect(in:draft.canvas) ?? .zero}
    private func resizeButton(_ symbol:String,width:CGFloat,height:CGFloat)->some View {
        Button {do {
            var next=draft;guard let index=next.controls.firstIndex(where:{$0.id==selectedID}) else{return}
            let r=selectedRect,w=max(44,r.width+width),h=max(44,r.height+height)
            next.controls[index]=ControllerSkinControl(id:selectedID,rect:CGRect(x:max(0,min(next.canvas.width-w,r.midX-w/2)),y:max(0,min(next.canvas.height-h,r.midY-h/2)),width:w,height:h),canvas:next.canvas)
            try next.validated(console:console,orientation:orientation);draft=next;error=nil
        }catch{self.error=error.localizedDescription}} label:{Image(systemName:symbol).frame(minWidth:44,minHeight:44)}.buttonStyle(.bordered).accessibilityLabel(L10n.text(width != 0 ? (width>0 ? "Aumentar ancho":"Reducir ancho"):(height>0 ? "Aumentar alto":"Reducir alto")))
    }
    private func nudge(_ symbol:String,x:CGFloat,y:CGFloat)->some View {
        Button {let id=selected ?? draft.controls.first?.id ?? "";guard let item=draft.controls.first(where:{$0.id==id}) else{return};let r=item.rect(in:draft.canvas);do {try draft.move(id,to:CGPoint(x:r.midX+x,y:r.midY+y));selected=id;error=nil}catch{self.error=error.localizedDescription}} label:{Image(systemName:symbol).frame(minWidth:44,minHeight:44)}.buttonStyle(.bordered).accessibilityLabel(LocalizedStringKey(["arrow.left":"Mover a la izquierda","arrow.up":"Mover arriba","arrow.down":"Mover abajo","arrow.right":"Mover a la derecha"][symbol]!))
    }
}
struct SkinEditorCanvas:UIViewRepresentable {
    @Binding var layout:ControllerSkinLayout
    @Binding var selected:String?
    @Binding var error:String?
    var artwork:UIImage? = nil
    func makeUIView(context:Context)->SkinEditorCanvasView {SkinEditorCanvasView()}
    func updateUIView(_ view:SkinEditorCanvasView,context:Context) {
        view.layout=layout;view.selected=selected;view.artwork=artwork
        view.onSelect={selected=$0}
        view.onMove={id,center in do {try layout.move(id,to:center);error=nil}catch{self.error=error.localizedDescription}}
    }
}
final class SkinEditorCanvasView:UIView {
    private let deck=TouchDeck()
    private let highlight=CAShapeLayer()
    var layout:ControllerSkinLayout? {didSet{setNeedsLayout()}}
    var selected:String? {didSet{setNeedsLayout()}}
    var artwork:UIImage? {didSet{setNeedsLayout()}}
    var onSelect:((String)->Void)?
    var onMove:((String,CGPoint)->Void)?
    private var dragging:String?,offset=CGPoint.zero
    override init(frame:CGRect) {
        super.init(frame:frame);addSubview(deck);deck.isUserInteractionEnabled=false;deck.showsTouchTargets=true
        layer.addSublayer(highlight);highlight.fillColor=UIColor.clear.cgColor;highlight.strokeColor=UIColor.systemOrange.cgColor;highlight.lineWidth=3
        addGestureRecognizer(UIPanGestureRecognizer(target:self,action:#selector(pan(_:))))
        addGestureRecognizer(UITapGestureRecognizer(target:self,action:#selector(tap(_:))))
        isAccessibilityElement=false
    }
    required init?(coder:NSCoder){fatalError()}
    override func layoutSubviews(){super.layoutSubviews();guard let layout,let console=GameConsole(rawValue:layout.console) else{return}
        let canvas=layout.canvas,scale=min(bounds.width/canvas.width,bounds.height/canvas.height)
        var style=ControlStyle(console:console,defaults:nil);style.skin=layout.palette.rawValue
        deck.style=style;deck.landscape=layout.orientation == .landscape;deck.customLayout=layout;deck.customArtwork=artwork
        deck.bounds=CGRect(origin:.zero,size:canvas);deck.center=CGPoint(x:bounds.midX,y:bounds.midY);deck.transform=CGAffineTransform(scaleX:scale,y:scale);deck.layoutIfNeeded()
        backgroundColor=style.background
        if let selected,let rect=deck.zones[selected] {highlight.path=UIBezierPath(roundedRect:deck.convert(rect,to:self),cornerRadius:5).cgPath}else{highlight.path=nil}
    }
    @objc private func tap(_ gesture:UITapGestureRecognizer){let p=gesture.location(in:deck);if let id=deck.zones.keys.sorted().first(where:{deck.zones[$0]!.contains(p)}){onSelect?(id)}}
    @objc private func pan(_ gesture:UIPanGestureRecognizer){let p=gesture.location(in:deck)
        if gesture.state == .began {dragging=deck.zones.keys.sorted().first(where:{deck.zones[$0]!.contains(p)});if let dragging,let r=deck.zones[dragging]{offset=CGPoint(x:r.midX-p.x,y:r.midY-p.y);onSelect?(dragging)}}
        if gesture.state == .changed,let dragging {onMove?(dragging,CGPoint(x:p.x+offset.x,y:p.y+offset.y))}
        if [.ended,.cancelled,.failed].contains(gesture.state){dragging=nil}
    }
}
