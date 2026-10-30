import Foundation
import SwiftUI

/// Session cookies stay in memory; optional credentials are managed separately in Keychain.
actor KrafifySharedConnection: DirectCloudSource {
    static let origin = "https://retro.krafify.com"
    private let http: DirectCloudHTTP
    private var cookie: String?
    init(http: DirectCloudHTTP = DirectCloudURLSession(allowDownloadRedirects: false)) { self.http = http }
    static func validateLink(_ text: String) throws -> URL {
        guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https", parts.host?.lowercased() == "retro.krafify.com",
              parts.user == nil, parts.password == nil, parts.port == nil || parts.port == 443,
              ["/compartir", "/compartir/"].contains(parts.path), parts.query == nil, parts.fragment == nil,
              let url = parts.url else { throw KrafifySharedError.invalidLink }
        return url
    }
    private func request(_ action: String, item: String? = nil) -> URLRequest {
        var parts = URLComponents(string: Self.origin + "/api/shared-drive/" + action)!
        if let item { parts.queryItems = [.init(name: "item", value: item)] }
        var request = URLRequest(url: parts.url!)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }
    private func check(_ response: HTTPURLResponse, data: Data? = nil) throws {
        guard response.url?.scheme == "https", response.url?.host == "retro.krafify.com" else { throw DirectCloudError.invalidResponse }
        if response.statusCode == 401 { cookie = nil; throw KrafifySharedError.password }
        if response.statusCode == 403 { throw KrafifySharedError.expired }
        if response.statusCode == 429 { throw KrafifySharedError.limited }
        if response.statusCode == 412 { throw DirectCloudError.changed }
        guard response.statusCode == 200 else { throw DirectCloudError.service(response.statusCode) }
    }
    func login(link: String, password: String) async throws {
        cookie = nil
        _ = try Self.validateLink(link)
        guard !password.isEmpty, password.count <= 256 else { throw KrafifySharedError.password }
        var req = request("login"); req.httpMethod = "POST"
        req.setValue(Self.origin, forHTTPHeaderField: "Origin")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["password": password])
        let (data, response) = try await http.data(req); try check(response, data: data)
        guard let raw = response.value(forHTTPHeaderField: "Set-Cookie"),
              let value = raw.split(separator: ";").first.map(String.init),
              value.hasPrefix("__Host-veta-share="), value.utf8.count < 4096,
              !value.contains("\r"), !value.contains("\n") else { throw DirectCloudError.invalidResponse }
        cookie = value
    }
    func list(folder: String) async throws -> [DirectCloudEntry] {
        guard cookie != nil else { throw KrafifySharedError.password }
        var next: String? = folder == "root" || folder.isEmpty ? nil : folder
        var result: [DirectCloudEntry] = [], pages = Set<String>()
        repeat {
            try Task.checkCancellation()
            if let next, !pages.insert(next).inserted { throw DirectCloudError.invalidResponse }
            let (data, response) = try await http.data(request("list", item: next)); try check(response, data: data)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = object["items"] as? [[String: Any]] else { throw DirectCloudError.invalidResponse }
            for item in items {
                guard let id = item["item"] as? String, !id.isEmpty, id.utf8.count <= 8192,
                      let name = item["name"] as? String, let folder = item["folder"] as? Bool else { throw DirectCloudError.invalidResponse }
                let size = (item["size"] as? String).flatMap(Int64.init) ?? (item["size"] as? NSNumber)?.int64Value
                if let size, size < 0 { throw DirectCloudError.invalidResponse }
                result.append(.init(id: id, name: name, folder: folder, size: size, revision: item["revision"] as? String, md5: item["md5"] as? String, canDownload: folder || item["download"] as? Bool == true))
            }
            guard result.count <= 10_000, pages.count <= 100 else { throw DirectCloudError.limit }
            next = object["next"] as? String
            if let next, next.isEmpty || next.utf8.count > 8192 { throw DirectCloudError.invalidResponse }
        } while next != nil
        return result
    }
    func download(_ entry: DirectCloudEntry, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        guard cookie != nil else { throw KrafifySharedError.password }
        guard !entry.folder, entry.canDownload else { throw DirectCloudError.permission }
        var req = request("download", item: entry.id)
        if let revision = entry.revision { req.setValue(revision, forHTTPHeaderField: "X-Veta-Revision") }
        let (url, response) = try await http.download(req, progress: progress)
        do { try check(response); try DirectCloudTransfer.validateFile(url, entry: entry); return url }
        catch { try? FileManager.default.removeItem(at: url); throw error }
    }
}

