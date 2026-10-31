import XCTest
import CryptoKit
import UIKit
import SwiftUI
@testable import VetaNative

private actor CloudFixtureSource: DirectCloudSource {
    var folders: [String: [DirectCloudEntry]]
    let payloads: [String: Data]
    var failID: String?
    var downloaded: [String] = []
    init(folders: [String: [DirectCloudEntry]] = [:], payloads: [String: Data] = [:], failID: String? = nil) {
        self.folders = folders; self.payloads = payloads; self.failID = failID
    }
    func list(folder: String) async throws -> [DirectCloudEntry] { folders[folder] ?? [] }
    func download(_ entry: DirectCloudEntry, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        try Task.checkCancellation()
        downloaded.append(entry.id)
        if failID == entry.id { throw DirectCloudError.service(503) }
        guard let data = payloads[entry.id] else { throw DirectCloudError.invalidResponse }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: file); progress(Int64(data.count), Int64(data.count)); return file
    }
}
private actor CloudWaitingSource: DirectCloudSource {
    let started: @Sendable () -> Void
    init(started: @escaping @Sendable () -> Void) { self.started = started }
    func list(folder: String) async throws -> [DirectCloudEntry] { [] }
    func download(_ entry: DirectCloudEntry, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        started()
        try await Task.sleep(nanoseconds: 30_000_000_000)
        throw DirectCloudError.invalidResponse
    }
}
private actor CloudFixtureHTTP: DirectCloudHTTP {
    let replies: [(Int, Data)]
    var calls: [URLRequest] = []
    init(_ replies: [(Int, Data)]) { self.replies = replies }
    func data(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let i = calls.count; calls.append(request)
        guard i < replies.count else { throw DirectCloudError.invalidResponse }
        let r = replies[i]
        return (r.1, HTTPURLResponse(url: request.url!, statusCode: r.0, httpVersion: nil, headerFields: nil)!)
    }
    func download(_ request: URLRequest, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> (URL, HTTPURLResponse) { throw DirectCloudError.invalidResponse }
}

final class DirectCloudTests: XCTestCase {
    func testTolerantPlanAndDownloadKeepGoodFileAndReportOthers() async throws {
        let entries=[DirectCloudEntry(id:"denied",name:"Denied.gb",folder:false,size:1,canDownload:false),
                     .init(id:"bad",name:"Unavailable.gb",folder:false,size:1),
                     .init(id:"changed",name:"Changed.gb",folder:false,size:2),
                     .init(id:"good",name:"Good.gb",folder:false,size:1)]
        let source=CloudFixtureSource(payloads:["changed":Data([8]),"good":Data([7])],failID:"bad")
        let transfer=DirectCloudTransfer(source:source,extensions:["gb"],continueOnError:true)
        let plan=try await transfer.plan(selection:entries)
        XCTAssertEqual(plan.files.count,3);XCTAssertEqual(plan.issues.map(\.file),["Denied.gb"])
        let snapshot=try await transfer.prepare(plan){_ in};defer{snapshot.remove()}
        XCTAssertEqual(snapshot.files.map(\.lastPathComponent),["Good.gb"])
        XCTAssertEqual(try Data(contentsOf:XCTUnwrap(snapshot.files.first)),Data([7]))
        XCTAssertEqual(Set(snapshot.issues.map(\.file)),["Denied.gb","Unavailable.gb","Changed.gb"])
    }
    func testTolerantDownloadWithNoValidFilesStillReturnsIssues() async throws {
        let source=CloudFixtureSource(failID:"bad"),transfer=DirectCloudTransfer(source:source,extensions:["gb"],continueOnError:true)
        let plan=try await transfer.plan(selection:[.init(id:"bad",name:"Bad.gb",folder:false,size:1)])
        let snapshot=try await transfer.prepare(plan){_ in};defer{snapshot.remove()}
        XCTAssertTrue(snapshot.files.isEmpty);XCTAssertEqual(snapshot.issues.map(\.file),["Bad.gb"])
    }
    func data(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    func config(_ provider: DirectCloudProvider = .google) -> DirectCloudConfiguration { .init(provider: provider, clientID: "test-client", redirectURI: "com.example.veta:/oauthredirect") }
    func testPKCEKnownVectorAndExactCallback() throws {
        let p = DirectCloudPKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "random-state")
        XCTAssertEqual(p.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(try p.code(from: URL(string: "com.example.veta:/oauthredirect?state=random-state&code=abc")!, config: config()), "abc")
        for bad in ["com.attacker:/oauthredirect?state=random-state&code=abc", "com.example.veta:/wrong?state=random-state&code=abc", "com.example.veta:/oauthredirect?state=wrong&code=abc", "com.example.veta:/oauthredirect?state=random-state&state=random-state&code=abc", "com.example.veta:/oauthredirect?state=random-state&code=abc&code=def", "com.example.veta:/oauthredirect?state=random-state&code=abc#token=bad"] {
            XCTAssertThrowsError(try p.code(from: URL(string: bad)!, config: config()))
        }
    }
    func testProviderAuthorizationUsesReadScopesAndPKCE() throws {
        let p = try DirectCloudPKCE()
        XCTAssertGreaterThanOrEqual(p.verifier.count, 43); XCTAssertNotEqual(p.verifier, p.state)
        for provider in DirectCloudProvider.allCases {
            let url = p.authorizationURL(config(provider))
            let fields = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
            XCTAssertEqual(fields["code_challenge_method"], "S256")
            XCTAssertEqual(fields["scope"], provider.scopes)
            XCTAssertFalse(provider.scopes.lowercased().contains("write"))
            XCTAssertNil(fields["client_secret"])
            XCTAssertFalse(url.absoluteString.contains(p.verifier))
        }
    }
    func testRefreshTokenRotationPreservesMissingRefresh() throws {
        let body = try data(["access_token": "new", "token_type": "Bearer", "expires_in": 120])
        let token = try DirectCloudToken.decode(body, previousRefresh: "previous", now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(token.refreshToken, "previous"); XCTAssertEqual(token.expiresAt.timeIntervalSince1970, 120)
        XCTAssertThrowsError(try DirectCloudToken.decode(data(["access_token": "x", "token_type": "MAC"])))
    }
    func testListingDecodesProvidersAndSkipsShortcuts() throws {
        let google = try DirectCloudAPI.decodePage(data(["files": [["id": "a", "name": "Console", "mimeType": "application/vnd.google-apps.folder"], ["id": "b", "name": "Alias", "mimeType": "application/vnd.google-apps.shortcut"], ["id": "c", "name": "Game.gb", "size": "42", "md5Checksum": "abc", "capabilities": ["canDownload": false]]], "nextPageToken": "next"]), provider: .google)
        XCTAssertEqual(google.entries.count, 2); XCTAssertTrue(google.entries[0].folder); XCTAssertEqual(google.entries[1].size, 42); XCTAssertFalse(google.entries[1].canDownload)
        let ms = try DirectCloudAPI.decodePage(data(["value": [["id": "a", "name": "Console", "folder": [:]], ["id": "b", "name": "Game.gb", "size": 40, "eTag": "rev"], ["id": "c", "name": "Shared", "remoteItem": [:]]]]), provider: .onedrive)
        XCTAssertEqual(ms.entries.count, 2); XCTAssertEqual(ms.entries[1].revision, "rev")
        let db = try DirectCloudAPI.decodePage(data(["entries": [["id": "id:a", "name": "Game.gb", ".tag": "file", "size": 42, "rev": "r", "content_hash": "h"]], "has_more": true, "cursor": "continue"]), provider: .dropbox)
        XCTAssertEqual(db.next, "continue"); XCTAssertEqual(db.entries[0].dropboxHash, "h")
    }
    func testHostilePaginationAndRedirectNeverReceiveBearer() throws {
        for link in ["http://graph.microsoft.com/v1.0/x", "https://attacker.example/steal", "https://graph.microsoft.com.attacker.example/v1.0/x", "https://graph.microsoft.com:444/v1.0/x", "https://user@graph.microsoft.com/v1.0/x"] {
            XCTAssertThrowsError(try DirectCloudAPI.decodePage(data(["value": [], "@odata.nextLink": link]), provider: .onedrive))
        }
        var req = URLRequest(url: URL(string: "https://download.example.com/game")!); req.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        req.setValue("session=secret", forHTTPHeaderField: "Cookie")
        let clean = DirectCloudRedirectPolicy.redirected(req, previous: URL(string: "https://graph.microsoft.com/v1.0/x"), downloads: true)
        XCTAssertNil(clean?.value(forHTTPHeaderField: "Authorization")); XCTAssertNil(clean?.value(forHTTPHeaderField: "Cookie")); XCTAssertNotNil(clean)
        XCTAssertNil(DirectCloudRedirectPolicy.redirected(req, previous: nil, downloads: false))
        req.url = URL(string: "https://127.0.0.1/x"); XCTAssertNil(DirectCloudRedirectPolicy.redirected(req, previous: nil, downloads: true))
    }
    func testPaginatedListingRefreshesOnlyAfterUnauthorized() async throws {
        let http = CloudFixtureHTTP([(401, Data()), (200, try data(["access_token": "rotated", "token_type": "Bearer", "expires_in": 3600])), (200, try data(["files": [["id": "a", "name": "A.gb", "size": "1"]], "nextPageToken": "p2"])), (200, try data(["files": [["id": "b", "name": "B.gb", "size": "2"]]]))])
        let connection = DirectCloudConnection(config: config(), token: .init(accessToken: "old", refreshToken: "refresh", expiresAt: .distantFuture), http: http, save: { _ in })
        let entries = try await connection.list(folder: "root")
        XCTAssertEqual(entries.map(\.id), ["a", "b"])
        let calls = await http.calls
        XCTAssertEqual(calls.count, 4); XCTAssertEqual(calls[2].value(forHTTPHeaderField: "Authorization"), "Bearer rotated")
        XCTAssertNil(calls[1].value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(calls[3].url!.absoluteString.contains("pageToken=p2"))
    }
    func testRepeatedCursorFailsInsteadOfLooping() async throws {
        let body = try data(["files": [], "nextPageToken": "same"])
        let http = CloudFixtureHTTP([(200, body), (200, body)])
        let c = DirectCloudConnection(config: config(), token: .init(accessToken: "a", refreshToken: nil, expiresAt: .distantFuture), http: http, save: { _ in })
        do { _ = try await c.list(folder: "root"); XCTFail("Repeated cursor accepted") } catch DirectCloudError.invalidResponse {} catch { XCTFail("\(error)") }
    }
    func testSafeNamesAndFolderBoundaries() async throws {
        for bad in ["../a.gb", "..", ".", "/x", "a\\b", "a:b", "a\u{0}b", String(repeating: "a", count: 241)] { XCTAssertThrowsError(try DirectCloudAPI.safeName(bad)) }
        let a = DirectCloudEntry(id: "a", name: "NES", folder: true), b = DirectCloudEntry(id: "b", name: "GB", folder: true)
        let source = CloudFixtureSource(folders: ["a": [.init(id: "g1", name: "Game.gb", folder: false, size: 1)], "b": [.init(id: "g2", name: "Game.gb", folder: false, size: 2)]])
        let plan = try await DirectCloudTransfer(source: source, extensions: ["gb"]).plan(selection: [a, b])
        XCTAssertEqual(plan.files.map(\.components), [["NES", "Game.gb"], ["GB", "Game.gb"]]); XCTAssertEqual(plan.bytes, 3)
    }
    func testDuplicateNamesAndCyclesRejectedBeforeDownload() async throws {
        let duplicates = [DirectCloudEntry(id: "a", name: "Game.gb", folder: false, size: 1), .init(id: "b", name: "GAME.gb", folder: false, size: 1)]
        let transfer = DirectCloudTransfer(source: CloudFixtureSource(), extensions: ["gb"])
        do { _ = try await transfer.plan(selection: duplicates); XCTFail("duplicate") } catch DirectCloudError.ambiguousNames {} catch { XCTFail("\(error)") }
        let folder = DirectCloudEntry(id: "cycle", name: "Folder", folder: true)
        let loop = DirectCloudTransfer(source: CloudFixtureSource(folders: ["cycle": [folder]]), extensions: ["gb"])
        do { _ = try await loop.plan(selection: [folder]); XCTFail("cycle") } catch DirectCloudError.invalidResponse {} catch { XCTFail("\(error)") }
    }
    func testFailedDownloadCleansStagingAndKeepsOriginals() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("original.sav"); try Data([7,8,9]).write(to: marker)
        let source = CloudFixtureSource(payloads: ["a": Data([1])], failID: "b")
        let transfer = DirectCloudTransfer(source: source, extensions: ["gb"])
        let plan = try await transfer.plan(selection: [.init(id: "a", name: "A.gb", folder: false, size: 1), .init(id: "b", name: "B.gb", folder: false, size: 1)])
        do { _ = try await transfer.prepare(plan, temporaryRoot: root) { _ in }; XCTFail("failure expected") } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["original.sav"])
        XCTAssertEqual(try Data(contentsOf: marker), Data([7,8,9]))
    }
    func testCancelledDownloadRemovesStagingAndKeepsOriginals() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("original.sav")
        try Data([7,8,9]).write(to: marker)
        let started = expectation(description: "Download started")
        let source = CloudWaitingSource(started: { started.fulfill() })
        let transfer = DirectCloudTransfer(source: source, extensions: ["gb"])
        let plan = try await transfer.plan(selection: [.init(id: "a", name: "A.gb", folder: false, size: 1)])
        let task = Task { try await transfer.prepare(plan, temporaryRoot: root) { _ in } }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        do { _ = try await task.value; XCTFail("cancel") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["original.sav"])
        XCTAssertEqual(try Data(contentsOf: marker), Data([7,8,9]))
    }
    func testCardsPairSiblingCoversWithoutDuplicatingThem() {
        let game = DirectCloudEntry(id: "game", name: "Mario.nes", folder: false, size: 1)
        let image = DirectCloudEntry(id: "image", name: "MARIO.PNG", folder: false, size: 1)
        let noCover = DirectCloudEntry(id: "no-cover", name: "Otro.gb", folder: false, size: 1)
        let orphan = DirectCloudEntry(id: "orphan", name: "Solo imagen.jpg", folder: false, size: 1)
        let folder = DirectCloudEntry(id: "folder", name: "Carpeta", folder: true)
        let index = DirectCloudArtworkIndex([game, image, noCover, orphan, folder])
        XCTAssertEqual(index.games.map(\.id), ["game", "no-cover"])
        XCTAssertEqual(index.covers[game.id], image)
        XCTAssertNil(index.covers[noCover.id])
        XCTAssertEqual(index.unpairedImages, [orphan]); XCTAssertEqual(index.folders, [folder])
    }
    @MainActor func testArtworkDownsamplesCachesAndNeverDownloadsGameBytes() async throws {
        let data = UIGraphicsImageRenderer(size: CGSize(width: 1500, height: 2100)).pngData { ctx in
            UIColor.orange.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 1500, height: 2100))
        }
        let source = CloudFixtureSource(payloads: ["cover": data])
        let loader = DirectCloudArtworkLoader(source: source)
        let entry = DirectCloudEntry(id: "cover", name: "Game.png", folder: false, size: Int64(data.count))
        let a = try await loader.image(entry), b = try await loader.image(entry)
        XCTAssertLessThanOrEqual(max(a.size.width, a.size.height), 320)
        XCTAssertEqual(a.size, b.size)
        do { _ = try await loader.image(.init(id: "rom", name: "Game.gb", folder: false, size: 1)); XCTFail("ROM preview") } catch DirectCloudError.noPreview {} catch { XCTFail("\(error)") }
        do { _ = try await loader.image(.init(id: "large", name: "Huge.png", folder: false, size: 31 * 1024 * 1024)); XCTFail("Oversize preview") } catch DirectCloudError.noPreview {} catch { XCTFail("\(error)") }
        let downloads = await source.downloaded
        XCTAssertEqual(downloads, ["cover"])
    }
    func testDownloadChecksumAndSize() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let bytes = Data("abc".utf8); try bytes.write(to: file)
        let hash = SHA256.hash(data: Data(SHA256.hash(data: bytes))).map { String(format: "%02x", $0) }.joined()
        var entry = DirectCloudEntry(id: "a", name: "A.gb", folder: false, size: 3, md5: "900150983cd24fb0d6963f7d28e17f72", dropboxHash: hash)
        XCTAssertNoThrow(try DirectCloudTransfer.validateFile(file, entry: entry))
        entry.md5 = "bad"; XCTAssertThrowsError(try DirectCloudTransfer.validateFile(file, entry: entry))
        entry.md5 = nil; entry.size = 4; XCTAssertThrowsError(try DirectCloudTransfer.validateFile(file, entry: entry))
    }
    @MainActor func testDirectFolderImportCoverPersistsAfterReopeningLibrary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        var rom = Data(repeating: 0, count: 16+16384+8192); rom.replaceSubrange(0..<6, with: [0x4e,0x45,0x53,0x1a,1,1])
        let cover = UIGraphicsImageRenderer(size: .init(width: 20, height: 30)).pngData { c in UIColor.orange.setFill(); c.fill(.init(x: 0,y: 0,width: 20,height: 30)) }
        let children = [DirectCloudEntry(id: "rom", name: "Test.nes", folder: false, size: Int64(rom.count)), .init(id: "cover", name: "Test.png", folder: false, size: Int64(cover.count))]
        let transfer = DirectCloudTransfer(source: CloudFixtureSource(folders: ["console": children], payloads: ["rom": rom, "cover": cover]), extensions: ["nes", "png"])
        let plan = try await transfer.plan(selection: [.init(id: "console", name: "NES", folder: true)])
        let snapshot = try await transfer.prepare(plan, temporaryRoot: root) { _ in }
        let library = Library(root: root.appendingPathComponent("library"))
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let art = ArtworkStore(root: library.root, defaults: defaults)
        let first = try library.importURLs(snapshot.files, console: .nes, artwork: art)
        XCTAssertEqual(first.games, 1); XCTAssertEqual(first.covers, 1)
        let game = try XCTUnwrap(library.games.first)
        let save = Data([1,2,3]); try save.write(to: library.file(game, "battery.sav"))
        _ = try library.importURLs(snapshot.files, console: .nes, artwork: art)
        XCTAssertEqual(library.games.count, 1)
        snapshot.remove()
        let reopened = Library(root: library.root), freshArt = ArtworkStore(root: library.root, defaults: defaults)
        XCTAssertEqual(reopened.games.count, 1); XCTAssertNotNil(freshArt.image(game))
        XCTAssertEqual(try Data(contentsOf: reopened.file(game,"battery.sav")), save)
        XCTAssertEqual(try Data(contentsOf: reopened.romURL(game)), rom)
    }
}

