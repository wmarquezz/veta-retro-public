import Foundation
import CryptoKit

/// Server-queue confined. Web cards have their own namespace; native files are
/// read only during first import and never become write destinations.
final class DreamcastWebVMUStore {
    static let engine = "db2b87d8d2742087a56c4eeed317da14e3549ee037e36de3d77c1e6e5291bead"
    static let maximumBytes = 8 * 1024 * 1024
    static let cardBytes = 131072
    struct Entry: Codable { let path: String; let bytes: Int; let sha256: String; let base64: String }
    struct Envelope: Codable { let format: String; let version: Int; let engine: String; let game: String; let entries: [Entry] }
    enum Failure: Error, LocalizedError {
        case invalidBundle, unsafePath, conflictingNative, unsupportedNative, changedSession, backupLimit, verificationFailed, missingCurrentWithBackups, unreadableBackups
        var errorDescription: String? {
            switch self {
            case .missingCurrentWithBackups: return L10n.text("Falta la tarjeta actual, pero hay copias de seguridad. No se modificó ninguna; es necesario revisar la recuperación.")
            case .unreadableBackups: return L10n.text("No se pudo revisar el historial de tarjetas de Dreamcast. No se importó ni reemplazó ninguna tarjeta.")
            case .invalidBundle: return L10n.text("La tarjeta de Dreamcast recibida no es válida. Se conserva la copia anterior.")
            case .unsafePath: return L10n.text("No se pudo acceder de forma segura a las tarjetas de Dreamcast.")
            case .conflictingNative: return L10n.text("Hay tarjetas distintas para la misma ranura. No se eligió ni reemplazó ninguna.")
            case .unsupportedNative: return L10n.text("Una tarjeta de memoria necesita revisión antes de abrir este motor. No se reemplazó.")
            case .changedSession: return L10n.text("La tarjeta cambió desde que se abrió esta sesión. No se sobrescribió.")
            case .backupLimit: return L10n.text("No hay espacio en el historial de seguridad de Dreamcast. Se conserva la tarjeta anterior.")
            case .verificationFailed: return L10n.text("No se pudo verificar la copia de Dreamcast. Conserva esta sesión para reintentar.")
            }
        }
    }
    private let gameID: String, gameDirectory: URL, nativeSaveDirectory: URL, nativeSystem: URL
    private let directory: URL
    private static let fileLock = NSRecursiveLock()
    private var loaded = false
    private var expectedCurrent: String?
    private var current: URL { directory.appendingPathComponent("persistent.bin") }
    private var backups: URL { directory.appendingPathComponent("backups") }

