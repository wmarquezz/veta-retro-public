#if VETA_JIT_DEVELOPMENT
import Foundation
import CryptoKit

// Console identity is explicit. In particular an ISO is never guessed to be
// Xbox, Xbox 360 or a different optical-disc console from its extension.
enum ExperimentalGameContent {
    static let maximumBytes = 64 * 1024 * 1024 * 1024
    static func validate(_ url:URL, console:GameConsole)throws {
        let fm=FileManager.default
        let info=try url.resourceValues(forKeys:[.isSymbolicLinkKey,.isRegularFileKey,.isDirectoryKey,.fileSizeKey])
        guard info.isSymbolicLink != true else {throw VetaError.message("No se importan enlaces como juegos.")}
        if console == .ps3 && info.isDirectory == true {
            let candidates=[("PS3_GAME/USRDIR/EBOOT.BIN","PS3_GAME/PARAM.SFO"),("USRDIR/EBOOT.BIN","PARAM.SFO")]
            guard candidates.contains(where:{paths in
                let file=url.appendingPathComponent(paths.0)
                guard let attrs=try? file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey]) else{return false}
                let metadata=url.appendingPathComponent(paths.1)
                return attrs.isRegularFile == true && attrs.isSymbolicLink != true && (attrs.fileSize ?? 0)>0 && fm.fileExists(atPath:metadata.path)
            }) else {throw VetaError.message("Selecciona una carpeta PS3 con PS3_GAME/USRDIR/EBOOT.BIN o USRDIR/EBOOT.BIN.")}
            return
        }
        if console == .xbox && url.pathExtension.lowercased()=="veta-xbox-firmware" {
            guard info.isRegularFile == true,info.fileSize==Data("VETA-XBOX-FIRMWARE-1\n".utf8).count,
                  try Data(contentsOf:url)==Data("VETA-XBOX-FIRMWARE-1\n".utf8) else {
                throw VetaError.message("El diagnóstico Xbox no contiene la marca de firmware abierto esperada.")
            }
            return
        }
        guard info.isRegularFile == true,let size=info.fileSize,size>=32,size<=maximumBytes else {throw VetaError.message("El juego debe ser un archivo válido de hasta 64 GB.")}
        let ext=url.pathExtension.lowercased(),file=try FileHandle(forReadingFrom:url);defer{try? file.close()}
        let header=try file.read(upToCount:64) ?? Data()
        switch console {
        case .ps3:
            guard ext=="pkg",header.starts(with:[0x7f,0x50,0x4b,0x47]) else {throw VetaError.message("PS3 admite una carpeta extraída con PARAM.SFO y EBOOT.BIN, o un paquete PKG.")}
        case .xbox,.xbox360:
            if console == .xbox360 && ext=="xex" {
                guard header.starts(with:Data("XEX2".utf8)) else {throw VetaError.message("El ejecutable no contiene una cabecera XEX2 válida.")};return
            }
            guard ["iso","xiso"].contains(ext),size>=0x10000+20 else {throw VetaError.message("Selecciona una imagen ISO/XISO de la consola elegida o un XEX2 para Xbox 360.")}
            // Offsets are taken from the pinned engines' readers. Xbox accepts
            // normalized XISO; Xbox 360 follows XeniOS GdfxFindPartition.
            let partitions:[UInt64]=console == .xbox ? [0]:[0,0xFB20,0x20600,0x02080000,0x0FD90000]
            var valid=false
            for partition in partitions {
                let offset=partition+0x10000
                guard offset+28<=UInt64(size) else {continue}
                try file.seek(toOffset:offset)
                let descriptor=try file.read(upToCount:28) ?? Data()
                guard descriptor.count==28,descriptor.starts(with:Data("MICROSOFT*XBOX*MEDIA".utf8)) else {continue}
                func word(_ at:Int)->UInt64 {(0..<4).reduce(0){$0 | UInt64(descriptor[at+$1]) << ($1*8)}}
                let root=partition+word(20)*2048,length=word(24)
                guard length>=13,length<=32*1024*1024,root<=UInt64(size),length<=UInt64(size)-root else {continue}
                valid=true;break
            }
            guard valid else {throw VetaError.message("No se encontró una cabecera XDVDFS compatible. No se tratará este ISO como otra consola.")}
        default:throw VetaError.message("Selecciona la consola experimental antes de importar.")
        }
    }
}

