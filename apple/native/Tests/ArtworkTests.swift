import XCTest
import UIKit
#if VETA_JIT_DEVELOPMENT
@testable import VetaJITLab
#else
@testable import VetaNative
#endif

actor StubCovers:CoverProviding {
    var result:DownloadedCover?
    var failing=false
    var delayed=false
    var calls=0
    private var continuation:CheckedContinuation<Void,Never>?
    func configure(_ result:DownloadedCover?,failing:Bool=false,delayed:Bool=false) {self.result=result;self.failing=failing;self.delayed=delayed}
    func release() {continuation?.resume();continuation=nil}
    func find(_ game:Game)async throws -> DownloadedCover? {
        calls+=1
        if delayed {await withCheckedContinuation{continuation=$0}}
        if failing {throw URLError(.notConnectedToInternet)}
        return result
    }
}
@MainActor final class ArtworkTests:XCTestCase {
    var root:URL!
    var defaults:UserDefaults!
    var suite:String!
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        suite="veta-artwork-test-"+UUID().uuidString;defaults=UserDefaults(suiteName:suite)
    }
    override func tearDownWithError()throws {try? FileManager.default.removeItem(at:root);defaults.removePersistentDomain(forName:suite)}
    func picture(_ color:UIColor = .red)->Data {
        let format=UIGraphicsImageRendererFormat();format.scale=1
        return UIGraphicsImageRenderer(size:CGSize(width:1200,height:800),format:format).jpegData(withCompressionQuality:0.9){ctx in color.setFill();ctx.fill(CGRect(x:0,y:0,width:1200,height:800))}
    }
    func game(_ library:Library)throws -> Game {
        var bytes=Data(repeating:0,count:16+16384+8192)
        bytes.replaceSubrange(0..<6,with:[0x4e,0x45,0x53,0x1a,1,1])
        return try library.add(data:bytes,name:"Artwork fixture.nes")
    }
    func downloaded()throws -> DownloadedCover {DownloadedCover(image:try CoverImage.prepare(picture()),source:URL(string:"https://raw.githubusercontent.com/libretro-thumbnails/Nintendo_-_Nintendo_Entertainment_System/master/Named_Boxarts/Test.png")!)}
    func testPublicEditionNeverRequestsRemoteCoversAndKeepsPersonalImages()async throws {
        try XCTSkipIf(ArtworkDistributionPolicy.allowsRemoteCovers,"This check targets the public edition")
        defaults.set(true,forKey:"native.autoArtwork")
        let library=Library(root:root),g=try game(library),stub=StubCovers()
        let store=ArtworkStore(root:root,provider:stub,defaults:defaults)
        XCTAssertFalse(store.enabled)
        try store.setManual(picture(.blue),for:g)
        let original=try Data(contentsOf:store.url(g))
        store.enabled=true
        store.schedule([g]);await store.search(g);await store.search(g,automatic:true)
        await Task.yield()
        let calls=await stub.calls;XCTAssertEqual(calls,0)
        XCTAssertEqual(try Data(contentsOf:store.url(g)),original)
        XCTAssertEqual(store.record(g)?.manual,true)
        XCTAssertNotNil(ArtworkStore(root:root,provider:stub,defaults:defaults).image(g))
    }
    func testNamesRegionsSequelsAndModifiedGames() {
        let names=["Super Mario Bros. (USA).png","Super Mario Bros. (Europe).png","Super Mario Bros. 2 (USA).png","Legend of Zelda, The (USA).png","1942 (Japan).png","Super Mario Bros. (USA) (Hack).png"]
        XCTAssertEqual(CoverMatcher.match("1095 - Super Mario Bros. (E) [!].nes",names:names),names[1])
        XCTAssertEqual(CoverMatcher.match("Super Mario Bros 2",names:names),names[2])
        XCTAssertEqual(CoverMatcher.match("The Legend of Zelda.nes",names:names),names[3])
        XCTAssertEqual(CoverMatcher.match("1942",names:names),names[4])
        XCTAssertNil(CoverMatcher.match("Super Mario Bros 3",names:names))
        XCTAssertNil(CoverMatcher.match("Super Mario Bros (Hack)",names:names))
        XCTAssertNil(CoverMatcher.match("Super Mario Bros [h1]",names:names))
        XCTAssertNil(CoverMatcher.match("No such homebrew 987654321",names:names))
        XCTAssertNotEqual(CoverMatcher.key("ゼルダ"),CoverMatcher.key("マリオ"))
        XCTAssertNotEqual(CoverMatcher.key("Pokemon (Red)"),CoverMatcher.key("Pokemon (Blue)"))
        XCTAssertEqual(CoverMatcher.key("Tetris (Europe) (En,Fr,De,Es) (Rev 1)"),"tetris")
        XCTAssertEqual(CoverMatcher.match("Donkey Kong [GB]",names:["Donkey Kong (World) (SGB Enhanced).png","Donkey Kong Land (World) (SGB Enhanced).png"]),"Donkey Kong (World) (SGB Enhanced).png")
        XCTAssertEqual(CoverMatcher.key("Link's Awakening DX (USA) (SGB Enhanced) (GB Compatible).png"),CoverMatcher.key("Link's Awakening DX [GBC]"))
        XCTAssertEqual(CoverMatcher.match("The Legend of Zelda - Ocarina of Time",names:["Legend of Zelda, The - Ocarina of Time (USA).png","Legend of Zelda, The - Majora's Mask (USA).png"]),"Legend of Zelda, The - Ocarina of Time (USA).png")
        XCTAssertEqual(Set(GameConsole.allCases.map(\.artworkRepository)).count,GameConsole.allCases.count)
    }
    func testIndexedArtworkAliasesCannotEscapeOrChangeGame() {
        let revision="Super Mario 3D Land (USA) (En,Fr,Es) (Rev 1).png"
        let base="Super Mario 3D Land (USA) (En,Fr,Es).png"
        let other="Super Mario 3D World (USA).png"
        let names:Set<String>=[revision,base,other]
        XCTAssertEqual(CoverMatcher.alias(Data(base.utf8),from:revision,names:names),base)
        for bad in [revision,other,"../"+base,"https://example.com/"+base,"Unknown.png",String(repeating:"x",count:1025)] {
            XCTAssertNil(CoverMatcher.alias(Data(bad.utf8),from:revision,names:names))
        }
        XCTAssertNil(CoverMatcher.alias(Data([137,80,78,71]),from:revision,names:names))
    }
    func testImageValidationAndDownsampling()throws {
        let data=try CoverImage.prepare(picture())
        let file=root.appendingPathComponent("manual.png");try picture().write(to:file)
        XCTAssertNotNil(UIImage(data:try CoverImage.read(file)))
        let image=try XCTUnwrap(UIImage(data:data))
        XCTAssertEqual(image.size.width,768);XCTAssertEqual(image.size.height,512)
        XCTAssertThrowsError(try CoverImage.prepare(Data("<html>not an image</html>".utf8)))
        XCTAssertThrowsError(try CoverImage.prepare(Data(count:CoverImage.maximumBytes+1)))
        let invalid=CoverRecord(image:data,manual:false,source:URL(string:"http://example.com/cover"),savedAt:Date())
        XCTAssertThrowsError(try CoverRecord.decode(invalid.encoded()))
        let oversized=CoverRecord(image:picture(),manual:true,source:nil,savedAt:Date())
        XCTAssertThrowsError(try CoverRecord.decode(oversized.encoded()),"Backups must contain bounded thumbnails, never full-resolution decompression bombs")
    }
    func testAutomaticDownloadPersistenceAndOfflineReuse()async throws {
        try XCTSkipUnless(ArtworkDistributionPolicy.allowsRemoteCovers,"Remote provider is excluded from the public distribution")
        let library=Library(root:root),g=try game(library),stub=StubCovers()
        let originalROM=try Data(contentsOf:library.romURL(g))
        let battery=Data([1,2,3,4]);try battery.write(to:library.file(g,"battery.sav"))
        try await stub.configure(downloaded())
        let store=ArtworkStore(root:root,provider:stub,defaults:defaults)
        await store.search(g,automatic:true)
        XCTAssertNotNil(store.image(g));XCTAssertEqual(store.record(g)?.manual,false)
        let offline=ArtworkStore(root:root,provider:stub,defaults:defaults)
        XCTAssertNotNil(offline.image(g))
        await offline.search(g,automatic:true)
        let calls=await stub.calls;XCTAssertEqual(calls,1,"An existing cover must not be downloaded again")
        XCTAssertEqual(try Data(contentsOf:library.romURL(g)),originalROM)
        XCTAssertEqual(try Data(contentsOf:library.file(g,"battery.sav")),battery)
    }
    func testFailedSearchAndNoMatchKeepManualCover()async throws {
        try XCTSkipUnless(ArtworkDistributionPolicy.allowsRemoteCovers,"Remote provider is excluded from the public distribution")
        let library=Library(root:root),g=try game(library),stub=StubCovers(),store=ArtworkStore(root:root,provider:stub,defaults:defaults)
        try store.setManual(picture(.blue),for:g)
        let original=try Data(contentsOf:store.url(g))
        await stub.configure(nil,failing:true)
        await store.search(g)
        XCTAssertEqual(try Data(contentsOf:store.url(g)),original)
        XCTAssertTrue(store.messages[g.id]?.contains("conserva") == true)
        await stub.configure(nil)
        await store.search(g)
        XCTAssertEqual(try Data(contentsOf:store.url(g)),original)
        XCTAssertTrue(store.messages[g.id]?.contains("coincidencia") == true)
        try await stub.configure(downloaded())
        await store.search(g,automatic:true)
        XCTAssertEqual(try Data(contentsOf:store.url(g)),original)
        await store.search(g)
        XCTAssertEqual(store.record(g)?.manual,false,"Explicit search may replace a personal cover only on success")
    }
    func testManualSelectionWinsAgainstDownloadInFlight()async throws {
        try XCTSkipUnless(ArtworkDistributionPolicy.allowsRemoteCovers,"Remote provider is excluded from the public distribution")
        let library=Library(root:root),g=try game(library),stub=StubCovers(),store=ArtworkStore(root:root,provider:stub,defaults:defaults)
        try await stub.configure(downloaded(),delayed:true)
        let search=Task {await store.search(g,automatic:true)}
        while await stub.calls==0 {await Task.yield()}
        try store.setManual(picture(.blue),for:g)
        let manual=try Data(contentsOf:store.url(g))
        await stub.release();await search.value
        XCTAssertEqual(try Data(contentsOf:store.url(g)),manual)
        XCTAssertEqual(store.record(g)?.manual,true)
        XCTAssertTrue(store.messages[g.id]?.contains("personal") == true)
    }
    func testDisableWhileDownloadIsInFlight()async throws {
        try XCTSkipUnless(ArtworkDistributionPolicy.allowsRemoteCovers,"Remote provider is excluded from the public distribution")
        let library=Library(root:root),g=try game(library),stub=StubCovers(),store=ArtworkStore(root:root,provider:stub,defaults:defaults)
        try await stub.configure(downloaded(),delayed:true)
        let search=Task {await store.search(g,automatic:true)}
        while await stub.calls==0 {await Task.yield()}
        store.enabled=false
        await stub.release();await search.value
        XCTAssertNil(store.record(g));XCTAssertTrue(store.searching.isEmpty)
        XCTAssertTrue(store.messages[g.id]?.contains("desactivada") == true)
    }
    func testDisabledAutomaticDownloadsAndNegativeCache()async throws {
        try XCTSkipUnless(ArtworkDistributionPolicy.allowsRemoteCovers,"Remote provider is excluded from the public distribution")
        let library=Library(root:root),g=try game(library),stub=StubCovers(),store=ArtworkStore(root:root,provider:stub,defaults:defaults)
        store.enabled=false;store.schedule([g]);await store.search(g,automatic:true)
        let calls=await stub.calls;XCTAssertEqual(calls,0)
        XCTAssertFalse(ArtworkStore(root:root,provider:stub,defaults:defaults).enabled)
        store.enabled=true;await store.search(g,automatic:true)
        let reopened=ArtworkStore(root:root,provider:stub,defaults:defaults);reopened.schedule([g]);await Task.yield()
        let after=await stub.calls;XCTAssertEqual(after,1,"Persist misses across launches to avoid repeated traffic")
    }
    func testBackupRestoresArtworkWithoutReplacingExistingGames()throws {
        let library=Library(root:root),g=try game(library),store=ArtworkStore(root:root,defaults:defaults)
        let rom=try Data(contentsOf:library.romURL(g))
        try store.setManual(picture(.blue),for:g)
        let backup=try library.export();defer{try? FileManager.default.removeItem(at:backup)}
        let destination=root.appendingPathComponent("restored"),restored=Library(root:destination)
        try restored.importURL(backup)
        let saved=ArtworkStore(root:destination,defaults:defaults)
        XCTAssertEqual(saved.record(g)?.manual,true);XCTAssertNotNil(saved.image(g))
        XCTAssertEqual(try Data(contentsOf:restored.romURL(g)),rom)
        try saved.setManual(picture(.green),for:g)
        let newer=try Data(contentsOf:saved.url(g));try restored.importURL(backup)
        XCTAssertEqual(try Data(contentsOf:saved.url(g)),newer)
        var archive=try JSONDecoder().decode(NativeBackup.self,from:Data(contentsOf:backup))
        var entries=archive.entries;entries[0].cover=Data("invalid".utf8)
        archive=NativeBackup(format:archive.format,version:archive.version,entries:entries)
        try JSONEncoder().encode(archive).write(to:backup)
        let invalid=Library(root:root.appendingPathComponent("invalid"))
        XCTAssertThrowsError(try invalid.importURL(backup));XCTAssertTrue(invalid.games.isEmpty)
    }
    // Explicit acceptance check against the real provider; normal offline tests
    // above never depend on external service availability.
    func testLiveProviderNESGameBoyPlayStation()async throws {
        try XCTSkipUnless(ArtworkDistributionPolicy.allowsRemoteCovers,"Remote provider is excluded from the public distribution")
        let provider=LibretroArtwork(cache:root.appendingPathComponent("indexes"))
        for (name,console) in [("Super Mario Bros. (USA)",GameConsole.nes),("Tetris (World)",.gb),("Crash Bandicoot (USA)",.ps1),("Super Mario 3D Land",.threeDS),("The Legend of Zelda - Ocarina of Time",.n64)] {
            let cover=try await provider.find(Game(id:"test",name:name,console:console))
            let found=try XCTUnwrap(cover,"Missing real artwork for \(console.name)")
            XCTAssertNotNil(UIImage(data:found.image));XCTAssertEqual(found.source.host,"raw.githubusercontent.com")
        }
    }
}

