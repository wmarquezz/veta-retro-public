import Foundation
import UIKit
import SwiftUI

// No caller-provided filename reaches the filesystem. A single atomic envelope
// contains payload, integrity, thumbnail and protection so metadata cannot point
// at a different generation after interruption.
struct SaveMetadata {
    let createdAt: Date?
    let thumbnail: Data?
    let protected: Bool?
    let options: [String:String]?
    let name: String?
}
struct SaveSlot: Identifiable, Equatable {
    let id: String
    let title: String
    let state: SaveMetadata?
    let issue: String?
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.state?.createdAt == rhs.state?.createdAt && lhs.state?.protected == rhs.state?.protected && lhs.state?.name == rhs.state?.name && lhs.issue == rhs.issue }
    var displayTitle: String { state?.name ?? (NativeSaveStore.manualSlots.contains(id) ? L10n.format("Partida %@", id.replacingOccurrences(of: "slot", with: "")) : L10n.text(title)) }
}
struct NativeSaveStore {
    let directory: URL
    let rom: String
    let core: String
    static let manualSlots = (1...8).map { "slot\($0)" }
    static let slots = ["auto", "quick"] + manualSlots + ["previous-auto", "previous-quick", "before-load"]
    static func title(_ slot: String) -> String {
        switch slot { case "auto": return "Automático"; case "quick": return "Rápido"; case "before-load": return "Antes de cargar"; case "previous-auto": return "Automático anterior"; case "previous-quick": return "Rápido anterior"; default: return "Partida \(slot.replacingOccurrences(of: "slot", with: ""))" }
    }
    func url(_ slot: String) throws -> URL {
        guard Self.slots.contains(slot) else { throw VetaError.message("Ranura de guardado inválida.") }
        return directory.appendingPathComponent(slot + ".vstate")
    }
    func read(_ slot: String) throws -> Data {
        let file = try url(slot)
        let attributes = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard attributes.isSymbolicLink != true, (attributes.fileSize ?? Int.max) <= 180*1024*1024 else { throw VetaError.message("El archivo de partida supera el límite o no es válido.") }
        return try Data(contentsOf: file)
    }
    func list() -> [SaveSlot] {
        Self.slots.map { slot in
            do {
                let file = try url(slot)
                guard FileManager.default.fileExists(atPath: file.path) else { return SaveSlot(id: slot, title: Self.title(slot), state: nil, issue: nil) }
                let envelope = try JSONDecoder().decode(StateFile.self, from: read(slot))
                guard envelope.rom == rom, envelope.core == core, (envelope.thumbnail?.count ?? 0) <= 512*1024 else { throw VetaError.message("Partida incompatible") }
                return SaveSlot(id: slot, title: Self.title(slot), state: SaveMetadata(createdAt: envelope.createdAt, thumbnail: envelope.thumbnail, protected: envelope.protected, options: envelope.optionsSnapshot, name: envelope.name), issue: nil)
            } catch { return SaveSlot(id: slot, title: Self.title(slot), state: nil, issue: error.localizedDescription) }
        }
    }
    func write(_ encoded: Data, slot: String) throws {
        guard ["auto", "quick"].contains(slot) || Self.manualSlots.contains(slot) else { throw VetaError.message("La copia anterior se conserva para recuperación.") }
        let file = try url(slot)
        _ = try StateFile.decode(encoded, rom: rom, core: core)
        var output = encoded
        if FileManager.default.fileExists(atPath: file.path) {
            let old = try read(slot)
            let metadata = try JSONDecoder().decode(StateFile.self, from: old)
            guard metadata.protected != true else { throw VetaError.message("Esta partida está protegida. Desprotégela antes de reemplazarla.") }
            if Self.manualSlots.contains(slot), let name = metadata.name {
                var incoming = try JSONDecoder().decode(StateFile.self, from: encoded)
                incoming.name = name
                output = try JSONEncoder().encode(incoming)
            }
            if slot == "auto" || slot == "quick" {
                // Do not replace a useful recovery copy with a corrupt state.
                if (try? StateFile.decode(old, rom: rom, core: core)) != nil {
                    try old.write(to: url("previous-" + slot), options: .atomic)
                }
            }
        }
        try output.write(to: file, options: .atomic)
        guard try read(slot) == output else { throw VetaError.message("No se pudo verificar la partida guardada.") }
    }
    func rename(_ slot: String, name: String) throws {
        guard Self.manualSlots.contains(slot) else { throw VetaError.message("Ranura de guardado inválida.") }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count <= 80, !clean.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw VetaError.message("El nombre admite hasta 80 caracteres y una sola línea.")
        }
        let data = try read(slot)
        _ = try StateFile.decode(data, rom: rom, core: core)
        var envelope = try JSONDecoder().decode(StateFile.self, from: data)
        envelope.name = clean.isEmpty ? nil : clean
        let output = try JSONEncoder().encode(envelope)
        try output.write(to: url(slot), options: .atomic)
        guard try read(slot) == output else { throw VetaError.message("No se pudo verificar la partida guardada.") }
    }
    func protect(_ slot: String, enabled: Bool) throws {
        guard Self.manualSlots.contains(slot) else { throw VetaError.message("Solo las ranuras manuales pueden protegerse.") }
        let data = try read(slot)
        _ = try StateFile.decode(data, rom: rom, core: core)
        var metadata = try JSONDecoder().decode(StateFile.self, from: data)
        metadata.protected = enabled
        try JSONEncoder().encode(metadata).write(to: url(slot), options: .atomic)
    }
    func delete(_ slot: String) throws {
        guard Self.manualSlots.contains(slot) else { throw VetaError.message("Solo se eliminan las ranuras manuales desde esta vista.") }
        let file = try url(slot)
        // A corrupt envelope is retained until repaired/exported, not silently erased.
        let metadata = try JSONDecoder().decode(StateFile.self, from: read(slot))
        guard metadata.protected != true else { throw VetaError.message("Desprotege la partida antes de eliminarla.") }
        try FileManager.default.removeItem(at: file)
    }
    static func thumbnail() -> Data? {
        let width = Int(veta_width()), height = Int(veta_height())
        guard width > 0, height > 0, width <= 2048, height <= 2048,
              let pixels = veta_video(), let provider = CGDataProvider(data: Data(bytes: pixels, count: width*height*4) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width*4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue).union(.byteOrder32Little), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let scale = min(480 / CGFloat(width), 360 / CGFloat(height))
        let size = CGSize(width: max(1, (CGFloat(width) * scale).rounded()), height: max(1, (CGFloat(height) * scale).rounded()))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let data = UIGraphicsImageRenderer(size: size, format: format).image { _ in UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size)) }.jpegData(compressionQuality: 0.85)
        guard let data, data.count <= 512*1024 else { return nil }; return data
    }
}
struct SaveStateGallery: View {
    @ObservedObject var emulation: Emulation
    var body: some View {
        SaveGalleryView(gameName: emulation.game.name, store: emulation.saveStore,
                        save: { try emulation.save($0) }, load: { try emulation.restore($0) },
                        open: { emulation.openMenu() })
    }
}
struct SaveGalleryView: View {
    let gameName: String
    let store: NativeSaveStore
    let save: (String) async throws -> Void
    let load: (String) async throws -> Void
    var open: () -> Void = {}
    var allowedSlots = NativeSaveStore.slots
    @Environment(\.dismiss) private var dismiss
    @State private var slots: [SaveSlot] = []
    @State private var error: String?
    @State private var pending: SaveSlot?
    @State private var replacing: SaveSlot?
    @State private var loading: SaveSlot?
    @State private var deletedSlot: String?
    @State private var renaming: SaveSlot?
    @State private var saveName = ""
    @State private var busy = false
    var body: some View {
        NavigationStack {
            List {
                Section { Text("Cada partida conserva juego, motor y perfil. Al cargar, VETA conserva una copia de la sesión actual para recuperarse si el motor rechaza el estado.").font(.footnote) }
                if let error { Text(L10n.text(error)).foregroundStyle(.red) }
                ForEach(slots) { slot in
                    VStack(alignment: .leading, spacing: 8) {
                        if let data = slot.state?.thumbnail, let image = UIImage(data: data) {
                            Image(uiImage: image).resizable().scaledToFit()
                                .frame(maxWidth: .infinity).frame(height: 160)
                                .background(.black).clipShape(RoundedRectangle(cornerRadius: 10))
                                .accessibilityLabel("Captura al guardar")
                                .accessibilityIdentifier("save-preview-\(slot.id)")
                        } else if slot.state != nil {
                            Label("Sin captura en este guardado", systemImage: "photo")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        HStack {
                            VStack(alignment: .leading) {
                                Text(verbatim: slot.displayTitle).font(.headline)
                                if let date = slot.state?.createdAt { Text(date, style: .date).font(.caption); Text(date, style: .time).font(.caption) }
                                if let options = slot.state?.options, !options.isEmpty {
                                    Text(options.keys.sorted().map { "\(L10n.text(CoreOptionID(rawValue:$0)?.title ?? $0)): \(options[$0]!)" }.joined(separator: " · ")).font(.caption)
                                }
                                if slot.state?.protected == true { Label("Protegida", systemImage: "lock.fill").font(.caption) }
                                if let issue = slot.issue { Text(L10n.text(issue)).font(.caption).foregroundStyle(.red) }
                                if slot.state == nil && slot.issue == nil { Text("Vacía").font(.caption) }
                                if deletedSlot == slot.id {
                                    Label("Partida eliminada", systemImage: "checkmark.circle.fill")
                                        .font(.callout).foregroundStyle(VetaTheme.mint)
                                        .accessibilityIdentifier("save-deleted-\(slot.id)")
                                }
                            }
                        }
                        LazyVGrid(columns:[GridItem(.flexible(),alignment:.leading),GridItem(.flexible(),alignment:.leading)],alignment:.leading,spacing:10) {
                            if slot.state != nil { Button("Cargar") { loading = slot } }
                            if NativeSaveStore.manualSlots.contains(slot.id) {
                                Button(LocalizedStringKey(slot.state == nil ? "Guardar aquí" : "Reemplazar")) { if slot.state == nil { perform { try await save(slot.id) } } else { replacing = slot } }.disabled(slot.state?.protected == true || slot.issue != nil)
                                if slot.state != nil {
                                    Button("Cambiar nombre") { saveName = slot.state?.name ?? ""; renaming = slot }
                                    Button(LocalizedStringKey(slot.state?.protected == true ? "Desproteger" : "Proteger")) { run { try store.protect(slot.id, enabled: slot.state?.protected != true) } }
                                }
                            }
                        }.buttonStyle(.borderless)
                        if NativeSaveStore.manualSlots.contains(slot.id), slot.state != nil {
                            Button(role: .destructive) { pending = slot } label: {
                                Label("Eliminar partida", systemImage: "trash")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.bordered).tint(.red)
                            .disabled(slot.state?.protected == true)
                            .accessibilityIdentifier("delete-save-\(slot.id)")
                            if slot.state?.protected == true {
                                Text("Para eliminarla, toca primero Desproteger.").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(.vertical, 4).accessibilityIdentifier("save-slot-\(slot.id)").listRowBackground(VetaTheme.panel)
                }
            }
            .vetaForm().tint(VetaTheme.mint)
            .disabled(busy).interactiveDismissDisabled(busy)
            .overlay { if busy { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .navigationTitle("Mis partidas").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Listo") { dismiss() }.disabled(busy) }
            .onAppear { open(); reload() }
            .alert("Nombre de la partida", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Nombre", text: $saveName)
                Button("Guardar") {
                    if let slot = renaming { run { try store.rename(slot.id, name: saveName) } }
                    renaming = nil
                }
                Button("Cancelar", role: .cancel) { renaming = nil }
            } message: { Text("Déjalo vacío para recuperar el nombre original.") }
            .confirmationDialog("¿Cargar esta partida?", isPresented: Binding(get: { loading != nil }, set: { if !$0 { loading = nil } }), titleVisibility: .visible) {
                if let slot = loading { Button("Cargar partida") { perform { try await load(slot.id); dismiss() }; loading = nil } }
            } message: { Text("La sesión actual se conservará en «Antes de cargar».") }
            .alert("¿Eliminar esta partida?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
                if let slot = pending {
                    Button("Eliminar partida", role: .destructive) {
                        run { try store.delete(slot.id); deletedSlot = slot.id }
                        pending = nil
                    }.accessibilityIdentifier("confirm-delete-save")
                }
                Button("Cancelar", role: .cancel) { pending = nil }
            } message: {
                if let slot = pending {
                    Text(L10n.format("Se eliminará «%@» de «%@». Las demás partidas y el guardado dentro del juego se conservan. Esta acción no se puede deshacer.", slot.displayTitle, gameName))
                }
            }
            .confirmationDialog("¿Reemplazar esta partida?", isPresented: Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } }), titleVisibility: .visible) {
                if let slot = replacing { Button("Reemplazar", role: .destructive) { perform { try await save(slot.id) }; replacing = nil } }
            }
        }
    }
    private func reload() {
        let all = store.list().filter { allowedSlots.contains($0.id) }
        slots = all.filter { NativeSaveStore.manualSlots.contains($0.id) } + all.filter { !NativeSaveStore.manualSlots.contains($0.id) }
    }
    private func run(_ action: () throws -> Void) { deletedSlot = nil; do { try action(); error = nil } catch { self.error = error.localizedDescription }; reload() }
    private func perform(_ action: @escaping () async throws -> Void) {
        guard !busy else { return }; busy = true; deletedSlot = nil
        Task { @MainActor in
            defer { busy = false; reload() }
            do { try await action(); error = nil } catch { self.error = error.localizedDescription }
        }
    }
}

struct EngineSaveArchive: Codable {
    let engine: DSGameEngine
    let states: [String:Data]
    let ram: Data?
    let rtc: Data?
    let coreSaves: [String:Data]?
}
extension Library {
    func archiveOtherEngine(_ game:Game)throws->EngineSaveArchive? {
        guard game.console == .ds else{return nil}
        var other=game;other.dsEngine=game.dsEngine == .desmume ? .melonDS:.desmume
        guard FileManager.default.fileExists(atPath:stateDirectory(other).path) else{return nil}
        func optional(_ name:String)throws->Data? {let path=file(other,name);return FileManager.default.fileExists(atPath:path.path) ? try Data(contentsOf:path):nil}
        var states:[String:Data]=[:]
        for slot in NativeSaveStore.slots {if let data=try optional(slot+".vstate"){states[slot]=data}}
        let ram=try optional("battery.sav"),rtc=try optional("clock.rtc"),saves=try coreSaveFiles(other)
        if states.isEmpty && ram==nil && rtc==nil && saves==nil {return nil}
        return EngineSaveArchive(engine:other.dsEngine,states:states,ram:ram,rtc:rtc,coreSaves:saves)
    }
    func validateEngineArchive(_ archive:EngineSaveArchive,game:Game)throws {
        guard game.console == .ds,archive.engine != game.dsEngine,archive.states.count<=NativeSaveStore.slots.count,
              archive.states.keys.allSatisfy({NativeSaveStore.slots.contains($0)}),(archive.ram?.count ?? 0)<=4*1024*1024,(archive.rtc?.count ?? 0)<=4096 else {throw VetaError.message("Respaldo de motor Nintendo DS inválido.")}
        var other=game;other.dsEngine=archive.engine
        for state in archive.states.values {_ = try StateFile.decode(state,rom:game.id,core:other.coreID)}
        if let files=archive.coreSaves {try Self.validateCoreSaves(files)}
    }
    func restoreEngineArchive(_ archive:EngineSaveArchive,game:Game)throws {
        try validateEngineArchive(archive,game:game)
        var other=game;other.dsEngine=archive.engine
        _ = try prepareSessionSaves(for:other)
        for (slot,data) in archive.states {try data.write(to:file(other,slot+".vstate"),options:.atomic)}
        if let ram=archive.ram {try ram.write(to:file(other,"battery.sav"),options:.atomic)}
        if let rtc=archive.rtc {try rtc.write(to:file(other,"clock.rtc"),options:.atomic)}
        if let files=archive.coreSaves {try restoreCoreSaves(files,for:other)}
    }
}

#if VETA_JIT_DEVELOPMENT
// Explicit development-only fixture: bundled homebrew and saves stay in a unique cache root.
// Every launch owns a new cache directory; normal launches never create this fixture.
struct SaveGalleryQAView: View {
    @State private var session: Emulation?
    @State private var failure: String?
    var body: some View {
        Group {
            if let session { SaveStateGallery(emulation: session) }
            else if let failure { Text(verbatim: failure) }
            else { ProgressView() }
        }.task {
            guard session == nil, failure == nil else { return }
            do {
                let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("VetaSaveGalleryQA").appendingPathComponent(UUID().uuidString)
                let library = Library(root: root)
                let game = Game(id: "save-gallery-fixture", name: "Thwaite · QA")
                let model = Emulation(game: game, library: library)
                let store = model.saveStore
                try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
                guard let rom = Bundle.main.url(forResource: "thwaite", withExtension: "nes", subdirectory: "Content/thwaite"),
                      veta_load(rom.path, store.directory.path, "NTSC") else {
                    throw VetaError.message("No se encontró el juego de muestra.")
                }
                defer { veta_unload() }
                for _ in 0..<180 { veta_run() }
                for slot in ["slot1", "slot2", "slot3", "auto", "quick"] {
                    if slot == "slot2" {
                        veta_set_input(0, 8)
                        for _ in 0..<3 { veta_run() }
                        veta_set_input(0, 0)
                        for _ in 0..<180 { veta_run() }
                    }
                    var bytes = Data(count: veta_state_size())
                    guard !bytes.isEmpty, bytes.withUnsafeMutableBytes({ veta_save_state($0.baseAddress, $0.count) }) else {
                        throw VetaError.message("No se pudo obtener el estado.")
                    }
                    let preview = NativeSaveStore.thumbnail()
                    guard preview != nil else { throw VetaError.message("No se pudo obtener el estado.") }
                    // slot3 deliberately models a legacy save without an image.
                    try store.write(StateFile.encode(bytes, rom: game.id, core: store.core, thumbnail: slot == "slot3" ? nil : preview), slot: slot)
                }
                try store.protect("slot2", enabled: true)
                try Data("battery-preservation-fixture".utf8).write(to: store.directory.appendingPathComponent("battery.sav"))
                session = model
            } catch { failure = error.localizedDescription }
        }
    }
}
#endif
