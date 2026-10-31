import Foundation
import CryptoKit

// Large optical-disc images are validated and copied as streams, never loaded
// into a single Data allocation. Executables are guest console programs only.
enum NativeGameFile {
    static let consoles:Set<GameConsole> = [.n64,.psp,.dreamcast,.threeDS,.gamecube,.wii,.ps2]
    static func isStreamedContent(_ game:Game)->Bool {
        consoles.contains(game.console) || (game.console == .ps1 && game.contentName?.lowercased().hasSuffix(".pbp") == true)
    }
    static let extensions:Set<String> = ["z64","v64","n64","pbp","prx","cso","iso","gcm","rvz","wbfs","elf","dol","cdi","3dsx","3ds","cci","cxi","chd"]
    static func console(header:Data,ext:String,preferred:GameConsole?)throws->GameConsole {
        switch ext {
        case "z64","v64","n64":return .n64
        case "pbp":return preferred == .ps1 ? .ps1:.psp
        case "prx":return .psp
        case "cso":return preferred == .ps2 ? .ps2:.psp
        case "3dsx","3ds","cci","cxi":return .threeDS
        case "cdi":return .dreamcast
        case "gcm":return .gamecube
        case "wbfs":return .wii
        default:
            if let preferred,consoles.contains(preferred){return preferred}
            if header.count>=32 {
                if Array(header[28..<32])==[0xc2,0x33,0x9f,0x3d] {return .gamecube}
                if Array(header[24..<28])==[0x5d,0x1c,0x9e,0xa3] {return .wii}
            }
            throw VetaError.message("Selecciona primero la consola de este archivo en la biblioteca.")
        }
    }
    static func validate(header:Data,size:Int,ext:String,console:GameConsole)throws {
        let invalid=VetaError.message("El archivo no tiene una cabecera válida de \(console.name) o está incompleto.")
        guard size>=32,size<=8*1024*1024*1024 else{throw invalid}
        func prefix(_ text:String)->Bool {header.starts(with:Data(text.utf8))}
        func le(_ offset:Int)->UInt32 {guard offset+4<=header.count else{return 0};return (0..<4).reduce(UInt32(0)){$0 | UInt32(header[offset+$1])<<($1*8)}}
        func be(_ offset:Int)->UInt32 {guard offset+4<=header.count else{return 0};return (0..<4).reduce(UInt32(0)){($0<<8)|UInt32(header[offset+$1])}}
        if console == .n64 {
            guard size>=4096,size<=64*1024*1024,[[0x80,0x37,0x12,0x40],[0x37,0x80,0x40,0x12],[0x40,0x12,0x37,0x80]].contains(Array(header.prefix(4)).map{Int($0)}) else{throw invalid};return
        }
        if ext=="elf" || ext=="prx" {
            guard header.count>=52,prefix("\u{7f}ELF"),header[4]==1,[1,2].contains(header[5]) else{throw invalid}
            let machine=header[5]==1 ? Int(header[18])|Int(header[19])<<8:Int(header[18])<<8|Int(header[19])
            guard (console == .psp || console == .ps2) && machine==8 || console == .dreamcast && machine==42 || [.gamecube,.wii].contains(console) && machine==20 else{throw invalid};return
        }
        if [.ps1,.psp].contains(console) && ext=="pbp" {
            guard prefix("\0PBP"),header.count>=40,le(8)>=40 else{throw invalid}
            var previous:UInt32=40
            for offset in stride(from:8,through:36,by:4) {let n=le(offset);guard n>=previous,Int(n)<=size else{throw invalid};previous=n};return
        }
        if [.psp,.ps2].contains(console) && ext=="cso" {
            // Common CSO v1 writers leave header_size at zero; PPSSPP uses
            // the fixed 24-byte header for this version as well.
            guard prefix("CISO"),header.count>=24,header[20]<=1,
                  (le(4)>=24 || le(4)==0),
                  le(16)>=2048,le(16)<=16*1024*1024,le(16)&(le(16)-1)==0,header[21]<32 else{throw invalid}
            if console == .ps2 {
                // Play reads the index immediately after its fixed 24-byte
                // CSOv1 header. Bound its allocation and index before import.
                let expanded=UInt64(le(8)) | UInt64(le(12))<<32
                guard [0,24].contains(le(4)),header[21]<=20,
                      expanded>=32768,expanded<=8*1024*1024*1024,expanded%2048==0 else{throw invalid}
                let block=UInt64(le(16)),frames=(expanded+block-1)/block
                guard frames+1<=UInt64(size-24)/4 else{throw invalid}
            }
            return
        }
        if console == .threeDS {
            let valid = ext=="3dsx" ? prefix("3DSX") : header.count>=260 && ["NCSD","NCCH"].contains(String(data:header[256..<260],encoding:.ascii) ?? "")
            guard valid else{throw invalid};return
        }
        if [.gamecube,.wii].contains(console) {
            if ext=="dol" {
                guard header.count>=256 else{throw invalid}
                var populated=false
                for i in 0..<18 {let offset=Int(be(i*4)),length=Int(be(0x90+i*4));if length>0 {guard offset>=256,offset<=size,length<=size-offset else{throw invalid};populated=true}}
                guard populated else{throw invalid};return
            }
            if ext=="rvz" {guard prefix("RVZ\u{1}") else{throw invalid};return}
            if ext=="wbfs" {guard prefix("WBFS") else{throw invalid};return}
            guard (console == .gamecube && be(28)==0xc2339f3d) || (console == .wii && be(24)==0x5d1c9ea3) else{throw invalid};return
        }
        if console == .dreamcast && ext=="chd" {guard prefix("MComprHD") else{throw invalid};return}
        if console == .dreamcast && ext=="cdi" {guard size>32768 else{throw invalid};return} // CDI's directory lives at the end; Flycast validates it on load.
        if [.psp,.ps2,.dreamcast].contains(console) && ext=="iso" {
            guard header.count>=32774,String(data:header[32769..<32774],encoding:.ascii)=="CD001" else{throw invalid};return
        }
        throw invalid
    }
    // PS1 discs and PSP executables share .pbp. Inspect DATA.PSAR rather
    // than routing every PBP to PSP; artwork can place it beyond 64 KiB.
    static func pbpConsole(header:Data,size:Int,read:(UInt64,Int)throws->Data)throws->GameConsole {
        try validate(header:header,size:size,ext:"pbp",console:.psp)
        let offset=(0..<4).reduce(UInt32(0)){$0 | UInt32(header[36+$1])<<($1*8)}
        guard Int(offset)<size else{return .psp} // PSP homebrew may have no PSAR.
        let signature=try read(UInt64(offset),min(11,size-Int(offset)))
        if signature.starts(with:Data("PSISOIMG00".utf8)) || signature.starts(with:Data("PSTITLEIMG".utf8)) {return .ps1}
        return .psp
    }
}

