#if DEBUG && VETA_JIT_DEVELOPMENT
import Foundation
import CryptoKit

// Deliberately separate from normal library/import policy. Game/state writes
// use this run's cache; normal control/TV preferences remain shared. The ISO
// is opened read-only and hard-linked, never
// copied over an existing game or changed in place.
enum PS2Retail165Contract {
    struct Fixture: Codable {
        let version: Int
        let id: String
        let title: String
        let bytes: UInt64
        let serial: String
        let contentName: String?
        var discName: String { contentName ?? "game.iso" }
        func validate() throws {
            guard version == 1, id.count == 64,
                  id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  !title.isEmpty, title.utf8.count <= 160, !title.contains("\n"),
                  bytes > 32768, bytes <= 8 * 1024 * 1024 * 1024,
                  ["game.iso", "game.cso"].contains(discName),
                  serial.range(of: #"^[A-Z]{4}_[0-9]{3}\.[0-9]{2}$"#, options: .regularExpression) != nil
            else { throw Failure.invalidFixture }
        }
    }
    enum Failure: Error { case invalidRun, invalidFixture, unsafePath, wrongSize, wrongHash, wrongDisc, existingMismatch }
    struct Diagnostic: Error, CustomStringConvertible {
        let stage: String
        let relativePath: String
        let reason: String
        var description: String { "\(stage) [\(relativePath)]: \(reason)" }
    }
    static func checked<T>(_ stage: String, _ relativePath: String, _ body: () throws -> T) throws -> T {
        do { return try body() }
        catch let error as Diagnostic { throw error }
        catch {
            // Do not expose container UUIDs or absolute source paths in the UI/log.
            let reason = (error as? Failure).map { String(describing: $0) }
                ?? "\((error as NSError).domain):\((error as NSError).code)"
            throw Diagnostic(stage: stage, relativePath: relativePath, reason: reason)
        }
    }
    static func systemURL(_ url: URL) -> URL {
        let path = url.standardizedFileURL.path
        // Darwin may spell its trusted system prefix either way, even between
        // two Foundation calls. Do not resolve arbitrary links below this prefix.
        let canonical = path == "/var" || path.hasPrefix("/var/") ? "/private" + path : path
        // Do not standardize again: Foundation can shorten /private/var back
        // to /var only after a previously missing directory has been created.
        return URL(fileURLWithPath: canonical)
    }
    static func run(_ value: String?) throws -> String {
        guard let value, !value.isEmpty, value.count <= 32,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 })
        else { throw Failure.invalidRun }
        return value
    }
    static func basename(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && value.utf8.count <= 240 &&
        !value.contains("/") && !value.contains("\\") && !value.contains("\0")
    }
    static func sessionRoot(caches: URL, run: String) throws -> URL {
        caches.appendingPathComponent("VetaPS2Retail165Sessions").appendingPathComponent(try self.run(run))
    }
    static func stagingRoot(caches: URL, run: String) throws -> URL {
        caches.appendingPathComponent("VetaPS2Retail165Staging").appendingPathComponent(try self.run(run))
    }
    static func safe(_ url: URL, inside root: URL) throws {
        let base = systemURL(root)
        let path = systemURL(url)
        guard path.path.hasPrefix(base.path + "/"), systemURL(path.resolvingSymlinksInPath()).path == path.path,
              systemURL(base.resolvingSymlinksInPath()).path == base.path else { throw Failure.unsafePath }
        // Foundation may leave a symlinked parent unresolved when the final
        // component does not yet exist. Check each path component explicitly.
        var ancestor = path
        while ancestor.path.count >= base.path.count {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: ancestor.path)) != nil { throw Failure.unsafePath }
            if ancestor.path == base.path { break }
            ancestor.deleteLastPathComponent()
        }
    }
    static func regular(_ url: URL, inside root: URL) throws -> UInt64 {
        try safe(url, inside: root)
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, let bytes = info.fileSize, bytes > 0
        else { throw Failure.unsafePath }
        return UInt64(bytes)
    }
    static func readFixture(_ url: URL, inside root: URL) throws -> Fixture {
        guard try regular(url, inside: root) <= 4096 else { throw Failure.invalidFixture }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        try fixture.validate(); return fixture
    }
    static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 4 * 1024 * 1024), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func validateDisc(_ url: URL, serial: String) throws {
        let f = try PS2DiscReader(url: url)
        func read(_ offset: UInt64, _ size: Int) throws -> Data {
            try f.read(offset: offset, length: size)
        }
        func le32(_ d: Data, _ offset: Int) throws -> UInt64 {
            guard offset >= 0, offset + 4 <= d.count else { throw Failure.wrongDisc }
            return (0..<4).reduce(0) { $0 | UInt64(d[offset+$1]) << ($1*8) }
        }
        let pvd = try read(16*2048, 2048)
        guard pvd[0] == 1, pvd.subdata(in: 1..<6) == Data("CD001".utf8) else { throw Failure.wrongDisc }
        let extent = try le32(pvd, 158), size = try le32(pvd, 166)
        guard size > 0, size <= 1024*1024 else { throw Failure.wrongDisc }
        let directory = try read(extent*2048, Int(size)); var offset = 0, system: Data?, executable = false
        while offset < directory.count {
            let length = Int(directory[offset])
            if length == 0 { offset = (offset/2048+1)*2048; continue }
            guard length >= 34, offset+length <= directory.count else { throw Failure.wrongDisc }
            let entry = directory.subdata(in: offset..<offset+length), count = Int(entry[32])
            guard 33+count <= length else { throw Failure.wrongDisc }
            let name = String(decoding: entry.subdata(in: 33..<33+count), as: UTF8.self)
            if name == serial+";1" { executable = true }
            if name == "SYSTEM.CNF;1" {
                let count = try le32(entry, 10); guard count > 0, count <= 4096 else { throw Failure.wrongDisc }
                system = try read(try le32(entry, 2)*2048, Int(count))
            }
            offset += length
        }
        guard executable, let system,
              String(decoding: system, as: UTF8.self).split(whereSeparator: \.isNewline).contains(where: {
                  $0.replacingOccurrences(of: " ", with: "").uppercased() == "BOOT2=CDROM0:\\"+serial+";1"
              }) else { throw Failure.wrongDisc }
    }
    static func linkVerified(_ source: URL, sourceRoot: URL, destination: URL, session: URL, fixture: Fixture) throws {
        try fixture.validate()
        try checked("destination-path", "Sessions/<run>/<game>/game.iso") { try safe(destination, inside: session) }
        try checked("source-path-size", "source/game.iso") {
            guard try regular(source, inside: sourceRoot) == fixture.bytes else { throw Failure.wrongSize }
        }
        try checked("source-hash", "source/game.iso") {
            guard try hash(source) == fixture.id else { throw Failure.wrongHash }
        }
        try checked("disc-header", "source/game.iso") { try validateDisc(source, serial: fixture.serial) }
        let fm = FileManager.default
        try checked("destination-link", "Sessions/<run>/<game>/game.iso") {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try safe(destination, inside: session)
            if fm.fileExists(atPath: destination.path) {
                guard try regular(destination, inside: session) == fixture.bytes, try hash(destination) == fixture.id else { throw Failure.existingMismatch }
            } else {
                // Same sandbox volume; no hidden multi-GB copy or source mutation.
                try fm.linkItem(at: source, to: destination)
            }
        }
    }
}

