#if VETA_JIT_DEVELOPMENT
import XCTest
import WebKit
import Network
import CryptoKit
@testable import VetaJITLab

/// Opt-in, read-only homebrew experiment. Only the emulator assets are bundled.
/// The disc is streamed from the existing library; all emulator writes stay in MEMFS.
@MainActor final class OfflinePS2WebKitTests:XCTestCase,WKScriptMessageHandler,WKNavigationDelegate {
    private var result:[String:Any]?
    private var completion:XCTestExpectation?

    func userContentController(_ userContentController:WKUserContentController,didReceive message:WKScriptMessage) {
        guard let value=message.body as? [String:Any] else{return}
        if let data=try? JSONSerialization.data(withJSONObject:value,options:.sortedKeys) {
            print("VETA160_PS2_WASM "+String(decoding:data,as:UTF8.self))
        }
        if value["terminal"] as? Bool == true {finish(value)}
    }
    private func finish(_ value:[String:Any]) {
        guard let done=completion else{return}
        result=value;completion=nil;done.fulfill()
    }
    func webView(_ webView:WKWebView,didFailProvisionalNavigation navigation:WKNavigation!,withError error:Error) {
        finish(["terminal":true,"error":"Navigation: "+error.localizedDescription])
    }
    func webView(_ webView:WKWebView,didFail navigation:WKNavigation!,withError error:Error) {
        finish(["terminal":true,"error":"Navigation: "+error.localizedDescription])
    }
    func webViewWebContentProcessDidTerminate(_ webView:WKWebView) {
        finish(["terminal":true,"error":"WebContent process terminated"])
    }

