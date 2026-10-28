import UIKit
import CoreText

@main struct ExportSkins {
    @MainActor static func main() throws {
        let out=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        let fonts=URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
        for name in ["BarlowCondensed-Bold.ttf","Manrope.ttf"] {CTFontManagerRegisterFontsForURL(fonts.appendingPathComponent(name) as CFURL,.process,nil)}
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        var manifest:[[String:Any]]=[]
        func save(_ url:URL,size:CGSize,transparent:Bool=false,draw:(CGContext)->Void)throws {
            let format=UIGraphicsImageRendererFormat();format.scale=3;format.opaque = !transparent
            let data=UIGraphicsImageRenderer(size:size,format:format).pngData {draw($0.cgContext)}
            try data.write(to:url)
        }
        for console in GameConsole.allCases {
            for orientation in ControllerSkinOrientation.allCases {
                let landscape=orientation == .landscape
                let palette:ControllerSkinPalette=console == .nes ? .veta:.classic
                let model=ControllerSkinLayout.makeDefault(console:console,orientation:orientation,palette:palette)
                try model.validated(console:console,orientation:orientation)
                let folderName="\(landscape ? "02-horizontal":"01-vertical")/\(console.rawValue)"
                let folder=out.appendingPathComponent(folderName,isDirectory:true)
                try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                try model.encoded().write(to:folder.appendingPathComponent("distribucion.json"))
                let size=model.canvas
                let deck=TouchDeck(frame:CGRect(origin:.zero,size:size))
                var style=ControlStyle(console:console,defaults:nil);style.skin=palette.rawValue
                deck.style=style;deck.landscape=landscape;deck.customLayout=model;deck.layoutIfNeeded()
                guard deck.layoutIssue == nil,deck.zones.count == model.controls.count else{fatalError("Invalid \(console.rawValue) \(orientation)")}
                for c in model.controls {let actual=deck.zones[c.id]!,expected=c.rect(in:size);precondition(abs(actual.minX-expected.minX)<0.001 && abs(actual.minY-expected.minY)<0.001 && abs(actual.width-expected.width)<0.001 && abs(actual.height-expected.height)<0.001,"Export differs from input map")}
                for p in ControllerSkinPalette.allCases {
                    style.skin=p.rawValue;deck.style=style;deck.layoutIfNeeded()
                    let slug:[ControllerSkinPalette:String]=[.classic:"clasica",.veta:"veta",.night:"noche",.transparent:"transparente"]
                    try save(folder.appendingPathComponent("variante-\(slug[p]!).png"),size:size,transparent:p == .transparent || landscape) {ctx in
                        if !landscape && p != .transparent {style.background.setFill();ctx.fill(CGRect(origin:.zero,size:size))}
                        deck.draw(deck.bounds)
                    }
                }
                style.skin=palette.rawValue;deck.style=style;deck.layoutIfNeeded()
                try save(folder.appendingPathComponent("control.png"),size:size,transparent:landscape) {ctx in
                    if !landscape {style.background.setFill();ctx.fill(CGRect(origin:.zero,size:size))}
                    deck.draw(deck.bounds)
                }
                deck.showsTouchTargets=true
                try save(folder.appendingPathComponent("areas-tactiles.png"),size:size) {ctx in
                    UIColor(hex:0x18212a).setFill();ctx.fill(CGRect(origin:.zero,size:size));deck.draw(deck.bounds)
                }
                deck.showsTouchTargets=false
                // Reference phone geometry, not a screen capture of a user's device.
                let phone=landscape ? CGSize(width:844,height:390):CGSize(width:400,height:866)
                let safe=landscape ? CGRect(x:0,y:35,width:844,height:320):CGRect(x:0,y:44,width:400,height:788)
                let aspect:CGFloat=console == .threeDS && landscape ? 3:console.aspect
                let layout=ConsoleLayout(safe:safe,aspect:aspect,minimumDeck:console.minimumDeck,compactDualScreen:console == .threeDS,overlayLandscape:landscape)
                let fullDeck=TouchDeck(frame:CGRect(origin:.zero,size:layout.deck.size));fullDeck.style=style;fullDeck.landscape=landscape;fullDeck.customLayout=model;fullDeck.layoutIfNeeded()
                precondition(fullDeck.layoutIssue == nil)
                let shell=ConsoleShellView(frame:CGRect(origin:.zero,size:phone));shell.style=style;shell.screenRect=layout.screen;shell.portraitSkinTop=landscape ? nil:layout.toolbar.minY
                try save(folder.appendingPathComponent("vista-completa.png"),size:phone) {ctx in
                    UIColor.black.setFill();ctx.fill(CGRect(origin:.zero,size:phone))
                    if !landscape {shell.draw(shell.bounds)}
                    // Neutral reserved picture area avoids including games or ROM art.
                    UIColor(hex:0x10171e).setFill();ctx.fill(layout.screen)
                    SkinDrawing.text("ÁREA DEL JUEGO",in:layout.screen,size:14,color:UIColor(hex:0x7e8b97))
                    ctx.saveGState();ctx.translateBy(x:layout.deck.minX,y:layout.deck.minY);fullDeck.draw(fullDeck.bounds);ctx.restoreGState()
                    if !landscape {SkinDrawing.text("VETA / \(console.shortName)",in:CGRect(x:layout.toolbar.minX+20,y:layout.toolbar.minY,width:185,height:44),size:17,color:style.headerInk,font:"BarlowCondensed-Bold")}
                    let menu=landscape ? layout.toolbar:CGRect(x:layout.toolbar.maxX-100,y:layout.toolbar.minY,width:80,height:44)
                    if landscape {UIColor.black.withAlphaComponent(0.4).setFill();UIBezierPath(roundedRect:menu,cornerRadius:8).fill()}
                    SkinDrawing.text("☰  Menú",in:menu,size:13,color:landscape ? .white:style.headerInk)
                }
                manifest.append(["console":console.rawValue,"name":console.name,"orientation":orientation.rawValue,"folder":folderName,"palette":palette.rawValue,"canvasPoints":[size.width,size.height],"pixelScale":3,"fullCanvasPoints":[phone.width,phone.height],"screenRectPoints":[layout.screen.minX,layout.screen.minY,layout.screen.width,layout.screen.height],"deckRectPoints":[layout.deck.minX,layout.deck.minY,layout.deck.width,layout.deck.height],"controls":model.controls.map { ["id":$0.id,"label":style.buttonLabel($0.id),"rectPoints":[$0.x*size.width,$0.y*size.height,$0.width*size.width,$0.height*size.height]] }])
                print("EXPORTED \(console.rawValue) \(orientation.rawValue)")
            }
        }
        let data=try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys]);try data.write(to:out.appendingPathComponent("manifest.json"))
        print("PASS: \(manifest.count) console/orientation exports, native render and matching input geometry")
    }
}
