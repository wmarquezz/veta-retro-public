import Foundation
import Network
import CryptoKit
import Security

/// h6 adds terminal VMU persistence around the immutable accepted h4 engine.
/// BIOS and games remain private files; only the validated card endpoint writes.
enum DreamcastWebAssets {
    static let manifest: [String: (bytes: Int, sha256: String)] = [
        "flycast_libretro.js": (312813, "543017851ef8d5f56176fc74bbdcb4ae04e05d195334394967dc512d5c9a96f1"),
        "flycast_libretro.wasm": (10398725, "db2b87d8d2742087a56c4eeed317da14e3549ee037e36de3d77c1e6e5291bead"),
        "harness.js": (24676, "0112a354f3522aed25de30746e2afbeae7f112c1cc542dc1811dde9fbcbce24b"),
        "persistence.js": (3007, "c7a1acde5e6250575146d8c75b7dc0b93c8150d932263e9c78f94ed0f5282a08"),
        "index.html": (1107, "cf5d7d8971c2c25e79d8f03a3054662aff69c885d4ec20b610fc1f0110040980"),
        "LICENSE-Flycast-GPLv2.txt": (17984, "edaef632cbb643e4e7a221717a6c441a4c1a7c918e6e4d56debc3d8739b233f6")
    ]
    static func directory(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "flycast_libretro", withExtension: "wasm", subdirectory: "DreamcastWasm")?.deletingLastPathComponent()
    }
    /// Canonicalize only Apple's /var alias. Every other symbolic component
    /// is rejected, including dangling links and ancestors of an existing file.
    static func validatePath(_ url: URL) throws {
        guard url.isFileURL else { throw failure("No se pudo acceder de forma segura a los archivos de Dreamcast.") }
        func canonical(_ value: URL) -> URL {
            let path = value.standardizedFileURL.path
            return URL(fileURLWithPath: path == "/var" || path.hasPrefix("/var/") ? "/private" + path : path)
        }
        let path = canonical(url)
        guard canonical(path.resolvingSymlinksInPath()).path == path.path else {
            throw failure("No se pudo acceder de forma segura a los archivos de Dreamcast.")
        }
        var ancestor = path
        while true {
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: ancestor.path)) == nil else {
                throw failure("No se pudo acceder de forma segura a los archivos de Dreamcast.")
            }
            if ancestor.path == "/" { break }
            ancestor.deleteLastPathComponent()
        }
    }
    static func validate(at directory: URL) throws {
        try validatePath(directory)
        // Check every resource path before reading any resource contents.
        for name in manifest.keys { try validatePath(directory.appendingPathComponent(name)) }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard Set(names) == Set(manifest.keys) else { throw failure("El paquete Dreamcast contiene archivos inesperados.") }
        for (name, entry) in manifest {
            let file = directory.appendingPathComponent(name)
            let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true, info.fileSize == entry.bytes else {
                throw failure("El paquete Dreamcast está incompleto.")
            }
            let hash = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
            guard hash == entry.sha256 else { throw failure("El motor Dreamcast no coincide con la versión comprobada.") }
        }
    }
    static func failure(_ message: String) -> Error {
        NSError(domain: "VetaDreamcastWeb", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.text(message)])
    }
}

