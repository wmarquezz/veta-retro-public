import XCTest
@testable import VetaNative

private final class PortalMockHTTP: DirectCloudHTTP {
    var requests: [URLRequest] = []
    var unauthorized = false
    var failure: Error?
    var bytes = Data([1,2,3])
    func data(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let failure { throw failure }
        let url = request.url!
        if url.path.hasSuffix("login") {
            let status = unauthorized ? 401 : 200
            return (Data("{}".utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Set-Cookie":"__Host-veta-share=test-session; Path=/; HttpOnly; Secure; SameSite=Strict"])!)
        }
        let next = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
        let body: [String:Any] = next == nil ? ["items":[["item":"game-token","name":"A_KANOID.zip","folder":false,"size":"3","download":true]],"next":"page2"] : ["items":[["item":"image-token","name":"A_KANOID.png","folder":false,"size":"3","download":true]]]
        return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: url,statusCode:200,httpVersion:nil,headerFields:nil)!)
    }
    func download(_ request: URLRequest, progress: @escaping @Sendable (Int64,Int64)->Void) async throws -> (URL,HTTPURLResponse) {
        requests.append(request)
        let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to:file)
        return (file,HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
    }
}
final class KrafifySharedPortalTests: XCTestCase {
    func testOnlyExplicitHTTPSPortalIsAccepted() throws {
        XCTAssertNoThrow(try KrafifySharedConnection.validateLink(" https://retro.krafify.com/compartir "))
        for url in ["http://retro.krafify.com/compartir","https://retro.krafify.com.evil.test/compartir","https://user:pass@retro.krafify.com/compartir","https://retro.krafify.com:8443/compartir","https://retro.krafify.com/jugar","https://retro.krafify.com/compartir?url=https://evil.test","https://127.0.0.1/compartir"] { XCTAssertThrowsError(try KrafifySharedConnection.validateLink(url)) }
    }
    func testLoginPaginationAndZIPCoverPairing() async throws {
        let http=PortalMockHTTP(),source=KrafifySharedConnection(http:PortalMockHTTP())
        do { _ = try await source.list(folder:"root"); XCTFail("List must require login") } catch {}
        let connected=KrafifySharedConnection(http:http)
        try await connected.login(link:"https://retro.krafify.com/compartir",password:"test-only-password")
        let items=try await connected.list(folder:"root")
        XCTAssertEqual(items.count,2)
        XCTAssertEqual(DirectCloudArtworkIndex(items).covers["game-token"]?.id,"image-token")
        XCTAssertEqual(http.requests[0].value(forHTTPHeaderField:"Origin"),KrafifySharedConnection.origin)
        XCTAssertNil(http.requests[0].value(forHTTPHeaderField:"Cookie"))
        XCTAssertEqual(http.requests[1].value(forHTTPHeaderField:"Cookie"),"__Host-veta-share=test-session")
        XCTAssertFalse(http.requests[1].url!.absoluteString.contains("test-only-password"))
        XCTAssertNil(http.requests[1].httpBody)
        XCTAssertEqual(URLComponents(url:http.requests[2].url!,resolvingAgainstBaseURL:false)?.queryItems?.first?.value,"page2")
    }
    func testWrongPasswordNeverStartsListing() async throws {
        let http=PortalMockHTTP();http.unauthorized=true
        let source=KrafifySharedConnection(http:http)
        do {try await source.login(link:"https://retro.krafify.com/compartir",password:"wrong");XCTFail()}catch{}
        do {_ = try await source.list(folder:"root");XCTFail()}catch{}
        XCTAssertEqual(http.requests.count,1)
    }
    func testDownloadedSizeMustMatchBeforeImport() async throws {
        let http=PortalMockHTTP(),entry=DirectCloudEntry(id:"file-token",name:"A_KANOID.gb",folder:false,size:3)
        let source=KrafifySharedConnection(http:http)
        try await source.login(link:"https://retro.krafify.com/compartir",password:"test-only-password")
        let file=try await source.download(entry){_,_ in};defer{try? FileManager.default.removeItem(at:file)}
        XCTAssertEqual(try Data(contentsOf:file),Data([1,2,3]))
        http.bytes=Data([1])
        do {_ = try await source.download(entry){_,_ in};XCTFail("Incomplete file must not import")}catch{}
    }
}

