import SwiftUI
import UIKit

struct ThermalNoticeCard: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let state: ThermalNoticeState
    let minimize: () -> Void
    let expand: () -> Void
    var pause: (() -> Void)?
    private var title: LocalizedStringKey {
        state.level == .critical ? "Temperatura muy alta" : "Temperatura alta"
    }
    var body: some View {
        if state.visible {
            Group {
                if state.collapsed {
                    Button(action: expand) {
                        Label(title, systemImage: "thermometer.high")
                            .font(.subheadline.weight(.semibold)).padding(.horizontal,14).frame(minHeight:44)
                    }
                    .accessibilityHint("Mostrar recomendación de descanso")
                    .accessibilityIdentifier("thermal-notice-expand")
                } else {
                    HStack(alignment:.top,spacing:10) {
                        Image(systemName:"thermometer.high").font(.title3).padding(.top,10).accessibilityHidden(true)
                        VStack(alignment:.leading,spacing:5) {
                            Text(title).font(.headline).fixedSize(horizontal:false,vertical:true)
                            Text(state.level == .critical
                                 ? LocalizedStringKey("Pausa el juego y deja enfriar el dispositivo antes de continuar.")
                                 : LocalizedStringKey("Te recomendamos pausar y dejar enfriar el dispositivo unos minutos."))
                                .font(.subheadline).fixedSize(horizontal:false,vertical:true)
                            if let pause {
                                Button("Pausar juego",action:pause).font(.subheadline.weight(.bold)).frame(minHeight:44)
                                    .accessibilityIdentifier("thermal-notice-pause")
                            }
                        }.padding(.vertical,10)
                        Button(action:minimize) {
                            Image(systemName:"xmark").font(.body.weight(.semibold)).frame(width:44,height:44)
                        }.accessibilityLabel("Minimizar aviso de temperatura")
                            .accessibilityIdentifier("thermal-notice-minimize")
                    }.padding(.leading,14).padding(.trailing,2)
                }
            }
            .foregroundStyle(Color(red:1,green:0.91,blue:0.72))
            .background(Color(red:0.16,green:0.10,blue:0.06).opacity(0.98),in:RoundedRectangle(cornerRadius:14))
            .overlay(RoundedRectangle(cornerRadius:14).stroke(Color.orange.opacity(0.7),lineWidth:1))
            .frame(maxWidth:typeSize.isAccessibilitySize ? 600:420)
            .accessibilityIdentifier("gameplay-thermal-notice")
        }
    }
}

private struct ThermalGameNoticeModifier: ViewModifier {
    let pause: (() -> Void)?
    let topInset: CGFloat
    @State private var state: ThermalNoticeState = {
        var state = ThermalNoticeState()
        // Read before registering notifications, as required by ProcessInfo.
        state.update(ProcessInfo.processInfo.thermalState)
        return state
    }()
    func body(content:Content) -> some View {
        content.overlay(alignment:.top) {
            ThermalNoticeCard(state:state,minimize:{state.minimize()},expand:{state.expand()},pause:pause)
                .padding(.horizontal,12).padding(.top,topInset)
        }
        .onAppear {refresh()}
        .onReceive(NotificationCenter.default.publisher(for:ProcessInfo.thermalStateDidChangeNotification).receive(on:RunLoop.main)) {_ in refresh()}
        .onReceive(NotificationCenter.default.publisher(for:UIApplication.didBecomeActiveNotification).receive(on:RunLoop.main)) {_ in refresh()}
    }
    private func refresh() { state.update(ProcessInfo.processInfo.thermalState) }
}
extension View {
    func gameplayThermalNotice(topInset:CGFloat = 56, pause:(() -> Void)? = nil) -> some View {
        modifier(ThermalGameNoticeModifier(pause:pause,topInset:topInset))
    }
}