extension Library {
    @discardableResult func importNativeFile(_ url:URL,console preferred:GameConsole?)throws->Game {
        let fm=FileManager.default,info=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard info.isRegularFile==true,info.isSymbolicLink != true,let size=info.fileSize,size<=8*1024*1024*1024 else{throw VetaError.message("El juego debe ser un archivo de hasta 8 GB.")}
        let input=try FileHandle(forReadingFrom:url);defer{try? input.close()}
        let header=try input.read(upToCount:65536) ?? Data(),ext=url.pathExtension.lowercased()
        let console:GameConsole
        if ext=="pbp" {
            console=try NativeGameFile.pbpConsole(header:header,size:size) {offset,count in
                try input.seek(toOffset:offset);return try input.read(upToCount:count) ?? Data()
            }
            if let preferred,preferred != console {throw VetaError.message("El archivo no tiene una cabecera válida de \(preferred.name) o está incompleto.")}
        } else {console=try NativeGameFile.console(header:header,ext:ext,preferred:preferred)}
        // Import validates and stores bytes; it never starts the core. A JIT
        // session may expire between launches, so it must only gate playback.
        guard GameConsole.allCases.contains(console) else {throw VetaError.message("Consola desconocida.")}
        try NativeGameFile.validate(header:header,size:size,ext:ext,console:console)
        let staging=root.appendingPathComponent(".import-\(UUID().uuidString)",isDirectory:true)
        try fm.createDirectory(at:staging,withIntermediateDirectories:true);defer{try? fm.removeItem(at:staging)}
        let filename="game.\(ext)",copy=staging.appendingPathComponent(filename)
        guard fm.createFile(atPath:copy.path,contents:nil) else{throw VetaError.message("No se pudo copiar el juego.")}
        let output=try FileHandle(forWritingTo:copy);defer{try? output.close()}
        try input.seek(toOffset:0);var digest=SHA256(),copied=0
        while let chunk=try input.read(upToCount:1024*1024),!chunk.isEmpty {copied += chunk.count;guard copied<=size else{throw VetaError.message("El archivo cambió durante la importación.")};digest.update(data:chunk);try output.write(contentsOf:chunk)}
        guard copied==size else{throw VetaError.message("La copia del juego quedó incompleta.")}
        // libogc permits an unaligned final DOL section; Dolphin reads each
        // section in 32-byte blocks. Zero-pad the copied file, preserving all
        // executable bytes and leaving the original untouched.
        if ext=="dol",size%32 != 0 {let padding=Data(repeating:0,count:32-size%32);try output.write(contentsOf:padding);digest.update(data:padding)}
        try output.synchronize();let id=digest.finalize().map{String(format:"%02x",$0)}.joined()
        // Keep source identity stable for cloud deduplication and existing saves.
        let normalized = console == .threeDS ? try ThreeDSImportNormalization.apply(toStagedCopy:copy):false
        if let existing=games.first(where:{$0.id==id}) {
            // Reimport can repair the old internal copy without changing its
            // record, cover or saves. Never overwrite a different user file.
            let current=romURL(existing)
            if normalized, existing.console == .threeDS,
               try ThreeDSImportNormalization.patch(for:current) != nil,
               try ThreeDSImportNormalization.digest(of:current) == id {
                _ = try fm.replaceItemAt(current,withItemAt:copy)
            }
            return existing
        }
        var game=Game(id:id,name:String(url.deletingPathExtension().lastPathComponent.prefix(160)),console:console);game.contentName=filename
        let destination=directory(id)
        guard !fm.fileExists(atPath:destination.path) else{throw VetaError.message("Ya existe una carpeta para este juego. Se conservó sin modificar.")}
        try fm.moveItem(at:staging,to:destination);games.append(game)
        do {try persist()}catch{games.removeAll{$0.id==id};try? fm.removeItem(at:destination);throw error}
        return game
    }
}
