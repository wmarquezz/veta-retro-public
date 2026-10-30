import Foundation
import CryptoKit

/// Public OAuth identifiers only. Never put a client secret or a user's token in the bundle.
enum DirectCloudProvider: String, CaseIterable, Identifiable, Codable {
    case google, onedrive, dropbox
    var id: String { rawValue }
    var title: String { switch self { case .google: return "Google Drive"; case .onedrive: return "OneDrive"; case .dropbox: return "Dropbox" } }
    var rootID: String { self == .dropbox ? "" : "root" }
    var scopes: String {
        switch self {
        case .google: return "https://www.googleapis.com/auth/drive.readonly"
        case .onedrive: return "https://graph.microsoft.com/Files.Read offline_access"
        case .dropbox: return "files.metadata.read files.content.read"
        }
    }
    var authorizationEndpoint: String {
        switch self {
        case .google: return "https://accounts.google.com/o/oauth2/v2/auth"
        case .onedrive: return "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
        case .dropbox: return "https://www.dropbox.com/oauth2/authorize"
        }
    }
    var tokenEndpoint: String {
        switch self {
        case .google: return "https://oauth2.googleapis.com/token"
        case .onedrive: return "https://login.microsoftonline.com/common/oauth2/v2.0/token"
        case .dropbox: return "https://api.dropboxapi.com/oauth2/token"
        }
    }
    var apiHost: String {
        switch self { case .google: return "www.googleapis.com"; case .onedrive: return "graph.microsoft.com"; case .dropbox: return "api.dropboxapi.com" }
    }
    func configuration(bundle: Bundle = .main) -> DirectCloudConfiguration? {
        guard let all = bundle.object(forInfoDictionaryKey: "VetaCloudAccounts") as? [String: [String: String]],
              let values = all[rawValue], let client = values["clientID"], !client.isEmpty,
              let redirect = values["redirectURI"], let url = URL(string: redirect),
              let scheme = url.scheme, scheme.contains("."), !["http", "https"].contains(scheme),
              let types = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]],
              types.contains(where: { ($0["CFBundleURLSchemes"] as? [String] ?? []).contains(scheme) }) else { return nil }
        return .init(provider: self, clientID: client, redirectURI: redirect)
    }
}