    init(gameID: String, gameDirectory: URL, nativeSaveDirectory: URL, nativeSystem: URL) throws {
        guard Self.digestName(gameID) else { throw Failure.invalidBundle }
        self.gameID = gameID
        self.gameDirectory = Self.systemURL(gameDirectory)
        self.nativeSaveDirectory = Self.systemURL(nativeSaveDirectory)
        self.nativeSystem = Self.systemURL(nativeSystem)
        directory = Self.systemURL(gameDirectory).appendingPathComponent("engines/flycast-web-v1")
        try Self.safe(directory, inside: self.gameDirectory)
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func digestName(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func allowed(_ path: String) -> Bool {
        guard path.utf8.allSatisfy({ (32...126).contains($0) }) else { return false }
        return path == "/system/dc/dc_nvmem.bin" ||
        path.range(of: #"^/system/dc/vmu_save_[A-D][12]\.bin$"#, options: .regularExpression) != nil ||
        path.range(of: #"^/saves/Flycast/[A-Za-z0-9_().-]{1,128}\.[A-D][12]\.bin$"#, options: .regularExpression) != nil
    }
    static func validate(_ data: Data, gameID: String) throws -> Envelope {
        guard !data.isEmpty, data.count <= maximumBytes else { throw Failure.invalidBundle }
        let value: Envelope
        do { value = try JSONDecoder().decode(Envelope.self, from: data) } catch { throw Failure.invalidBundle }
        guard value.format == "veta-flycast-persistent", value.version == 1, value.engine == engine,
              value.game == gameID, digestName(gameID), (1...17).contains(value.entries.count),
              Set(value.entries.map(\.path)).count == value.entries.count,
              value.entries.contains(where: { $0.path != "/system/dc/dc_nvmem.bin" }) else { throw Failure.invalidBundle }
        for entry in value.entries {
            guard allowed(entry.path), entry.bytes == cardBytes, digestName(entry.sha256),
                  entry.base64.utf8.count == ((cardBytes+2)/3)*4,
                  let bytes = Data(base64Encoded: entry.base64), bytes.count == cardBytes,
                  bytes.base64EncodedString() == entry.base64, digest(bytes) == entry.sha256 else { throw Failure.invalidBundle }
        }
        return value
    }
    private static func systemURL(_ url: URL) -> URL {
        let path = url.standardizedFileURL.path
        return URL(fileURLWithPath: path == "/var" || path.hasPrefix("/var/") ? "/private"+path : path)
    }
    private static func safe(_ url: URL, inside root: URL) throws {
        let path = systemURL(url), base = systemURL(root)
        guard path.path.hasPrefix(base.path+"/"), systemURL(path.resolvingSymlinksInPath()).path == path.path,
              systemURL(base.resolvingSymlinksInPath()).path == base.path else { throw Failure.unsafePath }
        var ancestor = path
        while ancestor.path.count >= base.path.count {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: ancestor.path)) != nil { throw Failure.unsafePath }
            if ancestor.path == base.path { break }
            ancestor.deleteLastPathComponent()
        }
    }
    private func ensureDirectory(_ path: URL) throws {
        try Self.safe(path, inside: gameDirectory)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try Self.safe(path, inside: gameDirectory)
        guard try path.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw Failure.unsafePath }
    }
    private static func readFile(_ path: URL, inside root: URL, maximum: Int) throws -> Data {
        try safe(path, inside: root)
        let info = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true,
              let size = info.fileSize, size > 0, size <= maximum else { throw Failure.unsafePath }
        let data = try Data(contentsOf: path)
        guard data.count == size else { throw Failure.verificationFailed }
        return data
    }
    private func currentData() throws -> Data? {
        try Self.safe(current, inside: gameDirectory)
        guard FileManager.default.fileExists(atPath: current.path) else { return nil }
        let data = try Self.readFile(current, inside: gameDirectory, maximum: Self.maximumBytes)
        _ = try Self.validate(data, gameID: gameID)
        return data
    }
    /// Selection/preflight only. No directories, imports, backups or session
    /// optimistic-state changes. An existing malformed package is still present
    /// and therefore cannot authorize an automatic fallback to native memory.
    func hasPersistentPackage() throws -> Bool {
        Self.fileLock.lock(); defer { Self.fileLock.unlock() }
        try Self.safe(current, inside: gameDirectory)
        do { _ = try FileManager.default.attributesOfItem(atPath: current.path); return true }
        catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
            try requireNoPriorBackups(); return false
        }
    }
    /// Missing current plus any prior backup is recovery, not first use. Even
    /// malformed backup bytes are evidence: do not pick, parse, delete or import
    /// over them automatically. A genuinely absent/empty history is first use.
    private func requireNoPriorBackups() throws {
        try Self.safe(backups, inside: gameDirectory)
        let info: [FileAttributeKey: Any]
        do { info = try FileManager.default.attributesOfItem(atPath: backups.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return }
        catch { throw Failure.unreadableBackups }
        guard info[.type] as? FileAttributeType == .typeDirectory else { throw Failure.unreadableBackups }
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: backups.path) }
        catch { throw Failure.unreadableBackups }
        guard names.isEmpty else { throw Failure.missingCurrentWithBackups }
    }
    /// Validate the same current package/native import used by read(), but do
    /// not publish that import or change loaded/expectedCurrent.
    func preflight() throws {
        Self.fileLock.lock(); defer { Self.fileLock.unlock() }
        if try currentData() == nil { try requireNoPriorBackups(); _ = try importNative() }
    }
    /// First access may import a verified COPY of native slots. Existing web
    /// state always wins; later native progress is never merged silently.
    func read() throws -> Data? {
        Self.fileLock.lock(); defer { Self.fileLock.unlock() }
        if loaded {
            let existing = try currentData()
            if existing == nil { try requireNoPriorBackups() }
            return existing
        }
        if let existing = try currentData() {
            expectedCurrent = Self.digest(existing); loaded = true; return existing
        }
        try requireNoPriorBackups()
        try ensureDirectory(directory)
        let imported = try importNative()
        if let imported {
            try preserve(imported) // Retain the first native snapshot as well.
            try atomicPublish(imported)
            expectedCurrent = Self.digest(imported)
        }
        loaded = true
        return imported
    }
    /// Optimistic session guard prevents an older page overwriting a newer one.
    /// Identical retry is accepted after a lost PUT/readback response.
    func commit(_ data: Data) throws {
        Self.fileLock.lock(); defer { Self.fileLock.unlock() }
        let incomingBundle = try Self.validate(data, gameID: gameID)
        if !loaded { _ = try read() }
        let old = try currentData()
        let incoming = Self.digest(data)
        if old.map(Self.digest) == incoming { expectedCurrent = incoming; return }
        guard old.map(Self.digest) == expectedCurrent else { throw Failure.changedSession }
        if let old {
            let previousBundle = try Self.validate(old, gameID: gameID)
            guard Set(previousBundle.entries.map(\.path)).isSubset(of: Set(incomingBundle.entries.map(\.path))) else {
                throw Failure.invalidBundle
            }
            try preserve(old)
        }
        try atomicPublish(data)
        expectedCurrent = incoming
    }
    private func atomicPublish(_ data: Data) throws {
        try ensureDirectory(directory)
        try Self.safe(current, inside: gameDirectory)
        try data.write(to: current, options: .atomic)
        let readback = try Self.readFile(current, inside: gameDirectory, maximum: Self.maximumBytes)
        guard readback == data else { throw Failure.verificationFailed }
    }
    private func preserve(_ data: Data) throws {
        try ensureDirectory(backups)
        let destination = backups.appendingPathComponent(Self.digest(data)+".bin")
        try Self.safe(destination, inside: gameDirectory)
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try Self.readFile(destination, inside: gameDirectory, maximum: Self.maximumBytes) == data else { throw Failure.verificationFailed }
            return
        }
        let contents = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard contents.count < 128 else { throw Failure.backupLimit }
        var total = 0
        for file in contents {
            try Self.safe(file, inside: gameDirectory)
            let info = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true, let size = info.fileSize else { throw Failure.unsafePath }
            total += size
        }
        guard total+data.count <= 128*1024*1024 else { throw Failure.backupLimit }
        let temporary = backups.appendingPathComponent(".pending-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Self.safe(temporary, inside: gameDirectory)
        try data.write(to: temporary, options: .atomic)
        // Creating a hard link is atomic and refuses to replace an existing
        // backup. The temporary inode already contains the complete snapshot.
        try FileManager.default.linkItem(at: temporary, to: destination)
        guard try Self.readFile(destination, inside: gameDirectory, maximum: Self.maximumBytes) == data else { throw Failure.verificationFailed }
    }
    private func importNative() throws -> Data? {
        // Only explicit VMU slot names. Per-content formats are not guessed or
        // renamed; incompatible/ambiguous cards block creation of an empty one.
        let fm = FileManager.default
        let roots = [(nativeSystem.appendingPathComponent("dc"), nativeSystem, false),
                     (nativeSaveDirectory, nativeSaveDirectory.deletingLastPathComponent(), true),
                     (nativeSaveDirectory.appendingPathComponent("dc"), nativeSaveDirectory, true),
                     (nativeSaveDirectory.appendingPathComponent("Flycast"), nativeSaveDirectory, true)]
        var slots: [String: Data] = [:]
        for (folder, root, local) in roots {
            try Self.safe(folder, inside: root)
            guard fm.fileExists(atPath: folder.path) else { continue }
            let names = try fm.contentsOfDirectory(atPath: folder.path)
            guard names.count <= 512 else { throw Failure.unsupportedNative }
            for name in names.sorted() {
                let slot: String?
                let pattern = local ? #"^(?:[A-Za-z0-9_().-]{0,128}_)?vmu_save_([A-D][12])\.bin$"# : #"^vmu_save_([A-D][12])\.bin$"#
                if let expression = try? NSRegularExpression(pattern: pattern),
                   let match = expression.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                   let range = Range(match.range(at: 1), in: name) { slot = String(name[range]) }
                else { slot = nil }
                let destination: String
                if let slot { destination = "/system/dc/vmu_save_"+slot+".bin" }
                else if name == "dc_nvmem.bin" { destination = "/system/dc/dc_nvmem.bin" }
                else {
                    if local && name.hasSuffix(".bin") && (name.lowercased().contains("vmu") || name.range(of: #"\.[A-D][12]\.bin$"#, options: .regularExpression) != nil) { throw Failure.unsupportedNative }
                    continue
                }
                let data = try Self.readFile(folder.appendingPathComponent(name), inside: root, maximum: Self.cardBytes)
                guard data.count == Self.cardBytes else { throw Failure.unsupportedNative }
                if let prior = slots[destination], prior != data { throw Failure.conflictingNative }
                slots[destination] = data
            }
        }
        guard slots.keys.contains(where: { $0 != "/system/dc/dc_nvmem.bin" }) else { return nil }
        let entries = slots.keys.sorted().map { path in
            let data = slots[path]!
            return Entry(path: path, bytes: data.count, sha256: Self.digest(data), base64: data.base64EncodedString())
        }
        let value = Envelope(format: "veta-flycast-persistent", version: 1, engine: Self.engine, game: gameID, entries: entries)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value); _ = try Self.validate(data, gameID: gameID)
        return data
    }
}