@MainActor final class DirectCloudLayoutTests: XCTestCase {
    func testScreensAtSmallPortraitLandscapeAndAccessibilitySizes() throws {
        for (label, size, accessibility) in [("portrait", CGSize(width: 375, height: 812), false), ("landscape", CGSize(width: 812, height: 375), false), ("large-text", CGSize(width: 375, height: 812), true)] {
            for browsing in [false, true] {
                let model = DirectCloudBrowserModel()
                if browsing {
                    model.provider = .google
                    model.entries = [.init(id:"folder",name:"Game Boy Advance",folder:true), .init(id:"game",name:"Un juego con nombre largo para comprobar la selección.gb",folder:false,size:32768), .init(id:"cover",name:"Un juego con nombre largo para comprobar la selección.png",folder:false,size:8000)]
                    model.selected = ["game"]
                }
                let view = DirectCloudView(model:model) { _ in "Importación de prueba" }.environment(\.dynamicTypeSize, accessibility ? .accessibility3 : .large).preferredColorScheme(.dark)
                let controller = UIHostingController(rootView:view)
                let window = UIWindow(frame:CGRect(origin:.zero,size:size));window.rootViewController=controller;window.makeKeyAndVisible()
                controller.view.frame=window.bounds;controller.view.setNeedsLayout();controller.view.layoutIfNeeded()
                RunLoop.main.run(until:Date().addingTimeInterval(0.15))
                let image = UIGraphicsImageRenderer(size:size).image { _ in controller.view.drawHierarchy(in:controller.view.bounds,afterScreenUpdates:true) }
                let attachment = XCTAttachment(image:image);attachment.name="cloud-\(browsing ? "browser":"accounts")-\(label)";attachment.lifetime = .keepAlways;add(attachment)
                XCTAssertEqual(image.size,size)
                window.isHidden=true;window.rootViewController=nil
            }
        }
    }
}