    func test160PS2WasmColdLocalHomebrew()async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VETA_OFFLINE160_PS2_WASM"] == "1")
        let root=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("VetaNative")
        let indexURL=root.appendingPathComponent("library.json"),indexBefore=try Data(contentsOf:indexURL)
        let games=try JSONDecoder().decode([Game].self,from:indexBefore)
        let game=try XCTUnwrap(games.first{$0.console == .ps2 && $0.name == "Prueba JIT PS2"})
        guard game.id.count==64,game.id.allSatisfy({$0.isHexDigit}),let name=game.contentName,
              !name.contains("/"),!name.contains("\\"),["iso","elf","cso","chd","isz","bin"].contains((name as NSString).pathExtension.lowercased()) else {
            throw VetaError.message("Unexpected homebrew fixture metadata")
        }
        let file=root.appendingPathComponent(game.id).appendingPathComponent(name)
        let info=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey,.contentModificationDateKey])
        guard info.isRegularFile == true,info.isSymbolicLink != true,let size=info.fileSize,size>0 else {
            throw VetaError.message("Homebrew fixture unavailable")
        }
        let bundle=Bundle(for:Self.self)
        let js=try XCTUnwrap(bundle.url(forResource:"Play",withExtension:"js",subdirectory:"PS2Wasm"))
        let wasm=try XCTUnwrap(bundle.url(forResource:"Play",withExtension:"wasm",subdirectory:"PS2Wasm"))
        let jsData=try Data(contentsOf:js),wasmData=try Data(contentsOf:wasm)
        func digest(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
        XCTAssertEqual(digest(jsData),"91e28d659b1991aa7398a1e2221291ef613d8b6130a13435b9321fa4fc54e201")
        XCTAssertEqual(digest(wasmData),"7bb277dd3190b8f75ad3b656458abb40ab0746f49903e50647a32e7f369e974f")
        let fixtureConfig=try JSONSerialization.data(withJSONObject:["name":name,"size":size],options:.sortedKeys)
        let html=Self.page.replacingOccurrences(of:"__FIXTURE__",with:String(decoding:fixtureConfig,as:UTF8.self))
        let server=try PS2WasmLoopbackServer(html:Data(html.utf8),js:jsData,wasm:wasmData,disc:file,discSize:UInt64(size))
        defer {server.stop()}
        let ready=expectation(description:"PS2 loopback server")
        server.start{ready.fulfill()}
        await fulfillment(of:[ready],timeout:10)
        let port=try XCTUnwrap(server.port)
        let config=WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.userContentController.add(self,name:"report")
        let window=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.flatMap(\.windows).first)
        let web=WKWebView(frame:window.bounds,configuration:config)
        web.navigationDelegate=self;window.addSubview(web)
        defer {
            web.stopLoading();web.removeFromSuperview();web.navigationDelegate=nil
            config.userContentController.removeScriptMessageHandler(forName:"report")
        }
        let done=expectation(description:"PS2 WASM render evidence");completion=done
        web.load(URLRequest(url:URL(string:"http://127.0.0.1:\(port)/")!))
        await fulfillment(of:[done],timeout:165)
        let snapshotDone=expectation(description:"PS2 WASM screenshot")
        web.takeSnapshot(with:nil){image,error in
            if let image {let attachment=XCTAttachment(image:image);attachment.name="VETA160-PS2-WASM-homebrew";attachment.lifetime = .keepAlways;self.add(attachment)}
            if let error {print("VETA160_PS2_WASM_SNAPSHOT "+error.localizedDescription)}
            snapshotDone.fulfill()
        }
        await fulfillment(of:[snapshotDone],timeout:10)
        // No emulator storage is mounted to disk; verify metadata and the index too.
        XCTAssertEqual(try Data(contentsOf:indexURL),indexBefore)
        let after=try file.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey])
        XCTAssertEqual(after.fileSize,info.fileSize)
        XCTAssertEqual(after.contentModificationDate,info.contentModificationDate)
        let report=try XCTUnwrap(result)
        XCTAssertNil(report["error"],String(describing:report))
        XCTAssertGreaterThan((report["frames"] as? NSNumber)?.intValue ?? 0,10)
        XCTAssertGreaterThan((report["maxColors"] as? NSNumber)?.intValue ?? 0,2)
        XCTAssertGreaterThan((report["readBytes"] as? NSNumber)?.intValue ?? 0,0)
    }

    private static let page = #"""
    <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
    <style>html,body{margin:0;background:#111;color:white;font:14px system-ui}canvas{display:block;width:100%;height:auto}pre{white-space:pre-wrap}</style></head>
    <body><canvas id="outputCanvas" width="640" height="480" tabindex="0"></canvas><pre id="status">VETA · PS2 local</pre>
    <script type="module">
    const fixture=__FIXTURE__,canvas=document.querySelector('canvas'),status=document.querySelector('#status');
    let ended=false,module=null,readBytes=0,readRequests=0,maxColors=0,start=performance.now(),firstVisible=null,initialFrames=0;
    const report=(value)=>{status.textContent=JSON.stringify(value);window.webkit.messageHandlers.report.postMessage(value)};
    const fail=(error)=>{if(ended)return;ended=true;report({terminal:true,error:String(error),readBytes,readRequests,maxColors,seconds:(performance.now()-start)/1000})};
    window.addEventListener('error',e=>fail(e.message));window.addEventListener('unhandledrejection',e=>fail(e.reason));
    const watchdog=setTimeout(()=>fail('150 second render timeout'),150000);
    const originalGetContext=canvas.getContext.bind(canvas);
    canvas.getContext=(kind,attrs)=>originalGetContext(kind,kind.startsWith('webgl')?{...attrs,preserveDrawingBuffer:true}:attrs);
    // Keep this automated diagnostic silent; no audio context starts AirPlay.
    const BaseAudio=window.AudioContext || window.webkitAudioContext;
    if(BaseAudio){class SilentAudio extends BaseAudio{constructor(...args){super(...args);this.suspend()}resume(){return Promise.resolve()}}window.AudioContext=SilentAudio;window.webkitAudioContext=SilentAudio}
    async function range(offset,length){
      if(!Number.isSafeInteger(offset)||!Number.isSafeInteger(length)||offset<0||length<0||offset+length>fixture.size)throw Error('Invalid disc read');
      const response=await fetch('/disc',{headers:{Range:`bytes=${offset}-${offset+length-1}`}});
      if(response.status!==206)throw Error('Disc HTTP '+response.status);
      const bytes=new Uint8Array(await response.arrayBuffer());if(bytes.length!==length)throw Error('Short disc read');
      readBytes+=bytes.length;readRequests++;return bytes;
    }
    function colors(){
      const gl=canvas.getContext('webgl2');if(!gl)return 0;
      const old=gl.getParameter(gl.FRAMEBUFFER_BINDING);gl.bindFramebuffer(gl.FRAMEBUFFER,null);
      const pixels=new Uint8Array(640*480*4);gl.readPixels(0,0,640,480,gl.RGBA,gl.UNSIGNED_BYTE,pixels);gl.bindFramebuffer(gl.FRAMEBUFFER,old);
      const seen=new Set();for(let p=0;p<pixels.length;p+=256){seen.add((pixels[p]<<16)|(pixels[p+1]<<8)|pixels[p+2]);if(seen.size>=64)break}return seen.size;
    }
    try{
      if(!isSecureContext||!crossOriginIsolated||typeof SharedArrayBuffer!=='function')throw Error('Missing isolated WASM context');
      const {default:Play}=await import('/Play.js');
      module=await Play({locateFile:p=>new URL(p,location.href).href,mainScriptUrlOrBlob:new URL('/Play.js',location.href).href,
        print:s=>{console.log(s);if(/Initializing|Starting|Loading|Version/.test(s))report({stage:'core',text:String(s)})},
        printErr:s=>console.error(s),onAbort:s=>fail('WASM abort: '+s)});
      module.FS.mkdir('/work');
      module.discImageDevice={done:true,getFileSize:()=>fixture.size,isDone(){return this.done},read(dst,offset,size){
        this.done=false;(async()=>{try{for(let done=0;done<size;){const count=Math.min(1048576,size-done),bytes=await range(offset+done,count);module.HEAPU8.set(bytes,dst+done);done+=count}}
        catch(e){fail(e);module.HEAPU8.fill(0,dst,dst+size)}finally{this.done=true}})();
      }};
      module.ccall('initVm','',[],[]);canvas.focus();
      if(fixture.name.toLowerCase().endsWith('.elf')){
        if(fixture.size>33554432)throw Error('ELF exceeds bounded diagnostic size');
        const fd=module.FS.open('/work/game.elf','w');try{for(let offset=0;offset<fixture.size;){const bytes=await range(offset,Math.min(1048576,fixture.size-offset));module.FS.write(fd,bytes,0,bytes.length,offset);offset+=bytes.length}}finally{module.FS.close(fd)}
        module.bootElf('/work/game.elf');
      }else module.bootDiscImage(fixture.name);
      report({stage:'booted',isolated:crossOriginIsolated,readBytes,readRequests});
      const tick=setInterval(()=>{if(ended){clearInterval(tick);return}try{
        const frames=module.getFrames();maxColors=Math.max(maxColors,colors());const elapsed=(performance.now()-start)/1000;
        if(maxColors>2&&frames>10&&firstVisible===null){firstVisible=performance.now();initialFrames=frames}
        report({stage:'running',frames,maxColors,readBytes,readRequests,seconds:elapsed});
        if(firstVisible!==null&&performance.now()-firstVisible>=15000&&frames-initialFrames>10){ended=true;clearInterval(tick);clearTimeout(watchdog);report({terminal:true,frames,maxColors,readBytes,readRequests,seconds:elapsed,observedFPS:(frames-initialFrames)/((performance.now()-firstVisible)/1000)})}
      }catch(e){fail(e)}},1000);
    }catch(e){fail(e)}
    </script></body></html>
    """#
}

/// Exact routes only, read-only descriptor, bounded ranges, loopback binding.
private final class PS2WasmLoopbackServer {
    private let listener:NWListener
    private let queue=DispatchQueue(label:"veta.offline160.ps2-http")
    private let html:Data,js:Data,wasm:Data,disc:URL,discSize:UInt64
    private var connections:[NWConnection]=[]
    var port:UInt16? {listener.port?.rawValue}
    init(html:Data,js:Data,wasm:Data,disc:URL,discSize:UInt64)throws {
        self.html=html;self.js=js;self.wasm=wasm;self.disc=disc;self.discSize=discSize
        let parameters=NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:.any)
        listener=try NWListener(using:parameters,on:.any)
    }
    func start(ready:@escaping()->Void) {
        listener.stateUpdateHandler={state in if case .ready=state {ready()}}
        listener.newConnectionHandler={[weak self] connection in
            guard let self else{return};self.connections.append(connection)
            connection.start(queue:self.queue);self.receive(connection,buffer:Data())
        }
        listener.start(queue:queue)
    }
    func stop(){listener.cancel();queue.async{self.connections.forEach{$0.cancel()};self.connections.removeAll()}}
    private func receive(_ connection:NWConnection,buffer:Data) {
        connection.receive(minimumIncompleteLength:1,maximumLength:8192){[weak self] data,_,complete,error in
            guard let self else{return}
            let next=buffer+(data ?? Data())
            if next.count>16384 {self.send(connection,status:"431 Request Header Fields Too Large",body:Data());return}
            if next.range(of:Data("\r\n\r\n".utf8)) != nil {self.respond(connection,request:String(decoding:next,as:UTF8.self))}
            else if error != nil || complete {connection.cancel()}
            else {self.receive(connection,buffer:next)}
        }
    }
    private func respond(_ connection:NWConnection,request:String) {
        let lines=request.components(separatedBy:"\r\n"),first=(lines.first ?? "").split(separator:" ")
        guard first.count==3,["GET","HEAD"].contains(String(first[0])) else{send(connection,status:"405 Method Not Allowed",body:Data());return}
        let headOnly=first[0]=="HEAD",path=String(first[1])
        if path=="/" {send(connection,body:html,type:"text/html; charset=utf-8",headOnly:headOnly);return}
        if path=="/Play.js" {send(connection,body:js,type:"text/javascript",headOnly:headOnly);return}
        if path=="/Play.wasm" {send(connection,body:wasm,type:"application/wasm",headOnly:headOnly);return}
        guard path=="/disc" else{send(connection,status:"404 Not Found",body:Data());return}
        guard let header=lines.first(where:{$0.lowercased().hasPrefix("range:")}),
              let value=header.split(separator:":",maxSplits:1).last?.trimmingCharacters(in:.whitespaces),value.hasPrefix("bytes=") else {
            send(connection,status:"416 Range Not Satisfiable",body:Data(),extra:"Content-Range: bytes */\(discSize)\r\n");return
        }
        let bounds=value.dropFirst(6).split(separator:"-",omittingEmptySubsequences:false)
        guard bounds.count==2,let lower=UInt64(bounds[0]),let upper=UInt64(bounds[1]),lower<=upper,upper<discSize,upper-lower<1048576 else {
            send(connection,status:"416 Range Not Satisfiable",body:Data(),extra:"Content-Range: bytes */\(discSize)\r\n");return
        }
        do {
            let file=try FileHandle(forReadingFrom:disc);defer{try? file.close()}
            try file.seek(toOffset:lower)
            let data=try file.read(upToCount:Int(upper-lower+1)) ?? Data()
            guard data.count==Int(upper-lower+1) else{throw NSError(domain:"PS2Range",code:1)}
            send(connection,status:"206 Partial Content",body:data,extra:"Accept-Ranges: bytes\r\nContent-Range: bytes \(lower)-\(upper)/\(discSize)\r\n",headOnly:headOnly)
        }catch {send(connection,status:"500 Internal Server Error",body:Data())}
    }
    private func send(_ connection:NWConnection,status:String="200 OK",body:Data,type:String="application/octet-stream",extra:String="",headOnly:Bool=false) {
        let header="HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCross-Origin-Opener-Policy: same-origin\r\nCross-Origin-Embedder-Policy: require-corp\r\nCross-Origin-Resource-Policy: same-origin\r\nCache-Control: no-store\r\nConnection: close\r\n\(extra)\r\n"
        connection.send(content:Data(header.utf8)+(headOnly ? Data():body),completion:.contentProcessed{[weak self] _ in
            connection.cancel();self?.connections.removeAll{$0 === connection}
        })
    }
}
#endif