#if canImport(UIKit)
import SwiftUI
import UIKit

@MainActor enum PS2Retail165Bootstrap {
    static var requested: Bool { ProcessInfo.processInfo.arguments.contains("--ps2-retail165-qa") }
    static var libraryRoot: URL {
        let caches = PS2Retail165Contract.systemURL(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].resolvingSymlinksInPath())
        // Invalid configuration still never opens the normal library.
        if let run = try? PS2Retail165Contract.run(ProcessInfo.processInfo.environment["VETA_PS2_RETAIL165_RUN"]),
           let root = try? PS2Retail165Contract.sessionRoot(caches: caches, run: run),
           (try? PS2Retail165Contract.safe(root, inside: caches)) != nil { return root }
        return caches.appendingPathComponent("VetaPS2Retail165Invalid-"+UUID().uuidString)
    }
}

struct PS2Retail165QAView: View {
    @ObservedObject var library: Library
    @State private var session: PS2WebSession?
    @State private var nativeGame: Game?
    @State private var status = "Verificando copia local de PS2…"
    @State private var failed = false
    @State private var tools = true
    @State private var pulseTask: Task<Void, Never>?
    @State private var rows: [[String: Any]] = []
    @State private var actions: [[String: Any]] = []
    var body: some View {
        Group {
            if let nativeGame {
                PS2Native165QAView(game: nativeGame, root: library.root)
            } else if let session {
                PS2WebGameContainer(session: session)
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 8) {
                            Button(tools ? "Ocultar QA" : "Mostrar QA") { tools.toggle() }
                                .accessibilityIdentifier("ps2-retail-qa-tools")
                            if tools {
                                ScrollView(.horizontal) {
                                    HStack(spacing: 8) {
                                        control("START", mask: 1 << 3)
                                        control("Cruz", mask: 1)
                                        control("Círculo", mask: 1 << 8)
                                        control("Triángulo", mask: 1 << 9)
                                        control("Cuadrado", mask: 1 << 1)
                                        control("SELECT", mask: 1 << 2)
                                        control("Arriba", mask: 1 << 4)
                                        control("Abajo", mask: 1 << 5)
                                        control("Izquierda", mask: 1 << 6)
                                        control("Derecha", mask: 1 << 7)
                                        control("Izquierda 2 s", mask: 1 << 6, duration: 2)
                                        control("Derecha 2 s", mask: 1 << 7, duration: 2)
                                        control("Acelerar 3 s", mask: 1, duration: 3)
                                        Button("Soltar") { release(session) }.accessibilityIdentifier("ps2-retail-qa-release")
                                    }
                                }
                                Text(session.metrics.isEmpty ? session.status : session.metrics)
                                    .font(.caption.monospaced()).lineLimit(3)
                                    .accessibilityIdentifier("ps2-retail-qa-metrics")
                            }
                        }.buttonStyle(.bordered).controlSize(.large).padding(8)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .padding(.top, 45).padding(.horizontal, 8)
                    }
                    .task { await collect(session) }
            } else {
                VStack(spacing: 16) {
                    if !failed { ProgressView() }
                    Text(status).accessibilityIdentifier("ps2-retail-qa-status")
                }.padding()
            }
        }.task { if session == nil && nativeGame == nil && !failed { await prepare() } }
            .onDisappear { pulseTask?.cancel(); if let session { release(session) } }
    }
    private func control(_ name: String, mask: UInt16, duration: Double = 0.18) -> some View {
        Button(name) {
            guard let session, session.running, !session.showMenu, !session.busy else { return }
            pulseTask?.cancel(); session.setAnalog(0, .zero); session.setTouches(mask)
            actions.append(["time": ProcessInfo.processInfo.systemUptime, "name": name, "mask": mask, "seconds": duration])
            pulseTask = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: UInt64(duration*1_000_000_000)) } catch { return }
                session.setTouches(0); session.setAnalog(0, .zero)
            }
        }.disabled(session?.running != true || session?.showMenu == true || session?.busy == true)
            .accessibilityLabel("QA "+name)
            .accessibilityIdentifier("ps2-retail-qa-"+name)
    }
    private func release(_ session: PS2WebSession) {
        pulseTask?.cancel(); pulseTask = nil; session.setTouches(0); session.setAnalog(0, .zero)
    }
    private func prepare() async {
        var stage = "configuration"
        do {
            let env = ProcessInfo.processInfo.environment
            guard !veta_jit_available(), !veta_jit_debugger_attached() else {
                throw PS2Retail165Contract.Diagnostic(stage:"execution-mode",relativePath:"host",reason:"Fresh process without native JIT or debugger required")
            }
            let run = try PS2Retail165Contract.run(env["VETA_PS2_RETAIL165_RUN"])
            guard env["VETA_PS2_WEB_QA"] == "1", env["VETA_PS2_WEB_QA_RUN"] == run else { throw PS2Retail165Contract.Failure.invalidRun }
            let caches = PS2Retail165Contract.systemURL(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].resolvingSymlinksInPath())
            let support = PS2Retail165Contract.systemURL(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].resolvingSymlinksInPath())
            let staging = try PS2Retail165Contract.stagingRoot(caches: caches, run: run)
            // Reuse a read-only QA disc without copying it again over USB. The
            // fixture, BIOS and writable session still belong to this fresh run.
            // linkVerified rechecks the full hash, size and boot serial below.
            let discSourceRun = try PS2Retail165Contract.run(env["VETA_PS2_RETAIL165_DISC_SOURCE_RUN"] ?? run)
            let discStaging = try PS2Retail165Contract.stagingRoot(caches: caches, run: discSourceRun)
            let root = try PS2Retail165Contract.sessionRoot(caches: caches, run: run)
            stage = "library-root"
            try PS2Retail165Contract.checked(stage, "Sessions/<run>") {
                guard PS2Retail165Contract.systemURL(library.root).path == PS2Retail165Contract.systemURL(root).path else { throw PS2Retail165Contract.Failure.unsafePath }
                try PS2Retail165Contract.safe(library.root, inside: caches)
            }
            stage = "fixture-and-source"
            let fixture = try await Task.detached(priority: .userInitiated) {
                let fixture = try PS2Retail165Contract.checked("fixture", "Staging/<run>/fixture.json") {
                    try PS2Retail165Contract.readFixture(staging.appendingPathComponent("fixture.json"), inside: caches)
                }
                var source = discStaging.appendingPathComponent(fixture.discName), sourceRoot = caches
                // Read existing metadata only, avoiding Library() migration or
                // persistence on the user's Application Support library.
                struct Entry: Decodable { let id: String; let console: String; let contentName: String? }
                let original = support.appendingPathComponent("VetaNative"), index = original.appendingPathComponent("library.json")
                if let size = try? PS2Retail165Contract.regular(index, inside: support), size < 16*1024*1024,
                   let data = try? Data(contentsOf: index), let entries = try? JSONDecoder().decode([Entry].self, from: data),
                   let entry = entries.first(where: { $0.id == fixture.id && $0.console == "ps2" }) {
                    let filename = entry.contentName ?? "game.iso"
                    guard PS2Retail165Contract.basename(filename),
                          ["iso", "cso"].contains(URL(fileURLWithPath: filename).pathExtension.lowercased()),
                          URL(fileURLWithPath: filename).pathExtension.lowercased() == URL(fileURLWithPath: fixture.discName).pathExtension.lowercased()
                    else { throw PS2Retail165Contract.Failure.unsafePath }
                    let candidate = original.appendingPathComponent(fixture.id).appendingPathComponent(filename)
                    if FileManager.default.fileExists(atPath: candidate.path) { source = candidate; sourceRoot = support }
                }
                try PS2Retail165Contract.linkVerified(source, sourceRoot: sourceRoot,
                    destination: root.appendingPathComponent(fixture.id).appendingPathComponent(fixture.discName), session: root, fixture: fixture)
                return fixture
            }.value
            stage = "session-library"
            var game = Game(id: fixture.id, name: fixture.title, console: .ps2); game.contentName = fixture.discName
            library.games = [game]; library.consoles = [.ps2]; try library.persist()
            if env["VETA_PS2_RETAIL165_ENGINE"] == "arms" {
                nativeGame = game
            } else {
                session = PS2WebSession(game: game, library: library)
            }
        } catch {
            failed = true
            let diagnostic = (error as? PS2Retail165Contract.Diagnostic)?.description
                ?? "\(stage): \((error as? PS2Retail165Contract.Failure).map { String(describing: $0) } ?? "\((error as NSError).domain):\((error as NSError).code)")"
            print("VETA_PS2_RETAIL_QA_FAILURE \(diagnostic)")
            status = "QA PS2 no iniciada: \(diagnostic)"
        }
    }
    private func collect(_ session: PS2WebSession) async {
        while !Task.isCancelled {
            rows.append(["time": ProcessInfo.processInfo.systemUptime, "metrics": session.metrics,
                         "running": session.running, "ready": session.ready, "menu": session.showMenu,
                         "nativeJIT": veta_jit_available(), "debugger": veta_jit_debugger_attached(),
                         "error": session.error ?? "", "thermal": ProcessInfo.processInfo.thermalState.rawValue,
                         "qaTelemetry": session.qaTelemetry])
            if rows.count > 600 { rows.removeFirst(rows.count-600) }
            if actions.count > 200 { actions.removeFirst(actions.count-200) }
            let report: [String: Any] = ["schema": 1, "mode": "normalPS2WebSession", "gameID": session.game.id,
                "engineAssets": PS2WebSession.assetDirectoryName,
                "scope": "QA cache, native controls, existing web counters; not unique images/game-clock or audio listening acceptance",
                "samples": rows, "actions": actions]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                try? data.write(to: library.root.appendingPathComponent("metrics.json"), options: .atomic)
            }
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
        }
    }
}
#endif
#endif
