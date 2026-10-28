import Foundation

/// The execution choice is fixed before preflight and stays fixed until unload.
/// Network availability is deliberately not a prerequisite for local execution.
struct GameLaunchPlan: Equatable {
    enum Mode: String { case standard, jit, interpreter, webAssembly }
    enum Preference: String, CaseIterable {
        case automatic, maximumPerformance
        static let key = "native.advancedExecution"
        static var current: Self { Self(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .automatic }
    }
    static let localInterpreterConsoles: Set<GameConsole> = [.threeDS, .dreamcast, .gamecube, .wii]
    let console: GameConsole
    let mode: Mode
    let blocker: String?
    init(console: GameConsole, mode: Mode, blocker: String? = nil) {
        self.console = console; self.mode = mode; self.blocker = blocker
    }
    var isInterpreter: Bool { mode == .interpreter }
    var requiresJIT: Bool { mode == .jit }
    var usesSharedPreparation: Bool { requiresJIT && console.usesSharedJITPool }
    var stateNamespace: String? { isInterpreter ? "offline-\(console.rawValue)-v1" : nil }
    func stateCoreID(for game: Game) -> String { isInterpreter ? game.coreID + "-interpreter-v1" : game.coreID }
    var notice: String? { isInterpreter ? "Modo sin conexión. La velocidad depende del juego y puede ser menor. Máximo rendimiento está disponible en Ajustes." : nil }

    /// Decide once per launch, using the current process capability. Automatic
    /// never starts the helper just to replace an available local engine.
    static func prefersJIT(snapshot: DeviceReadiness.Snapshot, preference: Preference,
                           interpreterOverride: Bool = false) -> Bool {
        !interpreterOverride && (preference == .maximumPerformance ||
            (snapshot.experimentalBuild && snapshot.jitAvailable))
    }

