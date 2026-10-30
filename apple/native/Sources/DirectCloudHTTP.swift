import Foundation

protocol DirectCloudHTTP {
    func data(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func download(_ request: URLRequest, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> (URL, HTTPURLResponse)
}

final class DirectCloudRedirectPolicy: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    let downloads: Bool
    let progress: @Sendable (Int64, Int64) -> Void
    init(downloads: Bool, progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) { self.downloads = downloads; self.progress = progress }
    static func redirected(_ request: URLRequest, previous: URL?, downloads: Bool) -> URLRequest? {
        guard downloads, let url = request.url, url.scheme == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), !host.isEmpty, host.contains("."),
              host != "localhost", !host.hasSuffix(".local"), !host.hasSuffix(".localhost"),
              host.range(of: "^[0-9.]+$", options: .regularExpression) == nil, !host.contains(":") else { return nil }
        var result = request
        // A pre-signed download destination must never receive the API bearer or cookies.
        if url.host != previous?.host {
            result.setValue(nil, forHTTPHeaderField: "Authorization")
            result.setValue(nil, forHTTPHeaderField: "Cookie")
            result.setValue(nil, forHTTPHeaderField: "Dropbox-API-Arg")
            result.setValue(nil, forHTTPHeaderField: "X-Goog-Drive-Resource-Keys")
        }
        return result
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Self.redirected(request, previous: response.url, downloads: downloads))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { progress(totalBytesWritten, totalBytesExpectedToWrite) }
}

final class DirectCloudURLSession: DirectCloudHTTP {
    private let allowDownloadRedirects: Bool
    init(allowDownloadRedirects: Bool = true) { self.allowDownloadRedirects = allowDownloadRedirects }
    private func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil; c.httpCookieStorage = nil; c.httpShouldSetCookies = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 60; c.timeoutIntervalForResource = 3600
        return URLSession(configuration: c)
    }
    func data(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let session = session(); defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request, delegate: DirectCloudRedirectPolicy(downloads: false))
        guard let response = response as? HTTPURLResponse, data.count <= 16 * 1024 * 1024 else { throw DirectCloudError.invalidResponse }
        return (data, response)
    }
    func download(_ request: URLRequest, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> (URL, HTTPURLResponse) {
        let session = session(); defer { session.invalidateAndCancel() }
        let (url, response) = try await session.download(for: request, delegate: DirectCloudRedirectPolicy(downloads: allowDownloadRedirects, progress: progress))
        guard let response = response as? HTTPURLResponse else { try? FileManager.default.removeItem(at: url); throw DirectCloudError.invalidResponse }
        return (url, response)
    }
}