private final class MemorySharedAccess: SharedAccessStorage {
    var value: SharedAccessCredential?
    func read() throws -> SharedAccessCredential? { value }
    func write(_ value: SharedAccessCredential) throws { self.value = value }
    func remove() throws { value = nil }
}

@MainActor final class SharedAccessRememberTests: XCTestCase {
    let link = "https://retro.krafify.com/compartir"
    func testSuccessfulAccessIsRestoredByNewFormAndCanBeForgotten() async throws {
        let store = MemorySharedAccess(), http = PortalMockHTTP()
        let first = SharedAccessForm(storage: store)
        first.address = link; first.password = "test-only-password"
        _ = try await first.authenticate(http: http)
        let reopened = SharedAccessForm(storage: store); try reopened.restore()
        XCTAssertEqual(reopened.address, link); XCTAssertEqual(reopened.password, "test-only-password")
        XCTAssertTrue(reopened.hasSavedAccess)
        _ = try await reopened.authenticate(http: http)
        XCTAssertEqual(http.requests.count, 2, "Reopening must authenticate against current server password")
        try reopened.forget()
        XCTAssertNil(store.value); XCTAssertTrue(reopened.address.isEmpty); XCTAssertTrue(reopened.password.isEmpty)
    }
    func testChangedPasswordDropsRejectedSecretButKeepsAddress() async throws {
        let store = MemorySharedAccess(); store.value = .init(link: link, password: "old-password")
        let form = SharedAccessForm(storage: store); try form.restore()
        let http = PortalMockHTTP(); http.unauthorized = true
        do { _ = try await form.authenticate(http: http); XCTFail("Old password must fail") } catch {}
        XCTAssertEqual(store.value?.link, link); XCTAssertNil(store.value?.password); XCTAssertTrue(form.password.isEmpty)
        let reopened = SharedAccessForm(storage: store); try reopened.restore()
        XCTAssertEqual(reopened.address, link); XCTAssertTrue(reopened.password.isEmpty)
        http.unauthorized = false; reopened.password = "new-password"
        _ = try await reopened.authenticate(http: http)
        XCTAssertEqual(store.value?.password, "new-password")
    }
    func testNetworkFailurePreservesRememberedAccess() async throws {
        let store = MemorySharedAccess(); store.value = .init(link: link, password: "saved-password")
        let form = SharedAccessForm(storage: store); try form.restore()
        let http = PortalMockHTTP(); http.failure = URLError(.notConnectedToInternet)
        do { _ = try await form.authenticate(http: http); XCTFail() } catch {}
        XCTAssertEqual(store.value?.password, "saved-password")
    }
    func testUncheckedRememberDoesNotPersistAndClearsOldAccess() async throws {
        let store = MemorySharedAccess(); store.value = .init(link: link, password: "previous")
        let form = SharedAccessForm(storage: store); try form.restore()
        form.remember = false; form.password = "test-only-password"
        _ = try await form.authenticate(http: PortalMockHTTP())
        XCTAssertNil(store.value); XCTAssertFalse(form.hasSavedAccess)
    }
    func testRealKeychainSurvivesNewStoreAndSupportsReplacementAndRemoval() throws {
        let account = "unit-test-" + UUID().uuidString
        let store = SharedAccessKeychain(account: account)
        defer { try? store.remove() }
        try store.write(.init(link: link, password: "test-only-password"))
        let reopened = SharedAccessKeychain(account: account)
        XCTAssertEqual(try reopened.read()?.password, "test-only-password")
        try reopened.write(.init(link: link, password: nil))
        XCTAssertNil(try store.read()?.password)
        try reopened.remove(); XCTAssertNil(try store.read())
    }
    func testFailedReloginCannotReusePreviouslyIssuedCookie() async throws {
        let http = PortalMockHTTP(), source = KrafifySharedConnection(http: PortalMockHTTP())
        let connected = KrafifySharedConnection(http: http)
        try await connected.login(link: link, password: "old")
        http.unauthorized = true
        do { try await connected.login(link: link, password: "old"); XCTFail() } catch {}
        do { _ = try await connected.list(folder: "root"); XCTFail() } catch {}
        XCTAssertEqual(http.requests.count, 2)
        _ = source
    }
}
