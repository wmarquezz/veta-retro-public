import XCTest
@testable import VetaNative

@MainActor final class BulkDeletionTests:XCTestCase {
    var root:URL!
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    }
    override func tearDownWithError()throws {try? FileManager.default.removeItem(at:root)}
    func fixture(_ count:Int,console:GameConsole = .atari2600,offset:Int=0,in library:Library)throws -> [Game] {
        let games=try (offset..<offset+count).map {i -> Game in
            let game=Game(id:sha256(Data("bulk-fixture-\(i)".utf8)),name:String(format:"Fixture %03d",i),console:console)
            try FileManager.default.createDirectory(at:library.directory(game.id),withIntermediateDirectories:true)
            for name in ["game.\(console.romExtension)","auto.vstate","slot-1.vstate","battery.sav","cover.vcover"] {
                let file=library.file(game,name)
                try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
                try Data("\(i)-\(name)".utf8).write(to:file)
            }
            return game
        }
        library.games += games;try library.persist();return games
    }
    func testWholeConsole500GamesPreservesOtherConsoleOriginalsAndSkin()throws {
        let library=Library(root:root.appendingPathComponent("library"))
        let batch=try fixture(500,in:library),other=try fixture(2,console:.nes,offset:500,in:library)
        let originals=root.appendingPathComponent("original.a26"),skin=library.root.appendingPathComponent("personal-skin.json")
        try Data([7,8]).write(to:originals);try Data([9,10]).write(to:skin)
        let start=Date()
        let removed=try library.removeGames(ids:Set(batch.map(\.id)),console:.atari2600)
        print("Bulk deletion: 500 games / 2500 files in \(Date().timeIntervalSince(start)) seconds")
        XCTAssertEqual(removed,batch);XCTAssertEqual(library.games,other)
        for game in batch {XCTAssertFalse(FileManager.default.fileExists(atPath:library.directory(game.id).path))}
        for game in other {XCTAssertEqual(try Data(contentsOf:library.file(game,"slot-1.vstate")),Data("\(game.name.suffix(3))-slot-1.vstate".utf8))}
        XCTAssertEqual(try Data(contentsOf:originals),Data([7,8]));XCTAssertEqual(try Data(contentsOf:skin),Data([9,10]))
        let reopened=Library(root:library.root);XCTAssertNil(reopened.error);XCTAssertEqual(reopened.games,other)
        XCTAssertEqual(reopened.populatedConsoles,[.nes])
    }
    func testSubsetKeepsUnselectedSavesAndLaterImports()throws {
        let library=Library(root:root),batch=try fixture(6,in:library)
        let selection=Set([batch[1].id,batch[4].id]);let later=try fixture(1,offset:10,in:library)
        XCTAssertEqual(try library.removeGames(ids:selection,console:.atari2600).count,2)
        XCTAssertEqual(library.games,batch.enumerated().filter{![1,4].contains($0.offset)}.map(\.element)+later)
        for game in library.games {XCTAssertTrue(FileManager.default.fileExists(atPath:library.file(game,"slot-1.vstate").path))}
        XCTAssertEqual(Library(root:root).games,library.games)
    }
    func testIndexCommitFailureRestoresEveryDirectory()throws {
        let library=Library(root:root),batch=try fixture(20,in:library),index=root.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at:index);try FileManager.default.createDirectory(at:index,withIntermediateDirectories:true)
        XCTAssertThrowsError(try library.removeGames(ids:Set(batch.map(\.id)),console:.atari2600))
        XCTAssertEqual(library.games,batch)
        for game in batch {XCTAssertTrue(FileManager.default.fileExists(atPath:library.file(game,"auto.vstate").path))}
        try FileManager.default.removeItem(at:index);try library.persist()
        XCTAssertEqual(Library(root:root).games,batch)
    }
    func testStagingRootFailurePreservesEveryGame()throws {
        let library=Library(root:root),batch=try fixture(3,in:library)
        // A filename at a staging destination is removed by recovery; an invalid
        // staging root reliably prevents staging without touching game data.
        let staging=root.appendingPathComponent("DeletedGames")
        try Data([0]).write(to:staging)
        XCTAssertThrowsError(try library.removeGames(ids:Set(batch.map(\.id)),console:.atari2600))
        XCTAssertEqual(library.games,batch)
        for game in batch {XCTAssertTrue(FileManager.default.fileExists(atPath:library.romURL(game).path))}
    }
    func testInterruptedBatchRestoresBeforeCommitAndCleansAfterCommit()throws {
        let library=Library(root:root),batch=try fixture(8,in:library)
        let staging=root.appendingPathComponent("DeletedGames")
        try FileManager.default.createDirectory(at:staging,withIntermediateDirectories:true)
        func stage()throws {for game in batch {try FileManager.default.moveItem(at:library.directory(game.id),to:staging.appendingPathComponent(game.id))}}
        try stage();let recovered=Library(root:root)
        XCTAssertNil(recovered.error);XCTAssertEqual(recovered.games,batch)
        for game in batch {XCTAssertTrue(FileManager.default.fileExists(atPath:library.file(game,"slot-1.vstate").path))}
        try stage();try JSONEncoder().encode([Game]()).write(to:root.appendingPathComponent("library.json"),options:.atomic)
        let committed=Library(root:root);XCTAssertNil(committed.error);XCTAssertTrue(committed.games.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:staging.path).isEmpty)
    }
    func testRejectsCrossConsoleSelectionBeforeMovingAnything()throws {
        let library=Library(root:root),a=try fixture(2,in:library),b=try fixture(1,console:.nes,offset:3,in:library)
        XCTAssertThrowsError(try library.removeGames(ids:Set((a+b).map(\.id)),console:.atari2600))
        XCTAssertEqual(library.games,a+b)
        for game in a+b {XCTAssertTrue(FileManager.default.fileExists(atPath:library.romURL(game).path))}
    }
    func testEmptyStaleAndInvalidSelections()throws {
        let library=Library(root:root),batch=try fixture(2,in:library)
        XCTAssertTrue(try library.removeGames(ids:[],console:.atari2600).isEmpty)
        XCTAssertTrue(try library.removeGames(ids:[String(repeating:"f",count:64)],console:.atari2600).isEmpty)
        XCTAssertThrowsError(try library.removeGames(ids:[batch[0].id,"../outside"],console:.atari2600))
        XCTAssertEqual(library.games,batch)
        XCTAssertEqual(try library.removeGames(ids:[batch[0].id],console:.atari2600),[batch[0]])
        XCTAssertTrue(try library.removeGames(ids:[batch[0].id],console:.atari2600).isEmpty)
        XCTAssertEqual(library.games,[batch[1]])
    }
    func testMissingFilesDoNotBlockDeletionOfStaleEntry()throws {
        let library=Library(root:root),batch=try fixture(2,in:library)
        try FileManager.default.removeItem(at:library.directory(batch[0].id))
        XCTAssertEqual(try library.removeGames(ids:Set(batch.map(\.id)),console:.atari2600),batch)
        XCTAssertTrue(Library(root:root).games.isEmpty)
    }
}
