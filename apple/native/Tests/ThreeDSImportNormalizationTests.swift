import XCTest
import CryptoKit
@testable import VetaNative

@MainActor final class ThreeDSImportNormalizationTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    }
    override func tearDownWithError() throws {try FileManager.default.removeItem(at:root)}
    func fixture(container:Bool=true) -> Data {
        var h=Data(repeating:0,count:4096)
        func word(_ p:Int,_ v:UInt32){for i in 0..<4{h[p+i]=UInt8(truncatingIfNeeded:v>>(8*i))}}
        h.replaceSubrange(256..<260,with:Data("NCCH".utf8));word(0x104,8);word(0x180,1024)
        word(0x1a0,5);word(0x1a4,1);word(0x1a8,1)
        word(0x1b0,6);word(0x1b4,1);word(0x1b8,1)
        for (start,length,hashAt) in [(512,1024,0x160),(2560,512,0x1c0),(3072,512,0x1e0)] {
            h.replaceSubrange(start..<start+length,with:Data((0..<length).map{UInt8(truncatingIfNeeded:$0+start/512)}))
            let hash=Data(SHA256.hash(data:h.subdata(in:start..<start+length)));h.replaceSubrange(hashAt..<hashAt+32,with:hash)
        }
        if !container{return h}
        var outer=Data(repeating:0,count:512);outer.replaceSubrange(256..<260,with:Data("NCSD".utf8));outer[0x120]=1;outer[0x124]=8
        return outer+h
    }
    func write(_ bytes:Data,_ name:String="Fixture.3ds") throws -> URL {let u=root.appendingPathComponent(name);try bytes.write(to:u);return u}
    func testRepairsOnlyFlagAndIsIdempotentForNCSDAndNCCH() throws {
        for container in [true,false] {
            let original=fixture(container:container),u=try write(original,container ? "a.3ds":"a.cxi")
            XCTAssertTrue(try ThreeDSImportNormalization.apply(toStagedCopy:u))
            let after=try Data(contentsOf:u),diff=original.indices.filter{original[$0] != after[$0]}
            XCTAssertEqual(diff,[(container ? 512:0)+0x18f]);XCTAssertFalse(try ThreeDSImportNormalization.apply(toStagedCopy:u))
        }
    }
    func testUnprovenEncryptedOrDamagedContentNeverChanges() throws {
        for offset in [512+512,512+2560,512+3072] {
            var data=fixture();data[offset] ^= 1;let u=try write(data)
            XCTAssertFalse(try ThreeDSImportNormalization.apply(toStagedCopy:u));XCTAssertEqual(try Data(contentsOf:u),data)
        }
    }
    func testMalformedRangesAndTruncationNeverChange() throws {
        for offset in [0x120,0x124,512+0x104,512+0x1a8,512+0x1b0] {
            var data=fixture();data[offset]=255;let u=try write(data)
            XCTAssertFalse(try ThreeDSImportNormalization.apply(toStagedCopy:u));XCTAssertEqual(try Data(contentsOf:u),data)
        }
        let u=try write(Data(fixture().prefix(900)));XCTAssertNil(try ThreeDSImportNormalization.patch(for:u))
    }
    func testImportPreservesSourceIdentityAndReimportRepairsOldCopy() throws {
        let bytes=fixture(),u=try write(bytes),library=Library(root:root.appendingPathComponent("library"))
        let game=try library.importNativeFile(u,console:.threeDS)
        XCTAssertEqual(game.id,sha256(bytes));XCTAssertEqual(try Data(contentsOf:u),bytes)
        XCTAssertEqual(try Data(contentsOf:library.romURL(game))[512+0x18f],4)
        // Simulate a copy imported by a prior build, keeping its record/saves.
        try bytes.write(to:library.romURL(game));let save=library.directory(game.id).appendingPathComponent("keep.sav")
        try Data([1,2,3]).write(to:save)
        let again=try library.importNativeFile(u,console:.threeDS)
        XCTAssertEqual(again.id,game.id);XCTAssertEqual(library.games.count,1)
        XCTAssertEqual(try Data(contentsOf:library.romURL(game))[512+0x18f],4)
        XCTAssertEqual(try Data(contentsOf:save),Data([1,2,3]))
        _ = try library.importNativeFile(u,console:.threeDS);XCTAssertEqual(library.games.count,1)
        let backup=try library.export();defer{try? FileManager.default.removeItem(at:backup)}
        let restored=Library(root:root.appendingPathComponent("restored"))
        _ = try restored.importURL(backup)
        XCTAssertEqual(restored.games.first?.id,game.id)
        XCTAssertEqual(try Data(contentsOf:restored.romURL(game))[512+0x18f],4)
        var corrupt=try Data(contentsOf:library.romURL(game));corrupt[3000] ^= 1
        XCTAssertFalse(ThreeDSImportNormalization.matchesOriginalIdentity(corrupt,id:game.id))
    }
}
