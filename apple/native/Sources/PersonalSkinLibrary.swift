import Foundation
import UIKit
import Combine

/// Reviewed built-in artwork. Personal selections and their files remain separate.
@MainActor enum StudioSkins {
    private static var cache:[GameConsole:PersonalSkin]=[:]
    private static let images:NSCache<NSString,UIImage> = {let value=NSCache<NSString,UIImage>();value.totalCostLimit=48*1024*1024;value.countLimit=8;return value}()
    static func skin(console:GameConsole)->PersonalSkin? {
        if let skin=cache[console] {return skin}
        guard let url=Bundle.main.url(forResource:"studio-"+console.rawValue,withExtension:"vetaskin"),
              let data=try? Data(contentsOf:url),let skin=try? PersonalSkin.decode(data,console:console) else{return nil}
        cache[console]=skin;return skin
    }
    static func variant(console:GameConsole,orientation:ControllerSkinOrientation)->PersonalSkinVariant? {skin(console:console)?.variant(orientation)}
    static func image(console:GameConsole,orientation:ControllerSkinOrientation)->UIImage? {
        let key=(console.rawValue+"/"+orientation.rawValue) as NSString
        if let image=images.object(forKey:key) {return image}
        guard let variant=variant(console:console,orientation:orientation),let image=try? PersonalSkinImage.decoded(variant.imagePNG) else{return nil}
        images.setObject(image,forKey:key,cost:image.cgImage.map{$0.bytesPerRow*$0.height} ?? variant.imagePNG.count);return image
    }
    static func image(console:GameConsole,orientation:ControllerSkinOrientation,layout:ControllerSkinLayout)->UIImage? {
        guard var v=variant(console:console,orientation:orientation),layout.canvas==v.layout.canvas else{return nil}
        if layout==v.layout{return image(console:console,orientation:orientation)}
        let key=("edited/"+((try? layout.encoded().base64EncodedString()) ?? "")) as NSString
        if let image=images.object(forKey:key){return image}
        v.layout=layout
        guard let image=try? v.renderedImage() else{return nil}
        images.setObject(image,forKey:key,cost:image.cgImage.map{$0.bytesPerRow*$0.height} ?? 0);return image
    }

}

