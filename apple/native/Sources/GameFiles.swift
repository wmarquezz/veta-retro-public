import SwiftUI
import UniformTypeIdentifiers

enum GameFiles {
    static let consoles=GameConsole.chronological.map(\.name)
    // Documents is already the app's visible folder in Files. Never nest V-Retro.
    static func prepareFolder(in documents:URL? = nil,names:[String] = ["NES"]) throws -> URL {
        let folder = try documents ?? FileManager.default.url(for:.documentDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        for name in names {
            guard consoles.contains(name) else {throw VetaError.message("Consola desconocida.")}
            let target=folder.appendingPathComponent(name,isDirectory:true)
            if FileManager.default.fileExists(atPath:target.path),try target.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink == true {throw VetaError.message("La carpeta de consola no puede ser un enlace.")}
            let archived=folder.appendingPathComponent("Archivos conservados").appendingPathComponent(name)
            let archive=archived.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath:archive.path),try archive.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink == true {throw VetaError.message("Archivos conservados no puede ser un enlace.")}
            if FileManager.default.fileExists(atPath:archived.path) {try merge(archived,target)}
            try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
            if name == "Saturn" {try FileManager.default.createDirectory(at:target.appendingPathComponent("BIOS"),withIntermediateDirectories:true)}
        }
        return folder
    }
    private static func merge(_ source:URL,_ target:URL)throws {
            let fm=FileManager.default
            let sourceInfo=try source.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
            guard sourceInfo.isSymbolicLink != true else {throw VetaError.message("No se trasladó un enlace de V-Retro: \(source.lastPathComponent).")}
            if !fm.fileExists(atPath:target.path) {
                if sourceInfo.isDirectory == true {
                    // Files can reject renaming an externally created directory into Documents.
                    // Create an app-owned directory and transfer its children instead.
                    try fm.createDirectory(at:target,withIntermediateDirectories:true)
                } else {try fm.moveItem(at:source,to:target);return}
            }
            let targetInfo=try target.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
            if sourceInfo.isDirectory == true && targetInfo.isDirectory == true && targetInfo.isSymbolicLink != true {
                for child in try fm.contentsOfDirectory(at:source,includingPropertiesForKeys:nil) {try merge(child,target.appendingPathComponent(child.lastPathComponent))}
                try fm.removeItem(at:source)
            } else {
                // Keep both, even if names collide; never overwrite the user's files.
                var candidate=target;var n=1
                repeat {candidate=target.deletingPathExtension().appendingPathExtension("recuperado-\(n)" + (target.pathExtension.isEmpty ? "":"."+target.pathExtension));n += 1} while fm.fileExists(atPath:candidate.path)
                try fm.moveItem(at:source,to:candidate)
            }
        }
    static func migrate(in documents:URL? = nil,active:[String]) throws {
        let root=try prepareFolder(in:documents,names:[]),fm=FileManager.default
        let legacy=root.appendingPathComponent("V-Retro",isDirectory:true)
        if fm.fileExists(atPath:legacy.path) {
            let info=try legacy.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
            guard info.isDirectory == true,info.isSymbolicLink != true else{throw VetaError.message("V-Retro no es una carpeta normal; se conservó sin cambios.")}
            for child in try fm.contentsOfDirectory(at:legacy,includingPropertiesForKeys:nil) {try merge(child,root.appendingPathComponent(child.lastPathComponent))}
            try fm.removeItem(at:legacy)
        }
        // Retired consoles must also release empty folders; preserve any files.
        let migrationFolders=Set(consoles + ["PlayStation 3","Xbox","Xbox 360"])
        for name in migrationFolders where !active.contains(name) {
            let folder=root.appendingPathComponent(name)
            guard fm.fileExists(atPath:folder.path) else{continue}
            let info=try folder.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
            guard info.isDirectory == true,info.isSymbolicLink != true else{continue}
            if try fm.contentsOfDirectory(atPath:folder.path).isEmpty {try fm.removeItem(at:folder)}
            else {
                let archive=root.appendingPathComponent("Archivos conservados",isDirectory:true)
                if fm.fileExists(atPath:archive.path),try archive.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink == true {throw VetaError.message("Archivos conservados no puede ser un enlace.")}
                try fm.createDirectory(at:archive,withIntermediateDirectories:true)
                try merge(folder,archive.appendingPathComponent(name))
            }
        }
        _ = try prepareFolder(in:root,names:active)
    }

}

struct GameFilePicker:UIViewControllerRepresentable {
    let directory:URL
    var allowsDirectories=false
    let completion:([URL])->Void
    func makeCoordinator()->Coordinator {Coordinator(completion:completion)}
    func makeUIViewController(context:Context)->UIDocumentPickerViewController {
        let picker=UIDocumentPickerViewController(forOpeningContentTypes:allowsDirectories ? [.data,.folder]:[.data],asCopy:!allowsDirectories)
        picker.directoryURL=directory
        picker.allowsMultipleSelection=true
        picker.shouldShowFileExtensions=true
        picker.delegate=context.coordinator
        return picker
    }
    func updateUIViewController(_ controller:UIDocumentPickerViewController,context:Context) {}
    final class Coordinator:NSObject,UIDocumentPickerDelegate {
        let completion:([URL])->Void
        init(completion:@escaping ([URL])->Void) {self.completion=completion}
        func documentPicker(_ controller:UIDocumentPickerViewController,didPickDocumentsAt urls:[URL]) {completion(urls)}
        func documentPickerWasCancelled(_ controller:UIDocumentPickerViewController) {completion([])}
    }
}
