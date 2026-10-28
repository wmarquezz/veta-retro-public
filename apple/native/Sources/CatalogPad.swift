import UIKit

// Preview-only controllers for consoles whose native engine is not yet bundled.
// Their saved skin selection is ready for the future player, not an active core.
final class CatalogPad:UIView {
    var style=ControlStyle() {didSet{setNeedsDisplay()}}
    override init(frame:CGRect){super.init(frame:frame);isOpaque=false;backgroundColor = .clear}
    required init?(coder:NSCoder){fatalError()}
    override func draw(_ rect:CGRect) {
        guard let ctx=UIGraphicsGetCurrentContext() else{return}
        ctx.saveGState();ctx.scaleBy(x:bounds.width/400,y:bounds.height/276)
        let console=style.console,classic=style.skin == "Clásica",clear=style.skin == "Transparente"
        let fill=classic ? UIColor(hex:console.color):style.keyFill
        let ink=classic && [.ps1,.wii,.dreamcast,.pcEngine,.ds].contains(console) ? UIColor(hex:0x273641):style.glyph
        func shell(_ rect:CGRect) {
            if !clear {SkinDrawing.bevel(UIBezierPath(roundedRect:rect,cornerRadius:24),top:fill,bottom:fill.withAlphaComponent(0.65),edge:style.keyBorder,width:2,shadow:true)}
        }
        func key(_ name:String,_ x:CGFloat,_ y:CGFloat,_ size:CGFloat=38,_ color:UIColor?=nil) {
            let r=CGRect(x:x-size/2,y:y-size/2,width:size,height:size)
            SkinDrawing.bevel(UIBezierPath(ovalIn:r),top:color ?? style.actionColor(name),bottom:UIColor(hex:0x273343),edge:style.keyBorder,width:2,shadow:!clear)
            SkinDrawing.text(name,in:r,size:17,color:style.glyph)
        }
        func bar(_ title:String,_ x:CGFloat,_ y:CGFloat,_ w:CGFloat=48) {
            let r=CGRect(x:x-w/2,y:y-10,width:w,height:20)
            SkinDrawing.bevel(UIBezierPath(roundedRect:r,cornerRadius:8),top:style.keyFill,bottom:UIColor(hex:0x15232c),edge:style.keyBorder)
            SkinDrawing.text(title,in:r,size:9,color:style.glyph)
        }
        func cross(_ x:CGFloat,_ y:CGFloat) {
            let p=UIBezierPath();let unit:CGFloat=22
            let pts:[CGPoint]=[(1,0),(2,0),(2,1),(3,1),(3,2),(2,2),(2,3),(1,3),(1,2),(0,2),(0,1),(1,1)].map{CGPoint(x:x-33+CGFloat($0.0)*unit,y:y-33+CGFloat($0.1)*unit)}
            p.move(to:pts[0]);for point in pts.dropFirst(){p.addLine(to:point)};p.close()
            SkinDrawing.bevel(p,top:UIColor(hex:0x596675),bottom:UIColor(hex:0x15212c),edge:style.keyBorder,width:2,shadow:!clear)
        }
        func stick(_ x:CGFloat,_ y:CGFloat,_ color:UIColor=UIColor(hex:0x707987)) {
            let r=CGRect(x:x-26,y:y-26,width:52,height:52)
            SkinDrawing.bevel(UIBezierPath(ovalIn:r),top:UIColor(hex:0x202f3e),bottom:UIColor(hex:0x0d1723),edge:style.keyBorder,width:2)
            SkinDrawing.bevel(UIBezierPath(ovalIn:r.insetBy(dx:8,dy:8)),top:color,bottom:UIColor(hex:0x354354),edge:UIColor(hex:0x88939c),width:1,shadow:true)
        }
        if console == .wii {
            shell(CGRect(x:210,y:8,width:80,height:260));cross(250,65);key("A",250,125,34);bar("−   +",250,170,60);key("1",250,212,25);key("2",250,246,25)
            shell(CGRect(x:106,y:95,width:70,height:160));stick(141,135);bar("C / Z",141,195,58)
        } else if console == .atari2600 {
            shell(CGRect(x:80,y:42,width:240,height:200));key("FIRE",122,90,52,UIColor(hex:0xcc4949));stick(225,145)
            SkinDrawing.bevel(UIBezierPath(roundedRect:CGRect(x:215,y:65,width:20,height:80),cornerRadius:9),top:UIColor(hex:0x58616b),bottom:UIColor(hex:0x16222b),edge:style.keyBorder,width:2)
        } else {
            shell(CGRect(x:12,y:30,width:376,height:230))
            if [.ps1,.ps2,.psp,.n64,.gamecube,.ds,.threeDS,.saturn,.dreamcast].contains(console) {bar("L",65,32,70);bar("R",335,32,70)}
            if console != .gamecube {cross(85,122)}
            if console == .megaDrive || console == .saturn {
                for (i,name) in ["A","B","C"].enumerated(){key(name,255+CGFloat(i)*46,140-CGFloat(i)*12,38)}
                if console == .saturn {for (i,name) in ["X","Y","Z"].enumerated(){key(name,255+CGFloat(i)*46,88-CGFloat(i)*10,30)}}
                bar("START",192,125)
            } else if console == .n64 {
                stick(195,185);key("A",278,158,38,UIColor(hex:0x3677c3));key("B",251,115,33,UIColor(hex:0x41a17c))
                for (name,x,y) in [("↑",340.0,87.0),("↓",340.0,141.0),("←",313.0,114.0),("→",367.0,114.0)] {key(name,x,y,24,UIColor(hex:0xd5b943))}
                key("START",195,89,29,UIColor(hex:0xc85d63))
            } else if [.ps1,.ps2,.psp].contains(console) {
                for (name,x,y) in [("△",309.0,76.0),("×",309.0,160.0),("□",267.0,118.0),("○",351.0,118.0)] {key(name,x,y,35,UIColor(hex:0x414c60))}
                if console == .ps2 {stick(148,202);stick(247,202)}
                if console == .psp {stick(85,203)}
                bar("SELECT",175,120);bar("START",225,120)
            } else if console == .gamecube {
                stick(86,110);cross(123,190);bar("Z",345,61,38);key("A",310,128,54,UIColor(hex:0x4aad92));key("B",265,166,30,UIColor(hex:0xd55154));key("X",361,114,31);key("Y",309,73,31);stick(253,214,UIColor(hex:0xd7bc55));bar("START",195,115)
            } else if [.ds,.threeDS,.dreamcast].contains(console) {
                key("X",309,79);key("Y",267,121);key("A",351,121);key("B",309,163)
                if console == .threeDS || console == .dreamcast {stick(85,202)}
                bar("SELECT",177,218);bar("START",233,218)
            } else {
                key(console == .pcEngine ? "II":"B",277,136,46);key(console == .pcEngine ? "I":"A",337,115,46)
                bar(console == .pcEngine ? "RUN":"START",229,218);bar("SELECT",171,218)
            }
        }
        SkinDrawing.text(console.shortName.uppercased(),in:CGRect(x:120,y:4,width:160,height:20),size:12,color:ink,font:"BarlowCondensed-Bold")
        ctx.restoreGState()
    }
}
