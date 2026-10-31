import XCTest
import CryptoKit
import UIKit
@testable import VetaNative

private actor CatalogFixtureSource: DirectCloudSource {
    var folders: [String:[DirectCloudEntry]]
    let payloads: [String:Data]
    var lists: [String] = []
    var downloads: [String] = []
    init(folders:[String:[DirectCloudEntry]], payloads:[String:Data]) { self.folders=folders;self.payloads=payloads }
    func list(folder:String) async throws -> [DirectCloudEntry] { lists.append(folder);return folders[folder] ?? [] }
    func download(_ entry:DirectCloudEntry,progress:@escaping @Sendable(Int64,Int64)->Void) async throws -> URL {
        downloads.append(entry.id)
        guard let bytes=payloads[entry.id] else {throw DirectCloudError.service(404)}
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to:url);progress(Int64(bytes.count),Int64(bytes.count));return url
    }
}
final class CloudGameCatalogTests:XCTestCase {
    let gameA=String(repeating:"a",count:64),gameB=String(repeating:"b",count:64)
    func fixture() -> CloudGameCatalog {
        func file(_ path:String,_ data:Data) -> CloudGameCatalog.File { .init(path:path,bytes:Int64(data.count),sha256:sha256(data)) }
        return .init(format:"veta.catalog",version:1,title:"Mi colección",generatedAt:"2026-10-31",consoles:[
            .init(id:"nes",name:"NES",folder:"NES",games:[.init(id:gameA,title:"Aventura Ágil",file:file("NES/Example.nes",Data([1])),cover:file("NES/Example.png",Data([2])),validation:"boot")]),
            .init(id:"gb",name:"Game Boy",folder:"Game Boy",games:[.init(id:gameB,title:"Otro juego",file:file("Game Boy/Example.gb",Data([3])),cover:file("Game Boy/Example.png",Data([4])),validation:"import")])])
    }
    private func source(_ catalog:CloudGameCatalog) throws -> CatalogFixtureSource {
        let bytes=try JSONEncoder().encode(catalog)
        return CatalogFixtureSource(folders:["root":[.init(id:"manifest",name:CloudGameCatalog.filename,folder:false,size:Int64(bytes.count)),.init(id:"nesFolder",name:"NES",folder:true),.init(id:"gbFolder",name:"Game Boy",folder:true)],
            "nesFolder":[.init(id:"nesROM",name:"Example.nes",folder:false,size:1),.init(id:"nesCover",name:"Example.png",folder:false,size:1)],
            "gbFolder":[.init(id:"gbROM",name:"Example.gb",folder:false,size:1),.init(id:"gbCover",name:"Example.png",folder:false,size:1)]],
            payloads:["manifest":bytes,"nesROM":Data([1]),"nesCover":Data([2]),"gbROM":Data([3]),"gbCover":Data([4])])
    }
    func testSchemaRejectsUnsupportedVersionUnsafePathsAndDuplicateIdentity() throws {
        let data=try JSONEncoder().encode(fixture());XCTAssertEqual(try CloudGameCatalog.decode(data).consoles.count,2)
        var object=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        for version in [0,2] { var bad=object;bad["version"]=version;XCTAssertThrowsError(try CloudGameCatalog.decode(JSONSerialization.data(withJSONObject:bad))) }
        for path in ["../outside.nes","/NES/Example.nes","NES/../Example.nes","NES/https://example.com/a.nes","NES/a\\b.nes","NES/a.exe/../../b"] {
            var bad=object,consoles=bad["consoles"] as! [[String:Any]],games=consoles[0]["games"] as! [[String:Any]],file=games[0]["file"] as! [String:Any]
            file["path"]=path;games[0]["file"]=file;consoles[0]["games"]=games;bad["consoles"]=consoles
            XCTAssertThrowsError(try CloudGameCatalog.decode(JSONSerialization.data(withJSONObject:bad)),path)
        }
        var consoles=object["consoles"] as! [[String:Any]],games=consoles[1]["games"] as! [[String:Any]]
        games[0]["id"]=gameA;consoles[1]["games"]=games;object["consoles"]=consoles
        XCTAssertThrowsError(try CloudGameCatalog.decode(JSONSerialization.data(withJSONObject:object)))
    }
    func testConsoleSelectionExcludesInstalledGamesAndTheirCovers() throws {
        let catalog=fixture(),wrapped=CatalogCloudSource(catalog:catalog,rootID:"root",source:try source(catalog))
        let plan=try wrapped.plan(selection:Set(wrapped.folders.map(\.id)),installed:[gameA])
        XCTAssertEqual(plan.files.map(\.components),[["Game Boy","Example.gb"],["Game Boy","Example.png"]]);XCTAssertEqual(plan.bytes,2)
        XCTAssertFalse(wrapped.available(wrapped.folders[0],installed:[gameA]));XCTAssertTrue(wrapped.available(wrapped.folders[1],installed:[gameA]))
        XCTAssertThrowsError(try wrapped.plan(selection:Set(wrapped.folders.map(\.id)),installed:[gameA,gameB]))
    }
    func testCrossConsoleImagesWithSameStemRemainDistinct() throws {
        let catalog=fixture(),wrapped=CatalogCloudSource(catalog:catalog,rootID:"root",source:try source(catalog))
        let index=DirectCloudArtworkIndex(wrapped.allFiles)
        XCTAssertEqual(index.games.count,2);XCTAssertEqual(index.covers.count,2);XCTAssertTrue(index.unpairedImages.isEmpty)
        XCTAssertNotEqual(index.covers[index.games[0].id]?.id,index.covers[index.games[1].id]?.id)
    }
    func testResolverUsesOnlyCatalogRootAndCachesFolderListing() async throws {
        let catalog=fixture(),base=try source(catalog),wrapped=CatalogCloudSource(catalog:catalog,rootID:"root",source:base)
        for item in wrapped.allFiles {
            let url=try await wrapped.download(item){_,_ in};defer{try? FileManager.default.removeItem(at:url)}
            try DirectCloudTransfer.validateFile(url,entry:item)
        }
        let lists=await base.lists,downloads=await base.downloads
        XCTAssertEqual(lists,["root","nesFolder","gbFolder"]);XCTAssertEqual(downloads.count,4)
    }
    func testChangedRemoteMetadataFailsBeforeDownloading() async throws {
        let catalog=fixture(),base=CatalogFixtureSource(folders:["root":[.init(id:"n",name:"NES",folder:true)],"n":[.init(id:"r",name:"Example.nes",folder:false,size:2)]],payloads:[:])
        let wrapped=CatalogCloudSource(catalog:catalog,rootID:"root",source:base)
        do {_ = try await wrapped.download(wrapped.allFiles[0]){_,_ in};XCTFail("Changed file accepted")} catch DirectCloudError.changed {} catch {XCTFail("\(error)")}
        let downloads=await base.downloads;XCTAssertTrue(downloads.isEmpty)
    }
    func testSHA256MismatchIsRejectedEvenWithSameLength() throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:url)}
        try Data([9]).write(to:url)
        XCTAssertThrowsError(try DirectCloudTransfer.validateFile(url,entry:.init(id:"a",name:"A.nes",folder:false,size:1,sha256:sha256(Data([1])))))
    }
    @MainActor func testAutomaticDetectionSearchInstalledSelectionAndRemoval() async throws {
        let model=DirectCloudBrowserModel(),catalog=fixture(),base=try source(catalog)
        model.updateInstalled([gameA]);try await model.connectPortal(base)
        XCTAssertEqual(model.catalog?.consoles.count,2);XCTAssertEqual(model.artworkIndex.folders.count,2)
        model.search="agil";XCTAssertEqual(model.artworkIndex.games.count,1);XCTAssertTrue(model.selectableIDs.isEmpty)
        let item=try XCTUnwrap(model.artworkIndex.games.first);model.toggle(item);XCTAssertTrue(model.selected.isEmpty)
        model.updateInstalled([]);model.toggle(item);XCTAssertEqual(model.selected,[item.id]);model.plan(all:false)
        XCTAssertEqual(model.pendingPlan?.files.count,2)
        model.updateInstalled([gameA]);XCTAssertTrue(model.selected.isEmpty)
        model.search="Otro";XCTAssertEqual(model.artworkIndex.games.first?.catalogGameID,gameB)
        let downloaded=await base.downloads;XCTAssertEqual(downloaded,["manifest"])
    }
    @MainActor func testInvalidCatalogFallsBackToExistingFolders() async throws {
        let bytes=Data("invalid".utf8),base=CatalogFixtureSource(folders:["root":[.init(id:"m",name:CloudGameCatalog.filename,folder:false,size:Int64(bytes.count)),.init(id:"f",name:"NES",folder:true)]],payloads:["m":bytes])
        let model=DirectCloudBrowserModel();try await model.connectPortal(base)
        XCTAssertNil(model.catalog);XCTAssertNotNil(model.error);XCTAssertEqual(model.entries.map(\.name),["NES"])
    }
    @MainActor func testNoCatalogRetainsOrdinaryBrowser() async throws {
        let base=CatalogFixtureSource(folders:["root":[.init(id:"g",name:"A.nes",folder:false,size:1)]],payloads:[:]),model=DirectCloudBrowserModel()
        try await model.connectPortal(base);XCTAssertNil(model.catalog);XCTAssertNil(model.error);XCTAssertEqual(model.entries.count,1)
    }
    @MainActor func testZIPCatalogImportsROMAndCoverThenDisablesIdentity() async throws {
        let url=try XCTUnwrap(Bundle.main.url(forResource:"akanoid-gb",withExtension:"gb",subdirectory:"Content/akanoid-gb"))
        let rom=try Data(contentsOf:url),id=sha256(rom)
        let zip=ZIPGameImportTests().stored("Internal.gb",payload:rom)
        let cover=UIGraphicsImageRenderer(size:CGSize(width:20,height:20)).pngData {c in UIColor.orange.setFill();c.fill(CGRect(x:0,y:0,width:20,height:20))}
        let catalog=CloudGameCatalog(format:"veta.catalog",version:1,title:"Local",generatedAt:"2026-10-31",consoles:[.init(id:"gb",name:"Game Boy",folder:"Game Boy",games:[.init(id:id,title:"A_KANOID",file:.init(path:"Game Boy/A_KANOID.zip",bytes:Int64(zip.count),sha256:sha256(zip)),cover:.init(path:"Game Boy/A_KANOID.png",bytes:Int64(cover.count),sha256:sha256(cover)),validation:"import")])])
        let base=CatalogFixtureSource(folders:["root":[.init(id:"f",name:"Game Boy",folder:true)],"f":[.init(id:"z",name:"A_KANOID.zip",folder:false,size:Int64(zip.count)),.init(id:"p",name:"A_KANOID.png",folder:false,size:Int64(cover.count))]],payloads:["z":zip,"p":cover])
        let source=CatalogCloudSource(catalog:catalog,rootID:"root",source:base)
        let plan=try source.plan(selection:Set(source.folders.map(\.id)),installed:[])
        let snapshot=try await DirectCloudTransfer(source:source,extensions:LocalCoverImport.gameExtensions).prepare(plan){_ in};defer{snapshot.remove()}
        XCTAssertEqual(Set(snapshot.consoleHints.values),[.gb])
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let library=Library(root:root),art=ArtworkStore(root:root)
        let result=try library.importURLs(snapshot.files,console:nil,artwork:art,consoleHints:snapshot.consoleHints)
        XCTAssertEqual(result.games,1);XCTAssertEqual(result.covers,1)
        let game=try XCTUnwrap(library.games.first);XCTAssertEqual(game.id,id);XCTAssertEqual(game.console,.gb)
        XCTAssertEqual(try Data(contentsOf:library.romURL(game)),rom);XCTAssertNotNil(art.image(game))
        XCTAssertFalse(source.available(source.folders[0],installed:Set(library.games.map(\.id))))
    }
    func testCatalogHandlesFiveThousandEntriesWithoutFetchingFiles() throws {
        let items=(0..<5000).map {n in CloudGameCatalog.GameItem(id:String(format:"%064x",n+1),title:"Juego \(n)",file:.init(path:"NES/Juego \(n).nes",bytes:1,sha256:gameA),cover:nil,validation:"import")}
        let catalog=CloudGameCatalog(format:"veta.catalog",version:1,title:"Grande",generatedAt:"2026-10-31",consoles:[.init(id:"nes",name:"NES",folder:"NES",games:items)])
        let parsed=try CloudGameCatalog.decode(JSONEncoder().encode(catalog));XCTAssertEqual(parsed.consoles[0].games.count,5000)
    }
    func testResolverDisambiguatesOldCoverBySizeButStillChecksDigest() async throws {
        let catalog=fixture(),base=CatalogFixtureSource(folders:["root":[.init(id:"n",name:"NES",folder:true)],"n":[.init(id:"old",name:"Example.png",folder:false,size:2),.init(id:"new",name:"Example.png",folder:false,size:1)]],payloads:["new":Data([2])])
        let source=CatalogCloudSource(catalog:catalog,rootID:"root",source:base),image=source.allFiles[1]
        let url=try await source.download(image){_,_ in};defer{try? FileManager.default.removeItem(at:url)}
        try DirectCloudTransfer.validateFile(url,entry:image)
        let downloads=await base.downloads;XCTAssertEqual(downloads,["new"])
    }

}