    static func resolve(console: GameConsole, snapshot: DeviceReadiness.Snapshot,
                        preference: Preference = .current, interpreterOverride: Bool = false) -> Self {
        // PS2 uses the existing native JIT route. Keep WebAssembly available
        // only for the explicit offline QA override; never migrate its saves.
        if console == .ps2, snapshot.includedWebAssemblyConsoles.contains(.ps2),
           interpreterOverride {
            return Self(console:console,mode:.webAssembly)
        }
        if localInterpreterConsoles.contains(console),
           prefersJIT(snapshot: snapshot, preference: preference, interpreterOverride: interpreterOverride) {
            return Self(console: console, mode: .jit)
        }
        #if VETA_JIT_DEVELOPMENT
        if console == .dreamcast,
           DreamcastWebLaunchPolicy.enabled,
           snapshot.includedWebAssemblyConsoles.contains(.dreamcast),
           interpreterOverride || preference == .automatic {
            return Self(console: console, mode: .webAssembly)
        }
        if console == .xbox, snapshot.includedInterpreterConsoles.contains(.xbox),
           interpreterOverride || preference == .automatic {return Self(console:console,mode:.interpreter)}
        #endif
        guard localInterpreterConsoles.contains(console) else {
            return Self(console: console, mode: console.requiresJIT ? .jit : .standard)
        }
        let local = snapshot.includedInterpreterConsoles.contains(console)
        // No active JIT: retain the local route and its separate save namespace.
        if local && (interpreterOverride || preference == .automatic) {
            return Self(console: console, mode: .interpreter)
        }
        return Self(console: console, mode: .jit)
    }
    @MainActor static func capture(for game: Game, readiness: DeviceReadiness, library: Library, preference: Preference = .current) -> Self {
        var probe = false
        #if VETA_JIT_DEVELOPMENT
        // Explicit offline QA retains its local route, including PS2.
        probe = ProcessInfo.processInfo.environment["VETA_OFFLINE160_CONSOLE"] == game.console.rawValue
        #endif
        let selected = resolve(console: game.console, snapshot: readiness.snapshot, preference: preference, interpreterOverride: probe)
        #if VETA_JIT_DEVELOPMENT
        if game.console == .dreamcast {
            do {
                let route = try DreamcastWebLaunchPolicy.preflightAndSelect(
                    gameID: game.id, disc: library.romURL(game),
                    gameDirectory: library.stateDirectory(game),
                    nativeSaveDirectory: library.file(game, "CoreSaves"),
                    system: library.root.appendingPathComponent("System"),
                    assets: DreamcastWebLaunchPolicy.assetCandidate(),
                    maximumPerformance: prefersJIT(snapshot: readiness.snapshot, preference: preference, interpreterOverride: probe),
                    interpreterAvailable: readiness.snapshot.includedInterpreterConsoles.contains(.dreamcast))
                return Self(console: .dreamcast, mode: route == .web ? .webAssembly : route == .interpreter ? .interpreter : .jit)
            } catch {
                // Keep a blocking plan, never reinterpret a failure as permission
                // to switch to a different card namespace.
                return Self(console: .dreamcast, mode: .webAssembly, blocker: error.localizedDescription)
            }
        }
        #endif
        return selected
    }
}

struct GameLaunchRequest: Identifiable {
    let game: Game
    let plan: GameLaunchPlan
    var id: String { game.id }
}

/// Complete persistent PS2 Web storage, including retained recovery copies.
/// This mirrors PS2WebServer's on-disk contract, not its HTTP route names.
struct WebEngineArchive: Codable {
    struct File: Codable {let digest:String;let bytes:Data}
    struct StorageEntry:Codable {let path:String;let size:Int}
    struct StorageIndex:Codable {let files:[StorageEntry]}
    struct StateMetadata:Codable {let version:Int;let gameID:String;let format:String;let sha256:String;let bytes:Int;let createdAt:Date}
    static let engineID="play-web-v1"
    static let stateFormat="play-505dac7-vmzip-timing-v1"
    static let maximumBytes=128*1024*1024
    static let maximumFiles=16384
    let version:Int
    let engine:String
    let gameID:String
    let files:[String:File]
    static var invalid:Error {VetaError.message("Partida incompatible")}
    static func isDigest(_ value:String)->Bool {value.count==64 && value.utf8.allSatisfy{(48...57).contains($0) || (97...102).contains($0)}}
    static func validCardPath(_ path:String,allowRecovery:Bool=false)->Bool {
        guard path.hasPrefix("vfs/mc0/") || path.hasPrefix("vfs/mc1/"),path.utf8.count<=1024 else{return false}
        let parts=path.split(separator:"/",omittingEmptySubsequences:false)
        guard parts.count<=16 else{return false}
        return parts.enumerated().allSatisfy {index,part in
            guard !part.isEmpty,part != ".",part != "..",part.utf8.count<=255,
                  !part.contains("\\"),!part.unicodeScalars.contains(where:{$0.value<32 || $0.value==127}) else{return false}
            if part.hasPrefix(".veta-") {return allowRecovery && index==parts.count-1 && part.hasPrefix(".veta-previous-") && isDigest(String(part.dropFirst(15)))}
            return true
        }
    }
    static func fileLimit(_ path:String)throws->Int {
        if path.hasPrefix("files.previous/") {return try fileLimit("files/"+path.dropFirst("files.previous/".count))}
        if path=="files/.veta-manifest.json" {return 1024*1024}
        if path.hasPrefix("files/.veta-previous-"),isDigest(String(path.dropFirst("files/.veta-previous-".count))) {return 1024*1024}
        if path.hasPrefix("files/"),validCardPath(String(path.dropFirst(6)),allowRecovery:true) {return 64*1024*1024}
        let slots=["auto","quick","before-load"].flatMap{["states/"+$0+".state","states/"+$0+".previous.state"]}
        if slots.contains(path) {return maximumBytes+4096+12}
        if NativeSaveStore.manualSlots.map({"manual-saves/"+$0+".vstate"}).contains(path) {return 180*1024*1024}
        throw invalid
    }
    func validate(game:Game)throws {
        guard game.console == .ps2,version==1,engine==Self.engineID,gameID==game.id,Self.isDigest(gameID),files.count<=Self.maximumFiles else{throw Self.invalid}
        var total=0,cardTotal=0,paths=Set<String>()
        for (path,file) in files {
            let limit=try Self.fileLimit(path)
            // Avoid order-dependent writes on case/normalization-insensitive FS.
            guard paths.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                  file.bytes.count<=limit,Self.isDigest(file.digest),sha256(file.bytes)==file.digest else{throw Self.invalid}
            total+=file.bytes.count;guard total<=Self.maximumBytes else{throw Self.invalid}
            if path.hasPrefix("files/") || path.hasPrefix("files.previous/") {cardTotal+=file.bytes.count;guard cardTotal<=Self.maximumBytes else{throw Self.invalid}}
            if path.hasPrefix("states/") {try validateState(file.bytes)}
            if path.hasPrefix("manual-saves/") {
                let payload = try StateFile.decode(file.bytes, rom: gameID, core: Self.stateFormat)
                guard payload.starts(with: [0x50,0x4b,0x03,0x04]) else { throw Self.invalid }
            }
        }
        // A file cannot also be an ancestor directory of another entry.
        for path in files.keys {
            var parts=path.split(separator:"/").map(String.init);parts.removeLast()
            while !parts.isEmpty {
                guard !paths.contains(parts.joined(separator:"/").precomposedStringWithCanonicalMapping.lowercased()) else{throw Self.invalid}
                parts.removeLast()
            }
        }
        for (path,file) in files where path=="files/.veta-manifest.json" || path=="files.previous/.veta-manifest.json" || path.hasPrefix("files/.veta-previous-") || path.hasPrefix("files.previous/.veta-previous-") {
            let index=try JSONDecoder().decode(StorageIndex.self,from:file.bytes)
            guard index.files.count<=4096 else{throw Self.invalid}
            var seen=Set<String>(),size=0
            for entry in index.files {
                guard Self.validCardPath(entry.path),seen.insert(entry.path).inserted,entry.size>=0,entry.size<=64*1024*1024 else{throw Self.invalid}
                size+=entry.size;guard size<=Self.maximumBytes else{throw Self.invalid}
                // The prior manifest may describe the prior bytes; preserve it
                // without applying it as the current card index.
                if path.hasSuffix("/.veta-manifest.json") {
                    let prefix=path.hasPrefix("files.previous/") ? "files.previous/":"files/"
                    guard files[prefix+entry.path]?.bytes.count==entry.size else{throw Self.invalid}
                }
            }
        }
    }
    private func validateState(_ data:Data)throws {
        guard data.count>=12,data.prefix(8)==Data("VETAPSW1".utf8) else{throw Self.invalid}
        let length=data[8..<12].reduce(0){($0<<8)|Int($1)}
        guard length>0,length<=4096,data.count>=12+length else{throw Self.invalid}
        let meta=try JSONDecoder().decode(StateMetadata.self,from:data.subdata(in:12..<12+length))
        let payload=data.suffix(from:12+length)
        guard meta.version==1,meta.gameID==gameID,meta.format==Self.stateFormat,meta.bytes>=4,meta.bytes<=Self.maximumBytes,
              payload.count==meta.bytes,payload.starts(with:[0x50,0x4b,0x03,0x04]),Self.isDigest(meta.sha256),sha256(payload)==meta.sha256 else{throw Self.invalid}
    }
}

extension Library {
    /// Never follow an app-owned directory symlink, including dangling links.
    private func webStorageRoot(_ game:Game,createParents:Bool=false)throws->URL {
        guard game.console == .ps2,WebEngineArchive.isDigest(game.id) else{throw WebEngineArchive.invalid}
        let fm=FileManager.default
        var current=root
        for (index,part) in ["",game.id,"engines",WebEngineArchive.engineID].enumerated() {
            if !part.isEmpty {current.appendPathComponent(part,isDirectory:true)}
            guard (try? fm.destinationOfSymbolicLink(atPath:current.path)) == nil else{throw WebEngineArchive.invalid}
            if fm.fileExists(atPath:current.path) {
                let info=try current.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
                guard info.isDirectory==true,info.isSymbolicLink != true else{throw WebEngineArchive.invalid}
            }else if createParents && index<3 {try fm.createDirectory(at:current,withIntermediateDirectories:false)}
        }
        return current
    }
    func archiveWebEngineStorage(_ game:Game)throws->WebEngineArchive? {
        guard game.console == .ps2 else{return nil}
        let storage=try webStorageRoot(game),fm=FileManager.default
        guard fm.fileExists(atPath:storage.path) else{return nil}
        let canonical=storage.resolvingSymlinksInPath().standardizedFileURL
        var traversalError:Error?,visited=0,total=0,files:[String:WebEngineArchive.File]=[:]
        guard let iterator=fm.enumerator(at:storage,includingPropertiesForKeys:[.isRegularFileKey,.isDirectoryKey,.isSymbolicLinkKey,.fileSizeKey],errorHandler:{_,error in traversalError=error;return false}) else{throw WebEngineArchive.invalid}
        for case let url as URL in iterator {
            visited+=1;guard visited<=32768 else{throw WebEngineArchive.invalid}
            let info=try url.resourceValues(forKeys:[.isRegularFileKey,.isDirectoryKey,.isSymbolicLinkKey,.fileSizeKey])
            guard info.isSymbolicLink != true else{throw WebEngineArchive.invalid}
            if info.isDirectory==true {continue}
            let path=url.resolvingSymlinksInPath().standardizedFileURL.path
            guard path.hasPrefix(canonical.path+"/") else{throw WebEngineArchive.invalid}
            let relative=String(path.dropFirst(canonical.path.count+1)),limit=try WebEngineArchive.fileLimit(String(path.dropFirst(canonical.path.count+1)))
            guard info.isRegularFile==true,let size=info.fileSize,size>=0,size<=limit,files.count<WebEngineArchive.maximumFiles else{throw WebEngineArchive.invalid}
            total+=size;guard total<=WebEngineArchive.maximumBytes else{throw WebEngineArchive.invalid}
            let data=try Data(contentsOf:url);guard data.count==size else{throw WebEngineArchive.invalid}
            files[relative] = .init(digest:sha256(data),bytes:data)
        }
        if let traversalError {throw traversalError}
        guard !files.isEmpty else{return nil}
        let archive=WebEngineArchive(version:1,engine:WebEngineArchive.engineID,gameID:game.id,files:files)
        try archive.validate(game:game);return archive
    }
    func restoreWebEngineStorage(_ archive:WebEngineArchive,game:Game)throws {
        try archive.validate(game:game)
        let storage=try webStorageRoot(game,createParents:true),fm=FileManager.default
        guard !fm.fileExists(atPath:storage.path) else{throw VetaError.message("Ya existe una carpeta sin registrar para este juego. Sus archivos se conservaron.")}
        let staging=storage.deletingLastPathComponent().appendingPathComponent(".web-import-"+UUID().uuidString,isDirectory:true)
        try fm.createDirectory(at:staging,withIntermediateDirectories:false)
        defer{try? fm.removeItem(at:staging)}
        for (path,file) in archive.files {
            let destination=staging.appendingPathComponent(path)
            try fm.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
            try file.bytes.write(to:destination,options:.withoutOverwriting)
            guard sha256(try Data(contentsOf:destination))==file.digest else{throw WebEngineArchive.invalid}
        }
        // Publish a complete new namespace; existing namespaces always win.
        try fm.moveItem(at:staging,to:storage)
    }
}

extension Library {
    /// Quick states are backend-specific; guest SD/cards remain in CoreSaves.
    func stateDirectory(_ game: Game, plan: GameLaunchPlan) -> URL {
        let base = stateDirectory(game)
        guard let namespace = plan.stateNamespace else { return base }
        return base.appendingPathComponent("ExecutionStates", isDirectory: true)
            .appendingPathComponent(namespace, isDirectory: true)
    }

