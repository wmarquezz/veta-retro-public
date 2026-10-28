import UIKit
import Foundation
@main struct StudioContracts {
 @MainActor static func main() throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  var checks=0,failures:[String]=[]
  func check(_ value:Bool,_ label:String){checks+=1;if !value {failures.append(label)}}
  let suite="StudioContracts."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
  defer{defaults.removePersistentDomain(forName:suite)}
  check(GameConsole.allCases.count==19,"public console count")
  for console in GameConsole.allCases {
   guard let skin=StudioSkins.skin(console:console) else {failures.append("missing/invalid \(console)");continue}
   check(try PersonalSkin.decode(skin.encoded())==skin,"roundtrip \(console)")
   for orientation in ControllerSkinOrientation.allCases {
    let variant=skin.variant(orientation)!,art=StudioSkins.image(console:console,orientation:orientation)!,landscape=orientation == .landscape
    var sizes=[variant.layout.canvas]
    if landscape {sizes += [CGSize(width:667,height:354),CGSize(width:734,height:359),CGSize(width:746,height:356),CGSize(width:1000,height:700)]}
    else {sizes += [CGFloat(375),393,414,768].map {w in ConsoleLayout(safe:CGRect(x:0,y:0,width:w,height:w>500 ? 1000:759),aspect:console.aspect,minimumDeck:console.minimumDeck,compactDualScreen:variant.layout.usesCompactThreeDSCanvas,compactDS:variant.layout.usesCompactDSCanvas).deck.size}}
    for (i,size) in sizes.enumerated() {
     let tag="\(console.rawValue)/\(orientation)/\(size)"
     let deck=TouchDeck(frame:CGRect(origin:.zero,size:size));deck.applySkin(console:console,landscape:landscape,defaults:defaults);deck.layoutIfNeeded()
     check(deck.customLayout==variant.layout && deck.customArtwork != nil,"default skin \(tag)")
     check(deck.layoutIssue == nil,"geometry \(tag): \(deck.layoutIssue ?? "")")
     if deck.layoutIssue != nil {continue}
     for (id,rect) in deck.zones {
      check(rect.width>=44 && rect.height>=44,"minimum target \(tag)/\(id)")
      if !["SELECT","dpad","stick0","stick1"].contains(id){check(deck.inputMask(at:CGPoint(x:rect.midX,y:rect.midY))==console.buttonMask(id),"input \(tag)/\(id)")}
     }
     if let pad=deck.zones["dpad"]{check(deck.inputMask(at:CGPoint(x:pad.midX,y:pad.minY+pad.height*0.1)) & (1<<4) != 0,"dpad \(tag)")}
     let pixelFormat=UIGraphicsImageRendererFormat();pixelFormat.scale=1;pixelFormat.opaque=true;pixelFormat.preferredRange = .standard
     let markers=UIGraphicsImageRenderer(size:variant.layout.canvas,format:pixelFormat).image{context in
      UIColor.black.setFill();context.fill(CGRect(origin:.zero,size:variant.layout.canvas));UIColor.white.setFill()
      for c in variant.layout.controls {let r=c.rect(in:variant.layout.canvas);context.fill(CGRect(x:r.midX-3,y:r.midY-3,width:6,height:6))}
     }
     let mapped=UIGraphicsImageRenderer(size:size,format:pixelFormat).image{context in
      UIColor.black.setFill();context.fill(CGRect(origin:.zero,size:size));PersonalSkinGeometry.draw(markers,layout:variant.layout,size:size)
     }
     let cg=mapped.cgImage!,pixels=CFDataGetBytePtr(cg.dataProvider!.data!)!
     for (id,r) in deck.zones {
      let offset=Int(r.midY)*cg.bytesPerRow+Int(r.midX)*4
      check(pixels[offset]>200 && pixels[offset+1]>200 && pixels[offset+2]>200,"art maps to touch center \(tag)/\(id)")
     }
     var releases=0;deck.onInput={if $0==0{releases+=1}}
     for _ in 0..<3 {deck.applySkin(console:console,landscape:landscape,defaults:defaults);deck.layoutIfNeeded()}
     check(releases==0,"held input stable \(tag)")
     if console == .nes && !landscape {
      check(deck.zones["dpad"]!.width >= min(135,size.width*0.35),"NES enlarged dpad \(tag)")
      check(deck.zones["A"]!.width >= 70 && deck.zones["B"]!.width >= 70,"NES enlarged face keys \(tag)")
     }
     if landscape {
      func composed(_ color:UIColor)->UIImage {
       UIGraphicsImageRenderer(size:size,format:pixelFormat).image{context in color.setFill();context.fill(CGRect(origin:.zero,size:size));deck.draw(deck.bounds)}
      }
      let red=composed(.red).cgImage!,blue=composed(.blue).cgImage!
      let redPixels=CFDataGetBytePtr(red.dataProvider!.data!)!,bluePixels=CFDataGetBytePtr(blue.dataProvider!.data!)!
      for (id,zone) in deck.zones where id != "dpad" && !id.hasPrefix("stick") {
       let offset=Int(zone.midY)*red.bytesPerRow+Int(zone.midX)*4
       check((0..<3).allSatisfy{abs(Int(redPixels[offset+$0])-Int(bluePixels[offset+$0]))<4},"opaque button over game \(tag)/\(id)")
      }
      let center=Int(size.height/2)*red.bytesPerRow+Int(size.width/2)*4
      check((0..<3).contains{abs(Int(redPixels[center+$0])-Int(bluePixels[center+$0]))>200},"clear game center \(tag)")
     }
     if i==0 || i==1 {
      let f=UIGraphicsImageRendererFormat();f.scale=2;f.opaque=false;f.preferredRange = .standard
      let data=UIGraphicsImageRenderer(size:size,format:f).pngData{_ in deck.draw(deck.bounds)}
      try data.write(to:root.appendingPathComponent("\(console.rawValue)-\(orientation)-\(i).png"))
      let safe=landscape ? CGRect(x:0,y:0,width:size.width,height:size.height):CGRect(x:0,y:0,width:size.width,height:759)
      let layout=ConsoleLayout(safe:safe,aspect:console.aspect,minimumDeck:console.minimumDeck,compactDualScreen:variant.layout.usesCompactThreeDSCanvas,overlayLandscape:landscape,compactDS:variant.layout.usesCompactDSCanvas)
      let scene=UIGraphicsImageRenderer(size:safe.size,format:f).pngData{context in
       UIColor.black.setFill();context.fill(safe)
       context.cgContext.saveGState();context.cgContext.clip(to:layout.screen)
       for y in stride(from:layout.screen.minY,through:layout.screen.maxY,by:32) {
        for x in stride(from:layout.screen.minX,through:layout.screen.maxX,by:32) {
         UIColor(hex:(Int(x/32)+Int(y/32))%2==0 ? 0x56899e:0x254c68).setFill();context.fill(CGRect(x:x,y:y,width:32,height:32))
        }
       }
       context.cgContext.restoreGState()
       context.cgContext.saveGState();context.cgContext.translateBy(x:layout.deck.minX,y:layout.deck.minY)
       let composedDeck=TouchDeck(frame:CGRect(origin:.zero,size:layout.deck.size));composedDeck.applySkin(console:console,landscape:landscape,defaults:defaults);composedDeck.layoutIfNeeded();composedDeck.draw(composedDeck.bounds)
       context.cgContext.restoreGState()
      };try scene.write(to:root.appendingPathComponent("scene-\(console.rawValue)-\(orientation)-\(i).png"))
     }
     _ = art
    }
   }
  }
  // Contact sheets use the actual UIKit runtime renders, not ZIP presentation images.
  for o in ControllerSkinOrientation.allCases {
   let consoles=GameConsole.allCases,cell=CGSize(width:o == .portrait ? 300:420,height:o == .portrait ? 280:210),cols=4
   let size=CGSize(width:cell.width*CGFloat(cols),height:cell.height*CGFloat((consoles.count+cols-1)/cols))
   let format=UIGraphicsImageRendererFormat();format.scale=1;format.opaque=true;format.preferredRange = .standard
   let data=UIGraphicsImageRenderer(size:size,format:format).pngData{context in
    UIColor(white:0.06,alpha:1).setFill();context.fill(CGRect(origin:.zero,size:size))
    for (i,c) in consoles.enumerated() {
     let origin=CGPoint(x:CGFloat(i%cols)*cell.width,y:CGFloat(i/cols)*cell.height)
     (c.name as NSString).draw(at:CGPoint(x:origin.x+8,y:origin.y+6),withAttributes:[.font:UIFont.systemFont(ofSize:16),.foregroundColor:UIColor.white])
     if let image=UIImage(contentsOfFile:root.appendingPathComponent("\(c.rawValue)-\(o)-0.png").path) {
      let frame=CGRect(x:origin.x+8,y:origin.y+30,width:cell.width-16,height:cell.height-38),scale=min(frame.width/image.size.width,frame.height/image.size.height)
      image.draw(in:CGRect(x:frame.midX-image.size.width*scale/2,y:frame.midY-image.size.height*scale/2,width:image.size.width*scale,height:image.size.height*scale))
     }
    }
   };try data.write(to:root.appendingPathComponent("overview-\(o).png"))
  }
  // Existing choices stay selected; new art never overwrites a user's saved package.
  defaults.set("Noche",forKey:GameConsole.nes.preferencePrefix+"skin")
  let deck=TouchDeck(frame:CGRect(x:0,y:0,width:400,height:276));deck.applySkin(console:.nes,landscape:false,defaults:defaults);deck.layoutIfNeeded()
  check(deck.customArtwork == nil && deck.style.skin=="Noche","legacy style preserved")
  let ds=StudioSkins.variant(console:.ds,orientation:.portrait)!.layout
  check(ds.version==4 && ds.canvas==CGSize(width:400,height:188),"compact DS explicit version")
  var old=ds;old.version=1;check(old.canvas==CGSize(width:400,height:276),"legacy DS canvas preserved")
  let report:[String:Any]=["checks":checks,"failures":failures,"status":failures.isEmpty ? "PASS":"FAIL","consoles":19,"variants":38]
  try JSONSerialization.data(withJSONObject:report,options:.prettyPrinted).write(to:root.appendingPathComponent("result.json"))
  print(String(data:try JSONSerialization.data(withJSONObject:report,options:.prettyPrinted),encoding:.utf8)!)
  if !failures.isEmpty {exit(1)}
 }
}
