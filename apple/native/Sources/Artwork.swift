import Foundation
import UIKit
import ImageIO

// Artwork is separate from game metadata and emulation files. One atomic record
// keeps the image and its provenance together, including in native backups.
struct CoverRecord: Codable {
    let image: Data
    let manual: Bool
    let source: URL?
    let savedAt: Date
    static func decode(_ data:Data)throws -> Self {
        guard data.count <= 2*1024*1024 else {throw VetaError.message("Portada demasiado grande.")}
        let record=try PropertyListDecoder().decode(Self.self,from:data)
        _ = try CoverImage.prepare(record.image,maximumInputEdge:768)
        if let source=record.source {
            guard source.scheme == "https", source.host == "raw.githubusercontent.com", source.path.hasPrefix("/libretro-thumbnails/") else {throw VetaError.message("Fuente de portada inválida.")}
        }
        return record
    }
    func encoded()throws -> Data {
        let encoder=PropertyListEncoder();encoder.outputFormat = .binary
        return try encoder.encode(self)
    }
}
enum CoverImage {
    static let maximumBytes=30*1024*1024
    static func read(_ url:URL)throws -> Data {
        let access=url.startAccessingSecurityScopedResource();defer{if access {url.stopAccessingSecurityScopedResource()}}
        guard let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize,size>0,size<=maximumBytes else {throw VetaError.message("Elige una imagen de hasta 30 MB.")}
        return try prepare(Data(contentsOf:url,options:.mappedIfSafe))
    }
    static func prepare(_ data:Data,maximumInputEdge:Int = 20000)throws -> Data {
        let error=VetaError.message("No se pudo abrir la imagen. Prueba con una foto, PNG o JPEG de hasta 30 MB.")
        guard !data.isEmpty,data.count<=maximumBytes,
              let source=CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
              let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width=properties[kCGImagePropertyPixelWidth] as? Int,
              let height=properties[kCGImagePropertyPixelHeight] as? Int,
              width>0,height>0,width<=maximumInputEdge,height<=maximumInputEdge,width*height<=100_000_000,
              let thumbnail=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:768,kCGImageSourceShouldCacheImmediately:true] as CFDictionary),
              let jpeg=UIImage(cgImage:thumbnail).jpegData(compressionQuality:0.88) else {throw error}
        return jpeg
    }
}

