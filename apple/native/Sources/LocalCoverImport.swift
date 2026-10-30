import Foundation

/// Local user-selected files only. No network, fuzzy title matching or ROM changes.
enum LocalCoverImport {
    static let imageExtensions=["png","jpg","jpeg","heic","webp"]
    static let gameExtensions:Set<String> = ["zip","nes","sfc","smc","gb","gbc","gba","md","gen","sms","gg","a26","pce","nds","exe","bin","cue","wav","vetanes","vetaretro"]
    static func isImage(_ url:URL)->Bool {imageExtensions.contains(url.pathExtension.lowercased())}
    static func stem(_ url:URL)->String {url.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()}
    static func parent(_ url:URL)->URL {url.deletingLastPathComponent().standardizedFileURL}
    /// One selected console folder, not a recursive scan of the user's storage.
    static func files(_ selections:[URL])throws->[URL] {
        var files:[URL]=[],seen=Set<URL>()
        for selection in selections {
            let info=try selection.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
            guard info.isSymbolicLink != true else{throw VetaError.message("Selecciona archivos o carpetas originales, no enlaces.")}
            let children:[URL]
            if info.isDirectory == true {
                children=try FileManager.default.contentsOfDirectory(at:selection,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey],options:.skipsHiddenFiles).filter {
                    let ext=$0.pathExtension.lowercased()
                    return isImage($0) || gameExtensions.contains(ext) || NativeGameFile.extensions.contains(ext)
                }.sorted{$0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending}
            } else {children=[selection]}
            for child in children {
                let value=try child.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
                guard value.isRegularFile == true,value.isSymbolicLink != true else{continue}
                if seen.insert(child.standardizedFileURL).inserted {files.append(child)}
                guard files.count<=10_000 else{throw VetaError.message("Selecciona una carpeta con un máximo de 10.000 archivos.")}
            }
        }
        return files
    }
    struct Summary {
        var games=0,covers=0,unreadableCovers=0,backups=0
        var message:String {
            if games==0 && backups>0 {return L10n.text("Respaldo importado. Los juegos y portadas existentes se conservan.")}
            if games==0 {return L10n.text("Selecciona una ROM junto con su imagen, o la carpeta que contiene ambas. Las subcarpetas se importan por separado.")}
            var text=L10n.format("Juegos procesados: %d. Portadas añadidas: %d.",games,covers)
            text+=" "+L10n.text("Los juegos duplicados y las portadas existentes se conservan.")
            if unreadableCovers>0 {text+=" "+L10n.text("Alguna imagen no pudo importarse. El juego se conservó; puedes elegir otra desde Cambiar portada.")}
            return text
        }
    }
    @MainActor final class Session {
        private let selected:[URL]
        private var directories:[URL:[URL]]=[:]
        private(set) var summary=Summary()
        init(files:[URL]) {selected=files.filter{isImage($0)}}
        func attach(to game:Game,from rom:URL,store:ArtworkStore) {
            summary.games+=1
            // Even an unreadable old cover is retained for manual recovery.
            guard !FileManager.default.fileExists(atPath:store.url(game).path) else{return}
            let directory=parent(rom)
            if directories[directory]==nil {
                // This succeeds for VETA's Documents or a folder granted by Files.
                // A file-only grant may not expose siblings: the user can select
                // the image together with the ROM instead.
                directories[directory]=(try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil,options:.skipsHiddenFiles)) ?? []
            }
            let candidates=Set(selected.filter{parent($0)==directory}+(directories[directory] ?? []).filter{isImage($0)})
                .filter{stem($0)==stem(rom)}.sorted {
                    let a=imageExtensions.firstIndex(of:$0.pathExtension.lowercased())!,b=imageExtensions.firstIndex(of:$1.pathExtension.lowercased())!
                    return a==b ? $0.lastPathComponent<$1.lastPathComponent:a<b
                }
            guard let image=candidates.first else{return}
            do {
                let info=try image.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
                guard info.isRegularFile == true,info.isSymbolicLink != true else{throw VetaError.message("La portada no es un archivo de imagen normal.")}
                // CoverImage enforces size/decode limits; storage strips metadata.
                try store.setManual(CoverImage.read(image),for:game);summary.covers+=1
            } catch {summary.unreadableCovers+=1}
        }
    }
}
