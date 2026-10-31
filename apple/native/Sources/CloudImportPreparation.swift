import Foundation

/// Downloads user-selected File Provider documents into an isolated, disposable snapshot.
/// The library only sees this local snapshot; cloud originals are never modified.
final class CloudImportPreparation: @unchecked Sendable {
    struct Snapshot {
        let root: URL
        let files: [URL]
        var issues:[ImportIssue]=[]
        var sourceNames:[URL:String]=[:]
        var consoleHints:[URL:GameConsole]=[:]
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
    enum Failure: LocalizedError {
        case empty, tooMany, tooDeep, link, changed, noSpace, unavailable(String)
        var errorDescription: String? {
            switch self {
            case .empty: return "No se encontraron juegos compatibles en la selección."
            case .tooMany: return "Selecciona una carpeta con un máximo de 10.000 archivos."
            case .tooDeep: return "La carpeta tiene demasiados niveles. Selecciona una subcarpeta de consola."
            case .link: return "Selecciona archivos o carpetas originales, no enlaces."
            case .changed: return "Un archivo cambió durante la descarga. Vuelve a importarlo."
            case .noSpace: return "No hay espacio suficiente en el iPhone para preparar esta importación."
            case .unavailable(let name): return "No se pudo descargar «\(name)». Revisa Internet y tu sesión en la app de almacenamiento; vuelve a intentarlo."
            }
        }
    }
    private let lock = NSLock()
    private var cancelled = false
    private var coordinator: NSFileCoordinator?
    private let fm = FileManager.default
    private let extensions: Set<String>
    init(extensions: Set<String>) { self.extensions = extensions }
    func cancel() {
        lock.lock(); cancelled = true; let current = coordinator; lock.unlock()
        current?.cancel()
    }
    private func check() throws {
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped { throw CancellationError() }
    }
    private func read<T>(_ url: URL, metadata: Bool = false, _ body: (URL) throws -> T) throws -> T {
        try check()
        let c = NSFileCoordinator(filePresenter: nil)
        lock.lock(); coordinator = c; let stopped = cancelled; lock.unlock()
        defer { lock.lock(); coordinator = nil; lock.unlock() }
        if stopped { throw CancellationError() }
        var error: NSError?
        var result: Result<T, Error>?
        c.coordinate(readingItemAt: url, options: metadata ? .immediatelyAvailableMetadataOnly : [], error: &error) { available in
            result = Result { try check(); return try body(available) }
        }
        try check()
        if let error { throw error }
        guard let result else { throw Failure.unavailable(url.lastPathComponent) }
        return try result.get()
    }
    /// Runs off the main thread. Directory coordination enumerates metadata, then each
    /// supported file gets its own coordinated read to materialize remote placeholders.
    func prepare(_ selections: [URL], temporaryRoot: URL = FileManager.default.temporaryDirectory,
                 combineExplicitFiles: Bool = false,continueOnError:Bool = false,
                 progress: @escaping (String, Int, Int) -> Void) throws -> Snapshot {
        let scoped = selections.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        let root = temporaryRoot.appendingPathComponent("VetaImport-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var keep = false
        defer { if !keep { try? fm.removeItem(at: root) } }
        var sources: [URL] = [], seen = Set<URL>(), visited = Set<URL>()
        var examined = 0
        var selectedDirectory = false
        var issues:[ImportIssue]=[]
        func handle(_ url:URL,_ error:Error)throws {
            if error is CancellationError {throw error}
            if case Failure.tooMany = error {throw error}
            guard continueOnError else {throw error}
            issues.append(ImportIssue(file:url.lastPathComponent,error:error))
        }
        func collect(_ url: URL, depth: Int) throws {
            try check()
            guard depth <= 20 else { throw Failure.tooDeep }
            let identity = url.standardizedFileURL
            guard visited.insert(identity).inserted else { return }
            examined += 1
            guard examined <= 10_000 else { throw Failure.tooMany }
            let values = try read(url, metadata: true) { try $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) }
            guard values.isSymbolicLink != true else { throw Failure.link }
            if values.isDirectory == true {
                selectedDirectory = true
                progress(url.lastPathComponent, 0, 0)
                let children = try read(url, metadata: true) {
                    try fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                }
                for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    do {try collect(child, depth: depth + 1)} catch {try handle(child,error)}
                }
            } else if extensions.contains(url.pathExtension.lowercased()), seen.insert(identity).inserted {
                sources.append(url)
            }
        }
        do {
            for selection in selections {do {try collect(selection, depth:0)} catch {try handle(selection,error)}}
            guard !sources.isEmpty || (continueOnError && !issues.isEmpty) else {throw Failure.empty}
            // Some providers give each selected file a separate security-scoped parent.
            // Treat a file-only cloud selection as one batch when names are unique.
            // Directory selections and ambiguous duplicate names keep their boundaries.
            let names = sources.map { $0.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased() }
            let combine = combineExplicitFiles && !selectedDirectory && Set(names).count == names.count
            var parents: [URL: URL] = [:], files: [URL] = []
            for (index, source) in sources.enumerated() {
                try check(); progress(source.lastPathComponent, index, sources.count)
                let parent = combine ? root : source.deletingLastPathComponent().standardizedFileURL
                let folder: URL
                if let existing = parents[parent] { folder = existing }
                else {
                    folder = root.appendingPathComponent(String(parents.count), isDirectory: true)
                    try fm.createDirectory(at: folder, withIntermediateDirectories: true); parents[parent] = folder
                }
                let target = folder.appendingPathComponent(source.lastPathComponent)
                do {
                try autoreleasepool { try read(source) { available in
                    let before = try available.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                    guard before.isRegularFile == true, before.isSymbolicLink != true else { throw Failure.link }
                    let size = Int64(before.fileSize ?? 0)
                    if let capacity = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
                       size > max(0, (capacity - 32 * 1024 * 1024) / 2) { throw Failure.noSpace }
                    let input = try FileHandle(forReadingFrom: available)
                    defer { try? input.close() }
                    guard fm.createFile(atPath: target.path, contents: nil) else { throw Failure.noSpace }
                    let output = try FileHandle(forWritingTo: target)
                    defer { try? output.close() }
                    var bytes: Int64 = 0
                    while true {
                        try check()
                        let chunk = try input.read(upToCount: 1024 * 1024) ?? Data()
                        if chunk.isEmpty { break }
                        try output.write(contentsOf: chunk); bytes += Int64(chunk.count)
                    }
                    let after = try available.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    guard bytes == size, before.fileSize == after.fileSize,
                          before.contentModificationDate == after.contentModificationDate else { throw Failure.changed }
                } }
                files.append(target)
                } catch {try? fm.removeItem(at:target);try handle(source,error)}
                progress(source.lastPathComponent,index+1,sources.count)
            }
            let expanded=try ZIPGameImport.expand(files,temporaryRoot:root,continueOnError:continueOnError,checkCancellation:check)
            issues += expanded.issues
            let ready=try expanded.importFiles(onError:continueOnError ? {url,error in issues.append(ImportIssue(file:url.lastPathComponent,error:error,coverOnly:true))}:nil)
            try check(); keep = true
            return Snapshot(root:root,files:ready,issues:issues,sourceNames:expanded.sourceNames)
        } catch is CancellationError { throw CancellationError() }
        catch let error as Failure { throw error }
        catch let error as VetaError { throw error }
        catch let error as ZIPGameImport.ArchiveError { throw error }
        catch { throw Failure.unavailable(sources.last?.lastPathComponent ?? selections.first?.lastPathComponent ?? "") }
    }
}
