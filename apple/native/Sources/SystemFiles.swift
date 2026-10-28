import Foundation
import CryptoKit

extension Library {
    func prepareSystem(for console:GameConsole,documents:URL? = nil)throws->URL {
        let system=root.appendingPathComponent("System",isDirectory:true)
        try FileManager.default.createDirectory(at:system,withIntermediateDirectories:true)
        if console == .ps1 || console == .saturn {
            let folder=try GameFiles.prepareFolder(in:documents,names:[console.name]).appendingPathComponent(console.name).appendingPathComponent("BIOS")
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let expected:[String:String] = console == .saturn ? ["sega_101.bin":"85ec9ca47d8f6807718151cbcca8b964","mpr-17933.bin":"3240872c70984b6cbfda1586cab68dbe"]:["scph5500.bin":"8dd7d5296a650fac7319bce665a6a53c","scph5501.bin":"490f666e1afb15b7362b406ed1cea246f","scph5502.bin":"32736f17079d0b2b7024407c39bd3050"]
            for (name,digest) in expected {
                let publicFile=folder.appendingPathComponent(name)
                let source=FileManager.default.fileExists(atPath:publicFile.path) ? publicFile:system.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath:source.path) {
                    let size=try source.resourceValues(forKeys:[.fileSizeKey,.isSymbolicLinkKey]);guard size.fileSize==512*1024,size.isSymbolicLink != true else{throw VetaError.message("La BIOS \(name) no es válida.")}
                    let data=try Data(contentsOf:source)
                    guard Insecure.MD5.hash(data:data).map({String(format:"%02x",$0)}).joined()==digest else{throw VetaError.message("La BIOS \(name) no coincide con la versión esperada.")}
                    try data.write(to:system.appendingPathComponent(name),options:.atomic)
                }
            }
            if console == .saturn && !expected.keys.contains(where:{FileManager.default.fileExists(atPath:system.appendingPathComponent($0).path)}) {
                throw VetaError.message("Saturn necesita su BIOS. Coloca sega_101.bin (Japón) o mpr-17933.bin (EE. UU./Europa) en VETA-Retro → Saturn → BIOS.")
            }
        }
        if console == .psp {
            let destination=system.appendingPathComponent("PPSSPP")
            if !FileManager.default.fileExists(atPath:destination.path) {
                guard let source=Bundle.main.url(forResource:"PPSSPP",withExtension:nil,subdirectory:"Content") else{throw VetaError.message("Faltan los archivos de sistema incluidos de PSP.")}
                try FileManager.default.copyItem(at:source,to:destination)
            }
        }
        if console == .gamecube || console == .wii {
            let destination=system.appendingPathComponent("dolphin-emu/Sys")
            if !FileManager.default.fileExists(atPath:destination.path) {
                guard let source=Bundle.main.url(forResource:"DolphinSys",withExtension:nil,subdirectory:"Content") else{throw VetaError.message("Faltan los archivos de sistema incluidos de GameCube/Wii.")}
                try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
                try FileManager.default.copyItem(at:source,to:destination)
            }
        }
        return system
    }
}

extension Library {
    func prepareCoreSaves(for game:Game)throws->URL {
        guard game.console == .saturn || NativeGameFile.consoles.contains(game.console) else {return stateDirectory(game)}
        let folder=file(game,"CoreSaves")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        if game.console == .psp {for name in ["PSP/SAVEDATA","PSP/SYSTEM","PSP/PPSSPP_STATE"] {try FileManager.default.createDirectory(at:folder.appendingPathComponent(name,isDirectory:true),withIntermediateDirectories:true)}}
        if game.console == .dreamcast {try FileManager.default.createDirectory(at:folder.appendingPathComponent("dc",isDirectory:true),withIntermediateDirectories:true)}
        if game.console == .threeDS {try FileManager.default.createDirectory(at:folder.appendingPathComponent("Azahar/sdmc/config",isDirectory:true),withIntermediateDirectories:true)}
        return folder
    }
    static func validateCoreSaves(_ files:[String:Data])throws {
        guard files.count<=512,files.values.reduce(0,{$0+$1.count})<=32*1024*1024 else {throw VetaError.message("El respaldo de memoria de la consola supera el límite.")}
        let paths=Set(files.keys.map{$0.lowercased()})
        guard paths.count==files.count else {throw VetaError.message("Hay memorias duplicadas en el respaldo.")}
        for name in files.keys {
            let parts=name.components(separatedBy:"/")
            guard parts.count<=16,parts.allSatisfy(DiscFiles.safeName),!parts.dropLast().indices.contains(where:{paths.contains(parts.prefix($0+1).joined(separator:"/").lowercased())}) else {throw VetaError.message("Ruta de memoria inválida en el respaldo.")}
        }
    }
    func coreSaveFiles(_ game:Game)throws->[String:Data]? {
        let folder=file(game,"CoreSaves"),fm=FileManager.default
        guard fm.fileExists(atPath:folder.path) else{return nil}
        guard try folder.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else{throw VetaError.message("La carpeta de memorias no puede ser un enlace.")}
        var traversalError:Error?
        guard let walker=fm.enumerator(at:folder,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey],errorHandler:{_,error in traversalError=error;return false}) else{throw VetaError.message("No se pudieron leer las memorias de la consola.")}
        var files:[String:Data]=[:],total=0
        for case let url as URL in walker {
            let info=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
            guard info.isSymbolicLink != true else{throw VetaError.message("Una memoria no puede ser un enlace.")}
            guard info.isRegularFile==true else{continue}
            total += info.fileSize ?? 0
            guard total<=32*1024*1024,files.count<512 else{throw VetaError.message("Las memorias de la consola superan el límite del respaldo.")}
            files[String(url.path.dropFirst(folder.path.count+1))]=try Data(contentsOf:url)
        }
        if let traversalError {throw traversalError}
        try Self.validateCoreSaves(files)
        return files.isEmpty ? nil:files
    }
    func restoreCoreSaves(_ files:[String:Data],for game:Game)throws {
        try Self.validateCoreSaves(files)
        for (name,data) in files {
            let url=file(game,"CoreSaves").appendingPathComponent(name)
            try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
            try data.write(to:url,options:.atomic)
        }
    }
}
