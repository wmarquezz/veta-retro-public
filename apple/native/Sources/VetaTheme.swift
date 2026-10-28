import SwiftUI
import SceneKit

extension UIColor {
    convenience init(hex:UInt32,alpha:CGFloat=1) {self.init(red:CGFloat((hex>>16)&255)/255,green:CGFloat((hex>>8)&255)/255,blue:CGFloat(hex&255)/255,alpha:alpha)}
}
enum VetaTheme {
    static let background=Color(uiColor:UIColor(hex:0x101b26))
    static let panel=Color(uiColor:UIColor(hex:0x192c38))
    static let ink=Color(uiColor:UIColor(hex:0xfff1dd))
    static let muted=Color(uiColor:UIColor(hex:0xa8bdc7))
    static let orange=Color(uiColor:UIColor(hex:0xff853b))
    static let mint=Color(uiColor:UIColor(hex:0x72d8c6))
    static let border=Color(uiColor:UIColor(hex:0x36525f))
    static func heading(_ size:CGFloat)->Font {.custom("BarlowCondensed-Bold",size:size,relativeTo:.title)}
    static func body(_ size:CGFloat=14)->Font {.custom("Manrope-Regular",size:size,relativeTo:.body)}
}
// Approved vintage CRT identity, shared with the website and app icon.
struct VetaMark:View {
    var body:some View {
        Image("VetaLogo").resizable().scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius:8)).accessibilityHidden(true)
    }
}
struct VetaBrand:View {
    var body:some View {
        HStack(spacing:8) {
            VetaMark().frame(width:56,height:56)
            VStack(alignment:.leading,spacing:0) {
                Text("VETA").font(VetaTheme.heading(30)).tracking(1).foregroundStyle(VetaTheme.ink)
                Text("RETRO").font(.system(size:9,weight:.bold)).tracking(3).foregroundStyle(VetaTheme.orange)
            }
        }.dynamicTypeSize(.large).accessibilityElement(children:.ignore).accessibilityLabel("VETA Retro")
    }
}
struct VetaBackdrop:View {
    var body:some View {
        VetaTheme.background.overlay(alignment:.topTrailing) {
            Canvas {ctx,size in
                var p=Path()
                for i in 0..<8 {
                    let x=size.width-CGFloat(i)*24
                    p.move(to:CGPoint(x:x,y:0));p.addLine(to:CGPoint(x:x,y:80+CGFloat(i)*20));p.addLine(to:CGPoint(x:x-110,y:190+CGFloat(i)*20));p.addLine(to:CGPoint(x:x-110,y:420))
                }
                ctx.stroke(p,with:.color(VetaTheme.border.opacity(0.22)),lineWidth:1)
            }.frame(height:440)
        }.ignoresSafeArea().accessibilityHidden(true)
    }
}
struct VetaButton:ButtonStyle {
    var primary=false
    func makeBody(configuration:Configuration)->some View {
        configuration.label.font(VetaTheme.body(13).weight(.bold)).padding(.horizontal,14).frame(minHeight:44)
            .foregroundStyle(primary ? VetaTheme.background:VetaTheme.ink)
            .background(primary ? VetaTheme.orange:VetaTheme.panel,in:RoundedRectangle(cornerRadius:8))
            .overlay(RoundedRectangle(cornerRadius:8).stroke(primary ? VetaTheme.orange:VetaTheme.border,lineWidth:1))
            .opacity(configuration.isPressed ? 0.7:1)
    }
}
struct VetaFormStyle:ViewModifier {
    func body(content:Content)->some View {
        content.scrollContentBackground(.hidden).background(VetaTheme.background)
            .tint(VetaTheme.mint).foregroundStyle(VetaTheme.ink)
            .environment(\.defaultMinListRowHeight,48)
    }
}
extension View {func vetaForm()->some View {modifier(VetaFormStyle())}}

