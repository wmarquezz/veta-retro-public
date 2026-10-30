import Foundation
import CryptoKit

// Descriptors can only reference sibling files. WAV tracks are normalized to
// raw CD audio on import so both embedded disc engines receive BINARY tracks.
enum DiscFiles {
    static let expression=try! NSRegularExpression(pattern:#"(?im)^[\t ]*FILE[\t ]+(?:"([^"]+)"|([^\s]+))[\t ]+(BINARY|WAVE|WAV)[\t ]*\r?$"#)
    static func text(_ cue:Data)throws->String {
        guard cue.count<=1024*1024,let text=String(data:cue,encoding:.utf8) ?? String(data:cue,encoding:.isoLatin1) else{throw VetaError.message("El descriptor CUE no es válido.")}
        return text
    }
    static func names(in cue:Data)throws->[String] {
        let text=try text(cue),ns=text as NSString
        let names=expression.matches(in:text,range:NSRange(location:0,length:ns.length)).map {match in ns.substring(with:match.range(at:match.range(at:1).location == NSNotFound ? 2:1))}
        let fileLines=text.components(separatedBy:.newlines).filter {line in
            line.trimmingCharacters(in:.whitespaces).split(whereSeparator:{$0.isWhitespace}).first?.uppercased()=="FILE"
        }
        let unique=Set(names)
        guard !names.isEmpty,names.count<=99,names.count==fileLines.count,unique.count==Set(unique.map{$0.lowercased()}).count,names.allSatisfy({safeName($0) && ["bin","iso","wav"].contains(($0 as NSString).pathExtension.lowercased())}) else{throw VetaError.message("El CUE debe usar pistas BIN, ISO o WAV de la misma carpeta, sin rutas ni archivos comprimidos.")}
        return unique.sorted()
    }
    static func safeName(_ name:String)->Bool { !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && !name.contains(":" ) && !name.contains("\0") }
    static func digest(_ urls:[URL])throws->String {
        var hash=SHA256()
        for url in urls {
            let size=try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey])
            guard size.isRegularFile==true,size.isSymbolicLink != true,let count=size.fileSize,count>0,count<=2*1024*1024*1024 else{throw VetaError.message("Pista de disco inválida o mayor de 2 GB.")}
            var framed=UInt64(count).bigEndian;withUnsafeBytes(of:&framed){hash.update(data:Data($0))}
            let file=try FileHandle(forReadingFrom:url);defer{try? file.close()}
            while let chunk=try file.read(upToCount:1024*1024),!chunk.isEmpty {hash.update(data:chunk)}
        }
        return hash.finalize().map{String(format:"%02x",$0)}.joined()
    }
    static func normalize(_ cue:Data,sources:[String:URL],into folder:URL)throws->Data {
        let text=try text(cue),ns=text as NSString,result=NSMutableString(string:text)
        let matches=expression.matches(in:text,range:NSRange(location:0,length:ns.length))
        var converted:[String:String]=[:],used=Set(sources.keys.map{$0.lowercased()})
        for match in matches.reversed() {
            let name=ns.substring(with:match.range(at:match.range(at:1).location == NSNotFound ? 2:1))
            let format=ns.substring(with:match.range(at:3)).uppercased()
            guard let source=sources[name] else{throw VetaError.message("Falta la pista \(name).")}
            if format == "BINARY" {
                let destination=folder.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath:destination.path) {try FileManager.default.copyItem(at:source,to:destination)}
            } else {
                let destinationName:String
                if let previous=converted[name] {destinationName=previous}
                else {
                    var index=converted.count+1
                    while used.contains("veta-audio-\(index).bin") {index += 1}
                    destinationName="veta-audio-\(index).bin";used.insert(destinationName)
                    try waveToBinary(source,destination:folder.appendingPathComponent(destinationName))
                    converted[name]=destinationName
                }
                result.replaceCharacters(in:match.range,with:"FILE \"\(destinationName)\" BINARY")
            }
        }
        return converted.isEmpty ? cue:Data((result as String).utf8)
    }
    static func waveToBinary(_ source:URL,destination:URL)throws {
        let invalid=VetaError.message("La pista WAV debe ser PCM estéreo de 16 bits y 44.100 Hz, sin comprimir.")
        let info=try source.resourceValues(forKeys:[.fileSizeKey,.isSymbolicLinkKey,.isRegularFileKey])
        guard info.isRegularFile==true,info.isSymbolicLink != true,let size=info.fileSize,size>=44,size<=2*1024*1024*1024 else{throw invalid}
        let input=try FileHandle(forReadingFrom:source);defer{try? input.close()}
        func read(_ count:Int)throws->Data {let bytes=try input.read(upToCount:count) ?? Data();guard bytes.count==count else{throw invalid};return bytes}
        func word(_ data:Data,_ i:Int)->Int {Int(data[i]) | Int(data[i+1])<<8}
        func long(_ data:Data,_ i:Int)->Int {word(data,i) | word(data,i+2)<<16}
        let header=try read(12)
        guard header.prefix(4)==Data("RIFF".utf8),header.suffix(4)==Data("WAVE".utf8),long(header,4)+8<=size else{throw invalid}
        let end=long(header,4)+8
        var position=12,validFormat=false,audio:(offset:Int,count:Int)?
        while position+8<=end {
            try input.seek(toOffset:UInt64(position));let chunk=try read(8),count=long(chunk,4)
            guard count<=end-position-8 else{throw invalid}
            if chunk.prefix(4)==Data("fmt ".utf8) {
                guard count>=16 else{throw invalid};let f=try read(16)
                validFormat=word(f,0)==1 && word(f,2)==2 && long(f,4)==44100 && long(f,8)==176400 && word(f,12)==4 && word(f,14)==16
            } else if chunk.prefix(4)==Data("data".utf8) {guard audio==nil else{throw invalid};audio=(position+8,count)}
            position += 8+count+(count%2)
        }
        guard validFormat,let audio,audio.count>0,audio.count%4==0 else{throw invalid}
        guard FileManager.default.createFile(atPath:destination.path,contents:nil) else{throw VetaError.message("No se pudo preparar la pista de audio.")}
        let output=try FileHandle(forWritingTo:destination);defer{try? output.close()}
        try input.seek(toOffset:UInt64(audio.offset));var remaining=audio.count
        while remaining>0 {let data=try read(min(remaining,1024*1024));try output.write(contentsOf:data);remaining -= data.count}
        // CD-DA sectors contain 588 stereo sample frames (2352 bytes).
        let padding=(2352-audio.count%2352)%2352
        if padding>0 {try output.write(contentsOf:Data(repeating:0,count:padding))}
    }
}
extension Library {
    @discardableResult func importURLs(_ selections:[URL],console preferred:GameConsole?,artwork:ArtworkStore? = nil)throws -> LocalCoverImport.Summary {
        let scoped=selections.filter{$0.startAccessingSecurityScopedResource()};defer{scoped.forEach{$0.stopAccessingSecurityScopedResource()}}
        if let preferred, !GameConsole.allCases.contains(preferred) {throw VetaError.message("Consola desconocida.")}
        #if VETA_JIT_DEVELOPMENT
        if let console=preferred,console.isStandaloneEngine {for url in selections {_ = try importExperimental(url,console:console)};return .init(games:selections.count)}
        #endif
        let originalFiles=try LocalCoverImport.files(selections)
        let expanded=try ZIPGameImport.expand(originalFiles);defer{expanded.remove()}
        let files=expanded.files,covers=LocalCoverImport.Session(files:files+originalFiles)
        let urls=files.filter{!LocalCoverImport.isImage($0)}
        var processed=0
        var consumed=Set<URL>()
        for cue in urls where cue.pathExtension.lowercased()=="cue" {
            guard (try cue.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max)<=1024*1024 else{throw VetaError.message("El descriptor CUE es demasiado grande.")}
            let cueBytes=try Data(contentsOf:cue),names=try DiscFiles.names(in:cueBytes)
            var sources:[String:URL]=[:]
            for name in names {
                let matches=urls.filter{LocalCoverImport.parent($0)==LocalCoverImport.parent(cue) && $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame}
                guard matches.count<=1 else{throw VetaError.message("Hay varias pistas llamadas \(name). Importa un disco a la vez.")}
                let track=matches.first ?? cue.deletingLastPathComponent().appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath:track.path) else{throw VetaError.message("Falta \(name). Selecciona el CUE junto con todas sus pistas BIN o WAV.")}
                sources[name]=track
            }
            var console:GameConsole=preferred == .saturn ? .saturn:.ps1
            if preferred != .saturn && preferred != .ps1 {
                for source in sources.values where source.pathExtension.lowercased() != "wav" {
                    let input=try FileHandle(forReadingFrom:source);defer{try? input.close()}
                    let header=try input.read(upToCount:32) ?? Data()
                    if [0,16].contains(where:{header.dropFirst($0).starts(with:Data("SEGA SEGASATURN".utf8))}) {console = .saturn;break}
                }
            }
            // Check sizes and symbolic links before copying or converting files.
            _ = try DiscFiles.digest([cue]+names.compactMap{sources[$0]})
            let staging=root.appendingPathComponent(".import-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at:staging,withIntermediateDirectories:true)
            defer{try? FileManager.default.removeItem(at:staging)}
            let normalized=try DiscFiles.normalize(cueBytes,sources:sources,into:staging)
            let descriptor=staging.appendingPathComponent("disc.cue");try normalized.write(to:descriptor)
            let id=try DiscFiles.digest([descriptor]+DiscFiles.names(in:normalized).map{staging.appendingPathComponent($0)})
            if !games.contains(where:{$0.id==id}) {
                var game=Game(id:id,name:cue.deletingPathExtension().lastPathComponent,console:console);game.contentName="disc.cue"
                let destination=directory(id)
                guard !FileManager.default.fileExists(atPath:destination.path) else{throw VetaError.message("Ya existe una carpeta de este disco fuera del índice. Se conservó sin modificar.")}
                try FileManager.default.moveItem(at:staging,to:destination)
                games.append(game)
                do{try persist()}catch{games.removeAll{$0.id==id};try? FileManager.default.removeItem(at:destination);throw error}
            }
            if let game=games.first(where:{$0.id==id}) {processed+=1;if let artwork {covers.attach(to:game,from:cue,store:artwork);if let archive=expanded.origins[cue] {covers.attach(to:game,from:archive,store:artwork)}}}
            consumed.insert(cue);consumed.formUnion(sources.values)
        }
        for url in urls where !consumed.contains(url) {
            do {
                if let game=try importURL(url,console:preferred) {processed+=1;if let artwork {covers.attach(to:game,from:url,store:artwork);if let archive=expanded.origins[url] {covers.attach(to:game,from:archive,store:artwork)}}}
            } catch is CancellationError { throw CancellationError() }
            catch { throw ZIPGameImport.ArchiveError(name: (expanded.origins[url] ?? url).lastPathComponent, underlying: error) }
        }
        var summary=covers.summary;summary.games=processed;summary.backups=urls.filter{["vetanes","vetaretro"].contains($0.pathExtension.lowercased())}.count
        return summary
    }
}
