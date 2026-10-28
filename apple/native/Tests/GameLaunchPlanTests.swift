import XCTest
#if VETA_JIT_DEVELOPMENT
@testable import VetaJITLab
#else
@testable import VetaNative
#endif

/// Policy and file-format tests; these fixtures do not assert device performance.
@MainActor final class GameLaunchPlanTests: XCTestCase {
    private func facts(jit: Bool = false) -> DeviceReadiness.Snapshot {
        .init(metalAvailable: true, physicalMemory: 8 * 1024 * 1024 * 1024, processorCount: 6,
              osVersion: .init(majorVersion: 17, minorVersion: 4, patchVersion: 0), simulator: false,
              jitAvailable: jit, experimentalBuild: true,
              includedConsoles: Set(GameConsole.allCases),
              includedInterpreterConsoles: GameLaunchPlan.localInterpreterConsoles)
    }
    func testAutomaticUsesLocalModeWithoutAnActivatedPool() {
        for console in GameLaunchPlan.localInterpreterConsoles {
            let plan = GameLaunchPlan.resolve(console: console, snapshot: facts(), preference: .automatic)
            XCTAssertEqual(plan.mode, .interpreter)
            XCTAssertFalse(plan.usesSharedPreparation)
            XCTAssertTrue(DeviceReadiness(snapshot: facts()).assess(console: console, plan: plan).canAttemptLaunch)
        }
    }
    func testAutomaticReusesActiveJITAndMaximumPerformanceCanRequestIt() {
        for console in GameLaunchPlan.localInterpreterConsoles {
            let ready = GameLaunchPlan.resolve(console: console, snapshot: facts(jit: true), preference: .automatic)
            XCTAssertEqual(ready.mode, .jit)
            XCTAssertTrue(ready.usesSharedPreparation)
            XCTAssertEqual(GameLaunchPlan.resolve(console: console, snapshot: facts(jit: true), preference: .maximumPerformance).mode, .jit)
            let pending = GameLaunchPlan.resolve(console: console, snapshot: facts(), preference: .maximumPerformance)
            XCTAssertEqual(pending.mode, .jit)
            XCTAssertEqual(DeviceReadiness(snapshot: facts()).assess(console: console, plan: pending).status, .requiresJIT)
        }
    }
    func testAutomaticReevaluatesAtNextLaunchWithoutChangingCapturedPlan() {
        for console in GameLaunchPlan.localInterpreterConsoles {
            let local = GameLaunchPlan.resolve(console: console, snapshot: facts(), preference: .automatic)
            let accelerated = GameLaunchPlan.resolve(console: console, snapshot: facts(jit: true), preference: .automatic)
            let afterRestart = GameLaunchPlan.resolve(console: console, snapshot: facts(), preference: .automatic)
            XCTAssertEqual(local.mode, .interpreter)
            XCTAssertEqual(accelerated.mode, .jit)
            XCTAssertEqual(afterRestart, local)
            XCTAssertNotEqual(local.stateNamespace, accelerated.stateNamespace)
        }
    }
    func testMissingInterpreterDoesNotPretendOfflineCapability() {
        var snapshot = facts()
        snapshot.includedInterpreterConsoles.remove(.dreamcast)
        let plan = GameLaunchPlan.resolve(console: .dreamcast, snapshot: snapshot, preference: .automatic)
        XCTAssertEqual(plan.mode, .jit)
        XCTAssertFalse(DeviceReadiness(snapshot: snapshot).assess(console: .dreamcast, plan: plan).canAttemptLaunch)
        let requested = GameLaunchPlan(console: .dreamcast, mode: .interpreter)
        XCTAssertEqual(DeviceReadiness(snapshot: snapshot).assess(console: .dreamcast, plan: requested).status, .unavailable)
    }
    func testInterpreterOSRequirementAndNonJITEntitlementClaim() {
        var snapshot = facts(jit: true)
        snapshot.experimentalBuild = false
        let plan = GameLaunchPlan.resolve(console: .dreamcast, snapshot: snapshot, preference: .automatic)
        XCTAssertEqual(plan.mode, .interpreter)
        snapshot.osVersion = .init(majorVersion: 17, minorVersion: 3, patchVersion: 0)
        XCTAssertFalse(DeviceReadiness(snapshot: snapshot).assess(console: .dreamcast, plan: plan).canAttemptLaunch)
    }
    func testQAOverrideUsesExplicitModeEvenWhenPoolAlreadyReady() {
        let plan = GameLaunchPlan.resolve(console: .wii, snapshot: facts(jit: true), preference: .maximumPerformance, interpreterOverride: true)
        XCTAssertEqual(plan.mode, .interpreter)
        XCTAssertFalse(plan.requiresJIT)
    }
    func testPS2AutomaticRequiresNativeJITEvenWhenWebAssetsAreIncluded() {
        for jit in [false, true] {
            var snapshot = facts(jit: jit)
            snapshot.includedWebAssemblyConsoles = [.ps2]
            for preference in GameLaunchPlan.Preference.allCases {
                let plan = GameLaunchPlan.resolve(console: .ps2, snapshot: snapshot, preference: preference)
                XCTAssertEqual(plan.mode, .jit)
                XCTAssertTrue(plan.requiresJIT)
                XCTAssertTrue(plan.usesSharedPreparation)
                XCTAssertNil(plan.stateNamespace)
                let assessment = DeviceReadiness(snapshot: snapshot).assess(console: .ps2, plan: plan)
                XCTAssertEqual(assessment.status, jit ? .experimental : .requiresJIT)
                XCTAssertEqual(assessment.canAttemptLaunch, jit)
            }
        }
    }
    func testPS2ExplicitOfflineQARequiresItsWebAssets() {
        var snapshot = facts()
        snapshot.includedWebAssemblyConsoles = [.ps2]
        for preference in GameLaunchPlan.Preference.allCases {
            let plan = GameLaunchPlan.resolve(console: .ps2, snapshot: snapshot, preference: preference, interpreterOverride: true)
            XCTAssertEqual(plan.mode, .webAssembly)
            XCTAssertFalse(plan.requiresJIT)
            XCTAssertFalse(plan.usesSharedPreparation)
            XCTAssertTrue(DeviceReadiness(snapshot: snapshot).assess(console: .ps2, plan: plan).canAttemptLaunch)
        }
        snapshot.includedWebAssemblyConsoles = []
        XCTAssertEqual(GameLaunchPlan.resolve(console: .ps2, snapshot: snapshot, preference: .automatic, interpreterOverride: true).mode, .jit)
        XCTAssertEqual(DeviceReadiness(snapshot: snapshot).assess(console: .ps2, plan: .init(console: .ps2, mode: .webAssembly)).status, .unavailable)
    }
    #if VETA_JIT_DEVELOPMENT
    func testPS2CaptureKeepsOnlyTheExactOfflineQAOverride() {
        let old = ProcessInfo.processInfo.environment["VETA_OFFLINE160_CONSOLE"]
        defer {
            if let old { setenv("VETA_OFFLINE160_CONSOLE", old, 1) }
            else { unsetenv("VETA_OFFLINE160_CONSOLE") }
        }
        var snapshot = facts(); snapshot.includedWebAssemblyConsoles = [.ps2]
        let library = Library(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let game = Game(id: "ps2-plan-only", name: "PS2", console: .ps2)
        for value in [nil, "PS2", "psp", "ps2 "] as [String?] {
            if let value { setenv("VETA_OFFLINE160_CONSOLE", value, 1) }
            else { unsetenv("VETA_OFFLINE160_CONSOLE") }
            XCTAssertEqual(GameLaunchPlan.capture(for: game, readiness: .init(snapshot: snapshot), library: library, preference: .automatic).mode, .jit)
        }
        setenv("VETA_OFFLINE160_CONSOLE", "ps2", 1)
        XCTAssertEqual(GameLaunchPlan.capture(for: game, readiness: .init(snapshot: snapshot), library: library, preference: .automatic).mode, .webAssembly)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.root.path))
    }
    #endif
    #if VETA_JIT_DEVELOPMENT
    func testXboxAutoDoesNotConfuseSharedJITPoolWithXboxVerification() {
        var snapshot=facts(jit:true);snapshot.includedInterpreterConsoles.insert(.xbox)
        let local=GameLaunchPlan.resolve(console:.xbox,snapshot:snapshot,preference:.automatic)
        XCTAssertEqual(local.mode,.interpreter);XCTAssertFalse(local.requiresJIT)
        XCTAssertEqual(GameLaunchPlan.resolve(console:.xbox,snapshot:snapshot,preference:.maximumPerformance).mode,.jit)
        XCTAssertEqual(GameLaunchPlan.resolve(console:.xbox,snapshot:snapshot,preference:.maximumPerformance,interpreterOverride:true).mode,.interpreter)
        snapshot.includedInterpreterConsoles.remove(.xbox)
        XCTAssertEqual(GameLaunchPlan.resolve(console:.xbox,snapshot:snapshot,preference:.automatic,interpreterOverride:true).mode,.jit)
    }
    #endif
    func testInterpreterPreflightStillRejectsMissingContent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = Library(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let game = Game(id: "missing-content", name: "Missing", console: .wii)
        let plan = GameLaunchPlan.resolve(console: .wii, snapshot: facts(), preference: .automatic)
        XCTAssertFalse(DeviceReadiness(snapshot: facts()).preflight(game: game, library: library, plan: plan).canLaunch)
    }
    func testModeStatesDoNotReplaceLegacyAutoOrGuestSDAndRejectCrossModeImport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = Library(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let game = Game(id: "state-isolation", name: "Wii", console: .wii)
        let plan = GameLaunchPlan(console: .wii, mode: .interpreter)
        let old = try StateFile.encode(Data([1, 2, 3]), rom: game.id, core: game.coreID)
        try FileManager.default.createDirectory(at: library.stateDirectory(game), withIntermediateDirectories: true)
        try old.write(to: library.file(game, "auto.vstate"))
        let sd = try library.prepareCoreSaves(for: game).appendingPathComponent("User/Load/WiiSD.raw")
        try FileManager.default.createDirectory(at: sd.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([7, 8, 9]).write(to: sd)
        let directory = library.stateDirectory(game, plan: plan)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("auto.vstate").path))
        let new = try StateFile.encode(Data([4, 5, 6]), rom: game.id, core: plan.stateCoreID(for: game))
        try library.restoreExecutionStates([try XCTUnwrap(plan.stateNamespace): ["auto": new]], game: game)
        XCTAssertEqual(try Data(contentsOf: library.file(game, "auto.vstate")), old)
        XCTAssertEqual(try Data(contentsOf: sd), Data([7, 8, 9]))
        XCTAssertEqual(try library.archiveExecutionStates(game)?[try XCTUnwrap(plan.stateNamespace)]?["auto"], new)
        XCTAssertThrowsError(try library.validateExecutionStates([try XCTUnwrap(plan.stateNamespace): ["auto": old]], game: game))
        XCTAssertThrowsError(try library.validateExecutionStates(["../outside": ["auto": new]], game: game))
    }

    func test3DSMigrationPreservesPayloadAndOriginalAndNeverReplacesNewProgress() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = Library(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let game = Game(id: "3ds-migration", name: "3DS", console: .threeDS)
        let plan = GameLaunchPlan(console: .threeDS, mode: .interpreter)
        let profile = CoreProfile()
        let payload = Data(repeating: 42, count: 8192)
        let original = try StateFile.encode(payload, rom: game.id, core: game.coreID, optionsFingerprint: profile.fingerprint, optionsSnapshot: profile.values)
        try FileManager.default.createDirectory(at: library.stateDirectory(game), withIntermediateDirectories: true)
        let source = library.file(game, "auto.vstate")
        try original.write(to: source)
        XCTAssertFalse(try library.migrateLegacy3DSAuto(game, plan: plan, optionsFingerprint: profile.fingerprint, isRenderQA: true))
        XCTAssertTrue(try library.migrateLegacy3DSAuto(game, plan: plan, optionsFingerprint: profile.fingerprint, isRenderQA: false))
        let store = NativeSaveStore(directory: library.stateDirectory(game, plan: plan), rom: game.id, core: plan.stateCoreID(for: game))
        let migrated = try store.read("auto")
        XCTAssertEqual(try StateFile.decode(migrated, rom: game.id, core: plan.stateCoreID(for: game), optionsFingerprint: profile.fingerprint), payload)
        let before = try JSONDecoder().decode(StateFile.self, from: original)
        let after = try JSONDecoder().decode(StateFile.self, from: migrated)
        XCTAssertEqual(before.bytes, after.bytes)
        XCTAssertEqual(before.digest, after.digest)
        XCTAssertEqual(before.createdAt, after.createdAt)
        XCTAssertEqual(try Data(contentsOf: source), original)
        let newer = try StateFile.encode(Data([8, 9]), rom: game.id, core: plan.stateCoreID(for: game), optionsFingerprint: profile.fingerprint)
        try store.write(newer, slot: "auto")
        XCTAssertFalse(try library.migrateLegacy3DSAuto(game, plan: plan, optionsFingerprint: profile.fingerprint, isRenderQA: false))
        XCTAssertEqual(try store.read("auto"), newer)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func test3DSMigrationRejectsWrongROMProfileAndUnversionedOptionsWithoutChangingSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = Library(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let game = Game(id: "3ds-migration-invalid", name: "3DS", console: .threeDS)
        let plan = GameLaunchPlan(console: .threeDS, mode: .interpreter)
        let profile = CoreProfile()
        try FileManager.default.createDirectory(at: library.stateDirectory(game), withIntermediateDirectories: true)
        let source = library.file(game, "auto.vstate")
        let candidates = [
            try StateFile.encode(Data([1]), rom: "other-rom", core: game.coreID, optionsFingerprint: profile.fingerprint),
            try StateFile.encode(Data([1]), rom: game.id, core: "other-core", optionsFingerprint: profile.fingerprint),
            try StateFile.encode(Data([1]), rom: game.id, core: game.coreID, optionsFingerprint: String(repeating: "0", count: 64)),
            try StateFile.encode(Data([1]), rom: game.id, core: game.coreID)
        ]
        for candidate in candidates {
            try candidate.write(to: source)
            XCTAssertThrowsError(try library.migrateLegacy3DSAuto(game, plan: plan, optionsFingerprint: profile.fingerprint, isRenderQA: false))
            XCTAssertEqual(try Data(contentsOf: source), candidate)
            XCTAssertFalse(FileManager.default.fileExists(atPath: library.stateDirectory(game, plan: plan).appendingPathComponent("auto.vstate").path))
        }
    }
    private func webState(gameID:String,format:String=WebEngineArchive.stateFormat)throws->Data {
        let payload=Data([0x50,0x4b,0x03,0x04,1,2,3])
        let meta=WebEngineArchive.StateMetadata(version:1,gameID:gameID,format:format,sha256:sha256(payload),bytes:payload.count,createdAt:Date(timeIntervalSince1970:100))
        let json=try JSONEncoder().encode(meta),count=UInt32(json.count)
        var result=Data("VETAPSW1".utf8)
        result.append(contentsOf:[UInt8(count>>24),UInt8((count>>16)&255),UInt8((count>>8)&255),UInt8(count&255)])
        result.append(json);result.append(payload);return result
    }
    private func webArchive(_ game:Game)throws->WebEngineArchive {
        let card=Data([1,2,3]),index=WebEngineArchive.StorageIndex(files:[.init(path:"vfs/mc0/save/data",size:card.count)])
        let entries:[String:Data]=["files/vfs/mc0/save/data":card,"files/vfs/mc1/save/data":Data([4]),
            "files/vfs/mc0/save/.veta-previous-"+sha256(Data("data".utf8)):Data([8]),
            "files/.veta-manifest.json":try JSONEncoder().encode(index),
            "files.previous/vfs/mc0/save/data":card,"files.previous/.veta-manifest.json":try JSONEncoder().encode(index),
            "states/auto.state":try webState(gameID:game.id),"states/quick.previous.state":try webState(gameID:game.id)]
        return WebEngineArchive(version:1,engine:WebEngineArchive.engineID,gameID:game.id,files:entries.mapValues{.init(digest:sha256($0),bytes:$0)})
    }
    func testPS2WebBackupRoundTripAndExistingNamespaceWins()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library=Library(root:root.appendingPathComponent("source"))
        defer{try? FileManager.default.removeItem(at:root)}
        var bytes=Data(repeating:0,count:64);bytes.replaceSubrange(0..<4,with:[0x7f,0x45,0x4c,0x46]);bytes[4]=1;bytes[5]=1;bytes[18]=8
        let source=root.appendingPathComponent("fixture.elf");try bytes.write(to:source)
        let game=try library.importNativeFile(source,console:.ps2),archive=try webArchive(game)
        try library.restoreWebEngineStorage(archive,game:game)
        XCTAssertThrowsError(try library.restoreWebEngineStorage(archive,game:game))
        let backup=try library.export();defer{try? FileManager.default.removeItem(at:backup)}
        let envelope=try JSONDecoder().decode(NativeBackup.self,from:Data(contentsOf:backup))
        XCTAssertEqual(envelope.version,6);XCTAssertNotNil(envelope.entries.first?.webEngineStorage)
        let restored=Library(root:root.appendingPathComponent("restored"));try restored.importURL(backup)
        let result=try XCTUnwrap(restored.archiveWebEngineStorage(game))
        XCTAssertEqual(result.files.mapValues(\.bytes),archive.files.mapValues(\.bytes))
        // Reimport skips an existing game rather than resetting its offline card.
        let card=restored.directory(game.id).appendingPathComponent("engines/play-web-v1/files/vfs/mc0/save/data")
        let progress=Data([9,9,9]);try progress.write(to:card)
        try restored.importURL(backup);XCTAssertEqual(try Data(contentsOf:card),progress)
        var oldEntry=try XCTUnwrap(envelope.entries.first);oldEntry.webEngineStorage=nil
        let legacy=try JSONEncoder().encode(NativeBackup(format:"veta-native",version:5,entries:[oldEntry]))
        XCTAssertNil(try JSONDecoder().decode(NativeBackup.self,from:legacy).entries.first?.webEngineStorage)
        let oldURL=root.appendingPathComponent("legacy.vetaretro");try legacy.write(to:oldURL)
        let oldLibrary=Library(root:root.appendingPathComponent("legacy"));try oldLibrary.importURL(oldURL)
        XCTAssertNil(try oldLibrary.archiveWebEngineStorage(game))
    }
    func testPS2WebArchiveRejectsTraversalIdentityDigestsAndStateABI()throws {
        let game=Game(id:String(repeating:"a",count:64),name:"PS2",console:.ps2),archive=try webArchive(game)
        func changed(_ files:[String:WebEngineArchive.File])->WebEngineArchive {.init(version:1,engine:archive.engine,gameID:game.id,files:files)}
        for path in ["../outside","files/vfs/mc0/../escape","files/vfs/mc0//save","files/vfs/mc0/\\escape","states/other.state","files/.veta-arbitrary"] {
            var files=archive.files;files[path] = .init(digest:sha256(Data()),bytes:Data())
            XCTAssertThrowsError(try changed(files).validate(game:game))
        }
        var files=archive.files;files["files/vfs/mc0/save/data"] = .init(digest:String(repeating:"0",count:64),bytes:Data([1,2,3]))
        XCTAssertThrowsError(try changed(files).validate(game:game))
        XCTAssertThrowsError(try archive.validate(game:Game(id:String(repeating:"b",count:64),name:"Other",console:.ps2)))
        XCTAssertThrowsError(try WebEngineArchive(version:1,engine:"other-engine",gameID:game.id,files:archive.files).validate(game:game))
        for invalid in [try webState(gameID:String(repeating:"b",count:64)),try webState(gameID:game.id,format:"other-abi")] {
            files=archive.files;files["states/auto.state"] = .init(digest:sha256(invalid),bytes:invalid)
            XCTAssertThrowsError(try changed(files).validate(game:game))
        }
        var corrupt=try webState(gameID:game.id);corrupt[corrupt.count-1] ^= 1
        files=archive.files;files["states/auto.state"] = .init(digest:sha256(corrupt),bytes:corrupt)
        XCTAssertThrowsError(try changed(files).validate(game:game),"Inner payload digest must be checked independently")
        files=archive.files;files["files/vfs/mc0/save/Data"] = files["files/vfs/mc0/save/data"]
        XCTAssertThrowsError(try changed(files).validate(game:game))
    }
    func testPS2ManualGalleryBackupPreservesNamePreviewAndProtection() throws {
        let game = Game(id: String(repeating: "a", count: 64), name: "PS2", console: .ps2)
        let payload = Data([0x50,0x4b,0x03,0x04,5,6,7])
        var state = try JSONDecoder().decode(StateFile.self, from: StateFile.encode(payload, rom: game.id, core: WebEngineArchive.stateFormat, thumbnail: Data([1,2])))
        state.name = "Final"; state.protected = true
        let data = try JSONEncoder().encode(state)
        let archive = WebEngineArchive(version: 1, engine: WebEngineArchive.engineID, gameID: game.id,
                                      files: ["manual-saves/slot3.vstate": .init(digest: sha256(data), bytes: data)])
        try archive.validate(game: game)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = Library(root: root)
        try library.restoreWebEngineStorage(archive, game: game)
        XCTAssertEqual(try library.archiveWebEngineStorage(game)?.files["manual-saves/slot3.vstate"]?.bytes, data)
        for path in ["manual-saves/slot9.vstate", "manual-saves/../slot1.vstate"] {
            XCTAssertThrowsError(try WebEngineArchive(version: 1, engine: archive.engine, gameID: game.id,
                files: [path: .init(digest: sha256(data), bytes: data)]).validate(game: game))
        }
        let incompatible = try StateFile.encode(payload, rom: game.id, core: "different-engine")
        XCTAssertThrowsError(try WebEngineArchive(version: 1, engine: archive.engine, gameID: game.id,
            files: ["manual-saves/slot3.vstate": .init(digest: sha256(incompatible), bytes: incompatible)]).validate(game: game))
    }
    func testPS2ManualServerRequiresPreviewAndPreservesProtectedSlot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let disc = root.appendingPathComponent("disc.elf")
        try Data([1,2,3,4]).write(to: disc)
        let server = PS2WebServer(html: Data(), assets: root, disc: disc,
                                  storage: root.appendingPathComponent("storage"), gameID: "fixture", stateFormat: WebEngineArchive.stateFormat)
        let url = try await server.start()
        defer { server.stop() }
        let payload = Data([0x50,0x4b,0x03,0x04,5,6,7])
        func request(_ slot: String, put: Bool = true) async throws -> (Data, Int) {
            var request = URLRequest(url: url.appendingPathComponent("state/"+slot))
            request.httpMethod = put ? "PUT" : "GET"
            if put { request.httpBody = payload }
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as! HTTPURLResponse).statusCode)
        }
        let missing = try await request("slot1")
        XCTAssertEqual(missing.1, 409)
        try await server.stageManualPreview(Data([9,8]), slot: "slot1")
        let saved = try await request("slot1")
        XCTAssertEqual(saved.1, 204)
        let loaded = try await request("slot1", put: false)
        XCTAssertEqual(loaded.1, 200); XCTAssertEqual(loaded.0, payload)
        let store = server.manualSaveStore
        XCTAssertEqual(store.list().first(where: { $0.id == "slot1" })?.state?.thumbnail, Data([9,8]))
        try store.rename("slot1", name: "Prueba"); try store.protect("slot1", enabled: true)
        let before = try store.read("slot1")
        try await server.stageManualPreview(Data([7]), slot: "slot1")
        let protected = try await request("slot1")
        XCTAssertNotEqual(protected.1, 204); XCTAssertEqual(try store.read("slot1"), before)
        let unknown = try await request("slot9", put: false)
        XCTAssertEqual(unknown.1, 404)
    }
    func testPS2WebArchiveRejectsSymlinksAndOversizeFilesBeforeReading()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),library=Library(root:root.appendingPathComponent("library"))
        defer{try? FileManager.default.removeItem(at:root)}
        let game=Game(id:String(repeating:"a",count:64),name:"PS2",console:.ps2),archive=try webArchive(game)
        let engines=library.directory(game.id).appendingPathComponent("engines")
        try FileManager.default.createDirectory(at:engines.deletingLastPathComponent(),withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(at:engines,withDestinationURL:root.appendingPathComponent("missing"))
        XCTAssertThrowsError(try library.restoreWebEngineStorage(archive,game:game))
        XCTAssertThrowsError(try library.archiveWebEngineStorage(game))
        try FileManager.default.removeItem(at:engines);try library.restoreWebEngineStorage(archive,game:game)
        let storage=engines.appendingPathComponent(WebEngineArchive.engineID),card=storage.appendingPathComponent("files/vfs/mc0/save/data")
        try FileManager.default.removeItem(at:card)
        try FileManager.default.createSymbolicLink(at:card,withDestinationURL:root.appendingPathComponent("missing"))
        XCTAssertThrowsError(try library.archiveWebEngineStorage(game))
        try FileManager.default.removeItem(at:card)
        XCTAssertTrue(FileManager.default.createFile(atPath:card.path,contents:nil))
        let handle=try FileHandle(forWritingTo:card);try handle.truncate(atOffset:64*1024*1024+1);try handle.close()
        XCTAssertThrowsError(try library.archiveWebEngineStorage(game))
    }
}
