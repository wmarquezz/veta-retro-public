import UIKit

// One layout keeps the native Metal image and touch regions separate, including
// iPad and compact landscape. No web view or raster controller assets are used.
struct ConsoleLayout {
    let body:CGRect
    let screen:CGRect
    let deck:CGRect
    let toolbar:CGRect
    init(safe:CGRect,aspect:CGFloat = 4/3,minimumDeck:CGFloat = 210,compactDualScreen:Bool = false,overlayLandscape:Bool = false) {
        if safe.width > safe.height {
            body=safe
            if overlayLandscape {
                let width=max(1,min(safe.width,safe.height*aspect)),height=width/aspect
                screen=CGRect(x:safe.midX-width/2,y:safe.midY-height/2,width:width,height:height)
                deck=safe
                toolbar=CGRect(x:safe.midX-44,y:safe.minY,width:88,height:44)
                return
            }
            toolbar=CGRect(x:safe.minX,y:safe.minY,width:safe.width,height:44)
            let height=max(1,min(safe.height-64,(safe.width-376)/aspect))
            screen=CGRect(x:safe.midX-height*aspect/2,y:safe.minY+48+(safe.height-56-height)/2,width:height*aspect,height:height)
            deck=CGRect(x:safe.minX,y:safe.minY+48,width:safe.width,height:safe.height-48)
        } else {
            let minimum=compactDualScreen ? CGFloat(240):minimumDeck
            let width=min(800,safe.width),imageWidth=min(safe.width,max(1,safe.height-minimum-44)*aspect),height=imageWidth/aspect
            // A black display above one compact, bottom-anchored controller.
            // The toolbar belongs to the controller, not above the game.
            let deckHeight=compactDualScreen ? min(240,max(1,safe.height-height-44)):min(320,max(minimumDeck,width*0.69),safe.height-height-44)
            deck=CGRect(x:safe.midX-width/2,y:safe.maxY-deckHeight,width:width,height:deckHeight)
            toolbar=CGRect(x:deck.minX,y:deck.minY-44,width:width,height:44)
            body=CGRect(x:deck.minX,y:toolbar.minY,width:width,height:deckHeight+44)
            let displayHeight=toolbar.minY-safe.minY
            screen=CGRect(x:safe.midX-imageWidth/2,y:safe.minY+(displayHeight-height)/2,width:imageWidth,height:height)
        }
    }
}
extension CGRect {
    func withHeight(_ height:CGFloat)->CGRect {CGRect(x:minX,y:minY,width:width,height:height)}
}
enum SkinDrawing {
    static func text(_ text:String,in rect:CGRect,size:CGFloat,color:UIColor,font:String?=nil) {
        let attrs:[NSAttributedString.Key:Any]=[.font:font.flatMap{UIFont(name:$0,size:size)} ?? UIFont.systemFont(ofSize:size,weight:.bold),.foregroundColor:color]
        let string=text as NSString,measure=string.size(withAttributes:attrs)
        string.draw(at:CGPoint(x:rect.midX-measure.width/2,y:rect.midY-measure.height/2),withAttributes:attrs)
    }
    static func bevel(_ path:UIBezierPath,top:UIColor,bottom:UIColor,edge:UIColor,width:CGFloat=1,shadow:Bool=false) {
        guard let ctx=UIGraphicsGetCurrentContext() else{return}
        if shadow {
            ctx.saveGState();ctx.setShadow(offset:CGSize(width:0,height:3),blur:3,color:UIColor.black.withAlphaComponent(0.6).cgColor)
            bottom.setFill();path.fill();ctx.restoreGState()
        }
        ctx.saveGState();path.addClip()
        let gradient=CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:[top.cgColor,bottom.cgColor] as CFArray,locations:[0,1])!
        ctx.drawLinearGradient(gradient,start:CGPoint(x:path.bounds.midX,y:path.bounds.minY),end:CGPoint(x:path.bounds.midX,y:path.bounds.maxY),options:[])
        ctx.restoreGState();edge.setStroke();path.lineWidth=width;path.stroke()
    }
}
final class ConsoleShellView:UIView {
    var style=ControlStyle()
    var screenRect=CGRect.zero
    var portraitSkinTop:CGFloat?
    override init(frame:CGRect) {super.init(frame:frame);isUserInteractionEnabled=false;isOpaque=false;backgroundColor = .clear}
    required init?(coder:NSCoder) {fatalError()}
    override func draw(_ rect:CGRect) {
        let classic=style.skin == "Clásica",night=style.skin == "Noche",clear=style.skin == "Transparente"
        let casing:CGRect
        if let top=portraitSkinTop {
            UIColor.black.setFill();UIBezierPath(rect:bounds).fill()
            casing=CGRect(x:bounds.minX,y:top,width:bounds.width,height:bounds.maxY-top)
        } else {casing=bounds}
        if !clear {
            SkinDrawing.bevel(UIBezierPath(rect:casing),top:UIColor(hex:classic ? (style.console == .nes ? 0xeeeae1:style.console.color):night ? 0x111b2a:0x24454f),bottom:style.background,edge:style.background,width:0)
        }
        let framed=screenRect.width < bounds.width-1
        let rim=screenRect.insetBy(dx:-10,dy:-10)
        if !clear && framed {SkinDrawing.bevel(UIBezierPath(roundedRect:rim,cornerRadius:9),top:UIColor(hex:0x454e4c),bottom:UIColor(hex:0x121b20),edge:UIColor(hex:classic ? 0xa2aaa0:0x476672),width:2)}
        UIColor.black.setFill();UIBezierPath(rect:screenRect.insetBy(dx:-2,dy:-2)).fill()
        if !clear && framed {
            // Small power light belongs to the bezel, never overlaps the picture.
            style.accent.setFill();UIBezierPath(ovalIn:CGRect(x:rim.maxX-6,y:rim.midY-2,width:3,height:3)).fill()
        }
    }
}
