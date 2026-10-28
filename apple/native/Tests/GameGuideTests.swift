import XCTest
@testable import VetaNative

@MainActor final class GameGuideTests: XCTestCase {
    func testExactConsoleAndTitleMatchingAvoidsSequelsRemakesAndHacks() {
        XCTAssertEqual(GuideCatalog.suggestions(for: Game(id:"1",name:"Legend of Zelda, The (USA) [!].nes")).count,1)
        XCTAssertTrue(GuideCatalog.suggestions(for: Game(id:"1",name:"The Legend of Zelda (Hack)")).isEmpty)
        XCTAssertTrue(GuideCatalog.suggestions(for: Game(id:"1",name:"Zelda II: The Adventure of Link")).isEmpty)
        XCTAssertTrue(GuideCatalog.suggestions(for: Game(id:"1",name:"The Legend of Zelda: Ocarina of Time",console:.threeDS)).isEmpty)
        XCTAssertEqual(GuideCatalog.suggestions(for: Game(id:"1",name:"The Legend of Zelda: Ocarina of Time",console:.n64)).count,1)
    }
    func testLinksValidateSchemeCredentialsLengthAndRestoreLegacyGame() throws {
        for bad in ["javascript:alert(1)","file:///private/guide.html","http://example.com/guide","https://user:password@example.com/guide","https:///guide","https://example.com/"+String(repeating:"a",count:2048)] {
            XCTAssertThrowsError(try GameGuide(title:"Guide",address:bad),bad)
        }
        XCTAssertThrowsError(try GameGuide(title:" ",address:"https://example.com/guide"))
        let guide=try GameGuide(title:" Guía 日本語 ",address:" https://example.com/guide#chapter2 ")
        XCTAssertEqual(guide.title,"Guía 日本語");XCTAssertEqual(guide.url.fragment,"chapter2")
        let legacy=Data(#"{"id":"legacy","name":"Old"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(Game.self,from:legacy).guide)
        let corrupt=Data(#"{"id":"legacy","name":"Old","guide":{"title":"Bad","url":"file:///private/data"}}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(Game.self,from:corrupt).guide)
    }
    func testSearchEncodesNamesAndKeepsPlatformAndLanguage() throws {
        let title="Pokémon & Zelda #? 日本語"
        let components=try XCTUnwrap(URLComponents(url:GuideCatalog.searchURL(title:title,console:.gbc,site:"strategywiki.org",language:.spanish),resolvingAgainstBaseURL:false))
        XCTAssertEqual(components.host,"www.google.com")
        let query=try XCTUnwrap(components.queryItems?.first?.value)
        XCTAssertTrue(query.contains(title));XCTAssertTrue(query.contains("Game Boy Color"));XCTAssertTrue(query.contains("guía completa"));XCTAssertTrue(query.contains("site:strategywiki.org"))
        XCTAssertEqual(components.queryItems?.count,1)
        XCTAssertFalse(GuideCatalog.searchURL(title:"Game",console:.nes,site:"evil.example").absoluteString.contains("evil"))
    }
    func testGuideSurvivesBackupAndUpdatingStaleGamePreservesOtherMetadata() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let library=Library(root:root.appendingPathComponent("original"))
        let rom=try Data(contentsOf:XCTUnwrap(Bundle.main.url(forResource:"thwaite",withExtension:"nes",subdirectory:"Content/thwaite")))
        let original=try library.add(data:rom,name:"Thwaite")
        var latest=original;latest.favorite=true;library.update(latest)
        let guide=try GameGuide(title:"Author guide",address:"https://example.com/thwaite")
        try library.setGuide(guide,for:original)
        XCTAssertTrue(try XCTUnwrap(library.games.first).favorite)
        XCTAssertEqual(Library(root:library.root).games.first?.guide,guide)
        let archive=try library.export();defer{try? FileManager.default.removeItem(at:archive)}
        let restored=Library(root:root.appendingPathComponent("restored"));try restored.importURL(archive)
        XCTAssertEqual(restored.games.first?.guide,guide)
        let before=try Data(contentsOf:library.romURL(original))
        try library.setGuide(nil,for:original)
        XCTAssertNil(Library(root:library.root).games.first?.guide)
        XCTAssertEqual(try Data(contentsOf:library.romURL(original)),before)
        // Failed persistence must leave the published library unchanged.
        let index=library.root.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at:index);try FileManager.default.createDirectory(at:index,withIntermediateDirectories:true)
        XCTAssertThrowsError(try library.setGuide(guide,for:original))
        XCTAssertNil(library.games.first?.guide)
    }
}
