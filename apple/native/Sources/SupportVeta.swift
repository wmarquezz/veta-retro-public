import SwiftUI
import StoreKit

/// Voluntary, repeatable one-time contributions. Never grants an entitlement.
enum VetaContribution: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { "com.krafify.vetaretro.support.\(rawValue)" }
    var title: String {
        switch self {
        case .small: return "Un impulso"
        case .medium: return "Un gran apoyo"
        case .large: return "Apoyo extra"
        }
    }
    static let productIDs = Set(allCases.map(\.id))
}

@MainActor final class VetaSupportStore: ObservableObject {
    static let shared = VetaSupportStore()
    @Published private(set) var products: [Product] = []
    @Published private(set) var loading = false
    @Published private(set) var purchasingID: String?
    @Published private(set) var feedback: Feedback?
    @Published private(set) var loadFailed = false
    enum Feedback: Equatable {
        case thanks, cancelled, pending, failed, unverified, unavailable
        var message: String {
            switch self {
            case .thanks: return "¡Gracias por apoyar VETA! Tu aporte ayuda a mantener y mejorar la app."
            case .cancelled: return "Aporte cancelado. Puedes seguir usando VETA con normalidad."
            case .pending: return "Apple está esperando la aprobación del aporte. Puedes seguir jugando; te confirmaremos cuando se complete."
            case .failed: return "No se pudo completar el aporte. Revisa tu conexión e inténtalo de nuevo."
            case .unverified: return "No pudimos verificar el aporte con Apple. No vuelvas a pagar para resolverlo; consulta tu historial de compras o contacta con soporte."
            case .unavailable: return "Este aporte no está disponible ahora. Todas las funciones de VETA siguen disponibles."
            }
        }
    }
    private var updates: Task<Void,Never>?
    private var recovery: Task<Void,Never>?
    private var handled = Set<UInt64>()
    init(listenForTransactions: Bool = true) {
        guard listenForTransactions else { return }
        updates = Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                guard !Task.isCancelled else { return }
                await self?.receive(result)
            }
        }
        recovery = Task { [weak self] in
            for await result in StoreKit.Transaction.unfinished {
                guard !Task.isCancelled else { return }
                await self?.receive(result)
            }
        }
    }
    deinit { updates?.cancel(); recovery?.cancel() }
    var busy: Bool { loading || purchasingID != nil }
    func product(for contribution: VetaContribution) -> Product? { products.first { $0.id == contribution.id } }
    func load() async {
        guard !busy else { return }
        loading = true; loadFailed = false
        defer { loading = false }
        do {
            let received = try await Product.products(for: VetaContribution.productIDs)
            products = received.filter { VetaContribution.productIDs.contains($0.id) && $0.type == .consumable }
        } catch {
            products = []; loadFailed = true
        }
    }
    func purchase(_ contribution: VetaContribution) async {
        guard !busy else { return }
        guard AppStore.canMakePayments, let product = product(for: contribution), product.type == .consumable else {
            feedback = .unavailable; return
        }
        purchasingID = product.id; feedback = nil
        defer { purchasingID = nil }
        do {
            switch try await product.purchase() {
            case .success(let result): await receive(result)
            case .userCancelled: feedback = .cancelled
            case .pending: feedback = .pending
            @unknown default: feedback = .failed
            }
        } catch StoreKitError.userCancelled { feedback = .cancelled }
        catch { feedback = .failed }
    }
    private func receive(_ result: VerificationResult<StoreKit.Transaction>) async {
        // The unverified payload is used only to ignore other products, never to
        // acknowledge a contribution or finish an untrusted transaction.
        guard VetaContribution.productIDs.contains(result.unsafePayloadValue.productID) else { return }
        guard case .verified(let transaction) = result else { feedback = .unverified; return }
        guard transaction.productType == .consumable else { return }
        guard handled.insert(transaction.id).inserted else { return }
        if transaction.revocationDate == nil { feedback = .thanks }
        await transaction.finish()
    }
}

