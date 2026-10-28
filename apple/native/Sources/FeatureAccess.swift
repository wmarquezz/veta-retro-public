import SwiftUI

enum FeatureClassification: String, Codable, CaseIterable {
    case undecided, free, paidFuture
    var title: String {
        switch self {
        case .undecided: return "Sin decidir"
        case .free: return "Gratuita"
        case .paidFuture: return "Posible función de pago"
        }
    }
}
struct FeatureDefinition: Identifiable {
    let id: String
    let title: String
    let classification: FeatureClassification
}
enum FeatureAccess {
    /// Product planning only. This is not a StoreKit entitlement or receipt.
    static let developmentUnlocked = true
    static let catalog: [FeatureDefinition] = [
        .init(id: "library", title: "Biblioteca y juegos", classification: .undecided),
        .init(id: "engines", title: "Motores de emulación", classification: .undecided),
        .init(id: "states", title: "Partidas guardadas", classification: .undecided),
        .init(id: "controls", title: "Mandos y controles", classification: .undecided),
        .init(id: "skins", title: "Skins y personalización", classification: .undecided),
        .init(id: "artwork", title: "Portadas", classification: .undecided),
        .init(id: "diagnostics", title: "Diagnósticos", classification: .undecided),
        .init(id: "profiles", title: "Perfiles del juego", classification: .undecided),
        .init(id: "tv", title: "Pantalla externa", classification: .undecided),
        .init(id: "localMultiplayer", title: "Multijugador local", classification: .undecided),
        .init(id: "onlineMultiplayer", title: "Multijugador en línea", classification: .undecided),
        .init(id: "languages", title: "Idiomas", classification: .undecided),
        .init(id: "deviceReadiness", title: "Compatibilidad del dispositivo", classification: .undecided)
    ]
    static func isAccessible(_ id: String) -> Bool { developmentUnlocked && catalog.contains { $0.id == id } }
}
struct FeatureAccessView: View {
    var body: some View {
        List {
            Section {
                Label("Desarrollo: todo desbloqueado", systemImage: "lock.open")
                Text("Todavía no hay precios, compras ni suscripciones. La clasificación comercial se decidirá más adelante.").font(.footnote)
            }.listRowBackground(VetaTheme.panel)
            Section("Funciones") {
                ForEach(FeatureAccess.catalog) { feature in
                    HStack {
                        Text(LocalizedStringKey(feature.title))
                        Spacer()
                        Text(LocalizedStringKey(feature.classification.title)).font(.caption).foregroundStyle(.secondary)
                    }.accessibilityIdentifier("feature-\(feature.id)")
                }
            }.listRowBackground(VetaTheme.panel)
        }.vetaForm().tint(VetaTheme.mint).navigationTitle("Acceso a funciones")
    }
}
