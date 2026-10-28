#if DEBUG && VETA_JIT_DEVELOPMENT
import SwiftUI
import WebKit
import Network

// Explicit research launch. Assets, reports and web storage are isolated in
// caches. The only library file exposed is the selected, read-only game image.
struct WebJIT165ProbeView: View {
    @ObservedObject var library: Library
    @StateObject private var model = WebJIT165ProbeModel()
    var body: some View {
        VStack(spacing: 0) {
            Text(verbatim: model.status).font(.caption).padding(5)
            ScrollView(.horizontal) {
                HStack {
                    ForEach(["START", "A", "B", "UP", "DOWN", "LEFT", "RIGHT", "HOLD A", "STEER LEFT", "STEER RIGHT", "CENTER", "RELEASE", "PAUSE", "RESUME", "CHECK DISC", "AUDIO"], id: \.self) { name in
                        Button { model.press(name) } label: { Text(verbatim: "QA " + name).padding(6) }
                    }
                }.buttonStyle(.borderedProminent)
            }
            WebJIT165ProbeSurface(web: model.web)
        }.task { await model.start(library: library) }
            .onDisappear { model.stop() }
    }
}

private struct WebJIT165ProbeSurface: UIViewRepresentable {
    let web: WKWebView
    func makeUIView(context: Context) -> WKWebView { web }
    func updateUIView(_ view: WKWebView, context: Context) {}
}

