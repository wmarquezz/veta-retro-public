#if VETA_JIT_DEVELOPMENT
import XCTest
import QuartzCore
import UIKit
@testable import VetaJITLab

@MainActor final class NextGenTests:XCTestCase {
    private var root:URL!
    override func setUpWithError()throws {root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)}
    override func tearDownWithError()throws {try? FileManager.default.removeItem(at:root)}
    func testPS3RetiredFromCatalogAndRuntime()throws {
        XCTAssertEqual(GameConsole.allCases.count,20)
        XCTAssertFalse(GameConsole.allCases.contains(.ps3))
        XCTAssertTrue(GameConsole.allCases.contains(.ps2))
        XCTAssertTrue(GameConsole.allCases.contains(.psp))
        XCTAssertFalse(GameConsole.ps3.playable)
        XCTAssertFalse(vng_available(1,Bundle.main.privateFrameworksPath ?? ""))
        XCTAssertFalse(FileManager.default.fileExists(atPath:(Bundle.main.privateFrameworksPath ?? "")+"/RPCS3Core.framework"))
        let libraryRoot=root.appendingPathComponent("retired-library")
        try FileManager.default.createDirectory(at:libraryRoot,withIntermediateDirectories:true)
        try JSONEncoder().encode(Set([GameConsole.nes,.ps3])).write(to:libraryRoot.appendingPathComponent("consoles.json"))
        let library=Library(root:libraryRoot)
        XCTAssertEqual(library.consoles,[.nes])
        XCTAssertEqual(Library(root:libraryRoot).consoles,[.nes])
        XCTAssertThrowsError(try library.enable(.ps3,documents:root.appendingPathComponent("Documents")))
    }
    func testXbox360RetiredFromCatalogAndRuntime()throws {
        XCTAssertFalse(GameConsole.allCases.contains(.xbox360))
        XCTAssertFalse(GameConsole.allCases.contains(.xbox))
        XCTAssertFalse(GameConsole.xbox360.playable)
        XCTAssertFalse(vng_available(3,Bundle.main.privateFrameworksPath ?? ""))
        for name in ["XeniOSCore.framework","libdxilconv.dylib","libmetalirconverter.dylib"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath:(Bundle.main.privateFrameworksPath ?? "")+"/"+name))
        }
        let libraryRoot=root.appendingPathComponent("retired-360-library"),docs=root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at:libraryRoot,withIntermediateDirectories:true)
        try JSONEncoder().encode(Set([GameConsole.nes,.xbox360])).write(to:libraryRoot.appendingPathComponent("consoles.json"))
        let library=Library(root:libraryRoot)
        XCTAssertEqual(library.consoles,[.nes])
        XCTAssertThrowsError(try library.enable(.xbox360,documents:docs))
        let oldFolder=docs.appendingPathComponent("Xbox 360")
        try FileManager.default.createDirectory(at:oldFolder,withIntermediateDirectories:true)
        try GameFiles.migrate(in:docs,active:["NES"])
        XCTAssertFalse(FileManager.default.fileExists(atPath:oldFolder.path))
        try FileManager.default.createDirectory(at:oldFolder,withIntermediateDirectories:true)
        let original=Data("preserve-user-file".utf8)
        try original.write(to:oldFolder.appendingPathComponent("game.xex"))
        try GameFiles.migrate(in:docs,active:["NES"])
        XCTAssertEqual(try Data(contentsOf:docs.appendingPathComponent("Archivos conservados/Xbox 360/game.xex")),original)
    }
    func testXboxRetiredFromCatalogRuntimeAndImports()throws {
        XCTAssertEqual(GameConsole.allCases.count,20)
        XCTAssertFalse(GameConsole.allCases.contains(.xbox))
        XCTAssertFalse(GameConsole.xbox.playable)
        for name in ["DukeXCore.framework","DukeXInterpreterCore.framework","DukeXSlirp.framework","DukeXMetal.framework"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath:(Bundle.main.privateFrameworksPath ?? "")+"/"+name))
        }
        let libraryRoot=root.appendingPathComponent("retired-xbox"),docs=root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at:libraryRoot,withIntermediateDirectories:true)
        try JSONEncoder().encode(Set([GameConsole.nes,.xbox])).write(to:libraryRoot.appendingPathComponent("consoles.json"))
        let library=Library(root:libraryRoot)
        XCTAssertEqual(library.consoles,[.nes])
        XCTAssertThrowsError(try library.enable(.xbox,documents:docs))
        let old=docs.appendingPathComponent("Xbox")
        try FileManager.default.createDirectory(at:old,withIntermediateDirectories:true)
        try Data("preserve".utf8).write(to:old.appendingPathComponent("game.iso"))
        try GameFiles.migrate(in:docs,active:["NES"])
        XCTAssertEqual(try Data(contentsOf:docs.appendingPathComponent("Archivos conservados/Xbox/game.iso")),Data("preserve".utf8))
        XCTAssertThrowsError(try library.importExperimental(docs.appendingPathComponent("Archivos conservados/Xbox/game.iso"),console:.xbox))
    }
    private func ps3Folder(_ name:String)throws->URL {
        let folder=root.appendingPathComponent(name),game=folder.appendingPathComponent("PS3_GAME")
        try FileManager.default.createDirectory(at:game.appendingPathComponent("USRDIR"),withIntermediateDirectories:true)
        try Data([0,0x50,0x53,0x46]).write(to:game.appendingPathComponent("PARAM.SFO"))
        try Data(repeating:0x4e,count:64).write(to:game.appendingPathComponent("USRDIR/EBOOT.BIN"))
        return folder
    }
    private func identifiedPS3Folder(_ name:String,version:String)throws->URL {
        let folder=try ps3Folder(name)
        var sfo=Data(repeating:0,count:80)
        func word(_ offset:Int,_ value:UInt32){for i in 0..<4{sfo[offset+i]=UInt8((value >> (i*8)) & 255)}}
        sfo.replaceSubrange(0..<4,with:[0,0x50,0x53,0x46]);word(8,36);word(12,48);word(16,1);word(24,10);word(28,10)
        sfo.replaceSubrange(36..<45,with:Data("TITLE_ID\0".utf8));sfo.replaceSubrange(48..<58,with:Data("VETATEST1\0".utf8))
        try sfo.write(to:folder.appendingPathComponent("PS3_GAME/PARAM.SFO"))
        try Data(version.utf8).write(to:folder.appendingPathComponent("PS3_GAME/version"))
        return folder
    }
    private func seedPrivatePS3(_ source:URL,library:Library)throws->URL {
        let installed=library.root.appendingPathComponent("NativeEngines/ps3/Support/dev_hdd0/game/VETATEST1")
        try FileManager.default.createDirectory(at:installed.deletingLastPathComponent(),withIntermediateDirectories:true)
        try FileManager.default.copyItem(at:source.appendingPathComponent("PS3_GAME"),to:installed)
        return installed
    }
    // Model an already-installed historical title without reopening retired imports.
    private func seedLegacyPS3(_ folder:URL,library:Library)throws->Game {
        var game=Game(id:sha256(Data(folder.path.utf8)),name:folder.lastPathComponent,console:.ps3)
        game.contentName="game.ps3"
        try FileManager.default.createDirectory(at:library.directory(game.id),withIntermediateDirectories:true)
        try FileManager.default.copyItem(at:folder,to:library.romURL(game))
        library.games.append(game);try library.persist();return game
    }
    func testPS3LibraryDeletionKeepsSharedLegacyTitleAndPreservesSaves()throws {
        let a=try identifiedPS3Folder("First",version:"A"),b=try identifiedPS3Folder("Second",version:"B")
        let library=Library(root:root.appendingPathComponent("library")),ga=try seedLegacyPS3(a,library:library),gb=try seedLegacyPS3(b,library:library)
        let installed=try seedPrivatePS3(a,library:library)
        let save=library.root.appendingPathComponent("NativeEngines/ps3/Support/dev_hdd0/home/00000001/savedata/VETATEST1/save")
        try FileManager.default.createDirectory(at:save.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data("preserve".utf8).write(to:save)
        try library.remove(ga)
        XCTAssertTrue(FileManager.default.fileExists(atPath:installed.path),"Unowned legacy title is retained while another entry refers to it")
        try library.remove(gb)
        XCTAssertFalse(FileManager.default.fileExists(atPath:installed.path));XCTAssertNil(library.error)
        XCTAssertEqual(try Data(contentsOf:save),Data("preserve".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath:a.path),"Original imported folder belongs to user")
    }
    func testPS3CleanupIntentUsesCommittedLibraryIndexAfterInterruption()throws {
        let source=try identifiedPS3Folder("Recovery",version:"A"),libraryRoot=root.appendingPathComponent("library")
        let library=Library(root:libraryRoot),game=try seedLegacyPS3(source,library:library)
        let installed=try seedPrivatePS3(source,library:library)
        try library.preparePS3Deletion(game)
        let unchanged=Library(root:libraryRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath:installed.path));XCTAssertEqual(unchanged.games.count,1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:libraryRoot.appendingPathComponent("PS3PendingDeletes").path).isEmpty)
        try unchanged.preparePS3Deletion(game)
        let staged=libraryRoot.appendingPathComponent("DeletedGames/"+game.id)
        try FileManager.default.createDirectory(at:staged.deletingLastPathComponent(),withIntermediateDirectories:true)
        try FileManager.default.moveItem(at:unchanged.directory(game.id),to:staged)
        try JSONEncoder().encode([Game]()).write(to:libraryRoot.appendingPathComponent("library.json"),options:.atomic)
        let recovered=Library(root:libraryRoot)
        XCTAssertTrue(recovered.games.isEmpty);XCTAssertNil(recovered.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath:installed.path));XCTAssertFalse(FileManager.default.fileExists(atPath:staged.path))
    }
    func testRetiredPS3ImportRejectsValidFoldersAndAliasesWithoutPublishing()throws {
        let folder=try ps3Folder("Homebrew"),library=Library(root:root.appendingPathComponent("library"))
        XCTAssertNoThrow(try ExperimentalGameContent.validate(folder,console:.ps3))
        XCTAssertThrowsError(try library.importExperimental(folder,console:.ps3))
        let alias=root.deletingLastPathComponent().appendingPathComponent("veta-alias-"+UUID().uuidString)
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:root)
        defer{try? FileManager.default.removeItem(at:alias)}
        XCTAssertThrowsError(try library.importExperimental(alias.appendingPathComponent(folder.lastPathComponent),console:.ps3))
        XCTAssertTrue(library.games.isEmpty)
        XCTAssertEqual(try Data(contentsOf:folder.appendingPathComponent("PS3_GAME/USRDIR/EBOOT.BIN")),Data(repeating:0x4e,count:64))
    }
    func testPS3RejectsMissingMetadataAndLinksWithoutPublishing()throws {
        let folder=try ps3Folder("Invalid"),library=Library(root:root.appendingPathComponent("library"))
        try FileManager.default.removeItem(at:folder.appendingPathComponent("PS3_GAME/PARAM.SFO"))
        XCTAssertThrowsError(try library.importExperimental(folder,console:.ps3));XCTAssertTrue(library.games.isEmpty)
        let valid=try ps3Folder("Linked")
        try FileManager.default.createSymbolicLink(at:valid.appendingPathComponent("outside"),withDestinationURL:root)
        XCTAssertThrowsError(try library.importExperimental(valid,console:.ps3));XCTAssertTrue(library.games.isEmpty)
    }
    func testXEXIsConsoleExplicitAndDiscBoundsAreChecked()throws {
        let xex=root.appendingPathComponent("homebrew.xex")
        var bytes=Data(repeating:0,count:64);bytes.replaceSubrange(0..<4,with:Data("XEX2".utf8));try bytes.write(to:xex)
        XCTAssertNoThrow(try ExperimentalGameContent.validate(xex,console:.xbox360))
        XCTAssertThrowsError(try ExperimentalGameContent.validate(xex,console:.xbox))
        XCTAssertThrowsError(try GameConsole.detect(bytes,extension:"xex"),"No console inferred from an unknown format")
        let iso=root.appendingPathComponent("fixture.iso")
        var disc=Data(repeating:0,count:72*1024)
        disc.replaceSubrange(0x10000..<0x10014,with:Data("MICROSOFT*XBOX*MEDIA".utf8))
        func word(_ offset:Int,_ value:UInt32) {for i in 0..<4 {disc[offset+i]=UInt8((value >> (i*8)) & 255)}}
        word(0x10014,34);word(0x10018,32);try disc.write(to:iso)
        XCTAssertNoThrow(try ExperimentalGameContent.validate(iso,console:.xbox))
        XCTAssertNoThrow(try ExperimentalGameContent.validate(iso,console:.xbox360))
        word(0x10014,0xffffffff);try disc.write(to:iso)
        XCTAssertThrowsError(try ExperimentalGameContent.validate(iso,console:.xbox360))
    }
    func testOpenFirmwareDiagnosticIsExplicitAndNotAConsoleGame()throws {
        let marker=root.appendingPathComponent("Open firmware.veta-xbox-firmware")
        try Data("VETA-XBOX-FIRMWARE-1\n".utf8).write(to:marker)
        let library=Library(root:root.appendingPathComponent("diagnostics"))
        XCTAssertNoThrow(try ExperimentalGameContent.validate(marker,console:.xbox))
        XCTAssertThrowsError(try library.importExperimental(marker,console:.xbox))
        XCTAssertThrowsError(try ExperimentalGameContent.validate(marker,console:.xbox360))
        XCTAssertThrowsError(try ExperimentalGameContent.validate(marker,console:.ps3))
        try Data("VETA-XBOX-FIRMWARE-0\n".utf8).write(to:marker)
        XCTAssertThrowsError(try library.importExperimental(marker,console:.xbox))
        XCTAssertEqual(library.games.count,0)
    }
    func testXboxSystemImportIsValidatedAndFailurePreservesPreviousFiles()throws {
        let source=root.appendingPathComponent("xbox-source"),destination=root.appendingPathComponent("System/xbox")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        try Data(repeating:1,count:512).write(to:source.appendingPathComponent("mcpx_1.0.bin"))
        try Data(repeating:2,count:262144).write(to:source.appendingPathComponent("flash.bin"))
        var disk=Data(repeating:0,count:104);disk.replaceSubrange(0..<8,with:[0x51,0x46,0x49,0xfb,0,0,0,3])
        try disk.write(to:source.appendingPathComponent("xbox_hdd.qcow2"))
        try XboxSystemFiles.install(from:source,to:destination)
        let original=try Data(contentsOf:destination.appendingPathComponent("flash.bin"))
        let identity=Data(repeating:4,count:256)
        try identity.write(to:destination.appendingPathComponent("xbox_eeprom.bin"))
        try Data(repeating:3,count:262144).write(to:source.appendingPathComponent("flash.bin"))
        XCTAssertThrowsError(try XboxSystemFiles.install(from:source,to:destination,beforeCommit:{throw CocoaError(.fileWriteOutOfSpace)}))
        XCTAssertEqual(try Data(contentsOf:destination.appendingPathComponent("flash.bin")),original)
        XCTAssertEqual(try Data(contentsOf:destination.appendingPathComponent("xbox_hdd.qcow2")),disk)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:destination.deletingLastPathComponent().path),["xbox"])
        try XboxSystemFiles.install(from:source,to:destination)
        XCTAssertEqual(try Data(contentsOf:destination.appendingPathComponent("flash.bin")),Data(repeating:3,count:262144))
        XCTAssertEqual(try Data(contentsOf:destination.appendingPathComponent("xbox_eeprom.bin")),identity)
        disk[15]=1 // External backing file is not copied or followed.
        try disk.write(to:source.appendingPathComponent("xbox_hdd.qcow2"))
        XCTAssertThrowsError(try XboxSystemFiles.install(from:source,to:destination))
        XCTAssertEqual(try Data(contentsOf:destination.appendingPathComponent("flash.bin")),Data(repeating:3,count:262144))
    }
    func testSnapshotMailboxDoesNotBlockMainAndDiscardsInvalidatedWork()async {
        let queue=DispatchQueue(label:"test.native.snapshot.lifecycle")
        let mailbox=NativeSnapshotMailbox(queue:queue)
        let entered=expectation(description:"Lifecycle worker is busy")
        let release=DispatchSemaphore(value:0)
        queue.async {entered.fulfill();_ = release.wait(timeout:.now()+3)}
        await fulfillment(of:[entered],timeout:2)
        let stale=expectation(description:"Invalidated snapshot must not run");stale.isInverted=true
        XCTAssertNil(mailbox.value {stale.fulfill();return VNGSnapshot()})
        XCTAssertNil(mailbox.value {stale.fulfill();return VNGSnapshot()})
        mailbox.invalidate()
        release.signal()
        let drained=expectation(description:"Invalidated queue drained")
        queue.async {drained.fulfill()}
        await fulfillment(of:[drained],timeout:2)
        await fulfillment(of:[stale],timeout:0.05)
        let refreshed=expectation(description:"Snapshot read on worker")
        XCTAssertNil(mailbox.value {
            XCTAssertFalse(Thread.isMainThread)
            var snapshot=VNGSnapshot();snapshot.state=2;snapshot.frames=42
            refreshed.fulfill();return snapshot
        })
        await fulfillment(of:[refreshed],timeout:2)
        let published=expectation(description:"Snapshot publication complete")
        queue.async {published.fulfill()}
        await fulfillment(of:[published],timeout:2)
        let snapshot=mailbox.value {VNGSnapshot()}
        XCTAssertEqual(snapshot?.frames,42)
        mailbox.close()
        XCTAssertNil(mailbox.value {XCTFail("Closed mailbox refreshed");return VNGSnapshot()})
    }
    func testStandalonePreparationCancelsWaitingPoolButRejectsInFlightProtocols() {
        let previous=UIApplication.shared.isIdleTimerDisabled
        defer{UIApplication.shared.isIdleTimerDisabled=previous}
        let waiting=JITSession()
        waiting.begin()
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
        XCTAssertTrue(waiting.prepareStandalone())
        XCTAssertEqual(waiting.phase,.cancelled)
        XCTAssertFalse(waiting.canRequestHelper)
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
        waiting.begin() // The cancelled root cannot restart its timeout timer.
        XCTAssertEqual(waiting.phase,.cancelled)
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
        var preparing=JITActivationPolicy()
        XCTAssertTrue(preparing.requestHelper(now:0))
        XCTAssertTrue(preparing.prepare(attached:true))
        let blockedPrepare=JITSession(policy:preparing)
        XCTAssertFalse(blockedPrepare.prepareStandalone())
        XCTAssertEqual(blockedPrepare.phase,.preparing)
        let timedOut=JITSession(policy:preparing)
        XCTAssertTrue(timedOut.beginProtocolWork())
        XCTAssertTrue(timedOut.expireWaiting(at:181))
        XCTAssertEqual(timedOut.phase,.failed)
        XCTAssertTrue(timedOut.protocolInFlight)
        XCTAssertFalse(timedOut.prepareStandalone(),"A timeout does not cancel the native background protocol")
        XCTAssertFalse(timedOut.beginProtocolWork(),"Never start a second protocol while the previous worker is pending")
        XCTAssertFalse(timedOut.canRequestHelper)
        timedOut.finishProtocolWork()
        XCTAssertFalse(timedOut.protocolInFlight)
        XCTAssertTrue(timedOut.prepareStandalone())
        var verifying=preparing
        XCTAssertTrue(verifying.verify())
        let blockedVerify=JITSession(policy:verifying)
        XCTAssertFalse(blockedVerify.prepareStandalone())
        XCTAssertEqual(blockedVerify.phase,.verifying)
        var ready=verifying;ready.complete(verified:true)
        var failed=verifying;failed.complete(verified:false)
        for policy in [ready,failed] {
            let session=JITSession(policy:policy)
            XCTAssertTrue(session.prepareStandalone())
            XCTAssertEqual(session.phase,policy.phase)
        }
    }
    func testPreparationRequiresAnExplicitActionAndClosingIdleDoesNotHang() {
        let library=Library(root:root.appendingPathComponent("idle-library"))
        let model=NativeSessionModel(game:Game(id:"idle",name:"Idle",console:.ps3),library:library)
        model.prepare(layer:CAMetalLayer())
        XCTAssertEqual(model.phase,.idle,"Attaching a display must never initialize a core or trigger a debugger protocol")
        XCTAssertTrue(model.canPrepare)
        var finished=false
        model.stop {finished=$0}
        XCTAssertTrue(finished);XCTAssertEqual(model.phase,.stopped)
    }
    func testRetiredRuntimesDoNotAdvertiseRemoteControllerSlots() {
        let hub=ControllerHub.shared
        for console in [GameConsole.ps3,.xbox,.xbox360] {
            XCTAssertFalse(vng_available(console.nativeEngine!,Bundle.main.privateFrameworksPath ?? ""))
            XCTAssertEqual(console.maximumPlayers,1,"UI fallback must not advertise multiplayer for absent runtimes")
            hub.configure(console:console,maxPlayers:console.maximumPlayers)
            let peer="retired-test-"+UUID().uuidString
            XCTAssertNil(hub.reservePeer(peer))
            hub.releasePeer(peer)
        }
    }
    func testGameJITActivationDoesNotBypassMissingFilesOrUnsupportedEngines()throws {
        let file=root.appendingPathComponent("game.bin")
        let consoles:[GameConsole]=[.gamecube,.wii,.dreamcast,.ps2,.threeDS]
        let readiness=DeviceReadiness(snapshot:.init(metalAvailable:true,physicalMemory:8*1024*1024*1024,processorCount:6,osVersion:.init(majorVersion:18,minorVersion:0,patchVersion:0),simulator:false,jitAvailable:false,experimentalBuild:true,includedConsoles:Set(consoles)))
        try Data([1]).write(to:file)
        for console in consoles {
            let game=Game(id:"gate-"+console.rawValue,name:"Gate",console:console)
            let valid=readiness.preflight(console:console,gameURL:file,systemDirectory:root)
            XCTAssertFalse(valid.canLaunch)
            XCTAssertTrue(JITGameContainer.canOfferActivation(game:game,check:valid))
            let missing=readiness.preflight(console:console,gameURL:root.appendingPathComponent("missing"),systemDirectory:root)
            XCTAssertFalse(JITGameContainer.canOfferActivation(game:game,check:missing))
            let directory=readiness.preflight(console:console,gameURL:root,systemDirectory:root)
            XCTAssertFalse(JITGameContainer.canOfferActivation(game:game,check:directory))
        }
        let unsupported=Game(id:"ps3",name:"Standalone",console:.ps3)
        let check=readiness.preflight(console:.ps3,gameURL:file,systemDirectory:root)
        XCTAssertFalse(JITGameContainer.canOfferActivation(game:unsupported,check:check))
        try Data().write(to:file)
        let empty=readiness.preflight(console:.gamecube,gameURL:file,systemDirectory:root)
        XCTAssertFalse(JITGameContainer.canOfferActivation(game:Game(id:"empty",name:"Empty",console:.gamecube),check:empty))
    }
    func testPerGameJITRetryNeverTakesActivationBackFromStandalone() {
        let previous=UIApplication.shared.isIdleTimerDisabled
        defer{UIApplication.shared.isIdleTimerDisabled=previous}
        let skipped=JITSession();skipped.cancel()
        XCTAssertTrue(skipped.canActivateForGame,"Skipping the untouched global banner must not permanently disable per-game activation")
        XCTAssertTrue(skipped.prepareStandalone())
        XCTAssertFalse(skipped.canActivateForGame,"A standalone engine owns its protocol until process restart")
        var requested=JITActivationPolicy();XCTAssertTrue(requested.requestHelper(now:0));XCTAssertTrue(requested.cancel())
        XCTAssertFalse(JITSession(policy:requested).canActivateForGame,"A cancelled helper can still attach; do not issue a new protocol")
        let working=JITSession();XCTAssertTrue(working.beginProtocolWork())
        XCTAssertFalse(working.canActivateForGame)
        working.finishProtocolWork();XCTAssertTrue(working.canActivateForGame)
        working.cancel()
    }
    func testStandaloneCapabilitiesAndMissingRuntimeStayHonest() {
        let capabilities=NativeSessionCapabilities(raw:7,maxPlayers:1)
        XCTAssertTrue(capabilities.pause);XCTAssertTrue(capabilities.input);XCTAssertTrue(capabilities.firmwareInstall)
        XCTAssertFalse(capabilities.saveStates);XCTAssertTrue(capabilities.externalDisplay);XCTAssertFalse(capabilities.remoteControllers);XCTAssertFalse(capabilities.rumble)
        for console in [GameConsole.ps3,.xbox,.xbox360] {
            XCTAssertTrue(console.isStandaloneEngine)
            XCTAssertGreaterThan(console.coreIndex,100,"Never dispatch these engines into libretro")
            XCTAssertFalse(vng_available(console.nativeEngine!,root.appendingPathComponent("missing-frameworks").path))
        }
    }
}
#endif

