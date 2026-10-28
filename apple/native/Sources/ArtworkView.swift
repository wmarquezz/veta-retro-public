import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct PickedCover:Transferable {
    let data:Data
    static var transferRepresentation:some TransferRepresentation {
        FileRepresentation(importedContentType:.image) {file in
            PickedCover(data:try CoverImage.read(file.file))
        }
    }
}
struct ArtworkView:View {
    let game:Game
    @ObservedObject var artwork:ArtworkStore
    let fallback:URL?
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPhoto:PhotosPickerItem?
    @State private var files=false
    @State private var loading=false
    @State private var error:String?
    var body:some View {
        NavigationStack {
            Form {
                Section {
                    HStack(alignment:.top,spacing:18) {
                        GameCover(game:game,artURL:fallback,coverImage:artwork.image(game)).frame(width:110).accessibilityIdentifier("cover-preview")
                        VStack(alignment:.leading,spacing:10) {
                            Text(game.name).font(VetaTheme.heading(26))
                            Text(game.console.name).font(.caption).foregroundStyle(VetaTheme.muted)
                            if let record=artwork.record(game) {
                                Label(LocalizedStringKey(record.manual ? "Imagen personal":"Libretro Thumbnails"),systemImage:record.manual ? "photo":"globe").font(.footnote).accessibilityIdentifier("cover-source")
                                Text("Guardada · disponible sin conexión").font(.caption).foregroundStyle(VetaTheme.muted)
                                if let source=record.source {Link("Ver imagen de origen",destination:source).font(.caption)}
                            }
                        }.frame(maxWidth:.infinity,alignment:.leading)
                    }.padding(.vertical,8)
                }.listRowBackground(VetaTheme.panel)
                Section("Cambiar portada") {
                    if ArtworkDistributionPolicy.allowsRemoteCovers {
                        Button {Task {await artwork.search(game)}} label:{Label("Buscar portada en Internet",systemImage:"arrow.down.circle")}.disabled(artwork.searching.contains(game.id) || loading).accessibilityIdentifier("cover-search")
                    }
                    PhotosPicker(selection:$selectedPhoto,matching:.images,photoLibrary:.shared()) {Label("Elegir de Fotos",systemImage:"photo.on.rectangle")}.disabled(loading).accessibilityIdentifier("cover-photos")
                    Button {files=true} label:{Label("Elegir de Archivos",systemImage:"folder")}.disabled(loading).accessibilityIdentifier("cover-files")
                    if loading || artwork.searching.contains(game.id) {ProgressView(LocalizedStringKey(loading ? "Guardando imagen…":"Buscando portada…"))}
                    if let message=artwork.messages[game.id] {Text(L10n.text(message)).font(.footnote).foregroundStyle(VetaTheme.muted).accessibilityIdentifier("cover-status")}
                }.listRowBackground(VetaTheme.panel)
                Section {
                    if ArtworkDistributionPolicy.allowsRemoteCovers {
                        Text("La imagen personal tiene prioridad sobre las descargas automáticas. Buscar una portada aquí solo la reemplaza si se encuentra una coincidencia.").font(.caption).foregroundStyle(VetaTheme.muted)
                    }
                    Text("PNG, JPEG, HEIC y otras imágenes compatibles, hasta 30 MB. Se guarda una copia optimizada, sin recortar la portada.").font(.caption).foregroundStyle(VetaTheme.muted)
                }.listRowBackground(VetaTheme.panel)
            }.vetaForm().navigationTitle("Portada del juego").navigationBarTitleDisplayMode(.inline)
                .toolbar {Button("Listo"){dismiss()}.accessibilityIdentifier("cover-done")}
        }.tint(VetaTheme.mint)
        .fileImporter(isPresented:$files,allowedContentTypes:[.image]) {result in
            switch result {
            case .success(let url):
                loading=true
                Task {
                    do {let data=try await Task.detached(priority:.userInitiated){try CoverImage.read(url)}.value;try artwork.setManual(data,for:game)}
                    catch {self.error=error.localizedDescription}
                    loading=false
                }
            case .failure(let failure):error=failure.localizedDescription
            }
        }
        .task(id:selectedPhoto) {
            guard let selectedPhoto else{return};loading=true
            do {
                guard let image=try await selectedPhoto.loadTransferable(type:PickedCover.self) else {throw VetaError.message("No se pudo obtener la foto. Reintenta o elige una imagen de Archivos.")}
                try artwork.setManual(image.data,for:game)
            } catch {self.error=error.localizedDescription}
            loading=false;self.selectedPhoto=nil
        }
        .alert("Portada",isPresented:Binding(get:{error != nil},set:{if !$0 {error=nil}})) {Button("Aceptar"){error=nil}} message:{Text(L10n.text(error ?? ""))}
    }
}