@MainActor private final class WebJIT165ProbeModel: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    @Published var status = "QA Web JIT · preparando"
    let web: WKWebView
    private var server: WebJIT165ReadOnlyServer?
    private var records: [[String: Any]] = []
    private var reportURL: URL?
    private var origin: URL?
    private var console: GameConsole?
    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        web = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(self, name: "vetaWebJIT")
        web.navigationDelegate = self
        web.isInspectable = true
    }
    func start(library: Library) async {
        let env = ProcessInfo.processInfo.environment
        guard env["VETA_WEBJIT165_QA"] == "1", server == nil,
              let id = env["VETA_WEBJIT165_GAME"], let game = library.games.first(where: { $0.id == id }),
              [.dreamcast, .gamecube].contains(game.console),
              let run = env["VETA_WEBJIT165_RUN"], !run.isEmpty, run.count <= 60,
              run.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }) else {
            status = "QA Web JIT · requiere juego y caso explícitos"; return
        }
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        reportURL = cache.appendingPathComponent("Veta165WebJIT-" + run + ".json")
        do {
            console = game.console
            let storage = env["VETA_WEBJIT165_STORAGE"] ?? run
            guard !storage.isEmpty, storage.count <= 60, storage.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }) else { throw VetaError.message("Invalid QA storage name") }
            let state = cache.appendingPathComponent("Veta165WebJITState-" + storage).appendingPathComponent(game.id).appendingPathComponent("qa-state.bin")
            let server = try WebJIT165ReadOnlyServer(assets: cache.appendingPathComponent("Veta165WebJITAssets"), disc: library.romURL(game), qaState: state)
            self.server = server
            let url = try await server.start(); origin = url
            record(["stage": "host-start", "gameID": game.id, "nativeJIT": veta_jit_available(), "debugger": veta_jit_debugger_attached()])
            var request = URLRequest(url: url)
            request.allowsCellularAccess = false
            web.load(request)
        } catch { record(["error": error.localizedDescription]) }
    }
    func stop() {
        web.stopLoading(); server?.stop(); server = nil
        web.configuration.userContentController.removeScriptMessageHandler(forName: "vetaWebJIT")
        web.navigationDelegate = nil
    }
    func press(_ name: String) {
        if let expression = ["HOLD A":"hold(8,3000)", "STEER LEFT":"analog(0,-0.8,0,0)", "STEER RIGHT":"analog(0,0.8,0,0)", "CENTER":"analog(0,0,0,0)", "RELEASE":"releaseAll()", "PAUSE":"pause(true)", "RESUME":"pause(false)", "SAVE":"save()", "LOAD":"load()", "FLUSH":"flushPersistent()", "INVENTORY":"persistentInventory()", "CHECK DISC":"diagnoseDisc()", "GC FULL":"restartProfile('jit-full-raster')", "GC CACHED":"restartProfile('cached-nojit')", "GC INTERPRETER":"restartProfile('interpreter')", "AUDIO":"audio(true)", "CLOSE STORAGE":"closePersistent()"][name] {
            Task {
                do {
                    record(["stage":"qa-command", "command":name])
                    let result = try await web.callAsyncJavaScript("return await window.vetaWebJIT." + expression, arguments:[:], in:nil, contentWorld:.page)
                    record(["stage":"qa-command-returned", "command":name, "result":result ?? NSNull()])
                } catch { record(["stage":"qa-command-error", "command":name, "error":error.localizedDescription]) }
            }
            return
        }
        guard let index = ["START":3, "A":console == .dreamcast ? 0 : 8, "B":console == .dreamcast ? 8 : 0, "UP":4, "DOWN":5, "LEFT":6, "RIGHT":7][name] else { return }
        Task {
            do {
                _ = try await web.evaluateJavaScript("window.vetaWebJIT.press(\(index),1)")
                try await Task.sleep(nanoseconds: 350_000_000)
                _ = try await web.evaluateJavaScript("window.vetaWebJIT.press(\(index),0)")
            } catch { record(["error": error.localizedDescription]) }
        }
    }
    private func record(_ value: [String: Any]) {
        var value = value
        value["hostTime"] = ProcessInfo.processInfo.systemUptime
        value["thermal"] = ProcessInfo.processInfo.thermalState.rawValue
        guard JSONSerialization.isValidJSONObject(value), let bytes = try? JSONSerialization.data(withJSONObject: value), bytes.count <= 65536 else { return }
        records.append(value); if records.count > 600 { records.removeFirst() }
        if let path = reportURL, let data = try? JSONSerialization.data(withJSONObject: records, options: [.sortedKeys]) { try? data.write(to: path, options: .atomic) }
        if let error = value["error"] as? String { status = "QA Web JIT · " + error }
        else if let phase = value["stage"] as? String { status = "QA Web JIT · " + phase }
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.host == "127.0.0.1",
              message.frameInfo.securityOrigin.port == origin?.port,
              let value = message.body as? [String: Any] else { return }
        record(value)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        decisionHandler(url?.host == origin?.host && url?.port == origin?.port ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { record(["error": error.localizedDescription]) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { record(["error": "Web content process terminated"]) }
}

// A bounded local HTTP origin. Assets/disc are read-only; the one explicit QA
// state endpoint writes only isolated cache. No user paths or remote destinations.
private final class WebJIT165ReadOnlyServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "veta.webjit165.files")
    private let files: [String: URL]
    private let prefix = "/" + UUID().uuidString + "/"
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var host = ""
    private let qaState: URL?
    private var upload: ObjectIdentifier?
    init(assets: URL, disc: URL, qaState: URL? = nil) throws {
        self.qaState = qaState
        if let qaState { try FileManager.default.createDirectory(at: qaState.deletingLastPathComponent(), withIntermediateDirectories: true) }
        let root = assets.resolvingSymlinksInPath().standardizedFileURL
        var entries: [String: URL] = [:]
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { throw VetaError.message("Missing web JIT assets") }
        for case let item as URL in iterator {
            let resolved = item.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(root.path + "/") else { continue }
            let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) <= 256 * 1024 * 1024 else { continue }
            let relative = String(resolved.path.dropFirst(root.path.count + 1))
            guard !relative.split(separator: "/").contains(".."), entries.count < 1000 else { throw VetaError.message("Invalid web JIT assets") }
            entries[relative] = resolved
        }
        guard let index = entries["index.html"] else { throw VetaError.message("Missing web JIT index") }
        entries[""] = index; entries["game.chd"] = disc; entries["game.iso"] = disc
        files = entries
    }
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    let listener = try NWListener(using: parameters); self.listener = listener
                    var pending: CheckedContinuation<URL, Error>? = continuation
                    listener.stateUpdateHandler = { state in
                        guard let callback = pending else { return }
                        if case .ready = state, let port = listener.port {
                            pending = nil; self.host = "127.0.0.1:\(port.rawValue)"
                            callback.resume(returning: URL(string: "http://" + self.host + self.prefix)!)
                        } else if case .failed(let error) = state { pending = nil; callback.resume(throwing: error) }
                    }
                    listener.newConnectionHandler = { [weak self] in self?.accept($0) }
                    listener.start(queue: self.queue)
                    self.queue.asyncAfter(deadline: .now() + 10) {
                        if let callback = pending { pending = nil; callback.resume(throwing: VetaError.message("Local server timeout")); listener.cancel() }
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func stop() { queue.async { self.listener?.cancel(); self.listener = nil; self.connections.values.forEach { $0.cancel() }; self.connections.removeAll() } }
    private func finish(_ connection: NWConnection) { connection.cancel(); let key = ObjectIdentifier(connection); connections.removeValue(forKey: key); if upload == key { upload = nil } }
    private func accept(_ connection: NWConnection) {
        guard connections.count < 16 else { connection.cancel(); return }
        connections[ObjectIdentifier(connection)] = connection; connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 120) { [weak self, weak connection] in if let connection { self?.finish(connection) } }
        receive(connection, header: Data())
    }
    private func receive(_ connection: NWConnection, header: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] bytes, _, complete, error in
            guard let self else { connection.cancel(); return }
            let data = header + (bytes ?? Data())
            guard data.count <= 16384, error == nil else { self.finish(connection); return }
            if let end = data.range(of: Data("\r\n\r\n".utf8)), let text = String(data: data[..<end.lowerBound], encoding: .utf8) { self.respond(connection, header: text, body: Data(data[end.upperBound...])) }
            else if complete { self.finish(connection) }
            else { self.receive(connection, header: data) }
        }
    }
    private func respond(_ connection: NWConnection, header: String, body: Data) {
        do {
            let lines = header.components(separatedBy: "\r\n"), first = (lines.first ?? "").split(separator: " ")
            guard first.count == 3, ["GET", "HEAD", "PUT"].contains(first[0]), first[2] == "HTTP/1.1" else { throw VetaError.message("method") }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { throw VetaError.message("headers") }
                let key = line[..<colon].lowercased()
                guard headers[key] == nil else { throw VetaError.message("duplicate") }
                headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard headers["host"] == host, headers["transfer-encoding"] == nil else { throw VetaError.message("framing") }
            let target = String(first[1]).split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
            guard target.hasPrefix(prefix), let route = String(target.dropFirst(prefix.count)).removingPercentEncoding else { throw VetaError.message("route") }
            if first[0] == "PUT" {
                guard let qaFile = qaFile(route), upload == nil,
                      headers["origin"] == "http://" + host, headers["range"] == nil,
                      let rawLength = headers["content-length"], rawLength.utf8.allSatisfy({ (48...57).contains($0) }),
                      let length = Int(rawLength), length > 0, length <= (route == "qa-persistent.bin" ? 8 : 64) * 1024 * 1024, body.count <= length else { throw VetaError.message("upload") }
                upload = ObjectIdentifier(connection)
                receiveState(connection, buffer: StateBuffer(body), length: length, file: qaFile)
                return
            }
            guard (headers["content-length"] ?? "0") == "0", body.isEmpty,
                  let file = qaFile(route) ?? files[route] else { throw VetaError.message("route") }
            let handle = try FileHandle(forReadingFrom: file), size = try handle.seekToEnd()
            var offset: UInt64 = 0, count = size, status = "200 OK", extra = ""
            if let range = headers["range"] {
                let values = range.hasPrefix("bytes=") ? range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false) : []
                guard values.count == 2, let start = UInt64(values[0]), start < size else { try? handle.close(); throw VetaError.message("range") }
                let end = values[1].isEmpty ? size - 1 : UInt64(values[1]) ?? UInt64.max
                guard end >= start, end < size else { try? handle.close(); throw VetaError.message("range") }
                offset = start; count = end - start + 1; status = "206 Partial Content"; extra = "Content-Range: bytes \(start)-\(end)/\(size)\r\n"
            }
            try handle.seek(toOffset: offset)
            let type = ["html":"text/html; charset=utf-8", "js":"text/javascript", "mjs":"text/javascript", "wasm":"application/wasm", "json":"application/json", "css":"text/css", "png":"image/png"][file.pathExtension] ?? "application/octet-stream"
            let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(count)\r\n\(extra)Accept-Ranges: bytes\r\nCross-Origin-Opener-Policy: same-origin\r\nCross-Origin-Embedder-Policy: require-corp\r\nCross-Origin-Resource-Policy: same-origin\r\nContent-Security-Policy: default-src 'self' blob: data:; script-src 'self' 'unsafe-inline' 'unsafe-eval' blob:; connect-src 'self'; worker-src 'self' blob:; style-src 'self' 'unsafe-inline'; frame-src 'none'\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
                guard let self, error == nil, first[0] != "HEAD" else { try? handle.close(); self?.finish(connection); return }
                self.stream(connection, handle: handle, remaining: count)
            })
        } catch {
            connection.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { [weak self] _ in self?.finish(connection) })
        }
    }
    private func qaFile(_ route: String) -> URL? {
        guard let qaState else { return nil }
        if route == "qa-state.bin" { return qaState }
        if route == "qa-persistent.bin" { return qaState.deletingLastPathComponent().appendingPathComponent(route) }
        return nil
    }
    private final class StateBuffer: @unchecked Sendable {
        var bytes: Data
        init(_ bytes: Data) { self.bytes = bytes }
    }
    private func receiveState(_ connection: NWConnection, buffer: StateBuffer, length: Int, file: URL) {
        guard connections[ObjectIdentifier(connection)] != nil, buffer.bytes.count <= length else { finish(connection); return }
        if buffer.bytes.count == length {
            do {
                try buffer.bytes.write(to: file, options: .atomic)
                connection.send(content: Data("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nCache-Control: no-store\r\nCross-Origin-Resource-Policy: same-origin\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { [weak self] _ in self?.finish(connection) })
            } catch { finish(connection) }
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: min(65536, length - buffer.bytes.count)) { [weak self] bytes, _, complete, error in
            guard let self, error == nil, let bytes, !bytes.isEmpty else { self?.finish(connection); return }
            buffer.bytes.append(bytes)
            guard !complete || buffer.bytes.count == length else { self.finish(connection); return }
            self.receiveState(connection, buffer: buffer, length: length, file: file)
        }
    }
    private func stream(_ connection: NWConnection, handle: FileHandle, remaining: UInt64) {
        guard remaining > 0, connections[ObjectIdentifier(connection)] != nil else { try? handle.close(); finish(connection); return }
        do {
            let data = try handle.read(upToCount: Int(min(remaining, 65536))) ?? Data()
            guard !data.isEmpty else { try? handle.close(); finish(connection); return }
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self, error == nil else { try? handle.close(); self?.finish(connection); return }
                self.stream(connection, handle: handle, remaining: remaining - UInt64(data.count))
            })
        } catch { try? handle.close(); finish(connection) }
    }
}
#endif
