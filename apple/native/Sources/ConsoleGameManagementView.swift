import SwiftUI

/// Selection is scoped to a console, independent of the library's search/tab.
/// Confirm a captured set of identifiers: a later import is never deleted implicitly.
struct ConsoleGameManagementView:View {
    @ObservedObject var library:Library
    @ObservedObject var artwork:ArtworkStore
    let console:GameConsole
    @Environment(\.dismiss) private var dismiss
    @State private var selection=Set<String>()
    @State private var query=""
    @State private var confirmation=Set<String>()
    @State private var showingConfirmation=false
    @State private var busy=false
    @State private var failure:String?
    private var games:[Game] {
        library.games.filter {$0.console == console}.sorted {$0.name.localizedStandardCompare($1.name) == .orderedAscending}
    }
    private var ids:Set<String> {Set(games.map(\.id))}
    private var visible:[Game] {games.filter {query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)}}
    private var selected:Set<String> {selection.intersection(ids)}
    var body:some View {
        let selectedIDs=selected
        NavigationStack {
            List {
                Section {
                    Text(console.name).font(.title2.bold())
                    Text(L10n.format("%d seleccionados de %d juegos",selectedIDs.count,games.count))
                        .foregroundStyle(.secondary).accessibilityIdentifier("bulk-selection-count")
                    Button("Seleccionar toda la consola") {selection=ids}
                        .disabled(ids.isEmpty || selectedIDs == ids).accessibilityIdentifier("bulk-select-all")
                    Button("Quitar selección") {selection.removeAll()}
                        .disabled(selectedIDs.isEmpty).accessibilityIdentifier("bulk-deselect-all")
                }
                Section {
                    TextField("Buscar en tu biblioteca",text:$query)
                        .autocorrectionDisabled().submitLabel(.done).accessibilityIdentifier("bulk-game-search")
                    if visible.isEmpty {
                        Text("No hay juegos que coincidan con esta búsqueda.").foregroundStyle(.secondary)
                    }
                    ForEach(visible) {game in
                        Button {
                            if selection.contains(game.id) {selection.remove(game.id)}
                            else {selection.insert(game.id)}
                        } label:{
                            HStack(spacing:14) {
                                Image(systemName:selectedIDs.contains(game.id) ? "checkmark.circle.fill":"circle")
                                    .font(.title2).foregroundStyle(selectedIDs.contains(game.id) ? VetaTheme.mint:VetaTheme.muted)
                                    .accessibilityHidden(true)
                                Text(game.name).foregroundStyle(.primary).multilineTextAlignment(.leading)
                                Spacer(minLength:0)
                            }.frame(minHeight:44).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityLabel(game.name)
                            .accessibilityAddTraits(selectedIDs.contains(game.id) ? [.isSelected]:[])
                            .accessibilityIdentifier("bulk-game-\(game.id)")
                    }
                } footer:{
                    Text("Buscar no cambia tu selección. Seleccionar toda la consola incluye también los juegos ocultos por la búsqueda.")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .disabled(busy)
            .safeAreaInset(edge:.bottom) {
                VStack(spacing:8) {
                    if busy {ProgressView("Eliminando juegos…")}
                    Button(role:.destructive) {
                        confirmation=selectedIDs;showingConfirmation=true
                    } label:{
                        Label(L10n.format("Eliminar (%d)",selectedIDs.count),systemImage:"trash")
                            .frame(maxWidth:.infinity,minHeight:44)
                    }.buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius:12)).tint(.red)
                        .disabled(selectedIDs.isEmpty || busy).accessibilityIdentifier("bulk-delete")
                }.padding().background(.regularMaterial)
            }
            .navigationTitle("Administrar juegos").navigationBarTitleDisplayMode(.inline)
            .toolbar {ToolbarItem(placement:.cancellationAction) {
                Button("Cerrar") {dismiss()}.disabled(busy).accessibilityIdentifier("bulk-close")
            }}
            .alert("¿Eliminar los juegos seleccionados?",isPresented:$showingConfirmation) {
                Button("Eliminar",role:.destructive) {deleteConfirmed()}.accessibilityIdentifier("bulk-confirm-delete")
                Button("Cancelar",role:.cancel) {confirmation.removeAll()}
            } message:{
                Text(L10n.format("Se eliminarán %d juegos de %@, con sus portadas y todas sus partidas guardadas en VETA. No se puede deshacer. Los originales de Archivos o la nube y los demás juegos se conservan.",confirmation.count,console.name))
            }
            .alert("No se pudo completar la operación",isPresented:Binding(get:{failure != nil},set:{if !$0 {failure=nil}})) {
                Button("Aceptar",role:.cancel) {failure=nil}
            } message:{Text(failure ?? "")}
            .onChange(of:ids) {_,current in selection.formIntersection(current)}
        }.interactiveDismissDisabled(busy)
    }
    private func deleteConfirmed() {
        let captured=confirmation
        guard !captured.isEmpty,!busy else{return}
        busy=true
        Task { @MainActor in
            // Present the disabled state before the single, synchronous transaction.
            await Task.yield()
            defer {busy=false;confirmation.removeAll()}
            do {
                let removed=try library.removeGames(ids:captured,console:console)
                for game in removed {artwork.forget(game)}
                selection.subtract(captured)
                if games.isEmpty {dismiss()}
            } catch {failure=error.localizedDescription}
        }
    }
}
