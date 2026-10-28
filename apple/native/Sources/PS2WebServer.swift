import Foundation
import Network
import CryptoKit
import Security
import Darwin

/// Private loopback origin for the bundled PS2 engine. Paths never select an
/// arbitrary device file; writable state belongs only to this engine instance.
// Mutable state is confined to queue; public entry points only enqueue work.
final class PS2WebServer:@unchecked Sendable {
    private static let mib=1024*1024
    private let queue=DispatchQueue(label:"veta.ps2.web-files",qos:.userInitiated)
    private let html:Data,assets:URL,disc:URL,storage:URL,gameID:String,stateFormat:String
    private let prefix:String
    private var listener:NWListener?
    private var pendingStart:CheckedContinuation<URL,Error>?
    private var baseURL:URL?,origin="",host="",discSize:UInt64=0
    private var discReader:PS2DiscReader?
    private var filesRoot:URL?,statesRoot:URL?
    private var storageTransaction:String?
    private var stopped=false
    private var requests:[ObjectIdentifier:Request]=[:]
    private var bufferedBytes=0
    private var manualPreview: (slot: String, data: Data)?
    var manualSaveStore: NativeSaveStore {
        NativeSaveStore(directory: storage.appendingPathComponent("manual-saves"), rom: gameID, core: stateFormat)
    }
    func stageManualPreview(_ data: Data?, slot: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard NativeSaveStore.manualSlots.contains(slot), !self.stopped, (data?.count ?? 0) <= 512*1024 else {
                    continuation.resume(throwing: self.failure("Invalid manual preview")); return
                }
                self.manualPreview = data.map { (slot, $0) }
                continuation.resume()
            }
        }
    }

    init(html:Data,assets:URL,disc:URL,storage:URL,gameID:String,stateFormat:String) {
        self.html=html;self.assets=assets;self.disc=disc;self.storage=storage
        self.gameID=gameID;self.stateFormat=stateFormat
        var nonce=[UInt8](repeating:0,count:16)
        let secure=SecRandomCopyBytes(kSecRandomDefault,nonce.count,&nonce)==errSecSuccess
        self.prefix=secure ? "/"+nonce.map{String(format:"%02x",$0)}.joined()+"/":""
    }

    func start()async throws->URL {
        try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation {continuation in
                queue.async {
                    if let url=self.baseURL {continuation.resume(returning:url);return}
                    guard !self.stopped,self.pendingStart==nil else {continuation.resume(throwing:self.failure("Server unavailable"));return}
                    self.pendingStart=continuation
                    do {
                        try self.prepareStorage()
                        let parameters=NWParameters.tcp
                        parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:.any)
                        let listener=try NWListener(using:parameters,on:.any);self.listener=listener
                        listener.stateUpdateHandler={[weak self] state in
                            guard let self else{return}
                            switch state {
                            case .ready:
                                guard let port=self.listener?.port else{self.finishStart(.failure(self.failure("Missing listener port")));return}
                                self.host="127.0.0.1:\(port.rawValue)";self.origin="http://"+self.host
                                let url=URL(string:self.origin+self.prefix)!
                                self.baseURL=url;self.finishStart(.success(url))
                            case .failed(let error):self.finishStart(.failure(error));self.close()
                            case .cancelled:self.finishStart(.failure(CancellationError()))
                            default:break
                            }
                        }
                        listener.newConnectionHandler={[weak self] connection in self?.accept(connection)}
                        listener.start(queue:self.queue)
                        self.queue.asyncAfter(deadline:.now()+10){[weak self] in
                            guard let self,self.pendingStart != nil else{return}
                            self.finishStart(.failure(self.failure("Loopback listener timed out")));self.close()
                        }
                    }catch {self.finishStart(.failure(error));self.close()}
                }
            }
        },onCancel:{self.stop()})
    }

    func stop(){queue.async{self.close()}}
    private func close() {
        stopped=true;baseURL=nil;listener?.cancel();listener=nil
        finishStart(.failure(CancellationError()))
        for request in requests.values {request.connection.cancel()}
        requests.removeAll();bufferedBytes=0;discReader=nil
        try? recoverStorageTransaction()
    }
    private func finishStart(_ result:Result<URL,Error>) {let callback=pendingStart;pendingStart=nil;callback?.resume(with:result)}
    private func failure(_ message:String)->Error {NSError(domain:"VetaPS2WebServer",code:1,userInfo:[NSLocalizedDescriptionKey:message])}

    private final class Request {
        let connection:NWConnection
        var header=Data(),body=Data(),expected=0,parsed=false,finished=false
        var method="",route="",headers:[String:String]=[:]
        init(_ connection:NWConnection){self.connection=connection}
    }
    private struct HTTPError:Error {let code:Int;let message:String}
    private func reject(_ code:Int,_ message:String)->HTTPError {HTTPError(code:code,message:message)}

    private func accept(_ connection:NWConnection) {
        guard !stopped,requests.count<16 else{connection.cancel();return}
        let request=Request(connection);requests[ObjectIdentifier(request)]=request
        connection.start(queue:queue)
        queue.asyncAfter(deadline:.now()+30){[weak self,weak request] in
            guard let self,let request,!request.finished else{return}
            self.send(request,code:408,body:Data("Request timed out".utf8))
        }
        receive(request)
    }
    private func receive(_ request:Request) {
        request.connection.receive(minimumIncompleteLength:1,maximumLength:65536){[weak self,weak request] data,_,complete,error in
            guard let self,let request,!request.finished else{return}
            do {
                if let data,!data.isEmpty {
                    if request.parsed {try self.append(data,to:request)}
                    else {
                        request.header.append(data)
                        if let end=request.header.range(of:Data("\r\n\r\n".utf8)) {
                            guard end.upperBound<=16384 else{throw self.reject(431,"Headers too large")}
                            let head=request.header.subdata(in:0..<end.lowerBound),body=request.header.subdata(in:end.upperBound..<request.header.count)
                            request.header.removeAll();try self.parse(head,request:request);request.parsed=true
                            try self.append(body,to:request)
                        }else if request.header.count>16384 {throw self.reject(431,"Headers too large")}
                    }
                }
                if request.parsed,request.body.count==request.expected {try self.respond(request);return}
                if complete || error != nil {throw self.reject(400,"Incomplete request")}
                self.receive(request)
            }catch let error as HTTPError {self.send(request,code:error.code,body:Data(error.message.utf8))}
            catch {self.send(request,code:500,body:Data("Local file operation failed".utf8))}
        }
    }
    private func append(_ data:Data,to request:Request)throws {
        guard request.body.count+data.count<=request.expected else{throw reject(400,"Unexpected request body")}
        guard bufferedBytes+data.count<=129*Self.mib else{throw reject(413,"Too much buffered data")}
        request.body.append(data);bufferedBytes+=data.count
    }
    private func parse(_ data:Data,request:Request)throws {
        guard let text=String(data:data,encoding:.utf8) else{throw reject(400,"Invalid headers")}
        let lines=text.components(separatedBy:"\r\n"),first=(lines.first ?? "").split(separator:" ")
        guard first.count==3,first[2]=="HTTP/1.1",["GET","HEAD","PUT"].contains(String(first[0])) else{throw reject(405,"Unsupported method")}
        request.method=String(first[0]);let target=String(first[1])
        guard target.hasPrefix(prefix),!target.contains("?"),!target.contains("#") else{throw reject(404,"Not found")}
        request.route=String(target.dropFirst(prefix.count))
        for line in lines.dropFirst() {
            guard !line.hasPrefix(" "),!line.hasPrefix("\t"),let colon=line.firstIndex(of:":") else{throw reject(400,"Invalid header")}
            let name=String(line[..<colon]).lowercased(),value=line[line.index(after:colon)...].trimmingCharacters(in:.whitespaces)
            guard !name.isEmpty,request.headers[name]==nil else{throw reject(400,"Duplicate header")}
            request.headers[name]=value
        }
        guard request.headers["host"]==host,request.headers["transfer-encoding"]==nil else{throw reject(400,"Invalid framing")}
        if let other=request.headers["origin"],other != origin {throw reject(403,"Foreign origin")}
        if let site=request.headers["sec-fetch-site"],!["same-origin","none"].contains(site) {throw reject(403,"Foreign site")}
        let lengthText=request.headers["content-length"] ?? "0"
        guard !lengthText.isEmpty,lengthText.utf8.allSatisfy({(48...57).contains($0)}),let length=Int(lengthText) else{throw reject(400,"Invalid length")}
        let limit:Int
        if request.method=="PUT",request.route=="storage-index" {limit=Self.mib}
        else if request.method=="PUT",request.route.hasPrefix("storage/") {limit=64*Self.mib}
        else if request.method=="PUT",(["auto","quick","before-load"] + NativeSaveStore.manualSlots).map({"state/"+$0}).contains(request.route) {limit=128*Self.mib}
        else {limit=0}
        guard length<=limit else{throw reject(413,"Body too large")}
        guard request.method != "PUT" || request.headers["content-length"] != nil else{throw reject(411,"Length required")}
        request.expected=length
    }
    private func respond(_ request:Request)throws {
        let read=request.method=="GET" || request.method=="HEAD"
        switch request.route {
        case "":guard read else{throw reject(405,"Read only")};send(request,body:html,type:"text/html; charset=utf-8")
        case "Play.js","Play.wasm":
            guard read else{throw reject(405,"Read only")}
            let url=assets.appendingPathComponent(request.route);try regularFile(url,max:32*Self.mib)
            send(request,body:try Data(contentsOf:url),type:request.route.hasSuffix("wasm") ? "application/wasm":"text/javascript")
        case "disc":
            guard read else{throw reject(405,"Read only")}
            guard let range=request.headers["range"],range.hasPrefix("bytes=") else{throw reject(416,"Range required")}
            let pair=range.dropFirst(6).split(separator:"-",omittingEmptySubsequences:false)
            guard pair.count==2,let lower=UInt64(pair[0]),let upper=UInt64(pair[1]),lower<=upper,upper<discSize,upper-lower<UInt64(Self.mib) else{throw reject(416,"Invalid range")}
            guard let discReader else{throw reject(500,"Disc unavailable")}
            let bytes=try discReader.read(offset:lower,length:Int(upper-lower+1))
            guard bytes.count==Int(upper-lower+1) else{throw reject(500,"Short disc read")}
            send(request,code:206,body:bytes,extra:"Accept-Ranges: bytes\r\nContent-Range: bytes \(lower)-\(upper)/\(discSize)\r\n")
        case "storage-begin":
            guard request.method=="PUT",request.body.isEmpty else{throw reject(405,"Transaction requires an empty PUT")}
            try beginStorageTransaction();send(request,code:204,body:Data())
        case "storage-index":
            if read {send(request,body:try encodeJSON(activeStorageEntries()),type:"application/json")}
            else {try commitStorageIndex(request.body);send(request,code:204,body:Data())}
        case "state-index":
            guard read else{throw reject(405,"Read only")}
            var index:[String:Any]=[:],recovered:[String]=[]
            for slot in ["auto","quick"] {
                if try recoverStateIfNeeded(slot) {recovered.append(slot)}
                let exists=FileManager.default.fileExists(atPath:try stateURL(slot).path)
                if exists {_ = try readState(slot,includePayload:false)}
                index[slot]=exists
            }
            index["recovered"]=recovered
            send(request,body:try JSONSerialization.data(withJSONObject:index,options:.sortedKeys),type:"application/json")
        default:
            if request.route.hasPrefix("storage/") {
                let relative=try decodeRelative(String(request.route.dropFirst(8)))
                let root=try read ? require(filesRoot):pendingStorageRoot()
                let url=try child(relative,root:root,createParents:request.method=="PUT")
                if read {try regularFile(url,max:64*Self.mib);send(request,body:try Data(contentsOf:url))}
                else {
                    let current=FileManager.default.fileExists(atPath:url.path) ? (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0):0
                    guard try physicalStorageSize(require(filesRoot))+physicalStorageSize(root)-current+request.body.count<=128*Self.mib else{throw reject(413,"Storage transaction quota exceeded")}
                    try atomicWrite(request.body,to:url,quotaRoot:root);send(request,code:204,body:Data())
                }
            }else if request.route.hasPrefix("state/") {
                let slot=String(request.route.dropFirst(6));guard (["auto","quick","before-load"] + NativeSaveStore.manualSlots).contains(slot) else{throw reject(404,"Unknown slot")}
                if NativeSaveStore.manualSlots.contains(slot) {
                    if read {
                        let zip = try StateFile.decode(manualSaveStore.read(slot), rom: gameID, core: stateFormat)
                        guard zip.starts(with: [0x50,0x4b,0x03,0x04]) else { throw reject(409,"Invalid manual state") }
                        send(request, body: zip, type: "application/zip")
                    } else {
                        defer { manualPreview = nil }
                        guard request.body.count >= 4, request.body.starts(with: [0x50,0x4b,0x03,0x04]) else { throw reject(400,"Expected ZIP state") }
                        let preview = manualPreview?.slot == slot ? manualPreview?.data : nil
                        guard preview != nil else { throw reject(409,"Manual save requires a fresh preview") }
                        try manualSaveStore.write(StateFile.encode(request.body, rom: gameID, core: stateFormat, thumbnail: preview), slot: slot)
                        send(request, code: 204, body: Data())
                    }
                } else if read {send(request,body:try readState(slot,includePayload:true),type:"application/zip")}
                else {try writeState(request.body,slot:slot);send(request,code:204,body:Data())}
            }else {throw reject(404,"Not found")}
        }
    }
    private func send(_ request:Request,code:Int=200,body:Data,type:String="application/octet-stream",extra:String="") {
        guard !request.finished else{return};request.finished=true
        bufferedBytes-=request.body.count;request.body.removeAll()
        let reasons=[200:"OK",204:"No Content",206:"Partial Content",400:"Bad Request",403:"Forbidden",404:"Not Found",405:"Method Not Allowed",408:"Request Timeout",409:"Conflict",411:"Length Required",413:"Content Too Large",416:"Range Not Satisfiable",431:"Request Header Fields Too Large",500:"Internal Server Error"]
        let header="HTTP/1.1 \(code) \(reasons[code] ?? "Error")\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCross-Origin-Opener-Policy: same-origin\r\nCross-Origin-Embedder-Policy: require-corp\r\nCross-Origin-Resource-Policy: same-origin\r\nX-Content-Type-Options: nosniff\r\nCache-Control: no-store\r\nConnection: close\r\n\(extra)\r\n"
        request.connection.send(content:Data(header.utf8)+(request.method=="HEAD" ? Data():body),completion:.contentProcessed{[weak self,weak request] _ in
            guard let request else{return};request.connection.cancel();self?.requests.removeValue(forKey:ObjectIdentifier(request))
        })
    }

    private func prepareStorage()throws {
        guard !prefix.isEmpty,!gameID.isEmpty,gameID.count<256,!stateFormat.isEmpty,stateFormat.count<128 else{throw failure("Invalid state identity or nonce")}
        let info=try disc.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard info.isRegularFile==true,info.isSymbolicLink != true,let size=info.fileSize,size>0 else{throw failure("Game file unavailable")}
        let reader=try PS2DiscReader(url:disc)
        discReader=reader;discSize=reader.logicalSize
        try directory(storage)
        let canonical=storage.resolvingSymlinksInPath().standardizedFileURL
        filesRoot=canonical.appendingPathComponent("files",isDirectory:true);statesRoot=canonical.appendingPathComponent("states",isDirectory:true)
        try directory(require(filesRoot));try directory(require(statesRoot))
        try directory(manualSaveStore.directory)
        try recoverStorageTransaction()
    }
    private func require(_ url:URL?)throws->URL {guard let url else{throw failure("Storage unavailable")};return url}
    private func directory(_ url:URL)throws {
        let fm=FileManager.default
        if fm.fileExists(atPath:url.path) {
            let info=try url.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]);guard info.isDirectory==true,info.isSymbolicLink != true else{throw reject(403,"Invalid directory")}
        }else {try fm.createDirectory(at:url,withIntermediateDirectories:true)}
    }
    private func decodeRelative(_ encoded:String)throws->String {
        guard let value=encoded.removingPercentEncoding else{throw reject(403,"Invalid path")}
        return try validateRelative(value)
    }
    private func validateRelative(_ value:String)throws->String {
        guard !value.isEmpty,value.utf8.count<=1024,!value.contains("\\"),
              !value.unicodeScalars.contains(where:{$0.value<32 || $0.value==127}) else{throw reject(403,"Invalid path")}
        guard value.hasPrefix("vfs/mc0/") || value.hasPrefix("vfs/mc1/") else{throw reject(403,"Only memory-card paths are writable")}
        let parts=value.split(separator:"/",omittingEmptySubsequences:false)
        guard parts.count<=16,parts.allSatisfy({!$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count<=255 && !$0.hasPrefix(".veta-")}) else{throw reject(403,"Invalid path")}
        return value
    }
    private func child(_ relative:String,root:URL,createParents:Bool)throws->URL {
        let parts=relative.split(separator:"/");var current=root
        for (index,part) in parts.enumerated() {
            current.appendPathComponent(String(part));let exists=FileManager.default.fileExists(atPath:current.path)
            if exists {
                let info=try current.resourceValues(forKeys:[.isSymbolicLinkKey,.isDirectoryKey])
                guard info.isSymbolicLink != true else{throw reject(403,"Symbolic link rejected")}
                if index<parts.count-1,info.isDirectory != true {throw reject(403,"Invalid directory")}
            }else if index<parts.count-1,createParents {try directory(current)}
            // Also catch dangling symlinks, which fileExists follows.
            if (try? FileManager.default.destinationOfSymbolicLink(atPath:current.path)) != nil {throw reject(403,"Symbolic link rejected")}
        }
        guard current.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path+"/") else{throw reject(403,"Path escape")}
        return current
    }
    private func regularFile(_ url:URL,max:Int)throws {
        guard FileManager.default.fileExists(atPath:url.path) else{throw reject(404,"Missing file")}
        let info=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard info.isRegularFile==true,info.isSymbolicLink != true,let count=info.fileSize,count<=max else{throw reject(403,"Invalid file")}
    }
    private func storageEntries(root selectedRoot:URL?=nil)throws->[[String:Any]] {
        let root=try selectedRoot ?? require(filesRoot),fm=FileManager.default
        var traversalError:Error?
        guard let iterator=fm.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey,.isDirectoryKey,.isSymbolicLinkKey,.fileSizeKey],options:[],errorHandler:{_,error in traversalError=error;return false}) else{throw failure("Cannot enumerate storage")}
        var entries:[[String:Any]]=[],visited=0
        for case let url as URL in iterator {
            visited+=1;guard visited<=8192 else{throw reject(413,"Too many storage entries")}
            let info=try url.resourceValues(forKeys:[.isRegularFileKey,.isDirectoryKey,.isSymbolicLinkKey,.fileSizeKey])
            guard info.isSymbolicLink != true else{throw reject(403,"Symbolic link rejected")}
            if url.lastPathComponent.hasPrefix(".veta-") {iterator.skipDescendants();continue}
            if info.isDirectory==true {continue}
            guard info.isRegularFile==true,let size=info.fileSize,size<=64*Self.mib else{throw reject(403,"Invalid storage entry")}
            // Foundation may enumerate /var while the canonical root is
            // /private/var. Compare canonical paths after rejecting symlinks.
            let canonicalPath=url.resolvingSymlinksInPath().standardizedFileURL.path
            guard canonicalPath.hasPrefix(root.path+"/") else{throw reject(403,"Storage path escape")}
            let relative=String(canonicalPath.dropFirst(root.path.count+1))
            _ = try validateRelative(relative)
            entries.append(["path":relative,"size":size])
        }
        if let traversalError {throw traversalError}
        return entries.sorted{($0["path"] as! String)<($1["path"] as! String)}
    }
    private struct StorageEntry:Codable {let path:String,size:Int}
    private struct StorageIndex:Codable {let files:[StorageEntry];var generation:String?=nil}
    private func storageManifest(root:URL?=nil)throws->URL {try (root ?? require(filesRoot)).appendingPathComponent(".veta-manifest.json")}
    private func activeStorageEntries()throws->[StorageEntry] {
        let manifest=try storageManifest()
        if FileManager.default.fileExists(atPath:manifest.path) {
            try regularFile(manifest,max:Self.mib)
            let index=try JSONDecoder().decode(StorageIndex.self,from:Data(contentsOf:manifest))
            try validateStorageIndex(index)
            return index.files.sorted{$0.path<$1.path}
        }
        return try storageEntries().map{StorageEntry(path:$0["path"] as! String,size:$0["size"] as! Int)}
    }
    private func validateStorageIndex(_ index:StorageIndex,root selectedRoot:URL?=nil)throws {
        let root=try selectedRoot ?? require(filesRoot)
        guard index.files.count<=4096 else{throw reject(413,"Too many memory-card files")}
        var paths=Set<String>(),total=0
        for entry in index.files {
            let path=try validateRelative(entry.path)
            guard paths.insert(path).inserted,entry.size>=0,entry.size<=64*Self.mib else{throw reject(400,"Invalid storage manifest")}
            total+=entry.size;guard total<=128*Self.mib else{throw reject(413,"Storage quota exceeded")}
            let url=try child(path,root:root,createParents:false)
            try regularFile(url,max:64*Self.mib)
            guard try url.resourceValues(forKeys:[.fileSizeKey]).fileSize==entry.size else{throw reject(409,"Memory-card file size mismatch")}
        }
    }
    private func commitStorageIndex(_ data:Data)throws {
        let root=try pendingStorageRoot()
        guard let index=try? JSONDecoder().decode(StorageIndex.self,from:data) else{throw reject(400,"Invalid storage manifest")}
        try validateStorageIndex(index,root:root)
        let stored=try storageEntries(root:root)
        guard Set(stored.compactMap{$0["path"] as? String})==Set(index.files.map(\.path)) else{throw reject(409,"Transaction must contain exactly its complete index")}
        let sorted=StorageIndex(files:index.files.sorted{$0.path<$1.path},generation:storageTransaction)
        try atomicWrite(encodeJSON(sorted),to:storageManifest(root:root),quotaRoot:root)
        guard try physicalStorageSize(require(filesRoot))+physicalStorageSize(root)<=128*Self.mib else{throw reject(413,"Storage transaction quota exceeded")}
        // A single filesystem swap publishes all files and their index together.
        // Unsupported filesystems fail here, leaving the published generation intact.
        guard Darwin.renameatx_np(AT_FDCWD,root.path,AT_FDCWD,try require(filesRoot).path,UInt32(RENAME_SWAP))==0 else{throw failure("Atomic memory-card publication failed")}
        try recoverStorageTransaction()
    }
    private struct CardTransaction:Codable {let version:Int;let generation:String}
    private func transactionURL(_ name:String)throws->URL {try child(name,root:require(filesRoot).deletingLastPathComponent(),createParents:false)}
    private func pendingStorageRoot()throws->URL {
        guard storageTransaction != nil else{throw reject(409,"Begin a memory-card transaction first")}
        let root=try transactionURL(".veta-cards-pending")
        let info=try root.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
        guard info.isDirectory==true,info.isSymbolicLink != true else{throw reject(409,"Memory-card transaction unavailable")}
        return root
    }
    private func beginStorageTransaction()throws {
        try recoverStorageTransaction()
        // Validate the published generation before beginning its replacement.
        _ = try activeStorageEntries()
        let pending=try transactionURL(".veta-cards-pending"),journal=try transactionURL(".veta-cards-transaction.json"),fm=FileManager.default
        guard !fm.fileExists(atPath:pending.path) else{throw reject(409,"Uncommitted memory-card storage requires recovery")}
        let transaction=CardTransaction(version:1,generation:UUID().uuidString)
        try encodeJSON(transaction).write(to:journal,options:.withoutOverwriting)
        do {try fm.createDirectory(at:pending,withIntermediateDirectories:false);storageTransaction=transaction.generation}
        catch {try? fm.removeItem(at:journal);throw error}
    }
    private func recoverStorageTransaction()throws {
        guard filesRoot != nil else{return}
        let pending=try transactionURL(".veta-cards-pending"),journal=try transactionURL(".veta-cards-transaction.json"),fm=FileManager.default
        guard fm.fileExists(atPath:journal.path) else{storageTransaction=nil;return}
        try regularFile(journal,max:4096)
        let transaction=try JSONDecoder().decode(CardTransaction.self,from:Data(contentsOf:journal))
        guard transaction.version==1,UUID(uuidString:transaction.generation) != nil else{throw reject(409,"Invalid memory-card transaction")}
        let manifest=try storageManifest()
        var published:String?
        if fm.fileExists(atPath:manifest.path) {
            try regularFile(manifest,max:Self.mib)
            published=try JSONDecoder().decode(StorageIndex.self,from:Data(contentsOf:manifest)).generation
        }
        if fm.fileExists(atPath:pending.path) {
            let info=try pending.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
            guard info.isDirectory==true,info.isSymbolicLink != true else{throw reject(403,"Invalid transaction directory")}
            if published==transaction.generation {
                // Swap has completed: pending now holds the previous complete
                // generation. A crash during this cleanup remains recoverable.
                _ = try activeStorageEntries()
                let previous=try transactionURL("files.previous")
                if fm.fileExists(atPath:previous.path) {
                    let info=try previous.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
                    guard info.isDirectory==true,info.isSymbolicLink != true else{throw reject(403,"Invalid previous generation")}
                    try fm.removeItem(at:previous)
                }
                try fm.moveItem(at:pending,to:previous)
            }else {
                // No publication occurred. Only uncommitted private staging is
                // discarded; published bytes and their previous copy survive.
                try fm.removeItem(at:pending)
            }
        }
        try fm.removeItem(at:journal);storageTransaction=nil
    }
    private func encodeJSON<T:Encodable>(_ value:T)throws->Data {
        let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys;return try encoder.encode(value)
    }
    private func checksum(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    private func fileChecksum(_ url:URL)throws->String {
        let handle=try FileHandle(forReadingFrom:url);defer{try? handle.close()};var hash=SHA256()
        while let bytes=try handle.read(upToCount:Self.mib),!bytes.isEmpty {hash.update(data:bytes)}
        return hash.finalize().map{String(format:"%02x",$0)}.joined()
    }
    private func rename(_ source:URL,to destination:URL)throws {
        guard Darwin.rename(source.path,destination.path)==0 else{throw failure("Atomic replacement failed")}
    }
    private func previousFile(for destination:URL)->URL {
        destination.deletingLastPathComponent().appendingPathComponent(".veta-previous-"+checksum(Data(destination.lastPathComponent.utf8)))
    }
    private func physicalStorageSize(_ root:URL)throws->Int {
        let fm=FileManager.default
        var traversalError:Error?
        guard let iterator=fm.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey,.isDirectoryKey,.isSymbolicLinkKey,.fileSizeKey],options:[],errorHandler:{_,error in traversalError=error;return false}) else{throw failure("Cannot account for storage")}
        var total=0,count=0
        for case let url as URL in iterator {
            count+=1;guard count<=16384 else{throw reject(413,"Too many retained storage files")}
            let info=try url.resourceValues(forKeys:[.isRegularFileKey,.isDirectoryKey,.isSymbolicLinkKey,.fileSizeKey])
            guard info.isSymbolicLink != true else{throw reject(403,"Symbolic link rejected")}
            if info.isDirectory==true {continue}
            guard info.isRegularFile==true,let size=info.fileSize,size>=0,size<=64*Self.mib else{throw reject(413,"Invalid retained file size")}
            total+=size
        }
        if let traversalError {throw traversalError}
        return total
    }
    private func checkPhysicalStorageQuota(_ bytes:Int,to destination:URL,preservePrevious:Bool,root:URL)throws {
        let fm=FileManager.default
        var total=try physicalStorageSize(root)
        if fm.fileExists(atPath:destination.path) {
            if preservePrevious {
                // Current bytes remain as the new previous copy; only the old
                // previous copy leaves the persistent budget.
                let previous=previousFile(for:destination)
                if fm.fileExists(atPath:previous.path) {total-=try previous.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0}
            }else {total-=try destination.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0}
        }
        guard total+bytes<=128*Self.mib else{throw reject(413,"Retained memory-card storage quota exceeded")}
    }
    private func atomicWrite(_ data:Data,to destination:URL,preservePrevious:Bool=false,quotaRoot:URL?=nil)throws {
        try checkPhysicalStorageQuota(data.count,to:destination,preservePrevious:preservePrevious,root:quotaRoot ?? require(filesRoot))
        let temp=destination.deletingLastPathComponent().appendingPathComponent(".veta-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:temp)}
        try data.write(to:temp,options:.withoutOverwriting)
        guard try fileChecksum(temp)==checksum(data) else{throw failure("Write verification failed")}
        if preservePrevious,FileManager.default.fileExists(atPath:destination.path) {
            try regularFile(destination,max:64*Self.mib)
            let previousTemp=destination.deletingLastPathComponent().appendingPathComponent(".veta-"+UUID().uuidString)
            defer{try? FileManager.default.removeItem(at:previousTemp)}
            try FileManager.default.copyItem(at:destination,to:previousTemp)
            guard try fileChecksum(previousTemp)==fileChecksum(destination) else{throw failure("Previous file verification failed")}
            let previous=previousFile(for:destination)
            if (try? FileManager.default.destinationOfSymbolicLink(atPath:previous.path)) != nil {throw reject(403,"Symbolic link rejected")}
            try rename(previousTemp,to:previous)
        }
        try rename(temp,to:destination)
    }

    private struct StateMetadata:Codable {let version:Int,gameID:String,format:String,sha256:String,bytes:Int,createdAt:Date}
    private let stateMagic=Data("VETAPSW1".utf8)
    private func stateURL(_ slot:String)throws->URL {try child(slot+".state",root:require(statesRoot),createParents:false)}
    private func recoverStateIfNeeded(_ slot:String)throws->Bool {
        let current=try stateURL(slot),previous=try stateURL(slot+".previous"),fm=FileManager.default
        let exists=fm.fileExists(atPath:current.path),hasPrevious=fm.fileExists(atPath:previous.path)
        guard exists || hasPrevious else{return false}
        if exists,(try? readState(slot,includePayload:false)) != nil {return false}
        guard hasPrevious,(try? readState(slot+".previous",includePayload:false)) != nil else {
            throw reject(409,"Saved state is invalid and no valid previous copy is available")
        }
        let temporary=try child(".veta-"+UUID().uuidString,root:require(statesRoot),createParents:false)
        defer{try? fm.removeItem(at:temporary)}
        try fm.copyItem(at:previous,to:temporary)
        guard try fileChecksum(temporary)==fileChecksum(previous) else{throw failure("State recovery verification failed")}
        try rename(temporary,to:current)
        return true
    }
    private func readState(_ slot:String,includePayload:Bool)throws->Data {
        let url=try stateURL(slot);try regularFile(url,max:128*Self.mib+4096+12)
        let file=try FileHandle(forReadingFrom:url);defer{try? file.close()}
        let head=try file.read(upToCount:12) ?? Data()
        guard head.count==12,head.prefix(8)==stateMagic else{throw reject(409,"Invalid state envelope")}
        let length=head.suffix(4).reduce(0){($0<<8)|Int($1)}
        guard length>0,length<=4096,let json=try file.read(upToCount:length),json.count==length,
              let meta=try? JSONDecoder().decode(StateMetadata.self,from:json),meta.version==1,meta.gameID==gameID,meta.format==stateFormat,meta.bytes>0,meta.bytes<=128*Self.mib else{throw reject(409,"State identity mismatch")}
        var hash=SHA256(),count=0,result=Data()
        if includePayload {result.reserveCapacity(meta.bytes)}
        while let bytes=try file.read(upToCount:Self.mib),!bytes.isEmpty {
            count+=bytes.count;guard count<=meta.bytes else{throw reject(409,"Invalid state size")};hash.update(data:bytes)
            if includePayload {result.append(bytes)}
        }
        guard count==meta.bytes,hash.finalize().map({String(format:"%02x",$0)}).joined()==meta.sha256 else{throw reject(409,"State hash mismatch")}
        return result
    }
    private func writeState(_ zip:Data,slot:String)throws {
        guard zip.count>=4,zip.count<=128*Self.mib,zip.starts(with:[0x50,0x4b,0x03,0x04]) else{throw reject(400,"Expected ZIP state")}
        let destination=try stateURL(slot),root=destination.deletingLastPathComponent(),fm=FileManager.default
        let metadata=StateMetadata(version:1,gameID:gameID,format:stateFormat,sha256:checksum(zip),bytes:zip.count,createdAt:Date())
        let json=try JSONEncoder().encode(metadata);guard json.count<=4096 else{throw failure("State metadata too large")}
        var envelope=stateMagic;let count=UInt32(json.count)
        envelope.append(contentsOf:[UInt8((count>>24)&255),UInt8((count>>16)&255),UInt8((count>>8)&255),UInt8(count&255)]);envelope.append(json)
        let temp=root.appendingPathComponent(".veta-"+UUID().uuidString),previousTemp=root.appendingPathComponent(".veta-"+UUID().uuidString)
        defer{try? fm.removeItem(at:temp);try? fm.removeItem(at:previousTemp)}
        try envelope.write(to:temp,options:.withoutOverwriting)
        let handle=try FileHandle(forWritingTo:temp)
        do {try handle.seekToEnd();try handle.write(contentsOf:zip);try handle.synchronize();try handle.close()}catch{try? handle.close();throw error}
        // Verify exactly the bytes written before publishing either slot.
        var expected=SHA256();expected.update(data:envelope);expected.update(data:zip)
        guard try fileChecksum(temp)==expected.finalize().map({String(format:"%02x",$0)}).joined() else{throw failure("State write verification failed")}
        if fm.fileExists(atPath:destination.path),(try? readState(slot,includePayload:false)) != nil {
            // A corrupt current must never replace a valid recovery copy.
            try regularFile(destination,max:128*Self.mib+4096+12)
            try fm.copyItem(at:destination,to:previousTemp)
            guard try fileChecksum(previousTemp)==fileChecksum(destination) else{throw failure("Previous state verification failed")}
            let previous=try child(slot+".previous.state",root:root,createParents:false)
            try rename(previousTemp,to:previous)
        }
        try rename(temp,to:destination)
    }
}