/// Local installation-owned collection. Imported records get a new identity;
/// a peer's appearance message cannot replace this selection or these files.
@MainActor final class PersonalSkinLibrary:ObservableObject {
    static let shared=PersonalSkinLibrary()
    let root:URL
    let defaults:UserDefaults
    @Published private(set) var revision=0
    private var cache:[String:PersonalSkin]=[:]
    private let images=NSCache<NSString,UIImage>()
    init(root:URL?=nil,defaults:UserDefaults = .standard) {
        self.root=root ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("VetaPersonalSkins/v1",isDirectory:true)
        self.defaults=defaults
        images.totalCostLimit=48*1024*1024;images.countLimit=8
    }
    private func key(_ console:GameConsole,_ orientation:ControllerSkinOrientation)->String {console.preferencePrefix+"personalSkin.v1."+orientation.rawValue}
    private func url(_ id:String)throws->URL {
        guard UUID(uuidString:id) != nil else{throw PersonalSkinError.invalid}
        let u=root.appendingPathComponent(id+".vetaskin")
        // Canonicalize the standard /var alias but reject symlinked storage.
        let canonical: (URL)->String = {let p=$0.standardizedFileURL.path;return p == "/var" || p.hasPrefix("/var/") ? "/private"+p:p}
        guard canonical(root.resolvingSymlinksInPath())==canonical(root),
              canonical(u.resolvingSymlinksInPath())==canonical(u) else{throw PersonalSkinError.storage}
        return u
    }
    func load(_ id:String)throws->PersonalSkin {
        if let value=cache[id]{return value}
        let data=try PersonalSkinImage.read(url(id),limit:PersonalSkin.byteLimit)
        let skin=try PersonalSkin.decode(data);guard skin.id==id else{throw PersonalSkinError.invalid}
        if cache.count>=8{cache.removeAll()};cache[id]=skin;return skin
    }
    func list(console:GameConsole)throws->[PersonalSkin] {
        guard FileManager.default.fileExists(atPath:root.path) else{return []}
        return try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
            .filter{$0.pathExtension == "vetaskin"}.map{try load($0.deletingPathExtension().lastPathComponent)}
            .filter{$0.console==console.rawValue}.sorted{$0.name.localizedStandardCompare($1.name) == .orderedAscending}
    }
    func save(_ skin:PersonalSkin)throws {
        let data=try skin.encoded(),destination=try url(skin.id)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try data.write(to:destination,options:[.atomic,.completeFileProtectionUnlessOpen])
        if cache.count>=8{cache.removeAll()};cache[skin.id]=skin;images.removeAllObjects();revision+=1
    }
    func imported(_ skin:PersonalSkin,console:GameConsole)throws->PersonalSkin {
        try skin.validated(console:console);var copy=skin;copy.id=UUID().uuidString;return copy
    }
    func selectedID(console:GameConsole,orientation:ControllerSkinOrientation)->String? {defaults.string(forKey:key(console,orientation))}
    func selected(console:GameConsole,orientation:ControllerSkinOrientation)->PersonalSkinVariant? {
        guard let id=selectedID(console:console,orientation:orientation),let skin=try? load(id),skin.console==console.rawValue else{return nil}
        return skin.variant(orientation)
    }
    func image(id:String,orientation:ControllerSkinOrientation)throws->UIImage? {
        let key=id+"/"+orientation.rawValue
        if let image=images.object(forKey:key as NSString){return image}
        guard let v=try load(id).variant(orientation) else{return nil}
        let image=try v.editable().renderedImage()
        let cost=image.cgImage.map{$0.bytesPerRow*$0.height} ?? v.imagePNG.count
        images.setObject(image,forKey:key as NSString,cost:cost);return image
    }
    func select(_ skin:PersonalSkin,orientation:ControllerSkinOrientation)throws {
        guard let console=GameConsole(rawValue:skin.console),let saved=try? load(skin.id),saved==skin,let variant=skin.variant(orientation) else{throw PersonalSkinError.invalid}
        _ = try PersonalSkinImage.decoded(variant.imagePNG)
        defaults.set(skin.id,forKey:key(console,orientation));revision+=1
    }
    func useOriginal(console:GameConsole,orientation:ControllerSkinOrientation) {defaults.removeObject(forKey:key(console,orientation));revision+=1}
    func delete(_ skin:PersonalSkin)throws {
        let saved=try load(skin.id);guard saved==skin else{throw PersonalSkinError.storage}
        try FileManager.default.removeItem(at:url(skin.id))
        for console in GameConsole.allCases {for o in ControllerSkinOrientation.allCases {if selectedID(console:console,orientation:o)==skin.id{defaults.removeObject(forKey:key(console,o))}}}
        cache.removeValue(forKey:skin.id);images.removeAllObjects();revision+=1
    }
    static func generated(console:GameConsole,orientation:ControllerSkinOrientation,palette:ControllerSkinPalette)throws->PersonalSkinVariant {
        if palette == .studio,let variant=StudioSkins.variant(console:console,orientation:orientation) {return variant}
        let layout=ControllerSkinLayout.makeDefault(console:console,orientation:orientation,palette:palette)
        let deck=TouchDeck(frame:CGRect(origin:.zero,size:layout.canvas));var style=ControlStyle(console:console,defaults:nil);style.skin=palette.rawValue
        deck.style=style;deck.landscape=orientation == .landscape;deck.customLayout=layout;deck.layoutIfNeeded()
        guard deck.layoutIssue == nil else{throw PersonalSkinError.invalid}
        let format=UIGraphicsImageRendererFormat();format.scale=3;format.opaque=false
        let data=UIGraphicsImageRenderer(size:layout.canvas,format:format).pngData{context in
            if orientation == .portrait && palette != .transparent {style.background.setFill();context.fill(deck.bounds)}
            deck.draw(deck.bounds)
        }
        let variant=PersonalSkinVariant(layout:layout,imagePNG:data,procedural:true);try variant.validated(console:console);return variant
    }
}
