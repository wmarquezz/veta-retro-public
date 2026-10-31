import XCTest
import UIKit
import zlib
@testable import VetaNative

@MainActor final class BatchImportHistoryTests:XCTestCase {
    var root:URL!
    override func setUpWithError()throws {root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)}
    override func tearDownWithError()throws {try? FileManager.default.removeItem(at:root)}
    func write(_ name:String,_ data:Data)throws->URL {let p=root.appendingPathComponent(name);try data.write(to:p);return p}
    func image()->Data {UIGraphicsImageRenderer(size:CGSize(width:30,height:30)).pngData{ctx in UIColor.orange.setFill();ctx.fill(CGRect(x:0,y:0,width:30,height:30))}}
    func rom()throws->Data {let b=Bundle(for:Self.self);return try Data(contentsOf:XCTUnwrap(b.url(forResource:"thwaite",withExtension:"nes",subdirectory:"SaveFixtures") ?? b.url(forResource:"thwaite",withExtension:"nes")))}
    func zip(_ name:String,_ bytes:Data)->Data {
        var d=Data(),c=Data()
        func add(_ value:Int,_ n:Int,_ target:inout Data) {for i in 0..<n {target.append(UInt8(truncatingIfNeeded:value>>(i*8)))}}
        let crc=bytes.withUnsafeBytes{Int(crc32(0,$0.bindMemory(to:Bytef.self).baseAddress,uInt(bytes.count)))};let name=Data(name.utf8)
        for (v,n) in [(0x04034b50,4),(20,2),(0,2),(0,2),(0,2),(0,2),(crc,4),(bytes.count,4),(bytes.count,4),(name.count,2),(0,2)] {add(v,n,&d)}
        d.append(name);d.append(bytes)
        for (v,n) in [(0x02014b50,4),(0x0314,2),(20,2),(0,2),(0,2),(0,2),(0,2),(crc,4),(bytes.count,4),(bytes.count,4),(name.count,2),(0,2),(0,2),(0,2),(0,2),(0,4),(0,4)] {add(v,n,&c)}
        c.append(name);let offset=d.count;d.append(c)
        for (v,n) in [(0x06054b50,4),(0,2),(0,2),(1,2),(1,2),(c.count,4),(offset,4),(0,2)] {add(v,n,&d)}
        return d
    }
    func testBadZIPAndBadROMDoNotImportTheirPicturesButGoodGameDoes()throws {
        let good=try write("Good.zip",zip("Inside.nes",rom())),badZIP=try write("Broken.zip",Data([0,1])),badROM=try write("Invalid.nes",Data([0,1]))
        let covers=try ["Good.png","Broken.png","Invalid.png"].map{try write($0,image())}
        let library=Library(root:root.appendingPathComponent("library")),art=ArtworkStore(root:library.root)
        let summary=try library.importURLs([badZIP,good,badROM]+covers,console:.nes,artwork:art,continueOnError:true)
        XCTAssertEqual(summary.games,1);XCTAssertEqual(summary.covers,1);XCTAssertEqual(summary.issues.count,2)
        XCTAssertEqual(Set(summary.issues.map(\.file)),["Broken.zip","Invalid.nes"])
        XCTAssertEqual(library.games.count,1);let game=try XCTUnwrap(library.games.first)
        XCTAssertEqual(try Data(contentsOf:library.romURL(game)),try rom());XCTAssertNotNil(art.image(game))
        let coverFiles=FileManager.default.enumerator(at:library.root,includingPropertiesForKeys:nil)!.allObjects.compactMap{$0 as? URL}.filter{$0.lastPathComponent=="cover.vcover"}
        XCTAssertEqual(coverFiles.count,1)
        let saved=try ImportHistory.read(library.root);XCTAssertEqual(saved.first?.issues.map(\.file),summary.issues.map(\.file))
        for file in covers {XCTAssertEqual(try Data(contentsOf:file),image())}
    }
    func testCloudSnapshotContinuesAndPreservesOriginalArchiveNameForInvalidROM()throws {
        let good=try write("Good.zip",zip("inside.nes",rom())),corrupt=try write("Corrupt.zip",Data([0])),invalid=try write("Invalid ROM.zip",zip("different-name.nes",Data([0,1])))
        let images=try ["Good.png","Corrupt.png","Invalid ROM.png"].map{try write($0,image())}
        let op=CloudImportPreparation(extensions:LocalCoverImport.gameExtensions.union(LocalCoverImport.imageExtensions))
        let snapshot=try op.prepare([good,corrupt,invalid]+images,temporaryRoot:root,continueOnError:true){_,_,_ in};defer{snapshot.remove()}
        XCTAssertEqual(snapshot.issues.map(\.file),["Corrupt.zip"])
        let library=Library(root:root.appendingPathComponent("library")),art=ArtworkStore(root:library.root)
        let result=try library.importURLs(snapshot.files,console:.nes,artwork:art,continueOnError:true,initialIssues:snapshot.issues,sourceNames:snapshot.sourceNames)
        XCTAssertEqual(result.games,1);XCTAssertEqual(result.covers,1)
        XCTAssertEqual(Set(result.issues.map(\.file)),["Corrupt.zip","Invalid ROM.zip"])
        XCTAssertEqual(library.games.count,1)
    }
    func testAllInvalidLeavesNoGameOrCoverAndKeepsPersistentReport()throws {
        let bad=try write("Bad.zip",Data([0])),photo=try write("Bad.png",image()),library=Library(root:root.appendingPathComponent("library"))
        let result=try library.importURLs([bad,photo],console:.nes,artwork:ArtworkStore(root:library.root),continueOnError:true)
        XCTAssertEqual(result.games,0);XCTAssertEqual(result.covers,0);XCTAssertEqual(result.issues.count,1)
        XCTAssertTrue(Library(root:library.root).games.isEmpty)
        XCTAssertEqual(try ImportHistory.read(library.root).first?.issues.first?.file,"Bad.zip")
        XCTAssertFalse(FileManager.default.enumerator(at:library.root,includingPropertiesForKeys:nil)!.allObjects.compactMap{$0 as? URL}.contains{$0.lastPathComponent=="cover.vcover"})
    }
    func testInvalidCoverKeepsGameAndReportsOnlyCover()throws {
        let game=try write("Good.nes",rom()),photo=try write("Good.png",Data([0])),library=Library(root:root.appendingPathComponent("library"))
        let result=try library.importURLs([game,photo],console:.nes,artwork:ArtworkStore(root:library.root),continueOnError:true)
        XCTAssertEqual(result.games,1);XCTAssertEqual(result.covers,0);XCTAssertEqual(result.issues.first?.file,"Good.png");XCTAssertEqual(result.issues.first?.coverOnly,true)
    }
    func testMissingCloudFileDoesNotBlockValidFile()throws {
        let valid=try write("Good.nes",rom()),missing=root.appendingPathComponent("Missing.nes")
        let snapshot=try CloudImportPreparation(extensions:["nes"]).prepare([missing,valid],temporaryRoot:root,continueOnError:true){_,_,_ in};defer{snapshot.remove()}
        XCTAssertEqual(snapshot.files.count,1);XCTAssertEqual(snapshot.issues.map(\.file),["Missing.nes"])
    }
    func testMissingFirstDiscTrackCannotImportLaterTracksSeparately()throws {
        let cue=try write("Bad Disc.cue",Data("FILE \"Missing.bin\" BINARY\n TRACK 01 MODE2/2352\n INDEX 01 00:00:00\nFILE \"Track.bin\" BINARY\n TRACK 02 AUDIO\n INDEX 01 00:00:00\n".utf8)),track=try write("Track.bin",Data(repeating:0,count:2352)),good=try write("Good.nes",rom())
        let library=Library(root:root.appendingPathComponent("library"))
        let result=try library.importURLs([cue,track,good],console:nil,continueOnError:true)
        XCTAssertEqual(result.games,1);XCTAssertEqual(result.issues.map(\.file),["Bad Disc.cue"])
        XCTAssertEqual(library.games.first?.console,.nes)
    }
    func testHistoryRetentionAndWriteFailureDoNotEraseImportedGame()throws {
        let library=Library(root:root.appendingPathComponent("library"))
        for _ in 0..<25 {try ImportHistory.append(ImportReport(processed:1,covers:0,issues:[]),root:library.root)}
        XCTAssertEqual(try ImportHistory.read(library.root).count,20)
        try FileManager.default.removeItem(at:ImportHistory.url(library.root));try FileManager.default.createDirectory(at:ImportHistory.url(library.root),withIntermediateDirectories:true)
        let result=try library.importURLs([write("Good.nes",rom())],console:.nes,continueOnError:true)
        XCTAssertEqual(result.games,1);XCTAssertFalse(result.historySaved);XCTAssertEqual(library.games.count,1)
    }
    func testReportDoesNotPersistSystemErrorPrivateURL()throws {
        let failure=NSError(domain:NSURLErrorDomain,code:-1001,userInfo:[NSLocalizedDescriptionKey:"https://private.example/file?token=secret",NSURLErrorFailingURLStringErrorKey:"https://private.example/file?token=secret"])
        let issue=ImportIssue(file:"Game.zip",error:failure)
        XCTAssertFalse(issue.reason.contains("secret"));XCTAssertFalse(issue.reason.contains("private.example"));XCTAssertTrue(issue.reason.contains("-1001"))
    }
}