enum CoverMatcher {
    static func matches(_ value:String,_ pattern:String)->Bool {value.range(of:pattern,options:[.regularExpression,.caseInsensitive]) != nil}
    static func modified(_ value:String)->Bool {matches(value,#"\b(hack|hacked|randomizer|randomized|modded)\b|\[(h\d*|t[^\]]*|f\d*|b\d*)\]"#)}
    static func key(_ name:String)->String {
        name.replacingOccurrences(of:#"\.(nes|sfc|smc|gb|gbc|gba|md|gen|sms|gg|a26|pce|nds|z64|v64|n64|3ds|3dsx|cxi|cci|cue|chd|pbp|iso|cso|bin|elf|dol|gcm|rvz|wbfs|png)$"#,with:"",options:[.regularExpression,.caseInsensitive])
            .replacingOccurrences(of:#"\((?:SGB Enhanced|GB Compatible)\)"#,with:" ",options:[.regularExpression,.caseInsensitive])
            .replacingOccurrences(of:#"\((?:(?:USA|U|US|Europe|E|EU|Japan|J|JP|World|W|Australia|Canada|Brazil|France|Germany|Italy|Spain|Sweden|Netherlands|Korea|China|Taiwan|Russia|UK|Asia|En|Fr|De|Es|It|Nl|Sv|Pt|Ja|Zh|Ko|Ru|NTSC|PAL)(?:[, /-]*))+\)|\((?:Rev|Version|Disc|Disk)\s+[^)]*\)|\[[^\]]*\]"#,with:" ",options:[.regularExpression,.caseInsensitive])
            .trimmingCharacters(in:.whitespacesAndNewlines)
            .replacingOccurrences(of:#",\s*(the|a|an)(?=\s*[-:]|$)|^(the|a|an)\s+"#,with:"",options:[.regularExpression,.caseInsensitive])
            .folding(options:[.diacriticInsensitive,.widthInsensitive],locale:Locale(identifier:"en_US_POSIX")).lowercased()
            .replacingOccurrences(of:"&",with:" and ")
            .replacingOccurrences(of:#"[^\p{L}\p{N}]+"#,with:" ",options:.regularExpression).trimmingCharacters(in:.whitespaces)
    }
    // GitHub raw serves a repository symlink as its filename text, not an image.
    // Accept only an indexed sibling for the same title; never follow URLs/paths.
    static func alias(_ data:Data,from name:String,names:Set<String>)->String? {
        guard data.count<=1024,let text=String(data:data,encoding:.utf8) else{return nil}
        let target=text.trimmingCharacters(in:.whitespacesAndNewlines)
        guard target != name,target.hasSuffix(".png"),!target.contains("/"),!target.contains("\\"),
              names.contains(target),!modified(target),key(target)==key(name) else{return nil}
        return target
    }
    static func region(_ name:String)->String {
        for (key,pattern) in [("usa","USA|U|US"),("europe","Europe|E|EU"),("japan","Japan|J|JP"),("world","World")] {
            if matches(name,"\\((?:[^)]*,\\s*)?(?:"+pattern+")(?:[,)]|\\s)") {return key}
        };return ""
    }
    static func grouped(_ names:[String])->[String:[String]] {
        Dictionary(grouping:names.filter{!modified($0) && !matches($0,#"\b(beta|proto|demo|sample|pirate)\b"#)},by:key)
    }
    static func match(_ name:String,names:[String])->String? {match(name,groups:grouped(names))}
    static func match(_ name:String,groups:[String:[String]])->String? {
        guard !modified(name) else{return nil}
        let full=key(name), stripped=key(name.replacingOccurrences(of:#"^\d{3,5}[ ._-]+(?=[A-Za-z])"#,with:"",options:.regularExpression))
        for target in [full,stripped] where !target.isEmpty {
            let candidates=groups[target] ?? []
            func score(_ candidate:String)->Int {
                let r=region(candidate), wanted=region(name)
                return (!wanted.isEmpty && r==wanted ? 100:0)+(r=="usa" ? 20:r=="world" ? 15:r=="europe" ? 10:0)
            }
            if let best=candidates.sorted(by:{score($0)==score($1) ? $0<$1:score($0)>score($1)}).first {return best}
        };return nil
    }
}
extension GameConsole {
    var artworkRepository:String {
        switch self {
        case .nes:return "Nintendo_-_Nintendo_Entertainment_System"
        case .snes:return "Nintendo_-_Super_Nintendo_Entertainment_System"
        case .gb:return "Nintendo_-_Game_Boy"
        case .gbc:return "Nintendo_-_Game_Boy_Color"
        case .gba:return "Nintendo_-_Game_Boy_Advance"
        case .ds:return "Nintendo_-_Nintendo_DS"
        case .threeDS:return "Nintendo_-_Nintendo_3DS"
        case .n64:return "Nintendo_-_Nintendo_64"
        case .gamecube:return "Nintendo_-_GameCube"
        case .wii:return "Nintendo_-_Wii"
        case .megaDrive:return "Sega_-_Mega_Drive_-_Genesis"
        case .masterSystem:return "Sega_-_Master_System_-_Mark_III"
        case .gameGear:return "Sega_-_Game_Gear"
        case .saturn:return "Sega_-_Saturn"
        case .dreamcast:return "Sega_-_Dreamcast"
        case .atari2600:return "Atari_-_2600"
        case .pcEngine:return "NEC_-_PC_Engine_-_TurboGrafx_16"
        case .ps1:return "Sony_-_PlayStation"
        case .ps2:return "Sony_-_PlayStation_2"
        #if VETA_JIT_DEVELOPMENT
        case .ps3:return "Sony_-_PlayStation_3"
        case .xbox:return "Microsoft_-_Xbox"
        case .xbox360:return "Microsoft_-_Xbox_360"
        #endif
        case .psp:return "Sony_-_PlayStation_Portable"
        }
    }
}
struct DownloadedCover {let image:Data;let source:URL}
protocol CoverProviding {func find(_ game:Game)async throws -> DownloadedCover?}
actor LibretroArtwork:CoverProviding {
    struct Index:Codable {let date:Date;let names:[String]}
    struct Tree:Decodable {struct Item:Decodable {let path:String;let type:String};let tree:[Item];let truncated:Bool}
    let cache:URL
    let session:URLSession
    private var indexes:[String:Index]=[:]
    private var failures:[String:Date]=[:]
    private var groupedNames:[String:[String:[String]]]=[:]
    private var rateLimitedUntil=Date.distantPast
    init(cache:URL,session:URLSession? = nil) {
        self.cache=cache
        let configuration=URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest=20;configuration.timeoutIntervalForResource=45
        configuration.httpShouldSetCookies=false;configuration.urlCredentialStorage=nil
        self.session=session ?? URLSession(configuration:configuration)
    }
    func fetch(_ url:URL,limit:Int)async throws -> Data {
        var request=URLRequest(url:url);request.setValue("VETA-Retro-Artwork",forHTTPHeaderField:"User-Agent")
        let (stream,response)=try await session.bytes(for:request)
        guard let http=response as? HTTPURLResponse,http.statusCode==200 else {
            if let http=response as? HTTPURLResponse,[403,429].contains(http.statusCode) {rateLimitedUntil=Date().addingTimeInterval(600)}
            throw VetaError.message("El proveedor no está disponible. Puedes reintentar más tarde o elegir una imagen.")
        }
        guard response.expectedContentLength<=Int64(limit) else{throw VetaError.message("La descarga supera el tamaño permitido.")}
        var data=Data();data.reserveCapacity(min(limit,max(0,Int(response.expectedContentLength))))
        for try await byte in stream {
            if data.count%16384==0 {try Task.checkCancellation()}
            guard data.count<limit else{throw VetaError.message("La descarga supera el tamaño permitido.")};data.append(byte)
        }
        return data
    }
    func index(_ repo:String)async throws -> [String] {
        let file=cache.appendingPathComponent(repo+".json")
        let cached=indexes[repo] ?? (try? JSONDecoder().decode(Index.self,from:Data(contentsOf:file)))
        if let cached,Date().timeIntervalSince(cached.date)<7*86400 {indexes[repo]=cached;return cached.names}
        if (failures[repo] ?? .distantPast)>Date() || rateLimitedUntil>Date() {
            if let cached{return cached.names};throw VetaError.message("El proveedor está ocupado. Reintenta más tarde.")
        }
        do {
            let url=URL(string:"https://api.github.com/repos/libretro-thumbnails/\(repo)/git/trees/master:Named_Boxarts")!
            let tree=try JSONDecoder().decode(Tree.self,from:await fetch(url,limit:8*1024*1024))
            guard !tree.truncated else{throw VetaError.message("El catálogo de portadas está incompleto.")}
            let names=tree.tree.filter{$0.type=="blob" && $0.path.hasSuffix(".png") && !$0.path.contains("/") && !$0.path.contains("\\")}.map(\.path)
            guard !names.isEmpty else{throw VetaError.message("No hay portadas en este catálogo.")}
            let result=Index(date:Date(),names:names);indexes[repo]=result;groupedNames[repo]=nil
            try? FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true)
            try? JSONEncoder().encode(result).write(to:file,options:.atomic)
            return names
        } catch {
            if error is CancellationError {throw error}
            failures[repo]=Date().addingTimeInterval(300)
            if let cached{return cached.names};throw error
        }
    }
    func find(_ game:Game)async throws -> DownloadedCover? {
        guard ArtworkDistributionPolicy.allowsRemoteCovers else{return nil}
        guard !CoverMatcher.modified(game.name) else{return nil}
        let names=try await index(game.console.artworkRepository)
        if groupedNames[game.console.artworkRepository]==nil {groupedNames[game.console.artworkRepository]=CoverMatcher.grouped(names)}
        guard let name=CoverMatcher.match(game.name,groups:groupedNames[game.console.artworkRepository]!) else{return nil}
        let base=URL(string:"https://raw.githubusercontent.com/libretro-thumbnails/\(game.console.artworkRepository)/master/Named_Boxarts/")!
        guard rateLimitedUntil<=Date() else {throw VetaError.message("El proveedor está ocupado. Reintenta más tarde.")}
        var selected=name,visited=Set<String>()
        for _ in 0..<4 {
            guard visited.insert(selected).inserted else{break}
            let url=base.appendingPathComponent(selected),data=try await fetch(url,limit:4*1024*1024)
            if let alias=CoverMatcher.alias(data,from:selected,names:Set(names)) {selected=alias;continue}
            return DownloadedCover(image:try CoverImage.prepare(data),source:url)
        }
        throw VetaError.message("No se pudo descargar la portada. Se conserva la imagen actual. Puedes reintentar o elegir una imagen.")
    }
}

@MainActor final class ArtworkStore:ObservableObject {
    @Published private(set) var revision=0
    @Published private(set) var messages:[String:String]=[:]
    @Published private(set) var searching:Set<String>=[]
    @Published var enabled:Bool {didSet {defaults.set(enabled,forKey:"native.autoArtwork");if !enabled {queue.removeAll()}}}
    let root:URL
    let provider:any CoverProviding
    private let defaults:UserDefaults
    private var images=NSCache<NSString,UIImage>()
    private var attempts:[String:Date]=[:]
    private var generations:[String:UUID]=[:]
    private var requests:[String:UUID]=[:]
    private var queue:[Game]=[]
    private var worker:Task<Void,Never>?
    init(root:URL,provider:(any CoverProviding)? = nil,defaults:UserDefaults = .standard) {
        self.root=root;self.defaults=defaults
        enabled=ArtworkDistributionPolicy.allowsRemoteCovers && (defaults.object(forKey:"native.autoArtwork") as? Bool ?? true)
        self.provider=provider ?? LibretroArtwork(cache:root.appendingPathComponent("ArtworkIndexes"))
        images.totalCostLimit=32*1024*1024
        attempts=(try? JSONDecoder().decode([String:Date].self,from:Data(contentsOf:root.appendingPathComponent("artwork-attempts.json")))) ?? [:]
        // Retry previous misses once when matching improves. Existing images,
        // including personal artwork, still take priority in schedule/search.
        if defaults.integer(forKey:"native.artworkMatchingVersion") < 2 {
            attempts.removeAll()
            try? JSONEncoder().encode(attempts).write(to:root.appendingPathComponent("artwork-attempts.json"),options:.atomic)
            defaults.set(2,forKey:"native.artworkMatchingVersion")
        }
    }
    func url(_ game:Game)->URL {root.appendingPathComponent(game.id).appendingPathComponent("cover.vcover")}
    func record(_ game:Game)->CoverRecord? {guard let data=try? Data(contentsOf:url(game)) else{return nil};return try? CoverRecord.decode(data)}
    func image(_ game:Game)->UIImage? {
        if let cached=images.object(forKey:game.id as NSString) {return cached}
        guard let record=record(game),let image=UIImage(data:record.image) else{return nil}
        images.setObject(image,forKey:game.id as NSString,cost:Int(image.size.width*image.size.height*4));return image
    }
    func save(_ record:CoverRecord,for game:Game)throws {
        guard FileManager.default.fileExists(atPath:root.appendingPathComponent(game.id).path) else {throw VetaError.message("El juego ya no está en la biblioteca.")}
        try record.encoded().write(to:url(game),options:.atomic)
        generations[game.id]=UUID();images.removeObject(forKey:game.id as NSString);revision+=1
    }
    func setManual(_ data:Data,for game:Game)throws {
        try save(CoverRecord(image:try CoverImage.prepare(data),manual:true,source:nil,savedAt:Date()),for:game)
        messages[game.id]="Portada personal guardada. Disponible sin conexión."
    }
    func forget(_ game:Game) {
        generations[game.id]=UUID();requests[game.id]=nil
        queue.removeAll{$0.id==game.id};searching.remove(game.id)
        images.removeObject(forKey:game.id as NSString);messages[game.id]=nil;attempts[game.id]=nil
        try? JSONEncoder().encode(attempts).write(to:root.appendingPathComponent("artwork-attempts.json"),options:.atomic)
        revision+=1
    }
    func schedule(_ games:[Game]) {
        guard ArtworkDistributionPolicy.allowsRemoteCovers,enabled else{return}
        for game in games where !queue.contains(where:{$0.id==game.id}) && !searching.contains(game.id) && !FileManager.default.fileExists(atPath:url(game).path) && (attempts[game.id] ?? .distantPast)<=Date() {queue.append(game)}
        guard worker==nil,!queue.isEmpty else{return}
        worker=Task { [weak self] in
            guard let self else{return}
            while enabled,!queue.isEmpty {let game=queue.removeFirst();await search(game,automatic:true)}
            worker=nil
        }
    }
    func search(_ game:Game,automatic:Bool = false)async {
        guard ArtworkDistributionPolicy.allowsRemoteCovers else{return}
        guard !searching.contains(game.id) else{return}
        if automatic && (!enabled || record(game) != nil) {return}
        let token=UUID();generations[game.id]=token;requests[game.id]=token;searching.insert(game.id);messages[game.id]="Buscando portada…"
        defer{if requests[game.id]==token {requests[game.id]=nil;searching.remove(game.id)}}
        do {
            let result=try await provider.find(game)
            guard generations[game.id]==token else {return}
            guard !automatic || enabled else {messages[game.id]="Búsqueda automática desactivada. Se conserva la imagen actual.";return}
            if let result {
                try save(CoverRecord(image:result.image,manual:false,source:result.source,savedAt:Date()),for:game)
                messages[game.id]="Portada descargada. Disponible sin conexión."
            } else {messages[game.id]="No encontramos una coincidencia segura. Puedes elegir una imagen desde Fotos o Archivos."}
            attempts[game.id]=Date().addingTimeInterval(7*86400)
        } catch {
            guard generations[game.id]==token else{return}
            messages[game.id]="No se pudo descargar la portada. Se conserva la imagen actual. Puedes reintentar o elegir una imagen."
            attempts[game.id]=Date().addingTimeInterval(300)
        }
        try? JSONEncoder().encode(attempts).write(to:root.appendingPathComponent("artwork-attempts.json"),options:.atomic)
    }
}
