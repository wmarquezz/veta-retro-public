#if DEBUG && targetEnvironment(simulator)
import SwiftUI

/// Isolated local fixture for the complete catalog/import UI. Never included in a device build.
private actor CatalogPreviewSource: DirectCloudSource {
    let folders:[String:[DirectCloudEntry]], payloads:[String:Data]
    init(folders:[String:[DirectCloudEntry]],payloads:[String:Data]) {self.folders=folders;self.payloads=payloads}
    func list(folder:String) async throws->[DirectCloudEntry] {folders[folder] ?? []}
    func download(_ entry:DirectCloudEntry,progress:@escaping @Sendable(Int64,Int64)->Void) async throws->URL {
        guard let data=payloads[entry.id] else {throw DirectCloudError.changed}
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to:url);progress(Int64(data.count),Int64(data.count));return url
    }
}
struct CloudCatalogPreview:View {
    @StateObject private var model=DirectCloudBrowserModel()
    @StateObject private var library:Library
    init() {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("VetaCatalogUITest",isDirectory:true)
        try? FileManager.default.removeItem(at:root)
        _library=StateObject(wrappedValue:Library(root:root))
    }
    var body:some View {
        DirectCloudView(model:model) { snapshot in
            let result=try library.importURLs(snapshot.files,console:nil,artwork:ArtworkStore(root:library.root),continueOnError:true,initialIssues:snapshot.issues,sourceNames:snapshot.sourceNames,consoleHints:snapshot.consoleHints)
            return result.message
        }.environment(\.cloudInstalledGameIDs,Set(library.games.map(\.id)))
            .task {do {try await prepare()} catch {model.error=error.localizedDescription}}
    }
    @MainActor private func prepare() async throws {
        guard !model.isConnected else {return}
        var folders:[String:[DirectCloudEntry]]=[:],payloads:[String:Data]=[:],consoles:[CloudGameCatalog.Console]=[]
        for (console,folder,resource,name) in [(GameConsole.gb,"Game Boy","akanoid-gb","A_KANOID"),(.gba,"Game Boy Advance","space-game","Space Game")] {
            let ext=console.romExtension
            guard let url=Bundle.main.url(forResource:resource,withExtension:ext,subdirectory:"Content/"+resource) else {throw VetaError.message("No se encontró el juego de muestra.")}
            let data=try Data(contentsOf:url),id=sha256(data),filename=name+"."+ext
            let cover=UIGraphicsImageRenderer(size:CGSize(width:160,height:180)).pngData { context in
                UIColor(red:0.01,green:0.15,blue:0.19,alpha:1).setFill();context.fill(CGRect(x:0,y:0,width:160,height:180))
                (name as NSString).draw(in:CGRect(x:12,y:60,width:136,height:90),withAttributes:[.font:UIFont.boldSystemFont(ofSize:22),.foregroundColor:UIColor.orange])
            }
            payloads[id]=data;payloads[id+"-cover"]=cover
            folders[console.rawValue]=[.init(id:id,name:filename,folder:false,size:Int64(data.count)),.init(id:id+"-cover",name:name+".png",folder:false,size:Int64(cover.count))]
            consoles.append(.init(id:console.rawValue,name:folder,folder:folder,games:[.init(id:id,title:name,file:.init(path:folder+"/"+filename,bytes:Int64(data.count),sha256:id),cover:.init(path:folder+"/"+name+".png",bytes:Int64(cover.count),sha256:sha256(cover)),validation:"import")]))
            if console == .gb {_ = try library.importURL(url,console:console)}
        }
        let catalog=CloudGameCatalog(format:"veta.catalog",version:1,title:"Colección de prueba",generatedAt:"2026-10-31",consoles:consoles)
        let manifest=try JSONEncoder().encode(catalog);payloads["manifest"]=manifest
        folders["root"]=[.init(id:"manifest",name:CloudGameCatalog.filename,folder:false,size:Int64(manifest.count))]+consoles.map{.init(id:$0.id,name:$0.folder,folder:true)}
        model.updateInstalled(Set(library.games.map(\.id)))
        try await model.connectPortal(CatalogPreviewSource(folders:folders,payloads:payloads))
    }
}
#endif
