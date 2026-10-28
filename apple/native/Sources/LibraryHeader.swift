import SwiftUI

/// Keeps the invitation beside Settings without squeezing the brand or touch targets.
struct VetaLibraryHeader: View {
    @ObservedObject var support: VetaSupportStore = .shared
    @Environment(\.dynamicTypeSize) private var typeSize
    var openSettings: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(compactBrand: false, compactSettings: false)
            row(compactBrand: false, compactSettings: true)
            row(compactBrand: true, compactSettings: true)
        }
    }

    private func row(compactBrand: Bool, compactSettings: Bool) -> some View {
        HStack(spacing: 8) {
            if compactBrand {
                VetaMark().frame(width: 48, height: 48)
                    .accessibilityElement(children: .ignore).accessibilityLabel("VETA Retro")
            } else { VetaBrand().fixedSize() }
            Spacer(minLength: 4)
            if !support.hasContributed {
                NavigationLink { SupportVetaView(store: support) } label: {
                    if typeSize.isAccessibilitySize {
                        Image(systemName: "heart").font(.system(size: 21)).frame(width: 24)
                    } else {
                        Label("Apoyar VETA", systemImage: "heart").lineLimit(1).fixedSize()
                    }
                }
                .buttonStyle(VetaButton(primary: true))
                .accessibilityLabel("Apoyar VETA")
                .accessibilityIdentifier("library-support-veta")
            }
            Button(action: openSettings) {
                if compactSettings || typeSize.isAccessibilitySize {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 21)).frame(width: 24)
                } else { Label("Ajustes", systemImage: "slider.horizontal.3").lineLimit(1).fixedSize() }
            }
            .buttonStyle(VetaButton()).accessibilityLabel("Ajustes")
            .accessibilityIdentifier("open-settings")
        }
    }
}
