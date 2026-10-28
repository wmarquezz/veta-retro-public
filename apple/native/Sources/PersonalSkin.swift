import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers

extension UTType {
    static let vetaSkin = UTType(exportedAs:"com.krafify.vetaretro.skin",conformingTo:.json)
}
enum PersonalSkinError:Error,LocalizedError {
    case invalid,image,proportion,name,storage
    var errorDescription:String? {let key:String = switch self {
    case .invalid:"El archivo no es un skin VETA válido o pertenece a otra consola."
    case .image:"Usa una imagen PNG, JPEG o HEIC de hasta 16 MB y 16 megapíxeles."
    case .proportion:"La imagen debe tener la misma proporción que el control. Usa control.png de la plantilla, no la vista completa."
    case .name:"Escribe un nombre de entre 1 y 64 caracteres."
    case .storage:"No se pudo acceder a este skin. Tus diseños anteriores se conservan."
    };return L10n.text(key)}
}
struct PersonalSkinVariant:Codable,Equatable {
    var layout:ControllerSkinLayout
    var imagePNG:Data
    // Immutable source layers. Editing the layout never repeatedly resamples art.
    var artwork:PersonalSkinArtwork? = nil
    var procedural:Bool? = nil
    func validated(console:GameConsole)throws {
        try layout.validated(console:console,orientation:layout.orientation)
        let dimensions=try PersonalSkinImage.dimensions(imagePNG,pngOnly:true)
        try PersonalSkinImage.validateProportion(dimensions,canvas:layout.canvas)
        _ = try PersonalSkinImage.decoded(imagePNG)
        if let artwork {try artwork.validated(for:layout,console:console)}
        guard !(procedural == true && artwork != nil) else{throw PersonalSkinError.invalid}
    }
}
/// Background and individual control sprites share one reference canvas.
/// Bundled skins supply clean layers; a flat imported PNG is split once, locally.
struct PersonalSkinArtwork:Codable,Equatable {
    var layout:ControllerSkinLayout
    var backgroundPNG:Data
    var controlsPNG:[String:Data]
    func validated(for target:ControllerSkinLayout,console:GameConsole)throws {
        try layout.validated(console:console,orientation:target.orientation)
        guard layout.canvas == target.canvas,Set(controlsPNG.keys)==Set(target.controls.map(\.id)) else{throw PersonalSkinError.invalid}
        try PersonalSkinImage.validateProportion(PersonalSkinImage.dimensions(backgroundPNG,pngOnly:true),canvas:layout.canvas)
        var pixels=0.0
        for c in layout.controls {
            guard let data=controlsPNG[c.id] else{throw PersonalSkinError.invalid}
            let size=try PersonalSkinImage.dimensions(data,pngOnly:true)
            pixels+=size.width*size.height
            guard pixels<=16_000_000 else{throw PersonalSkinError.image}
            try PersonalSkinImage.validateProportion(size,canvas:c.rect(in:layout.canvas).size)
        }
    }
    @MainActor static func split(_ image:UIImage,layout:ControllerSkinLayout)throws->Self {
        let format=UIGraphicsImageRendererFormat();format.scale=3;format.opaque=false
        var sprites:[String:Data]=[:]
        for c in layout.controls {
            let rect=c.rect(in:layout.canvas)
            sprites[c.id]=UIGraphicsImageRenderer(size:rect.size,format:format).pngData{_ in
                image.draw(in:CGRect(origin:CGPoint(x:-rect.minX,y:-rect.minY),size:layout.canvas))
            }
        }
        // A flattened import has no hidden background. Remove old controls using
        // the surrounding edge colour (transparent art stays transparent).
        let background=UIGraphicsImageRenderer(size:layout.canvas,format:format).pngData{context in
            image.draw(in:CGRect(origin:.zero,size:layout.canvas))
            for c in layout.controls {
                let rect=c.rect(in:layout.canvas)
                let sampleFormat=UIGraphicsImageRendererFormat();sampleFormat.scale=1;sampleFormat.preferredRange = .standard
                let sample=UIGraphicsImageRenderer(size:CGSize(width:1,height:1),format:sampleFormat).image{_ in
                    image.draw(in:CGRect(x:-max(0,rect.minX-1),y:-max(0,rect.minY-1),width:layout.canvas.width,height:layout.canvas.height))
                }
                context.cgContext.clear(rect)
                sample.draw(in:rect)
            }
        }
        return Self(layout:layout,backgroundPNG:background,controlsPNG:sprites)
    }
}
extension PersonalSkinVariant {
    @MainActor func editable()throws->Self {
        if artwork != nil || procedural == true{return self}
        var copy=self
        if let console=GameConsole(rawValue:layout.console),
           let base=StudioSkins.variant(console:console,orientation:layout.orientation),base.imagePNG==imagePNG,base.artwork != nil {
            // Recover edits saved by older versions: their PNG is still the
            // original Estudio image, while their layout already contains edits.
            copy.artwork=base.artwork
        } else if let console=GameConsole(rawValue:layout.console),layout.palette != .studio,
                  let base=try? PersonalSkinLibrary.generated(console:console,orientation:layout.orientation,palette:layout.palette),base.imagePNG==imagePNG {
            copy.procedural=true
        } else {copy.artwork=try PersonalSkinArtwork.split(PersonalSkinImage.decoded(imagePNG),layout:layout)}
        return copy
    }
    @MainActor func renderedImage()throws->UIImage {
        let format=UIGraphicsImageRendererFormat();format.scale=3;format.opaque=false
        if procedural == true,let console=GameConsole(rawValue:layout.console) {
            let deck=TouchDeck(frame:CGRect(origin:.zero,size:layout.canvas));var style=ControlStyle(console:console,defaults:nil);style.skin=layout.palette.rawValue
            deck.style=style;deck.landscape=layout.orientation == .landscape;deck.customLayout=layout;deck.layoutIfNeeded()
            return UIGraphicsImageRenderer(size:layout.canvas,format:format).image{context in
                if layout.orientation == .portrait && layout.palette != .transparent {style.background.setFill();context.fill(deck.bounds)}
                deck.draw(deck.bounds)
            }
        }
        guard let artwork else{return try PersonalSkinImage.decoded(imagePNG)}
        let background=try PersonalSkinImage.decoded(artwork.backgroundPNG)
        let sprites=try artwork.controlsPNG.mapValues{try PersonalSkinImage.decoded($0)}
        return UIGraphicsImageRenderer(size:layout.canvas,format:format).image{_ in
            background.draw(in:CGRect(origin:.zero,size:layout.canvas))
            for c in layout.controls {sprites[c.id]?.draw(in:c.rect(in:layout.canvas))}
        }
    }
}
struct PersonalSkin:Codable,Equatable,Identifiable {
    static let byteLimit=24*1024*1024
    var format="veta-personal-skin"
    var version=1
    var id=UUID().uuidString
    var name:String
    var console:String
    var variants:[PersonalSkinVariant]
    func variant(_ orientation:ControllerSkinOrientation)->PersonalSkinVariant? {variants.first{$0.layout.orientation == orientation}}
    mutating func set(_ variant:PersonalSkinVariant) {
        variants.removeAll{$0.layout.orientation == variant.layout.orientation};variants.append(variant)
    }
    func validated(console expected:GameConsole? = nil)throws {
        guard format == "veta-personal-skin",version == 1,UUID(uuidString:id) != nil,
              let console=GameConsole(rawValue:console),GameConsole.allCases.contains(console),expected == nil || expected == console,
              (1...2).contains(variants.count),Set(variants.map{$0.layout.orientation}).count == variants.count else{throw PersonalSkinError.invalid}
        guard (1...64).contains(name.trimmingCharacters(in:.whitespacesAndNewlines).count),
              !name.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else{throw PersonalSkinError.name}
        for v in variants {try v.validated(console:console)}
    }
    func encoded()throws->Data {
        try validated();let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let data=try encoder.encode(self);guard data.count<=Self.byteLimit else{throw PersonalSkinError.invalid};return data
    }
    static func decode(_ data:Data,console:GameConsole? = nil)throws->Self {
        guard !data.isEmpty,data.count<=byteLimit else{throw PersonalSkinError.invalid}
        let skin:Self
        do {skin=try JSONDecoder().decode(Self.self,from:data)}catch{throw PersonalSkinError.invalid}
        try skin.validated(console:console);return skin
    }
    static func read(_ url:URL,console:GameConsole)throws->Self {
        try decode(PersonalSkinImage.read(url,limit:byteLimit),console:console)
    }
}
enum PersonalSkinImage {
    static let inputLimit=16*1024*1024
    static let pngLimit=8*1024*1024
    private static func completePNG(_ data:Data)->Bool {
        guard data.starts(with:[137,80,78,71,13,10,26,10]) else{return false}
        var offset=8,first=true
        while offset+12<=data.count {
            let length=(0..<4).reduce(0){($0<<8)|Int(data[offset+$1])}
            guard length<=data.count-offset-12 else{return false}
            let type=String(bytes:data[(offset+4)..<(offset+8)],encoding:.ascii)
            if first && (type != "IHDR" || length != 13){return false};first=false
            if type == "acTL"{return false}
            offset+=12+length
            if type == "IEND"{return length==0 && offset==data.count}
        }
        return false
    }
    static func read(_ url:URL,limit:Int)throws->Data {
        guard url.isFileURL else{throw PersonalSkinError.invalid}
        let scoped=url.startAccessingSecurityScopedResource();defer{if scoped{url.stopAccessingSecurityScopedResource()}}
        let info=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard info.isRegularFile == true,info.isSymbolicLink != true,let size=info.fileSize,size>0,size<=limit else{throw PersonalSkinError.invalid}
        let handle=try FileHandle(forReadingFrom:url);defer{try? handle.close()}
        let data=try handle.read(upToCount:limit+1) ?? Data();guard !data.isEmpty,data.count<=limit else{throw PersonalSkinError.invalid};return data
    }
    static func dimensions(_ data:Data,pngOnly:Bool=false)throws->CGSize {
        guard !data.isEmpty,data.count<=(pngOnly ? pngLimit:inputLimit),
              let source=CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),CGImageSourceGetCount(source)==1,CGImageSourceGetStatus(source) == .statusComplete,
              let type=CGImageSourceGetType(source) as String?,
              (pngOnly ? ["public.png"]:["public.png","public.jpeg","public.heic"]).contains(type),
              let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let w=properties[kCGImagePropertyPixelWidth] as? NSNumber,let h=properties[kCGImagePropertyPixelHeight] as? NSNumber,
              w.doubleValue>=44,h.doubleValue>=44,w.doubleValue<=8192,h.doubleValue<=8192,
              w.doubleValue*h.doubleValue<=16_000_000 else{throw PersonalSkinError.image}
        guard type != "public.png" || completePNG(data),
              type != "public.jpeg" || data.suffix(2)==Data([255,217]) else{throw PersonalSkinError.image}
        return CGSize(width:w.doubleValue,height:h.doubleValue)
    }
    static func validateProportion(_ size:CGSize,canvas:CGSize)throws {
        guard abs((size.width/size.height)/(canvas.width/canvas.height)-1)<0.015 else{throw PersonalSkinError.proportion}
    }
    static func normalized(_ data:Data,canvas:CGSize)throws->Data {
        _ = try dimensions(data)
        guard let source=CGImageSourceCreateWithData(data as CFData,nil),
              let cg=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:3072,kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else{throw PersonalSkinError.image}
        try validateProportion(CGSize(width:cg.width,height:cg.height),canvas:canvas)
        guard let result=UIImage(cgImage:cg).pngData(),result.count<=pngLimit else{throw PersonalSkinError.image}
        return result
    }
    static func decoded(_ data:Data)throws->UIImage {
        _ = try dimensions(data,pngOnly:true)
        guard let source=CGImageSourceCreateWithData(data as CFData,nil),
              let cg=CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else{throw PersonalSkinError.image}
        return UIImage(cgImage:cg)
    }
}
/// Matching transforms for artwork and touch centers. Landscape keeps side panels
/// at their reference width, scaling the center. Minimum hit areas may expand to44pt;
/// geometry validation rejects overlaps instead of moving invisible buttons.
enum PersonalSkinGeometry {
    static func imageRect(canvas:CGSize,in size:CGSize)->CGRect {
        let scale=min(size.width/canvas.width,size.height/canvas.height)
        return CGRect(x:(size.width-canvas.width*scale)/2,y:(size.height-canvas.height*scale)/2,width:canvas.width*scale,height:canvas.height*scale)
    }
    private static func mapX(_ x:CGFloat,canvas:CGSize,size:CGSize)->CGFloat {
        let rail=ControllerSkinGeometry.overlayRail(canvas)
        if x<=rail{return x}
        if x>=canvas.width-rail{return size.width-(canvas.width-x)}
        return rail+(x-rail)*(size.width-2*rail)/(canvas.width-2*rail)
    }
    static func draw(_ image:UIImage,layout:ControllerSkinLayout,size:CGSize) {
        guard layout.orientation == .landscape,let context=UIGraphicsGetCurrentContext() else {
            image.draw(in:imageRect(canvas:layout.canvas,in:size));return
        }
        let canvas=layout.canvas,rail=ControllerSkinGeometry.overlayRail(canvas)
        let sy=min(1,size.height/canvas.height),y=(size.height-canvas.height*sy)/2
        for (left,right) in [(CGFloat(0),rail),(rail,canvas.width-rail),(canvas.width-rail,canvas.width)] {
            let x=mapX(left,canvas:canvas,size:size),end=mapX(right,canvas:canvas,size:size),sx=(end-x)/(right-left)
            context.saveGState();context.clip(to:CGRect(x:x,y:y,width:end-x,height:canvas.height*sy))
            image.draw(in:CGRect(x:x-left*sx,y:y,width:canvas.width*sx,height:canvas.height*sy));context.restoreGState()
        }
    }
    static func resolved(_ layout:ControllerSkinLayout,console:GameConsole,size:CGSize)throws->[String:CGRect] {
        try layout.validated(console:console,orientation:layout.orientation)
        guard size.width.isFinite,size.height.isFinite,size.width>=44,size.height>=44 else{throw ControllerSkinError.tooSmall}
        let image=imageRect(canvas:layout.canvas,in:size)
        var result:[String:CGRect]=[:]
        for c in layout.controls {
            var r=c.rect(in:image.size).offsetBy(dx:image.minX,dy:image.minY)
            if layout.orientation == .landscape {
                let rail=ControllerSkinGeometry.overlayRail(layout.canvas)
                guard size.width>2*rail+44 else{throw ControllerSkinError.tooSmall}
                let source=c.rect(in:layout.canvas),sy=min(1,size.height/layout.canvas.height)
                let x=mapX(source.minX,canvas:layout.canvas,size:size),end=mapX(source.maxX,canvas:layout.canvas,size:size)
                r=CGRect(x:x,y:(size.height-layout.canvas.height*sy)/2+source.minY*sy,width:end-x,height:source.height*sy)
            }
            let w=max(44,r.width),h=max(44,r.height)
            result[c.id]=CGRect(x:max(0,min(size.width-w,r.midX-w/2)),y:max(0,min(size.height-h,r.midY-h/2)),width:w,height:h)
        }
        // The reference layout already restricts game-area intrusion. Letterbox
        // transforms can move the lower utility row above the device's bottom;
        // validate actual bounds/overlaps and the real menu, not legacy rails.
        try ControllerSkinGeometry.validate(result,size:size,orientation:.portrait)
        if layout.orientation == .landscape {
            let menu=CGRect(x:size.width/2-44,y:0,width:88,height:44)
            for rect in result.values {let overlap=rect.intersection(menu);if !overlap.isNull && overlap.width>0.01 && overlap.height>0.01 {throw ControllerSkinError.overlap}}
        }
        return result
    }
}