    /// A real 3DS JIT -> FastInterp resume has been verified; this is not a
    /// compatibility claim for other cores or every historical state format.
    /// Copy only a validated v3 auto with the current profile. Preserve the
    /// original envelope and compressed payload, changing only backend identity.
    @discardableResult
    func migrateLegacy3DSAuto(_ game: Game, plan: GameLaunchPlan, optionsFingerprint: String,
                             isRenderQA: Bool = ProcessInfo.processInfo.environment["VETA_TV158_QA_PRIMARY"] == "1") throws -> Bool {
        guard !isRenderQA, game.console == .threeDS, plan.console == .threeDS, plan.isInterpreter else { return false }
        let target = NativeSaveStore(directory: stateDirectory(game, plan: plan), rom: game.id, core: plan.stateCoreID(for: game))
        let destination = try target.url("auto")
        guard !FileManager.default.fileExists(atPath: destination.path) else { return false }
        let legacy = NativeSaveStore(directory: stateDirectory(game), rom: game.id, core: game.coreID)
        guard FileManager.default.fileExists(atPath: try legacy.url("auto").path) else { return false }
        let original = try legacy.read("auto")
        let envelope = try JSONDecoder().decode(StateFile.self, from: original)
        guard envelope.version == 3, envelope.optionsFingerprint == optionsFingerprint else {
            throw VetaError.message("Este estado usa otro perfil del motor. Restaura sus opciones antes de cargarlo; tu partida actual no cambió.")
        }
        let payload = try StateFile.decode(original, rom: game.id, core: game.coreID, optionsFingerprint: optionsFingerprint)
        guard var metadata = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
            throw VetaError.message("Partida incompatible")
        }
        metadata["core"] = plan.stateCoreID(for: game)
        let migrated = try JSONSerialization.data(withJSONObject: metadata, options: .sortedKeys)
        guard try StateFile.decode(migrated, rom: game.id, core: plan.stateCoreID(for: game), optionsFingerprint: optionsFingerprint) == payload else {
            throw VetaError.message("Partida incompatible")
        }
        try FileManager.default.createDirectory(at: target.directory, withIntermediateDirectories: true)
        // MainActor + no suspension keeps the absence check and atomic write in
        // one app operation. Subsequent launches never replace an existing auto.
        try target.write(migrated, slot: "auto")
        return true
    }
}