private final class ArtworkHTTP:URLProtocol {
    struct Reply {let status:Int;let body:Data;var headers:[String:String]=[:]}
    private static let lock=NSLock()
    private static var replies:[Reply]=[]
    private static var calls=0
    static func reset(_ values:[Reply]) {lock.lock();defer{lock.unlock()};replies=values;calls=0}
    static func count()->Int {lock.lock();defer{lock.unlock()};return calls}
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        Self.lock.lock();Self.calls+=1
        let reply=Self.replies.isEmpty ? Reply(status:503,body:Data()):Self.replies.removeFirst()
        Self.lock.unlock()
        let response=HTTPURLResponse(url:request.url!,statusCode:reply.status,httpVersion:"HTTP/1.1",headerFields:reply.headers)!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
extension ArtworkTests {
    private func httpProvider()->LibretroArtwork {
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[ArtworkHTTP.self]
        return LibretroArtwork(cache:root.appendingPathComponent("http-indexes"),session:URLSession(configuration:config))
    }
    func testNetworkSizeLimitsAndInvalidImages()async throws {
        try XCTSkipUnless(ArtworkDistributionPolicy.allowsRemoteCovers,"Remote provider is excluded from the public distribution")
        let provider=httpProvider(),url=URL(string:"https://api.github.com/test")!
        ArtworkHTTP.reset([.init(status:200,body:Data([1]),headers:["Content-Length":"1000"])])
        do {_ = try await provider.fetch(url,limit:10);XCTFail("Oversized declared body accepted")} catch {}
        ArtworkHTTP.reset([.init(status:200,body:Data(repeating:1,count:20))])
        do {_ = try await provider.fetch(url,limit:10);XCTFail("Unbounded streamed body accepted")} catch {}
        let tree=Data(#"{"tree":[{"path":"Tetris (World).png","type":"blob"}],"truncated":false}"#.utf8)
        ArtworkHTTP.reset([.init(status:200,body:tree),.init(status:200,body:Data("<html>error</html>".utf8))])
        do {_ = try await provider.find(Game(id:"test",name:"Tetris",console:.gb));XCTFail("HTML accepted as cover")} catch {}
        XCTAssertEqual(ArtworkHTTP.count(),2)
    }
    func testRateLimitAndTruncatedCatalogAreNotRetriedPerGame()async throws {
        try XCTSkipUnless(ArtworkDistributionPolicy.allowsRemoteCovers,"Remote provider is excluded from the public distribution")
        let provider=httpProvider()
        ArtworkHTTP.reset([.init(status:429,body:Data())])
        for console in [GameConsole.nes,.gb] {
            do {_ = try await provider.find(Game(id:"test",name:"Tetris",console:console));XCTFail("429 accepted")} catch {}
        }
        XCTAssertEqual(ArtworkHTTP.count(),1,"A rate limit must suppress the remaining automatic queue's requests")
        let second=httpProvider()
        ArtworkHTTP.reset([.init(status:200,body:Data(#"{"tree":[],"truncated":true}"#.utf8))])
        for _ in 0..<2 {
            do {_ = try await second.find(Game(id:"test",name:"Tetris",console:.gb));XCTFail("Truncated index accepted")} catch {}
        }
        XCTAssertEqual(ArtworkHTTP.count(),1)
    }
    func testExpiredIndexRemainsUsableDuringOutage()async throws {
        try XCTSkipUnless(ArtworkDistributionPolicy.allowsRemoteCovers,"Remote provider is excluded from the public distribution")
        let cache=root.appendingPathComponent("http-indexes")
        try FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true)
        let stale=LibretroArtwork.Index(date:Date().addingTimeInterval(-8*86400),names:["Tetris (World).png"])
        try JSONEncoder().encode(stale).write(to:cache.appendingPathComponent(GameConsole.gb.artworkRepository+".json"))
        let provider=httpProvider()
        ArtworkHTTP.reset([.init(status:503,body:Data())])
        let names=try await provider.index(GameConsole.gb.artworkRepository)
        XCTAssertEqual(names,stale.names)
        _ = try await provider.index(GameConsole.gb.artworkRepository)
        XCTAssertEqual(ArtworkHTTP.count(),1)
    }
}
