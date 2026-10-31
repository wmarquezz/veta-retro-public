import SwiftUI

struct GameImportLocation: Identifiable {
    let id = UUID()
    var directory: URL?
    var cloud = false
    var folderOnly = false
}

enum GameImportChoice { case files, folder, cloud, shared }

struct GameImportOptionsView: View {
    @Environment(\.dismiss) private var dismiss
    let choose: (GameImportChoice) -> Void
    let historyRoot:URL
    private var providers: [DirectCloudProvider] {
        DirectCloudProvider.allCases.filter { $0.configuration() != nil }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    option(.files, title: "Elegir archivos", detail: "iPhone, iCloud Drive y servicios disponibles en Archivos.", icon: "doc.badge.plus", id: "import-source-files")
                    option(.folder, title: "Importar una carpeta", detail: "iPhone o iCloud Drive. Incluye sus subcarpetas.", icon: "folder.badge.plus", id: "import-source-folder")
                    if !providers.isEmpty {
                        option(.cloud, title: "Conectar mi nube", detail: providers.map(\.title).joined(separator: ", "), icon: "cloud", id: "import-source-cloud")
                    }
                    option(.shared, title: "Abrir enlace compartido", detail: "Enlace de un portal compatible con VETA y su contraseña.", icon: "link", id: "import-source-shared")
                } footer: {
                    Text("Portada opcional: Juego.zip + Juego.png. Selecciona ambos archivos o importa su carpeta.")
                }
                Section {
                    NavigationLink {ImportHistoryView(root:historyRoot)} label:{
                        Label("Historial de importación",systemImage:"list.bullet.clipboard").frame(minHeight:44)
                    }.accessibilityIdentifier("import-history")
                    NavigationLink { CloudImportHelpView(embedded: true) } label: {
                        Label("Cómo agregar juegos", systemImage: "questionmark.circle").frame(minHeight:44)
                    }.accessibilityIdentifier("import-source-help")
                }
            }
            .navigationTitle("Agregar juegos").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button("Cerrar") {dismiss()} } }
        }.tint(VetaTheme.mint)
    }
    private func option(_ choice: GameImportChoice, title: String, detail: String, icon: String, id: String) -> some View {
        Button { choose(choice) } label: {
            HStack(spacing: 14) {
                Image(systemName:icon).font(.system(size:24)).frame(width:30).foregroundStyle(VetaTheme.mint).accessibilityHidden(true)
                VStack(alignment:.leading,spacing:5) {
                    Text(LocalizedStringKey(title)).font(.headline).foregroundStyle(Color.primary)
                    Text(LocalizedStringKey(detail)).font(.subheadline).foregroundStyle(Color.secondary)
                }.fixedSize(horizontal:false,vertical:true)
                Spacer(minLength:0)
                Image(systemName:"chevron.right").font(.system(size:14)).foregroundStyle(Color.secondary).accessibilityHidden(true)
            }.frame(minHeight:56).padding(.vertical,6).contentShape(Rectangle())
        }.accessibilityIdentifier(id)
    }
}

@MainActor final class CloudImportModel: ObservableObject {
    @Published var busy = false
    @Published var saving = false
    @Published var name = ""
    @Published var completed = 0
    @Published var total = 0
    @Published var cancelling = false
    private var operation: CloudImportPreparation?
    func prepare(_ urls: [URL]) async throws -> CloudImportPreparation.Snapshot {
        busy = true; saving = false; cancelling = false; name = ""; completed = 0; total = 0
        let job = CloudImportPreparation(extensions: LocalCoverImport.gameExtensions.union(NativeGameFile.extensions).union(LocalCoverImport.imageExtensions))
        operation = job
        let snapshot = try await Task.detached(priority: .userInitiated) { [weak self] in
            try job.prepare(urls, combineExplicitFiles:true,continueOnError:true) { name, done, count in
                Task { @MainActor in
                    guard let self, self.operation === job else { return }
                    self.name = name; self.completed = done; self.total = count
                }
            }
        }.value
        if cancelling { snapshot.remove(); throw CancellationError() }
        saving = true
        return snapshot
    }
    func cancel() { cancelling = true; operation?.cancel() }
    func finish() { operation = nil; busy = false; saving = false }
}

struct CloudImportProgressView: View {
    @ObservedObject var model: CloudImportModel
    var body: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(spacing: 16) {
                Text(LocalizedStringKey(model.saving ? "Agregando a tu biblioteca…" : (model.cancelling ? "Cancelando…" : "Preparando tus juegos…")))
                    .font(.headline).multilineTextAlignment(.center)
                if model.total > 0 && !model.saving {
                    ProgressView(value: Double(model.completed), total: Double(model.total))
                    Text("\(model.completed) / \(model.total)").font(.subheadline).monospacedDigit()
                } else { ProgressView() }
                Text(model.name).font(.subheadline).lineLimit(2).truncationMode(.middle)
                Text("Si los archivos están en la nube, espera mientras se descargan. Mantén VETA abierta.")
                    .font(.footnote).foregroundStyle(Color.secondary).multilineTextAlignment(.center)
                if !model.saving {
                    Button("Cancelar") { model.cancel() }.frame(minHeight: 44).disabled(model.cancelling)
                        .accessibilityIdentifier("cancel-cloud-import")
                }
            }.padding(24).frame(maxWidth: 360).background(VetaTheme.panel, in: RoundedRectangle(cornerRadius: 20)).padding(20)
        }.accessibilityAddTraits(.isModal)
    }
}

struct CloudImportHelpView: View {
    @Environment(\.dismiss) private var dismiss
    var embedded = false
    var body: some View {
        if embedded { content } else { NavigationStack { content } }
    }
    private var content: some View {
            List {
                Section("Conectar mi nube") {
                    Text("Conecta tu cuenta y elige una carpeta. VETA descarga tus juegos y portadas directamente, sin pasar por Archivos.")
                }
                Section("Google Drive, OneDrive y Dropbox") {
                    Text("1. Instala la app del servicio e inicia sesión allí.")
                    Text("2. Abre Archivos → Explorar → ⋯ → Editar y activa el servicio en Ubicaciones.")
                    Text("3. En VETA, toca Agregar juegos → Elegir archivos. En Explorar, elige tu servicio, selecciona juegos y portadas y toca Abrir.")
                }
                Section("Carpetas completas") {
                    Text("Usa Importar una carpeta para iPhone o iCloud Drive. Para otros servicios, usa Elegir archivos o Conectar mi nube si está disponible.")
                }
                Section("Juegos y portadas") {
                    Text("VETA descomprime los ZIP automáticamente. Para discos CUE/BIN, incluye todas sus pistas.")
                    Text("Se copian los formatos compatibles a VETA. Los originales y las partidas existentes se conservan. Una vez importados, puedes jugar sin conexión; no es una sincronización automática.")
                    Text("Necesitas espacio libre en el iPhone e Internet para los archivos que todavía no se han descargado.")
                }
            }.navigationTitle("Cómo agregar juegos").navigationBarTitleDisplayMode(.inline)
                .toolbar { if !embedded { ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } } } }
        .tint(VetaTheme.mint)
    }
}
