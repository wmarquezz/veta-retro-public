#if VETA_JIT_DEVELOPMENT
import Foundation

// The library index is the commit point. Persist a cleanup intent before moving
// the source; replay only once that entry is absent from the committed index.
extension Library {
    private struct PS3DeletionIntent:Codable {let version:Int;let owner:String;let legacyTitle:String?}
    private var ps3DeletionIntents:URL {root.appendingPathComponent("PS3PendingDeletes",isDirectory:true)}
    private func ps3SourceTitle(_ game:Game)->String? {
        var title=[CChar](repeating:0,count:64)
        return veta_ps3_source_title(romURL(game).path,&title,64) ? String(cString:title):nil
    }
    func preparePS3Deletion(_ game:Game)throws {
        guard game.console == .ps3 else{return}
        var legacy=ps3SourceTitle(game)
        if let title=legacy {
            // A legacy copy has no known owner. Keep it if another entry could
            // share the same title, including an unreadable/unknown source.
            for other in games where other.console == .ps3 && other.id != game.id {
                let otherTitle=ps3SourceTitle(other)
                if otherTitle == nil || otherTitle == title {legacy=nil;break}
            }
        }
        let fm=FileManager.default
        if fm.fileExists(atPath:ps3DeletionIntents.path),try ps3DeletionIntents.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink == true {throw VetaError.message("La carpeta de limpieza PS3 no puede ser un enlace.")}
        try fm.createDirectory(at:ps3DeletionIntents,withIntermediateDirectories:true)
        let intent=PS3DeletionIntent(version:1,owner:game.id,legacyTitle:legacy)
        try JSONEncoder().encode(intent).write(to:ps3DeletionIntents.appendingPathComponent(game.id+".json"),options:.atomic)
    }
    func recoverPS3Deletions()throws {
        let fm=FileManager.default
        guard fm.fileExists(atPath:ps3DeletionIntents.path) else{return}
        guard try ps3DeletionIntents.resourceValues(forKeys:[.isSymbolicLinkKey,.isDirectoryKey]).isSymbolicLink != true else {throw VetaError.message("La carpeta de limpieza PS3 no puede ser un enlace.")}
        for file in try fm.contentsOfDirectory(at:ps3DeletionIntents,includingPropertiesForKeys:[.isSymbolicLinkKey,.isRegularFileKey]) {
            let attrs=try file.resourceValues(forKeys:[.isSymbolicLinkKey,.isRegularFileKey])
            guard attrs.isSymbolicLink != true,attrs.isRegularFile == true else {continue}
            let intent=try JSONDecoder().decode(PS3DeletionIntent.self,from:Data(contentsOf:file))
            guard intent.version==1,intent.owner.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil,file.lastPathComponent==intent.owner+".json" else {throw VetaError.message("No se pudo identificar la limpieza PS3 pendiente; se conservaron los archivos.")}
            if games.contains(where:{$0.id==intent.owner}) {try fm.removeItem(at:file);continue}
            var message=[CChar](repeating:0,count:2048)
            let support=root.appendingPathComponent("NativeEngines/ps3/Support").path
            let ok=veta_ps3_remove_content(support,intent.owner,intent.legacyTitle ?? "",&message,2048)
            guard ok else {throw VetaError.message(String(cString:message))}
            try fm.removeItem(at:file)
        }
    }
}
#endif