#if VETA_JIT_DEVELOPMENT
@MainActor final class RemoteControllerAppearanceTests: XCTestCase {
    func testWelcomeTransfersBothOrientationsAndPreservesOtherPreferences() throws {
        let sourceName = "VETA.RemoteAppearance.Source." + UUID().uuidString
        let targetName = "VETA.RemoteAppearance.Target." + UUID().uuidString
        let source = try XCTUnwrap(UserDefaults(suiteName: sourceName)), target = try XCTUnwrap(UserDefaults(suiteName: targetName))
        defer { source.removePersistentDomain(forName: sourceName); target.removePersistentDomain(forName: targetName) }
        target.set("keep", forKey: "unrelated-setting")
        target.set("Noche", forKey: GameConsole.snes.preferencePrefix + "skin")
        for console in GameConsole.allCases {
            let store = ControllerSkinStore(defaults: source)
            try store.save(.makeDefault(console: console, orientation: .portrait, palette: .classic), console: console)
            try store.save(.makeDefault(console: console, orientation: .landscape, palette: .night), console: console)
            source.set(1.15, forKey: console.preferencePrefix + "controlSize")
            let appearance = RemoteControllerAppearance(console: console, defaults: source)
            let packet = RemoteInputPacket(version: 1, kind: .welcome, session: UUID(), console: console.rawValue, slot: 1, sequence: 0, mask: 0, axes: [0,0,0,0], appearance: appearance)
            let decoded = try RemoteInputPacket.decode(packet.encoded())
            XCTAssertEqual(decoded.appearance, appearance)
            try XCTUnwrap(decoded.appearance).apply(console: console, defaults: target)
            XCTAssertEqual(RemoteControllerAppearance(console: console, defaults: target), appearance)
            XCTAssertEqual(target.string(forKey: "unrelated-setting"), "keep")
            if console == .nes { XCTAssertEqual(target.string(forKey: GameConsole.snes.preferencePrefix + "skin"), "Noche") }
        }
    }
    func testInvalidAppearanceIsRejectedBeforeAnyPreferenceChanges() throws {
        let name = "VETA.RemoteAppearance.Invalid." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("Noche", forKey: GameConsole.nes.preferencePrefix + "skin")
        let original = RemoteControllerAppearance(console: .nes, defaults: defaults)
        var invalid = original; invalid.size = 100
        XCTAssertThrowsError(try invalid.apply(console: .nes, defaults: defaults))
        invalid = original; invalid.landscapeLayout = .makeDefault(console: .snes, orientation: .landscape, palette: .night)
        XCTAssertThrowsError(try invalid.apply(console: .nes, defaults: defaults))
        XCTAssertThrowsError(try original.apply(console: .snes, defaults: defaults))
        XCTAssertEqual(RemoteControllerAppearance(console: .nes, defaults: defaults), original)
    }
    func testInputPacketBudgetAndLegacyWelcomeRemainIntact() throws {
        let legacy = RemoteInputPacket(version: 1, kind: .welcome, session: UUID(), console: "nes", slot: 1, sequence: 0, mask: 0, axes: [0,0,0,0])
        XCTAssertEqual(try RemoteInputPacket.decode(legacy.encoded()), legacy)
        let input = RemoteInputPacket(version: 1, kind: .input, session: UUID(), console: "nes", slot: 1, sequence: 1, mask: 1, axes: [0,0,0,0])
        var padded = try input.encoded(); padded.append(Data(repeating: 32, count: 513 - padded.count))
        XCTAssertThrowsError(try RemoteInputPacket.decode(padded))
        var disguised = input; disguised.appearance = RemoteControllerAppearance(console: .nes)
        XCTAssertThrowsError(try RemoteInputPacket.decode(JSONEncoder().encode(disguised)))
        XCTAssertThrowsError(try RemoteInputPacket.decode(Data(repeating: 32, count: RemoteInputPacket.maximumWelcomeBytes + 1)))
    }
}
#endif
