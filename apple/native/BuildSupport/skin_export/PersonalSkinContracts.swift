import UIKit
import Foundation

@main struct Contracts {
    @MainActor static func main() throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let suite="VetaPersonalSkinContracts."+UUID().uuidString,otherSuite=suite+".other"
        let defaults=UserDefaults(suiteName:suite)!,otherDefaults=UserDefaults(suiteName:otherSuite)!
        defer{defaults.removePersistentDomain(forName:suite);otherDefaults.removePersistentDomain(forName:otherSuite)}
        var checks=0,geometryFailures:[String]=[]
        func check(_ value:Bool,_ label:String) {precondition(value,label);checks+=1}
        func rejects(_ label:String,_ body:()throws->Void){do{try body();fatalError("Accepted: "+label)}catch{checks+=1}}
        let lib=PersonalSkinLibrary(root:root.appendingPathComponent("mine"),defaults:defaults)
        let other=PersonalSkinLibrary(root:root.appendingPathComponent("other"),defaults:otherDefaults)
        var fixture:PersonalSkin!
        for console in GameConsole.allCases {
            var variants:[PersonalSkinVariant]=[]
            for orientation in ControllerSkinOrientation.allCases {
                let v=try PersonalSkinLibrary.generated(console:console,orientation:orientation,palette:.veta);variants.append(v)
                let image=try PersonalSkinImage.decoded(v.imagePNG)
                let deck=TouchDeck(frame:CGRect(origin:.zero,size:v.layout.canvas));deck.style=ControlStyle(console:console,defaults:nil);deck.landscape=orientation == .landscape;deck.customLayout=v.layout;deck.customArtwork=image;deck.layoutIfNeeded()
                check(deck.layoutIssue==nil,"reference artwork geometry")
                for (id,rect) in deck.zones where !["SELECT","dpad","stick0","stick1"].contains(id) {
                    check(deck.inputMask(at:CGPoint(x:rect.midX,y:rect.midY)) == console.buttonMask(id),"button hit \(console.rawValue)/\(id)")
                }
                if let pad=deck.zones["dpad"] {check(deck.inputMask(at:CGPoint(x:pad.midX,y:pad.minY+pad.height*0.1)) & (1<<4) != 0,"dpad up")}
                for size in (orientation == .portrait ? [CGSize(width:393,height:console == .threeDS ? 240:max(console.minimumDeck,393*0.69)),CGSize(width:390,height:console == .threeDS ? 240:max(console.minimumDeck,390*0.69))]:[CGSize(width:734,height:359),CGSize(width:746,height:356),CGSize(width:1000,height:700)]) {
                    do{
                        let mapped=try PersonalSkinGeometry.resolved(v.layout,console:console,size:size);check(mapped.values.allSatisfy{$0.width>=44 && $0.height>=44},"44pt mapping")
                        let fmt=UIGraphicsImageRendererFormat();fmt.scale=1;fmt.opaque=true;fmt.preferredRange = .standard
                        let markers=UIGraphicsImageRenderer(size:v.layout.canvas,format:fmt).image{context in
                            UIColor.black.setFill();context.fill(CGRect(origin:.zero,size:v.layout.canvas))
                            UIColor.white.setFill()
                            for c in v.layout.controls {let r=c.rect(in:v.layout.canvas);context.fill(CGRect(x:r.midX-5,y:r.midY-5,width:10,height:10))}
                        }
                        let rendered=UIGraphicsImageRenderer(size:size,format:fmt).image{context in
                            UIColor.black.setFill();context.fill(CGRect(origin:.zero,size:size));PersonalSkinGeometry.draw(markers,layout:v.layout,size:size)
                        }
                        let cg=rendered.cgImage!,pixels=CFDataGetBytePtr(cg.dataProvider!.data!)!
                        for (id,r) in mapped {
                            let offset=Int(r.midY)*cg.bytesPerRow+Int(r.midX)*4
                            check(pixels[offset]>200 && pixels[offset+1]>200 && pixels[offset+2]>200,"artwork pixel matches touch center: \(console)/\(orientation)/\(size)/\(id) bpp\(cg.bitsPerPixel) at\(offset) RGB\(pixels[offset]),\(pixels[offset+1]),\(pixels[offset+2])")
                        }
                        if console == .ps2 && orientation == .landscape && size.width==734 {
                            let rendered=UIGraphicsImageRenderer(size:size,format:fmt).pngData{context in
                                UIColor.black.setFill();context.fill(CGRect(origin:.zero,size:size));PersonalSkinGeometry.draw(image,layout:v.layout,size:size)
                            };try rendered.write(to:root.appendingPathComponent("ps2-horizontal-734.png"))
                        }
                    }
                    catch{geometryFailures.append("\(console.rawValue)/\(orientation.rawValue)/\(size): \(error)")}
                }
            }
            let skin=PersonalSkin(name:"Personal \(console.name)",console:console.rawValue,variants:variants)
            let data=try skin.encoded(),decoded=try PersonalSkin.decode(data,console:console)
            check(decoded==skin,"package round trip")
            try lib.save(skin);try lib.select(skin,orientation:.portrait)
            check(lib.selectedID(console:console,orientation:.portrait)==skin.id,"portrait selected")
            check(lib.selectedID(console:console,orientation:.landscape)==nil,"orientation independent")
            check(other.selected(console:console,orientation:.portrait)==nil,"user installation isolated")
            let reopened=PersonalSkinLibrary(root:lib.root,defaults:defaults)
            check(try reopened.load(skin.id)==skin,"disk reload")
            if console == .nes {fixture=skin}
        }
        let applied=TouchDeck(frame:CGRect(x:0,y:0,width:400,height:276))
        applied.applySkin(console:.nes,landscape:false,defaults:defaults,personalLibrary:lib);applied.layoutIfNeeded()
        check(applied.customArtwork != nil && applied.customLayout==fixture.variant(.portrait)!.layout,"runtime applies local selected art")
        var releases=0;applied.onInput={if $0==0{releases+=1}}
        for _ in 0..<100 {applied.applySkin(console:.nes,landscape:false,defaults:defaults,personalLibrary:lib);applied.layoutIfNeeded()}
        check(releases==0,"repeated layouts do not release held controls")
        let importedPNG=try PersonalSkinImage.normalized(fixture.variants[0].imagePNG,canvas:fixture.variants[0].layout.canvas)
        check(try PersonalSkinImage.dimensions(importedPNG,pngOnly:true)==PersonalSkinImage.dimensions(fixture.variants[0].imagePNG,pngOnly:true),"PNG import preserves dimensions")
        let jpeg=try PersonalSkinImage.decoded(importedPNG).jpegData(compressionQuality:0.9)!
        let normalizedJPEG=try PersonalSkinImage.normalized(jpeg,canvas:fixture.variants[0].layout.canvas)
        check(try PersonalSkinImage.dimensions(normalizedJPEG,pngOnly:true).width>0,"JPEG import normalized to PNG")
        rejects("wrong image proportion"){_ = try PersonalSkinImage.normalized(importedPNG,canvas:CGSize(width:844,height:320))}
        rejects("truncated PNG"){_ = try PersonalSkinImage.normalized(importedPNG.prefix(importedPNG.count/2),canvas:fixture.variants[0].layout.canvas)}
        let original=try fixture.encoded()
        var bad=fixture!;bad.version=99;rejects("wrong version"){_ = try bad.encoded()}
        bad=fixture;bad.name="\n";rejects("invalid name"){try lib.save(bad)}
        bad=fixture;bad.id="../../not-allowed";rejects("path traversal"){try lib.save(bad)}
        bad=fixture;bad.variants[0].imagePNG=Data([1,2,3]);rejects("corrupt image"){try lib.save(bad)}
        bad=fixture;bad.variants[0].layout.controls[0].x=1;rejects("out of bounds"){try lib.save(bad)}
        bad=fixture;bad.variants.append(bad.variants[0]);rejects("duplicate orientation"){try lib.save(bad)}
        rejects("foreign console"){_ = try PersonalSkin.decode(original,console:.wii)}
        rejects("truncated package"){_ = try PersonalSkin.decode(original.prefix(100))}
        rejects("oversize"){_ = try PersonalSkin.decode(Data(repeating:32,count:PersonalSkin.byteLimit+1))}
        let retained=try lib.load(fixture.id).encoded();check(retained==original,"failed import preserves original")
        let copied=try lib.imported(fixture,console:.nes);check(copied.id != fixture.id,"import gets separate identity")
        try lib.save(copied);try lib.select(copied,orientation:.landscape)
        check(lib.selectedID(console:.nes,orientation:.portrait)==fixture.id,"second selection preserves first")
        try lib.delete(copied);check(lib.selectedID(console:.nes,orientation:.landscape)==nil,"delete active falls back")
        check(try lib.load(fixture.id).encoded()==original,"delete keeps other designs")
        lib.useOriginal(console:.nes,orientation:.portrait);check(lib.selected(console:.nes,orientation:.portrait)==nil,"original restored")
        check(try lib.load(fixture.id).encoded()==original,"restore doesn't erase skin")
        let link=root.appendingPathComponent("linked.vetaskin");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:lib.root.appendingPathComponent(fixture.id+".vetaskin"))
        rejects("symlink import"){_ = try PersonalSkin.read(link,console:.nes)}
        precondition(geometryFailures.isEmpty,"device geometry must fit")
        let summary:[String:Any]=["checks":checks,"geometryFailures":geometryFailures,"consoles":20,"orientations":40,"scope":"production Swift with UIKit simulator, isolated storage; no physical game"]
        try JSONSerialization.data(withJSONObject:summary,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("result.json"))
        print("PERSONAL SKINS: \(checks) passed; geometry failures: \(geometryFailures.count)")
        for f in geometryFailures{print(f)}
    }
}
