import SwiftUI

struct DiscoverGame:Codable,Identifiable {
    let id:String
    let title:String
    let console:GameConsole
    let author:String
    let summary:String
    let source:URL
    let license:String
    let download:URL?
    let filename:String?
    let bundled:String?
    let note:String?
    static let catalog:[Self] = {
        guard let url=Bundle.main.url(forResource:"DiscoveryCatalog",withExtension:"json"),let data=try? Data(contentsOf:url),let games=try? JSONDecoder().decode([Self].self,from:data) else{return []}
        return games
    }()
}

@MainActor final class DiscoveryDownloads:ObservableObject {
    @Published var busy:String?
    @Published var message:String?
    @Published var failure:String?
    private var task:Task<Void,Never>?
    func cancel() {task?.cancel()}
    func download(_ game:DiscoverGame,library:Library,documents:URL? = nil) {
        guard busy == nil else{return}
        busy=game.id;message=nil;failure=nil
        task=Task {
            defer {busy=nil;task=nil}
            do {
                let file:URL
                if let bundled=game.bundled {
                    guard let url=Bundle.main.url(forResource:bundled,withExtension:library.demoExtension(bundled),subdirectory:"Content/\(bundled)") else {throw VetaError.message("No se encontró el juego incluido.")}
                    file=url
                } else {
                    guard let url=game.download else {throw VetaError.message("Descarga el juego desde la página de su autor.")}
                    file=try await Self.fetch(url)
                }
                defer {if game.bundled == nil {try? FileManager.default.removeItem(at:file)}}
                try Task.checkCancellation()
                try library.enable(game.console,documents:documents)
                let folder=try GameFiles.prepareFolder(in:documents,names:[game.console.name]).appendingPathComponent(game.console.name)
                let name=game.filename ?? file.lastPathComponent
                guard DiscFiles.safeName(name) else {throw VetaError.message("Nombre de descarga inválido.")}
                let target=Self.availableURL(folder.appendingPathComponent(name))
                try FileManager.default.copyItem(at:file,to:target)
                if game.id == "classicube-saturn" {
                    let cue="FILE \"\(target.lastPathComponent)\" BINARY\n  TRACK 01 MODE1/2048\n    INDEX 01 00:00:00\n"
                    try cue.write(to:target.appendingPathExtension("cue"),atomically:true,encoding:.utf8)
                }
                let receipt="\(game.title) — \(game.author)\n\(game.license)\nFuente: \(game.source.absoluteString)\nDescarga: \(game.download?.absoluteString ?? "Incluida con fuentes y licencia")\n\(game.note ?? "")\n"
                try receipt.write(to:target.appendingPathExtension("origen.txt"),atomically:true,encoding:.utf8)
                if target.pathExtension.lowercased() == "zip" {
                    message=L10n.format("Guardado en VETA-Retro / %@ / %@. Usa Agregar juegos → Elegir archivos para importar el ZIP.",game.console.name,target.lastPathComponent)
                } else if game.console.playable && ["nes","gb","gbc","gba","sfc","smc","md","gen","sms","gg","a26","nds","z64","n64","v64","3dsx","exe"].contains(target.pathExtension.lowercased()) {
                    do {
                        let known=Set(library.games.map(\.id))
                        try library.importURL(target,console:game.console)
                        if var added=library.games.first(where:{!known.contains($0.id)}) {added.name=game.title;library.update(added)}
                        message=L10n.format("%@ añadido a la biblioteca. Original guardado en VETA-Retro / %@.",game.title,game.console.name)}
                    catch {message=L10n.format("Archivo guardado en VETA-Retro / %@. No se pudo importar: %@",game.console.name,L10n.text(error.localizedDescription))}
                } else {message=L10n.format("Guardado en VETA-Retro / %@. %@",game.console.name,L10n.text(game.note ?? "Usa Agregar juegos para importarlo."))}
            } catch is CancellationError {message="Descarga cancelada."}
            catch {failure=error.localizedDescription}
        }
    }
    static func availableURL(_ target:URL)->URL {
        var candidate=target,n=2
        while FileManager.default.fileExists(atPath:candidate.path) {
            candidate=target.deletingLastPathComponent().appendingPathComponent(target.deletingPathExtension().lastPathComponent+" (\(n))").appendingPathExtension(target.pathExtension);n += 1
        }
        return candidate
    }
    nonisolated static func fetch(_ url:URL) async throws -> URL {
        guard url.scheme == "https" else {throw VetaError.message("La descarga debe usar HTTPS.")}
        let config=URLSessionConfiguration.ephemeral;config.timeoutIntervalForRequest=30;config.timeoutIntervalForResource=180
        let session=URLSession(configuration:config);defer {session.invalidateAndCancel()}
        let (bytes,response)=try await session.bytes(from:url)
        let limit=128*1024*1024
        guard let http=response as? HTTPURLResponse,(200..<300).contains(http.statusCode),response.url?.scheme == "https",response.expectedContentLength<=limit,
              !(response.mimeType ?? "").contains("text/html") else {throw VetaError.message("El autor no pudo entregar el archivo. Abre su página o vuelve a intentarlo.")}
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath:url.path,contents:nil)
        let handle=try FileHandle(forWritingTo:url)
        var complete=false
        defer {try? handle.close();if !complete {try? FileManager.default.removeItem(at:url)}}
        var block=Data(),size=0;block.reserveCapacity(65536)
        for try await byte in bytes {
            try Task.checkCancellation();size += 1
            guard size<=limit else {throw VetaError.message("Esta descarga supera los 128 MB.")}
            block.append(byte)
            if block.count == 65536 {try handle.write(contentsOf:block);block.removeAll(keepingCapacity:true)}
        }
        guard size>0 else {throw VetaError.message("El archivo descargado está vacío.")}
        try handle.write(contentsOf:block);complete=true;return url
    }
}

