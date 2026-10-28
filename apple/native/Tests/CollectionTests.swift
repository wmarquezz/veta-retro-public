import XCTest
@testable import VetaNative

@MainActor final class CollectionTests:XCTestCase {
    var temp:URL!
    override func setUp() {temp=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try! FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)}
    override func tearDown() {try? FileManager.default.removeItem(at:temp)}
    func write(_ name:String,_ contents:String)throws {
        let url=temp.appendingPathComponent(name);try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true);try Data(contents.utf8).write(to:url)
    }
    func testMigrationMovesFilesPreservesConflictsAndRemovesOnlyEmptyConsoles()throws {
        try write("V-Retro/NES/game.nes","legacy");try write("NES/game.nes","current")
        try write("V-Retro/Saturn/BIOS/bios.bin","bios")
        try FileManager.default.createDirectory(at:temp.appendingPathComponent("V-Retro/SNES"),withIntermediateDirectories:true)
        try GameFiles.migrate(in:temp,active:["NES"])
        XCTAssertFalse(FileManager.default.fileExists(atPath:temp.appendingPathComponent("V-Retro").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:temp.appendingPathComponent("SNES").path))
        XCTAssertEqual(try String(contentsOf:temp.appendingPathComponent("NES/game.nes")),"current")
        XCTAssertEqual(try String(contentsOf:temp.appendingPathComponent("NES/game.recuperado-1.nes")),"legacy")
        XCTAssertEqual(try String(contentsOf:temp.appendingPathComponent("Archivos conservados/Saturn/BIOS/bios.bin")),"bios")
        let before=try FileManager.default.subpathsOfDirectory(atPath:temp.path).sorted()
        try GameFiles.migrate(in:temp,active:["NES"])
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath:temp.path).sorted(),before)
        _ = try GameFiles.prepareFolder(in:temp,names:["Saturn"])
        XCTAssertEqual(try String(contentsOf:temp.appendingPathComponent("Saturn/BIOS/bios.bin")),"bios")
        XCTAssertFalse(FileManager.default.fileExists(atPath:temp.appendingPathComponent("Archivos conservados/Saturn").path))
    }
    func testOnlySelectedConsolesAreCreated()throws {
        try GameFiles.migrate(in:temp,active:["NES"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:temp.path),["NES"])
        let library=Library(root:temp.appendingPathComponent("PrivateLibrary"))
        try library.enable(.gb,documents:temp)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath:temp.path)),Set(["NES","Game Boy","PrivateLibrary"]))
        XCTAssertEqual(Library(root:library.root).consoles,Set([.nes,.gb]))
    }
    func testInterruptedMigrationAndLinks()throws {
        try write("V-Retro/NES/a.nes","a");try write("NES/b.nes","b")
        try GameFiles.migrate(in:temp,active:["NES"])
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath:temp.appendingPathComponent("NES").path)),Set(["a.nes","b.nes"]))
        try FileManager.default.createSymbolicLink(at:temp.appendingPathComponent("SNES"),withDestinationURL:temp.appendingPathComponent("NES"))
        XCTAssertThrowsError(try GameFiles.prepareFolder(in:temp,names:["SNES"]))
        XCTAssertEqual(try String(contentsOf:temp.appendingPathComponent("NES/a.nes")),"a")
    }
    func testEveryConsoleHasTwoAttributedGamesAndBundledFilesExist()throws {
        XCTAssertEqual(DiscoverGame.catalog.count,40)
        XCTAssertEqual(Set(DiscoverGame.catalog.map(\.id)).count,40)
        let library=Library(root:temp)
        for console in GameConsole.allCases {XCTAssertEqual(DiscoverGame.catalog.filter{$0.console == console}.count,2,console.name)}
        for game in DiscoverGame.catalog {
            XCTAssertEqual(game.source.scheme,"https");XCTAssertFalse(game.author.isEmpty);XCTAssertFalse(game.license.isEmpty)
            if let file=game.filename {XCTAssertTrue(DiscFiles.safeName(file))}
            if let bundled=game.bundled {XCTAssertNotNil(Bundle.main.url(forResource:bundled,withExtension:library.demoExtension(bundled),subdirectory:"Content/\(bundled)"),game.id)}
        }
    }
    func testBundledDownloadCreatesCorrectFolderAndImportsWithoutOverwriting()async throws {
        let library=Library(root:temp.appendingPathComponent("Library")),store=DiscoveryDownloads(),docs=temp.appendingPathComponent("Documents")
        let game=try XCTUnwrap(DiscoverGame.catalog.first{$0.id == "thwaite"})
        for _ in 0..<2 {
            store.download(game,library:library,documents:docs)
            for _ in 0..<100 where store.busy != nil {try await Task.sleep(nanoseconds:20_000_000)}
            XCTAssertNil(store.busy);XCTAssertNil(store.failure)
        }
        XCTAssertEqual(library.games.count,1)
        XCTAssertEqual(library.games.first?.name,"Thwaite")
        XCTAssertEqual(try Data(contentsOf:docs.appendingPathComponent("NES/thwaite.nes")),try Data(contentsOf:docs.appendingPathComponent("NES/thwaite (2).nes")))
        XCTAssertFalse(FileManager.default.fileExists(atPath:docs.appendingPathComponent("V-Retro").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:docs.path),["NES"])
    }
    func testRealAuthorDownloadCanBeImported()async throws {
        let library=Library(root:temp.appendingPathComponent("Library")),store=DiscoveryDownloads(),docs=temp.appendingPathComponent("Documents")
        let game=try XCTUnwrap(DiscoverGame.catalog.first{$0.id == "ucity"})
        store.download(game,library:library,documents:docs)
        for _ in 0..<600 where store.busy != nil {try await Task.sleep(nanoseconds:100_000_000)}
        XCTAssertNil(store.busy);XCTAssertNil(store.failure)
        XCTAssertEqual(library.games.first?.console,.gbc)
        XCTAssertTrue(FileManager.default.fileExists(atPath:docs.appendingPathComponent("Game Boy Color/uCity.gbc").path))
    }
}