/// Mutable state and file handles are confined to queue. Fixed routes, a random
/// origin path, Host/Origin checks and a loopback-only listener bound the scope.
final class DreamcastWebServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "veta.dreamcast.web-files", qos: .userInitiated)
    private let assets: URL, disc: URL, system: URL
    private let html: Data
    private let persistentStore: DreamcastWebVMUStore?
    private let prefix: String
    private var listener: NWListener?
    private var pendingStart: CheckedContinuation<URL, Error>?
    private var baseURL: URL?
    private var host = "", origin = ""
    private var stopped = false
    private var files: [String: File] = [:]
    private var requests: [ObjectIdentifier: Request] = [:]

    private struct File { let handle: FileHandle; let size: UInt64; let type: String }
    private final class Request {
        let connection: NWConnection
        var header = Data(), method = "", route = "", headers: [String: String] = [:]
        var body = Data(), expectedBody = 0, parsed = false
        var responding = false, closed = false
        init(_ connection: NWConnection) { self.connection = connection }
    }
    private struct HTTPError: Error { let code: Int; let message: String }

    init(assets: URL, disc: URL, system: URL, html: Data = Data(DreamcastWebClient.page.utf8), persistentStore: DreamcastWebVMUStore? = nil) {
        self.assets = assets; self.disc = disc; self.system = system; self.html = html; self.persistentStore = persistentStore
        var nonce = [UInt8](repeating: 0, count: 16)
        let secure = SecRandomCopyBytes(kSecRandomDefault, nonce.count, &nonce) == errSecSuccess
        prefix = secure ? "/" + nonce.map { String(format: "%02x", $0) }.joined() + "/" : ""
    }
    func start() async throws -> URL {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !self.stopped, self.pendingStart == nil, self.listener == nil else {
                        continuation.resume(throwing: DreamcastWebAssets.failure("La sesión local ya está iniciada o cerrada.")); return
                    }
                    self.pendingStart = continuation
                    do {
                        try self.prepare()
                        let parameters = NWParameters.tcp
                        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                        let listener = try NWListener(using: parameters, on: .any)
                        self.listener = listener
                        listener.stateUpdateHandler = { [weak self] state in
                            guard let self else { return }
                            switch state {
                            case .ready:
                                guard !self.stopped, let port = self.listener?.port else { return }
                                self.host = "127.0.0.1:\(port.rawValue)"; self.origin = "http://" + self.host
                                let url = URL(string: self.origin + self.prefix)!
                                self.baseURL = url; self.finishStart(.success(url))
                            case .failed(let error): self.finishStart(.failure(error)); self.close()
                            case .cancelled: self.finishStart(.failure(CancellationError()))
                            default: break
                            }
                        }
                        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                        listener.start(queue: self.queue)
                        self.queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                            guard let self, self.pendingStart != nil else { return }
                            self.finishStart(.failure(DreamcastWebAssets.failure("No se pudo abrir la sesión local."))); self.close()
                        }
                    } catch { self.finishStart(.failure(error)); self.close() }
                }
            }
        }, onCancel: { self.stop() })
    }
    func stop() { queue.async { self.close() } }
    private func finishStart(_ result: Result<URL, Error>) {
        let callback = pendingStart; pendingStart = nil; callback?.resume(with: result)
    }
    private func close() {
        guard !stopped else { return }; stopped = true
        listener?.cancel(); listener = nil; baseURL = nil
        finishStart(.failure(CancellationError()))
        for request in Array(requests.values) { finish(request) }
        for file in files.values { try? file.handle.close() }; files.removeAll()
    }
    private func prepare() throws {
        guard !prefix.isEmpty else { throw DreamcastWebAssets.failure("No se pudo crear una sesión privada.") }
        // Validate all private input paths before opening resources or BIOS.
        // This must run even when Store.read() returns an existing web package.
        try DreamcastWebAssets.validatePath(disc)
        for name in ["dc_boot.bin", "dc_flash.bin"] {
            try DreamcastWebAssets.validatePath(system.appendingPathComponent("dc").appendingPathComponent(name))
        }
        try DreamcastWebAssets.validate(at: assets)
        guard disc.pathExtension.lowercased() == "chd" else {
            throw DreamcastWebAssets.failure("Este motor de Dreamcast admite juegos CHD.")
        }
        for name in DreamcastWebAssets.manifest.keys {
            try open(name, at: assets.appendingPathComponent(name), maximum: 16 * 1024 * 1024,
                     type: name.hasSuffix("wasm") ? "application/wasm" : name.hasSuffix("js") ? "text/javascript; charset=utf-8" : "text/plain; charset=utf-8")
        }
        try open("game.chd", at: disc, maximum: 512 * 1024 * 1024)
        // h4 was accepted with user-owned BIOS. Do not silently substitute its
        // unvalidated HLE fallback or ship the BIOS inside the application.
        for (name, size) in [("dc_boot.bin", 2097152), ("dc_flash.bin", 131072)] {
            let path = system.appendingPathComponent("dc", isDirectory: true).appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: path.path) else {
                throw DreamcastWebAssets.failure(L10n.format("Falta la BIOS %@ en System/dc.", name))
            }
            try open(name, at: path, maximum: size)
            guard files[name]?.size == UInt64(size) else { throw DreamcastWebAssets.failure("Falta una BIOS de Dreamcast válida en System/dc.") }
        }
        _ = try persistentStore?.read()
    }
    private func open(_ route: String, at url: URL, maximum: Int, type: String = "application/octet-stream") throws {
        try DreamcastWebAssets.validatePath(url)
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, let size = info.fileSize, size > 0, size <= maximum else {
            throw DreamcastWebAssets.failure("Un archivo de Dreamcast no está disponible o supera el tamaño permitido.")
        }
        files[route] = File(handle: try FileHandle(forReadingFrom: url), size: UInt64(size), type: type)
    }
    private func accept(_ connection: NWConnection) {
        guard !stopped, requests.count < 16 else { connection.cancel(); return }
        let request = Request(connection); requests[ObjectIdentifier(request)] = request
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 120) { [weak self, weak request] in
            guard let self, let request, !request.closed else { return }; self.finish(request)
        }
        receive(request)
    }
    private func finish(_ request: Request) {
        guard !request.closed else { return }; request.closed = true
        request.connection.cancel(); requests.removeValue(forKey: ObjectIdentifier(request))
    }
    private func receive(_ request: Request) {
        request.connection.receive(minimumIncompleteLength: 1, maximumLength: 16385) { [weak self, weak request] data, _, complete, error in
            guard let self, let request, !request.closed else { return }
            do {
                if request.parsed {
                    if let data { request.body.append(data) }
                } else {
                    if let data { request.header.append(data) }
                    if let end = request.header.range(of: Data("\r\n\r\n".utf8)) {
                        guard end.lowerBound <= 16384 else { throw HTTPError(code: 431, message: "Headers too large") }
                        try self.parse(request.header.subdata(in: 0..<end.lowerBound), request: request)
                        request.body = request.header.subdata(in: end.upperBound..<request.header.count)
                        request.header.removeAll(); request.parsed = true
                    } else if request.header.count > 16384 { throw HTTPError(code: 431, message: "Headers too large") }
                }
                if request.parsed {
                    guard request.body.count <= request.expectedBody else { throw HTTPError(code: 400, message: "Unexpected body") }
                    if request.body.count == request.expectedBody { try self.respond(request); return }
                }
                if complete || error != nil { throw HTTPError(code: 400, message: "Incomplete headers") }
                self.receive(request)
            } catch let failure as HTTPError { self.send(request, code: failure.code, data: Data(failure.message.utf8)) }
            catch { self.send(request, code: 500, data: Data("Local read failed".utf8)) }
        }
    }
    private func parse(_ data: Data, request: Request) throws {
        guard let text = String(data: data, encoding: .utf8) else { throw HTTPError(code: 400, message: "Invalid headers") }
        let lines = text.components(separatedBy: "\r\n"), first = (lines.first ?? "").split(separator: " ")
        guard first.count == 3, first[2] == "HTTP/1.1" else { throw HTTPError(code: 400, message: "Invalid request") }
        request.method = String(first[0])
        guard ["GET", "HEAD", "PUT"].contains(request.method) else { throw HTTPError(code: 405, message: "Unsupported method") }
        let target = String(first[1])
        guard target.hasPrefix(prefix), !target.contains("%"), !target.contains("?"), !target.contains("#") else { throw HTTPError(code: 404, message: "Not found") }
        request.route = String(target.dropFirst(prefix.count))
        guard request.route.isEmpty || files[request.route] != nil || request.route == "adapter.js" || (request.route == "persistent.bin" && persistentStore != nil) else { throw HTTPError(code: 404, message: "Not found") }
        for line in lines.dropFirst() {
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { throw HTTPError(code: 400, message: "Invalid header") }
            let key = String(line[..<colon]).lowercased(), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, request.headers[key] == nil else { throw HTTPError(code: 400, message: "Duplicate header") }
            request.headers[key] = value
        }
        guard request.headers["host"] == host, request.headers["transfer-encoding"] == nil else { throw HTTPError(code: 400, message: "Invalid framing") }
        if request.method == "PUT" {
            guard request.route == "persistent.bin", persistentStore != nil else { throw HTTPError(code: 405, message: "Read only") }
            guard request.headers["origin"] == origin else { throw HTTPError(code: 403, message: "Origin required") }
            guard request.headers["content-type"] == "application/octet-stream",
                  let length = request.headers["content-length"], !length.isEmpty,
                  length.utf8.allSatisfy({ (48...57).contains($0) }), let size = Int(length),
                  size > 0, size <= DreamcastWebVMUStore.maximumBytes else { throw HTTPError(code: 413, message: "Invalid persistent body length") }
            request.expectedBody = size
        } else {
            guard request.headers["content-length"] == nil || request.headers["content-length"] == "0" else { throw HTTPError(code: 400, message: "Unexpected body") }
        }
        if let value = request.headers["origin"], value != origin { throw HTTPError(code: 403, message: "Foreign origin") }
        if let value = request.headers["sec-fetch-site"], !["same-origin", "none"].contains(value) { throw HTTPError(code: 403, message: "Foreign site") }
    }
    /// One RFC byte range. Suffix ranges and end-clamping match browser clients.
    static func byteRange(_ header: String?, size: UInt64) throws -> (start: UInt64, length: UInt64, partial: Bool) {
        guard let header else { return (0, size, false) }
        guard size > 0, header.hasPrefix("bytes=") else { throw HTTPError(code: 416, message: "Invalid range") }
        let pair = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        func number(_ value: Substring) -> UInt64? { !value.isEmpty && value.utf8.allSatisfy({ (48...57).contains($0) }) ? UInt64(value) : nil }
        guard pair.count == 2 else { throw HTTPError(code: 416, message: "Invalid range") }
        if pair[0].isEmpty, let suffix = number(pair[1]), suffix > 0 {
            let length = min(suffix, size); return (size - length, length, true)
        }
        guard let start = number(pair[0]), start < size else { throw HTTPError(code: 416, message: "Invalid range") }
        let end: UInt64
        if pair[1].isEmpty { end = size - 1 }
        else if let requested = number(pair[1]), requested >= start { end = min(requested, size - 1) }
        else { throw HTTPError(code: 416, message: "Invalid range") }
        return (start, end - start + 1, true)
    }
    private func respond(_ request: Request) throws {
        if request.route == "persistent.bin", let persistentStore {
            if request.method == "PUT" {
                do { try persistentStore.commit(request.body) }
                catch DreamcastWebVMUStore.Failure.changedSession { throw HTTPError(code: 409, message: "Persistent session conflict") }
                catch DreamcastWebVMUStore.Failure.invalidBundle { throw HTTPError(code: 422, message: "Invalid persistent bundle") }
                send(request, code: 204, data: Data()); return
            }
            guard let data = try persistentStore.read() else { send(request, code: 404, data: Data()); return }
            send(request, data: data, type: "application/octet-stream"); return
        }
        if request.route.isEmpty { send(request, data: html, type: "text/html; charset=utf-8"); return }
        if request.route == "adapter.js" { send(request, data: Data(DreamcastWebClient.adapter.utf8), type: "text/javascript; charset=utf-8"); return }
        guard let file = files[request.route] else { throw HTTPError(code: 404, message: "Not found") }
        let range: (start: UInt64, length: UInt64, partial: Bool)
        do { range = try Self.byteRange(request.headers["range"], size: file.size) }
        catch { send(request, code: 416, data: Data(), extra: "Content-Range: bytes */\(file.size)\r\n"); return }
        let extra = "Accept-Ranges: bytes\r\n" + (range.partial ? "Content-Range: bytes \(range.start)-\(range.start + range.length - 1)/\(file.size)\r\n" : "")
        request.responding = true
        let header = headers(code: range.partial ? 206 : 200, length: range.length, type: file.type, extra: extra)
        request.connection.send(content: header, completion: .contentProcessed { [weak self, weak request] error in
            guard let self, let request, !request.closed else { return }
            if error != nil || request.method == "HEAD" { self.finish(request); return }
            self.stream(file, request: request, offset: range.start, remaining: range.length)
        })
    }
    private func stream(_ file: File, request: Request, offset: UInt64, remaining: UInt64) {
        guard !request.closed, !stopped else { return }
        guard remaining > 0 else { finish(request); return }
        do {
            let count = Int(min(remaining, 65536))
            try file.handle.seek(toOffset: offset)
            let data = try file.handle.read(upToCount: count) ?? Data()
            guard data.count == count else { finish(request); return }
            request.connection.send(content: data, completion: .contentProcessed { [weak self, weak request] error in
                guard let self, let request else { return }
                if error != nil { self.finish(request); return }
                self.stream(file, request: request, offset: offset + UInt64(count), remaining: remaining - UInt64(count))
            })
        } catch { finish(request) }
    }
    private func headers(code: Int, length: UInt64, type: String, extra: String = "") -> Data {
        let reasons = [200: "OK", 204: "No Content", 206: "Partial Content", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 409: "Conflict", 413: "Payload Too Large", 416: "Range Not Satisfiable", 422: "Unprocessable Content", 431: "Request Header Fields Too Large", 500: "Internal Server Error"]
        // h4 creates its AudioWorklet module as a local Blob. Worklets use
        // script-src, not just worker-src; omitting blob: silently loses audio.
        let policy = "default-src 'none'; script-src 'self' blob: 'unsafe-eval'; style-src 'unsafe-inline'; connect-src 'self'; worker-src 'self' blob:; img-src 'self' data: blob:; media-src 'self' blob:; frame-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
        return Data("HTTP/1.1 \(code) \(reasons[code] ?? "Error")\r\nContent-Type: \(type)\r\nContent-Length: \(length)\r\nConnection: close\r\nCache-Control: no-store\r\nCross-Origin-Opener-Policy: same-origin\r\nCross-Origin-Embedder-Policy: require-corp\r\nCross-Origin-Resource-Policy: same-origin\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: \(policy)\r\n\(extra)\r\n".utf8)
    }
    private func send(_ request: Request, code: Int = 200, data: Data, type: String = "text/plain; charset=utf-8", extra: String = "") {
        guard !request.closed, !request.responding else { return }; request.responding = true
        request.connection.send(content: headers(code: code, length: UInt64(data.count), type: type, extra: extra) + (request.method == "HEAD" ? Data() : data), completion: .contentProcessed { [weak self, weak request] _ in
            if let request { self?.finish(request) }
        })
    }
}

