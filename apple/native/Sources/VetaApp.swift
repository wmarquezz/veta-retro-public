import SwiftUI
import UniformTypeIdentifiers

@main struct VetaApp: App {
    @StateObject private var library:Library
    init() {
        _ = VetaSupportStore.shared
        #if DEBUG && VETA_JIT_DEVELOPMENT
        _library = StateObject(wrappedValue: PS2Retail165Bootstrap.requested ? Library(root:PS2Retail165Bootstrap.libraryRoot) : Library())
        #else
        _library = StateObject(wrappedValue: Library())
        #endif
    }
    @StateObject private var localization=LocalizationSettings()
    var body: some Scene {WindowGroup {
        #if VETA_JIT_DEVELOPMENT
        Group {
            #if DEBUG
            if PS2Retail165Bootstrap.requested {
                PS2Retail165QAView(library:library)
            } else {
                developmentContent
            }
            #else
            developmentContent
            #endif
        }.preferredColorScheme(.dark)
            .environmentObject(localization).environment(\.locale,localization.locale).environment(\.layoutDirection,localization.layoutDirection)
            .onOpenURL { _ in }
        #else
        LibraryView(library:library).preferredColorScheme(.dark)
            .environmentObject(localization).environment(\.locale,localization.locale).environment(\.layoutDirection,localization.layoutDirection)
        #endif
    }}
    #if VETA_JIT_DEVELOPMENT
    @ViewBuilder private var developmentContent:some View {
            if ProcessInfo.processInfo.arguments.contains("--veta165-webjit") {
                #if DEBUG
                WebJIT165ProbeView(library: library)
                #else
                LibraryView(library: library)
                #endif
            } else if ProcessInfo.processInfo.arguments.contains("--commercial170-qa") {
                Commercial170QAView(library:library)
            } else if ProcessInfo.processInfo.arguments.contains("--veta165-qa") {
                Veta165QAView(library: library)
            } else if ProcessInfo.processInfo.arguments.contains("--save-gallery-qa") {
                SaveGalleryQAView()
            } else if ProcessInfo.processInfo.arguments.contains("--native-diagnostics") {
                JITDevelopmentRoot(library:library)
            } else {
                LibraryView(library:library)
            }
    }
    #endif
}
struct ShareItem: Identifiable { let id=UUID();let url:URL }
struct ShareSheet:UIViewControllerRepresentable {
    let url:URL
    func makeUIViewController(context:Context)->UIActivityViewController {UIActivityViewController(activityItems:[url],applicationActivities:nil)}
    func updateUIViewController(_ controller:UIActivityViewController,context:Context) {}
}
struct LibraryView:View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var localization:LocalizationSettings
    @ObservedObject var library:Library
    @StateObject private var artwork:ArtworkStore
    @State private var artworkGame:Game?
    @State private var profileGame:Game?
    @State private var guideGame:Game?
    @State private var deletionGame:Game?
    @State private var managementConsole:GameConsole?
    @Environment(\.scenePhase) private var scenePhase
    init(library:Library) {self.library=library;_artwork=StateObject(wrappedValue:ArtworkStore(root:library.root))}
    @State private var query=""
    @State private var filter="Biblioteca"
    @State private var importFolder:GameImportLocation?
    @State private var importOptions=false
    @State private var importChoice:GameImportChoice?
    @State private var directCloud=false
    @State private var sharedCloud=false
    @StateObject private var cloudImport=CloudImportModel()
    @State private var settings=false
    @State private var previewConsole:GameConsole?
    @State private var consoleFilter:GameConsole?
    @State private var consoleGames:GameConsole?
    @State private var activeLaunch:GameLaunchRequest?
    @FocusState private var searchFocused:Bool
    @State private var share:ShareItem?
    @State private var importMessage:String?
    @State private var importingExperimental=false
    private var selectedLibraryConsole:GameConsole? {filter == "Consolas" ? consoleGames:consoleFilter}
    var filtered:[Game] {
        library.games.filter {game in
            GameConsole.allCases.contains(game.console) && (selectedLibraryConsole == nil || game.console == selectedLibraryConsole) && (filter != "Favoritos" || game.favorite) && (filter != "Recientes" || game.lastPlayed != nil) &&
            (query.isEmpty || game.name.localizedCaseInsensitiveContains(query))
        }.sorted {a,b in filter == "Recientes" ? (a.lastPlayed ?? .distantPast) > (b.lastPlayed ?? .distantPast):a.name.localizedStandardCompare(b.name) == .orderedAscending}
    }
    @AppStorage("native.libraryList") private var listView=false
    @AppStorage(GameLaunchPlan.Preference.key) private var advancedExecution=GameLaunchPlan.Preference.automatic.rawValue
    @State private var showFreeGames=false
    private let tabs=["Consolas","Biblioteca","Favoritos","Recientes"]
    var body:some View {
        NavigationStack {
            VStack(spacing:0) {
                VetaLibraryHeader(openSettings: {settings=true})
                    .padding(.horizontal,20).padding(.top,8).padding(.bottom,14)
                if dynamicTypeSize.isAccessibilitySize {
                    Picker("Biblioteca",selection:$filter) {
                        ForEach(tabs,id:\.self) {tab in Text(LocalizedStringKey(tab)).tag(tab)}
                    }.pickerStyle(.menu).padding(.horizontal,20).frame(maxWidth:.infinity,alignment:.leading)
                        .onChange(of:filter) {_ in query="";consoleGames=nil}
                } else {
                HStack(spacing:0) {
                    ForEach(tabs,id:\.self) {tab in
                        Button {filter=tab;query="";consoleGames=nil} label:{
                            VStack(spacing:10) {
                                Text(LocalizedStringKey(tab)).font(VetaTheme.body(12).weight(.bold)).lineLimit(1).minimumScaleFactor(0.8)
                                Rectangle().fill(filter == tab ? VetaTheme.mint:.clear).frame(height:3)
                            }.frame(maxWidth:.infinity).padding(.top,12).contentShape(Rectangle())
                        }.buttonStyle(.plain).foregroundStyle(filter == tab ? VetaTheme.mint:VetaTheme.muted).accessibilityIdentifier("tab-\(tab)").accessibilityAddTraits(filter == tab ? .isSelected:[])
                    }
                }.padding(.horizontal,16).overlay(alignment:.bottom){VetaTheme.border.frame(height:1)}
                }
                if filter == "Consolas",consoleGames != nil {
                    HStack {
                        Button {consoleGames=nil;query=""} label:{Label("Tus consolas",systemImage:"chevron.left")}
                            .font(VetaTheme.body(15).bold()).frame(minHeight:44)
                            .accessibilityIdentifier("back-to-consoles")
                        Spacer()
                    }.padding(.horizontal,20).background(VetaTheme.background)
                }
                ScrollView {
                    VStack(alignment:.leading,spacing:22) {
                        if filter == "Consolas" {
                            if let console=consoleGames {
                                consoleGamesHeader(console)
                                gameCollection
                            } else {consoleHero}
                        } else {
                            libraryHeader
                            gameCollection
                            freeGames
                        }
                        HStack {VetaMark().frame(width:24,height:24);Text("VETA Retro").font(VetaTheme.heading(20));Spacer();Text("Hecho para jugar").font(VetaTheme.body(11)).foregroundStyle(VetaTheme.muted)}.padding(.top,12)
                    }.frame(maxWidth:1000).padding(20).frame(maxWidth:.infinity)
                }.id(filter == "Consolas" ? (consoleGames?.rawValue ?? "consoles-root"):filter)
                    .scrollDismissesKeyboard(.interactively)
            }.background(VetaBackdrop()).toolbar(.hidden,for:.navigationBar)
        }.tint(VetaTheme.mint).foregroundStyle(VetaTheme.ink)
        .sheet(item:$importFolder) {folder in
            GameFilePicker(directory:folder.directory,allowsDirectories:!folder.cloud,directoriesOnly:folder.folderOnly) {urls in
                importFolder=nil
                if folder.cloud {finishCloudImport(urls)} else {finishImport(urls)}
            }
        }
        .sheet(isPresented:$importOptions,onDismiss:applyImportChoice) {
            GameImportOptionsView { choice in
                importChoice=choice
                importOptions=false
            }
        }
        .sheet(isPresented:$sharedCloud) {
            KrafifySharedAccessView { snapshot in
                try library.importURLs(snapshot.files,console:selectedLibraryConsole,artwork:artwork).message
            }
        }
        .sheet(isPresented:$directCloud) {
            DirectCloudView { snapshot in
                try library.importURLs(snapshot.files,console:selectedLibraryConsole,artwork:artwork).message
            }
        }
        .fullScreenCover(item:$activeLaunch,onDismiss:{query=""}) {launch in
            let game=launch.game
            #if VETA_JIT_DEVELOPMENT
            if launch.plan.mode == .webAssembly && game.console == .ps2 {PS2WebGameContainer(game:game,library:library)}
            else if launch.plan.mode == .webAssembly && game.console == .dreamcast {DreamcastWebGameContainer(game:game,library:library)}
            else if game.console.isStandaloneEngine {NativeGameContainer(game:game,library:library,plan:launch.plan)}
            else if JITGameContainer.handles(launch.plan) {JITGameContainer(game:game,library:library,plan:launch.plan)}
            else {GameContainer(game:game,library:library,plan:launch.plan)}
            #else
            GameContainer(game:game,library:library,plan:launch.plan)
            #endif
        }
        .overlay {if importingExperimental {ProgressView("Copiando juego…").padding(24).background(VetaTheme.panel,in:RoundedRectangle(cornerRadius:12))}}
        .overlay {if cloudImport.busy {CloudImportProgressView(model:cloudImport)}}
        .sheet(item:$guideGame) {game in GameGuidesView(game:game,library:library)}
        .sheet(item:$profileGame) {game in GameProfileSettings(game:game,library:library)}
        .sheet(item:$artworkGame) {game in ArtworkView(game:game,artwork:artwork,fallback:artURL(game))}
        .task(id:library.games.map(\.id)) {artwork.schedule(library.games)}
        .onChange(of:scenePhase) {phase in if phase == .active {artwork.schedule(library.games)}}
        .onChange(of:artwork.enabled) {enabled in if enabled {artwork.schedule(library.games)}}
        .sheet(isPresented:$settings) {settingsView}
        .sheet(isPresented:$showFreeGames) {NavigationStack {ScrollView {DiscoveryView(library:library).padding()}.background(VetaTheme.background).tint(VetaTheme.mint).navigationTitle("Juegos por consola").toolbar {Button("Listo"){showFreeGames=false}}}}
        .sheet(item:$previewConsole) {console in ConsoleSkinPicker(console:console)}
        .sheet(item:$managementConsole) {console in
            ConsoleGameManagementView(library:library,artwork:artwork,console:console)
        }
        .alert("¿Eliminar juego de VETA?",isPresented:Binding(get:{deletionGame != nil},set:{if !$0 {deletionGame=nil}}),presenting:deletionGame) {game in
            Button("Eliminar juego",role:.destructive) {
                perform {try library.remove(game);artwork.forget(game)}
                deletionGame=nil
            }.accessibilityIdentifier("confirm-delete-game")
            Button("Cancelar",role:.cancel){deletionGame=nil}
        } message:{game in
            Text(L10n.format("Se eliminarán «%@», su portada y sus partidas guardadas de VETA. Esta acción no se puede deshacer. Los archivos originales en Archivos y los demás juegos se conservarán.",game.name))
        }
        .onChange(of:library.populatedConsoles) { _, available in
            if let consoleFilter, !available.contains(consoleFilter) { self.consoleFilter=nil }
            if let consoleGames, !available.contains(consoleGames) { self.consoleGames=nil }
        }
        .alert("VETA Retro",isPresented:Binding(get:{library.error != nil},set:{if !$0 {library.error=nil}})) {Button("Aceptar"){library.error=nil}} message:{Text(L10n.text(library.error ?? ""))}
        .alert("Biblioteca",isPresented:Binding(get:{importMessage != nil},set:{if !$0 {importMessage=nil}})) {Button("Listo"){importMessage=nil}} message:{Text(L10n.text(importMessage ?? ""))}
    }
    private var libraryHeader:some View {
        VStack(alignment:.leading,spacing:18) {
            ViewThatFits(in:.horizontal) {
                HStack {Text(LocalizedStringKey(filter)).font(VetaTheme.heading(36));Spacer(minLength:12);addButton}
                VStack(alignment:.leading,spacing:12) {Text(LocalizedStringKey(filter)).font(VetaTheme.heading(36));addButton}
            }
            HStack(spacing:10) {
                Image(systemName:"magnifyingglass").foregroundStyle(VetaTheme.muted)
                TextField("Buscar en tu biblioteca",text:$query).font(VetaTheme.body()).autocorrectionDisabled().focused($searchFocused).submitLabel(.search).onSubmit {searchFocused=false}.accessibilityIdentifier("library-search")
                if !query.isEmpty {Button {query=""} label:{Image(systemName:"xmark.circle.fill")}.accessibilityLabel("Borrar búsqueda")}
            }.padding(.horizontal,14).frame(minHeight:50).background(VetaTheme.panel,in:RoundedRectangle(cornerRadius:9)).overlay(RoundedRectangle(cornerRadius:9).stroke(VetaTheme.border))
            HStack {
                Button {showFreeGames=true} label:{Label("Juegos gratis",systemImage:"gift")}.buttonStyle(VetaButton()).accessibilityIdentifier("free-games")
                Spacer()
                Button {listView=false} label:{Image(systemName:"square.grid.2x2.fill").frame(width:44,height:44)}.foregroundStyle(listView ? VetaTheme.muted:VetaTheme.mint).accessibilityLabel("Ver portadas").accessibilityIdentifier("view-covers")
                Button {listView=true} label:{Image(systemName:"list.bullet").frame(width:44,height:44)}.foregroundStyle(listView ? VetaTheme.mint:VetaTheme.muted).accessibilityLabel("Ver lista").accessibilityIdentifier("view-list")
            }

            Menu {
                ForEach(library.populatedConsoles) {console in
                    Button(console.name) {managementConsole=console}
                }
            } label:{Label("Administrar juegos",systemImage:"checklist")}
                .buttonStyle(VetaButton()).disabled(library.populatedConsoles.isEmpty)
                .accessibilityIdentifier("manage-library-games")
            ConsoleTimeline(
                consoles:library.populatedConsoles,
                counts:Dictionary(grouping:library.games,by: \.console).mapValues(\.count),selection:$consoleFilter)
            Text("Portada opcional: Juego.zip + Juego.png. Selecciona ambos archivos o importa su carpeta.").font(VetaTheme.body(12)).foregroundStyle(VetaTheme.muted)
            Text(L10n.gameCount(filtered.count)).font(VetaTheme.body(12)).foregroundStyle(VetaTheme.muted)
        }
    }
    private func openImporter() {if !cloudImport.busy {importOptions=true}}
    private func applyImportChoice() {
        guard let choice=importChoice else{return}
        importChoice=nil
        switch choice {
        case .files: importFolder=GameImportLocation(cloud:true)
        case .folder: importFolder=GameImportLocation(cloud:true,folderOnly:true)
        case .cloud: directCloud=true
        case .shared: sharedCloud=true
        }
    }
    private func finishCloudImport(_ urls:[URL]) {
        guard !urls.isEmpty,!cloudImport.busy else{return}
        let console=selectedLibraryConsole
        Task { @MainActor in
            defer {cloudImport.finish()}
            do {
                let snapshot=try await cloudImport.prepare(urls)
                defer {snapshot.remove()}
                await Task.yield()
                let result=try library.importURLs(snapshot.files,console:console,artwork:artwork)
                importMessage=result.message
            } catch is CancellationError {
                importMessage="Importación cancelada. Tus originales y tu biblioteca se conservan."
            } catch {
                library.error=L10n.text(error.localizedDescription)+"\n"+L10n.text("Puedes volver a intentarlo. Los juegos ya agregados y sus partidas se conservan.")
            }
        }
    }
    private func finishImport(_ urls:[URL]) {
        // UIKit may dismiss the picker before delivering its selection.
        // Import from the delegate callback, never from the sheet onDismiss.
        guard !urls.isEmpty else{return}
        #if VETA_JIT_DEVELOPMENT
        if let console=selectedLibraryConsole,console.isStandaloneEngine {
            guard !importingExperimental else{return}
            importingExperimental=true
            Task { @MainActor in
                defer {importingExperimental=false}
                do {for url in urls {_ = try await library.importExperimentalInBackground(url,console:console)};importMessage="Importación completada. Los juegos duplicados se conservan una sola vez."}
                catch {library.error=error.localizedDescription}
            }
            return
        }
        #endif
        perform {
            let result=try library.importURLs(urls,console:selectedLibraryConsole,artwork:artwork)
            importMessage=result.message
        }
    }
    private var addButton:some View {Button(action:openImporter) {Label("Agregar juegos",systemImage:"plus")}.buttonStyle(VetaButton(primary:true)).accessibilityIdentifier("toolbar-import").disabled(importingExperimental)}
    private var gameCollection:some View {
        Group {
            if filtered.isEmpty {
                VStack(spacing:14) {
                    Image(systemName:"square.stack.3d.up").font(.system(size:32)).foregroundStyle(VetaTheme.mint)
                    Text(LocalizedStringKey(library.games.isEmpty ? "Tu biblioteca empieza aquí":"Sin juegos en esta vista")).font(VetaTheme.heading(28))
                    Text(LocalizedStringKey(library.games.isEmpty ? "Agrega tus juegos o descubre los juegos gratuitos de VETA.":"Prueba otra búsqueda o añade juegos a favoritos.")).font(VetaTheme.body()).foregroundStyle(VetaTheme.muted).multilineTextAlignment(.center)
                    Button("Importar juegos",action:openImporter).buttonStyle(VetaButton(primary:true)).accessibilityIdentifier("import-games")
                }.padding(24).frame(maxWidth:.infinity).background(VetaTheme.panel,in:RoundedRectangle(cornerRadius:12))
            } else if listView {
                LazyVStack(spacing:10) {ForEach(filtered) {game in gameRow(game)}}
            } else {
                LazyVGrid(columns:[GridItem(.adaptive(minimum:140,maximum:230),spacing:16)],spacing:22) {ForEach(filtered) {game in gameCard(game)}}
            }
        }
    }
    private func gameCard(_ game:Game)->some View {
        VStack(alignment:.leading,spacing:0) {
            Button {launch(game)} label:{GameCover(game:game,artURL:artURL(game),coverImage:artwork.image(game))}.buttonStyle(.plain).accessibilityLabel(L10n.format("Jugar %@",game.name)).accessibilityIdentifier("game-\(game.name)")
                .overlay(alignment:.topTrailing) {gameActions(game).padding(6)}
            VStack(alignment:.leading,spacing:2) {
                Text(game.name).font(VetaTheme.body(13).bold()).lineLimit(2).frame(maxWidth:.infinity,alignment:.leading)
                HStack(spacing:0) {
                    Text(game.console.shortName).font(VetaTheme.body(10)).foregroundStyle(VetaTheme.muted)
                    Spacer(minLength:0);coverButton(game);favoriteButton(game)
                }
            }.padding(.top,10)
        }.contextMenu {gameMenu(game)}
    }
    private func gameRow(_ game:Game)->some View {
        HStack(spacing:12) {
            Button {launch(game)} label:{
                HStack(spacing:14) {
                    GameCover(game:game,artURL:artURL(game),coverImage:artwork.image(game),compact:true).frame(width:60)
                    VStack(alignment:.leading,spacing:6) {Text(game.name).font(VetaTheme.body(15).bold());Text(game.console.shortName + " · " + L10n.text(game.lastPlayed == nil ? "Listo para jugar":"Continuar")).font(VetaTheme.body(11)).foregroundStyle(VetaTheme.muted)}
                    Spacer(minLength:0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("game-\(game.name)")
            gameActions(game)
            favoriteButton(game)
        }.padding(10).background(VetaTheme.panel,in:RoundedRectangle(cornerRadius:10)).contextMenu {gameMenu(game)}
    }
    private func gameActions(_ game:Game)->some View {
        Menu {gameMenu(game)} label:{
            Image(systemName:"ellipsis").font(.system(size:18,weight:.bold)).frame(width:44,height:44).background(VetaTheme.background.opacity(0.9),in:Circle())
        }.foregroundStyle(VetaTheme.ink).accessibilityLabel(L10n.format("Opciones de %@",game.name)).accessibilityIdentifier("options-\(game.name)")
    }
    private func coverButton(_ game:Game)->some View {
        Button {artworkGame=game} label:{Image(systemName:"photo").frame(width:44,height:44)}.buttonStyle(.plain).foregroundStyle(VetaTheme.muted).accessibilityLabel(L10n.format("Cambiar portada de %@",game.name)).accessibilityIdentifier("cover-\(game.name)")
    }
    private func favoriteButton(_ game:Game)->some View {
        Button {var g=game;g.favorite.toggle();library.update(g)} label:{Image(systemName:game.favorite ? "heart.fill":"heart").foregroundStyle(game.favorite ? VetaTheme.orange:VetaTheme.muted).frame(width:44,height:44)}.buttonStyle(.plain).accessibilityLabel(L10n.format(game.favorite ? "Quitar %@ de favoritos":"Añadir %@ a favoritos",game.name)).accessibilityIdentifier("favorite-\(game.name)")
    }
    @ViewBuilder private func gameMenu(_ game:Game)->some View {
        Button("Cambiar portada",systemImage:"photo") {artworkGame=game}
        Button("Guía del juego",systemImage:"book") {guideGame=game}
        Button("Perfiles del juego",systemImage:"slider.horizontal.3") {profileGame=game}
        Button(LocalizedStringKey(game.favorite ? "Quitar de favoritos":"Añadir a favoritos"),systemImage:"heart") {var g=game;g.favorite.toggle();library.update(g)}
        if game.console == .nes {Menu(L10n.format("Región: %@",game.region)) {ForEach(["Auto","NTSC","PAL","Dendy"],id:\.self){region in Button(region){var g=game;g.region=region;library.update(g)}}}}
        Divider()
        Button("Eliminar juego",systemImage:"trash",role:.destructive) {deletionGame=game}.accessibilityIdentifier("delete-game")
    }
    private func consoleGamesHeader(_ console:GameConsole)->some View {
        VStack(alignment:.leading,spacing:16) {
            HStack(spacing:16) {
                ConsoleThumbnail(console:console).frame(width:112,height:96)
                VStack(alignment:.leading,spacing:6) {
                    Text(console.name).font(VetaTheme.heading(32)).fixedSize(horizontal:false,vertical:true)
                    Text(L10n.gameCount(filtered.count)).font(VetaTheme.body(14)).foregroundStyle(VetaTheme.muted)
                }
                Spacer(minLength:0)
            }
            TextField("Buscar en tu biblioteca",text:$query).font(VetaTheme.body()).autocorrectionDisabled()
                .focused($searchFocused).submitLabel(.search).onSubmit {searchFocused=false}
                .padding(14).background(VetaTheme.panel,in:RoundedRectangle(cornerRadius:9))
                .accessibilityIdentifier("console-game-search")
            ViewThatFits(in:.horizontal) {
                HStack {manageGamesButton(console);Spacer();addButton}
                VStack(alignment:.leading) {manageGamesButton(console);addButton}
            }
        }
    }
    private func manageGamesButton(_ console:GameConsole)->some View {
        Button {managementConsole=console} label:{Label("Administrar juegos",systemImage:"checklist")}
            .buttonStyle(VetaButton()).accessibilityIdentifier("manage-console-games")
    }
    private var consoleHero:some View {
        LazyVStack(alignment:.leading,spacing:20) {
            HStack {Text("Tus consolas").font(VetaTheme.heading(36));Spacer();addButton}
            Text("Todas las consolas compatibles están disponibles. Aquí aparecen sólo las que tienen juegos.").font(VetaTheme.body()).foregroundStyle(VetaTheme.muted)
            if library.populatedConsoles.isEmpty { Text("Agrega tu primer juego y su consola aparecerá aquí automáticamente.").font(VetaTheme.body()).foregroundStyle(VetaTheme.muted) }
            LazyVStack(spacing:0) {
                ForEach(library.populatedConsoles) {console in
                    HStack(spacing:8) {
                        Button {consoleGames=console;query=""} label:{
                            HStack(spacing:10) {
                                Text(String(console.year)).font(VetaTheme.body(12).bold()).monospacedDigit()
                                    .foregroundStyle(VetaTheme.mint).lineLimit(1).minimumScaleFactor(0.5).frame(width:38)
                                ZStack {
                                    Rectangle().fill(VetaTheme.border).frame(width:1)
                                    Circle().fill(VetaTheme.mint).frame(width:7,height:7)
                                }.frame(width:8).accessibilityHidden(true)
                                ConsoleThumbnail(console:console).frame(width:110,height:98)
                                VStack(alignment:.leading,spacing:5) {
                                    Text(console.name).font(VetaTheme.heading(23)).fixedSize(horizontal:false,vertical:true)
                                    Text(L10n.gameCount(library.games.filter{$0.console == console}.count))
                                        .font(VetaTheme.body(12)).foregroundStyle(VetaTheme.muted)
                                    if !console.playable {
                                        Text(LocalizedStringKey(console.isStandaloneEngine ? console.availability:"Requiere JIT"))
                                            .font(VetaTheme.body(12)).foregroundStyle(VetaTheme.orange)
                                    }
                                }.frame(maxWidth:.infinity,alignment:.leading)
                            }.frame(minHeight:128).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityElement(children:.ignore)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel("\(console.year), \(console.name), \(L10n.gameCount(library.games.filter{$0.console == console}.count))")
                            .accessibilityHint("Ver juegos").accessibilityIdentifier("console-games-\(console.rawValue)")
                        Button {previewConsole=console} label:{
                            Image(systemName:"gamecontroller").font(.system(size:16)).frame(width:44,height:44)
                                .background(VetaTheme.panel,in:Circle())
                        }.buttonStyle(.plain).foregroundStyle(VetaTheme.mint)
                            .accessibilityLabel("\(L10n.text("Ver skin")): \(console.name)")
                            .accessibilityHint("Ver skin").accessibilityIdentifier("console-skin-\(console.rawValue)")
                    }
                }
            }

        }
    }
    private var freeGames:some View {DiscoveryView(library:library)}
    private var freeGameChoices:some View {DiscoveryView(library:library)}

    private var settingsView:some View {
        NavigationStack {
            Form {
                Section {VetaBrand().padding(.vertical,12).listRowBackground(VetaTheme.panel)}
                Section("Tu biblioteca") {
                    Text(L10n.gameCount(library.games.count))
                    Button("Exportar respaldo nativo") {perform {share=ShareItem(url:try library.export())}}
                    Text("El respaldo .vetaretro incluye juegos, favoritos, recientes, portadas y partidas de esta versión, hasta 128 MB por biblioteca.").font(.caption).foregroundStyle(VetaTheme.muted)
                    #if VETA_JIT_DEVELOPMENT
                    Text("Al confirmar una consola se crea su carpeta en Archivos → En mi iPhone (o iPad) → VETA-Retro. Agrega cartuchos NES, SNES, GB, GBC, GBA, Mega Drive, Master System, Game Gear, Atari 2600, PC Engine y DS. Para PlayStation y Saturn selecciona el CUE junto con todas sus pistas BIN o WAV. También puedes importar N64 (Z64/V64/N64), PSP (ISO/CSO/PBP/PRX), 3DS (3DSX/CCI/3DS/CXI), Dreamcast (CDI/CHD/ELF), GameCube/Wii (ISO/GCM/RVZ/WBFS/DOL) y PS2 (ISO/ELF), según la disponibilidad indicada en cada consola.").font(.caption).foregroundStyle(VetaTheme.muted)
                    #else
                    Text("Todas las consolas compatibles están disponibles. Importa desde Agregar juegos; cada consola aparece en tu biblioteca cuando tiene juegos. También puedes usar sus carpetas en Archivos → En mi iPhone → VETA-Retro.").font(.caption).foregroundStyle(VetaTheme.muted)
                    #endif
                }.listRowBackground(VetaTheme.panel)
                Section("Experiencia") {
                    NavigationLink("Idioma") {LanguageSettingsView()}.accessibilityIdentifier("language-settings")
                    NavigationLink("Este dispositivo") {DeviceReadinessView()}.accessibilityIdentifier("device-readiness")
                    NavigationLink("Funciones de esta versión") {FeatureAccessView()}.accessibilityIdentifier("feature-access")
                    NavigationLink("Mandos y jugadores") {ControllerSettingsView(console:selectedLibraryConsole ?? .nes)}
                    NavigationLink("Mis skins por consola") {SkinsByConsoleView()}.accessibilityIdentifier("personal-skins-main")
                    NavigationLink("Jugar juntos") {PlayTogetherView(console:selectedLibraryConsole ?? .nes)}
                    NavigationLink("TV y pantalla completa") {ExternalDisplaySettingsView()}
                }.listRowBackground(VetaTheme.panel)
                #if VETA_JIT_DEVELOPMENT
                Section("Consolas avanzadas") {
                    Picker("Modo de juego",selection:$advancedExecution) {
                        Text("Automático").tag(GameLaunchPlan.Preference.automatic.rawValue)
                        Text("Máximo rendimiento").tag(GameLaunchPlan.Preference.maximumPerformance.rawValue)
                    }.accessibilityIdentifier("advanced-execution-mode")
                    Text("Automático usa JIT si ya está activo; si no, usa el motor local disponible. PS2 requiere JIT.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Máximo rendimiento conserva la preparación de JIT. Cambiar el modo se aplica al próximo juego. Las partidas rápidas de cada modo se guardan por separado.")
                        .font(.footnote).foregroundStyle(.secondary)
                    #if VETA_EMBEDDED_JIT
                    NavigationLink(L10n.text("Activar JIT en este iPhone")) { JITSetupView() }
                        .accessibilityIdentifier("jit-setup-guide")
                    #endif
                }.listRowBackground(VetaTheme.panel)
                #endif
                Section("Portadas") {
                    if ArtworkDistributionPolicy.allowsRemoteCovers {
                    Toggle("Descargar portadas automáticamente",isOn:$artwork.enabled).accessibilityIdentifier("auto-artwork")
                    Text("Busca imágenes para los juegos existentes y los que agregues. Se guardan para verlas sin conexión; las imágenes personales tienen prioridad. También puedes cambiar la portada con el botón de imagen junto a cada juego.").font(.caption).foregroundStyle(VetaTheme.muted)
                    Text("Solo se consultan catálogos e imágenes de Libretro Thumbnails. Tus juegos y partidas no se envían.").font(.caption).foregroundStyle(VetaTheme.muted)
                    Link("Libretro Thumbnails",destination:URL(string:"https://github.com/libretro-thumbnails/libretro-thumbnails")!)
                    } else {
                        Text("Para añadir una portada, importa el juego y una imagen con el mismo nombre: Juego.zip y Juego.png. También puedes elegirla desde Cambiar portada. VETA guarda una copia en el iPhone.").font(.caption).foregroundStyle(VetaTheme.muted)
                    }
                }.listRowBackground(VetaTheme.panel)
                Section {
                    NavigationLink {SupportVetaView()} label: {Label("Apoyar VETA",systemImage:"heart")}
                        .accessibilityIdentifier("support-veta")
                    Text("Aporte voluntario. Todas las funciones siguen siendo gratuitas.").font(.footnote).foregroundStyle(VetaTheme.muted)
                }.listRowBackground(VetaTheme.panel)
                Section("Ayuda y privacidad") {
                    NavigationLink("Privacidad y datos") {PrivacyDetailsView()}.accessibilityIdentifier("privacy-details")
                    NavigationLink("Ayuda y soporte") {PublicationSupportView()}.accessibilityIdentifier("publication-support")
                    NavigationLink("Uso de juegos y licencias") {GameRightsView()}
                }.listRowBackground(VetaTheme.panel)
                Section("Esta versión") {
                    Text(verbatim: "VETA Retro · \(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? ""))")
                    #if VETA_JIT_DEVELOPMENT
                    Text(L10n.format("Motores incluidos: %@. Automático aprovecha JIT activo; Máximo rendimiento puede solicitar su preparación.",GameConsole.chronological.filter(\.playable).map(\.name).joined(separator:", "))).font(.footnote).foregroundStyle(VetaTheme.muted)
                    #else
                    Text(GameConsole.chronological.filter(\.playable).map(\.name).joined(separator:", ")).font(.footnote).foregroundStyle(VetaTheme.muted)
                    #endif
                }.listRowBackground(VetaTheme.panel)
                Section("Créditos") {
                    NavigationLink("VETA Retro · GPL-3.0-or-later") {ScrollView {
                        Text((Bundle.main.url(forResource:"VETA-LICENSE",withExtension:"txt",subdirectory:"Content")
                            .flatMap {try? String(contentsOf:$0,encoding:.utf8)}) ?? L10n.text("No se encontraron las licencias."))
                            .font(.caption.monospaced()).padding().textSelection(.enabled)
                    }}
                    #if VETA_JIT_DEVELOPMENT
                    NavigationLink("Licencias de motores") {ScrollView {
                        Text(experimentalEngineLicenses()).font(.caption.monospaced()).padding()
                    }}
                    #endif
                    if let url=PublicationInfo().webURL("SourceCodeURL") {
                        Link("Código fuente · VETA Retro",destination:url)
                    }
                    Text("FCEUmm · ac0d00a · GNU GPL v2")
                    #if VETA_ATARI_TIA
                    Text("jgenesis · Tia · Beetle PCE Fast · PCSX ReARMed · DeSmuME · Beetle Saturn")
                    #else
                    Text("jgenesis · Stella 2014 · Beetle PCE Fast · PCSX ReARMed · DeSmuME · Beetle Saturn")
                    #endif
                    NavigationLink("Fuentes y licencias de motores adicionales") {ScrollView {Text(extraEngineLicenses()).font(.caption.monospaced()).padding()}}
                    Text("mGBA · 0.10.5 · MPL 2.0")
                    Text("bsnes-mercury · GPL v3")
                    ForEach(["mGBA","BSNES","JGenesis","MelonDS"],id:\.self) {motor in
                        NavigationLink(L10n.format("Licencia %@",motor)){ScrollView {Text((try? String(contentsOf:Bundle.main.url(forResource:motor+"-LICENSE",withExtension:"txt",subdirectory:"Content")!)) ?? "").font(.caption.monospaced()).padding()}}
                    }
                    Link("Fuentes del motor",destination:URL(string:"https://github.com/libretro/libretro-fceumm/tree/ac0d00a7fc01166f84c7bac01d1084ebfd2b865e")!)
                    NavigationLink("Licencia del motor") {ScrollView {Text(license()).font(.caption.monospaced()).padding()}.navigationTitle("FCEUmm")}
                    if let fontLicenseURL = Bundle.main.url(forResource:"PPSSPP-FONTS-LICENSE",withExtension:"txt",subdirectory:"Content") {
                        NavigationLink("PPSSPP · Roboto, Noto, Source Han Sans, Ume") {ScrollView {
                            Text((try? String(contentsOf:fontLicenseURL,encoding:.utf8)) ?? "")
                                .font(.caption.monospaced()).padding().textSelection(.enabled)
                        }}
                    }
                    #if VETA_JIT_DEVELOPMENT
                    Text("Thwaite y Concentration Room · Damian Yerrick. Licencias y fuentes incluidas.").font(.footnote)
                    #else
                    Text("A_KANOID · Toxa. Space Game · EllAyling. MIT.").font(.footnote)
                    #endif
                    Text("Barlow Condensed · Jeremy Tribby. Manrope · Mikhail Sharanda. SIL Open Font License, incluida en la app.").font(.footnote)
                }.listRowBackground(VetaTheme.panel)
            }.vetaForm().navigationTitle("Tu VETA Retro").navigationBarTitleDisplayMode(.inline).toolbar {Button("Listo"){settings=false}}
        }.environment(\.locale,localization.locale).environment(\.layoutDirection,localization.layoutDirection).tint(VetaTheme.mint).sheet(item:$share){ShareSheet(url:$0.url)}
    }
    private func launch(_ game:Game) {
        searchFocused=false
        let readiness=DeviceReadiness.capture()
        let plan=GameLaunchPlan.capture(for:game,readiness:readiness,library:library)
        let check=readiness.preflight(game:game,library:library,plan:plan)
        #if VETA_JIT_DEVELOPMENT
        // Only defer the missing-JIT prerequisite. File/hardware/engine errors
        // still block before asking the helper to do any work.
        if JITGameContainer.canOfferActivation(game:game,check:check,plan:plan) {activeLaunch=GameLaunchRequest(game:game,plan:plan);return}
        #endif
        guard check.canLaunch else {library.error=check.blockers.map {L10n.text($0)}.joined(separator:"\n");return}
        activeLaunch=GameLaunchRequest(game:game,plan:plan)
    }
    private func perform(_ work:() throws -> Void) {do {try work()} catch {library.error=error.localizedDescription}}
    private func artURL(_ game:Game)->URL? {
        let name=DiscoverGame.catalog.first(where:{$0.title == game.name && $0.console == game.console})?.bundled ?? Library.demoNames.first(where:{$0.value == game.name})?.key ?? ""
        return Bundle.main.url(forResource:"screen",withExtension:"png",subdirectory:"Content/\(name)")
    }
    private func extraEngineLicenses()->String {
        let notices=["ThirdPartyNotices","EngineLicenses"].compactMap {name in
            Bundle.main.url(forResource:name,withExtension:"txt",subdirectory:"Content").flatMap {try? String(contentsOf:$0,encoding:.utf8)}
        }
        return notices.isEmpty ? L10n.text("No se encontraron las licencias."):notices.joined(separator:"\n\n")
    }
    private func license()->String {(try? String(contentsOf:Bundle.main.url(forResource:"FCEUmm-COPYING",withExtension:"txt",subdirectory:"Content")!)) ?? ""}
}
struct GameSurface:UIViewControllerRepresentable {
    let session:Emulation
    let skin:String
    let revision:Int
    func makeUIViewController(context:Context)->GameViewController {GameViewController(session:session)}
    func updateUIViewController(_ controller:GameViewController,context:Context) {controller.refresh()}
}
struct GameContainer:View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session:Emulation
    @AppStorage("native.skin") private var skin="VETA"
    @State private var revision=0
    init(game:Game,library:Library,plan:GameLaunchPlan? = nil) {_session=StateObject(wrappedValue:Emulation(game:game,library:library,plan:plan));_skin=AppStorage(wrappedValue:"Estudio",game.console.preferencePrefix+"skin")}
    var body:some View {
        GameSurface(session:session,skin:skin,revision:revision).tint(VetaTheme.mint).ignoresSafeArea().statusBarHidden(true).id("game")
            .overlay(alignment:.topTrailing) {if session.fastForward {Button("2× · Volver a 1×"){session.setFastForward(false)}.buttonStyle(VetaButton(primary:true)).padding(.top,60).padding(.trailing,20).accessibilityIdentifier("gameplay-normal-speed")}}
            .overlay(alignment:.bottom) {if !session.ready {Button("Volver a la biblioteca"){dismiss()}.padding(30)}}
            .gameplayThermalNotice(topInset:session.fastForward ? 112:56,pause:{session.openMenu()})
            .sheet(isPresented:$session.showMenu,onDismiss:{revision+=1;session.resume()}) {
                PauseView(session:session,leave:{session.close();session.showMenu=false;dismiss()})
                    .interactiveDismissDisabled()
            }
            .alert("VETA Retro",isPresented:Binding(get:{session.error != nil},set:{if !$0 {session.error=nil}})) {Button("Aceptar"){session.error=nil}} message:{Text(L10n.text(session.error ?? ""))}
            .onDisappear {session.close()}
            .onChange(of:skin){_ in revision+=1}
            .accessibilityIdentifier("native-player-\(revision)")
    }
}
struct PauseView:View {
    @ObservedObject var session:Emulation
    let leave:()->Void
    init(session:Emulation,leave:@escaping ()->Void) {self.session=session;self.leave=leave;_skin=AppStorage(wrappedValue:"Estudio",session.game.console.preferencePrefix+"skin")}
    @State private var confirm=""
    @State private var showConfirmation=false
    @State private var showControls=false
    @State private var showProfiles=false
    @State private var showGuides=false
    @State private var showCheats=false
    @State private var screenshot:GameplayScreenshotShare?
    @State private var showStates=false
    @State private var showControllers=false
    @State private var showTogether=false
    @State private var localError:String?
    @AppStorage("native.skin") private var skin="VETA"
    @AppStorage("native.volume") private var volume=0.8
    var body:some View {
        NavigationStack {
            Form {
                Section {
                    Button {session.showMenu=false} label:{Label("Continuar",systemImage:"play.fill").font(.headline)}.accessibilityIdentifier("resume-game")
                    Button {leave()} label:{Label("Ir a la biblioteca",systemImage:"books.vertical")}.accessibilityIdentifier("exit-game")
                    Text(session.game.name).foregroundStyle(.secondary)
                    if let notice=session.plan.notice {Text(L10n.text(notice)).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("offline-execution-notice")}
                }.listRowBackground(VetaTheme.panel)
                Section("Guardados manuales") {
                    Button("Guardar nuevo punto") {run {try session.saveNewManual()}}.accessibilityIdentifier("save-state")
                    Button("Elegir o gestionar guardados") {showStates=true}.accessibilityIdentifier("state-gallery")
                    Text("Guarda hasta ocho puntos con imagen y fecha. Puedes volver a cualquiera; sólo se reemplazan si tú lo eliges.").font(.caption).foregroundStyle(.secondary)
                    if !session.status.isEmpty {Text(L10n.text(session.status)).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("save-status")}
                }.listRowBackground(VetaTheme.panel)
                Section("Último autoguardado") {
                    Text("Se actualiza al pausar, salir o cambiar de app. Al abrir el juego se retoma este punto automáticamente.").font(.caption).foregroundStyle(.secondary)
                    Text("El autoguardado nunca reemplaza tus guardados manuales. Si el iPhone se apaga de golpe o la app falla, se conserva el último guardado completado.").font(.caption).foregroundStyle(.secondary)
                }.listRowBackground(VetaTheme.panel)
                Section("Tu partida") { Button("Guía del juego") {showGuides=true} }.listRowBackground(VetaTheme.panel)
                GameplayToolsSection(emulation:session,shareScreenshot:{screenshot=GameplayScreenshotShare(url:$0)},showCheats:{showCheats=true})
                Section("Tu mando") {
                    NavigationLink {ControllerSkinSettingsView(console:session.game.console)} label:{HStack {Text("Skin");Spacer();Text(LocalizedStringKey(skin)).foregroundStyle(.secondary)}}.accessibilityIdentifier("skin-picker")
                    Button("Personalizar controles") {showControls=true}
                    Button("Perfiles del juego") {showProfiles=true}
                    Button("Mandos y jugadores") {showControllers=true}
                    Button("Jugar juntos") {showTogether=true}
                    NavigationLink("TV y pantalla completa") {ExternalDisplaySettingsView()}
                    HStack {Image(systemName:"speaker.fill");Slider(value:$volume,in:0...1).accessibilityLabel("Volumen");Image(systemName:"speaker.wave.3.fill")}.onChange(of:volume){session.changeVolume($0)}
                }.listRowBackground(VetaTheme.panel)
                Section {
                    Button("Reiniciar juego",role:.destructive){confirm="reset";showConfirmation=true}
                }.listRowBackground(VetaTheme.panel)
                Section("Sesión nativa") {
                    Text(session.diagnostics).font(.caption.monospaced()).accessibilityIdentifier("native-metrics")
                    Button("Guardar diagnóstico") {run {_ = try session.report()}}.accessibilityIdentifier("save-diagnostics")
                }.listRowBackground(VetaTheme.panel)
            }.vetaForm().navigationTitle("En pausa").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented:$showCheats){NESCheatsView(emulation:session)}
            .sheet(item:$screenshot){GameplayShareSheet(url:$0.url)}
            .sheet(isPresented:$showControls){ControlsSettings(console:session.game.console)}
            .sheet(isPresented:$showGuides){GameGuidesView(game:session.game,library:session.library)}
            .sheet(isPresented:$showProfiles){GameProfileSettings(game:session.game,library:session.library)}
            .sheet(isPresented:$showStates){SaveStateGallery(emulation:session)}
            .sheet(isPresented:$showControllers){NavigationStack {ControllerSettingsView(console:session.game.console).toolbar {Button("Listo"){showControllers=false}}}}
            .sheet(isPresented:$showTogether){NavigationStack {PlayTogetherView(console:session.game.console).toolbar {Button("Listo"){showTogether=false}}}}
            .confirmationDialog(LocalizedStringKey(confirm == "load" ? "¿Cargar la partida guardada? Se reemplazará el momento actual." : confirm == "save" ? "¿Reemplazar el guardado rápido?" : "¿Reiniciar este juego?"),isPresented:$showConfirmation,titleVisibility:.visible) {
                // Dismissing the popover must not erase the requested action before its callback.
                let action=confirm
                Button("Confirmar",role:.destructive) {
                    showConfirmation=false
                    run {if action == "save" {try session.save()} else if action == "load" {try session.restore()} else if action == "reset" {try session.reset()}}
                }
                Button("Cancelar",role:.cancel){showConfirmation=false}
            }
            .alert("No se pudo completar",isPresented:Binding(get:{localError != nil},set:{if !$0 {localError=nil}})) {Button("Aceptar"){localError=nil}} message:{Text(L10n.text(localError ?? ""))}
        }
    }
    private func run(_ work:() throws->Void) {do {try work()} catch {localError=error.localizedDescription}}
}
struct ControlsSettings:View {
    let console:GameConsole
    @Environment(\.dismiss) private var dismiss
    @AppStorage("native.haptics") private var haptics=true
    @AppStorage("native.hapticStrength") private var strength="Suave"
    @AppStorage("native.controlSize") private var size=1.0
    @AppStorage("native.controlOpacity") private var opacity=1.0
    @AppStorage("native.controlHeight") private var height=0.0
    @AppStorage("native.controlSpacing") private var spacing=1.0
    init(console:GameConsole = .nes) {
        self.console=console
        _size=AppStorage(wrappedValue:1.0,console.preferencePrefix+"controlSize")
        _opacity=AppStorage(wrappedValue:1.0,console.preferencePrefix+"controlOpacity")
        _height=AppStorage(wrappedValue:0.0,console.preferencePrefix+"controlHeight")
        _spacing=AppStorage(wrappedValue:1.0,console.preferencePrefix+"controlSpacing")
    }
    private let feedback=Haptics()
    var body:some View {
        NavigationStack {
            Form {
                Section("Respuesta al tacto") {
                    Toggle("Vibración",isOn:$haptics)
                    Picker("Intensidad",selection:$strength){ForEach(["Suave","Media","Firme"],id:\.self){Text(LocalizedStringKey($0)).tag($0)}}
                    Button("Probar vibración"){feedback.pulse(force:true)}
                }.listRowBackground(VetaTheme.panel)
                Section {NavigationLink("Diseñar controles"){ControllerSkinSettingsView(console:console)}}.listRowBackground(VetaTheme.panel)
                Section("Distribución") {
                    Text(L10n.format("Tamaño %lld %%",Int(size*100)));Slider(value:$size,in:0.85...1.2)
                    Text(L10n.format("Separación %lld %%",Int(spacing*100)));Slider(value:$spacing,in:0.8...1.2)
                    Text("Altura");Slider(value:$height,in:-0.12...0.12)
                    Text(L10n.format("Opacidad %lld %%",Int(opacity*100)));Slider(value:$opacity,in:0.4...1)
                    Button("Original"){size=1;spacing=1;height=0;opacity=1}
                    Button("Cómodo"){size=1.15;spacing=1.1;height=0.03;opacity=1}
                    Button("Discreto"){size=1;spacing=1;height=0;opacity=0.6}
                }.listRowBackground(VetaTheme.panel)
                Section("Cómo jugar") {
                    Text("Desliza por la cruceta para hacer diagonales. Puedes mantener dirección y A/B a la vez. A+B pulsa ambos botones. Select solo se activa al soltar sin arrastrar.")
                    Text("Los mandos Bluetooth de iOS se detectan automáticamente. A y B son acción; Options es Select y Menu es Start. La cantidad de jugadores depende de la consola y del juego; configura los puertos en Mandos y jugadores.")
                }.listRowBackground(VetaTheme.panel)
            }.vetaForm().navigationTitle("Tu mando").toolbar{Button("Listo"){dismiss()}}
        }
    }
}


// The previews use the same native drawing and layout as the playable controls.
private struct SkinPreview:UIViewRepresentable {
    let skin:String
    let console:GameConsole
    func makeUIView(context:Context)->SkinPreviewView {SkinPreviewView()}
    func updateUIView(_ view:SkinPreviewView,context:Context) {view.apply(skin,console:console)}
}
private final class SkinPreviewView:UIView {
    private let deck=TouchDeck()
    private let catalog=CatalogPad()
    override init(frame:CGRect) {super.init(frame:frame);isUserInteractionEnabled=false;clipsToBounds=true;layer.cornerRadius=12;addSubview(deck);addSubview(catalog)}
    required init?(coder:NSCoder) {fatalError()}
    func apply(_ skin:String,console:GameConsole) {
        var style=ControlStyle(console:console,defaults:nil);style.skin=skin;style.size=1;style.height=0;style.spacing=1;style.opacity=1
        deck.customLayout=skin == "Estudio" ? StudioSkins.variant(console:console,orientation:.portrait)?.layout:nil
        deck.customArtwork=skin == "Estudio" ? StudioSkins.image(console:console,orientation:.portrait):nil
        deck.style=style;catalog.style=style;let hasControls=console.playable || console.isStandaloneEngine;deck.isHidden = !hasControls;catalog.isHidden=hasControls;backgroundColor=style.background
    }
    override func layoutSubviews() {
        super.layoutSubviews();catalog.frame=bounds;let canvas=deck.customLayout?.canvas ?? CGSize(width:400,height:276);deck.bounds=CGRect(origin:.zero,size:canvas)
        deck.center=CGPoint(x:bounds.midX,y:bounds.midY)
        let scale=min(bounds.width/canvas.width,bounds.height/canvas.height)
        deck.transform=CGAffineTransform(scaleX:scale,y:scale)
    }
}
private struct SkinGallery:View {
    @Binding var skin:String
    let console:GameConsole
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                Text("Elige tu mando").font(VetaTheme.heading(32))
                Text("Una carcasa distinta para cada forma de jugar.").foregroundStyle(VetaTheme.muted)
                LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:16) {
                    ForEach(ControllerSkinPalette.allCases.map(\.rawValue),id:\.self) {name in
                        Button {skin=name;dismiss()} label:{
                            VStack(alignment:.leading,spacing:10) {
                                SkinPreview(skin:name,console:console).aspectRatio(400/276,contentMode:.fit).accessibilityHidden(true)
                                HStack {Text(LocalizedStringKey(name)).font(.subheadline.bold());Spacer();if skin == name {Image(systemName:"checkmark.circle.fill").foregroundStyle(VetaTheme.mint)}}
                                Text(name == "Estudio" ? L10n.format("Carcasa de %@",console.shortName):name == "Clásica" ? L10n.format("Carcasa de %@",console.shortName):L10n.text(name == "VETA" ? "Petróleo y menta":name == "Noche" ? "Oscura y contorneada":"Ligera y translúcida")).font(.caption).foregroundStyle(VetaTheme.muted)
                            }.padding(10).background(VetaTheme.panel,in:RoundedRectangle(cornerRadius:16))
                                .overlay(RoundedRectangle(cornerRadius:16).stroke(skin == name ? VetaTheme.mint:VetaTheme.border,lineWidth:skin == name ? 2:1))
                        }.buttonStyle(.plain) .accessibilityLabel(Text(LocalizedStringKey(name))).accessibilityIdentifier("skin-option-"+name)
                    }
                }
            }.padding(20)
        }.background(VetaTheme.background).foregroundStyle(VetaTheme.ink).navigationTitle(L10n.format("Skins %@",console.shortName)).navigationBarTitleDisplayMode(.inline)
    }
}

private struct ConsoleSkinPicker:View {
    let console:GameConsole
    @AppStorage private var skin:String
    init(console:GameConsole) {self.console=console;_skin=AppStorage(wrappedValue:"Estudio",console.preferencePrefix+"skin")}
    var body:some View {NavigationStack {ControllerSkinSettingsView(console:console)}}
}
