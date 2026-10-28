#if VETA_JIT_DEVELOPMENT
import XCTest
import WebKit
import Network
@testable import VetaJITLab

/// A self-contained localhost page. No remote assets, games or network change.
@MainActor final class OfflineWebKitCapabilityTests:XCTestCase,WKScriptMessageHandler {
    private var report:[String:Any]?
    private var reported:XCTestExpectation?
    func userContentController(_ userContentController:WKUserContentController,didReceive message:WKScriptMessage) {
        report=message.body as? [String:Any];reported?.fulfill();reported=nil
    }
    func test160LocalhostWasmThreads()async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VETA_OFFLINE160_WEBKIT"] == "1")
        let body="""
        <!doctype html><meta name="viewport" content="width=device-width"><p>VETA · comprobación local</p>
        <script>
        (async()=>{let r={secure:isSecureContext,isolated:crossOriginIsolated,wasm:typeof WebAssembly,sab:typeof SharedArrayBuffer};
        try{await WebAssembly.compile(new Uint8Array([0,97,115,109,1,0,0,0]));r.compile=true;
        let m=new WebAssembly.Memory({initial:1,maximum:1,shared:true});Atomics.store(new Int32Array(m.buffer),0,7);r.atomic=Atomics.load(new Int32Array(m.buffer),0);
        let u=URL.createObjectURL(new Blob(['onmessage=e=>{Atomics.add(new Int32Array(e.data),0,1);postMessage(Atomics.load(new Int32Array(e.data),0))}'],{type:'application/javascript'}));
        let w=new Worker(u);r.worker=await new Promise((resolve,reject)=>{w.onmessage=e=>resolve(e.data);w.onerror=e=>reject(Error(e.message));w.postMessage(m.buffer)});w.terminate();URL.revokeObjectURL(u);
        }catch(e){r.error=String(e)}window.webkit.messageHandlers.report.postMessage(r)})();
        </script>
        """
        let payload=Data(body.utf8)
        let head="HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(payload.count)\r\nCross-Origin-Opener-Policy: same-origin\r\nCross-Origin-Embedder-Policy: require-corp\r\nCross-Origin-Resource-Policy: same-origin\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        let response=Data(head.utf8)+payload
        let parameters=NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:.any)
        let listener=try NWListener(using:parameters,on:.any)
        let ready=expectation(description:"Loopback listener")
        listener.stateUpdateHandler={state in if case .ready=state {ready.fulfill()}}
        listener.newConnectionHandler={connection in
            connection.start(queue:DispatchQueue.global(qos:.userInitiated))
            connection.receive(minimumIncompleteLength:1,maximumLength:65536){_,_,_,_ in
                connection.send(content:response,completion:.contentProcessed{_ in connection.cancel()})
            }
        }
        listener.start(queue:DispatchQueue(label:"veta.offline160.web-test"))
        defer {listener.cancel()}
        await fulfillment(of:[ready],timeout:10)
        let port=try XCTUnwrap(listener.port)
        let config=WKWebViewConfiguration();config.userContentController.add(self,name:"report")
        let web=WKWebView(frame:CGRect(x:0,y:0,width:390,height:700),configuration:config)
        let window=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.flatMap(\.windows).first)
        window.addSubview(web)
        defer {web.stopLoading();web.removeFromSuperview();config.userContentController.removeScriptMessageHandler(forName:"report")}
        let done=expectation(description:"Local WebAssembly report");reported=done
        web.load(URLRequest(url:URL(string:"http://127.0.0.1:\(port.rawValue)/")!))
        await fulfillment(of:[done],timeout:25)
        let result=try XCTUnwrap(report)
        let bytes=try JSONSerialization.data(withJSONObject:result,options:.sortedKeys)
        print("VETA160_WEBKIT "+String(decoding:bytes,as:UTF8.self))
        XCTAssertEqual(result["secure"] as? Bool,true)
        XCTAssertEqual(result["isolated"] as? Bool,true)
        XCTAssertEqual(result["compile"] as? Bool,true)
        XCTAssertEqual(result["atomic"] as? Int,7)
        XCTAssertEqual(result["worker"] as? Int,8)
        XCTAssertNil(result["error"])
    }
}
#endif
