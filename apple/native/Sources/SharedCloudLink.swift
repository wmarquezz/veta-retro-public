import Foundation

/// A user-supplied share URL, kept in memory only. Never log its query or resource key.
struct SharedCloudLink: Identifiable, Equatable {
    let url: URL
    let provider: DirectCloudProvider
    let googleID: String?
    let resourceKey: String?
    var id: String { url.absoluteString }
    static func parse(_ text: String) throws -> Self {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 8192, let c = URLComponents(string: value), let url = c.url,
              c.scheme?.lowercased() == "https", c.user == nil, c.password == nil,
              c.port == nil || c.port == 443, let host = c.host?.lowercased(),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw SharedLinkError.invalidLink }
        let provider: DirectCloudProvider
        var googleID: String?, resourceKey: String?
        if host == "drive.google.com" {
            provider = .google
            let parts = url.path.split(separator: "/").map(String.init)
            if let index = parts.firstIndex(of: "folders"), index + 1 < parts.count { googleID = parts[index + 1] }
            else if parts.count >= 3, parts[0] == "file", parts[1] == "d" { googleID = parts[2] }
            else if ["/open", "/uc"].contains(url.path) {
                let ids = (c.queryItems ?? []).filter { $0.name == "id" }
                guard ids.count == 1 else { throw SharedLinkError.invalidLink }; googleID = ids[0].value
            }
            guard let googleID, validGoogleComponent(googleID) else { throw SharedLinkError.invalidLink }
            let keys = (c.queryItems ?? []).filter { $0.name.lowercased() == "resourcekey" }
            guard keys.count <= 1 else { throw SharedLinkError.invalidLink }
            resourceKey = keys.first?.value
            if let resourceKey, !validGoogleComponent(resourceKey) { throw SharedLinkError.invalidLink }
        } else if domain(host, "dropbox.com") {
            provider = .dropbox
            guard ["/s/", "/sh/", "/scl/fi/", "/scl/fo/"].contains(where: url.path.hasPrefix) else { throw SharedLinkError.invalidLink }
        } else if host == "1drv.ms" || host == "onedrive.live.com" || domain(host, "sharepoint.com") {
            provider = .onedrive
            guard url.path != "/" || c.query != nil else { throw SharedLinkError.invalidLink }
        } else { throw SharedLinkError.invalidLink }
        return .init(url: url, provider: provider, googleID: googleID, resourceKey: resourceKey)
    }
    static func validGoogleComponent(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }
    static func domain(_ host: String, _ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
    func allows(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        switch provider {
        case .google: return host == "drive.google.com"
        case .dropbox: return Self.domain(host, "dropbox.com") || Self.domain(host, "dropboxusercontent.com")
        case .onedrive:
            return host == "1drv.ms" || host == "onedrive.live.com" || Self.domain(host,"onedrive.com") ||
                Self.domain(host,"sharepoint.com") || Self.domain(host,"sharepointonline.com") ||
                host == "login.live.com" || host == "account.live.com" || host == "login.microsoftonline.com" ||
                Self.domain(host,"files.1drv.com") || Self.domain(host,"storage.live.com")
        }
    }
}

enum SharedLinkError: LocalizedError {
    case invalidLink, navigation, failed, unsupportedFile, tooLarge
    var errorDescription: String? {
        switch self {
        case .invalidLink: return L10n.text("Pega un enlace HTTPS de una carpeta o archivo compartido de Google Drive, OneDrive o Dropbox.")
        case .navigation: return L10n.text("Este enlace abre otro servicio. Puedes continuar en Safari o usar una cuenta con acceso desde Conectar mi nube.")
        case .failed: return L10n.text("No se pudo abrir o descargar el enlace. Revisa tu conexión y los permisos del propietario.")
        case .unsupportedFile: return L10n.text("La descarga no es un juego, ZIP o imagen compatible.")
        case .tooLarge: return L10n.text("La descarga supera el límite o no hay espacio suficiente en el iPhone.")
        }
    }
}