enum DreamcastWebClient {
    // Required h4 elements remain present; the game uses the normal native deck.
    // Keep the real HTML click available as a fallback to the native start
    // button. This surface stays local until h4 confirms main-started.
    static let page = #"""
    <!doctype html><html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>VETA Dreamcast</title>
    <style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#000;color:#fff;font:17px system-ui}#screen{width:100%;height:100%;display:grid;place-items:center}canvas{max-width:100%;max-height:100%;width:auto;height:auto;aspect-ratio:4/3}#launch{position:fixed;inset:0;display:flex;flex-direction:column;justify-content:center;align-items:center;gap:16px;padding:16px;background:#101b24f5;text-align:center}#launch[hidden]{display:none}#boot{min-width:180px;min-height:56px;padding:12px 24px;background:#a0efcf;color:#122c29;border:0;border-radius:12px;font:700 22px system-ui}#boot:disabled{opacity:.5}#hint{max-width:32em;margin:0;font-size:14px;color:#d2dce2}.qa{display:none}</style></head><body>
    <div id="screen"><canvas id="canvas" width="640" height="480" tabindex="0"></canvas></div>
    <div id="launch"><button id="boot" disabled>Jugar</button><p id="hint">Preparando Dreamcast…</p></div>
    <div class="qa" aria-hidden="true"><div id="status"></div><button id="start">START</button><button id="a">A</button><button id="pause">Pausa</button></div>
    <script src="adapter.js"></script><script src="flycast_libretro.js"></script><script src="persistence.js"></script><script src="harness.js"></script></body></html>
    """#
    static let adapter = #"""
    (()=>{'use strict';
      let blocked=true;
      const previous=Array.from({length:4},()=>({mask:0,x:0,y:0}));
      const ids=[0,1,3,4,5,6,7,8,9,12,13];
      function release(){
        const core=window.vetaWebJIT;
        for(let p=0;p<4;p++){
          for(const id of ids)core?.press(id,0,p);
          core?.stick?.(0,0,p);
          previous[p]={mask:0,x:0,y:0};
        }
      }
      function input(ports){
        if(blocked)return;
        if(!Array.isArray(ports)||ports.length!==4)throw Error('Expected four controller ports');
        const next=ports.map(v=>{
          if(!Array.isArray(v)||v.length!==3||!v.every(Number.isInteger)||v[0]<0||v[0]>65535||Math.abs(v[1])>32767||Math.abs(v[2])>32767)throw Error('Invalid controller input');
          return {mask:v[0],x:v[1],y:v[2]};
        });
        for(let p=0;p<4;p++){
          const old=previous[p],v=next[p];
          for(const id of ids)if((old.mask^v.mask)&(1<<id))window.vetaWebJIT.press(id,(v.mask>>id)&1,p);
          if(old.x!==v.x||old.y!==v.y)window.vetaWebJIT.stick(v.x/32767,v.y/32767,p);
          previous[p]=v;
        }
      }
      async function pause(value){
        blocked=true;release();
        const result=await window.vetaWebJIT.setPaused(!!value);
        if(!result||result.ok===false||result.paused!==!!value)throw Error(result?.error||'Pause state not confirmed');
        blocked=!!value;return result;
      }
      function started(){blocked=false;document.getElementById('launch').hidden=true;}
      function ready(){document.getElementById('hint').textContent='Las partidas del juego se conservan al salir desde el menú.';}
      function interrupt(){blocked=true;release();}
      window.vetaDreamcast=Object.freeze({input,pause,release,started,ready,interrupt});
      document.addEventListener('visibilitychange',()=>{if(document.hidden){interrupt();window.webkit?.messageHandlers?.vetaWebJIT?.postMessage({stage:'adapter-interrupted'});}});
    })();
    """#
}