struct DiscoveryView:View {
    @ObservedObject var library:Library
    @Environment(\.openURL) private var openURL
    @StateObject private var downloads=DiscoveryDownloads()
    @State private var selected:GameConsole = DiscoverGame.catalog.first?.console ?? .nes
    @State private var confirmation:DiscoverGame?
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                Text("DESCUBRE ALGO NUEVO").font(VetaTheme.body(10).bold()).tracking(1.5).foregroundStyle(VetaTheme.mint)
                Spacer()
                Menu {ForEach(GameConsole.chronological.filter { console in DiscoverGame.catalog.contains { $0.console == console } }) {console in Button(console.name){selected=console}}} label:{Label(selected.shortName,systemImage:"chevron.down").font(VetaTheme.body(13).bold())}.accessibilityIdentifier("discover-console")
            }
            Text("Tu próxima partida").font(VetaTheme.heading(28))
            Text("Juegos de sus autores, organizados por consola. Descarga el original a Archivos o visita su página.").font(VetaTheme.body(12)).foregroundStyle(VetaTheme.muted)
            LazyVGrid(columns:[GridItem(.adaptive(minimum:270),spacing:12)],spacing:12) {
                ForEach(DiscoverGame.catalog.filter{$0.console == selected}) {game in
                    VStack(alignment:.leading,spacing:10) {
                        Text(game.console.name.uppercased()).font(VetaTheme.body(10).bold()).foregroundStyle(VetaTheme.mint)
                        Text(game.title).font(VetaTheme.heading(24))
                        Text(LocalizedStringKey(game.summary)).font(VetaTheme.body(12)).foregroundStyle(VetaTheme.muted).fixedSize(horizontal:false,vertical:true)
                        Text(game.author).font(VetaTheme.body(10)).foregroundStyle(VetaTheme.muted)
                        if let note=game.note {Text(LocalizedStringKey(note)).font(VetaTheme.body(11)).foregroundStyle(VetaTheme.orange)}
                        if !game.console.playable {Text("En este iPhone necesita JIT para jugar.").font(VetaTheme.body(11)).foregroundStyle(VetaTheme.orange)}
                        HStack {
                            if game.download != nil || game.bundled != nil {
                                Button {confirmation=game} label:{Label(LocalizedStringKey(downloads.busy == game.id ? "Descargando…":game.bundled != nil ? "Añadir":"Descargar"),systemImage:"arrow.down.circle")}.buttonStyle(VetaButton(primary:true)).disabled(downloads.busy != nil).accessibilityIdentifier("add-\(game.id)")
                            }
                            if game.download == nil && game.bundled == nil {Button("Obtener del autor"){confirmation=game}.buttonStyle(VetaButton(primary:true))}
                            Link("Autor",destination:game.source).font(VetaTheme.body(12)).frame(minHeight:44)
                        }
                    }.frame(maxWidth:.infinity,alignment:.leading).padding(14).background(VetaTheme.background,in:RoundedRectangle(cornerRadius:10))
                }
            }
            if downloads.busy != nil {HStack {ProgressView();Text("Guardando el juego…").font(.caption);Spacer();Button("Cancelar"){downloads.cancel()}}}
        }.padding(18).background(VetaTheme.panel,in:RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).stroke(VetaTheme.border))
        .alert(L10n.format("¿Agregar %@?",confirmation?.title ?? ""),isPresented:Binding(get:{confirmation != nil},set:{if !$0 {confirmation=nil}})) {
            if let game=confirmation {Button("Guardar juego"){
                if game.download == nil && game.bundled == nil {
                    do {try library.enable(game.console);openURL(game.source)} catch {downloads.failure=error.localizedDescription}
                } else {downloads.download(game,library:library)}
                confirmation=nil
            }}
            Button("Cancelar",role:.cancel){confirmation=nil}
        } message:{Text(L10n.format("Se guardará en VETA-Retro / %@. Si la consola no está en tu colección, se agregará al confirmar. %@",confirmation?.console.name ?? "",confirmation?.license ?? ""))}
        .alert("Descarga",isPresented:Binding(get:{downloads.message != nil || downloads.failure != nil},set:{if !$0 {downloads.message=nil;downloads.failure=nil}})) {Button("Listo"){downloads.message=nil;downloads.failure=nil}} message:{Text(L10n.text(downloads.failure ?? downloads.message ?? ""))}
    }
}