// Native port of VETA's original procedural NES sculpture (os/ui/src/scene.js).
// Render only on camera changes, never an idle animation loop.
struct NESConsoleView:UIViewRepresentable {
    func makeUIView(context:Context)->SCNView {
        let view=SCNView();view.backgroundColor = .clear;view.isOpaque=false
        view.antialiasingMode = .multisampling4X;view.allowsCameraControl=true;view.rendersContinuously=false
        let scene=SCNScene(),group=SCNNode();scene.rootNode.addChildNode(group)
        func box(_ w:CGFloat,_ h:CGFloat,_ d:CGFloat,_ color:UInt32,_ x:Float=0,_ y:Float=0,_ z:Float=0,_ radius:CGFloat=0.04) {
            let geometry=SCNBox(width:w,height:h,length:d,chamferRadius:radius)
            geometry.firstMaterial?.diffuse.contents=UIColor(hex:color);geometry.firstMaterial?.roughness.contents=0.58
            let node=SCNNode(geometry:geometry);node.position=SCNVector3(x,y,z);group.addChildNode(node)
        }
        func key(_ x:Float,_ y:Float,_ z:Float) {
            let shape=SCNCylinder(radius:0.12,height:0.075);shape.firstMaterial?.diffuse.contents=UIColor(hex:0xd94c43)
            let node=SCNNode(geometry:shape);node.position=SCNVector3(x,y,z);group.addChildNode(node)
        }
        box(4.4,0.85,3.1,0xc8cbc9);box(4.4,0.24,3.1,0x5e656a,0,-0.48)
        box(2.8,0.18,1.65,0xdeddd2,-0.45,0.51,0.55);box(2.52,0.04,0.12,0x353b40,-0.48,0.62,1.16,0.01)
        box(0.65,0.035,2.8,0x585e61,1.45,0.45,0,0.01)
        for i in 0..<8 {box(0.53,0.03,0.06,0x202b31,1.45,0.48,-1.2+Float(i)*0.15,0.01)}
        box(0.5,0.16,0.1,0x25272a,-1.45,-0.04,1.57);box(0.5,0.16,0.1,0x25272a,-0.82,-0.04,1.57)
        box(0.15,0.05,0.06,0xf75135,-1.85,0.03,1.57,0.01)
        box(1.9,0.22,0.8,0xd4d1c3,-0.9,-0.66,2.2);box(1.75,0.03,0.66,0x282c30,-0.9,-0.53,2.2)
        box(0.54,0.08,0.18,0x171c22,-1.45,-0.49,2.2);box(0.18,0.085,0.54,0x171c22,-1.45,-0.485,2.2)
        key(-0.45,-0.48,2.3);key(-0.15,-0.48,2.3)
        group.eulerAngles=SCNVector3(0.13,-0.4,0)
        let camera=SCNNode();camera.camera=SCNCamera();camera.camera?.usesOrthographicProjection=true;camera.camera?.orthographicScale=3.7
        camera.position=SCNVector3(6,7.2,10);camera.look(at:SCNVector3(0,0,0.35));scene.rootNode.addChildNode(camera);view.pointOfView=camera
        let ambient=SCNNode();ambient.light=SCNLight();ambient.light?.type = .ambient;ambient.light?.intensity=700;scene.rootNode.addChildNode(ambient)
        let light=SCNNode();light.light=SCNLight();light.light?.type = .omni;light.light?.intensity=1100;light.position=SCNVector3(-3,7,5);scene.rootNode.addChildNode(light)
        view.scene=scene;view.accessibilityLabel=L10n.text("Consola NES en tres dimensiones");return view
    }
    func updateUIView(_ view:SCNView,context:Context) {}
}

struct GameCover:View {
    let game:Game
    let artURL:URL?
    var coverImage:UIImage? = nil
    var compact=false
    var body:some View {
        GeometryReader {g in
            ZStack(alignment:.bottomLeading) {
                LinearGradient(colors:[VetaTheme.panel,Color(uiColor:UIColor(hex:0x294c56)),VetaTheme.background],startPoint:.topLeading,endPoint:.bottomTrailing)
                if let coverImage {
                    Image(uiImage:coverImage).resizable().scaledToFit().frame(width:g.size.width,height:g.size.height)
                } else if let artURL,let image=UIImage(contentsOfFile:artURL.path) {
                    Image(uiImage:image).resizable().interpolation(.none).scaledToFit().frame(width:g.size.width,height:g.size.height*0.68).frame(maxHeight:.infinity,alignment:.top).padding(.top,g.size.height*0.09)
                } else {
                    Image(systemName:"gamecontroller").font(.system(size:g.size.width*0.28)).foregroundStyle(VetaTheme.mint.opacity(0.5)).frame(maxWidth:.infinity,maxHeight:.infinity).offset(y:-g.size.height*0.1)
                }
                if coverImage == nil {
                LinearGradient(colors:[.clear,VetaTheme.background.opacity(0.8),VetaTheme.background],startPoint:.center,endPoint:.bottom)
                VStack(alignment:.leading,spacing:6) {
                    Text(game.console.shortName).font(.system(size:compact ? 6:9,weight:.bold)).tracking(2).foregroundStyle(VetaTheme.mint)
                    if !compact {Text(game.name.uppercased()).font(VetaTheme.heading(27)).lineLimit(3).minimumScaleFactor(0.7)}
                    Rectangle().fill(VetaTheme.orange).frame(width:g.size.width*0.24,height:3)
                }.padding(compact ? 7:14)
                }
            }.frame(width:g.size.width,height:g.size.height).clipped()
        }.aspectRatio(2/3,contentMode:.fit).clipShape(RoundedRectangle(cornerRadius:8))
            .overlay(RoundedRectangle(cornerRadius:8).stroke(VetaTheme.border,lineWidth:1))
            .shadow(color:.black.opacity(0.3),radius:0,x:0,y:4)
    }
}
