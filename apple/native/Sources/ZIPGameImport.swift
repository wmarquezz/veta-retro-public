import Foundation
import zlib

/// Bounded ZIP32/ZIP64 import. Streams stored/DEFLATE entries into private temporary folders.
/// Encrypted, split and nested archives are rejected; no external file is overwritten.
enum ZIPGameImport {
    static let supported = LocalCoverImport.gameExtensions.union(NativeGameFile.extensions).union(LocalCoverImport.imageExtensions).subtracting(["zip","vetanes","vetaretro"])
    /// Keep the failing archive visible when importing several games at once.
    struct ArchiveError: LocalizedError {
        let name: String
        let underlying: Error
        var errorDescription: String? { name + "\n" + underlying.localizedDescription }
    }
    static let limit = 32 * 1024 * 1024 * 1024
    struct Expansion {
        let files: [URL]
        let origins: [URL: URL]
        let directory: URL
        func importFiles() throws -> [URL] {
            var result=files
            // Index once: repeated path standardization for every game/image pair
            // accumulated gigabytes of temporary Foundation objects on large imports.
            let images=Dictionary(grouping:files.filter{LocalCoverImport.isImage($0)},by:LocalCoverImport.CoverKey.init)
            for (game,archive) in origins {
                let paired:URL? = try autoreleasepool {
                    if images[LocalCoverImport.CoverKey(game)] != nil { return nil }
                    guard let cover=images[LocalCoverImport.CoverKey(archive)]?.sorted(by:{$0.lastPathComponent<$1.lastPathComponent}).first else { return nil }
                    let target=game.deletingPathExtension().appendingPathExtension(cover.pathExtension)
                    try FileManager.default.copyItem(at:cover,to:target)
                    return target
                }
                if let paired { result.append(paired) }
            }
            return result
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
    static func expand(_ files: [URL], temporaryRoot: URL = FileManager.default.temporaryDirectory, checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> Expansion {
        let root = temporaryRoot.appendingPathComponent("VetaZIP-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            var result: [URL] = [], origins: [URL: URL] = [:], total = 0
            for file in files {
                guard file.pathExtension.lowercased() == "zip" else { result.append(file); continue }
                do {
                    let folder = root.appendingPathComponent(UUID().uuidString)
                    let extracted = try autoreleasepool { try extract(file, into: folder, total: &total, checkCancellation: checkCancellation) }
                    var tracks=Set<URL>()
                    for cue in extracted where cue.pathExtension.lowercased()=="cue" {
                        let names=try DiscFiles.names(in:Data(contentsOf:cue))
                        for name in names {if let match=extracted.first(where:{LocalCoverImport.parent($0)==LocalCoverImport.parent(cue) && $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame}) {tracks.insert(match)}}
                    }
                    let games = extracted.filter { !LocalCoverImport.isImage($0) && !tracks.contains($0) && $0.pathExtension.lowercased() != "wav" }
                    guard !games.isEmpty else { throw VetaError.message("El ZIP no contiene archivos de juego compatibles con esta versión de VETA.") }
                    result += extracted
                    // A single-game archive may use a different internal ROM filename.
                    // Its external cover belongs to that game, never to every game in a collection.
                    if games.count == 1 { origins[games[0]] = file }
                } catch is CancellationError { throw CancellationError() }
                catch { throw ArchiveError(name: file.lastPathComponent, underlying: error) }
            }
            return Expansion(files: result, origins: origins, directory: root)
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    static func extract(_ file: URL, into folder: URL, total: inout Int, checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> [URL] {
        let invalid = VetaError.message("El ZIP está dañado o usa un formato no compatible. Usa un ZIP normal, sin contraseña, o descomprímelo antes de importar.")
        let info = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, let size = info.fileSize, size >= 22, size <= 16*1024*1024*1024 else { throw invalid }
        let input = try FileHandle(forReadingFrom:file); defer { try? input.close() }
        func read(_ offset:Int,_ count:Int) throws -> Data {
            guard offset >= 0, count >= 0, offset <= size, count <= size-offset else { throw invalid }
            try input.seek(toOffset:UInt64(offset));let bytes=try input.read(upToCount:count) ?? Data()
            guard bytes.count == count else { throw invalid };return bytes
        }
        func u16(_ data:Data,_ i:Int)->Int {Int(data[i]) | Int(data[i+1]) << 8}
        func u32(_ data:Data,_ i:Int)->Int {u16(data,i) | u16(data,i+2) << 16}
        func u64(_ data:Data,_ i:Int)throws->Int {
            guard i >= 0,i+8 <= data.count else {throw invalid}
            let value=data.withUnsafeBytes{UInt64(littleEndian:$0.loadUnaligned(fromByteOffset:i,as:UInt64.self))}
            guard value <= UInt64(Int.max) else{throw invalid};return Int(value)
        }
        let tailStart=max(0,size-65557),tail=try read(tailStart,size-tailStart)
        guard let end = stride(from:tail.count-22,through:0,by:-1).first(where:{u32(tail,$0)==0x06054b50 && $0+22+u16(tail,$0+20)==tail.count}) else {throw invalid}
        guard u16(tail,end+4)==0,u16(tail,end+6)==0,u16(tail,end+8)==u16(tail,end+10) else{throw invalid}
        var count=u16(tail,end+10),centralSize=u32(tail,end+12),central=u32(tail,end+16),boundary=tailStart+end
        if count==65535 || centralSize==0xffffffff || central==0xffffffff {
            let locator=try read(boundary-20,20)
            guard u32(locator,0)==0x07064b50,u32(locator,4)==0,u32(locator,16)==1 else{throw invalid}
            let position=try u64(locator,8),record=try read(position,56)
            guard u32(record,0)==0x06064b50,try u64(record,4)>=44,u32(record,16)==0,u32(record,20)==0,try u64(record,24)==u64(record,32),position <= boundary-76 else{throw invalid}
            count=try u64(record,32);centralSize=try u64(record,40);central=try u64(record,48);boundary=position
        }
        guard count>0,count<=10_000,central>=0,central<=boundary,centralSize==boundary-central,centralSize<=16*1024*1024 else{throw invalid}
        var cursor=central,seen=Set<String>(),output:[URL]=[]
        for _ in 0..<count {
            try checkCancellation()
            guard cursor<=boundary-46 else{throw invalid}
            let header=try read(cursor,46)
            guard u32(header,0)==0x02014b50 else{throw invalid}
            let flags=u16(header,8),method=u16(header,10),crc=u32(header,16),nameCount=u16(header,28),extraCount=u16(header,30)
            var packed=u32(header,20),unpacked=u32(header,24),offset=u32(header,42),disk=u16(header,34)
            let next=cursor+46+nameCount+extraCount+u16(header,32)
            guard next<=boundary,flags & 0x2041==0,[0,8].contains(method) else{throw invalid}
            let nameBytes=try read(cursor+46,nameCount),extra=try read(cursor+46+nameCount,extraCount)
            if packed==0xffffffff || unpacked==0xffffffff || offset==0xffffffff || disk==65535 {
                var pos=0,found=false
                while pos+4<=extra.count {
                    let tag=u16(extra,pos),length=u16(extra,pos+2);pos+=4;guard length<=extra.count-pos else{throw invalid}
                    if tag==1 {
                        let block=extra.subdata(in:pos..<pos+length);var i=0
                        if unpacked==0xffffffff {unpacked=try u64(block,i);i+=8}
                        if packed==0xffffffff {packed=try u64(block,i);i+=8}
                        if offset==0xffffffff {offset=try u64(block,i);i+=8}
                        if disk==65535 {guard i+4<=block.count else{throw invalid};disk=u32(block,i)}
                        found=true;break
                    };pos+=length
                };guard found else{throw invalid}
            }
            guard disk==0,let name=String(data:nameBytes,encoding:.utf8) ?? (flags & 0x800==0 ? String(data:nameBytes,encoding:.isoLatin1):nil) else{throw invalid}
            let components=name.split(separator:"/",omittingEmptySubsequences:false),directory=name.hasSuffix("/")
            let parts=directory ? Array(components.dropLast()):components,mode=(u32(header,38)>>16)&0xf000
            guard !parts.isEmpty,parts.count<=20,parts.allSatisfy({!$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains(":") && !$0.contains("\0")}),mode==0 || mode==0x8000 || (directory && mode==0x4000),seen.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted else{throw invalid}
            guard offset>=0,offset<=central-30 else{throw invalid};let local=try read(offset,30)
            guard u32(local,0)==0x04034b50,u16(local,6)==flags,u16(local,8)==method,u16(local,26)==nameCount else{throw invalid}
            let start=offset+30+nameCount+u16(local,28)
            guard start<=central,packed<=central-start,try read(offset+30,nameCount)==nameBytes else{throw invalid}
            cursor=next
            if directory || parts.contains(where:{$0.hasPrefix(".") || $0=="__MACOSX"}) {continue}
            let ext=(name as NSString).pathExtension.lowercased()
            if ext=="zip" {throw VetaError.message("El ZIP contiene otro ZIP. Descomprímelo antes de importar.")}
            guard supported.contains(ext) else{continue}
            guard (ext != "cue" || unpacked<=1024*1024),(!LocalCoverImport.imageExtensions.contains(ext) || unpacked<=30*1024*1024) else{throw invalid}
            guard unpacked>0,unpacked<=16*1024*1024*1024,total<=limit-unpacked else{throw VetaError.message("El ZIP supera el límite de importación: 16 GB por archivo y 32 GB descomprimidos por selección.")}
            let available=try folder.deletingLastPathComponent().resourceValues(forKeys:[.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0
            guard Int64(available)>Int64(unpacked)*2+128*1024*1024 else{throw VetaError.message("No hay espacio suficiente para descomprimir e importar el ZIP.")}
            total+=unpacked
            let destination=folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
            guard FileManager.default.createFile(atPath:destination.path,contents:nil) else{throw invalid}
            let target=try FileHandle(forWritingTo:destination);defer{try? target.close()}
            var stream=z_stream(),position=start,remaining=packed,written=0,checksum:uLong=0,ended=false
            if method==8 {guard inflateInit2_(&stream,-MAX_WBITS,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size))==Z_OK else{throw invalid}}
            defer{if method==8 {inflateEnd(&stream)}}
            func save(_ bytes:Data)throws {
                guard bytes.count<=unpacked-written else{throw invalid};written+=bytes.count
                checksum=bytes.withUnsafeBytes{crc32(checksum,$0.bindMemory(to:Bytef.self).baseAddress,uInt(bytes.count))}
                try target.write(contentsOf:bytes)
            }
            while remaining>0 {
                try checkCancellation()
                let chunk=try read(position,min(65536,remaining));position+=chunk.count;remaining-=chunk.count
                if method==0 {try save(chunk);continue}
                try chunk.withUnsafeBytes{source in
                    stream.next_in=UnsafeMutablePointer(mutating:source.bindMemory(to:Bytef.self).baseAddress!);stream.avail_in=uInt(chunk.count)
                    repeat {
                        var decoded=Data(count:65536)
                        let before=stream.avail_in
                        let status=decoded.withUnsafeMutableBytes{buffer->Int32 in stream.next_out=buffer.bindMemory(to:Bytef.self).baseAddress!;stream.avail_out=65536;return inflate(&stream,Z_NO_FLUSH)}
                        let produced=65536-Int(stream.avail_out);decoded.count=produced;try save(decoded)
                        if status==Z_STREAM_END {guard remaining==0,stream.avail_in==0 else{throw invalid};ended=true;break}
                        if status==Z_BUF_ERROR && produced==0 && stream.avail_in==0 {break}
                        guard status==Z_OK,(produced>0 || stream.avail_in<before) else{throw invalid}
                    } while stream.avail_in>0 || stream.avail_out==0
                }
                if ended {break}
            }
            guard written==unpacked,checksum==uLong(crc),(method==0 || ended) else{throw invalid}
            output.append(destination)
        }
        guard cursor==boundary else{throw invalid};return output
    }
}
