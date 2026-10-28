import Foundation

/// Shared read-only launch checks after the h6 device close/reopen/readback gate.
/// Selected JIT stays separate; unsupported discs keep the native route.
enum DreamcastWebLaunchPolicy {
    static let promotedByDefault = true
    static let maximumDiscBytes: UInt64 = 512 * 1024 * 1024
    enum Route { case web, interpreter, jit }
    static func isEnabled(environment: [String: String]) -> Bool {
        #if VETA_JIT_DEVELOPMENT
        switch environment["VETA_DREAMCAST_WEB165"] {
        case "1": return true
        case "0": return false
        default: return promotedByDefault
        }
        #else
        return false
        #endif
    }
    static var enabled: Bool { isEnabled(environment: ProcessInfo.processInfo.environment) }
    /// Inspect the expected directory, not merely a discoverable WASM file:
    /// partial/empty/wrong-type installations must not become "absent".
    static func assetCandidate(in bundle: Bundle = .main) -> URL? {
        bundle.resourceURL?.appendingPathComponent("DreamcastWasm", isDirectory: true)
    }
    private static func attributesIfPresent(_ url: URL) throws -> [FileAttributeKey: Any]? {
        try DreamcastWebAssets.validatePath(url)
        do { return try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return nil }
    }
    static func assetsAvailable(_ directory: URL?) throws -> Bool {
        guard let directory, let info = try attributesIfPresent(directory) else { return false }
        guard info[.type] as? FileAttributeType == .typeDirectory else {
            throw DreamcastWebAssets.failure("Faltan archivos del motor Dreamcast. Tus partidas siguen guardadas.")
        }
        try DreamcastWebAssets.validate(at: directory)
        return true
    }
    private static func regularSize(_ url: URL) throws -> UInt64 {
        guard let info = try attributesIfPresent(url),
              info[.type] as? FileAttributeType == .typeRegular,
              let size = info[.size] as? NSNumber, size.uint64Value > 0 else {
            throw DreamcastWebAssets.failure("No se puede leer un archivo necesario para este juego de Dreamcast.")
        }
        return size.uint64Value
    }
    private static func validateBIOS(_ system: URL) throws {
        for (name, bytes) in [("dc_boot.bin", UInt64(2097152)), ("dc_flash.bin", UInt64(131072))] {
            guard try regularSize(system.appendingPathComponent("dc").appendingPathComponent(name)) == bytes else {
                throw DreamcastWebAssets.failure(L10n.format("La BIOS %@ no tiene el tamaño requerido en System/dc.", name))
            }
        }
    }
    private static func store(gameID: String, gameDirectory: URL, nativeSaveDirectory: URL, system: URL) throws -> DreamcastWebVMUStore {
        try DreamcastWebVMUStore(gameID: gameID, gameDirectory: gameDirectory, nativeSaveDirectory: nativeSaveDirectory, nativeSystem: system)
    }
    static func preflightAndSelect(gameID: String, disc: URL, gameDirectory: URL,
                                   nativeSaveDirectory: URL, system: URL, assets: URL?,
                                   maximumPerformance: Bool, interpreterAvailable: Bool,
                                   environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Route {
        // A JIT launch (active automatic or requested maximum) retains its native cards. No implicit card
        // merge/copy-back, even if the web namespace exists or is damaged.
        if maximumPerformance { return .jit }
        let cards = try store(gameID: gameID, gameDirectory: gameDirectory, nativeSaveDirectory: nativeSaveDirectory, system: system)
        let existing = try cards.hasPersistentPackage()
        func nativeFallback() throws -> Route {
            guard !existing else {
                throw DreamcastWebAssets.failure("No se puede abrir la partida con esta configuración. Tus partidas siguen guardadas; no se cambió de motor.")
            }
            return interpreterAvailable ? .interpreter : .jit
        }
        guard isEnabled(environment: environment) else { return try nativeFallback() }
        guard try assetsAvailable(assets) else { return try nativeFallback() }
        let size = try regularSize(disc)
        guard disc.pathExtension.lowercased() == "chd", size <= maximumDiscBytes else { return try nativeFallback() }
        try validateBIOS(system)
        try cards.preflight()
        return .web
    }
    /// Player repeats the read-only gates immediately before constructing the
    /// authoritative server. Failure is final for this launch, never fallback.
    static func preflightWeb(gameID: String, disc: URL, gameDirectory: URL,
                             nativeSaveDirectory: URL, system: URL, assets: URL) throws {
        guard enabled, try assetsAvailable(assets),
              disc.pathExtension.lowercased() == "chd", try regularSize(disc) <= maximumDiscBytes else {
            throw DreamcastWebAssets.failure("Este motor Dreamcast requiere un CHD de hasta 512 MiB y su paquete completo.")
        }
        try validateBIOS(system)
        try store(gameID: gameID, gameDirectory: gameDirectory, nativeSaveDirectory: nativeSaveDirectory, system: system).preflight()
    }
}
