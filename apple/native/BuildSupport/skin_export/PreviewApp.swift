import SwiftUI
import UIKit

@main @MainActor struct SkinPreviewApp:App {
    let skin:PersonalSkin
    init() {
        let lib=PersonalSkinLibrary.shared
        let existing=try? lib.list(console:.nes)
        if let first=existing?.first {skin=first}
        else {
            skin=PersonalSkin(name:"Mi mando nocturno",console:"nes",variants:try! ControllerSkinOrientation.allCases.map{try PersonalSkinLibrary.generated(console:.nes,orientation:$0,palette:.night)})
            try! lib.save(skin)
        }
    }
    var body:some Scene {WindowGroup {NavigationStack {
        if ProcessInfo.processInfo.arguments.contains("--collection") {PersonalSkinCollectionView(console:.nes)}
        else {PersonalSkinEditorView(console:.nes,skin:skin)}
    }}}
}
struct ShareItem:Identifiable {let id=UUID();let url:URL}
struct ShareSheet:UIViewControllerRepresentable {
    let url:URL
    func makeUIViewController(context:Context)->UIActivityViewController {UIActivityViewController(activityItems:[url],applicationActivities:nil)}
    func updateUIViewController(_ controller:UIActivityViewController,context:Context){}
}
