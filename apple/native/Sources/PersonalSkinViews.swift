import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PersonalSkinDocument:FileDocument {
    static var readableContentTypes:[UTType] {[.vetaSkin,.json]}
    var data:Data
    init(data:Data){self.data=data}
    init(configuration:ReadConfiguration)throws {
        guard let d=configuration.file.regularFileContents,d.count<=PersonalSkin.byteLimit else{throw PersonalSkinError.invalid};data=d
    }
    func fileWrapper(configuration:WriteConfiguration)throws->FileWrapper {FileWrapper(regularFileWithContents:data)}
}
@MainActor struct PersonalSkinCollectionView:View {
    let console:GameConsole
    @ObservedObject private var library=PersonalSkinLibrary.shared
    @State private var skins:[PersonalSkin]=[]
    @State private var orientation:ControllerSkinOrientation = .portrait
    @State private var editing:PersonalSkin?
    @State private var deleting:PersonalSkin?
    @State private var confirmingDelete=false
    @State private var importing=false
    @State private var error:String?
    init(console:GameConsole,initialOrientation:ControllerSkinOrientation = .portrait) {
        self.console=console;_orientation=State(initialValue:initialOrientation)
    }
    var body:some View {
        Form {
            Section {
                NavigationLink {PersonalSkinHelpView()} label:{Label("Cómo crear y usar un skin",systemImage:"questionmark.circle")}
                    .accessibilityIdentifier("personal-skin-help")
            }
            Section {
                Picker("Orientación",selection:$orientation) {ForEach(ControllerSkinOrientation.allCases,id:\.self){Text(LocalizedStringKey($0.title)).tag($0)}}.pickerStyle(.segmented)
                Button("Crear desde plantilla") {perform {
                    let palette:ControllerSkinPalette = .studio
                    editing=PersonalSkin(name:L10n.text("Mi skin"),console:console.rawValue,variants:try ControllerSkinOrientation.allCases.map{try PersonalSkinLibrary.generated(console:console,orientation:$0,palette:palette)})
                }}.accessibilityIdentifier("personal-skin-create")
                Button("Importar skin compartido") {importing=true}
                Button("Usar diseño original") {library.useOriginal(console:console,orientation:orientation)}
                Text("Tus skins se guardan en este iPhone. Puedes compartirlos e importarlos en otro teléfono.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Mis skins personalizados") {
                if skins.isEmpty {Text("Aún no tienes skins propios para esta consola.").foregroundStyle(.secondary)}
                ForEach(skins) {skin in
                    VStack(alignment:.leading,spacing:8) {
                        Button {perform {try library.select(skin,orientation:orientation)}} label:{
                            HStack(spacing:12) {
                                if let image=try? library.image(id:skin.id,orientation:orientation) {
                                    Image(uiImage:image).resizable().scaledToFit().frame(width:110,height:76).background(Color.black.opacity(0.9)).clipShape(RoundedRectangle(cornerRadius:8))
                                }
                                Text(skin.name).font(.headline).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName:library.selectedID(console:console,orientation:orientation)==skin.id ? "checkmark.circle.fill":"circle")
                                    .font(.title2).foregroundStyle(library.selectedID(console:console,orientation:orientation)==skin.id ? Color.accentColor:Color.secondary)
                            }.frame(maxWidth:.infinity,minHeight:76,alignment:.leading)
                                .padding(8)
                                .background(library.selectedID(console:console,orientation:orientation)==skin.id ? Color.accentColor.opacity(0.12):Color.clear,in:RoundedRectangle(cornerRadius:12))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(skin.variant(orientation)==nil)
                            .accessibilityIdentifier("personal-skin-select-"+skin.id)
                            .accessibilityAddTraits(library.selectedID(console:console,orientation:orientation)==skin.id ? .isSelected:[])
                            .accessibilityValue(L10n.text(library.selectedID(console:console,orientation:orientation)==skin.id ? "Seleccionado":"Disponible"))
                        HStack {
                            Button("Editar posiciones de los controles"){editing=skin}.buttonStyle(.borderless).frame(minHeight:44)
                            Spacer()
                            Button {deleting=skin;confirmingDelete=true} label:{Image(systemName:"trash").frame(minWidth:44,minHeight:44)}.buttonStyle(.borderless).foregroundStyle(.red).accessibilityLabel(L10n.format("Eliminar %@",skin.name))
                        }
                    }
                }
            }
            if let error {Section {Text(error).foregroundStyle(.red).accessibilityIdentifier("personal-skin-error")}}
        }.navigationTitle("Mis skins personalizados")
            .onAppear{reload()}.onChange(of:library.revision){_ in reload()}
            .sheet(item:$editing,onDismiss:{reload()}) {skin in NavigationStack {PersonalSkinEditorView(console:console,skin:skin,initialOrientation:orientation)}}
            .alert("¿Eliminar este skin?",isPresented:$confirmingDelete) {
                Button("Eliminar",role:.destructive) {guard let skin=deleting else{return};perform{try library.delete(skin)};deleting=nil}
                Button("Cancelar",role:.cancel){deleting=nil}
            } message:{Text(deleting?.name ?? "")}
            .fileImporter(isPresented:$importing,allowedContentTypes:[.vetaSkin,.json]) {result in
                perform {editing=try library.imported(PersonalSkin.read(result.get(),console:console),console:console)}
            }
    }
    private func reload(){do{skins=try library.list(console:console);error=nil}catch{self.error=error.localizedDescription}}
    private func perform(_ action:()throws->Void){do{try action();error=nil}catch{self.error=error.localizedDescription}}
}

struct PersonalSkinHelpView:View {
    var body:some View {
        Form {
            step("1.circle","Crear desde plantilla","Ponle un nombre y elige Vertical u Horizontal. Cada consola puede tener un diseño distinto en cada orientación.")
            step("2.circle","Cargar imagen del control","Elige una imagen desde Archivos. Usa PNG con la proporción indicada; en horizontal, deja transparente el centro. Puedes exportar la plantilla para rediseñarla.")
            step("3.circle","Ajustar zonas táctiles","Mueve y ajusta los recuadros sobre los botones de tu imagen: esas zonas reciben los toques.")
            step("4.circle","Probar controles","Gira el teléfono a la orientación elegida y prueba los botones sin abrir un juego.")
            step("5.circle","Guardar y usar en esta orientación","Guardar conserva el diseño. Guardar y usar lo activa sólo en la orientación elegida; repite para la otra.")
            step("6.circle","Compartir skin","Exporta el archivo .vetaskin. En el otro iPhone, elige la misma consola, toca Importar skin compartido y después guarda y aplica.")
            Section("Usar diseño original") {
                Text("Vuelve al control original sin borrar tu skin. La papelera elimina el diseño completo tras confirmarlo; tus partidas se conservan.")
            }
            Section {Text("Tus skins se guardan en este iPhone. Puedes compartirlos e importarlos en otro teléfono.").foregroundStyle(.secondary)}
        }.navigationTitle("Cómo crear y usar un skin").navigationBarTitleDisplayMode(.inline)
    }
    private func step(_ icon:String,_ title:LocalizedStringKey,_ detail:LocalizedStringKey)->some View {
        Section {Text(detail).fixedSize(horizontal:false,vertical:true)} header:{Label(title,systemImage:icon)}
    }
}

@MainActor struct PersonalSkinEditorView:View {
    let console:GameConsole
    @Environment(\.dismiss) private var dismiss
    @State private var draft:PersonalSkin
    @State private var savedDraft:PersonalSkin
    @State private var discardChanges=false
    @State private var orientation:ControllerSkinOrientation = .portrait
    @State private var palette:ControllerSkinPalette = .veta
    @State private var artwork:UIImage?
    @State private var selected:String?
    @State private var error:String?
    @State private var notice:String?
    @State private var fileImport=false
    @State private var importingLayout=false
    @State private var exporting=false
    @State private var document=PersonalSkinDocument(data:Data())
    @State private var testing=false
    @State private var replaceTemplate=false
    init(console:GameConsole,skin:PersonalSkin,initialOrientation:ControllerSkinOrientation = .portrait) {
        self.console=console;_draft=State(initialValue:skin);_savedDraft=State(initialValue:skin)
        let first=skin.variant(initialOrientation) ?? skin.variants[0]
        _orientation=State(initialValue:first.layout.orientation);_palette=State(initialValue:first.layout.palette)
        _artwork=State(initialValue:try? PersonalSkinImage.decoded(first.imagePNG))
    }
    private var layout:ControllerSkinLayout {draft.variant(orientation)?.layout ?? .makeDefault(console:console,orientation:orientation,palette:palette)}
    private var layoutBinding:Binding<ControllerSkinLayout> {Binding(get:{layout},set:{value in
        guard var v=draft.variant(orientation) else{return};v.layout=value;draft.set(v);error=nil
    })}
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:18) {
                TextField("Nombre del skin",text:$draft.name).textFieldStyle(.roundedBorder).accessibilityIdentifier("personal-skin-name")
                Picker("Orientación",selection:$orientation) {ForEach(ControllerSkinOrientation.allCases,id:\.self){Text(LocalizedStringKey($0.title)).tag($0)}}.pickerStyle(.segmented)
                SkinEditorCanvas(layout:layoutBinding,selected:$selected,error:$error,artwork:artwork)
                    .aspectRatio(layout.canvas.width/layout.canvas.height,contentMode:.fit)
                    .background(Color.black.opacity(0.9)).clipShape(RoundedRectangle(cornerRadius:12))
                    .accessibilityIdentifier("personal-skin-preview")
                Text("Las zonas marcadas reciben los toques. Ajústalas para que coincidan con los botones de tu imagen.").font(.footnote)
                Text("Si las zonas no caben en la pantalla, VETA usa el diseño original.").font(.caption).foregroundStyle(.secondary)
                if draft.variant(orientation) == nil {Text("Esta orientación usa el diseño original hasta que añadas una imagen o plantilla.").font(.footnote)}
                GroupBox {
                    VStack(alignment:.leading,spacing:12) {
                        Button("Cargar imagen del control") {importingLayout=false;fileImport=true}.accessibilityIdentifier("personal-skin-image")
                        Text("Usa el PNG del control, sin la pantalla del juego. En horizontal, deja transparente el centro.").font(.footnote).foregroundStyle(.secondary)
                        Text(L10n.format("Proporción de la plantilla: %@ × %@",String(Int(layout.canvas.width)),String(Int(layout.canvas.height)))).font(.caption)
                        Picker("Estilo de la plantilla",selection:$palette) {ForEach(ControllerSkinPalette.allCases,id:\.self){Text(LocalizedStringKey($0.rawValue)).tag($0)}}
                        Button("Generar plantilla") {replaceTemplate=true}
                        Button("Exportar imagen de plantilla") {perform {
                            let v=try PersonalSkinLibrary.generated(console:console,orientation:orientation,palette:palette)
                            let url=FileManager.default.temporaryDirectory.appendingPathComponent("VETA-\(console.rawValue)-\(orientation.rawValue)-\(UUID().uuidString).png")
                            try v.imagePNG.write(to:url,options:.atomic);share=ShareItem(url:url)
                        }}
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }
                if draft.variant(orientation) != nil {
                    GroupBox("Ajustar zonas táctiles") {
                        VStack(alignment:.leading,spacing:12) {
                            Picker("Control",selection:Binding(get:{selected ?? layout.controls.first?.id ?? ""},set:{selected=$0})) {ForEach(layout.controls,id:\.id){Text($0.id).tag($0.id)}}
                            HStack {nudge("arrow.left",x:-4,y:0);nudge("arrow.up",x:0,y:-4);nudge("arrow.down",x:0,y:4);nudge("arrow.right",x:4,y:0)}
                            HStack {Text("Ancho");Spacer();resizeButton("minus",width:-4,height:0);Text("\(Int(selectedRect.width))").monospacedDigit();resizeButton("plus",width:4,height:0)}
                            HStack {Text("Alto");Spacer();resizeButton("minus",width:0,height:-4);Text("\(Int(selectedRect.height))").monospacedDigit();resizeButton("plus",width:0,height:4)}
                            Button("Importar posiciones JSON"){importingLayout=true;fileImport=true}
                            Button("Probar controles"){testing=true}.accessibilityIdentifier("personal-skin-test")
                        }
                    }
                }
                if let error {Text(error).foregroundStyle(.red).accessibilityIdentifier("personal-skin-error")}
                if let notice {Text(notice).foregroundStyle(.secondary).accessibilityIdentifier("personal-skin-success")}
                Button("Guardar y usar en esta orientación") {perform {
                    let library=PersonalSkinLibrary.shared;try library.save(draft);savedDraft=draft;try library.select(draft,orientation:orientation)
                    notice=L10n.text("Skin guardado y aplicado en este iPhone.")
                }}.buttonStyle(.borderedProminent).frame(minHeight:44).disabled(draft.variant(orientation)==nil).accessibilityIdentifier("personal-skin-apply")
                Button("Compartir skin") {perform {document=PersonalSkinDocument(data:try draft.encoded());exporting=true}}
                Text("La otra orientación conserva su selección. Tu colección también está disponible al usar este iPhone como mando.").font(.footnote).foregroundStyle(.secondary)
            }.padding()
        }.navigationTitle("Editar skin personal")
            .toolbar {
                ToolbarItem(placement:.cancellationAction){Button("Cerrar"){if draft != savedDraft {discardChanges=true}else{dismiss()}}}
                ToolbarItem(placement:.confirmationAction){Button("Guardar"){perform{try PersonalSkinLibrary.shared.save(draft);savedDraft=draft;notice=L10n.text("Skin guardado.")}}.accessibilityIdentifier("personal-skin-save")}
            }
            .interactiveDismissDisabled(draft != savedDraft)
            .alert("¿Descartar los cambios sin guardar?",isPresented:$discardChanges) {
                Button("Descartar cambios",role:.destructive){dismiss()}
                Button("Cancelar",role:.cancel){}
            }
            .alert("Revisa el skin",isPresented:Binding(get:{error != nil},set:{if !$0{error=nil}})) {
                Button("Aceptar",role:.cancel){error=nil}
            } message:{Text(error ?? "")}
            .onChange(of:orientation){_ in refreshArtwork();selected=nil;notice=nil;error=nil}
            .alert("¿Reemplazar la imagen y las zonas por la plantilla?",isPresented:$replaceTemplate) {
                Button("Generar plantilla",role:.destructive) {perform{draft.set(try PersonalSkinLibrary.generated(console:console,orientation:orientation,palette:palette));refreshArtwork();selected=nil}}
                Button("Cancelar",role:.cancel){}
            }
            .fileImporter(isPresented:$fileImport,allowedContentTypes:importingLayout ? [.json]:[.png,.jpeg,.heic]) {result in perform {
                let url=try result.get()
                if importingLayout {
                    let imported=try ControllerSkinLayout.read(url,console:console,orientation:orientation)
                    guard var v=draft.variant(orientation) else{throw PersonalSkinError.invalid}
                    try PersonalSkinImage.validateProportion(PersonalSkinImage.dimensions(v.imagePNG,pngOnly:true),canvas:imported.canvas)
                    v.layout=imported;draft.set(v)
                } else {
                    let data=try PersonalSkinImage.read(url,limit:PersonalSkinImage.inputLimit)
                    let png=try PersonalSkinImage.normalized(data,canvas:layout.canvas)
                    draft.set(PersonalSkinVariant(layout:layout,imagePNG:png));refreshArtwork()
                }
            }}
            .fileExporter(isPresented:$exporting,document:document,contentType:.vetaSkin,defaultFilename:"VETA-\(console.rawValue)-skin") {result in if case .failure(let e)=result{error=e.localizedDescription}}
            .fullScreenCover(isPresented:$testing) {PersonalSkinTestView(console:console,layout:layout,artwork:artwork)}
            .sheet(item:$share) {ShareSheet(url:$0.url)}
    }
    @State private var share:ShareItem?
    private var selectedID:String {selected ?? layout.controls.first?.id ?? ""}
    private var selectedRect:CGRect {layout.controls.first{$0.id==selectedID}?.rect(in:layout.canvas) ?? .zero}
    private func refreshArtwork(){artwork=draft.variant(orientation).flatMap{try? PersonalSkinImage.decoded($0.imagePNG)}}
    private func perform(_ action:()throws->Void){do{try action();error=nil}catch{self.error=error.localizedDescription;notice=nil}}
    private func nudge(_ symbol:String,x:CGFloat,y:CGFloat)->some View {
        Button {perform{var v=layout;try v.move(selectedID,to:CGPoint(x:selectedRect.midX+x,y:selectedRect.midY+y));layoutBinding.wrappedValue=v}} label:{Image(systemName:symbol).frame(minWidth:44,minHeight:44)}.buttonStyle(.bordered).accessibilityLabel(LocalizedStringKey(["arrow.left":"Mover a la izquierda","arrow.up":"Mover arriba","arrow.down":"Mover abajo","arrow.right":"Mover a la derecha"][symbol]!))
    }
    private func resizeButton(_ symbol:String,width:CGFloat,height:CGFloat)->some View {
        Button {perform {
            var v=layout;guard let index=v.controls.firstIndex(where:{$0.id==selectedID}) else{throw PersonalSkinError.invalid}
            let r=selectedRect,w=max(44,r.width+width),h=max(44,r.height+height)
            let next=CGRect(x:max(0,min(v.canvas.width-w,r.midX-w/2)),y:max(0,min(v.canvas.height-h,r.midY-h/2)),width:w,height:h)
            v.controls[index]=ControllerSkinControl(id:selectedID,rect:next,canvas:v.canvas)
            try v.validated(console:console,orientation:orientation);layoutBinding.wrappedValue=v
        }} label:{Image(systemName:symbol).frame(minWidth:44,minHeight:44)}.buttonStyle(.bordered).accessibilityLabel(L10n.text(width != 0 ? (width>0 ? "Aumentar ancho":"Reducir ancho"):(height>0 ? "Aumentar alto":"Reducir alto")))
    }
}

