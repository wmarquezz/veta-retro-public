import XCTest
#if CLOUD_IMPORT_STANDALONE
@testable import CloudImport
#elseif VETA_JIT_DEVELOPMENT
@testable import VetaJITLab
#else
@testable import VetaNative
#endif

final class CloudImportPreparationTests:XCTestCase {
    var root:URL!
    override func setUpWithError()throws {root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)}
    override func tearDownWithError()throws {try? FileManager.default.removeItem(at:root)}
    func file(_ name:String,_ bytes:Data=Data([1,2,3]))throws->URL {let p=root.appendingPathComponent("source/"+name);try FileManager.default.createDirectory(at:p.deletingLastPathComponent(),withIntermediateDirectories:true);try bytes.write(to:p);return p}
    func job()->CloudImportPreparation {CloudImportPreparation(extensions:["nes","png","cue","bin"])}
    func testNestedFoldersAndSiblingPairRemainLocalAfterSourceRemoved()throws {
        let rom=try file("NES/Game.nes"),cover=try file("NES/Game.png",Data([9])),other=try file("other/Game.nes",Data([4]));_ = try file("ignore.txt")
        let result=try job().prepare([root.appendingPathComponent("source")],temporaryRoot:root){_,_,_ in}
        defer{result.remove()}
        XCTAssertEqual(result.files.count,3)
        let roms=result.files.filter{$0.pathExtension=="nes"};XCTAssertEqual(roms.count,2)
        XCTAssertNotEqual(roms[0].deletingLastPathComponent(),roms[1].deletingLastPathComponent())
        let image=try XCTUnwrap(result.files.first{$0.pathExtension=="png"})
        XCTAssertTrue(roms.contains{$0.deletingLastPathComponent()==image.deletingLastPathComponent()})
        XCTAssertEqual(try Data(contentsOf:rom),Data([1,2,3]));XCTAssertEqual(try Data(contentsOf:cover),Data([9]));XCTAssertEqual(try Data(contentsOf:other),Data([4]))
        try FileManager.default.removeItem(at:root.appendingPathComponent("source"))
        XCTAssertEqual(try result.files.map{try Data(contentsOf:$0)}.count,3)
    }
    func testSeparateSelectionPreservesDiscTracksAndDeduplicates()throws {
        let cue=try file("Disc.cue",Data("FILE \"Track.bin\" BINARY".utf8)),track=try file("Track.bin")
        let result=try job().prepare([cue,track,cue],temporaryRoot:root){_,_,_ in};defer{result.remove()}
        XCTAssertEqual(result.files.count,2);XCTAssertEqual(Set(result.files.map{$0.deletingLastPathComponent()}).count,1)
    }
    func testProviderIsolatedFilesJoinOnlyWhenUnambiguous()throws {
        let rom=try file("provider-a/Game.nes"),cover=try file("provider-b/Game.png"),cue=try file("provider-c/Disc.cue"),track=try file("provider-d/Track.bin")
        let result=try job().prepare([rom,cover,cue,track],temporaryRoot:root,combineExplicitFiles:true){_,_,_ in};defer{result.remove()}
        XCTAssertEqual(result.files.count,4)
        XCTAssertEqual(Set(result.files.map{$0.deletingLastPathComponent()}).count,1)
        let duplicate=try file("provider-e/Game.nes",Data([8]))
        let separate=try job().prepare([rom,duplicate,cover],temporaryRoot:root,combineExplicitFiles:true){_,_,_ in};defer{separate.remove()}
        XCTAssertEqual(separate.files.count,3)
        XCTAssertEqual(Set(separate.files.map{$0.deletingLastPathComponent()}).count,3)
    }
    func testCancellationCleansOnlyOwnSnapshot()throws {
        let rom=try file("Game.nes",Data(repeating:7,count:3*1024*1024)),op=job()
        XCTAssertThrowsError(try op.prepare([rom],temporaryRoot:root){_,_,total in if total>0 {op.cancel()}}) {XCTAssertTrue($0 is CancellationError)}
        XCTAssertEqual(try Data(contentsOf:rom).count,3*1024*1024)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:root.path).contains{$0.hasPrefix("VetaImport-")})
    }
    func testSymlinkCannotImportOutsideSelection()throws {
        let rom=try file("Game.nes"),link=root.appendingPathComponent("alias.nes")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:rom)
        XCTAssertThrowsError(try job().prepare([link],temporaryRoot:root){_,_,_ in})
        XCTAssertTrue(FileManager.default.fileExists(atPath:rom.path))
    }
    func testMissingFileAndEmptyFolderLeaveLibraryUntouched()throws {
        let txt=try file("readme.txt")
        XCTAssertThrowsError(try job().prepare([txt.deletingLastPathComponent()],temporaryRoot:root){_,_,_ in})
        XCTAssertThrowsError(try job().prepare([root.appendingPathComponent("missing.nes")],temporaryRoot:root){_,_,_ in})
        XCTAssertEqual(try Data(contentsOf:txt),Data([1,2,3]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.path),["source"])
    }
}