struct DirectCloudConfiguration {
    let provider: DirectCloudProvider
    let clientID: String
    let redirectURI: String
    var callbackScheme: String { URL(string: redirectURI)!.scheme! }
    var credentialKey: String { provider.rawValue + "." + String(SHA256.hash(data: Data((clientID + redirectURI).utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)) }
}

enum DirectCloudError: LocalizedError {
    case noPreview, notConfigured, reconnect, invalidResponse, unsafeName, ambiguousNames, limit, noGames, noSpace, changed, permission, service(Int), keychain, invalidCallback
    var errorDescription: String? {
        switch self {
        case .noPreview: return L10n.text("Vista previa no disponible")
        case .notConfigured: return L10n.text("La conexión directa aún no está habilitada en esta versión.")
        case .reconnect: return L10n.text("Tu sesión venció o fue revocada. Desconecta la cuenta y vuelve a conectarla.")
        case .invalidResponse: return L10n.text("El servicio no entregó una respuesta válida. Vuelve a intentarlo.")
        case .unsafeName: return L10n.text("Una carpeta contiene un nombre no compatible. Renómbralo en tu servicio de almacenamiento.")
        case .ambiguousNames: return L10n.text("Hay archivos con el mismo nombre en una carpeta. Renómbralos antes de importar.")
        case .limit: return L10n.text("La selección es demasiado grande. Elige una carpeta de consola más pequeña.")
        case .noGames: return L10n.text("No se encontraron juegos compatibles en la selección.")
        case .noSpace: return L10n.text("No hay espacio suficiente en el iPhone para preparar esta importación.")
        case .changed: return L10n.text("Un archivo cambió o no se descargó completo. Vuelve a importarlo.")
        case .permission: return L10n.text("El servicio no permite descargar este archivo con los permisos actuales.")
        case .service: return L10n.text("El servicio no está disponible en este momento. Vuelve a intentarlo.")
        case .keychain: return L10n.text("No se pudo guardar la conexión de forma segura. Desbloquea el iPhone y vuelve a intentarlo.")
        case .invalidCallback: return L10n.text("No se pudo verificar el inicio de sesión. Vuelve a conectar la cuenta.")
        }
    }
}

struct DirectCloudEntry: Identifiable, Hashable {
    let id: String
    let name: String
    let folder: Bool
    var size: Int64?
    var revision: String?
    var md5: String?
    var dropboxHash: String?
    var canDownload = true
    var resourceKey: String?
}
struct DirectCloudPage { let entries: [DirectCloudEntry]; let next: String? }

enum DirectCloudAPI {
    static func component(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~")))!
    }
    static func form(_ values: [String: String]) -> Data {
        Data(values.sorted { $0.key < $1.key }.map { component($0.key) + "=" + component($0.value) }.joined(separator: "&").utf8)
    }
    static func jsonRequest(_ url: String, _ object: [String: Any]) throws -> URLRequest {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: object)
        return req
    }
    static func validateAPIURL(_ url: URL, provider: DirectCloudProvider) throws {
        guard url.scheme == "https", url.host == provider.apiHost, url.port == nil || url.port == 443,
              url.user == nil, url.password == nil, url.fragment == nil else { throw DirectCloudError.invalidResponse }
        if provider == .onedrive && !url.path.hasPrefix("/v1.0/") { throw DirectCloudError.invalidResponse }
    }
    static func listRequest(_ provider: DirectCloudProvider, folder: String, page: String?) throws -> URLRequest {
        switch provider {
        case .google:
            let escaped = folder.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            var url = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            url.queryItems = [URLQueryItem(name: "q", value: "'\(escaped)' in parents and trashed = false"),
                URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,mimeType,size,version,md5Checksum,resourceKey,capabilities/canDownload)"),
                URLQueryItem(name: "supportsAllDrives", value: "true"), URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
                URLQueryItem(name: "pageSize", value: "1000"), URLQueryItem(name: "orderBy", value: "folder,name")]
            if let page { url.queryItems!.append(.init(name: "pageToken", value: page)) }
            return URLRequest(url: url.url!)
        case .onedrive:
            let url = page.flatMap(URL.init(string:)) ?? URL(string: "https://graph.microsoft.com/v1.0/me/drive/" + (folder == "root" ? "root" : "items/" + component(folder)) + "/children?$top=200&$select=id,name,size,folder,file,eTag,remoteItem,deleted")!
            try validateAPIURL(url, provider: provider)
            return URLRequest(url: url)
        case .dropbox:
            if let page { return try jsonRequest("https://api.dropboxapi.com/2/files/list_folder/continue", ["cursor": page]) }
            return try jsonRequest("https://api.dropboxapi.com/2/files/list_folder", ["path": folder, "recursive": false, "limit": 1000, "include_deleted": false])
        }
    }
    static func decodePage(_ data: Data, provider: DirectCloudProvider) throws -> DirectCloudPage {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj[provider == .google ? "files" : (provider == .onedrive ? "value" : "entries")] as? [[String: Any]] else { throw DirectCloudError.invalidResponse }
        var result: [DirectCloudEntry] = []
        for item in raw {
            guard let id = item["id"] as? String, let name = item["name"] as? String else { throw DirectCloudError.invalidResponse }
            let folder: Bool
            switch provider {
            case .google:
                let mime = item["mimeType"] as? String ?? ""
                if mime.hasPrefix("application/vnd.google-apps.") && mime != "application/vnd.google-apps.folder" { continue } // No shortcuts/exports.
                folder = mime == "application/vnd.google-apps.folder"
            case .onedrive:
                if item["remoteItem"] != nil || item["deleted"] != nil { continue }
                folder = item["folder"] != nil
            case .dropbox:
                let tag = item[".tag"] as? String
                if tag == "deleted" { continue }
                folder = tag == "folder"
                if tag != "folder" && tag != "file" { continue }
            }
            let size = (item["size"] as? NSNumber)?.int64Value ?? (item["size"] as? String).flatMap(Int64.init)
            if let size, size < 0 { throw DirectCloudError.invalidResponse }
            result.append(.init(id: id, name: name, folder: folder, size: size,
                revision: item[provider == .google ? "version" : (provider == .onedrive ? "eTag" : "rev")] as? String,
                md5: item["md5Checksum"] as? String, dropboxHash: item["content_hash"] as? String,
                canDownload: (item["capabilities"] as? [String: Any])?["canDownload"] as? Bool ?? item["is_downloadable"] as? Bool ?? true, resourceKey: item["resourceKey"] as? String))
        }
        let next: String?
        switch provider {
        case .google: next = obj["nextPageToken"] as? String
        case .onedrive:
            next = obj["@odata.nextLink"] as? String
            if let next { guard let url = URL(string: next) else { throw DirectCloudError.invalidResponse }; try validateAPIURL(url, provider: provider) }
        case .dropbox:
            if obj["has_more"] as? Bool == true {
                guard let cursor = obj["cursor"] as? String, !cursor.isEmpty else { throw DirectCloudError.invalidResponse }
                next = cursor
            } else { next = nil }
        }
        return .init(entries: result, next: next)
    }
    static func downloadRequest(_ provider: DirectCloudProvider, entry: DirectCloudEntry) throws -> URLRequest {
        guard entry.canDownload, !entry.folder else { throw DirectCloudError.permission }
        var request: URLRequest
        switch provider {
        case .google:
            request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(component(entry.id))?alt=media")!)
        case .onedrive:
            request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/\(component(entry.id))/content")!)
            if let revision = entry.revision { request.setValue(revision, forHTTPHeaderField: "If-Match") }
        case .dropbox:
            request = URLRequest(url: URL(string: "https://content.dropboxapi.com/2/files/download")!); request.httpMethod = "POST"
            // JSON header must be ASCII; Dropbox accepts escaped Unicode.
            let object = ["path": entry.revision.map { "rev:" + $0 } ?? entry.id]
            let bytes = try JSONSerialization.data(withJSONObject: object, options: .fragmentsAllowed)
            let raw = String(decoding: bytes, as: UTF8.self)
            let ascii = raw.utf16.map { $0 > 127 ? String(format: "\\u%04x", $0) : String(UnicodeScalar($0)!) }.joined()
            request.setValue(ascii, forHTTPHeaderField: "Dropbox-API-Arg")
        }
        return request
    }
    static func safeName(_ value: String) throws -> String {
        guard !value.isEmpty, value != ".", value != "..", !value.hasPrefix("."), value.utf8.count <= 240,
              !value.contains("/"), !value.contains("\\"), !value.contains(":"),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw DirectCloudError.unsafeName }
        return value.precomposedStringWithCanonicalMapping
    }
}