private enum ExperimentalGameImport {
    struct Prepared {let game:Game;let staging:URL}
    static func prepare(_ url:URL,console:GameConsole,root:URL)throws->Prepared {
        guard GameConsole.allCases.contains(console),console.isStandaloneEngine else {throw VetaError.message("Selecciona la consola experimental antes de importar.")}
        let scoped=url.startAccessingSecurityScopedResource();defer{if scoped {url.stopAccessingSecurityScopedResource()}}
        try ExperimentalGameContent.validate(url,console:console)
        // iOS can expose /var and /private/var aliases for the same container.
        // Enumerated children and the root must share one canonical prefix.
        let url=url.resolvingSymlinksInPath().standardizedFileURL
        let fm=FileManager.default,isDirectory=try url.resourceValues(forKeys:[.isDirectoryKey]).isDirectory == true
        let staging=root.appendingPathComponent(".nextgen-import-"+UUID().uuidString,isDirectory:true)
        try fm.createDirectory(at:staging,withIntermediateDirectories:true)
        var ready=false;defer{if !ready {try? fm.removeItem(at:staging)}}
        let name=isDirectory ? "game.ps3":"game."+url.pathExtension.lowercased()
        let content=staging.appendingPathComponent(name,isDirectory:isDirectory)
        func relativePath(_ child:URL)throws->String {
            let prefix=url.path.hasSuffix("/") ? url.path:url.path+"/"
            let path=child.resolvingSymlinksInPath().standardizedFileURL.path
            guard path.hasPrefix(prefix) else {throw VetaError.message("La carpeta contiene nombres duplicados o inválidos.")}
            return String(path.dropFirst(prefix.count))
        }
        var sources:[URL]=[]
        if isDirectory {
            try fm.createDirectory(at:content,withIntermediateDirectories:true)
            var enumerationError:Error?
            var entryCount=0
            guard let iterator=fm.enumerator(at:url,includingPropertiesForKeys:[.isSymbolicLinkKey,.isRegularFileKey,.isDirectoryKey,.fileSizeKey],options:[],errorHandler:{_,error in enumerationError=error;return false}) else {throw VetaError.message("No se pudo leer la carpeta del juego.")}
            for case let child as URL in iterator {
                let info=try child.resourceValues(forKeys:[.isSymbolicLinkKey,.isRegularFileKey,.isDirectoryKey])
                guard info.isSymbolicLink != true else {throw VetaError.message("La carpeta del juego contiene enlaces; se conservó el original.")}
                if info.isRegularFile == true {sources.append(child)}
                else if info.isDirectory == true {
                    let relative=try relativePath(child)
                    try fm.createDirectory(at:content.appendingPathComponent(relative,isDirectory:true),withIntermediateDirectories:true)
                } else {throw VetaError.message("La carpeta contiene un archivo no admitido.")}
                entryCount+=1
                guard entryCount<=50000 else {throw VetaError.message("La carpeta supera el límite de archivos de importación.")}
            }
            if let enumerationError {throw enumerationError}
        } else {sources=[url]}
        var digest=SHA256(),total=0,seen=Set<String>()
        for source in sources.sorted(by:{$0.path<$1.path}) {
            let relative=isDirectory ? try relativePath(source):name
            guard !relative.isEmpty,!relative.split(separator:"/").contains(".."),seen.insert(relative.precomposedStringWithCanonicalMapping.lowercased()).inserted else {throw VetaError.message("La carpeta contiene nombres duplicados o inválidos.")}
            let destination=isDirectory ? content.appendingPathComponent(relative):content
            try fm.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
            let size=(try source.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? 0
            guard size>=0,size<=ExperimentalGameContent.maximumBytes-total else {throw VetaError.message("El juego supera los 64 GB permitidos.")};total+=size
            if isDirectory {digest.update(data:Data(relative.utf8));digest.update(data:Data([0]));var big=UInt64(size).bigEndian;withUnsafeBytes(of:&big){digest.update(data:Data($0))}}
            guard fm.createFile(atPath:destination.path,contents:nil) else {throw VetaError.message("No se pudo copiar el juego.")}
            let input=try FileHandle(forReadingFrom:source),output=try FileHandle(forWritingTo:destination)
            do {
                var copied=0
                while let chunk=try input.read(upToCount:1024*1024),!chunk.isEmpty {copied+=chunk.count;guard copied<=size else {throw VetaError.message("El archivo cambió durante la importación.")};digest.update(data:chunk);try output.write(contentsOf:chunk)}
                guard copied==size else {throw VetaError.message("La copia del juego quedó incompleta.")};try output.synchronize();try input.close();try output.close()
            } catch {try? input.close();try? output.close();throw error}
        }
        try ExperimentalGameContent.validate(content,console:console)
        let id=digest.finalize().map{String(format:"%02x",$0)}.joined()
        let title=url.pathExtension.lowercased()=="veta-xbox-firmware" ? "Diagnóstico Xbox (firmware abierto)":String(url.deletingPathExtension().lastPathComponent.prefix(160))
        var game=Game(id:id,name:title,console:console);game.contentName=name
        ready=true;return Prepared(game:game,staging:staging)
    }
}
extension Library {
    @discardableResult func importExperimental(_ url:URL,console:GameConsole)throws->Game {
        try commitExperimental(ExperimentalGameImport.prepare(url,console:console,root:root))
    }
    @discardableResult func importExperimentalInBackground(_ url:URL,console:GameConsole)async throws->Game {
        let root=self.root
        let prepared=try await Task.detached(priority:.userInitiated) {try ExperimentalGameImport.prepare(url,console:console,root:root)}.value
        return try commitExperimental(prepared)
    }
    private func commitExperimental(_ prepared:ExperimentalGameImport.Prepared)throws->Game {
        let fm=FileManager.default,game=prepared.game
        defer{try? fm.removeItem(at:prepared.staging)}
        if let existing=games.first(where:{$0.id==game.id}) {guard existing.console==game.console else {throw VetaError.message("Este archivo ya está asociado a otra consola.")};return existing}
        let destination=directory(game.id);guard !fm.fileExists(atPath:destination.path) else {throw VetaError.message("Ya existe una carpeta para este juego. Se conservó sin modificar.")}
        try fm.moveItem(at:prepared.staging,to:destination)
        let next=games+[game]
        do {try JSONEncoder().encode(next).write(to:root.appendingPathComponent("library.json"),options:.atomic);games=next}
        catch {try? fm.removeItem(at:destination);throw error}
        return game
    }
}
#endif
