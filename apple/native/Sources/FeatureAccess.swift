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
        .init(id: "library", title: "Biblioteca y juegos", classification: .free),
        .init(id: "engines", title: "Motores de emulación", classification: .free),
        .init(id: "states", title: "Partidas guardadas", classification: .free),
        .init(id: "controls", title: "Mandos y controles", classification: .free),
        .init(id: "skins", title: "Skins y personalización", classification: .free),
        .init(id: "artwork", title: "Portadas", classification: .free),
        .init(id: "diagnostics", title: "Diagnósticos", classification: .free),
        .init(id: "profiles", title: "Perfiles del juego", classification: .free),
        .init(id: "tv", title: "Pantalla externa", classification: .free),
        .init(id: "localMultiplayer", title: "Multijugador local", classification: .free),
        .init(id: "onlineMultiplayer", title: "Multijugador en línea", classification: .free),
        .init(id: "languages", title: "Idiomas", classification: .free),
        .init(id: "deviceReadiness", title: "Compatibilidad del dispositivo", classification: .free)
    ]
    static func isAccessible(_ id: String) -> Bool { developmentUnlocked && catalog.contains { $0.id == id } }
}
struct FeatureAccessView: View {
    var body: some View {
        List {
            Section {
                Label("Funciones gratuitas", systemImage: "lock.open")
                Text("Las funciones de esta versión son gratuitas. Los aportes de Apoyar VETA son voluntarios y no desbloquean funciones adicionales.").font(.footnote)
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
