import SwiftUI
import SceneKit

/// One cached render per console. Scrolling does not keep twenty SCNViews alive.
@MainActor private enum ConsoleThumbnailCache {
    static let images=NSCache<NSString,UIImage>()
    static func image(_ console:GameConsole)->UIImage {
        let key=console.rawValue as NSString
        if let cached=images.object(forKey:key) {return cached}
        let view=ConsoleModel.previewView(console:console,interactive:false)
        let renderer=SCNRenderer(device:nil,options:nil)
        renderer.scene=view.scene;renderer.pointOfView=view.pointOfView
        renderer.scene?.background.contents=UIColor.clear
        renderer.pointOfView?.camera?.orthographicScale=2.9
        let image=renderer.snapshot(atTime:0,with:CGSize(width:336,height:208),antialiasingMode:.multisampling4X)
        images.setObject(image,forKey:key,cost:336*208*4)
        return image
    }
}

struct ConsoleThumbnail:View {
    let console:GameConsole
    @State private var image:UIImage?
    var body:some View {
        Group {
            if let image {Image(uiImage:image).resizable().scaledToFit()}
            else {Color.clear}
        }.accessibilityHidden(true).task(id:console) {image=ConsoleThumbnailCache.image(console)}
    }
}

struct ConsoleTimeline:View {
    let consoles:[GameConsole]
    let counts:[GameConsole:Int]
    @Binding var selection:GameConsole?
    @ScaledMetric(relativeTo:.body) private var itemWidth:CGFloat=148
    var body:some View {
        VStack(alignment:.leading,spacing:4) {
            HStack {
                Text("Consolas").font(VetaTheme.body(14).bold())
                Spacer()
                Button("Todas") {selection=nil}
                    .font(VetaTheme.body(13).bold()).foregroundStyle(selection == nil ? VetaTheme.orange:VetaTheme.muted)
                    .frame(minWidth:60,minHeight:44).contentShape(Rectangle())
                    .accessibilityIdentifier("timeline-all").accessibilityAddTraits(selection == nil ? .isSelected:[])
            }
            ScrollViewReader {proxy in
                ScrollView(.horizontal,showsIndicators:false) {
                    LazyHStack(alignment:.top,spacing:0) {
                        ForEach(consoles) {console in
                            Button {selection=console} label:{tile(console)}
                                .buttonStyle(TimelineButtonStyle()).id(console.id)
                                .accessibilityElement(children:.ignore)
                                .accessibilityLabel("\(console.name), \(console.year), \(L10n.gameCount(counts[console,default:0]))")
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAddTraits(selection == console ? .isSelected:[])
                                .accessibilityIdentifier("timeline-\(console.rawValue)")
                        }
                    }.padding(.vertical,4)
                }.onAppear {if let selection {proxy.scrollTo(selection.id,anchor:.center)}}
                    .onChange(of:selection) {value in
                        if let value {proxy.scrollTo(value.id,anchor:.center)}
                        else if let first=consoles.first {proxy.scrollTo(first.id,anchor:.leading)}
                    }
            }
        }
    }
    private func tile(_ console:GameConsole)->some View {
        let selected=selection == console
        return VStack(spacing:6) {
            Text(String(console.year)).font(VetaTheme.body(12).bold()).monospacedDigit()
                .foregroundStyle(selected ? VetaTheme.orange:VetaTheme.muted)
            ZStack {
                Rectangle().fill(VetaTheme.border).frame(height:1)
                Circle().fill(selected ? VetaTheme.orange:VetaTheme.muted).frame(width:selected ? 9:5,height:selected ? 9:5)
            }.frame(height:10).accessibilityHidden(true)
            ConsoleThumbnail(console:console).frame(height:96)
            Text(console.name).font(VetaTheme.body(12).bold()).multilineTextAlignment(.center)
                .lineLimit(2,reservesSpace:true).foregroundStyle(VetaTheme.ink).frame(maxWidth:.infinity)
            Text(L10n.gameCount(counts[console,default:0])).font(VetaTheme.body(12)).foregroundStyle(VetaTheme.muted)
        }.padding(.vertical,10).frame(width:itemWidth)
            .background(selected ? VetaTheme.orange.opacity(0.08):.clear,in:RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).stroke(selected ? VetaTheme.orange:.clear,lineWidth:1.5))
            .contentShape(Rectangle())
    }
}

private struct TimelineButtonStyle:ButtonStyle {
    func makeBody(configuration:Configuration)->some View {
        configuration.label.opacity(configuration.isPressed ? 0.65:1)
    }
}