@MainActor private struct PersonalSkinTestView:View {
    let console:GameConsole
    let layout:ControllerSkinLayout
    let artwork:UIImage?
    @Environment(\.dismiss) private var dismiss
    @State private var pressed=""
    var body:some View {
        GeometryReader {geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                if (geometry.size.width>geometry.size.height) == (layout.orientation == .landscape) {
                    PersonalSkinTestCanvas(console:console,layout:layout,artwork:artwork,pressed:$pressed)
                    Text(pressed.isEmpty ? L10n.text("Sin pulsar"):pressed).font(.headline)
                        .padding(10).background(.black.opacity(0.75)).foregroundStyle(.white)
                        .allowsHitTesting(false).accessibilityIdentifier("personal-skin-input")
                } else {
                    Text("Gira el iPhone para probar esta orientación.").foregroundStyle(.white).padding(30)
                }
                VStack {Button("Cerrar"){dismiss()}.frame(width:88,height:44).background(.black.opacity(0.8)).foregroundStyle(.white);Spacer()}
            }
        }
    }
}
private struct PersonalSkinTestCanvas:UIViewRepresentable {
    let console:GameConsole;let layout:ControllerSkinLayout;let artwork:UIImage?
    @Binding var pressed:String
    func makeUIView(context:Context)->TouchDeck {TouchDeck()}
    func updateUIView(_ view:TouchDeck,context:Context) {
        var style=ControlStyle(console:console,defaults:nil);style.skin=layout.palette.rawValue
        view.style=style;view.landscape=layout.orientation == .landscape;view.customLayout=layout;view.customArtwork=artwork
        view.onInput={mask in
            let buttons=layout.controls.map(\.id).filter{let bit=console.buttonMask($0);return bit != 0 && mask & bit == bit}.map{style.buttonLabel($0)}
            let arrows=[(4,"↑"),(5,"↓"),(6,"←"),(7,"→")].filter{mask & (1 << $0.0) != 0}.map(\.1)
            DispatchQueue.main.async{pressed=(arrows+buttons).joined(separator:" · ")}
        }
        view.onAnalog={i,point in DispatchQueue.main.async{pressed=point == .zero ? "":L10n.text(i == 0 ? "Palanca izquierda":"Palanca derecha")}}
    }
}