// Only recognized backend namespaces and valid state envelopes enter a backup.
// Native cards/SD remain in the existing CoreSaves storage and are not duplicated.
extension Library {
    func archiveExecutionStates(_ game: Game) throws -> [String: [String: Data]]? {
        guard GameLaunchPlan.localInterpreterConsoles.contains(game.console) else { return nil }
        let plan = GameLaunchPlan(console: game.console, mode: .interpreter)
        let directory = stateDirectory(game, plan: plan)
        var states: [String: Data] = [:]
        for slot in NativeSaveStore.slots {
            let url = directory.appendingPathComponent(slot + ".vstate")
            if FileManager.default.fileExists(atPath: url.path) {
                let store = NativeSaveStore(directory: directory, rom: game.id, core: plan.stateCoreID(for: game))
                states[slot] = try store.read(slot)
            }
        }
        guard !states.isEmpty, let namespace = plan.stateNamespace else { return nil }
        let archive = [namespace: states]
        try validateExecutionStates(archive, game: game)
        return archive
    }
    func validateExecutionStates(_ archive: [String: [String: Data]], game: Game) throws {
        let plan = GameLaunchPlan(console: game.console, mode: .interpreter)
        guard GameLaunchPlan.localInterpreterConsoles.contains(game.console),
              archive.count <= 1, archive.keys.allSatisfy({ $0 == plan.stateNamespace }) else {
            throw VetaError.message("Partida incompatible")
        }
        for states in archive.values {
            guard states.count <= NativeSaveStore.slots.count,
                  states.keys.allSatisfy(NativeSaveStore.slots.contains) else { throw VetaError.message("Partida incompatible") }
            for data in states.values {
                _ = try StateFile.decode(data, rom: game.id, core: plan.stateCoreID(for: game))
            }
        }
    }
    func restoreExecutionStates(_ archive: [String: [String: Data]], game: Game) throws {
        try validateExecutionStates(archive, game: game)
        let directory = stateDirectory(game, plan: GameLaunchPlan(console: game.console, mode: .interpreter))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for states in archive.values {
            for (slot, data) in states { try data.write(to: directory.appendingPathComponent(slot + ".vstate"), options: .atomic) }
        }
    }
}