struct SupportVetaView: View {
    @ObservedObject var store: VetaSupportStore = .shared
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VetaBrand().padding(.top,8)
                VStack(alignment:.leading,spacing:12) {
                    Text("Apoyar VETA").font(VetaTheme.heading(34)).accessibilityAddTraits(.isHeader)
                    Text("VETA es gratuita. Si te gusta, puedes ayudar a mantenerla y mejorarla con un aporte voluntario.")
                    Text("Pago único. Sin suscripción. No desbloquea funciones adicionales.")
                        .foregroundStyle(VetaTheme.muted)
                }
                VStack(spacing:12) {
                    ForEach(VetaContribution.allCases) { contribution in
                        if let product = store.product(for: contribution) {
                            Button { Task { await store.purchase(contribution) } } label: {
                                VStack(alignment:.leading,spacing:8) {
                                    Text(LocalizedStringKey(contribution.title)).font(.headline)
                                    HStack {
                                        Text(verbatim:product.displayPrice).font(.title2.bold())
                                        Spacer()
                                        if store.purchasingID == product.id { ProgressView().tint(VetaTheme.mint) }
                                        else { Image(systemName:"heart").accessibilityHidden(true) }
                                    }
                                    Text("Aporte único").font(.footnote).foregroundStyle(VetaTheme.muted)
                                }.padding(18).frame(maxWidth:.infinity,alignment:.leading)
                                    .background(VetaTheme.panel,in:RoundedRectangle(cornerRadius:18))
                                    .overlay(RoundedRectangle(cornerRadius:18).stroke(VetaTheme.mint.opacity(0.35)))
                            }.buttonStyle(.plain).disabled(store.busy || !AppStore.canMakePayments)
                                .accessibilityIdentifier("support-\(contribution.rawValue)")
                                .accessibilityLabel(Text(LocalizedStringKey(contribution.title)) + Text(verbatim:", ") + Text(verbatim:product.displayPrice) + Text(", aporte único"))
                        }
                    }
                }
                if store.loading { ProgressView("Consultando aportes…").frame(maxWidth:.infinity) }
                else if store.products.isEmpty {
                    VStack(alignment:.leading,spacing:12) {
                        Text(LocalizedStringKey(store.loadFailed ? "No pudimos consultar los aportes. Revisa tu conexión." : "Los aportes todavía no están disponibles. Puedes seguir disfrutando de VETA gratis."))
                        Button("Volver a consultar") { Task { await store.load() } }
                            .buttonStyle(VetaButton()).disabled(store.busy).accessibilityIdentifier("support-retry")
                    }.padding(18).background(VetaTheme.panel,in:RoundedRectangle(cornerRadius:18))
                }
                if !AppStore.canMakePayments { Text("Las compras están restringidas en este dispositivo.").foregroundStyle(VetaTheme.muted) }
                if let feedback = store.feedback {
                    Text(LocalizedStringKey(feedback.message)).padding(18).frame(maxWidth:.infinity,alignment:.leading)
                        .background(VetaTheme.panel,in:RoundedRectangle(cornerRadius:18))
                        .accessibilityIdentifier("support-feedback")
                        .accessibilityAddTraits(.updatesFrequently)
                }
                VStack(alignment:.leading,spacing:12) {
                    Text("Apple te mostrará el importe antes de confirmar. Cada aporte es independiente; sólo se repite si vuelves a elegirlo.")
                    Text("Gracias también por jugar. Tus juegos, partidas y controles funcionan igual aunque no aportes.")
                    NavigationLink("Ayuda y soporte") { PublicationSupportView() }
                }.font(.footnote).foregroundStyle(VetaTheme.muted)
            }.font(VetaTheme.body(16)).padding(20).frame(maxWidth:600)
                .frame(maxWidth:.infinity)
        }.background(VetaBackdrop()).foregroundStyle(VetaTheme.ink).tint(VetaTheme.mint)
            .navigationTitle("Apoyar VETA").navigationBarTitleDisplayMode(.inline)
            .task { await store.load() }
    }
}
