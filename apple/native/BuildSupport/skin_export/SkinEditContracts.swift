import UIKit
import Foundation
@main struct EditContracts {
 @MainActor static func main() throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  let suite="SkinEdits."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
  defer{defaults.removePersistentDomain(forName:suite)}
  var checks=0,failures:[String]=[],cases=0
  func check(_ value:Bool,_ name:String){checks+=1;if !value{failures.append(name)}}
  func changed(_ layout:ControllerSkinLayout)throws->ControllerSkinLayout {
   // Move and resize a real input while keeping every target valid.
   for index in layout.controls.indices {
    let r=layout.controls[index].rect(in:layout.canvas)
    for delta in [CGFloat(8),-8,4,-4] {
     var v=layout
     v.controls[index]=ControllerSkinControl(id:v.controls[index].id,rect:CGRect(x:r.minX+delta,y:r.minY,width:r.width+4,height:r.height+4),canvas:v.canvas)
     if (try? v.validated(console:GameConsole(rawValue:v.console)!,orientation:v.orientation)) != nil{return v}
    }
   }
   throw ControllerSkinError.invalid
  }
  func rendered(_ deck:TouchDeck)->Data {
   let f=UIGraphicsImageRendererFormat();f.scale=1;f.preferredRange = .standard
   return UIGraphicsImageRenderer(size:deck.bounds.size,format:f).pngData{_ in deck.draw(deck.bounds)}
  }
  let lib=PersonalSkinLibrary(root:root.appendingPathComponent("skins"),defaults:defaults)
  for console in GameConsole.allCases {for orientation in ControllerSkinOrientation.allCases {for palette in ControllerSkinPalette.allCases {
   let tag="\(console.rawValue)/\(orientation)/\(palette)"
   var v=try PersonalSkinLibrary.generated(console:console,orientation:orientation,palette:palette).editable()
   let original=v;let before=try v.renderedImage().pngData()!
   v.layout=try changed(v.layout)
   let after=try v.renderedImage().pngData()!
   check(before != after,"visual image changes with size and position \(tag)")
   let skin=PersonalSkin(name:tag,console:console.rawValue,variants:[v]);try lib.save(skin);try lib.select(skin,orientation:orientation)
   let reload=PersonalSkinLibrary(root:lib.root,defaults:defaults)
   let loaded=try reload.load(skin.id)
   check(loaded==skin,"save and reopen \(tag)")
   let deck=TouchDeck(frame:CGRect(origin:.zero,size:v.layout.canvas))
   deck.applySkin(console:console,landscape:orientation == .landscape,defaults:defaults,personalLibrary:reload);deck.layoutIfNeeded()
   check(deck.customLayout==v.layout && deck.layoutIssue==nil,"game deck uses saved layout \(tag)")
   check(deck.customArtwork?.pngData()==after,"game deck uses changed image \(tag)")
   for c in v.layout.controls {let r=c.rect(in:v.layout.canvas);check(deck.zones[c.id]!.contains(CGPoint(x:r.midX,y:r.midY)),"hit and art coincide \(tag)/\(c.id)")}
   let active=rendered(deck)
   var again=v;again.layout=original.layout;var updated=skin;updated.set(again);try lib.save(updated)
   deck.applySkin(console:console,landscape:orientation == .landscape,defaults:defaults,personalLibrary:lib);deck.layoutIfNeeded()
   check(rendered(deck) != active,"cache refresh on re-save \(tag)")
   var legacy=v;legacy.artwork=nil;legacy.procedural=nil
   check(try legacy.editable().renderedImage().pngData()==after,"legacy saved layout recovered \(tag)")
   if palette == .studio {
    try after.write(to:root.appendingPathComponent("\(console.rawValue)-\(orientation.rawValue)-edited.png"))
    // Source layers stay immutable and survive export/import.
    check(try PersonalSkin.decode(skin.encoded()).variants[0].artwork==original.artwork,"lossless source layers retained \(tag)")
   } else {
    lib.useOriginal(console:console,orientation:orientation)
    try ControllerSkinStore(defaults:defaults).save(v.layout,console:console)
    deck.customArtwork=nil;deck.applySkin(console:console,landscape:orientation == .landscape,defaults:defaults,personalLibrary:lib);deck.layoutIfNeeded()
    check(deck.customLayout==v.layout && deck.layoutIssue==nil,"included layout save applied \(tag)")
    ControllerSkinStore(defaults:defaults).reset(console:console,orientation:orientation)
   }
   cases+=1
  }}}
  // Imported flat PNG: move one isolated coloured input; its old position clears.
  let base=ControllerSkinLayout.makeDefault(console:.nes,orientation:.portrait,palette:.transparent)
  let f=UIGraphicsImageRendererFormat();f.scale=3;f.opaque=false
  let png=UIGraphicsImageRenderer(size:base.canvas,format:f).pngData{context in
   UIColor.red.setFill();for c in base.controls{context.fill(c.rect(in:base.canvas).insetBy(dx:8,dy:8))}
  }
  var flat=try PersonalSkinVariant(layout:base,imagePNG:png).editable();let original=try flat.renderedImage().pngData();flat.layout=try changed(base)
  check(try flat.renderedImage().pngData() != original,"imported PNG moves visible art")
  check(try PersonalSkin.decode(PersonalSkin(name:"Imported",console:"nes",variants:[flat]).encoded()).variants[0]==flat,"imported layer roundtrip")
  // Optional private reproduction, never copied into public fixtures or sources.
  if CommandLine.arguments.count>2 {
   let skin=try PersonalSkin.decode(Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2])))
   for v in skin.variants {
    let edited=try v.editable();try edited.renderedImage().pngData()!.write(to:root.appendingPathComponent("user-\(v.layout.orientation.rawValue).png"))
    for width in [CGFloat(375),393,414] where v.layout.orientation == .portrait {
     let size=CGSize(width:width,height:width/400*v.layout.canvas.height)
     let mapped=try PersonalSkinGeometry.resolved(edited.layout,console:.nes,size:size)
     check(mapped.count==v.layout.controls.count,"user saved targets fit \(width)")
    }
    check(edited.layout==v.layout,"user edits preserved")
   }
  }
  let data=try JSONSerialization.data(withJSONObject:["checks":checks,"cases":cases,"failures":failures],options:.prettyPrinted);try data.write(to:root.appendingPathComponent("result.json"))
  print("SKIN EDITS: \(checks) checks, \(cases) console/orientation/palette cases, failures: \(failures)")
  if !failures.isEmpty{exit(1)}
 }
}
