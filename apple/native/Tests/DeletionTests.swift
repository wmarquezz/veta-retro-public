import XCTest
import UIKit
@testable import VetaNative

@MainActor final class DeletionTests:XCTestCase {
    var temp:URL!
    override func setUpWithError()throws {temp=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)}
    override func tearDownWithError()throws {try? FileManager.default.removeItem(at:temp)}
    func rom(_ name:String="thwaite")throws -> Data {
        let bundle=Bundle(for:Self.self)
        let url=try XCTUnwrap(bundle.url(forResource:"thwaite",withExtension:"nes",subdirectory:"SaveFixtures") ?? bundle.url(forResource:"thwaite",withExtension:"nes"))
        var data=try Data(contentsOf:url)
        if name != "thwaite" {data[data.count-1] ^= 1} // distinct deletion fixture; never executed
        return data
    }

    func testDeletionPreservesOriginalsOtherGamesAndAllowsFreshImport()throws {
        let source=temp.appendingPathComponent("original.nes");try rom().write(to:source)
        let library=Library(root:temp.appendingPathComponent("library"));try library.importURL(source)
        var game=try XCTUnwrap(library.games.first);game.favorite=true;game.lastPlayed=Date();library.update(game)
        let other=try library.add(data:rom("croom"),name:"Concentration Room")
        for name in ["quick.vstate","auto.vstate","battery.sav","clock.rtc","cover.vcover"] {try Data([1,2,3]).write(to:library.file(game,name))}
        let saves=library.directory(game.id).appendingPathComponent("CoreSaves")
        try FileManager.default.createDirectory(at:saves,withIntermediateDirectories:true);try Data([4]).write(to:saves.appendingPathComponent("memory.card"))
        let otherROM=try Data(contentsOf:library.romURL(other))
        try library.remove(game)
        XCTAssertEqual(library.games.map(\.id),[other.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath:library.directory(game.id).path))
        XCTAssertEqual(try Data(contentsOf:source),try rom())
        XCTAssertEqual(try Data(contentsOf:library.romURL(other)),otherROM)
        let reopened=Library(root:library.root);XCTAssertNil(reopened.error);XCTAssertEqual(reopened.games.map(\.id),[other.id])
        try reopened.importURL(source)
        let fresh=try XCTUnwrap(reopened.games.first{$0.id==game.id})
        XCTAssertFalse(fresh.favorite);XCTAssertNil(fresh.lastPlayed)
        XCTAssertFalse(FileManager.default.fileExists(atPath:reopened.file(fresh,"quick.vstate").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:reopened.file(fresh,"cover.vcover").path))
    }
    func testFailedIndexCommitRestoresGameFiles()throws {
        let library=Library(root:temp),game=try library.add(data:rom(),name:"Thwaite")
        let index=temp.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at:index)
        try FileManager.default.createDirectory(at:index,withIntermediateDirectories:true)
        XCTAssertThrowsError(try library.remove(game))
        XCTAssertEqual(library.games,[game]);XCTAssertEqual(try Data(contentsOf:library.romURL(game)),try rom())
        try FileManager.default.removeItem(at:index);try library.persist()
        XCTAssertEqual(Library(root:temp).games,[game])
    }
    func testInterruptedDeletionRecoversBeforeCommitAndFinishesAfterCommit()throws {
        let library=Library(root:temp),game=try library.add(data:rom(),name:"Thwaite")
        let staging=temp.appendingPathComponent("DeletedGames")
        try FileManager.default.createDirectory(at:staging,withIntermediateDirectories:true)
        let moved=staging.appendingPathComponent(game.id)
        try FileManager.default.moveItem(at:library.directory(game.id),to:moved)
        let recovered=Library(root:temp)
        XCTAssertNil(recovered.error);XCTAssertEqual(recovered.games,[game])
        XCTAssertEqual(try Data(contentsOf:recovered.romURL(game)),try rom())
        try FileManager.default.moveItem(at:recovered.directory(game.id),to:moved)
        try JSONEncoder().encode([Game]()).write(to:temp.appendingPathComponent("library.json"),options:.atomic)
        let committed=Library(root:temp)
        XCTAssertNil(committed.error);XCTAssertTrue(committed.games.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:moved.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:library.directory(game.id).path))
    }
    func testInvalidIdentifierCannotDeleteOtherPaths()throws {
        let library=Library(root:temp.appendingPathComponent("library")),outside=temp.appendingPathComponent("keep.txt")
        try Data([1]).write(to:outside)
        let invalid=Game(id:"../keep.txt",name:"Invalid");library.games=[invalid]
        XCTAssertThrowsError(try library.remove(invalid))
        XCTAssertEqual(try Data(contentsOf:outside),Data([1]))
    }
    func testDeletedGameCannotRegainCoverFromOldDownloadAfterReimport()async throws {
        try XCTSkipUnless(ArtworkDistributionPolicy.allowsRemoteCovers, "Remote artwork is disabled in the public edition")
        let library=Library(root:temp),game=try library.add(data:rom(),name:"Thwaite"),provider=StubCovers()
        let image=UIGraphicsImageRenderer(size:CGSize(width:32,height:32)).jpegData(withCompressionQuality:0.8){ctx in UIColor.blue.setFill();ctx.fill(CGRect(x:0,y:0,width:32,height:32))}
        let downloaded=DownloadedCover(image:image,source:URL(string:"https://raw.githubusercontent.com/libretro-thumbnails/Test/master/Named_Boxarts/Test.png")!)
        await provider.configure(downloaded,delayed:true)
        let store=ArtworkStore(root:temp,provider:provider)
        let search=Task {await store.search(game)}
        while await provider.calls==0 {await Task.yield()}
        try library.remove(game);store.forget(game)
        let reimported=try library.add(data:rom(),name:"Thwaite")
        await provider.release();await search.value
        XCTAssertNil(store.image(reimported));XCTAssertNil(store.record(reimported));XCTAssertNil(store.messages[game.id]);XCTAssertTrue(store.searching.isEmpty)
        await provider.configure(downloaded);await store.search(reimported)
        XCTAssertNotNil(store.image(reimported))
    }
}
