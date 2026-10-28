import SwiftUI

struct GameGuide: Codable, Equatable {
    let title: String
    let url: URL
    enum CodingKeys: String, CodingKey { case title, url }
    init(title: String, address: String) throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 160, address.utf8.count <= 2048,
              let parts = URLComponents(string: address), parts.scheme?.lowercased() == "https",
              let host = parts.host, host.contains("."), !host.hasSuffix("."),
              parts.user == nil, parts.password == nil, let url = parts.url else {
            throw VetaError.message("Escribe un título y un enlace HTTPS válido para la guía.")
        }
        self.title = title; self.url = url
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(title: values.decode(String.self, forKey: .title), address: values.decode(URL.self, forKey: .url).absoluteString)
    }
}
struct GuideSuggestion: Identifiable {
    let console: GameConsole
    let names: [String]
    let title: String
    let language: String
    let address: String
    var id: String { address }
    var guide: GameGuide { try! GameGuide(title: title, address: address) }
}
enum GuideCatalog {
    // Hand-reviewed title/platform mappings; never guess URLs from ROM filenames.
    // Availability/content remains controlled by each external publisher.
    static let entries: [GuideSuggestion] = [
        .init(console: .nes, names: ["The Legend of Zelda"], title: "The Legend of Zelda · StrategyWiki", language: "English", address: "https://strategywiki.org/wiki/The_Legend_of_Zelda/Walkthrough"),
        .init(console: .n64, names: ["The Legend of Zelda: Ocarina of Time", "Zelda Ocarina of Time"], title: "Ocarina of Time · Guías Nintendo", language: "Español", address: "https://www.guiasnintendo.com/4_Nintendo_64/zelda_ocarina_time/zelda64/welcome.html"),
        .init(console: .gamecube, names: ["Metroid Prime"], title: "Metroid Prime · Guías Nintendo", language: "Español", address: "https://www.guiasnintendo.com/2_GAMECUBE/MetroidPrime/MetroidPrime_SP/welcome.html"),
        .init(console: .snes, names: ["Super Metroid"], title: "Super Metroid · TMola / GameFAQs", language: "Español", address: "https://gamefaqs.gamespot.com/snes/588741-super-metroid/faqs/19107")
    ]
    static func suggestions(for game: Game) -> [GuideSuggestion] {
        guard !CoverMatcher.modified(game.name) else { return [] }
        let name = CoverMatcher.key(game.name)
        return entries.filter { $0.console == game.console && $0.names.contains { CoverMatcher.key($0) == name } }
    }
    static func searchURL(title: String, console: GameConsole, site: String? = nil, language: AppLanguage = .spanish) -> URL {
        let terms: String
        switch language {
        case .spanish: terms = "guía completa"
        case .french: terms = "guide complet"
        case .chinese: terms = "完整攻略"
        case .hindi: terms = "पूरी गाइड"
        case .arabic: terms = "دليل كامل"
        case .english: terms = "complete walkthrough"
        case .german: terms = "Komplettlösung"
        case .italian: terms = "guida completa"
        }
        let allowed = ["guiasnintendo.com", "strategywiki.org", "gamefaqs.gamespot.com"]
        let scope = site.flatMap { allowed.contains($0) ? "site:" + $0 : nil } ?? ""
        let query = [String(title.prefix(200)), console.name, terms, scope].filter { !$0.isEmpty }.joined(separator: " ")
        var url = URLComponents(string: "https://www.google.com/search")!
        url.queryItems = [URLQueryItem(name: "q", value: query)]
        return url.url!
    }
}
extension Library {
    func setGuide(_ guide: GameGuide?, for game: Game) throws {
        guard let index = games.firstIndex(where: { $0.id == game.id }) else { throw VetaError.message("El juego ya no está en la biblioteca.") }
        var next = games; next[index].guide = guide
        try JSONEncoder().encode(next).write(to: root.appendingPathComponent("library.json"), options: .atomic)
        games = next
    }
}
struct GameGuidesView: View {
    let game: Game
    @ObservedObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var localization: LocalizationSettings
    @State private var title = ""
    @State private var address = ""
    @State private var searchTitle = ""
    @State private var error: String?
    @State private var confirmRemove = false
    private enum Field:Hashable {case title,address}
    @FocusState private var focusedField:Field?
    private var saved: GameGuide? { library.games.first(where: { $0.id == game.id })?.guide }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(verbatim: game.name).font(.headline)
                    Text(verbatim: game.console.name).font(.caption)
                    Text("Guarda el enlace a la guía de esta versión del juego. Se abre en el navegador; puede contener spoilers y requiere Internet.").font(.footnote)
                }.listRowBackground(VetaTheme.panel)
                if let saved {
                    Section("Guía guardada") {
                        Link(destination: saved.url) { Label(saved.title, systemImage: "book") }.accessibilityIdentifier("guide-open")
                        Text(verbatim: saved.url.host ?? "").font(.caption)
                        Button("Quitar enlace", role: .destructive) { confirmRemove = true }
                    }.listRowBackground(VetaTheme.panel)
                }
                Section("Enlace de la guía") {
                    TextField("Título de la guía", text: $title).accessibilityIdentifier("guide-title").focused($focusedField,equals:.title).submitLabel(.next).onSubmit {focusedField = .address}
                    TextField("https://…", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("guide-url").focused($focusedField,equals:.address).submitLabel(.done).onSubmit {focusedField=nil}
                    Button("Guardar enlace") {
                        do { save(try GameGuide(title: title, address: address)) } catch { self.error = error.localizedDescription }
                    }.accessibilityIdentifier("guide-save")
                }.listRowBackground(VetaTheme.panel)
                if let error { Text(L10n.text(error)).foregroundStyle(.red) }
                let suggestions = GuideCatalog.suggestions(for: game)
                if !suggestions.isEmpty {
                    Section("Guías sugeridas") {
                        ForEach(suggestions) { item in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(verbatim: item.title).font(.headline)
                                Text(verbatim: item.language).font(.caption)
                                Link("Revisar guía", destination: item.guide.url)
                                Button("Usar esta guía") { save(item.guide) }.accessibilityIdentifier("guide-use-suggestion")
                            }
                        }
                        Text("Comprueba la consola, la edición y el idioma antes de guardar el enlace.").font(.caption)
                    }.listRowBackground(VetaTheme.panel)
                }
                Section("Buscar en Internet") {
                    TextField("Nombre para buscar", text: $searchTitle)
                    Link("Buscar guía completa", destination: GuideCatalog.searchURL(title: searchTitle, console: game.console, language: localization.selectedLanguage))
                    ForEach(["guiasnintendo.com", "strategywiki.org", "gamefaqs.gamespot.com"], id: \.self) { site in
                        Link(destination: GuideCatalog.searchURL(title: searchTitle, console: game.console, site: site, language: localization.selectedLanguage)) { Text(verbatim: site) }
                    }
                    Text("Al buscar, el navegador envía el título y la consola al buscador. No se envían juegos ni partidas. Copia el enlace de la guía que elijas y guárdalo aquí.").font(.caption)
                }.listRowBackground(VetaTheme.panel)
            }.vetaForm().scrollDismissesKeyboard(.interactively).tint(VetaTheme.mint).navigationTitle("Guía del juego")
                .toolbar {
                    ToolbarItem(placement:.confirmationAction){Button("Listo"){dismiss()}}
                    ToolbarItemGroup(placement:.keyboard){Spacer();Button("Listo"){focusedField=nil}.accessibilityIdentifier("guide-keyboard-done")}
                }
                .onAppear { searchTitle = game.name; title = saved?.title ?? game.name; address = saved?.url.absoluteString ?? "" }
                .confirmationDialog("¿Quitar el enlace de la guía?", isPresented: $confirmRemove, titleVisibility: .visible) {
                    Button("Quitar enlace", role: .destructive) { save(nil) }
                    Button("Cancelar", role: .cancel) { }
                }
        }
    }
    private func save(_ guide: GameGuide?) {
        do { try library.setGuide(guide, for: game); title = guide?.title ?? game.name; address = guide?.url.absoluteString ?? ""; error = nil }
        catch { self.error = error.localizedDescription }
    }
}
