import SwiftUI

struct GameImportLocation: Identifiable {
    let id = UUID()
    var directory: URL?
    var cloud = false
    var folderOnly = false
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
            try job.prepare(urls, combineExplicitFiles: true) { name, done, count in
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
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
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
    var body: some View {
        NavigationStack {
            List {
                Section("Google Drive, OneDrive y Dropbox") {
                    Text("1. Instala la app del servicio e inicia sesión allí.")
                    Text("2. Abre Archivos → Explorar → ⋯ → Editar y activa el servicio en Ubicaciones.")
                    Text("3. En VETA, toca Agregar juegos → Desde Drive, OneDrive o Dropbox. Entra a la carpeta de tu consola, selecciona los juegos y sus portadas y toca Abrir.")
                }
                Section("Carpetas completas") {
                    Text("Drive y OneDrive permiten seleccionar archivos, pero no carpetas completas. Para iCloud Drive o En mi iPhone, usa Carpeta de iCloud o del iPhone: incluye sus subcarpetas. La disponibilidad depende del proveedor.")
                }
                Section("Juegos y portadas") {
                    Text("Para la portada, usa el mismo nombre: Juego.nes y Juego.png. Selecciona también todas las pistas de los discos CUE/BIN.")
                    Text("Se copian los formatos compatibles a VETA. Los originales y las partidas existentes se conservan. Una vez importados, puedes jugar sin conexión; no es una sincronización automática.")
                    Text("Necesitas espacio libre en el iPhone e Internet para los archivos que todavía no se han descargado.")
                }
            }.navigationTitle("Importar desde la nube").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } } }
        }.tint(VetaTheme.mint)
    }
}
