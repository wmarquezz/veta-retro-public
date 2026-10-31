import Foundation
import SwiftUI

// Deliberately small allowlist of options verified in the pinned cores. A new
// engine option needs its own allowed values and state-compatibility review.
enum CoreOptionID: String, Codable, CaseIterable, Identifiable {
    case nesRegion = "fceumm_region"
    case snesRegion = "snes9x_region"
    case segaRegion = "genesis_plus_gx_region_detect"
    case pspResolution = "ppsspp_internal_resolution"
    case pspTextureFilter = "ppsspp_texture_filtering"
    case ps2Resolution = "play_res_multi"
    case ps2Bilinear = "play_bilinear_filtering"
    var id: String { rawValue }
    var title: String {switch self {case .pspResolution,.ps2Resolution:return "Resolución interna";case .pspTextureFilter:return "Filtrado de texturas";case .ps2Bilinear:return "Filtro bilineal del motor";default:return "Región"}}
    // Newly exposed defaults stay absent until explicitly selected, preserving
    // the fingerprint of pre-existing saves when behaviour has not changed.
    var explicitOnly:Bool {[.pspTextureFilter,.ps2Resolution,.ps2Bilinear].contains(self)}
    var values: [String] {
        switch self {
        case .nesRegion: return ["Auto", "NTSC", "PAL", "Dendy"]
        case .snesRegion: return ["auto", "ntsc", "pal"]
        case .segaRegion: return ["auto", "ntsc-u", "pal", "ntsc-j"]
        case .pspResolution: return ["480x272", "960x544"]
        case .pspTextureFilter:return ["Auto","Nearest","Linear"]
        case .ps2Resolution:return ["1x","2x"]
        case .ps2Bilinear:return ["false","true"]
        }
    }
    func label(_ value:String)->String {switch value {case "Auto","auto":return "Automático";case "true":return "Activado";case "false":return "Desactivado";case "Nearest":return "Píxeles originales";case "Linear":return "Suavizado";default:return value}}
    var defaultValue: String { values[0] }
    func supports(_ console: GameConsole) -> Bool {
        switch self {
        case .nesRegion: return console == .nes
        case .snesRegion: return console == .snes
        case .segaRegion: return [.megaDrive, .masterSystem, .gameGear].contains(console)
        case .pspResolution,.pspTextureFilter: return console == .psp
        case .ps2Resolution,.ps2Bilinear:return console == .ps2
        }
    }
    static func available(for console: GameConsole) -> [Self] { allCases.filter { $0.supports(console) } }
}
struct CoreProfile: Codable, Equatable {
    var version = 1
    var values: [String: String] = [:]
    func validated(for console: GameConsole) throws -> Self {
        guard version == 1, values.count <= CoreOptionID.allCases.count,
              values.allSatisfy({ key, value in
                  guard let option = CoreOptionID(rawValue: key) else { return false }
                  return option.supports(console) && option.values.contains(value)
              }) else { throw VetaError.message("El perfil contiene una opción incompatible con esta consola.") }
        return self
    }
    static func resolved(console: GameConsole, consoleProfile: Self, gameProfile: Self) throws -> Self {
        _ = try consoleProfile.validated(for: console); _ = try gameProfile.validated(for: console)
        var result = Self(values: Dictionary(uniqueKeysWithValues: CoreOptionID.available(for: console).filter { !$0.explicitOnly }.map { ($0.rawValue, $0.defaultValue) }))
        result.values.merge(consoleProfile.values) { _, new in new }
        result.values.merge(gameProfile.values) { _, new in new }
        return result
    }
    var fingerprint: String {
        // Stable independently of JSON/dictionary order. Values are allowlisted
        // and cannot contain separators. Bump this schema for ABI-affecting changes.
        sha256(Data((["veta-options-1"] + values.keys.sorted().map { "\($0)=\(values[$0]!)" }).joined(separator: "\n").utf8))
    }
    func forLaunch(game: Game, nesRegion: String = "Auto") -> Self {
        var result = self
        if game.console == .nes, result.values[CoreOptionID.nesRegion.rawValue] == "Auto" {
            result.values[CoreOptionID.nesRegion.rawValue] = nesRegion
        }
        // SMS region tags are useful when timing is absent from the cartridge.
        // This exact Genesis dump has an ambiguous region header. Identify its
        // normalized content, not the ZIP/member filename; explicit choices win.
        let namedSMSPAL = game.console == .masterSystem &&
            game.name.range(of: #"\((?:Europe|PAL|France|Germany|Italy|Spain|Sweden|Australia)\)"#,
                            options: [.regularExpression, .caseInsensitive]) != nil
        let knownGenesisPAL = game.console == .megaDrive &&
            game.id == "8c254d82237eba38a22d8d434ddd99b9187e408c6eb0393579f864f8c5e882ba"
        if result.values[CoreOptionID.segaRegion.rawValue] == "auto", namedSMSPAL || knownGenesisPAL {
            result.values[CoreOptionID.segaRegion.rawValue] = "pal"
        }
        return result
    }
    func installForNextLoad() throws {
        veta_options_clear()
        for key in values.keys.sorted() {
            guard veta_option_set(key, values[key]!) else {
                veta_options_clear(); throw VetaError.message("No se pudo preparar una opción del motor.")
            }
        }
    }
}
@MainActor struct GameProfileStore {
    let library: Library
    let game: Game
    func url(console: Bool) -> URL {
        console ? library.root.appendingPathComponent("profile-\(game.console.rawValue).json") : library.file(game, "profile.json")
    }
    func read(console: Bool) throws -> CoreProfile {
        let file = url(console: console)
        guard FileManager.default.fileExists(atPath: file.path) else { return CoreProfile() }
        let size = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard size.isSymbolicLink != true, (size.fileSize ?? Int.max) <= 16384 else { throw VetaError.message("El perfil no es válido.") }
        return try JSONDecoder().decode(CoreProfile.self, from: Data(contentsOf: file)).validated(for: game.console)
    }
    func write(_ profile: CoreProfile, console: Bool) throws {
        _ = try profile.validated(for: game.console)
        try JSONEncoder().encode(profile).write(to: url(console: console), options: .atomic)
    }
    func resolved() throws -> CoreProfile {
        try CoreProfile.resolved(console: game.console, consoleProfile: read(console: true), gameProfile: read(console: false))
    }
}
struct GameProfileSettings: View {
    let game: Game
    let library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var consoleScope = false
    @State private var consoleProfile = CoreProfile()
    @State private var gameProfile = CoreProfile()
    @State private var error: String?
    @State private var loaded = false
    @State private var dsEngine = DSGameEngine.desmume
    private var options: [CoreOptionID] { CoreOptionID.available(for: game.console) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Aplicar a", selection: $consoleScope) { Text("Este juego").tag(false); Text("Toda la consola").tag(true) }
                    Text("Los cambios se aplican al cerrar y volver a abrir el juego. Los estados con otro perfil se conservan; para cargarlos, restaura su configuración.")
                        .font(.footnote)
                }
                if !game.console.isStandaloneEngine {Section {NavigationLink("Imagen del juego"){VideoSettingsView(game:game,library:library)}}.listRowBackground(VetaTheme.panel)}
                if game.console == .ds {
                    Section("Motor de este juego") {
                        Picker("Motor Nintendo DS",selection:$dsEngine) {ForEach(DSGameEngine.allCases){Text($0.name).tag($0)}}.accessibilityIdentifier("profile-ds-engine")
                        Text("Cada motor conserva sus propias partidas. Cambiarlo no borra las del otro; se aplica al volver a abrir el juego.").font(.footnote)
                        if dsEngine == .melonDS {Text("melonDS DS está en evaluación. Flappy pasó las pruebas locales de imagen, sonido, controles y estados. DeSmuME sigue siendo el predeterminado.").font(.footnote)}
                    }.listRowBackground(VetaTheme.panel)
                }
                Section(L10n.format("Opciones verificadas de %@",game.console.name)) {
                    if options.isEmpty { Text("Este motor conserva su configuración probada. No hay ajustes experimentales habilitados.") }
                    ForEach(options) { option in
                        Picker(LocalizedStringKey(option.title), selection: binding(option)) {
                            Text(LocalizedStringKey(consoleScope ? "Predeterminado" : "Heredar de consola")).tag("")
                            ForEach(option.values, id: \.self) { Text(LocalizedStringKey(option.label($0))).tag($0) }
                        }.accessibilityIdentifier("profile-region-\(option.rawValue)")
                    }
                    if options.contains(.pspResolution) || options.contains(.ps2Resolution) { Text("2× mejora la definición, pero puede reducir el rendimiento y aumentar la temperatura.").font(.footnote) }
                    Button("Restaurar valores heredados") { if consoleScope { consoleProfile = CoreProfile() } else { gameProfile = CoreProfile() } }
                }.disabled(!loaded).listRowBackground(VetaTheme.panel)
                if let error { Section { Text(L10n.text(error)).foregroundStyle(.red) } }
            }
            .vetaForm().tint(VetaTheme.mint)
            .navigationTitle("Perfil de juego").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Guardar") { save() }.disabled(!loaded).listRowBackground(VetaTheme.panel) }
            }
            .onAppear {
                do { let store = GameProfileStore(library: library, game: game); consoleProfile = try store.read(console: true); gameProfile = try store.read(console: false); dsEngine = library.games.first(where:{$0.id==game.id})?.dsEngine ?? game.dsEngine; loaded = true }
                catch { self.error = error.localizedDescription }
            }
        }
    }
    private func binding(_ option: CoreOptionID) -> Binding<String> {
        Binding(get: { (consoleScope ? consoleProfile : gameProfile).values[option.rawValue] ?? "" }, set: { value in
            if consoleScope { consoleProfile.values[option.rawValue] = value.isEmpty ? nil : value }
            else { gameProfile.values[option.rawValue] = value.isEmpty ? nil : value }
        })
    }
    private func save() {
        do { let store = GameProfileStore(library: library, game: game); _ = try consoleProfile.validated(for:game.console); _ = try gameProfile.validated(for:game.console); try store.write(consoleProfile,console:true); try store.write(gameProfile,console:false); if game.console == .ds {try library.setDSEngine(dsEngine,for:game)}; dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
