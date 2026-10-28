import SwiftUI
import SceneKit

// Procedural reconstructions of launch hardware, with distinct shells and physical details.
// No downloaded manufacturer meshes, logos or textures. Dimensions are proportional.
struct ConsoleModel:UIViewRepresentable {
    let console:GameConsole
    func makeUIView(context:Context)->SCNView {
        Self.previewView(console:console,interactive:true)
    }
    static func previewView(console:GameConsole,interactive:Bool)->SCNView {
        let view=SCNView();view.backgroundColor = .clear;view.isOpaque=false
        view.allowsCameraControl=interactive;view.antialiasingMode = .multisampling4X
        view.rendersContinuously=false;view.autoenablesDefaultLighting=false
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.minimumVerticalAngle=15;view.defaultCameraController.maximumVerticalAngle=80
        let scene=SCNScene(),group=SCNNode();scene.rootNode.addChildNode(group)
        @discardableResult func box(_ w:CGFloat,_ h:CGFloat,_ d:CGFloat,_ color:UInt32,_ x:Float=0,_ y:Float=0,_ z:Float=0)->SCNNode {
            let shape=SCNBox(width:w,height:h,length:d,chamferRadius:min(0.10,h/3));shape.firstMaterial?.diffuse.contents=UIColor(hex:color);shape.firstMaterial?.roughness.contents=0.55
            let node=SCNNode(geometry:shape);node.position=SCNVector3(x,y,z);group.addChildNode(node);return node
        }
        func disk(_ radius:CGFloat,_ color:UInt32,_ x:Float,_ y:Float,_ z:Float,_ height:CGFloat=0.06) {
            let shape=SCNCylinder(radius:radius,height:height);shape.firstMaterial?.diffuse.contents=UIColor(hex:color)
            let node=SCNNode(geometry:shape);node.position=SCNVector3(x,y,z);group.addChildNode(node)
        }
        func pad(_ x:Float,_ y:Float,_ z:Float) {box(0.55,0.08,0.18,0x202a32,x,y,z);box(0.18,0.09,0.55,0x202a32,x,y+0.01,z)}
        func buttons(_ x:Float,_ y:Float,_ z:Float,_ four:Bool=true) {
            let neutral=[GameConsole.psp,.ds,.threeDS].contains(console)
            disk(0.12,neutral ? 0x28282c:0xd65e65,x+0.22,y,z);disk(0.12,neutral ? 0x28282c:0x6e9dba,x,y,z+0.22)
            if four {disk(0.12,neutral ? 0x28282c:0x73b68e,x-0.22,y,z);disk(0.12,neutral ? 0x28282c:0xd4bd67,x,y,z-0.22)}
        }
        let c=console.color
        switch console {
        #if VETA_JIT_DEVELOPMENT
        case .ps3:
            box(4.5,0.95,3.2,0x17191d);box(4.35,0.18,3.05,0x30343a,0,0.48);box(3.0,0.045,0.03,0x999da5,0,0.18,1.63);disk(0.045,0x68be59,1.75,0.13,1.65)
        case .xbox:
            box(4.5,0.95,3.5,0x202825);box(3.9,0.12,0.5,0x131c17,0,0.54);box(0.5,0.12,3.0,0x131c17,0,0.54);disk(0.48,0x75b840,0,0.63,0);box(2.6,0.13,0.04,0x111914,-0.5,0.05,1.78)
        case .xbox360:
            box(4.4,0.75,3.0,0xd4d8ce);box(2.5,0.14,0.045,0xb5bab6,-0.55,0.06,1.53);disk(0.16,0x75b840,1.55,0.38,1.27)
        #endif
        case .gb,.gbc:
            box(2.3,console == .gb ? 0.56:0.42,3.7,console == .gb ? 0xc8c6b9:0x65519a);box(1.9,0.08,1.7,0x3b4650,0,0.24,-0.7);box(1.45,0.03,1.27,console == .gb ? 0x829665:0x36597a,0,0.30,-0.7)
            pad(-0.64,0.32,0.72);disk(0.15,console == .gb ? 0x8c204c:0x303039,0.56,0.32,0.89);disk(0.15,console == .gb ? 0x8c204c:0x303039,0.88,0.32,0.67)
            for i in 0..<4 {box(0.5,0.02,0.05,0x646b69,0.65,0.23,1.2+Float(i)*0.12)}
            box(0.22,0.04,0.09,0x555b61,-0.15,0.25,1.2);box(0.22,0.04,0.09,0x555b61,0.2,0.25,1.2)
        case .gba:
            box(4.5,0.62,2.5,0x5d4ca4);box(2.65,0.10,2.10,0x2b2b37,0,0.36);box(2.05,0.03,1.38,0x4f6664,0,0.43)
            pad(-1.85,0.28,0);buttons(1.77,0.28,0,console == .psp)
            box(0.8,0.14,0.3,0xb9c2c4,-1.75,0.12,-1.13);box(0.8,0.14,0.3,0xb9c2c4,1.75,0.12,-1.13)
        case .gameGear:
            box(4.8,0.8,2.6,0x252629);box(2.9,0.08,2.2,0x171719,0,0.44);box(2.1,0.03,1.55,0x485b60,0,0.50)
            pad(-1.85,0.46,0);disk(0.15,0x273d8b,1.62,0.48,0.32);disk(0.15,0x273d8b,1.96,0.48,0.08)
            disk(0.09,0x323336,1.8,0.47,-0.68)
            for i in 0..<5 {box(0.42,0.025,0.045,0x101013,1.78,0.43,0.65+Float(i)*0.1)}
        case .psp:
            box(4.9,0.43,2.1,0x161719);box(4.82,0.10,1.99,0x8c8c90,0,-0.19)
            box(3.1,0.055,1.83,0x08090b,0,0.24);box(2.85,0.02,1.60,0x434f59,0,0.28)
            pad(-1.96,0.26,-0.12);buttons(1.94,0.26,-0.12)
            disk(0.18,0x323236,-1.95,0.26,0.68)
            for i in 0..<6 {box(0.13,0.025,0.06,0x77777c,-0.7+Float(i)*0.28,0.25,0.95)}
        case .ds,.threeDS:
            box(3.8,0.28,2.35,c,0,0,0.65);box(2.1,0.05,1.55,0x283d4a,0,0.18,0.55)
            let lid=SCNNode();lid.position=SCNVector3(0,0.18,-0.52);lid.eulerAngles.x = .pi/3;group.addChildNode(lid)
            lid.addChildNode(box(3.8,0.22,2.35,c,0,0,-1.175));lid.addChildNode(box(2.75,0.04,1.65,0x283d4a,0,0.13,-1.175))
            pad(-1.42,0.21,0.65);buttons(1.42,0.21,0.65)
            if console == .threeDS {disk(0.17,0xbdc4ca,-1.45,0.22,0);lid.addChildNode(box(0.06,0.02,0.06,0x111820,0,0.14,-2.2))}
            box(3.6,0.26,0.3,0x6e7e8a,0,0.32,-0.62)
        case .gamecube:
            box(2.9,2.2,2.9,c);disk(1.16,0x282b3b,0,1.14,0);disk(0.38,0x5d5a69,0,1.18,0)
            box(2.75,0.66,0.06,0xb8b8b9,0,0.12,1.49)
            for i in 0..<4 {
                let port=SCNNode(geometry:SCNCylinder(radius:0.19,height:0.07));port.geometry?.firstMaterial?.diffuse.contents=UIColor(hex:0x242429)
                port.eulerAngles.x = .pi/2;port.position=SCNVector3(-0.98+Float(i)*0.65,0.12,1.55);group.addChildNode(port)
            }
            for x:Float in [-0.68,0.68] {box(0.86,0.10,0.06,0x25252c,x,-0.48,1.49)}
            box(2.25,0.32,0.30,0x888ba3,0,0.65,-1.6)
        case .wii:
            box(0.85,3.5,2.6,c);box(1.8,0.18,3.1,0x858f97,0,-1.82)
            box(0.05,2.35,0.05,console == .wii ? 0x48a7cf:0x386a9c,0.12,0,1.32)
            disk(0.1,0x82a098,0,1.78,0.8)
        case .ps2:
            box(1.35,3.7,2.9,0x1c1c20);box(0.20,3.9,2.95,0x08090c,-0.7)
            box(1.8,0.15,3.15,0x153d8f,0,-1.97)
            for i in 0..<11 {box(0.035,3.6,2.92,0x37373b,-0.5+Float(i)*0.1)}
            box(0.025,1.85,0.04,0x050608,-0.48,0.70,1.49)
            for i in 0..<2 {box(0.30,0.25,0.06,0x090a0b,0.18,-0.65+Float(i)*0.55,1.51)}
            box(0.08,0.08,0.04,0x58ae73,0.20,1.50,1.51)
        case .ps1:
            box(4.4,0.68,3.2,0xb5b5b2);disk(1.24,0xc6c6c2,0,0.38,0)
            disk(0.22,0x898b88,-1.65,0.38,0.75);disk(0.22,0x898b88,1.65,0.38,0.75)
            disk(0.11,0x898b88,-1.65,0.38,0.12)
            for x:Float in [-0.95,0.95] {box(0.74,0.18,0.05,0x48494c,x,-0.12,1.63);box(0.80,0.06,0.05,0x6a6a6a,x,0.13,1.63)}
            for i in 0..<8 {box(0.36,0.02,0.05,0x777875,-1.87,0.36,-1.0+Float(i)*0.14);box(0.36,0.02,0.05,0x777875,1.87,0.36,-1.0+Float(i)*0.14)}
        case .saturn:
            box(4.4,1.15,3.9,0x292a2e);box(3.5,0.12,3.3,0x35363a,0,0.62)
            disk(1.36,0x202125,0,0.73,0.05);disk(0.22,0x5d5e61,-1.7,0.65,0.85);disk(0.22,0x5d5e61,1.7,0.65,0.85)
            box(1.9,0.03,0.14,0x090a0c,0,0.71,-1.55)
            for x:Float in [-0.95,0.95] {box(0.74,0.27,0.06,0x0c0d0f,x,-0.20,1.98)}
        case .dreamcast:
            box(3.5,1.2,3.45,0xd9d7d0);disk(1.23,0xe4e2db,0,0.65,-0.05)
            disk(0.22,0xa9aaa6,-1.35,0.65,0.9);disk(0.22,0xa9aaa6,1.35,0.65,0.9)
            for i in 0..<4 {box(0.50,0.34,0.06,0x454548,-1.08+Float(i)*0.72,-0.12,1.76)}
            box(0.10,0.04,0.08,0xe17d37,0,0.65,1.48)
        case .snes:
            box(3.6,0.65,4.25,0xaba7b5,0,-0.12);box(3.6,0.34,3.85,0xc9c5d0,0,0.36,-0.12)
            box(2.65,0.13,2.65,0xb8b4c1,0,0.60,-0.22)
            box(2.25,0.06,0.18,0x24242a,0,0.70,-0.74)
            box(1.30,0.16,0.65,0xa9a4b3,0,0.69,0.40)
            box(0.52,0.15,0.64,0x756190,-1.20,0.65,0.40);box(0.52,0.15,0.64,0x756190,1.20,0.65,0.40)
            for x:Float in [-0.80,0.80] {box(0.72,0.23,0.05,0x303036,x,-0.14,2.15)}
            for i in 0..<8 {box(2.6,0.025,0.04,0x92909b,0,0.55,-1.20-Float(i)*0.10)}
        case .n64:
            let body=box(4.1,0.8,2.8,c);(body.geometry as? SCNBox)?.chamferRadius=0.30;box(2.2,0.1,0.28,0x19252c,0,0.47,-0.1)
            for i in 0..<4 {box(0.50,0.34,0.05,0x1b282d,-1.15+Float(i)*0.76,-0.06,1.43)}
            box(0.65,0.12,0.58,0x3c4547,-1.25,0.48,0.65)
        case .atari2600:
            box(4.6,0.6,2.6,0x242d32);box(4.6,0.5,0.3,c,0,-0.04,1.36)
            for i in 0..<12 {box(0.13,0.03,1.75,0x4d5557,-1.5+Float(i)*0.27,0.34,-0.3)}
            box(1.5,0.07,0.2,0x111c21,0,0.36,-0.1)
        case .pcEngine:
            box(2.7,0.6,2.7,c);box(1.7,0.05,0.08,0x333e45,0,0,1.38);box(0.55,0.09,0.4,0xb93f43,-0.6,0.36,0.5)
        case .masterSystem:
            box(4.8,0.65,2.5,c);box(3.4,0.10,0.85,0xa6444b,0,0.37,0.65);box(2.4,0.05,0.15,0x151e28,0,0.42,-0.4)
        case .megaDrive:
            box(4.5,0.65,3.0,c);disk(1.15,0x1a242e,0.35,0.38,0);box(2.25,0.04,0.22,0x101a24,0.35,0.43,-0.2)
            box(0.5,0.1,0.3,0xa14549,-1.3,0.41,0.4)
        case .nes:
            // Front-loading NES: split shell, flush cartridge flap, dark right vent stripe.
            box(4.4,0.48,3.5,0x68686b,0,-0.29)
            box(4.4,0.67,3.5,0xc5c4bd,0,0.28)
            box(2.65,0.025,1.6,0xd6d5cd,-0.55,0.63,0.92)
            box(2.66,0.018,0.025,0x595a59,-0.55,0.65,0.12)
            box(0.75,0.025,3.45,0x45464b,1.38,0.63,0)
            for i in 0..<13 {box(0.66,0.02,0.045,0x16171b,1.38,0.65,-1.55+Float(i)*0.17)}
            box(0.75,0.35,0.025,0x45464b,1.38,-0.14,1.77)
            for i in 0..<2 {box(0.28,0.18,0.045,0x111217,1.20+Float(i)*0.36,-0.14,1.79)}
            box(0.43,0.17,0.045,0x9d9d98,-1.42,-0.18,1.78)
            box(0.43,0.17,0.045,0x9d9d98,-0.87,-0.18,1.78)
            box(0.07,0.06,0.05,0xd52c2c,-1.76,-0.15,1.79)

        }
        let camera=SCNNode();camera.camera=SCNCamera();camera.camera?.usesOrthographicProjection=true;camera.camera?.orthographicScale=2.5
        camera.position=SCNVector3(4,7,11);camera.look(at:SCNVector3(0,0,0));scene.rootNode.addChildNode(camera);view.pointOfView=camera
        let ambient=SCNNode();ambient.light=SCNLight();ambient.light?.type = .ambient;ambient.light?.intensity=700;scene.rootNode.addChildNode(ambient)
        let light=SCNNode();light.light=SCNLight();light.light?.type = .omni;light.light?.intensity=1100;light.position=SCNVector3(-3,7,5);scene.rootNode.addChildNode(light)
        view.scene=scene;view.accessibilityLabel="Consola \(console.name) en tres dimensiones";return view
    }
    func updateUIView(_ view:SCNView,context:Context) {}
}
