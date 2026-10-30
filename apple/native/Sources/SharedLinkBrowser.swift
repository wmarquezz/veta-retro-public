import SwiftUI
import WebKit

/// Isolated website session. Passwords are entered on the provider's page;
/// no injected scripts, credential interception, persisted cookies or history.
@MainActor final class SharedLinkBrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let link: SharedCloudLink
    let web: WKWebView
    @Published var host: String
    @Published var error: String?
    @Published var ready: [URL] = []
    @Published var active = 0
    @Published var bytes: Int64 = 0
    @Published var importing = false
    @Published var message: String?
    private var root: URL?
    private var jobs: [ObjectIdentifier: (WKDownload, URL?)] = [:]
    private var observers: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var operation: Task<Void, Never>?
    private var closed = false
    private var known: Set<String> = []
    private let extensions = LocalCoverImport.gameExtensions.union(NativeGameFile.extensions).union(LocalCoverImport.imageExtensions)
    init(link: SharedCloudLink) {
        self.link = link; host = link.url.host ?? link.provider.title
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        web = WKWebView(frame:.zero,configuration:configuration)
        super.init(); web.navigationDelegate = self; web.uiDelegate = self
    }
    func open() { web.load(URLRequest(url:link.url)) }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard !closed, let url = action.request.url else { decisionHandler(.cancel); return }
        let blob = url.scheme == "blob" && webView.url.map(link.allows) == true
        guard link.allows(url) || blob || (url.absoluteString == "about:blank" && action.targetFrame?.isMainFrame == false) else {
            if action.targetFrame?.isMainFrame != false { error = SharedLinkError.navigation.localizedDescription }
            decisionHandler(.cancel); return
        }
        if action.shouldPerformDownload { decisionHandler(.download) }
        else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard !closed else { decisionHandler(.cancel); return }
        let mime = response.response.mimeType?.lowercased() ?? ""
        let html = mime == "text/html" || mime == "application/xhtml+xml"
        let name = response.response.suggestedFilename ?? ""
        let supported = extensions.contains((name as NSString).pathExtension.lowercased())
        if response.isForMainFrame && !html && (supported || !response.canShowMIMEType) { decisionHandler(.download) }
        else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, link.allows(url) { webView.load(action.request) }
        else { error = SharedLinkError.navigation.localizedDescription }
        return nil
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { host = webView.url?.host ?? link.url.host ?? link.provider.title }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError failure: Error) {
        if (failure as NSError).code != NSURLErrorCancelled { error = SharedLinkError.failed.localizedDescription }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError failure: Error) { self.webView(webView,didFailProvisionalNavigation:navigation,withError:failure) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { error = SharedLinkError.failed.localizedDescription }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { attach(download) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { attach(download) }
    private func attach(_ download: WKDownload) {
        guard !closed, !importing, jobs.count < 2, ready.count < 1000 else { download.cancel { _ in }; error = DirectCloudError.limit.localizedDescription; return }
        let id = ObjectIdentifier(download)
        jobs[id] = (download,nil); active = jobs.count; download.delegate = self
        observers[id] = download.progress.observe(\.completedUnitCount,options:[.new]) { [weak self] _, _ in
            Task { @MainActor in self?.checkProgress() }
        }
    }
    private func checkProgress() {
        bytes = jobs.values.reduce(0) { $0 + max(0,$1.0.progress.completedUnitCount) }
        let completed = ready.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0) }
        if jobs.values.contains(where: { $0.0.progress.completedUnitCount > 16 * 1024 * 1024 * 1024 }) || bytes + completed > 32 * 1024 * 1024 * 1024 {
            error = SharedLinkError.tooLarge.localizedDescription; cancelDownloads()
        }
    }
    static func downloadName(_ suggested: String, allowed: Set<String>) throws -> String {
        let name = try DirectCloudAPI.safeName(suggested)
        guard allowed.contains((name as NSString).pathExtension.lowercased()) else { throw SharedLinkError.unsupportedFile }
        return name
    }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let id = ObjectIdentifier(download)
        do {
            guard !closed, jobs[id] != nil else { completionHandler(nil); return }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { throw SharedLinkError.failed }
            let mime = response.mimeType?.lowercased() ?? ""
            guard mime != "text/html", mime != "application/xhtml+xml" else { throw SharedLinkError.unsupportedFile }
            let name = try Self.downloadName(suggestedFilename,allowed:extensions)
            guard !known.contains(name.lowercased()) else { throw DirectCloudError.ambiguousNames }
            let expected = response.expectedContentLength
            guard expected <= 16 * 1024 * 1024 * 1024 else { throw SharedLinkError.tooLarge }
            if root == nil {
                root = FileManager.default.temporaryDirectory.appendingPathComponent("VetaSharedLink-" + UUID().uuidString,isDirectory:true)
                try FileManager.default.createDirectory(at:root!,withIntermediateDirectories:true)
            }
            if let free = try root!.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
               free < max(expected,0) + 128 * 1024 * 1024 { throw SharedLinkError.tooLarge }
            let target = root!.appendingPathComponent(name)
            known.insert(name.lowercased()); jobs[id] = (download,target); completionHandler(target)
        } catch {
            self.error = error.localizedDescription; jobs.removeValue(forKey:id); observers.removeValue(forKey:id); active = jobs.count; completionHandler(nil)
        }
    }
    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void) {
        guard let url = request.url, link.allows(url) else { error = SharedLinkError.navigation.localizedDescription; decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func downloadDidFinish(_ download: WKDownload) {
        let id = ObjectIdentifier(download)
        if let url = jobs.removeValue(forKey:id)?.1 {
            if !closed { ready.append(url) } else { try? FileManager.default.removeItem(at:url) }
        }
        observers.removeValue(forKey:id); active = jobs.count; checkProgress()
    }
    func download(_ download: WKDownload, didFailWithError failure: Error, resumeData: Data?) {
        let id = ObjectIdentifier(download)
        if let url = jobs.removeValue(forKey:id)?.1 { known.remove(url.lastPathComponent.lowercased()); try? FileManager.default.removeItem(at:url) }
        observers.removeValue(forKey:id); active = jobs.count
        if !closed && (failure as NSError).code != NSURLErrorCancelled { error = SharedLinkError.failed.localizedDescription }
    }
    func cancelDownloads() {
        let old = jobs; jobs = [:]; observers = [:]; active = 0; bytes = 0
        for (_, (job, path)) in old {
            if let path { known.remove(path.lastPathComponent.lowercased()) }
            job.cancel { _ in if let path { try? FileManager.default.removeItem(at:path) } }
        }
    }
    func importReady(_ commit: @escaping (CloudImportPreparation.Snapshot) throws -> String) {
        guard active == 0, !ready.isEmpty, !importing else { return }
        importing = true; error = nil; message = nil
        let files = ready, job = CloudImportPreparation(extensions:extensions)
        operation = Task {
            defer { importing = false; operation = nil }
            do {
                let snapshot = try await Task.detached { try job.prepare(files,combineExplicitFiles:true) { _,_,_ in } }.value
                defer { snapshot.remove() }
                try Task.checkCancellation()
                message = try commit(snapshot)
                for file in files { try? FileManager.default.removeItem(at:file) }
                ready = []; known = []
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    func close() {
        guard !closed else { return }; closed = true; web.stopLoading(); web.navigationDelegate = nil; web.uiDelegate = nil
        operation?.cancel(); cancelDownloads()
        if let root { try? FileManager.default.removeItem(at:root) }; root = nil; ready = []
    }
}

struct SharedLinkWebView: UIViewRepresentable {
    let model: SharedLinkBrowserModel
    func makeUIView(context: Context) -> WKWebView { model.web }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
struct SharedLinkBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: SharedLinkBrowserModel
    @State private var confirmClose = false
    let commit: (CloudImportPreparation.Snapshot) throws -> String
    init(link:SharedCloudLink,commit:@escaping (CloudImportPreparation.Snapshot)throws->String) {
        _model=StateObject(wrappedValue:SharedLinkBrowserModel(link:link));self.commit=commit
    }
    var body: some View {
        NavigationStack {
            SharedLinkWebView(model:model)
                .safeAreaInset(edge:.top) {
                    VStack(alignment:.leading,spacing:6) {
                        Label(model.host,systemImage:"lock").font(.footnote).textSelection(.enabled)
                        Text("Si el enlace pide contraseña, escríbela en la página del proveedor. Selecciona allí los juegos y toca Descargar; después, Importar descargas.").font(.footnote)
                        if let error=model.error { Text(error).foregroundStyle(.orange).font(.footnote) }
                        if let message=model.message { Text(message).font(.footnote) }
                    }.frame(maxWidth:.infinity,alignment:.leading).padding(12).background(VetaTheme.panel)
                }
                .safeAreaInset(edge:.bottom) {
                    VStack(spacing:8) {
                        if model.active > 0 {
                            HStack { ProgressView(); Text(ByteCountFormatter.string(fromByteCount:model.bytes,countStyle:.file)); Spacer(); Button("Cancelar") {model.cancelDownloads()} }
                        }
                        if !model.ready.isEmpty {
                            DisclosureGroup(L10n.format("%d archivos",model.ready.count)) {
                                ScrollView { VStack(alignment:.leading) {ForEach(model.ready,id:\.self) {Text($0.lastPathComponent).font(.footnote)}} }.frame(maxHeight:100)
                            }
                        }
                        if model.importing { ProgressView("Agregando a tu biblioteca…") }
                        Button("Importar descargas") {model.importReady(commit)}.buttonStyle(VetaButton(primary:true)).disabled(model.ready.isEmpty || model.active > 0 || model.importing)
                    }.padding(12).background(VetaTheme.panel)
                }
                .navigationTitle("Enlace compartido").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) { Button("Cerrar") {if model.active > 0 || !model.ready.isEmpty {confirmClose=true} else {dismiss()}}.disabled(model.importing) }
                    ToolbarItem(placement:.primaryAction) {
                        Menu {
                            Button("Volver") {model.web.goBack()}.disabled(!model.web.canGoBack)
                            Button("Volver a cargar") {model.web.reload()}
                            Link("Abrir en Safari",destination:model.link.url)
                        } label:{Image(systemName:"ellipsis.circle").frame(minWidth:44,minHeight:44)}.accessibilityLabel("Opciones")
                    }
                }
                .alert("¿Cerrar sin importar?",isPresented:$confirmClose) {
                    Button("Cerrar",role:.destructive) {model.close();dismiss()};Button("Cancelar",role:.cancel) {}
                } message:{Text("Se descartarán las descargas temporales. Los archivos compartidos y tus juegos de VETA se conservan.")}
        }.tint(VetaTheme.mint).interactiveDismissDisabled(model.active > 0 || !model.ready.isEmpty || model.importing)
            .onAppear {model.open()}.onDisappear {model.close()}
    }
}

struct SharedCloudLinkView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var error: String?
    @State private var opened: SharedCloudLink?
    let commit: (CloudImportPreparation.Snapshot) throws -> String
    var body: some View {
        NavigationStack {
            Form {
                Section("Enlace compartido") {
                    TextField("https://…",text:$address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive().accessibilityIdentifier("shared-link-url")
                    Text("Google Drive, OneDrive o Dropbox. Usa el enlace que te compartió el propietario.").font(.footnote)
                    Button("Abrir enlace") {do {opened=try SharedCloudLink.parse(address);error=nil} catch {self.error=error.localizedDescription}}.frame(minHeight:44).disabled(address.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty).accessibilityIdentifier("shared-link-open")
                    if let error { Text(error).foregroundStyle(.orange) }
                }
                Section("Acceso a la carpeta") {
                    Text("Drive usa la cuenta conectada a VETA. Si recibiste una invitación, esa cuenta debe tener permiso.")
                    Text("Si el enlace pide contraseña, escríbela en la página del proveedor. Selecciona allí los juegos y toca Descargar; después, Importar descargas.")
                    Text("Algunos servicios pueden pedir abrir Safari para iniciar sesión. La disponibilidad depende de los permisos del enlace.")
                }
            }.navigationTitle("Abrir enlace compartido").navigationBarTitleDisplayMode(.inline)
                .toolbar {ToolbarItem(placement:.cancellationAction) {Button("Cerrar") {dismiss()}}}
                .sheet(item:$opened) { link in
                    if link.provider == .google { DirectCloudView(sharedLink:link,commit:commit) }
                    else { SharedLinkBrowserView(link:link,commit:commit) }
                }
        }.tint(VetaTheme.mint)
    }
}
