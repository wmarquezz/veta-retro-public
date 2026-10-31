import SwiftUI

@MainActor final class DirectCloudBrowserModel: ObservableObject {
    @Published var provider: DirectCloudProvider?
    @Published var entries: [DirectCloudEntry] = []
    @Published var path: [DirectCloudEntry] = []
    @Published var selected = Set<String>()
    @Published var busy = false
    @Published var downloading = false
    @Published var saving = false
    @Published var progress: DirectCloudProgress?
    @Published var error: String?
    @Published var result: String?
    @Published var pendingPlan: DirectCloudPlan?
    @Published var showPlan = false
    @Published var artworkLoader: DirectCloudArtworkLoader?
    var artworkIndex: DirectCloudArtworkIndex { DirectCloudArtworkIndex(entries) }
    private var sharedRoot: DirectCloudEntry?
    private var connection: (any DirectCloudSource)?
    @Published private(set) var portalConnected = false
    var isConnected: Bool { provider != nil || portalConnected }
    private var operation: Task<Void, Never>?
    private let auth = DirectCloudAuthenticator()
    private var config: DirectCloudConfiguration?
    var currentName: String { path.last?.name ?? sharedRoot?.name ?? provider?.title ?? (portalConnected ? L10n.text("Carpetas compartidas") : "") }
    var currentID: String { path.last?.id ?? sharedRoot?.id ?? provider?.rootID ?? "root" }
    var supported: Set<String> { LocalCoverImport.gameExtensions.union(NativeGameFile.extensions).union(LocalCoverImport.imageExtensions) }
    func connect(_ target: DirectCloudProvider, sharedLink: SharedCloudLink? = nil) {
        guard !busy else { return }
        guard let config = target.configuration() else { error = DirectCloudError.notConfigured.localizedDescription; return }
        busy = true; error = nil; result = nil
        operation = Task {
            defer { busy = false; operation = nil }
            do {
                let saved = try DirectCloudKeychain.read(config.credentialKey)
                let token: DirectCloudToken
                if let saved { token = saved } else { token = try await auth.connect(config) }
                try Task.checkCancellation()
                self.config = config; provider = target; path = []; selected = []; entries = []
                let connected = DirectCloudConnection(config: config, token: token)
                connection = connected; portalConnected = false
                sharedRoot = nil
                if let connection {
                    if let sharedLink { sharedRoot = try await connected.sharedGoogleEntry(sharedLink) }
                    artworkLoader = DirectCloudArtworkLoader(source: connection)
                }
                try await load()
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    func connectPortal(_ source: KrafifySharedConnection) async throws {
        config = nil; provider = nil; connection = source; sharedRoot = nil
        path = []; selected = []; entries = []; portalConnected = true
        artworkLoader = DirectCloudArtworkLoader(source: source)
        do { try await load() } catch { disconnect(); throw error }
    }
    private func load() async throws {
        guard let connection else { return }
        let all: [DirectCloudEntry]
        if let sharedRoot, !sharedRoot.folder, path.isEmpty { all = [sharedRoot] }
        else { all = try await connection.list(folder: currentID) }
        try Task.checkCancellation()
        entries = all.filter { !$0.name.hasPrefix(".") && ($0.folder || supported.contains(($0.name as NSString).pathExtension.lowercased())) }
        selected = []
    }
    func navigate(to folder: DirectCloudEntry?) {
        guard !busy else { return }
        let oldPath = path
        if let folder { path.append(folder) } else if !path.isEmpty { path.removeLast() } else { sharedRoot = nil; provider = nil; portalConnected = false; connection = nil; artworkLoader = nil; entries = []; return }
        busy = true; error = nil; selected = []
        operation = Task {
            defer { busy = false; operation = nil }
            do { try await load() }
            catch { path = oldPath; if !(error is CancellationError) { self.error = error.localizedDescription } }
        }
    }
    func refresh() {
        guard !busy else { return }; busy = true; error = nil
        operation = Task {
            defer { busy = false; operation = nil }
            do { try await load() } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    func toggle(_ entry: DirectCloudEntry) { if !selected.insert(entry.id).inserted { selected.remove(entry.id) } }
    func plan(all: Bool) {
        guard !busy, let connection else { return }
        var chosen = all ? entries : entries.filter { selected.contains($0.id) }
        // Include matching optional covers next to individually selected games.
        let stems = Set(chosen.filter { !$0.folder && !LocalCoverImport.imageExtensions.contains(($0.name as NSString).pathExtension.lowercased()) }.map { DirectCloudArtworkIndex.stem($0.name) })
        for item in entries where !item.folder && LocalCoverImport.imageExtensions.contains((item.name as NSString).pathExtension.lowercased()) && stems.contains(DirectCloudArtworkIndex.stem(item.name)) && !chosen.contains(where: { $0.id == item.id }) { chosen.append(item) }
        guard !chosen.isEmpty else { return }
        busy = true; error = nil; result = nil
        let transfer = DirectCloudTransfer(source:connection,extensions:supported,continueOnError:true)
        operation = Task {
            defer { busy = false; operation = nil }
            do { pendingPlan = try await transfer.plan(selection: chosen); try Task.checkCancellation(); showPlan = true }
            catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    func importPlan(_ commit: @escaping (CloudImportPreparation.Snapshot) throws -> String) {
        guard let plan = pendingPlan, let connection, !busy else { return }
        pendingPlan = nil; busy = true; downloading = true; error = nil; result = nil; progress = nil
        let transfer = DirectCloudTransfer(source:connection,extensions:supported,continueOnError:true)
        operation = Task {
            defer { busy = false; downloading = false; saving = false; progress = nil; operation = nil }
            do {
                let snapshot = try await transfer.prepare(plan) { value in
                    Task { @MainActor [weak self] in if self?.downloading == true { self?.progress = value } }
                }
                defer { snapshot.remove() }
                try Task.checkCancellation()
                downloading = false; saving = true
                await Task.yield(); try Task.checkCancellation()
                result = try commit(snapshot)
                selected = []
            } catch is CancellationError {
                result = L10n.text("Importación cancelada. Tus originales y tu biblioteca se conservan.")
            } catch { self.error = error.localizedDescription }
        }
    }
    func cancel() { if !saving { operation?.cancel(); auth.cancel() } }
    func disconnect() {
        guard !busy else { return }
        do {
            if let config { try DirectCloudKeychain.remove(config.credentialKey) }
            connection = nil; artworkLoader = nil; self.config = nil; provider = nil; portalConnected = false; sharedRoot = nil; entries = []; path = []; selected = []; pendingPlan = nil
            result = L10n.text("Cuenta desconectada de VETA. Tus juegos importados se conservan.")
        } catch { self.error = error.localizedDescription }
    }
}

struct DirectCloudView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: DirectCloudBrowserModel
    @State private var confirmDisconnect = false
    @State private var preview: DirectCloudEntry?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var initialLink: SharedCloudLink?
    let commit: (CloudImportPreparation.Snapshot) throws -> String
    init(commit: @escaping (CloudImportPreparation.Snapshot) throws -> String) {
        _model = StateObject(wrappedValue: DirectCloudBrowserModel()); self.commit = commit
    }
    init(sharedLink: SharedCloudLink, commit: @escaping (CloudImportPreparation.Snapshot) throws -> String) {
        _model = StateObject(wrappedValue: DirectCloudBrowserModel()); self.commit = commit; initialLink = sharedLink
    }
    init(model: DirectCloudBrowserModel, commit: @escaping (CloudImportPreparation.Snapshot) throws -> String) {
        _model = StateObject(wrappedValue: model); self.commit = commit
    }
    @ViewBuilder private var importButtons: some View {
        Button("Importar selección") { model.plan(all: false) }
            .buttonStyle(VetaButton(primary: true)).disabled(model.selected.isEmpty)
        Button("Importar esta carpeta") { model.plan(all: true) }.frame(minHeight: 44).disabled(model.entries.isEmpty)
    }
    var body: some View {
        NavigationStack {
            List {
                if !model.isConnected {
                    Section {
                        Text("Conecta tu cuenta y elige una carpeta. VETA descarga tus juegos y portadas directamente, sin pasar por Archivos.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Section("Tus servicios") {
                        ForEach(DirectCloudProvider.allCases.filter { $0.configuration() != nil }) { provider in
                            Button { model.connect(provider) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "externaldrive.badge.icloud").foregroundStyle(VetaTheme.mint).accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(provider.title).foregroundStyle(.primary)
                                        Text("Conectar cuenta")
                                            .font(.footnote).foregroundStyle(.secondary)
                                    }
                                    Spacer(); Image(systemName: "chevron.right").accessibilityHidden(true)
                                }.frame(minHeight: 48).contentShape(Rectangle())
                            }.disabled(model.busy || provider.configuration() == nil)
                                .accessibilityIdentifier("cloud-connect-\(provider.rawValue)")
                        }
                    }
                    Section("Tú mantienes el control") {
                        Text("VETA carga las portadas visibles. Sólo importa los juegos que elijas; no modifica ni elimina archivos en la nube.")
                        Text("Los juegos quedan en este iPhone para jugar sin conexión. Puedes desconectar la cuenta en cualquier momento.")
                    }
                    Section("Privacidad y condiciones") { CloudPrivacyLinks() }
                } else {
                    Section {
                        Label(model.currentName, systemImage: "folder").font(.headline).textSelection(.enabled)
                        HStack {
                            Button(model.selected.count == (model.artworkIndex.games.count + model.artworkIndex.folders.count) && !model.selected.isEmpty ? "Deseleccionar todo" : "Seleccionar todo") {
                                let ids = Set((model.artworkIndex.games + model.artworkIndex.folders).map(\.id))
                                model.selected = model.selected == ids ? [] : ids
                            }.frame(minHeight: 44).disabled(model.busy || model.entries.isEmpty)
                            Spacer()
                            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise").frame(minWidth: 44, minHeight: 44) }
                                .accessibilityLabel("Actualizar carpeta").disabled(model.busy)
                        }
                    }
                    let index = model.artworkIndex
                    if !index.folders.isEmpty {
                        Section("Carpetas") {
                            ForEach(index.folders) { item in
                                HStack {
                                    Button { model.toggle(item) } label: { Image(systemName: model.selected.contains(item.id) ? "checkmark.circle.fill" : "circle").font(.title2).frame(width: 44, height: 48) }
                                        .buttonStyle(.borderless).accessibilityLabel(Text(L10n.format("Seleccionar %@", item.name)))
                                    Button { model.navigate(to: item) } label: {
                                        HStack { Label(item.name, systemImage: "folder.fill"); Spacer(); Image(systemName: "chevron.right") }.frame(minHeight: 48)
                                    }.buttonStyle(.borderless)
                                }.disabled(model.busy)
                            }
                        }
                    }
                    Section("Juegos") {
                        if index.games.isEmpty && !model.busy { Text("No hay juegos en esta carpeta.").foregroundStyle(.secondary) }
                        let columns = dynamicTypeSize.isAccessibilitySize ? 1 : (verticalSizeClass == .compact ? 3 : 2)
                        ForEach(Array(stride(from: 0, to: index.games.count, by: columns)), id: \.self) { offset in
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(Array(index.games[offset..<min(offset + columns, index.games.count)])) { item in

                                VStack(spacing: 4) {
                                    Button { model.toggle(item) } label: {
                                        VStack(alignment: .leading, spacing: 8) {
                                            DirectCloudThumbnail(entry: index.covers[item.id], loader: model.artworkLoader)
                                                .overlay(alignment: .topTrailing) { Image(systemName: model.selected.contains(item.id) ? "checkmark.circle.fill" : "circle").font(.title2).foregroundStyle(model.selected.contains(item.id) ? VetaTheme.orange : VetaTheme.mint).padding(8).background(.black.opacity(0.7), in: Circle()) }
                                            Text((item.name as NSString).deletingPathExtension).font(.subheadline.weight(.semibold)).foregroundStyle(Color.primary).lineLimit(3).multilineTextAlignment(.leading)
                                            if let size = item.size { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                    }.buttonStyle(.plain).accessibilityLabel(Text(L10n.format("Seleccionar %@", item.name)))
                                        .accessibilityValue(model.selected.contains(item.id) ? Text("Seleccionado") : Text("Sin seleccionar"))
                                    if let cover = index.covers[item.id] {
                                        Button { preview = cover } label: { Label("Ver portada", systemImage: "arrow.up.left.and.arrow.down.right").font(.caption).frame(maxWidth: .infinity, minHeight: 44) }.buttonStyle(.borderless)
                                    }
                                }.frame(maxWidth: .infinity).disabled(model.busy)
                                }
                                if index.games.count - offset < columns { Spacer().frame(maxWidth: .infinity) }
                            }
                        }
                    }
                    Section {
                        DisclosureGroup("Ayuda") { Text("Selecciona archivos o carpetas. Para discos CUE/BIN, importa la carpeta completa con todas sus pistas.").font(.footnote) }
                    }
                    if !index.unpairedImages.isEmpty {
                        Section {
                            DisclosureGroup("Imágenes sin juego asociado") {
                                ForEach(index.unpairedImages) { item in
                                    HStack {
                                        Button { model.toggle(item) } label: { Image(systemName: model.selected.contains(item.id) ? "checkmark.circle.fill" : "circle").font(.title2).frame(width: 44, height: 48) }.buttonStyle(.borderless)
                                        Button { preview = item } label: { Text(item.name).foregroundStyle(Color.primary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading) }.buttonStyle(.borderless)
                                    }.disabled(model.busy)
                                }
                            }
                        }
                    }
                }


            }
            .safeAreaInset(edge: .top) {
                if model.busy || model.error != nil || model.result != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        if let error = model.error { Label(error, systemImage: "exclamationmark.triangle") }
                        if let result = model.result { Label(result, systemImage: "checkmark.circle") }
                        if model.busy {
                            Text(LocalizedStringKey(model.saving ? "Agregando a tu biblioteca…" : (model.downloading ? "Descargando tus juegos…" : "Consultando tu cuenta…")))
                            if let progress = model.progress {
                                ProgressView(value: Double(progress.bytes), total: Double(max(1, progress.totalBytes)))
                                Text(progress.name).font(.caption).lineLimit(1)
                            } else { ProgressView() }
                            if !model.saving { Button("Cancelar") { model.cancel() }.frame(minHeight: 44) }
                        } else { Button("Cerrar") { model.error = nil; model.result = nil }.frame(minHeight: 44) }
                    }.font(.subheadline).frame(maxWidth: .infinity, alignment: .leading).padding().background(VetaTheme.panel)
                }
            }
            .sheet(item: $preview) { item in DirectCloudArtworkPreview(entry: item, loader: model.artworkLoader) }
            .navigationTitle(model.portalConnected ? "Enlace compartido" : "Conectar mi nube").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                if model.isConnected && !model.busy {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) { importButtons }
                        VStack(spacing: 8) { importButtons }
                    }.frame(maxWidth: .infinity).padding(.horizontal, 16).padding(.vertical, 8).background(VetaTheme.panel)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if model.isConnected { Button { if model.portalConnected && model.path.isEmpty { dismiss() } else { model.navigate(to: nil) } } label: { Label("Volver", systemImage: "chevron.left") }.disabled(model.busy) }
                    else { Button("Cerrar") { dismiss() }.disabled(model.busy) }
                }
                ToolbarItem(placement: .primaryAction) {
                    if model.isConnected { Menu { Button("Desconectar cuenta", role: .destructive) { confirmDisconnect = true }; Button("Cerrar") { dismiss() } } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("Opciones de la cuenta").disabled(model.busy) }
                }
            }
            .alert("Desconectar cuenta", isPresented: $confirmDisconnect) {
                Button("Desconectar", role: .destructive) { model.disconnect() }; Button("Cancelar", role: .cancel) {}
            } message: { Text("Se eliminará la conexión guardada en este iPhone. Tus juegos importados se conservan. Puedes revocar también el permiso desde la cuenta del proveedor.") }
            .alert("Descargar e importar", isPresented: $model.showPlan) {
                Button("Importar") { model.importPlan(commit) }
                Button("Cancelar", role: .cancel) { model.pendingPlan = nil }
            } message: {
                if let plan = model.pendingPlan {
                    Text(L10n.format("%d archivos · %@", plan.files.count, ByteCountFormatter.string(fromByteCount: plan.bytes, countStyle: .file)) + "\n" + L10n.text("Se incluirán las subcarpetas seleccionadas. Mantén VETA abierta hasta terminar."))
                }
            }
        }.tint(VetaTheme.mint).task { if let initialLink { model.connect(.google, sharedLink: initialLink) } }.interactiveDismissDisabled(model.busy).onDisappear { model.cancel() }
    }
}
