import XCTest
import UIKit
#if VETA_JIT_DEVELOPMENT
@testable import VetaJITLab
#else
@testable import VetaNative
#endif

@MainActor final class LocalCoverImportTests:XCTestCase {
    var root:URL!,input:URL!,library:Library!,store:ArtworkStore!,defaults:UserDefaults!,suite:String!
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("LocalCoverTests-"+UUID().uuidString)
        input=root.appendingPathComponent("input");try FileManager.default.createDirectory(at:input,withIntermediateDirectories:true)
        library=Library(root:root.appendingPathComponent("library"));suite=UUID().uuidString;defaults=UserDefaults(suiteName:suite)!
        store=ArtworkStore(root:library.root,defaults:defaults)
    }
    override func tearDownWithError()throws {try? FileManager.default.removeItem(at:root);defaults.removePersistentDomain(forName:suite)}
    func rom(_ name:String="Game (USA).nes",folder:URL?=nil,marker:UInt8=0)throws->URL {
        var data=Data(repeating:0,count:16+16384+8192);data.replaceSubrange(0..<6,with:[0x4e,0x45,0x53,0x1a,1,1]);data[100]=marker
        let path=(folder ?? input).appendingPathComponent(name);try data.write(to:path);return path
    }
    func picture(_ name:String="Game (USA).png",folder:URL?=nil,color:UIColor = .red)throws->URL {
        let f=UIGraphicsImageRendererFormat();f.scale=1
        let data=UIGraphicsImageRenderer(size:CGSize(width:200,height:300),format:f).pngData{c in color.setFill();c.fill(CGRect(x:0,y:0,width:200,height:300))}
        let path=(folder ?? input).appendingPathComponent(name);try data.write(to:path);return path
    }
    func testCoordinatedCloudSnapshotImportsNestedGamesAndCovers()throws {
        let folder=input.appendingPathComponent("NES");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        _ = try rom("Cloud A.nes",folder:folder,marker:5)
        _ = try picture("Cloud A.png",folder:folder)
        _ = try rom("Cloud B.nes",folder:folder,marker:6)
        let preparation=CloudImportPreparation(extensions:LocalCoverImport.gameExtensions.union(LocalCoverImport.imageExtensions))
        let snapshot=try preparation.prepare([input],temporaryRoot:root){_,_,_ in}
        let first=try library.importURLs(snapshot.files,console:.nes,artwork:store)
        XCTAssertEqual(first.games,2);XCTAssertEqual(first.covers,1);XCTAssertEqual(library.games.count,2)
        let game=try XCTUnwrap(library.games.first);let save=Data([9,8,7]);try save.write(to:library.file(game,"battery.sav"))
        _ = try library.importURLs(snapshot.files,console:.nes,artwork:store)
        XCTAssertEqual(library.games.count,2);XCTAssertEqual(try Data(contentsOf:library.file(game,"battery.sav")),save)
        snapshot.remove();try FileManager.default.removeItem(at:input)
        for game in library.games {XCTAssertTrue(FileManager.default.fileExists(atPath:library.romURL(game).path))}
        XCTAssertEqual(try Data(contentsOf:library.file(game,"battery.sav")),save)
    }
    func testIsolatedProviderURLsImportCoverAndDiscTracks()throws {
        let other=input.appendingPathComponent("provider-item-2"),third=input.appendingPathComponent("provider-item-3")
        try FileManager.default.createDirectory(at:other,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:third,withIntermediateDirectories:true)
        let source=try rom("Cloud.nes"),image=try picture("Cloud.png",folder:other)
        let op=CloudImportPreparation(extensions:LocalCoverImport.gameExtensions.union(LocalCoverImport.imageExtensions))
        let snapshot=try op.prepare([source,image],temporaryRoot:root,combineExplicitFiles:true){_,_,_ in};defer{snapshot.remove()}
        let result=try library.importURLs(snapshot.files,console:.nes,artwork:store)
        XCTAssertEqual(result.covers,1);XCTAssertEqual(result.games,1)
        let cue=input.appendingPathComponent("Race.cue"),bin=other.appendingPathComponent("track.bin"),cover=try picture("Race.png",folder:third)
        try Data("FILE \"track.bin\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n".utf8).write(to:cue)
        try Data(repeating:0,count:2352*2).write(to:bin)
        let disc=try op.prepare([cue,bin,cover],temporaryRoot:root,combineExplicitFiles:true){_,_,_ in};defer{disc.remove()}
        let imported=try library.importURLs(disc.files,console:.ps1,artwork:store)
        XCTAssertEqual(imported.covers,1);XCTAssertEqual(imported.games,1)
    }
    func testOptionalSiblingAndOfflinePersistence()throws {
        let source=try rom(),bytes=try Data(contentsOf:source)
        let first=try library.importURLs([source],console:.nes,artwork:store)
        XCTAssertEqual(first.games,1);XCTAssertEqual(first.covers,0)
        let game=try XCTUnwrap(library.games.first)
        let save=Data([1,2,3]);try save.write(to:library.file(game,"battery.sav"))
        let image=try picture(),original=try Data(contentsOf:image)
        let second=try library.importURLs([source],console:.nes,artwork:store)
        XCTAssertEqual(second.covers,1);XCTAssertEqual(library.games.count,1)
        XCTAssertEqual(store.record(game)?.manual,true);XCTAssertNil(store.record(game)?.source)
        XCTAssertNotNil(ArtworkStore(root:library.root,defaults:defaults).image(game))
        XCTAssertEqual(try Data(contentsOf:source),bytes);XCTAssertEqual(try Data(contentsOf:library.romURL(game)),bytes)
        XCTAssertEqual(try Data(contentsOf:library.file(game,"battery.sav")),save);XCTAssertEqual(try Data(contentsOf:image),original)
    }
    func testSelectedPairAndFolderIgnoreUnrelatedFiles()throws {
        let source=try rom(),image=try picture("GAME (USA).PNG")
        try Data("notes".utf8).write(to:input.appendingPathComponent("README.txt"))
        let nested=input.appendingPathComponent("nested");try FileManager.default.createDirectory(at:nested,withIntermediateDirectories:true)
        _ = try rom("Other.nes",folder:nested,marker:1)
        let pair=try library.importURLs([image,source],console:.nes,artwork:store)
        XCTAssertEqual(pair.covers,1);XCTAssertEqual(pair.games,1)
        let folder=try library.importURLs([input],console:.nes,artwork:store)
        XCTAssertEqual(folder.games,1);XCTAssertEqual(folder.covers,0);XCTAssertEqual(library.games.count,1)
    }
    func testInvalidImageDoesNotRejectROMAndExistingCoverWins()throws {
        let source=try rom(),bad=input.appendingPathComponent("Game (USA).png")
        try Data("invalid PNG".utf8).write(to:bad)
        let result=try library.importURLs([source,bad],console:.nes,artwork:store)
        XCTAssertEqual(result.games,1);XCTAssertEqual(result.covers,0);XCTAssertEqual(result.unreadableCovers,1)
        let game=try XCTUnwrap(library.games.first),image=try picture(color:.blue)
        try store.setManual(Data(contentsOf:image),for:game);let previous=try Data(contentsOf:store.url(game))
        _ = try picture(color:.green)
        let repeated=try library.importURLs([input],console:.nes,artwork:store)
        XCTAssertEqual(repeated.covers,0);XCTAssertEqual(try Data(contentsOf:store.url(game)),previous)
    }
    func testExactNamesAndNoCrossFolderAssociation()throws {
        let source=try rom();_ = try picture("Game (Europe).png")
        let another=root.appendingPathComponent("another");try FileManager.default.createDirectory(at:another,withIntermediateDirectories:true)
        let wrong=try picture(folder:another)
        let result=try library.importURLs([source,wrong],console:.nes,artwork:store)
        XCTAssertEqual(result.covers,0)
        XCTAssertNil(store.record(try XCTUnwrap(library.games.first)))
        let onlyImage=try library.importURLs([wrong],console:.nes,artwork:store)
        XCTAssertEqual(onlyImage.games,0);XCTAssertEqual(library.games.count,1)
    }
    func testImagePriorityAndSymlinkSafety()throws {
        let source=try rom();_ = try picture("Game (USA).jpg",color:.blue);let png=try picture(color:.red)
        _ = try library.importURLs([source],console:.nes,artwork:store)
        let game=try XCTUnwrap(library.games.first)
        XCTAssertEqual(store.record(game)?.image,try CoverImage.prepare(CoverImage.read(png)))
        let other=try rom("Other.nes",marker:1),link=input.appendingPathComponent("Other.png")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:png)
        let result=try library.importURLs([other],console:.nes,artwork:store)
        XCTAssertEqual(result.games,1);XCTAssertEqual(result.covers,0);XCTAssertEqual(result.unreadableCovers,1)
    }
    func testStreamedN64AndCUEDiscUseOriginalNames()throws {
        let n64=input.appendingPathComponent("Race.z64");var data=Data(repeating:0,count:4096);data.replaceSubrange(0..<4,with:[0x80,0x37,0x12,0x40]);try data.write(to:n64)
        _ = try picture("Race.png")
        let result=try library.importURLs([n64],console:.n64,artwork:store)
        XCTAssertEqual(result.covers,1);XCTAssertEqual(library.games.first?.contentName,"game.z64")
        let cue=input.appendingPathComponent("Racer.cue"),bin=input.appendingPathComponent("track.bin")
        try Data("FILE \"track.bin\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n".utf8).write(to:cue)
        try Data(repeating:0,count:2352*2).write(to:bin);_ = try picture("Racer.png")
        let disc=try library.importURLs([cue,bin],console:.ps1,artwork:store)
        XCTAssertEqual(disc.covers,1);XCTAssertEqual(disc.games,1)
        XCTAssertEqual(library.games.last?.contentName,"disc.cue")
    }
}