protocol DirectCloudSource {
    func list(folder: String) async throws -> [DirectCloudEntry]
    func download(_ entry: DirectCloudEntry, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL
}

actor DirectCloudConnection: DirectCloudSource {
    let config: DirectCloudConfiguration
    private var token: DirectCloudToken
    private let http: DirectCloudHTTP
    private var resourceKeys: [String: String] = [:]
    private var refreshTask: Task<DirectCloudToken, Error>?
    private let save: (DirectCloudToken) throws -> Void
    init(config: DirectCloudConfiguration, token: DirectCloudToken, http: DirectCloudHTTP = DirectCloudURLSession(),
         save: ((DirectCloudToken) throws -> Void)? = nil) {
        self.config = config; self.token = token; self.http = http
        self.save = save ?? { try DirectCloudKeychain.write($0, key: config.credentialKey) }
    }
    private func access(force: Bool = false) async throws -> String {
        if !force && token.expiresAt > Date().addingTimeInterval(60) { return token.accessToken }
        if let task = refreshTask { return try await task.value.accessToken }
        guard let refresh = token.refreshToken else { throw DirectCloudError.reconnect }
        let http = http, config = config, save = save
        let task = Task<DirectCloudToken, Error> {
            var req = URLRequest(url: URL(string: config.provider.tokenEndpoint)!)
            req.httpMethod = "POST"; req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = DirectCloudAPI.form(["grant_type": "refresh_token", "client_id": config.clientID, "refresh_token": refresh])
            let (data, response) = try await http.data(req)
            guard response.statusCode == 200 else { throw DirectCloudError.reconnect }
            let token = try DirectCloudToken.decode(data, previousRefresh: refresh)
            try save(token)
            return token
        }
        refreshTask = task
        defer { refreshTask = nil }
        token = try await task.value
        return token.accessToken
    }
    private func authorized(_ request: URLRequest, force: Bool = false) async throws -> URLRequest {
        var req = request
        req.setValue("Bearer " + (try await access(force: force)), forHTTPHeaderField: "Authorization")
        return req
    }
    private func delay(_ response: HTTPURLResponse, attempt: Int) async throws {
        let seconds = min(30, max(1, Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? pow(2, Double(attempt))))
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
    private func check(_ response: HTTPURLResponse) throws {
        if response.statusCode == 401 { throw DirectCloudError.reconnect }
        if response.statusCode == 403 { throw DirectCloudError.permission }
        if response.statusCode == 412 { throw DirectCloudError.changed }
        guard response.statusCode == 200 else { throw DirectCloudError.service(response.statusCode) }
    }
    func sharedGoogleEntry(_ link: SharedCloudLink) async throws -> DirectCloudEntry {
        guard config.provider == .google, link.provider == .google, var id = link.googleID else { throw SharedLinkError.invalidLink }
        if let key = link.resourceKey { resourceKeys[id] = key }
        var visited = Set<String>()
        for _ in 0..<4 {
            guard visited.insert(id).inserted else { throw DirectCloudError.invalidResponse }
            var c = URLComponents(string: "https://www.googleapis.com/drive/v3/files/" + DirectCloudAPI.component(id))!
            c.queryItems = [.init(name:"supportsAllDrives",value:"true"), .init(name:"fields",value:"id,name,mimeType,size,version,md5Checksum,resourceKey,capabilities/canDownload,shortcutDetails")]
            let request = googleKeys(URLRequest(url:c.url!), ids:[id])
            var (data, response) = try await http.data(authorized(request))
            if response.statusCode == 401 { (data,response) = try await http.data(authorized(request,force:true)) }
            try check(response)
            guard let object = try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw DirectCloudError.invalidResponse }
            if object["mimeType"] as? String == "application/vnd.google-apps.shortcut" {
                guard let target = object["shortcutDetails"] as? [String:Any], let next = target["targetId"] as? String,
                      SharedCloudLink.validGoogleComponent(next) else { throw DirectCloudError.invalidResponse }
                if let key = target["targetResourceKey"] as? String, SharedCloudLink.validGoogleComponent(key) { resourceKeys[next] = key }
                id = next; continue
            }
            let wrapped = try JSONSerialization.data(withJSONObject:["files":[object]])
            guard let entry = try DirectCloudAPI.decodePage(wrapped,provider:.google).entries.first else { throw DirectCloudError.noGames }
            rememberKeys([entry]); return entry
        }
        throw DirectCloudError.invalidResponse
    }
    private func rememberKeys(_ entries: [DirectCloudEntry]) {
        for entry in entries {
            if let key = entry.resourceKey, SharedCloudLink.validGoogleComponent(entry.id), SharedCloudLink.validGoogleComponent(key) { resourceKeys[entry.id] = key }
        }
    }
    private func googleKeys(_ request: URLRequest, ids: [String]) -> URLRequest {
        var request = request
        guard config.provider == .google else { return request }
        let values = ids.compactMap { id in resourceKeys[id].map { id + "/" + $0 } }
        if !values.isEmpty { request.setValue(values.joined(separator:","),forHTTPHeaderField:"X-Goog-Drive-Resource-Keys") }
        return request
    }
    func list(folder: String) async throws -> [DirectCloudEntry] {
        var entries: [DirectCloudEntry] = [], cursor: String?, cursors = Set<String>(), ids = Set<String>()
        repeat {
            try Task.checkCancellation()
            let request = googleKeys(try DirectCloudAPI.listRequest(config.provider, folder: folder, page: cursor), ids:[folder])
            var output: Data?
            for attempt in 0..<4 {
                let (data, response) = try await http.data(authorized(request))
                if response.statusCode == 401 && attempt == 0 {
                    let (retryData, retryResponse) = try await http.data(authorized(request, force: true))
                    try check(retryResponse); output = retryData; break
                }
                if (response.statusCode == 429 || (500...599).contains(response.statusCode)) && attempt < 3 { try await delay(response, attempt: attempt); continue }
                try check(response); output = data; break
            }
            guard let output else { throw DirectCloudError.invalidResponse }
            let page = try DirectCloudAPI.decodePage(output, provider: config.provider)
            rememberKeys(page.entries)
            for item in page.entries where ids.insert(item.id).inserted { entries.append(item) }
            guard entries.count <= 10_000, cursors.count < 100 else { throw DirectCloudError.limit }
            cursor = page.next
            if let cursor, !cursors.insert(cursor).inserted { throw DirectCloudError.invalidResponse }
        } while cursor != nil
        return entries.sorted { a, b in a.folder != b.folder ? a.folder : a.name.localizedStandardCompare(b.name) == .orderedAscending }
    }
    func download(_ entry: DirectCloudEntry, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        let request = googleKeys(try DirectCloudAPI.downloadRequest(config.provider, entry: entry), ids:[entry.id])
        var refreshed = false
        for attempt in 0..<4 {
            try Task.checkCancellation()
            let (file, response) = try await http.download(authorized(request), progress: progress)
            if response.statusCode == 200 { return file }
            try? FileManager.default.removeItem(at: file)
            if response.statusCode == 401 && !refreshed { _ = try await access(force: true); refreshed = true; continue }
            if (response.statusCode == 429 || (500...599).contains(response.statusCode)) && attempt < 3 { try await delay(response, attempt: attempt); continue }
            try check(response)
        }
        throw DirectCloudError.invalidResponse
    }
}
