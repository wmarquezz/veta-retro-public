import UIKit
import Combine

struct ControlStyle {
    var console:GameConsole = .nes
    init(console:GameConsole = .nes, defaults:UserDefaults? = .standard) {
        self.console=console
        let prefix=console.preferencePrefix
        skin=defaults?.string(forKey:prefix+"skin") ?? (console == .nes ? "VETA":"Clásica")
        size=defaults?.object(forKey:prefix+"controlSize") as? Double ?? 1
        opacity=defaults?.object(forKey:prefix+"controlOpacity") as? Double ?? 1
        height=defaults?.double(forKey:prefix+"controlHeight") ?? 0
        spacing=defaults?.object(forKey:prefix+"controlSpacing") as? Double ?? 1
        size = size.isFinite ? min(1.2, max(0.85, size)) : 1
        opacity = opacity.isFinite ? min(1, max(0.4, opacity)) : 1
        height = height.isFinite ? min(0.12, max(-0.12, height)) : 0
        spacing = spacing.isFinite ? min(1.2, max(0.8, spacing)) : 1
    }
    var skin="VETA"
    var size:Double=1
    var opacity:Double=1
    var height:Double=0
    var spacing:Double=1
    var accent:UIColor {UIColor(hex:skin == "Clásica" ? 0xd94c43:skin == "Noche" ? 0x879bb6:skin == "Transparente" ? 0xbed8dc:0x6ed8c3)}
    var background:UIColor {UIColor(hex:skin == "Clásica" ? (console == .nes ? 0xd8d6ce:console.color):skin == "Noche" ? 0x070b10:skin == "Transparente" ? 0x080d12:0x112631)}
    var lightClassic:Bool {
        guard skin == "Clásica" else{return false}
        let rgb=console == .nes ? UInt32(0xd8d6ce):console.color
        let red=Double((rgb>>16)&255),green=Double((rgb>>8)&255),blue=Double(rgb&255)
        return red*0.299+green*0.587+blue*0.114>150
    }
    var headerInk:UIColor {UIColor(hex:lightClassic ? 0x333d39:0xfff1dd)}
    var keyFill:UIColor {UIColor(hex:skin == "Clásica" ? 0x242b2b:skin == "Noche" ? 0x111b28:skin == "Transparente" ? 0x45616c:0x153844,alpha:skin == "Transparente" ? 0.5:1)}
    var keyBorder:UIColor {UIColor(hex:skin == "Clásica" ? 0x535c59:skin == "Noche" ? 0x879bb6:skin == "Transparente" ? 0xbed8dc:0x779ca7,alpha:skin == "Transparente" ? 0.6:1)}
    func actionColor(_ name:String)->UIColor {
        guard skin == "Clásica",console != .nes else{return UIColor(hex:0xff5a4e)}
        if console == .snes {return UIColor(hex:["A":0xe45757,"B":0xdfbf4d,"X":0x557dcd,"Y":0x4caa73][name] ?? 0x8485a5)}
        if console == .gb {return UIColor(hex:0x9b3864)}
        if console == .gbc || console == .gba {return UIColor(hex:0x535b69)}
        if console == .n64 && name.hasPrefix("C") {return UIColor(hex:0xdfbc45)}
        if console == .gamecube {return UIColor(hex:name == "A" ? 0x50b69c:name == "B" ? 0xd95f5f:0xa3aabb)}
        return UIColor(hex:console.color).withAlphaComponent(0.9)
    }
    func buttonLabel(_ name:String)->String {
        #if VETA_JIT_DEVELOPMENT
        if [.xbox,.xbox360].contains(console) {return ["A":"B","B":"A","X":"Y","Y":"X","L":"LB","R":"RB","L2":"LT","R2":"RT"][name] ?? name}
        #endif
        if console.isPlayStationController {return ["A":"○","B":"×","X":"△","Y":"□","L":console == .psp ? "L":"L1","R":console == .psp ? "R":"R1"][name] ?? name}
        if console == .masterSystem || console == .gameGear {return ["A":"2","B":"1","START":console == .masterSystem ? "PAUSE":"START"][name] ?? name}
        if console == .atari2600 {return ["A":"FIRE","START":"RESET","SELECT":"SELECT"][name] ?? name}
        if console == .pcEngine {return ["A":"I","B":"II","START":"RUN"][name] ?? name}
        if console == .megaDrive && name == "SELECT" {return "MODE"}
        if [.ps1,.ps2].contains(console) {return ["L":"L1","R":"R1"][name] ?? name}
        if name == "SHAKE" {return "↝"}
        if name == "HOME" {return "⌂"}
        return name
    }
    func actionGlyph(_ name:String)->UIColor {
        guard skin == "Clásica" else{return glyph}
        var r:CGFloat=0,g:CGFloat=0,b:CGFloat=0,a:CGFloat=0
        actionColor(name).getRed(&r,green:&g,blue:&b,alpha:&a)
        return r*0.299+g*0.587+b*0.114>0.58 ? UIColor(hex:0x19272e):glyph
    }
    var actionFill:UIColor {skin == "Clásica" ? accent:skin == "VETA" ? UIColor(hex:0x326d69):keyFill}
    var glyph:UIColor {UIColor(hex:skin == "VETA" ? 0xb6d1db:0xe7edf5)}

}
final class Haptics {
    private var generator: UIImpactFeedbackGenerator?
    private var cachedStyle: String?
    func pulse(force: Bool=false) {
        guard UIApplication.shared.applicationState == .active, force || UserDefaults.standard.object(forKey:"native.haptics") as? Bool ?? true else {return}
        let style=UserDefaults.standard.string(forKey:"native.hapticStrength") ?? "Suave"
        if cachedStyle != style || generator == nil {
            generator=UIImpactFeedbackGenerator(style:style == "Firme" ? .heavy : style == "Media" ? .medium : .light)
            cachedStyle = style
        }
        generator?.prepare();generator?.impactOccurred();generator?.prepare()
    }
}
final class TouchDeck: UIView {
    var onInput: ((UInt16)->Void)?
    var onAnalog:((Int,CGPoint)->Void)?
    private var stickOwners:[Int:ObjectIdentifier]=[:]
    private var stickValues:[Int:CGPoint]=[:]
    var landscape=false {didSet {if oldValue != landscape {releaseAll()};setNeedsLayout()}}
    var style=ControlStyle(defaults:nil) {didSet {if oldValue.console != style.console {releaseAll()};setNeedsLayout();setNeedsDisplay()}}
    var customLayout:ControllerSkinLayout? {didSet {if oldValue != customLayout {releaseAll();setNeedsLayout()}}}
    var customArtwork:UIImage? {didSet {if oldValue !== customArtwork {releaseAll();setNeedsLayout();setNeedsDisplay()}}}
    private var skinSubscription:AnyCancellable?
    var usesLandscapeOverlay:Bool {landscape && (customLayout == nil || customLayout?.usesLandscapeOverlay == true)}
    private(set) var layoutIssue:String?
    var showsTouchTargets=false {didSet {setNeedsDisplay()}}
    func applySkin(console:GameConsole,landscape:Bool,defaults:UserDefaults = .standard,personalLibrary:PersonalSkinLibrary? = nil) {
        let orientation:ControllerSkinOrientation=landscape ? .landscape:.portrait
        let store=ControllerSkinStore(defaults:defaults)
        var value=ControlStyle(console:console,defaults:defaults)
        value.skin=store.palette(console:console,orientation:orientation).rawValue
        self.landscape=landscape;style=value
        var nextLayout=store.layout(console:console,orientation:orientation)
        var nextArtwork:UIImage?
        if value.skin == ControllerSkinPalette.studio.rawValue,
           let variant=StudioSkins.variant(console:console,orientation:orientation),
           let image=StudioSkins.image(console:console,orientation:orientation) {
            if let edited=nextLayout,let updated=StudioSkins.image(console:console,orientation:orientation,layout:edited) {nextArtwork=updated}
            else {nextLayout=variant.layout;nextArtwork=image}
        }
        if let personal=personalLibrary ?? (defaults === UserDefaults.standard ? PersonalSkinLibrary.shared:nil) {
            if let id=personal.selectedID(console:console,orientation:orientation),
               let variant=personal.selected(console:console,orientation:orientation),
               let image=try? personal.image(id:id,orientation:orientation) {
                nextLayout=variant.layout;nextArtwork=image
            }
            if skinSubscription == nil {
                skinSubscription=personal.objectWillChange.sink { [weak self,weak personal] _ in
                    DispatchQueue.main.async { [weak self,weak personal] in
                        guard let self,let personal else{return}
                        self.applySkin(console:self.style.console,landscape:self.landscape,defaults:defaults,personalLibrary:personal)
                    }
                }
            }
        }
        customLayout=nextLayout;customArtwork=nextArtwork
    }
    private var active: [ObjectIdentifier:(CGPoint,CGPoint)]=[:]
    private var inputMask: UInt16=0
    private var pressDepth: [String: CGFloat] = [:]
    private var pressTimer: Timer?
    private func animatePresses() {
        guard !UIAccessibility.isReduceMotionEnabled else { pressDepth.removeAll(); setNeedsDisplay(); return }
        guard pressTimer == nil else { return }
        pressTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self, self.window != nil else { timer.invalidate(); self?.pressTimer = nil; return }
            var moving = false
            for name in self.zones.keys {
                let bits = self.style.console.buttonMask(name)
                let target: CGFloat = bits != 0 && self.inputMask & bits == bits ? 1 : 0
                let previous = self.pressDepth[name] ?? 0
                let next = previous + (target - previous) * 0.45
                self.pressDepth[name] = abs(next - target) < 0.02 ? target : next
                if abs(next - target) >= 0.02 { moving = true }
            }
            self.setNeedsDisplay()
            if !moving { timer.invalidate(); self.pressTimer = nil }
        }
    }
    private(set) var zones:[String:CGRect]=[:]
    private let feedback=Haptics()
    private var selectGeneration=0
    override init(frame:CGRect) {
        super.init(frame:frame);isMultipleTouchEnabled=true;backgroundColor = .clear;isOpaque=false
        accessibilityIdentifier="native-controls"
    }
    required init?(coder:NSCoder) {fatalError()}
    // Keep accessibility objects stable while status updates relayout the deck.
    // Replacing them every time can invalidate an in-flight VoiceOver/XCTest hit.
    private var accessibleControls:[String:UIAccessibilityElement]=[:]
    private var accessibleControlNames:[String]=[]
    private var lastLayoutSize = CGSize.zero
    override func layoutSubviews() {
        super.layoutSubviews()
        if lastLayoutSize != bounds.size { releaseAll(); lastLayoutSize = bounds.size }
        let previousZones=zones
        let base=usesLandscapeOverlay ? Self.overlayZones(style:style,size:bounds.size):Self.baseZones(style:style,size:bounds.size,landscape:landscape)
        let orientation:ControllerSkinOrientation=landscape ? .landscape:.portrait
        let safe=ControllerSkinGeometry.fitted(base,size:bounds.size,orientation:orientation,overlay:usesLandscapeOverlay)
        layoutIssue=nil
        if let customLayout {
            do {zones=try customArtwork == nil ? customLayout.resolved(console:style.console,orientation:orientation,size:bounds.size):PersonalSkinGeometry.resolved(customLayout,console:style.console,size:bounds.size)}
            catch {zones=safe;layoutIssue=error.localizedDescription}
        } else {zones=safe}
        if previousZones != zones {releaseAll()}
        accessibilityHint=layoutIssue
        let names=zones.keys.sorted()
        for name in names {
            let element=accessibleControls[name] ?? UIAccessibilityElement(accessibilityContainer:self)
            let label=L10n.text(name == "dpad" ? "Cruceta" : name == "stick0" ? "Palanca izquierda":name == "stick1" ? "Palanca derecha":name)
            if element.accessibilityLabel != label {element.accessibilityLabel=label}
            let identifier="control-\(name)"
            if element.accessibilityIdentifier != identifier {element.accessibilityIdentifier=identifier}
            element.accessibilityTraits = .button
            if element.accessibilityFrameInContainerSpace != zones[name]! {element.accessibilityFrameInContainerSpace=zones[name]!}
            accessibleControls[name]=element
        }
        if names != accessibleControlNames {
            accessibleControls=accessibleControls.filter {zones[$0.key] != nil}
            accessibilityElements=names.compactMap {accessibleControls[$0]}
            accessibleControlNames=names
        }
        setNeedsDisplay()
    }
    // The deck may cover the whole display. Only actual controls claim a touch;
    // DS/3DS touchscreens receive touches through every empty part of the deck.
    override func point(inside point:CGPoint,with event:UIEvent?)->Bool {
        bounds.contains(point) && zones.values.contains{$0.contains(point)}
    }
    static func overlayZones(style:ControlStyle,size:CGSize)->[String:CGRect] {
        let w=size.width,h=size.height
        guard w>=320,h>=220 else{return baseZones(style:style,size:size,landscape:true)}
        let legacy=baseZones(style:style,size:size,landscape:true)
        let keys=Set(legacy.keys),analog=style.console.analogSticks>0
        var zones:[String:CGRect]=[:]
        func place(_ name:String,_ x:CGFloat,_ y:CGFloat,_ width:CGFloat,_ height:CGFloat) {
            if keys.contains(name) {zones[name]=CGRect(x:x,y:y,width:width,height:height)}
        }
        let pad:CGFloat=analog ? 88:min(152,max(124,144*style.size))
        place("dpad",16,analog ? 60:h-pad-8,pad,pad)
        let stick:CGFloat=min(100,max(92,h*0.28))
        place("stick0",16,h-stick-8,stick,stick)
        if style.console == .threeDS {
            place("stick0",20,60,stick,stick)
            place("dpad",20,h-pad-8,pad,pad)
        }
        let dual=style.console.analogSticks>1
        let face:CGFloat=min(62,max(52,56*style.size)),step=face+3,cx=w-16-face*1.5-3
        let cy=dual ? min(150,h-172):h-16-face*1.5-3
        if keys.contains("X") && keys.contains("Y") && ![GameConsole.megaDrive,.saturn].contains(style.console) {
            for (name,x,y) in [("X",cx,cy-step),("A",cx+step,cy),("B",cx,cy+step),("Y",cx-step,cy)] {place(name,x-face/2,y-face/2,face,face)}
        } else {
            let side:CGFloat=min(78,max(64,72*style.size))
            place("A",w-side-12,h-side*2-12,side,side)
            place("B",w-side*2-18,h-side-8,side,side)
            place("A+B",w-68,h-48,60,44)
        }
        if keys.contains("stick1") {
            let size:CGFloat=min(80,max(64,h-240))
            place("stick1",w-16-face*1.5-3-size/2,h-size-8,size,size)
        }
        // Shoulder controls have a dedicated top row; small utility buttons
        // move to the lower centre instead of shrinking the game to make rails.
        place("L",12,4,keys.contains("L2") ? 76:112,44)
        place("L2",92,4,76,44)
        place("R",w-(keys.contains("R2") ? 88:124),4,keys.contains("R2") ? 76:112,44)
        place("R2",w-168,4,76,44)
        place("SELECT",w/2-82,h-46,72,44)
        place("START",w/2+10,h-46,72,44)
        place("L3",132,h-46,44,44)
        place("R3",w-176,h-46,44,44)
        if [.megaDrive,.saturn].contains(style.console) {
            let side:CGFloat=56
            for (row,names) in [["X","Y","Z"],["A","B","C"]].enumerated() {
                for (column,name) in names.enumerated() {place(name,w-192+CGFloat(column)*60,h-124+CGFloat(row)*60,side,side)}
            }
        }
        if style.console == .n64 {
            let side:CGFloat=48,step:CGFloat=50,cx=w-92,cy:CGFloat=124
            for (name,x,y) in [("C↑",cx,cy-step),("C↓",cx,cy+step),("C←",cx-step,cy),("C→",cx+step,cy)] {place(name,x-side/2,y-side/2,side,side)}
            place("A",w-72,h-72,64,64);place("B",w-144,h-72,64,64)
            place("Z",132,4,44,44)
        }
        if style.console == .gamecube {place("Z",w-176,4,44,44)}
        if style.console == .wii {
            place("C",12,4,100,44);place("Z",w-112,4,100,44);place("SHAKE",120,4,52,44)
            for (row,names) in [["A","B"],["1","2"]].enumerated() {for (column,name) in names.enumerated() {place(name,w-140+CGFloat(column)*64,64+CGFloat(row)*60,56,56)}}
            place("−",w/2-96,h-46,48,44);place("HOME",w/2-36,h-46,72,44);place("+",w/2+48,h-46,48,44)
        }
        // Unknown future buttons retain their prior zone and still pass through
        // the same collision fitter used by the editor and hit testing.
        for (name,rect) in legacy where zones[name] == nil {zones[name]=rect}
        // Retain the general customization sliders without moving a thumb
        // group across the pause menu, shoulders or another player's controls.
        func shift(_ names:[String],dx:CGFloat,dy:CGFloat,left:Bool) {
            let selected=names.filter{zones[$0] != nil}
            guard !selected.isEmpty else{return}
            let box=selected.compactMap{zones[$0]}.reduce(CGRect.null){$0.union($1)}
            let rail=ControllerSkinGeometry.overlayRail(size)
            let x0:CGFloat=left ? 4:w-rail,x1:CGFloat=left ? rail:w-4
            let x=max(x0-box.minX,min(x1-box.maxX,dx))
            let y=max(52-box.minY,min(h-4-box.maxY,dy))
            for name in selected {zones[name]=zones[name]?.offsetBy(dx:x,dy:y)}
        }
        let spread=CGFloat(style.spacing-1)*60,lift=CGFloat(style.height)*h
        shift(["dpad","stick0"],dx:-spread,dy:lift,left:true)
        let right=["A","B","C","X","Y","Z","C↑","C↓","C←","C→","1","2","stick1"].filter{(zones[$0]?.minY ?? 0)>=52}
        shift(right,dx:spread,dy:lift,left:false)
        return zones
    }
    static func baseZones(style:ControlStyle,size:CGSize,landscape:Bool)->[String:CGRect] {
        let w=size.width,h=size.height
        guard w>0,h>0 else{return [:]}
        // A compact handheld arrangement: circle pad above the D-pad, a
        // diamond of face buttons, and shoulders directly below both screens.
        // Unlike the general two-stick deck it does not reserve a third row.
        if style.console == .threeDS && !landscape {
            // Delta's DS reference uses 60pt keys on a 414pt canvas. Keep
            // similarly generous keys without enlarging the screen's deck.
            let side:CGFloat=min(60,max(44,w*0.145*style.size)),step=side+2
            let pad:CGFloat=min(84,max(64,w*0.21)),stick:CGFloat=min(92,max(64,w*0.234))
            let left:CGFloat=max(52,w*0.18),right=w-10-side*1.5-2
            let centerY=(h+40)/2
            let shoulder:CGFloat=min(120,max(76,w*0.28))
            var zones=[
                "L":CGRect(x:20,y:2,width:shoulder,height:44),
                "R":CGRect(x:w-20-shoulder,y:2,width:shoulder,height:44),
                "stick0":CGRect(x:left-stick/2,y:48,width:stick,height:stick),
                "dpad":CGRect(x:left-pad/2,y:h-pad-8,width:pad,height:pad),
                "X":CGRect(x:right-side/2,y:centerY-step-side/2,width:side,height:side),
                "A":CGRect(x:right+step-side/2,y:centerY-side/2,width:side,height:side),
                "B":CGRect(x:right-side/2,y:centerY+step-side/2,width:side,height:side),
                "Y":CGRect(x:right-step-side/2,y:centerY-side/2,width:side,height:side),
                "SELECT":CGRect(x:w*0.40-28,y:h-96,width:56,height:44),
                "START":CGRect(x:w*0.40-28,y:h-48,width:56,height:44)
            ]
            // Keep the customization sliders effective without moving a group
            // outside the deck or into its shoulder row. The shared fitter then
            // resolves collisions on narrow windows using the same hit targets.
            func shift(_ names:[String],dx:CGFloat,dy:CGFloat,bottom:CGFloat) {
                let frame=names.compactMap{zones[$0]}.reduce(CGRect.null){$0.union($1)}
                let x=max(6-frame.minX,min(w-6-frame.maxX,dx))
                let y=max(48-frame.minY,min(bottom-frame.maxY,dy))
                for name in names {zones[name]=zones[name]?.offsetBy(dx:x,dy:y)}
            }
            let separation=CGFloat(style.spacing-1)*w*0.2,lift=CGFloat(style.height)*h
            shift(["stick0","dpad"],dx:-separation,dy:lift,bottom:h-4)
            shift(["A","B","X","Y"],dx:separation,dy:lift,bottom:h-8)
            shift(["SELECT","START"],dx:0,dy:lift,bottom:h-2)
            return zones
        }
        if style.console == .threeDS && landscape {
            let side:CGFloat=min(58,max(44,56*style.size)),step=side+2
            let cx=w-94,cy=max(48+step+side/2,min(h-50-step-side/2,h*0.47))
            let stick:CGFloat=min(92,max(64,(h-100)*0.54)),pad:CGFloat=min(84,max(64,(h-100)*0.44))
            return [
                "L":CGRect(x:24,y:2,width:116,height:44),"R":CGRect(x:w-140,y:2,width:116,height:44),
                "stick0":CGRect(x:94-stick/2,y:48,width:stick,height:stick),
                "dpad":CGRect(x:94-pad/2,y:h-50-pad,width:pad,height:pad),
                "X":CGRect(x:cx-side/2,y:cy-step-side/2,width:side,height:side),
                "A":CGRect(x:cx+step-side/2,y:cy-side/2,width:side,height:side),
                "B":CGRect(x:cx-side/2,y:cy+step-side/2,width:side,height:side),
                "Y":CGRect(x:cx-step-side/2,y:cy-side/2,width:side,height:side),
                "SELECT":CGRect(x:64,y:h-46,width:60,height:44),"START":CGRect(x:w-124,y:h-46,width:60,height:44)
            ]
        }
        // The NES has a horizontal B/A pair. Visual keys can be smaller than
        // their 44pt targets; the picture always has its own, separate region.
        let utilityY=landscape ? h-54:min(h-54,h*0.75)
        let pad=min(CGFloat(128*style.size),landscape ? 132:w*0.43-16,h-124)
        let cy=min(utilityY-18-pad/2,max(42+pad/2,h*(landscape ? 0.47:0.42)+CGFloat(style.height)*h))
        let left=landscape ? CGFloat(78):max(pad/2+24,w*0.23-CGFloat(style.spacing-1)*22)
        let button=min(60,max(46,CGFloat(54*style.size)),landscape ? 60:w*0.16)
        let gap=CGFloat(16*style.spacing)
        let ax=w-24-button, bx=ax-gap-button
        var zones=["dpad":CGRect(x:left-pad/2,y:cy-pad/2,width:pad,height:pad),
               "B":CGRect(x:bx,y:cy-button/2,width:button,height:button),
               "A":CGRect(x:ax,y:cy-button/2,width:button,height:button),
               "A+B":CGRect(x:w-68,y:utilityY,width:44,height:44),
               "SELECT":CGRect(x:landscape ? 26:w/2-76,y:utilityY,width:60,height:44),
               "START":CGRect(x:landscape ? w-142:w/2-8,y:utilityY,width:60,height:44)]
        if style.console.fourButtons {
            let side:CGFloat=min(48,max(44,46*style.size)),step=side+2
            let cx=w-92,centerY=max(54+step+side/2,min(h-50-step-side/2,h*0.48))
            zones["A"]=CGRect(x:cx+step-side/2,y:centerY-side/2,width:side,height:side)
            zones["B"]=CGRect(x:cx-side/2,y:centerY+step-side/2,width:side,height:side)
            zones["X"]=CGRect(x:cx-side/2,y:centerY-step-side/2,width:side,height:side)
            zones["Y"]=CGRect(x:cx-step-side/2,y:centerY-side/2,width:side,height:side)
            zones.removeValue(forKey:"A+B")
            zones["SELECT"]?.origin.y=h-46;zones["START"]?.origin.y=h-46
        }
        if style.console.shoulders {
            zones["L"]=CGRect(x:24,y:6,width:72,height:44)
            zones["R"]=CGRect(x:w-96,y:6,width:72,height:44)
            if var pad=zones["dpad"] {pad.origin.y=max(54,min(h-100-pad.height,pad.minY));zones["dpad"]=pad}
        }
        if style.console == .megaDrive || style.console == .saturn {
            for name in ["A","B","X","Y","A+B"] {zones.removeValue(forKey:name)}
            let y=max(64,min(h-108,h*0.42)),side:CGFloat=44
            for (row,names) in [["X","Y","Z"],["A","B","C"]].enumerated() {
                for (column,name) in names.enumerated() {zones[name]=CGRect(x:w-162+CGFloat(column)*48,y:y+CGFloat(row)*50,width:side,height:side)}
            }
            zones["SELECT"]?.origin.y=h-46;zones["START"]?.origin.y=h-46
        }
        if style.console == .saturn {zones.removeValue(forKey:"SELECT")}
        if [.ps1,.ps2].contains(style.console) || style.console.isStandaloneEngine {
            for (name,x) in [("L",CGFloat(24)),("L2",CGFloat(92)),("R2",w-152),("R",w-84)] {zones[name]=CGRect(x:x,y:6,width:60,height:44)}
        }
        if style.console == .atari2600 {for name in ["B","A+B"] {zones.removeValue(forKey:name)}}
        if [.masterSystem,.gameGear,.pcEngine].contains(style.console) {zones.removeValue(forKey:"A+B")}
        if style.console.analogSticks>0 {
            // Keep the upper-left D-pad and lower-left analog separate. The
            // second stick sits below the face buttons on dual-stick systems.
            let padSide:CGFloat=min(88,max(60,(h-140)*0.43)),stickSide:CGFloat=min(92,max(64,(h-140)*0.45))
            let leftX:CGFloat=landscape ? 76:78
            zones["dpad"]=CGRect(x:leftX-padSide/2,y:54,width:padSide,height:padSide)
            zones["stick0"]=CGRect(x:leftX-stickSide/2,y:h-50-stickSide,width:stickSide,height:stickSide)
            let side:CGFloat=44,step:CGFloat=46,cx=w-86,cy:CGFloat=123
            zones["A"]=CGRect(x:cx+step-side/2,y:cy-side/2,width:side,height:side)
            zones["B"]=CGRect(x:cx-side/2,y:cy+step-side/2,width:side,height:side)
            zones["X"]=CGRect(x:cx-side/2,y:cy-step-side/2,width:side,height:side)
            zones["Y"]=CGRect(x:cx-step-side/2,y:cy-side/2,width:side,height:side)
            zones.removeValue(forKey:"A+B")
            zones["SELECT"]=CGRect(x:24,y:h-46,width:60,height:44)
            zones["START"]=CGRect(x:w-84,y:h-46,width:60,height:44)
            if style.console.analogSticks>1 {
                let size:CGFloat=min(76,max(48,h-242))
                zones["stick1"]=CGRect(x:cx-size/2,y:h-50-size,width:size,height:size)
            }
        }
        if style.console == .n64 {
            for name in ["X","Y","SELECT"] {zones.removeValue(forKey:name)}
            let cx=w-86,cy:CGFloat=120,side:CGFloat=44,step:CGFloat=46
            for (name,x,y) in [("C↑",cx,cy-step),("C↓",cx,cy+step),("C←",cx-step,cy),("C→",cx+step,cy)] {zones[name]=CGRect(x:x-side/2,y:y-side/2,width:side,height:side)}
            zones["B"]=CGRect(x:w-146,y:h-100,width:44,height:44)
            zones["A"]=CGRect(x:w-84,y:h-100,width:44,height:44)
            zones["Z"]=CGRect(x:114,y:6,width:44,height:44)
        }
        if style.console == .dreamcast {zones.removeValue(forKey:"SELECT")}
        if style.console == .gamecube {
            zones.removeValue(forKey:"SELECT")
            zones["Z"]=CGRect(x:w-154,y:6,width:44,height:44)
        }
        if style.console == .ps2 || style.console.isStandaloneEngine {
            zones["L3"]=CGRect(x:88,y:h-46,width:44,height:44)
            zones["R3"]=CGRect(x:w-132,y:h-46,width:44,height:44)
        }
        if style.console == .wii {
            for name in ["L","R","X","Y","SELECT","START"] {zones.removeValue(forKey:name)}
            zones["C"]=CGRect(x:24,y:6,width:72,height:44)
            zones["Z"]=CGRect(x:w-96,y:6,width:72,height:44)
            zones["SHAKE"]=CGRect(x:114,y:6,width:44,height:44)
            for (row,names) in [["A","B"],["1","2"]].enumerated() {for (column,name) in names.enumerated() {zones[name]=CGRect(x:w-142+CGFloat(column)*54,y:70+CGFloat(row)*52,width:44,height:44)}}
            zones["−"]=CGRect(x:24,y:h-46,width:44,height:44)
            zones["HOME"]=CGRect(x:72,y:h-46,width:60,height:44)
            zones["+"]=CGRect(x:w-68,y:h-46,width:44,height:44)
        }
        return zones
    }
    func releaseAll() {pressTimer?.invalidate();pressTimer=nil;pressDepth.removeAll();selectGeneration+=1;active.removeAll();stickOwners.removeAll();stickValues.removeAll();for i in 0..<2 {onAnalog?(i,.zero)};inputMask=0;onInput?(0);setNeedsDisplay()}
    func inputMask(at point:CGPoint) -> UInt16 {
        if let pad=zones["dpad"],pad.contains(point) {
            let x=(point.x-pad.midX)/(pad.width/2),y=(point.y-pad.midY)/(pad.height/2)
            var value:UInt16=0
            if x < -0.28 {value |= 1<<6};if x > 0.28 {value |= 1<<7}
            if y < -0.28 {value |= 1<<4};if y > 0.28 {value |= 1<<5}
            return value
        }
        for name in ["A","B","C","A+B","START","X","Y","Z","L","R","L2","R2","L3","R3","C↑","C↓","C←","C→","1","2","−","+","HOME","SHAKE"] {
            if zones[name]?.contains(point) == true {return style.console.buttonMask(name)}
        }
        return 0
    }
    private func update() {
        for i in 0..<style.console.analogSticks {
            var value=CGPoint.zero
            if let owner=stickOwners[i],let touch=active[owner],let zone=zones["stick\(i)"] {
                let x=(touch.1.x-zone.midX)/(zone.width*0.38),y=(touch.1.y-zone.midY)/(zone.height*0.38),length=hypot(x,y)
                if length>0.12 {value=CGPoint(x:x/max(1,length),y:y/max(1,length))}
            }
            stickValues[i]=value;onAnalog?(i,value)
        }
        let owners=Set(stickOwners.values)
        var value=active.filter{!owners.contains($0.key)}.values.reduce(UInt16(0)) {$0 | inputMask(at:$1.1)}
        if value & 0x30 == 0x30 {value &= ~0x30};if value & 0xC0 == 0xC0 {value &= ~0xC0}
        if value & ~inputMask != 0 {feedback.pulse()}
        if inputMask != value {inputMask=value;animatePresses()}
        onInput?(value);setNeedsDisplay()
    }
    override func touchesBegan(_ touches:Set<UITouch>,with event:UIEvent?) {
        for t in touches {let p=t.location(in:self),id=ObjectIdentifier(t);active[id]=(p,p)
            for i in 0..<style.console.analogSticks where stickOwners[i]==nil && zones["stick\(i)"]?.contains(p)==true {stickOwners[i]=id;feedback.pulse()}
        };update()
    }
    override func touchesMoved(_ touches:Set<UITouch>,with event:UIEvent?) {
        for t in touches {let id=ObjectIdentifier(t);if let old=active[id] {active[id]=(old.0,t.location(in:self))}};update()
    }
    override func touchesEnded(_ touches:Set<UITouch>,with event:UIEvent?) {
        var select=false
        for t in touches {
            if let old=active.removeValue(forKey:ObjectIdentifier(t)),let rect=zones["SELECT"] {
                let end=t.location(in:self)
                if rect.contains(old.0),rect.contains(end),hypot(end.x-old.0.x,end.y-old.0.y)<=10 {select=true}
            }
        }
        for i in Array(stickOwners.keys) where active[stickOwners[i]!] == nil {stickOwners.removeValue(forKey:i)}
        update()
        if select {
            feedback.pulse();onInput?(inputMask | (1<<2));selectGeneration+=1;let generation=selectGeneration
            DispatchQueue.main.asyncAfter(deadline:.now()+0.08) { [weak self] in
                guard let self,self.selectGeneration==generation else{return};self.onInput?(self.inputMask)
            }
        }
    }
    override func touchesCancelled(_ touches:Set<UITouch>,with event:UIEvent?) {releaseAll()}
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { releaseAll() } }
    override func draw(_ rect:CGRect) {
        guard let ctx=UIGraphicsGetCurrentContext(),let pad=zones["dpad"] else{return}
        if let artwork=customArtwork,let layout=customLayout,layoutIssue == nil {
            ctx.saveGState();ctx.setAlpha(style.opacity)
            defer {ctx.restoreGState()}
            PersonalSkinGeometry.draw(artwork,layout:layout,size:bounds.size)
            for (name,zone) in zones {
                let mask=style.console.buttonMask(name)
                if mask != 0 && inputMask & mask == mask {
                    UIColor.white.withAlphaComponent(0.22).setFill();UIBezierPath(roundedRect:zone,cornerRadius:8).fill()
                }
            }
            for (i,value) in stickValues where value != .zero {
                if let zone=zones["stick\(i)"] {
                    let point=CGPoint(x:zone.midX+value.x*zone.width*0.25,y:zone.midY+value.y*zone.height*0.25)
                    style.accent.setStroke();let ring=UIBezierPath(ovalIn:CGRect(x:point.x-10,y:point.y-10,width:20,height:20));ring.lineWidth=3;ring.stroke()
                }
            }
            if showsTouchTargets {
                for zone in zones.values {UIColor.systemTeal.withAlphaComponent(0.15).setFill();let path=UIBezierPath(roundedRect:zone,cornerRadius:5);path.fill();UIColor.systemTeal.setStroke();path.lineWidth=1;path.stroke()}
            }
            return
        }
        let classic=style.skin == "Clásica",night=style.skin == "Noche",clear=style.skin == "Transparente"
        let edge=classic ? UIColor(hex:0xb8bab3):style.keyBorder
        // The faceplate belongs to the casing, not to the button opacity setting.
        if !clear && !usesLandscapeOverlay {
            let faces=landscape ? [CGRect(x:8,y:8,width:144,height:bounds.height-12),CGRect(x:bounds.width-172,y:8,width:164,height:bounds.height-12)] : [bounds.insetBy(dx:12,dy:4)]
            for face in faces {
                SkinDrawing.bevel(UIBezierPath(roundedRect:face,cornerRadius:landscape ? 12:20),top:UIColor(hex:classic ? (style.console == .nes ? 0x343936:style.console.color):night ? 0x101b28:0x173440),bottom:UIColor(hex:classic ? (style.console == .nes ? 0x202421:0x414958):night ? 0x080e16:0x0b1e29),edge:edge,width:1.5)
            }
            if !landscape {
                let rib=CGRect(x:bounds.midX-30,y:14,width:60,height:28)
                if classic && style.console == .nes {
                    let bandWidth=min(240,bounds.width*0.40),step=(bounds.height-24)/5
                    for row in 0..<5 {
                        UIColor(hex:0x454c44).setFill()
                        UIBezierPath(roundedRect:CGRect(x:bounds.midX-bandWidth/2,y:12+CGFloat(row)*step,width:bandWidth,height:step*0.64),cornerRadius:4).fill()
                    }
                    if let select=zones["SELECT"],let start=zones["START"] {
                        let well=CGRect(x:select.minX-4,y:select.minY,width:start.maxX-select.minX+8,height:26)
                        SkinDrawing.bevel(UIBezierPath(roundedRect:well,cornerRadius:4),top:UIColor(hex:0xdcded3),bottom:UIColor(hex:0xa5aca0),edge:UIColor(hex:0xeaf0e2))
                    }
                } else if classic {
                    for row in 0..<4 {for col in 0..<3 {
                        UIColor(hex:0x343d4a,alpha:0.5).setFill()
                        UIBezierPath(ovalIn:CGRect(x:bounds.midX-8+CGFloat(col)*7,y:62+CGFloat(row)*7,width:3,height:3)).fill()
                    }}
                } else {
                    for i in 0..<4 {
                        UIColor(hex:night ? 0x243444:0x2a4e59).setFill()
                        UIBezierPath(roundedRect:rib.offsetBy(dx:0,dy:CGFloat(i)*7).withHeight(4),cornerRadius:2).fill()
                    }
                }
            }
        }
        ctx.saveGState();ctx.setAlpha(style.opacity)
        let unit=pad.width/3
        let cross=UIBezierPath()
        let pts:[CGPoint]=[(1,0),(2,0),(2,1),(3,1),(3,2),(2,2),(2,3),(1,3),(1,2),(0,2),(0,1),(1,1)].map{CGPoint(x:pad.minX+CGFloat($0.0)*unit,y:pad.minY+CGFloat($0.1)*unit)}
        cross.move(to:pts[0]);for p in pts.dropFirst(){cross.addLine(to:p)};cross.close();cross.lineJoinStyle = .round
        let disc=UIBezierPath(ovalIn:pad)
        let key=style.skin == "VETA" ? disc:cross
        if classic && style.console != .threeDS && !usesLandscapeOverlay {
            // A raised pale socket surrounds the black cross, like a physical NES pad.
            UIColor(hex:0xc2c5bc).setStroke();cross.lineWidth=10;cross.stroke()
            UIColor(hex:0x747c72).setStroke();cross.lineWidth=6;cross.stroke()
        }
        SkinDrawing.bevel(key,top:clear ? style.keyFill:UIColor(hex:classic ? 0x424945:night ? 0x233247:0x3b626b),bottom:clear ? style.keyFill:UIColor(hex:0x121f25),edge:edge,width:clear ? 1:2,shadow:!clear)
        let center=CGPoint(x:pad.midX,y:pad.midY)
        for (dx,dy,bit) in [(0.0,-1.0,4),(0.0,1.0,5),(-1.0,0.0,6),(1.0,0.0,7)] {
            let point=CGPoint(x:center.x+dx*unit,y:center.y+dy*unit)
            let arrow=UIBezierPath()
            let forward=CGPoint(x:dx*7,y:dy*7),side=CGPoint(x:-dy*6,y:dx*6)
            arrow.move(to:CGPoint(x:point.x+forward.x,y:point.y+forward.y))
            arrow.addLine(to:CGPoint(x:point.x-forward.x+side.x,y:point.y-forward.y+side.y))
            arrow.addLine(to:CGPoint(x:point.x-forward.x-side.x,y:point.y-forward.y-side.y));arrow.close()
            (inputMask & UInt16(1<<bit) != 0 ? style.accent:UIColor(hex:classic && style.lightClassic ? 0x151e1b:0x87a9ad)).setFill();arrow.fill()
        }
        SkinDrawing.bevel(UIBezierPath(ovalIn:CGRect(x:center.x-10,y:center.y-10,width:20,height:20)),top:UIColor(hex:0x101a20),bottom:UIColor(hex:0x354a4f),edge:style.keyBorder.withAlphaComponent(0.4),width:1)
        for name in ["B","A","C","X","Y","Z","C↑","C↓","C←","C→","1","2"] {
            guard let r=zones[name] else{continue}
            let bits=style.console.buttonMask(name)
            let selected=inputMask & bits != 0
            if !clear && style.console != .threeDS && !usesLandscapeOverlay {
                let socket=UIBezierPath(roundedRect:r.insetBy(dx:-5,dy:-5),cornerRadius:classic ? 9:r.width/2+5)
                SkinDrawing.bevel(socket,top:UIColor(hex:classic ? 0xe4e5dd:0x51747e),bottom:UIColor(hex:classic ? 0x8a9187:0x1b3943),edge:edge,width:1)
            }
            let depth = UIAccessibility.isReduceMotionEnabled ? (selected ? CGFloat(1) : 0) : pressDepth[name] ?? (selected ? 1 : 0)
            let key=UIBezierPath(ovalIn:r.insetBy(dx:2+depth,dy:2+depth).offsetBy(dx:0,dy:depth*2))
            let top=selected ? UIColor(hex:0xa7643c):classic ? style.actionColor(name):night ? UIColor(hex:0x3b4e69):clear ? style.keyFill:UIColor(hex:0x6fd2b9)
            let bottom=selected ? UIColor(hex:0x6e3b22):classic ? style.actionColor(name).withAlphaComponent(0.75):night ? UIColor(hex:0x152336):clear ? style.keyFill:UIColor(hex:0x207b75)
            SkinDrawing.bevel(key,top:top,bottom:bottom,edge:clear ? style.keyBorder:UIColor(hex:0x0c1c22),width:2,shadow:!selected && !clear)
            if !classic || style.console != .nes || usesLandscapeOverlay {SkinDrawing.text(style.buttonLabel(name),in:r,size:22,color:classic && !selected ? style.actionGlyph(name):night || clear || classic ? style.glyph:UIColor(hex:0x123e40))}
            else {SkinDrawing.text(name,in:r.offsetBy(dx:0,dy:r.height+10).withHeight(18),size:16,color:style.accent,font:"BarlowCondensed-Bold")}
        }
        for name in ["SELECT","START","A+B","L","R","L2","R2","L3","R3","−","+","HOME","SHAKE"] {
            guard let r=zones[name] else{continue}
            let bits=style.console.buttonMask(name)
            let selected=bits != 0 && inputMask & bits == bits
            if style.console == .threeDS || usesLandscapeOverlay {
                let visual=r.insetBy(dx:4,dy:5)
                SkinDrawing.bevel(UIBezierPath(roundedRect:visual,cornerRadius:10),top:selected ? style.accent:UIColor(hex:0x4b5c5a,alpha:clear ? 0.4:1),bottom:UIColor(hex:0x152326,alpha:clear ? 0.4:1),edge:edge,width:1,shadow:!clear && !selected)
                SkinDrawing.text(style.buttonLabel(name),in:visual,size:name == "L" || name == "R" ? 16:10,color:style.glyph)
                continue
            }
            let visual=CGRect(x:r.midX-(name == "A+B" ? 19:24),y:r.minY+4,width:name == "A+B" ? 38:48,height:18)
            SkinDrawing.bevel(UIBezierPath(roundedRect:visual,cornerRadius:9),top:selected ? style.accent:UIColor(hex:0x4b5c5a,alpha:clear ? 0.4:1),bottom:UIColor(hex:0x152326,alpha:clear ? 0.4:1),edge:edge,width:1,shadow:!clear && !selected)
            SkinDrawing.text(style.buttonLabel(name),in:CGRect(x:r.minX-3,y:r.minY+26,width:r.width+6,height:12),size:8,color:classic ? UIColor(hex:0xf46d5c):style.glyph)
        }
        for i in 0..<style.console.analogSticks {
            guard let zone=zones["stick\(i)"] else{continue}
            SkinDrawing.bevel(UIBezierPath(ovalIn:zone),top:style.keyFill,bottom:UIColor(hex:0x080d12),edge:style.keyBorder,width:2)
            let value=stickValues[i] ?? .zero,diameter=zone.width*0.56
            let knob=CGRect(x:zone.midX-diameter/2+value.x*zone.width*0.18,y:zone.midY-diameter/2+value.y*zone.height*0.18,width:diameter,height:diameter)
            SkinDrawing.bevel(UIBezierPath(ovalIn:knob),top:UIColor(hex:0x6c7b87),bottom:UIColor(hex:0x273542),edge:style.keyBorder,width:2,shadow:true)
            SkinDrawing.text(i==0 ? "L":style.console == .gamecube ? "C":style.console == .wii ? "IR":"R",in:knob,size:12,color:style.glyph)
        }
        ctx.restoreGState()
        if showsTouchTargets {
            for zone in zones.values {UIColor.systemTeal.withAlphaComponent(0.14).setFill();UIBezierPath(roundedRect:zone,cornerRadius:5).fill();UIColor.systemTeal.setStroke();let outline=UIBezierPath(roundedRect:zone,cornerRadius:5);outline.lineWidth=1;outline.stroke()}
        }
        if !landscape && !clear {
            for x in [CGFloat(22),bounds.width-24] {
                let screw=CGRect(x:x,y:bounds.height-18,width:5,height:5)
                UIColor(hex:0x78847f).setFill();UIBezierPath(ovalIn:screw).fill()
                UIColor(hex:0x22312c).setFill();UIBezierPath(rect:CGRect(x:x+1,y:screw.midY,width:3,height:1)).fill()
            }
        }
    }

}
final class GameViewController: UIViewController {
    let session:Emulation
    let screen=MetalScreen()
    let deck=TouchDeck()
    private let shell=ConsoleShellView()
    private let bar=UILabel()
    private let menu=UIButton(type:.system)
    private var displayObservers: [AnyCancellable] = []
    init(session:Emulation) {self.session=session;super.init(nibName:nil,bundle:nil)}
    required init?(coder:NSCoder) {fatalError()}
    override var prefersHomeIndicatorAutoHidden:Bool {true}
    override var preferredScreenEdgesDeferringSystemGestures:UIRectEdge {.all}
    override func viewDidLoad() {
        super.viewDidLoad();deck.style=ControlStyle(console:session.game.console);view.backgroundColor=deck.style.background
        for publisher in [ControllerHub.shared.objectWillChange, ExternalDisplayHub.shared.objectWillChange] {
            publisher.sink { [weak self] _ in DispatchQueue.main.async { self?.view.setNeedsLayout() } }.store(in: &displayObservers)
        }
        ExternalDisplayHub.shared.configurePresentation(session.presentation,aspect:session.presentationAspect,isNintendoDS:session.game.console == .ds,console:session.game.console)
        screen.enhancementConsole=session.game.console
        screen.isNintendoDS=session.game.console == .ds
        screen.isNintendo3DS=session.game.console == .threeDS
        screen.acceptsTouchscreen=[.ds,.threeDS,.wii].contains(session.game.console)
        screen.accessibilityLabel="Pantalla \(session.game.console.name)"
        [shell,screen,deck,bar,menu].forEach(view.addSubview)
        bar.text="VETA  /  \(session.game.console.shortName)";bar.font = UIFont(name:"BarlowCondensed-Bold",size:20);bar.textColor = UIColor(hex:0xfff1dd)
        menu.setTitle("  Menú",for:.normal);menu.setImage(UIImage(systemName:"line.3.horizontal"),for:.normal);menu.backgroundColor=UIColor(hex:0x153844);menu.layer.cornerRadius=8;menu.layer.borderWidth=1;menu.layer.borderColor=UIColor(hex:0x779ca7).cgColor;menu.titleLabel?.font = .systemFont(ofSize:13,weight:.semibold)
        menu.tintColor=deck.style.accent;menu.accessibilityIdentifier="pause-game"
        menu.addAction(UIAction { [weak self] _ in self?.session.openMenu() },for:.touchUpInside)
        deck.onInput={ [weak session] inputMask in session?.setTouches(inputMask) }
        deck.onAnalog={ [weak session] index,value in session?.setTouchAnalog(index,value) }
        session.releaseTouches={ [weak deck] in deck?.releaseAll();veta_set_pointer(0,0,false) }
    }
    override func viewDidAppear(_ animated:Bool) {super.viewDidAppear(animated);ExternalDisplayHub.shared.configurePresentation(session.presentation,aspect:session.presentationAspect,isNintendoDS:session.game.console == .ds,console:session.game.console);screen.applyPresentation(session.presentation);session.open(screen:screen)}
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); if isBeingDismissed || navigationController?.isBeingDismissed == true { ExternalDisplayHub.shared.endGame() } }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe=view.safeAreaLayoutGuide.layoutFrame,landscape=safe.width>safe.height
        deck.applySkin(console:session.game.console,landscape:landscape)
        let presentation=session.presentation.resolved(for:session.game.console,landscape:landscape)
        screen.applyPresentation(presentation)
        screen.threeDSSideBySide=session.game.console == .threeDS && landscape
        let aspect:CGFloat=session.game.console == .ds ? presentation.dsLayout.aspect:screen.threeDSSideBySide ? 3:session.presentationAspect
        // Legacy saved layouts retain their canvas; new 3DS edits and the
        // automatic skin both keep the compact 240-point controller.
        let compact3DS=session.game.console == .threeDS && (deck.customLayout == nil || deck.customLayout?.usesCompactThreeDSCanvas == true)
        let layout=ConsoleLayout(safe:safe,aspect:aspect,minimumDeck:session.game.console.minimumDeck,compactDualScreen:compact3DS,overlayLandscape:deck.usesLandscapeOverlay,compactDS:deck.customLayout?.usesCompactDSCanvas == true)
        deck.frame=layout.deck
        shell.frame=view.bounds;shell.style=deck.style;shell.screenRect=layout.screen;shell.portraitSkinTop=landscape ? nil:layout.toolbar.minY;shell.setNeedsDisplay()
        bar.frame=CGRect(x:layout.toolbar.minX+20,y:layout.toolbar.minY,width:185,height:44)
        bar.font=UIFont(name:"BarlowCondensed-Bold",size:landscape ? 20:17)
        menu.frame=deck.usesLandscapeOverlay ? layout.toolbar:CGRect(x:layout.toolbar.maxX-100,y:layout.toolbar.minY,width:80,height:44)
        menu.layer.borderWidth=landscape ? 1:0
        menu.backgroundColor=landscape ? (deck.style.skin == "Clásica" ? UIColor(hex:0xc5c8be):deck.style.keyFill):.clear
        menu.tintColor=landscape && deck.style.skin == "Clásica" ? UIColor(hex:0x36433b):deck.style.headerInk
        deck.landscape=landscape
        screen.frame=layout.screen;deck.frame=layout.deck
        let phoneIsControl = ExternalDisplayHub.shared.connected && ExternalDisplayHub.shared.enabled && ExternalDisplayHub.shared.hidePhonePicture
        screen.alpha = phoneIsControl ? 0 : 1
        let fullScreen = !phoneIsControl && !ControllerHub.shared.devices.isEmpty && (UserDefaults.standard.object(forKey:"native.fullscreenWithController") as? Bool ?? true)
        if deck.isHidden != fullScreen { deck.releaseAll() }
        deck.isHidden = fullScreen; shell.isHidden = fullScreen || deck.usesLandscapeOverlay; bar.isHidden = fullScreen || deck.usesLandscapeOverlay
        if fullScreen {
            let width = min(safe.width, safe.height * aspect), height = width / aspect
            screen.frame = CGRect(x:safe.midX-width/2,y:safe.midY-height/2,width:width,height:height)
            menu.frame = CGRect(x:safe.maxX-92,y:safe.minY+8,width:80,height:44)
            view.backgroundColor = .black
        } else { view.backgroundColor = deck.usesLandscapeOverlay ? .black:deck.style.background }
        if deck.usesLandscapeOverlay {menu.backgroundColor=UIColor.black.withAlphaComponent(0.4);menu.tintColor = .white;menu.layer.borderWidth=0}
        view.bringSubviewToFront(menu)
    }
    func refresh() {
        screen.applyPresentation(session.presentation)
        ExternalDisplayHub.shared.configurePresentation(session.presentation,aspect:session.presentationAspect,isNintendoDS:session.game.console == .ds,console:session.game.console)
        deck.style=ControlStyle(console:session.game.console);view.backgroundColor=deck.style.background
        let classic=deck.style.skin == "Clásica"
        bar.textColor=deck.style.headerInk
        menu.backgroundColor=classic ? UIColor(hex:0xc5c8be):deck.style.keyFill
        menu.tintColor=deck.style.headerInk
        menu.accessibilityValue=deck.style.skin
        view.setNeedsLayout()
    }
    override func viewWillTransition(to size:CGSize,with coordinator:UIViewControllerTransitionCoordinator) {
        deck.releaseAll();veta_set_pointer(0,0,false);super.viewWillTransition(to:size,with:coordinator)
    }
}
