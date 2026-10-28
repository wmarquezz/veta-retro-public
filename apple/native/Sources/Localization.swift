import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case spanish = "es", english = "en", chinese = "zh-Hans", hindi = "hi", arabic = "ar", french = "fr", german = "de", italian = "it"
    var id: String { rawValue }
    var nativeName: String {
        switch self {
        case .spanish: return "Español"
        case .english: return "English"
        case .chinese: return "简体中文"
        case .hindi: return "हिन्दी"
        case .arabic: return "العربية"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .italian: return "Italiano"
        }
    }
    var locale: Locale { Locale(identifier: rawValue) }
    var layoutDirection: LayoutDirection { self == .arabic ? .rightToLeft : .leftToRight }
    static let preferenceKey = "native.language"
    static func resolve(stored: String?, preferredLanguages: [String]) -> Self {
        if let stored, let explicit = Self(rawValue: stored) { return explicit }
        for identifier in preferredLanguages {
            let parts = identifier.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-")
            guard let code = parts.first else { continue }
            if code == "zh" {
                if !parts.contains("hant") && !parts.contains("tw") && !parts.contains("hk") && !parts.contains("mo") { return .chinese }
            } else if let supported = Self(rawValue: String(code)) { return supported }
        }
        return .english
    }
    static var current: Self { resolve(stored: UserDefaults.standard.string(forKey: preferenceKey), preferredLanguages: Locale.preferredLanguages) }
}
@MainActor final class LocalizationSettings: ObservableObject {
    @Published var selectedLanguage: AppLanguage {
        didSet { defaults.set(selectedLanguage.rawValue, forKey: AppLanguage.preferenceKey) }
    }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard, preferredLanguages: [String] = Locale.preferredLanguages) {
        self.defaults = defaults
        selectedLanguage = AppLanguage.resolve(stored: defaults.string(forKey: AppLanguage.preferenceKey), preferredLanguages: preferredLanguages)
    }
    var locale: Locale { selectedLanguage.locale }
    var layoutDirection: LayoutDirection { selectedLanguage.layoutDirection }
}
enum L10n {
    static func catalog(_ language: AppLanguage, bundle: Bundle = .main) -> [String: String] {
        guard let url = bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language.rawValue),
              let data = try? Data(contentsOf: url),
              let result = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else { return [:] }
        return result
    }
    static func text(_ key: String, language: AppLanguage? = nil, bundle: Bundle = .main) -> String {
        let selected = language ?? .current
        guard let path = bundle.path(forResource: selected.rawValue, ofType: "lproj"), let localized = Bundle(path: path) else { return key }
        let missing = "\u{FFFF}veta-missing-translation"
        let translated = localized.localizedString(forKey: key, value: missing, table: "Localizable")
        if translated != missing { return translated }
        // Existing model errors carry completed Spanish strings. Match only these
        // bounded app-authored templates; filenames and engine payloads stay intact.
        for pattern in legacyMessages {
            guard let expression = try? NSRegularExpression(pattern: pattern.expression),
                  let match = expression.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) else { continue }
            let values: [CVarArg] = (1..<match.numberOfRanges).map { index in
                let value = Range(match.range(at: index), in: key).map { String(key[$0]) } ?? ""
                return pattern.localizedCaptures.contains(index) ? text(value, language: selected, bundle: bundle) : value
            }
            let template = localized.localizedString(forKey: pattern.key, value: pattern.key, table: "Localizable")
            return String(format: template, locale: selected.locale, arguments: values)
        }
        return key
    }
    private struct LegacyMessage {
        let key: String
        let expression: String
        var localizedCaptures: Set<Int> = []
    }
    private static let legacyMessages: [LegacyMessage] = [
        .init(key: "No se actualizó el juego PS3; se restauró la instalación anterior. %@", expression: #"^No se actualizó el juego PS3; se restauró la instalación anterior\. ([\s\S]+)$"#, localizedCaptures: [1]),
        .init(key: "No se completó la actualización PS3. %@", expression: #"^No se completó la actualización PS3\. ([\s\S]+)$"#, localizedCaptures: [1]),
        .init(key: "No se pudo abrir la biblioteca: %@", expression: #"^No se pudo abrir la biblioteca: ([\s\S]+)$"#, localizedCaptures: [1]),
        .init(key: "No se pudieron organizar las carpetas de Archivos: %@ La biblioteca y las partidas están disponibles. VETA volverá a intentarlo al abrir.", expression: #"^No se pudieron organizar las carpetas de Archivos: ([\s\S]+) La biblioteca y las partidas están disponibles\. VETA volverá a intentarlo al abrir\.$"#, localizedCaptures: [1]),
        .init(key: "El motor de %@ todavía no está integrado.", expression: #"^El motor de (.+) todavía no está integrado\.$"#),
        .init(key: "Falta la pista %@.", expression: #"^Falta la pista (.+)\.$"#),
        .init(key: "Hay varias pistas llamadas %@. Importa un disco a la vez.", expression: #"^Hay varias pistas llamadas (.+)\. Importa un disco a la vez\.$"#),
        .init(key: "Falta %@. Selecciona el CUE junto con todas sus pistas BIN o WAV.", expression: #"^Falta (.+)\. Selecciona el CUE junto con todas sus pistas BIN o WAV\.$"#),
        .init(key: "El archivo no tiene una cabecera válida de %@ o está incompleto.", expression: #"^El archivo no tiene una cabecera válida de (.+) o está incompleto\.$"#),
        .init(key: "%@ todavía no está disponible en este dispositivo.", expression: #"^(.+) todavía no está disponible en este dispositivo\.$"#),
        .init(key: "La BIOS %@ no es válida.", expression: #"^La BIOS (.+) no es válida\.$"#),
        .init(key: "La BIOS %@ no coincide con la versión esperada.", expression: #"^La BIOS (.+) no coincide con la versión esperada\.$"#),
        .init(key: "No se trasladó un enlace de V-Retro: %@.", expression: #"^No se trasladó un enlace de V-Retro: (.+)\.$"#),
        .init(key: "No se pudo abrir este juego de %@. Comprueba el archivo y su compatibilidad.", expression: #"^No se pudo abrir este juego de (.+)\. Comprueba el archivo y su compatibilidad\.$"#),
        .init(key: "Audio: %@", expression: #"^Audio: ([\s\S]+)$"#, localizedCaptures: [1]),
        .init(key: "No se pudo guardar al pausar: %@", expression: #"^No se pudo guardar al pausar: ([\s\S]+)$"#, localizedCaptures: [1]),
        .init(key: "No se pudo guardar al salir: %@", expression: #"^No se pudo guardar al salir: ([\s\S]+)$"#, localizedCaptures: [1])
    ]
    static func format(_ key: String, _ arguments: CVarArg..., language: AppLanguage? = nil) -> String {
        let selected = language ?? .current
        return String(format: text(key, language: selected), locale: selected.locale, arguments: arguments)
    }
    static func gameCount(_ count: Int, language: AppLanguage? = nil) -> String {
        format(count == 1 ? "%lld juego" : "%lld juegos", count, language: language)
    }
    static func missingKeys(required: Set<String>, catalog: [String: String]) -> Set<String> {
        required.subtracting(catalog.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.keys)
    }
}
struct LanguageSettingsView: View {
    @EnvironmentObject private var settings: LocalizationSettings
    var body: some View {
        List {
            Section("Idioma de la app") {
                ForEach(AppLanguage.allCases) { language in
                    Button { settings.selectedLanguage = language } label: {
                        HStack {
                            Text(verbatim: language.nativeName)
                            Spacer()
                            if settings.selectedLanguage == language { Image(systemName: "checkmark") }
                        }.contentShape(Rectangle())
                    }.accessibilityIdentifier("language-\(language.rawValue)")
                        .accessibilityAddTraits(settings.selectedLanguage == language ? .isSelected : [])
                }
            }.listRowBackground(VetaTheme.panel)
            Section { Text("Los nombres de juegos y consolas conservan su idioma original.").font(.footnote) }.listRowBackground(VetaTheme.panel)
        }.vetaForm().tint(VetaTheme.mint).environment(\.locale, settings.locale)
            .environment(\.layoutDirection, settings.layoutDirection)
            .navigationTitle(Text(verbatim: L10n.text("Idioma", language: settings.selectedLanguage)))
    }
}
