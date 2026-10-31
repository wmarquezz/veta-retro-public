import Foundation
import CryptoKit

struct DirectCloudPlannedFile {
    let entry: DirectCloudEntry
    let components: [String]
}
struct DirectCloudPlan {
    let files: [DirectCloudPlannedFile]
    let bytes: Int64
    var issues:[ImportIssue]=[]
}
struct DirectCloudProgress {
    let name: String
    let completed: Int
    let total: Int
    let bytes: Int64
    let totalBytes: Int64
}

struct DirectCloudTransfer {
    let source: DirectCloudSource
    let extensions: Set<String>
    var continueOnError=false
    func plan(selection: [DirectCloudEntry]) async throws -> DirectCloudPlan {
        var result: [DirectCloudPlannedFile] = [], visited = Set<String>(), paths = Set<String>(), total: Int64 = 0, examined = 0
        var issues:[ImportIssue]=[]
        func visit(_ entries: [DirectCloudEntry], parent: [String], depth: Int) async throws {
            guard depth <= 20 else { throw DirectCloudError.limit }
            var siblings = Set<String>()
            for entry in entries {
                try Task.checkCancellation()
                examined += 1; guard examined <= 10_000 else { throw DirectCloudError.limit }
                do {
                guard !entry.name.hasPrefix(".") else { continue }
                let name = try DirectCloudAPI.safeName(entry.name)
                guard siblings.insert(name.lowercased()).inserted else { throw DirectCloudError.ambiguousNames }
                guard visited.insert(entry.id).inserted else { throw DirectCloudError.invalidResponse }
                let components = parent + [name]
                if entry.folder {
                    let children = try await source.list(folder: entry.id)
                    try await visit(children, parent: components, depth: depth + 1)
                } else if extensions.contains((name as NSString).pathExtension.lowercased()) {
                    guard entry.canDownload else { throw DirectCloudError.permission }
                    guard let size = entry.size, size >= 0, size <= 16 * 1024 * 1024 * 1024 else { throw DirectCloudError.limit }
                    guard total <= 32 * 1024 * 1024 * 1024 - size else { throw DirectCloudError.limit }
                    total += size
                    guard paths.insert(components.joined(separator: "/").lowercased()).inserted else { throw DirectCloudError.ambiguousNames }
                    result.append(.init(entry: entry, components: components))
                }
                } catch is CancellationError {throw CancellationError()}
                catch {
                    if case DirectCloudError.limit = error {throw error}
                    guard continueOnError else {throw error}
                    issues.append(ImportIssue(file:entry.name,error:error))
                }
            }
        }
        try await visit(selection, parent: [], depth: 0)
        guard !result.isEmpty || (continueOnError && !issues.isEmpty) else {throw DirectCloudError.noGames}
        return .init(files:result,bytes:total,issues:issues)
    }
    static func validateFile(_ url: URL, entry: DirectCloudEntry) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              Int64(values.fileSize ?? -1) == entry.size else { throw DirectCloudError.changed }
        if entry.md5 == nil && entry.dropboxHash == nil && entry.sha256 == nil { return }
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        var md5 = Insecure.MD5(), dropbox = SHA256(), sha = SHA256()
        // Dropbox content_hash is SHA256 of concatenated 4 MiB block SHA256 digests.
        while true {
            try Task.checkCancellation()
            var block = Data()
            while block.count < 4 * 1024 * 1024 {
                let chunk = try input.read(upToCount: 4 * 1024 * 1024 - block.count) ?? Data()
                if chunk.isEmpty { break }
                block.append(chunk)
            }
            if block.isEmpty { break }
            md5.update(data: block)
            sha.update(data: block)
            dropbox.update(data: Data(SHA256.hash(data: block)))
        }
        func hex(_ data: some Sequence<UInt8>) -> String { data.map { String(format: "%02x", $0) }.joined() }
        if let expected = entry.md5, hex(md5.finalize()) != expected.lowercased() { throw DirectCloudError.changed }
        if let expected = entry.dropboxHash, hex(dropbox.finalize()) != expected.lowercased() { throw DirectCloudError.changed }
        if let expected = entry.sha256, hex(sha.finalize()) != expected.lowercased() { throw DirectCloudError.changed }
    }
    func prepare(_ plan: DirectCloudPlan, temporaryRoot: URL = FileManager.default.temporaryDirectory,
                 progress: @escaping @Sendable (DirectCloudProgress) -> Void) async throws -> CloudImportPreparation.Snapshot {
        let fm = FileManager.default
        let root = temporaryRoot.appendingPathComponent("VetaDirectImport-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var keep = false
        defer { if !keep { try? fm.removeItem(at: root) } }
        let required = plan.bytes * 2 + 128 * 1024 * 1024
        if let free = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           free < required { throw DirectCloudError.noSpace }
        var paths:[URL]=[],done:Int64=0,issues=plan.issues,hints:[URL:GameConsole]=[:]
        for (index, file) in plan.files.enumerated() {
            try Task.checkCancellation()
            let already = done
            do {
            let downloaded = try await source.download(file.entry) { bytes, _ in
                progress(.init(name: file.entry.name, completed: index, total: plan.files.count,
                               bytes: already + min(bytes, file.entry.size ?? bytes), totalBytes: plan.bytes))
            }
            defer { try? fm.removeItem(at: downloaded) }
            try Task.checkCancellation()
            try Self.validateFile(downloaded, entry: file.entry)
            var target = root
            for component in file.components { target.appendPathComponent(try DirectCloudAPI.safeName(component)) }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard !fm.fileExists(atPath: target.path) else { throw DirectCloudError.ambiguousNames }
            try fm.moveItem(at: downloaded, to: target)
            paths.append(target)
            if let code = file.entry.catalogConsole, let console = GameConsole(rawValue: code) { hints[target] = console }
            } catch is CancellationError {throw CancellationError()}
            catch {
                guard continueOnError else {throw error}
                issues.append(ImportIssue(file:file.entry.name,error:error))
            }
            done += file.entry.size ?? 0
            progress(.init(name: file.entry.name, completed: index + 1, total: plan.files.count, bytes: done, totalBytes: plan.bytes))
        }
        let expanded=try ZIPGameImport.expand(paths,temporaryRoot:root,continueOnError:continueOnError)
        issues += expanded.issues
        let ready=try expanded.importFiles(onError:continueOnError ? {url,error in issues.append(ImportIssue(file:url.lastPathComponent,error:error,coverOnly:true))}:nil)
        var finalHints:[URL:GameConsole]=[:]
        for url in ready { if let console = hints[expanded.origins[url] ?? url] { finalHints[url] = console } }
        try Task.checkCancellation(); keep = true
        return .init(root:root,files:ready,issues:issues,sourceNames:expanded.sourceNames,consoleHints:finalHints)
    }
}
