import XCTest
import UIKit
#if VETA_JIT_DEVELOPMENT
@testable import VetaJITLab
#else
@testable import VetaNative
#endif

@MainActor final class ProfileSaveTests: XCTestCase {
    private var temp: URL!
    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        veta_options_clear()
    }
    override func tearDownWithError() throws {
        veta_unload(); veta_options_clear(); try? FileManager.default.removeItem(at: temp)
    }
    func testProfilesResolvePrecedenceRejectUnknownAndPersist() throws {
        let console = CoreProfile(values: [CoreOptionID.nesRegion.rawValue: "PAL"])
        let game = CoreProfile(values: [CoreOptionID.nesRegion.rawValue: "NTSC"])
        XCTAssertEqual(try CoreProfile.resolved(console: .nes, consoleProfile: console, gameProfile: game).values, game.values)
        XCTAssertEqual(try CoreProfile.resolved(console: .nes, consoleProfile: console, gameProfile: CoreProfile()).values, console.values)
        XCTAssertThrowsError(try CoreProfile(values: ["jit": "enabled"]).validated(for: .nes))
        XCTAssertThrowsError(try CoreProfile(values: [CoreOptionID.pspResolution.rawValue: "480x272"]).validated(for: .nes))
        XCTAssertThrowsError(try CoreProfile(values: [CoreOptionID.pspResolution.rawValue: "99999x99999"]).validated(for: .psp))
        XCTAssertThrowsError(try CoreProfile(version: 2).validated(for: .nes))
        let library = Library(root: temp), entry = Game(id: "fixture", name: "Fixture")
        try FileManager.default.createDirectory(at: library.directory(entry.id), withIntermediateDirectories: true)
        let store = GameProfileStore(library: library, game: entry)
        try store.write(console, console: true); try store.write(game, console: false)
        XCTAssertEqual(try store.resolved(), game)
        try store.write(CoreProfile(), console: false)
        XCTAssertEqual(try store.resolved(), console)
        let before = try Data(contentsOf: store.url(console: true))
        XCTAssertThrowsError(try store.write(CoreProfile(values: ["unknown": "yes"]), console: true))
        XCTAssertEqual(try Data(contentsOf: store.url(console: true)), before)
    }
    func testRealNESProfileAppliedOnceAndDoesNotLeakToNextLoad() throws {
        let fixture = try XCTUnwrap(Bundle(for: ProfileSaveTests.self).url(forResource: "thwaite", withExtension: "nes"))
        XCTAssertFalse(veta_option_set("dolphin_cpu_core", "4"))
        XCTAssertFalse(veta_option_set("fceumm_region", "invalid"))
        try CoreProfile(values: [CoreOptionID.nesRegion.rawValue: "PAL"]).installForNextLoad()
        XCTAssertTrue(veta_load(fixture.path, temp.path, "NTSC"))
        for _ in 0..<3 { veta_run() }
        XCTAssertEqual(veta_fps(), 50, accuracy: 0.1)
        veta_unload()
        XCTAssertTrue(veta_load(fixture.path, temp.path, "NTSC"))
        for _ in 0..<3 { veta_run() }
        XCTAssertGreaterThan(veta_fps(), 60)
    }
    func testStateProfileCompatibilityAndLegacyRemainReadable() throws {
        let raw = Data(repeating: 0x4e, count: 30000)
        let profile = CoreProfile(values: [CoreOptionID.nesRegion.rawValue: "PAL"])
        let encoded = try StateFile.encode(raw, rom: "rom", optionsFingerprint: profile.fingerprint)
        XCTAssertEqual(try StateFile.decode(encoded, rom: "rom", optionsFingerprint: profile.fingerprint), raw)
        XCTAssertThrowsError(try StateFile.decode(encoded, rom: "rom", optionsFingerprint: CoreProfile().fingerprint))
        XCTAssertThrowsError(try StateFile.decode(encoded, rom: "other", optionsFingerprint: profile.fingerprint))
        let v2 = try StateFile.encode(raw, rom: "rom")
        XCTAssertEqual(try StateFile.decode(v2, rom: "rom", optionsFingerprint: profile.fingerprint), raw)
        let v1 = StateFile(version: 1, core: StateFile.coreID, rom: "rom", digest: sha256(raw), bytes: raw)
        XCTAssertEqual(try StateFile.decode(JSONEncoder().encode(v1), rom: "rom", optionsFingerprint: profile.fingerprint), raw)
        var broken = try JSONDecoder().decode(StateFile.self, from: encoded)
        broken.optionsFingerprint = nil
        XCTAssertThrowsError(try StateFile.decode(JSONEncoder().encode(broken), rom: "rom"))
    }
    func testProtectedSlotsRecoveryCopiesAndPathBounds() throws {
        let store = NativeSaveStore(directory: temp, rom: "rom", core: StateFile.coreID)
        let first = try StateFile.encode(Data([1,2,3]), rom: "rom", optionsFingerprint: CoreProfile().fingerprint)
        let second = try StateFile.encode(Data([4,5,6]), rom: "rom", optionsFingerprint: CoreProfile().fingerprint)
        try store.write(first, slot: "slot1"); try store.protect("slot1", enabled: true)
        let protected = try store.read("slot1")
        XCTAssertThrowsError(try store.write(second, slot: "slot1"))
        XCTAssertThrowsError(try store.delete("slot1"))
        XCTAssertEqual(try store.read("slot1"), protected)
        try store.protect("slot1", enabled: false); try store.write(second, slot: "slot1")
        try store.write(first, slot: "auto"); try store.write(second, slot: "auto")
        XCTAssertEqual(try store.read("previous-auto"), first)
        XCTAssertEqual(try store.read("auto"), second)
        XCTAssertThrowsError(try store.write(first, slot: "../escape"))
        XCTAssertThrowsError(try store.write(first, slot: "before-load"))
        XCTAssertThrowsError(try store.protect("auto", enabled: true))
        XCTAssertThrowsError(try store.write(Data("invalid".utf8), slot: "auto"))
        XCTAssertEqual(try store.read("auto"), second)
        XCTAssertEqual(store.list().filter { $0.state != nil }.count, 3)
        try store.delete("slot1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.url("slot1").path))
    }
    func testNamedSavePreservesPayloadPreviewAndReplacementIdentity() throws {
        let store = NativeSaveStore(directory: temp, rom: "rom", core: StateFile.coreID)
        let first = try StateFile.encode(Data([1,2,3]), rom: "rom", thumbnail: Data([7]))
        try store.write(first, slot: "slot1")
        try store.protect("slot1", enabled: true)
        let original = try JSONDecoder().decode(StateFile.self, from: store.read("slot1"))
        try store.rename("slot1", name: "  Antes del jefe 🏁  ")
        let renamed = try JSONDecoder().decode(StateFile.self, from: store.read("slot1"))
        XCTAssertEqual(renamed.name, "Antes del jefe 🏁")
        XCTAssertEqual(renamed.bytes, original.bytes)
        XCTAssertEqual(renamed.thumbnail, original.thumbnail)
        XCTAssertEqual(renamed.createdAt, original.createdAt)
        XCTAssertEqual(renamed.protected, true)
        let unchanged = try store.read("slot1")
        for invalid in [String(repeating: "a", count: 81), "dos\nlíneas"] {
            XCTAssertThrowsError(try store.rename("slot1", name: invalid))
            XCTAssertEqual(try store.read("slot1"), unchanged)
        }
        XCTAssertThrowsError(try store.rename("../slot1", name: "Escape"))
        XCTAssertThrowsError(try store.rename("auto", name: "Auto"))
        try store.protect("slot1", enabled: false)
        let second = try StateFile.encode(Data([4,5,6]), rom: "rom", thumbnail: Data([8]))
        try store.write(second, slot: "slot1")
        let replaced = try JSONDecoder().decode(StateFile.self, from: store.read("slot1"))
        XCTAssertEqual(replaced.name, renamed.name)
        XCTAssertEqual(replaced.thumbnail, Data([8]))
        XCTAssertEqual(try StateFile.decode(store.read("slot1"), rom: "rom"), Data([4,5,6]))
        XCTAssertEqual(store.list().first(where: { $0.id == "slot1" })?.displayTitle, renamed.name)
        try store.rename("slot1", name: "  ")
        XCTAssertNil(try JSONDecoder().decode(StateFile.self, from: store.read("slot1")).name)
    }
    func testBackupPreservesSlotsProtectionAndResolvedProfile() throws {
        let library = Library(root: temp.appendingPathComponent("original"))
        let fixture = try XCTUnwrap(Bundle(for: ProfileSaveTests.self).url(forResource: "thwaite", withExtension: "nes"))
        let game = try library.add(data: Data(contentsOf: fixture), name: "Fixture")
        let profile = CoreProfile(values: [CoreOptionID.nesRegion.rawValue: "PAL"])
        try GameProfileStore(library: library, game: game).write(profile, console: true)
        let store = NativeSaveStore(directory: library.directory(game.id), rom: game.id, core: game.console.coreID)
        try store.write(StateFile.encode(Data([7,8]), rom: game.id, optionsFingerprint: profile.fingerprint), slot: "slot3")
        try store.protect("slot3", enabled: true)
        let archive = try library.export(); defer { try? FileManager.default.removeItem(at: archive) }
        let restored = Library(root: temp.appendingPathComponent("restored"))
        try restored.importURL(archive)
        let restoredGame = try XCTUnwrap(restored.games.first)
        XCTAssertEqual(try GameProfileStore(library: restored, game: restoredGame).resolved(), profile)
        let loadedStore = NativeSaveStore(directory: restored.directory(game.id), rom: game.id, core: game.console.coreID)
        XCTAssertEqual(try loadedStore.read("slot3"), try store.read("slot3"))
        XCTAssertThrowsError(try loadedStore.delete("slot3"))
    }
    func testFourPortBridgeBoundsAndCoreCapabilities() {
        XCTAssertEqual(veta_max_players(GameConsole.n64.coreIndex), 4)
        XCTAssertEqual(veta_max_players(GameConsole.gamecube.coreIndex), 4)
        XCTAssertEqual(veta_max_players(GameConsole.gba.coreIndex), 1)
        XCTAssertEqual(veta_max_players(GameConsole.nes.coreIndex), 2)
        XCTAssertEqual(veta_max_players(20), 1)
        for port: UInt32 in 0..<4 { veta_set_input(port, UInt16(port+1)); XCTAssertEqual(veta_input_mask(port), UInt16(port+1)) }
        veta_set_input(4, 99); XCTAssertEqual(veta_input_mask(4), 0)
        veta_unload()
        for port: UInt32 in 0..<4 { XCTAssertEqual(veta_input_mask(port), 0); XCTAssertEqual(veta_rumble_strength(port, 0), 0) }
    }
    func testRejectedCorePayloadRecoversCurrentNESState() throws {
        let library = Library(root: temp.appendingPathComponent("rollback"))
        let fixture = try XCTUnwrap(Bundle(for: ProfileSaveTests.self).url(forResource: "thwaite", withExtension: "nes"))
        let game = try library.add(data: Data(contentsOf: fixture), name: "Rollback fixture")
        let screen = MetalScreen()
        try XCTSkipUnless(screen.ready, "Metal is required for the real Emulation integration")
        let emulation = Emulation(game: game, library: library)
        emulation.open(screen: screen); defer { emulation.close() }
        XCTAssertTrue(emulation.ready, emulation.error ?? "Core failed to open")
        emulation.pause()
        func snapshot() throws -> Data {
            var bytes = Data(count: veta_state_size())
            guard bytes.count > 0, bytes.withUnsafeMutableBytes({ veta_save_state($0.baseAddress, $0.count) }) else { throw VetaError.message("Fixture did not serialize") }
            return bytes
        }
        let before = try snapshot()
        var invalid = before
        // Correct ROM, envelope checksum and profile; deliberately invalid core
        // header. This reaches the native rejection/rollback path, unlike a
        // corrupt JSON or checksum which must be rejected before core mutation.
        invalid.replaceSubrange(0..<min(16, invalid.count), with: Data(repeating: 0, count: min(16, invalid.count)))
        let envelope = try StateFile.encode(invalid, rom: game.id, core: game.console.coreID, optionsFingerprint: emulation.activeOptionsFingerprint)
        try emulation.saveStore.write(envelope, slot: "slot2")
        XCTAssertThrowsError(try emulation.restore("slot2"))
        XCTAssertTrue(emulation.ready, "A rejected state should recover the prior session")
        XCTAssertEqual(try snapshot(), before)
        let recovery = try emulation.saveStore.read("before-load")
        XCTAssertEqual(try StateFile.decode(recovery, rom: game.id, core: game.console.coreID, optionsFingerprint: emulation.activeOptionsFingerprint), before)
    }

    func testRecoveryCopyFailureResumesUntouchedSession() throws {
        try XCTSkipUnless(UIApplication.shared.applicationState == .active,"Active test host required")
        let library=Library(root:temp.appendingPathComponent("recovery-write-failure"))
        let fixture=try XCTUnwrap(Bundle(for:ProfileSaveTests.self).url(forResource:"thwaite",withExtension:"nes"))
        let game=try library.add(data:Data(contentsOf:fixture),name:"Recovery write fixture")
        let screen=MetalScreen();try XCTSkipUnless(screen.ready,"Metal required")
        let emulation=Emulation(game:game,library:library)
        emulation.open(screen:screen);defer {emulation.close()}
        XCTAssertTrue(emulation.running,emulation.error ?? "Expected running session")
        try emulation.save("slot1")
        let recovery=try emulation.saveStore.url("before-load")
        try FileManager.default.createDirectory(at:recovery,withIntermediateDirectories:false)
        // This fails before veta_load_state; the prior engine must remain usable
        // and its display/audio lifecycle must resume automatically.
        veta_set_input(0,8);for _ in 0..<60 {veta_run()};veta_set_input(0,0)
        var prior=Data(count:veta_state_size())
        XCTAssertTrue(prior.withUnsafeMutableBytes {veta_save_state($0.baseAddress,$0.count)})
        let frames=veta_frame_count()
        XCTAssertThrowsError(try emulation.restore("slot1"))
        XCTAssertTrue(emulation.ready);XCTAssertTrue(emulation.running)
        // Resuming primes audio with actual frames. Compare against the same
        // advancement from the pre-failure snapshot, not a frozen frame counter.
        let advanced=veta_frame_count()-frames
        let actual=Data(bytes:veta_video(),count:Int(veta_width()*veta_height()*4))
        emulation.pause()
        XCTAssertTrue(prior.withUnsafeBytes {veta_load_state($0.baseAddress,$0.count)})
        for _ in 0..<advanced {veta_run()}
        XCTAssertEqual(actual,Data(bytes:veta_video(),count:Int(veta_width()*veta_height()*4)))
        try FileManager.default.removeItem(at:recovery)
    }
    func testDSEngineIsolationAndBackupKeepsBothEngines() throws {
        let library=Library(root:temp.appendingPathComponent("ds-engines"))
        var rom=Data(repeating:0,count:1024)
        func put(_ offset:Int,_ value:UInt32) {for i in 0..<4 {rom[offset+i]=UInt8((value >> (i*8)) & 255)}}
        put(0x20,512);put(0x2c,32);put(0x30,544);put(0x3c,32)
        let original=try library.add(data:rom,name:"DS storage fixture",console:.ds)
        XCTAssertEqual(original.dsEngine,.desmume)
        let oldState=try StateFile.encode(Data([1,2,3]),rom:original.id,core:original.coreID)
        try NativeSaveStore(directory:library.stateDirectory(original),rom:original.id,core:original.coreID).write(oldState,slot:"quick")
        var latest=original;latest.favorite=true;latest.lastPlayed=Date(timeIntervalSince1970:123456)
        library.update(latest)
        // The settings sheet may still hold the original Game value. Changing
        // only its engine must retain newer favorite/history metadata.
        try library.setDSEngine(.melonDS,for:original)
        let alternate=try XCTUnwrap(library.games.first)
        XCTAssertTrue(alternate.favorite);XCTAssertEqual(alternate.lastPlayed,latest.lastPlayed)
        XCTAssertEqual(alternate.coreIndex,20);XCTAssertNotEqual(alternate.coreID,original.coreID)
        XCTAssertEqual(library.romURL(alternate),library.romURL(original))
        XCTAssertNotEqual(library.file(alternate,"quick.vstate"),library.file(original,"quick.vstate"))
        _ = try library.prepareSessionSaves(for:alternate)
        let newState=try StateFile.encode(Data([4,5,6]),rom:alternate.id,core:alternate.coreID)
        try NativeSaveStore(directory:library.stateDirectory(alternate),rom:alternate.id,core:alternate.coreID).write(newState,slot:"quick")
        XCTAssertEqual(try Data(contentsOf:library.file(original,"quick.vstate")),oldState)
        XCTAssertThrowsError(try StateFile.decode(newState,rom:original.id,core:original.coreID))
        let archive=try library.export();defer {try? FileManager.default.removeItem(at:archive)}
        let restored=Library(root:temp.appendingPathComponent("ds-restored"));try restored.importURL(archive)
        let current=try XCTUnwrap(restored.games.first)
        XCTAssertEqual(current.dsEngine,.melonDS)
        XCTAssertEqual(try Data(contentsOf:restored.file(current,"quick.vstate")),newState)
        var previous=current;previous.dsEngine = .desmume
        XCTAssertEqual(try Data(contentsOf:restored.file(previous,"quick.vstate")),oldState)
        XCTAssertThrowsError(try restored.validateEngineArchive(EngineSaveArchive(engine:.melonDS,states:["quick":newState],ram:nil,rtc:nil,coreSaves:nil),game:current))
    }
    func testBackupPublishFailureCanRetryAndPreservesExistingGames() throws {
        let fixture=try XCTUnwrap(Bundle(for:ProfileSaveTests.self).url(forResource:"thwaite",withExtension:"nes"))
        let rom=try Data(contentsOf:fixture)
        let source=Library(root:temp.appendingPathComponent("backup-source"))
        let game=try source.add(data:rom,name:"Backup game")
        let state=try StateFile.encode(Data([7,8,9]),rom:game.id,core:game.coreID)
        try NativeSaveStore(directory:source.stateDirectory(game),rom:game.id,core:game.coreID).write(state,slot:"slot3")
        let backup=try source.export();defer {try? FileManager.default.removeItem(at:backup)}
        let target=Library(root:temp.appendingPathComponent("backup-target"))
        var otherROM=rom;otherROM[otherROM.count-1] ^= 1
        let existing=try target.add(data:otherROM,name:"Keep existing")
        let index=target.root.appendingPathComponent("library.json"),indexData=try Data(contentsOf:index)
        // A directory where the atomic index file belongs forces failure after
        // all staged ROM/profile/state writes and the final directory move.
        try FileManager.default.removeItem(at:index)
        try FileManager.default.createDirectory(at:index,withIntermediateDirectories:false)
        XCTAssertThrowsError(try target.importURL(backup))
        XCTAssertEqual(target.games.map(\.id),[existing.id])
        XCTAssertEqual(try Data(contentsOf:target.romURL(existing)),otherROM)
        XCTAssertFalse(FileManager.default.fileExists(atPath:target.directory(game.id).path))
        try FileManager.default.removeItem(at:index);try indexData.write(to:index,options:.atomic)
        try target.importURL(backup)
        XCTAssertEqual(Set(target.games.map(\.id)),Set([existing.id,game.id]))
        XCTAssertEqual(try Data(contentsOf:target.file(game,"slot3.vstate")),state)
        // Recover an interrupted publication after process termination without
        // deleting an already indexed entry or its game files.
        let journal=target.root.appendingPathComponent(".backup-import-test")
        try FileManager.default.createDirectory(at:journal,withIntermediateDirectories:true)
        try Data(game.id.utf8).write(to:journal.appendingPathComponent("moving-game"))
        let reopened=Library(root:target.root)
        XCTAssertEqual(reopened.games.count,2)
        XCTAssertEqual(try Data(contentsOf:reopened.file(game,"slot3.vstate")),state)
        XCTAssertFalse(FileManager.default.fileExists(atPath:journal.path))
    }
    func testMelonDSAlternativeRealFixtureStateAndTouch() throws {
        let docs=PhysicalFixturePaths.root.appendingPathComponent("EngineFixtures")
        let fixture=docs.appendingPathComponent("flappy.nds")
        try XCTSkipUnless(FileManager.default.fileExists(atPath:fixture.path),"Author-provided Flappy DS fixture required")
        XCTAssertTrue(veta_load_system(fixture.path,temp.path,temp.path,"Auto",20))
        defer {veta_unload()}
        for _ in 0..<360 {veta_run()}
        XCTAssertEqual(veta_width(),256);XCTAssertEqual(veta_height(),384)
        XCTAssertGreaterThan(veta_audio_count(),10000)
        func image()->Data {Data(bytes:veta_video(),count:Int(veta_width()*veta_height()*4))}
        let boot=image()
        veta_set_pointer(0,16384,true);veta_set_input(0,8);for _ in 0..<3 {veta_run()}
        veta_set_pointer(0,0,false);veta_set_input(0,0);for _ in 0..<120 {veta_run()}
        XCTAssertNotEqual(image(),boot)
        XCTAssertGreaterThan(veta_audio_nonzero(),1000,"FreeBIOS must execute sound routines across direct-boot protection")
        print("VETA_MELONDS_ACTIVE: frames=\(veta_frame_count()) audio=\(veta_audio_count()) nonzero=\(veta_audio_nonzero())")
        var saved=Data(count:veta_state_size());XCTAssertFalse(saved.isEmpty)
        XCTAssertTrue(saved.withUnsafeMutableBytes{veta_save_state($0.baseAddress,$0.count)})
        for _ in 0..<20 {veta_run()};let expected=image()
        XCTAssertTrue(saved.withUnsafeBytes{veta_load_state($0.baseAddress,$0.count)})
        for _ in 0..<20 {veta_run()};XCTAssertEqual(image(),expected)
        // Reopening runs the actual bridge deinit/reinit and callback lifecycle.
        veta_unload()
        XCTAssertTrue(veta_load_system(fixture.path,temp.path,temp.path,"Auto",20))
        for _ in 0..<2 {veta_run()}
        XCTAssertTrue(saved.withUnsafeBytes{veta_load_state($0.baseAddress,$0.count)})
        for _ in 0..<20 {veta_run()};XCTAssertEqual(image(),expected)
        print("VETA_MELONDS: frames=\(veta_frame_count()) audio=\(veta_audio_count()) nonzero=\(veta_audio_nonzero()) state=\(saved.count)")
        // Actual PCM is asserted before unload; the silent 140 fixture is no longer accepted.
    }

}