enum KrafifySharedError: LocalizedError {
    case invalidLink, password, expired, limited
    var errorDescription: String? {
        switch self {
        case .invalidLink: return L10n.text("Revisa el enlace compartido que te entregó el propietario.")
        case .password: return L10n.text("La contraseña no es válida o la sesión venció. Ingresa la contraseña actual para volver a entrar.")
        case .expired: return L10n.text("El acceso venció o el archivo cambió de carpeta. Cierra este acceso y vuelve a entrar.")
        case .limited: return L10n.text("Espera un minuto antes de volver a intentar la conexión.")
        }
    }
}

struct KrafifySharedAccessView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var form = SharedAccessForm()
    @State private var error: String?
    @State private var busy = false
    @State private var opened = false
    @State private var operation: Task<Void, Never>?
    @StateObject private var model = DirectCloudBrowserModel()
    let commit: (CloudImportPreparation.Snapshot) throws -> String
    var body: some View {
        NavigationStack {
            Form {
                Section("Enlace compartido") {
                    TextField("Pega aquí el enlace compartido", text: $form.address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive().accessibilityIdentifier("shared-link-url").disabled(busy)
                    SecureField("Contraseña del enlace", text: $form.password).textContentType(.password).privacySensitive().accessibilityIdentifier("shared-link-password").disabled(busy)
                    Text("Usa la contraseña que te entregó el propietario. No es la de Google ni la de Apple.").font(.footnote)
                    Toggle("Recordar acceso en este iPhone", isOn: $form.remember).disabled(busy).accessibilityIdentifier("shared-link-remember")
                    Text("Si activas Recordar acceso, el enlace y la contraseña se guardan en el llavero de este iPhone. Si cambia la contraseña, tendrás que ingresar la nueva.").font(.footnote)
                    if form.hasSavedAccess {
                        Button("Olvidar acceso guardado", role: .destructive) {
                            do { try form.forget(); error = nil } catch { self.error = error.localizedDescription }
                        }.disabled(busy).accessibilityIdentifier("shared-link-forget")
                    }
                    Button("Ver consolas y juegos") { connect() }.frame(minHeight: 44).disabled(busy || form.address.isEmpty || form.password.isEmpty).accessibilityIdentifier("shared-link-open")
                    if busy { ProgressView("Abriendo carpeta compartida…") }
                    if let error { Text(error).foregroundStyle(.orange) }
                }
                Section("Todo dentro de VETA") {
                    Text("Abre una consola, selecciona sus juegos y toca Importar selección. La portada con el mismo nombre se incluye automáticamente, también para juegos ZIP.")
                    Text("Los juegos quedan en este iPhone para jugar sin conexión. Olvidar el acceso no elimina tus juegos importados.")
                    Link("Privacidad", destination: URL(string: "https://retro.krafify.com/privacidad#carpeta-compartida")!)
                }
            }.navigationTitle("Abrir enlace compartido").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { operation?.cancel(); form.password = ""; dismiss() } } }
                .sheet(isPresented: $opened, onDismiss: { model.disconnect(); restore() }) { DirectCloudView(model: model, commit: commit) }
        }.tint(VetaTheme.mint).interactiveDismissDisabled(busy).task { restore() }.onDisappear { operation?.cancel(); form.password = "" }
    }
    private func restore() {
        do { try form.restore() } catch { self.error = error.localizedDescription }
    }
    private func connect() {
        busy = true; error = nil
        operation = Task {
            defer { busy = false; operation = nil; form.password = "" }
            do {
                let connection = try await form.authenticate()
                try Task.checkCancellation()
                try await model.connectPortal(connection)
                try Task.checkCancellation(); opened = true
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}
