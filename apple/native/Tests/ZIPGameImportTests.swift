import XCTest
import UIKit
import zlib
@testable import VetaNative

@MainActor final class ZIPGameImportTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    func write(_ data: Data, _ name: String) throws -> URL { let url=root.appendingPathComponent(name);try data.write(to:url);return url }
    func stored(_ name: String, payload: Data=Data([1,2,3]), flags: Int=0, mode: Int=0) -> Data {
        var data=Data(),central=Data()
        func append(_ n:Int,_ count:Int,_ target:inout Data){for i in 0..<count {target.append(UInt8(truncatingIfNeeded:n >> (i*8)))}}
        let crc=payload.withUnsafeBytes{Int(crc32(0,$0.bindMemory(to:Bytef.self).baseAddress,uInt(payload.count)))};let nameBytes=Data(name.utf8)
        for (n,c) in [(0x04034b50,4),(20,2),(flags,2),(0,2),(0,2),(0,2),(crc,4),(payload.count,4),(payload.count,4),(nameBytes.count,2),(0,2)]{append(n,c,&data)}
        data.append(nameBytes);data.append(payload)
        for (n,c) in [(0x02014b50,4),(0x0314,2),(20,2),(flags,2),(0,2),(0,2),(0,2),(crc,4),(payload.count,4),(payload.count,4),(nameBytes.count,2),(0,2),(0,2),(0,2),(0,2),(mode << 16,4),(0,4)]{append(n,c,&central)}
        central.append(nameBytes);let offset=data.count;data.append(central)
        for (n,c) in [(0x06054b50,4),(0,2),(0,2),(1,2),(1,2),(central.count,4),(offset,4),(0,2)]{append(n,c,&data)}
        return data
    }
    func testDeflatedSNESExternalCoverDifferentInternalNameAndDeduplication() throws {
        let zip=try write(Data(base64Encoded:"UEsDBBQAAAAIAOS9XF0LFWlvOAAAAACAAAATAAAAaW5zaWRlL09yaWdpbmFsLnNmY+3KMREAMAgAsZeC1ErHAnMvmVMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA8Kk5vlcLUEsBAhQDFAAAAAgA5L1cXQsVaW84AAAAAIAAABMAAAAAAAAAAAAAAIABAAAAAGluc2lkZS9PcmlnaW5hbC5zZmNQSwUGAAAAAAEAAQBBAAAAaQAAAAAA")!,"My Game.zip")
        let image=UIGraphicsImageRenderer(size:CGSize(width:40,height:40)).pngData{ctx in UIColor.red.setFill();ctx.fill(CGRect(x:0,y:0,width:40,height:40))}
        let cover=try write(image,"My Game.png"), library=Library(root:root.appendingPathComponent("library"))
        let suite=UUID().uuidString,defaults=UserDefaults(suiteName:suite)!;defer{defaults.removePersistentDomain(forName:suite)}
        let artwork=ArtworkStore(root:library.root,defaults:defaults)
        let result=try library.importURLs([zip,cover],console:nil,artwork:artwork)
        XCTAssertEqual(result.games,1);XCTAssertEqual(result.covers,1);XCTAssertEqual(library.games.count,1)
        let game=try XCTUnwrap(library.games.first);XCTAssertEqual(game.console,.snes)
        try Library.validateROM(Data(contentsOf:library.romURL(game)),console:.snes)
        XCTAssertTrue(FileManager.default.fileExists(atPath:artwork.url(game).path))
        let save=library.file(game,"battery.sav");try FileManager.default.createDirectory(at:save.deletingLastPathComponent(),withIntermediateDirectories:true);try Data([7,8,9]).write(to:save)
        let again=try library.importURLs([zip,cover],console:nil,artwork:artwork)
        XCTAssertEqual(again.covers,0);XCTAssertEqual(library.games.count,1);XCTAssertEqual(try Data(contentsOf:save),Data([7,8,9]))
        XCTAssertEqual(try Data(contentsOf:zip),Data(base64Encoded:"UEsDBBQAAAAIAOS9XF0LFWlvOAAAAACAAAATAAAAaW5zaWRlL09yaWdpbmFsLnNmY+3KMREAMAgAsZeC1ErHAnMvmVMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA8Kk5vlcLUEsBAhQDFAAAAAgA5L1cXQsVaW84AAAAAIAAABMAAAAAAAAAAAAAAIABAAAAAGluc2lkZS9PcmlnaW5hbC5zZmNQSwUGAAAAAAEAAQBBAAAAaQAAAAAA")!)
    }
    func testBatchFailureNamesArchiveAndRemovesPartialExtraction() throws {
        let good = try write(stored("Game.bin"), "First.zip")
        let bad = try write(stored("Unsupported.txt"), "Second.zip")
        let temporary = root.appendingPathComponent("temporary")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ZIPGameImport.expand([good, bad], temporaryRoot: temporary)) { error in
            let failure = error as? ZIPGameImport.ArchiveError
            XCTAssertEqual(failure?.name, "Second.zip")
            XCTAssertTrue(error.localizedDescription.contains("Second.zip"))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: good.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bad.path))
    }
    func testStoredAndCleanup() throws {
        let zip=try write(stored("Game.sfc"),"Game.zip"), expansion=try ZIPGameImport.expand([zip])
        XCTAssertEqual(expansion.files.count,1);XCTAssertEqual(try Data(contentsOf:expansion.files[0]),Data([1,2,3]))
        expansion.remove();XCTAssertFalse(FileManager.default.fileExists(atPath:expansion.directory.path))
    }
    func testRejectTraversalSymlinkEncryptionNestedAndCorruptCRC() throws {
        for (i,data) in [stored("../escape.sfc"),stored("/escape.sfc"),stored("a\\b.sfc"),stored("link.sfc",mode:0xa000),stored("Game.sfc",flags:1),stored("Other.zip")].enumerated() {
            let file=try write(data,"bad-\(i).zip");XCTAssertThrowsError(try ZIPGameImport.expand([file]))
        }
        var bad=stored("Game.sfc");bad[30+8] ^= 1
        XCTAssertThrowsError(try ZIPGameImport.expand([write(bad,"crc.zip")]))
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("escape.sfc").path))
    }
    func testRejectTruncatedAndDeclaredOversize() throws {
        let bytes=stored("Game.sfc")
        for count in [0,10,22,bytes.count-1] {XCTAssertThrowsError(try ZIPGameImport.expand([write(Data(bytes.prefix(count)),"short-\(count).zip")]))}
        var bad=bytes;let central=30+8+3;bad[central+24]=0;bad[central+25]=0;bad[central+26]=0;bad[central+27]=127
        XCTAssertThrowsError(try ZIPGameImport.expand([write(bad,"large.zip")]))
    }
    func testZIPVisibleAndCoverPairedWithoutReadingArchive() throws {
        XCTAssertTrue(LocalCoverImport.gameExtensions.contains("zip"))
        let zip=try write(stored("Game.sfc"),"Game.zip")
        XCTAssertTrue(try LocalCoverImport.files([root]).contains(zip))
        let game=DirectCloudEntry(id:"zip",name:"Game.zip",folder:false,size:10)
        let cover=DirectCloudEntry(id:"png",name:"Game.png",folder:false,size:10)
        let index=DirectCloudArtworkIndex([game,cover])
        XCTAssertEqual(index.games.map(\.id),["zip"]);XCTAssertEqual(index.covers["zip"]?.id,"png");XCTAssertTrue(index.unpairedImages.isEmpty)
    }
    func testAllSupportedGameFormatsPassThroughZIPAndMatchCover() throws {
        let formats=LocalCoverImport.gameExtensions.union(NativeGameFile.extensions).subtracting(["zip","vetanes","vetaretro","cue","wav"])
        for ext in formats {
            let file=try write(stored("Game."+ext),"Format-"+ext+".zip"),expanded=try ZIPGameImport.expand([file]);defer{expanded.remove()}
            XCTAssertEqual(expanded.files.first?.pathExtension,ext)
            let game=DirectCloudEntry(id:"game",name:"Format-"+ext+".zip",folder:false,size:100),cover=DirectCloudEntry(id:"cover",name:"Format-"+ext+".png",folder:false,size:10)
            XCTAssertEqual(DirectCloudArtworkIndex([game,cover]).covers["game"]?.id,"cover")
        }
    }
    func testGameBoyZIPThroughCloudSnapshotAndLocalLibrary() throws {
        let file=try write(Data(base64Encoded:"UEsDBBQAAAAIAEu/XF1i0V1tOQAAAACAAAAJAAAASW5zaWRlLmdi7c4xDQAACAOw+TeKDTwsJDytgiacme8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAK0FUEsBAhQDFAAAAAgAS79cXWLRXW05AAAAAIAAAAkAAAAAAAAAAAAAAIABAAAAAEluc2lkZS5nYlBLBQYAAAAAAQABADcAAABgAAAAAAA=")!,"Cloud GB.zip")
        let image=UIGraphicsImageRenderer(size:CGSize(width:40,height:40)).pngData{ctx in UIColor.blue.setFill();ctx.fill(CGRect(x:0,y:0,width:40,height:40))}
        let cover=try write(image,"Cloud GB.png")
        let snapshot=try CloudImportPreparation(extensions:LocalCoverImport.gameExtensions.union(LocalCoverImport.imageExtensions)).prepare([file,cover],temporaryRoot:root){_,_,_ in};defer{snapshot.remove()}
        XCTAssertFalse(snapshot.files.contains{$0.pathExtension=="zip"})
        let library=Library(root:root.appendingPathComponent("gb-library")),suite=UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
        defer{defaults.removePersistentDomain(forName:suite)}
        let result=try library.importURLs(snapshot.files,console:nil,artwork:ArtworkStore(root:library.root,defaults:defaults))
        XCTAssertEqual(result.games,1);XCTAssertEqual(result.covers,1);XCTAssertEqual(library.games.first?.console,.gb)
    }
    func testDiscTracksPreservedAndZIP64() throws {
        let file=try write(Data(base64Encoded:"UEsDBBQAAAAIAEu/XF1BWeKzPAAAAEAAAAANAAAAZGlzYy9HYW1lLmN1ZXPz9HFVUCopSkzO1kvKzFNScPL0cwyK5FIICXJ09lYwMFTw9XdxNdI3MjY14lLw9HNxjQAJGhhYgREXAFBLAwQUAAAACABLv1xdZvzhkxUAAABgEgAADgAAAGRpc2MvdHJhY2suYmlu7cExAQAAAMKg9U9tB2+gAAAAAOA3UEsBAhQDFAAAAAgAS79cXUFZ4rM8AAAAQAAAAA0AAAAAAAAAAAAAAIABAAAAAGRpc2MvR2FtZS5jdWVQSwECFAMUAAAACABLv1xdZvzhkxUAAABgEgAADgAAAAAAAAAAAAAAgAFnAAAAZGlzYy90cmFjay5iaW5QSwUGAAAAAAIAAgB3AAAAqAAAAAAA")!,"Disc.zip"),expanded=try ZIPGameImport.expand([file]);defer{expanded.remove()}
        let cue=try XCTUnwrap(expanded.files.first{$0.pathExtension=="cue"})
        XCTAssertEqual(expanded.origins[cue],file)
        XCTAssertEqual(try Data(contentsOf:cue.deletingLastPathComponent().appendingPathComponent("track.bin")).count,4704)
        let z64=try write(Data(base64Encoded:"UEsDBBQAAAAIAEu/XF3CQSQ1BQAAAAMAAAAJAAAAU21hbGwuc2ZjS0xKBgBQSwECFAMUAAAACABLv1xdwkEkNf//////////CQAcAAAAAAAAAAAAgAH/////U21hbGwuc2ZjAQAYAAMAAAAAAAAABQAAAAAAAAAAAAAAAAAAAFBLBgYsAAAAAAAAAC0ALQAAAAAAAAAAAAEAAAAAAAAAAQAAAAAAAABTAAAAAAAAACwAAAAAAAAAUEsGBwAAAAB/AAAAAAAAAAEAAABQSwUGAAAAAP///////////////wAA")!,"64.zip"),large=try ZIPGameImport.expand([z64]);defer{large.remove()}
        XCTAssertEqual(try Data(contentsOf:large.files[0]),Data("abc".utf8))
    }
    func testCancellationStopsExtraction() throws {
        let file=try write(stored("Game.sfc"),"Cancel.zip")
        XCTAssertThrowsError(try ZIPGameImport.expand([file],checkCancellation:{throw CancellationError()})) {XCTAssertTrue($0 is CancellationError)}
    }

    func testStreamingDeflateAcrossManyBuffers() throws {
        let file=try write(Data(base64Encoded:"UEsDBBQAAAAIAHK/XF015NAEJhEAAAAAEAAJAAAATGFyZ2UuaXNv7c9DAhgGAACw2rZt27bN1bZt27a51Vpt27Ztu4/oNflBAgQMFDhI0GDBQ4QMFTpM2HDhI0SMFDlK1GjRY8SMFTtO3HjxEyRMlDhJ0mTJU6RMlTpN2nTpM2TMlDlL1mzZc+TMlTtP3nz5CxQsVLhI0WLFS5QsVbpM2XLlK1SsVLlK1WrVa9T8p1btOnXr1W/QsFHjJk2bNW/RslXrNm3bte/QsVPnLl27de/Rs1fvPn379R8wcNDgIUOHDR8xctToMWPHjZ8wcdLkKVOnTZ8xc9bsOXPnzV+wcNHiJUuXLf/3vxUrV61es3bd+g0bN/2/ecvWbdt37Ny1e8/effsPHDx0+MjRY8dPnDx1+szZc+cvXLx0+crVa9dv3Lx1+87de/cfPHz0+MnTZ89fvHz1+s3bd+8/fPz0+cvXb99//Pz1O4C/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7//X///AFBLAQIUAxQAAAAIAHK/XF015NAEJhEAAAAAEAAJAAAAAAAAAAAAAACAAQAAAABMYXJnZS5pc29QSwUGAAAAAAEAAQA3AAAATREAAAAA")!,"Large.zip"),expanded=try ZIPGameImport.expand([file]);defer{expanded.remove()}
        let bytes=try Data(contentsOf:expanded.files[0]);XCTAssertEqual(bytes.count,1048576)
        for i in stride(from:0,to:bytes.count,by:4095) {XCTAssertEqual(bytes[i],UInt8(i%256))}
    }

}
