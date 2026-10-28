#if VETA_JIT_DEVELOPMENT
import XCTest
import CryptoKit
@testable import VetaJITLab

/// Explicit user-requested imports. These are the user's games, not disposable
/// QA fixtures: no cleanup test may remove them or replace existing metadata.
@MainActor final class PhysicalRetailFixtures:XCTestCase {
    func test147EnableUserConsoleCatalog()throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VETA_ENABLE_ALL_CONSOLES"] == "147")
        let library=Library(),original=library.games
        for console in GameConsole.chronological {try library.enable(console)}
        XCTAssertEqual(library.consoles,Set(GameConsole.allCases))
        XCTAssertEqual(Library().consoles,Set(GameConsole.allCases))
        XCTAssertEqual(library.games,original,"Enabling consoles must preserve every game")
        let documents=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        for console in GameConsole.allCases {
            var isDirectory:ObjCBool=false
            XCTAssertTrue(FileManager.default.fileExists(atPath:documents.appendingPathComponent(console.name).path,isDirectory:&isDirectory),console.name)
            XCTAssertTrue(isDirectory.boolValue,console.name)
        }
        print("VETA147_CATALOG_ENABLED consoles=\(library.consoles.count) games=\(library.games.count)")
    }
    func test147RemovePS3AtUserRequest()throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VETA_REMOVE_PS3"] == "147")
        let library=Library(),fm=FileManager.default
        guard !library.games.contains(where:{$0.console == .ps3}) else {XCTFail("Back up and remove the owned PS3 game first");return}
        XCTAssertFalse(library.consoles.contains(.ps3))
        let folder=fm.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("PlayStation 3")
        if fm.fileExists(atPath:folder.path) {
            guard try fm.contentsOfDirectory(atPath:folder.path).isEmpty else {XCTFail("Unexpected PS3 files were preserved");return}
            try fm.removeItem(at:folder)
        }
        let runtime=library.root.appendingPathComponent("NativeEngines/ps3")
        if fm.fileExists(atPath:runtime.path) {try fm.removeItem(at:runtime)}
        XCTAssertFalse(fm.fileExists(atPath:runtime.path))
        XCTAssertFalse(fm.fileExists(atPath:folder.path))
        print("VETA147_PS3_REMOVED catalog, runtime, empty document folder")
    }
    static let rotationStagingName="VETA-Retail-Rotation-147-mobile"
    struct Entry:Codable {let console:GameConsole;let path:String;let name:String}
    struct Result:Codable {let console:GameConsole;let name:String;let id:String?;let error:String?}
    func testPrepareRotationStaging()throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VETA_RETAIL_ROTATION"] == "147")
        let fm=FileManager.default,cache=fm.urls(for:.cachesDirectory,in:.userDomainMask)[0]
        let directories=try JSONDecoder().decode([String].self,from:Data(contentsOf:cache.appendingPathComponent("VETA-Retail-Rotation-147-plan.json")))
        guard directories.allSatisfy({!$0.isEmpty && !$0.hasPrefix("/") && !$0.split(separator:"/").contains("..")}) else{throw VetaError.message("Invalid rotation directory plan")}
        let staging=cache.appendingPathComponent(Self.rotationStagingName)
        if fm.fileExists(atPath:staging.path) {try fm.removeItem(at:staging)}
        // CoreDevice-created directories can belong to root. Pre-create every
        // directory in the app so its own cleanup can remove the copied files.
        try fm.createDirectory(at:staging,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        for path in directories.sorted(by:{$0.count<$1.count}) {
            try fm.createDirectory(at:staging.appendingPathComponent(path),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        }
    }
    func testDiscardRotationStaging()throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VETA_RETAIL_ROTATION"] == "147")
        let fm=FileManager.default,library=Library()
        let journal=library.root.appendingPathComponent("retail-rotation-147.json")
        let owned=try JSONDecoder().decode([Result].self,from:Data(contentsOf:journal))
        XCTAssertFalse(owned.isEmpty)
        guard !owned.isEmpty,owned.allSatisfy({entry in library.games.contains{$0.id==entry.id && $0.name==entry.name && $0.console==entry.console}}) else {
            XCTFail("Imported rotation copy must exist before discarding staging");return
        }
        let staging=fm.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent(Self.rotationStagingName)
        if fm.fileExists(atPath:staging.path) {try fm.removeItem(at:staging)}
        XCTAssertTrue(fm.fileExists(atPath:library.root.appendingPathComponent("library.json").path))
        for entry in owned {if let id=entry.id {XCTAssertTrue(fm.fileExists(atPath:library.directory(id).path))}}
    }
    func testAuditRestoredOriginals()throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VETA_AUDIT_RECOVERY"] == "147")
        struct Expected:Decodable {let games:[Game];let files:[String:String]}
        let fm=FileManager.default,home=URL(fileURLWithPath:NSHomeDirectory())
        let manifest=home.appendingPathComponent("Library/Caches/VETA-Recovery-147/expected.json")
        let expected=try JSONDecoder().decode(Expected.self,from:Data(contentsOf:manifest))
        let library=Library()
        XCTAssertNil(library.error)
        // New user imports may coexist with the restored original library.
        // Require every original record unchanged, without rejecting additions.
        for game in expected.games {
            XCTAssertEqual(library.games.first(where:{$0.id==game.id}),game)
        }
        for (path,digest) in expected.files {
            guard !path.hasPrefix("/"),!path.split(separator:"/").contains("..") else{throw VetaError.message("Invalid recovery audit path")}
            let actual=SHA256.hash(data:try Data(contentsOf:home.appendingPathComponent(path))).map{String(format:"%02x",$0)}.joined()
            XCTAssertEqual(actual,digest,path)
        }
        // Check that restored directories remain writable by the app itself.
        for folder in [library.root]+expected.games.map({library.directory($0.id)}) {
            let probe=folder.appendingPathComponent(".recovery-audit-"+UUID().uuidString)
            try Data("write probe".utf8).write(to:probe,options:.atomic)
            try fm.removeItem(at:probe)
        }
        print("VETA147_RECOVERY_AUDIT games=\(expected.games.count) files=\(expected.files.count) writable=true")
    }
    // Heavy games are explicitly rotated at the user's request. Ownership is
    // recorded separately from permanent imports; existing entries never enter
    // this journal, so cleanup cannot remove a pre-existing library game.
    func testRemoveRotationSelection()throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VETA_RETAIL_ROTATION"] == "147")
        let library=Library(),fm=FileManager.default
        let journal=library.root.appendingPathComponent("retail-rotation-147.json")
        guard fm.fileExists(atPath:journal.path) else{return}
        let entries=try JSONDecoder().decode([Result].self,from:Data(contentsOf:journal))
        for entry in entries {
            guard let id=entry.id,let game=library.games.first(where:{$0.id==id}) else{continue}
            guard game.name==entry.name,game.console==entry.console else {
                XCTFail("Rotation entry was changed; preserve it for review");return
            }
            try library.remove(game)
        }
        try JSONEncoder().encode([Result]()).write(to:journal,options:.atomic)
        XCTAssertNil(library.error)
    }
    func testImportUserSelection()throws {
        let selectionVersion=ProcessInfo.processInfo.environment["VETA_IMPORT_USER_SELECTION"]
        try XCTSkipUnless(["147","152"].contains(selectionVersion ?? ""))
        let fm=FileManager.default
        let rotation=ProcessInfo.processInfo.environment["VETA_RETAIL_ROTATION"] == "147"
        let source=fm.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent(rotation ? Self.rotationStagingName:(selectionVersion == "152" ? "VETA-Retail-152":"VETA-Retail-147"))
        let entries=try JSONDecoder().decode([Entry].self,from:Data(contentsOf:source.appendingPathComponent("selection.json")))
        let library=Library(),documents=fm.urls(for:.documentDirectory,in:.userDomainMask)[0]
        let capacity=try fm.attributesOfFileSystem(forPath:library.root.path)[.systemFreeSize] as? NSNumber
        print("VETA147_FREE_BYTES \(capacity?.uint64Value ?? 0)")
        var results=[Result]()
        for entry in entries {
            do {
                if let existing=library.games.first(where:{$0.console==entry.console && $0.name==entry.name}) {
                    results.append(Result(console:entry.console,name:entry.name,id:existing.id,error:nil));continue
                }
                guard !entry.path.hasPrefix("/"),!entry.path.split(separator:"/").contains("..") else {throw VetaError.message("Invalid staged path")}
                let file=source.appendingPathComponent(entry.path)
                try library.enable(entry.console)
                let original=Set(library.games.map(\.id))
                try library.importURLs([file],console:entry.console)
                if var game=library.games.first(where:{!original.contains($0.id)}) {
                    game.name=entry.name;library.update(game)
                    if rotation {
                        let journal=library.root.appendingPathComponent("retail-rotation-147.json")
                        var owned=try fm.fileExists(atPath:journal.path) ? JSONDecoder().decode([Result].self,from:Data(contentsOf:journal)):[]
                        owned.append(Result(console:entry.console,name:entry.name,id:game.id,error:nil))
                        try JSONEncoder().encode(owned).write(to:journal,options:.atomic)
                    }
                    // Keep an accessible original alongside the private runtime copy.
                    // Move only our staged game/package; never overwrite Documents.
                    let visible=documents.appendingPathComponent(entry.console.name).appendingPathComponent(file.lastPathComponent)
                    if !rotation && !fm.fileExists(atPath:visible.path) {
                        if file.pathExtension.lowercased()=="cue" {
                            let folder=visible.deletingPathExtension()
                            if !fm.fileExists(atPath:folder.path) {try fm.moveItem(at:file.deletingLastPathComponent(),to:folder)}
                        } else {try fm.moveItem(at:file,to:visible)}
                    }
                    results.append(Result(console:entry.console,name:entry.name,id:game.id,error:nil))
                    print("VETA147_IMPORTED \(entry.console.rawValue) \(game.id) \(entry.name)")
                } else {
                    let game=library.games.first{$0.console==entry.console && $0.name==entry.name}
                    results.append(Result(console:entry.console,name:entry.name,id:game?.id,error:game==nil ? "No new game, and no matching existing entry":nil))
                }
            } catch {
                results.append(Result(console:entry.console,name:entry.name,id:nil,error:error.localizedDescription))
                print("VETA147_IMPORT_FAILED \(entry.console.rawValue) \(entry.name): \(error)")
            }
            // devicectl-created cache directories may be read-only to the app.
            // Store the journal in the app-created library, not in the input.
            try JSONEncoder().encode(results).write(to:library.root.appendingPathComponent("retail-import-147.json"),options:.atomic)
        }
        XCTAssertTrue(results.allSatisfy{$0.error==nil},"Inspect import-results.json; successful imports are preserved")
    }
}
// Dedicated opt-in staging; never touches the older rotation ownership journal.
extension PhysicalRetailFixtures {
    func test152PreparePermanentStaging()throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VETA_IMPORT_USER_SELECTION"] == "152")
        let fm=FileManager.default,cache=fm.urls(for:.cachesDirectory,in:.userDomainMask)[0]
        let names=try JSONDecoder().decode([String].self,from:Data(contentsOf:cache.appendingPathComponent("VETA-Retail-152-plan.json")))
        guard names.allSatisfy({!$0.isEmpty && !$0.hasPrefix("/") && !$0.split(separator:"/").contains("..")}) else {throw VetaError.message("Invalid staging plan")}
        let root=cache.appendingPathComponent("VETA-Retail-152")
        for name in [""]+names.sorted(by:{$0.count<$1.count}) {
            try fm.createDirectory(at:name.isEmpty ? root:root.appendingPathComponent(name),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        }
    }
    private var xbox151Staging:URL {FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("VETA-Xbox151")}
    func test151PrepareXboxStaging()throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VETA_XBOX151"] == "1")
        let fm=FileManager.default,library=Library()
        let free=(try fm.attributesOfFileSystem(forPath:library.root.path)[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
        print("VETA151_XBOX_FREE_BYTES \(free)")
        guard free>=4*1024*1024*1024 else {throw VetaError.message("Xbox151 requires at least 4 GiB free before staging.")}
        for name in ["", "system", "rom"] {
            try fm.createDirectory(at:name.isEmpty ? xbox151Staging:xbox151Staging.appendingPathComponent(name),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        }
        print("VETA151_XBOX_STAGING_READY \(xbox151Staging.path)")
    }
    func test151ImportXboxFightingGameAndSystem()throws {
        let env=ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["VETA_XBOX151"] == "1")
        guard env["VETA_XBOX151_BACKED_UP"] == "1" else {throw VetaError.message("Read-only Mac backup must be completed before replacing Xbox system files.")}
        let fm=FileManager.default,library=Library(),original=library.games
        let expectedID="d548c46da9287cafedb9dd96b27a4aaa240b7a39a2bf036c8177fcf49315ff4a"
        guard original.filter({$0.id != expectedID}).count==33 else {throw VetaError.message("Unexpected library size; preserve all games and review the baseline.")}
        let source=xbox151Staging.appendingPathComponent("rom/KingOfFightersNeowave.xiso")
        let systemSource=xbox151Staging.appendingPathComponent("system")
        _ = try XboxSystemFiles.validate(systemSource)
        func hash(_ url:URL)throws->String {
            let handle=try FileHandle(forReadingFrom:url);defer{try? handle.close()}
            var digest=SHA256()
            while let data=try handle.read(upToCount:1024*1024),!data.isEmpty {digest.update(data:data)}
            return digest.finalize().map{String(format:"%02x",$0)}.joined()
        }
        guard try hash(systemSource.appendingPathComponent("flash.bin"))=="3d5fae186cb31b5a6331155e532ef63e493afd85d7af8576fb52c95d0ce0362c" else {throw VetaError.message("Xbox151 BIOS differs from verified host kit.")}
        guard try hash(source)==expectedID else {throw VetaError.message("KOF image differs from the verified source.")}
        let system=library.root.appendingPathComponent("NativeEngines/xbox/System/xbox")
        let backup=system.deletingLastPathComponent().appendingPathComponent("xbox.before151")
        // Retain the first pre-change system, including writable HDD/EEPROM.
        if fm.fileExists(atPath:system.path),!fm.fileExists(atPath:backup.path) {
            try fm.copyItem(at:system,to:backup)
            for file in try XboxSystemFiles.validate(system) {
                guard try hash(system.appendingPathComponent(file))==hash(backup.appendingPathComponent(file)) else {throw VetaError.message("Internal Xbox backup verification failed.")}
            }
        }
        guard fm.fileExists(atPath:backup.path) else {throw VetaError.message("No internal pre-change Xbox backup; inspect before proceeding.")}
        try library.enable(.xbox)
        var game=try library.importExperimental(source,console:.xbox)
        XCTAssertEqual(game.id,expectedID)
        if !original.contains(where:{$0.id==game.id}) {game.name="The King of Fighters Neowave";library.update(game)}
        let documents=fm.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("Xbox")
        try fm.createDirectory(at:documents,withIntermediateDirectories:true)
        let visible=documents.appendingPathComponent(source.lastPathComponent)
        if !fm.fileExists(atPath:visible.path) {try fm.moveItem(at:source,to:visible)}
        else {guard try hash(visible)==expectedID else {throw VetaError.message("Existing Documents game differs; preserved without overwrite.")}}
        try XboxSystemFiles.install(from:systemSource,to:system)
        for old in original {XCTAssertEqual(library.games.first(where:{$0.id==old.id}),old)}
        XCTAssertEqual(library.games.count,34)
        XCTAssertEqual(try hash(library.romURL(game)),expectedID)
        XCTAssertNil(library.error)
        print("VETA151_XBOX_IMPORTED id=\(game.id) games=\(library.games.count) previousSystem=\(backup.path)")
    }
}
#endif
