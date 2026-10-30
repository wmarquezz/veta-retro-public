import Foundation
import CryptoKit

struct DirectCloudPlannedFile {
    let entry: DirectCloudEntry
    let components: [String]
}
struct DirectCloudPlan {
    let files: [DirectCloudPlannedFile]
    let bytes: Int64
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
    func plan(selection: [DirectCloudEntry]) async throws -> DirectCloudPlan {
        var result: [DirectCloudPlannedFile] = [], visited = Set<String>(), paths = Set<String>(), total: Int64 = 0, examined = 0
        func visit(_ entries: [DirectCloudEntry], parent: [String], depth: Int) async throws {
            guard depth <= 20 else { throw DirectCloudError.limit }
            var siblings = Set<String>()
            for entry in entries {
                try Task.checkCancellation()
                examined += 1; guard examined <= 10_000 else { throw DirectCloudError.limit }
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
            }
        }
        try await visit(selection, parent: [], depth: 0)
        guard !result.isEmpty else { throw DirectCloudError.noGames }
        return .init(files: result, bytes: total)
    }
    static func validateFile(_ url: URL, entry: DirectCloudEntry) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              Int64(values.fileSize ?? -1) == entry.size else { throw DirectCloudError.changed }
        if entry.md5 == nil && entry.dropboxHash == nil { return }
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        var md5 = Insecure.MD5(), dropbox = SHA256()
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
            dropbox.update(data: Data(SHA256.hash(data: block)))
        }
        func hex(_ data: some Sequence<UInt8>) -> String { data.map { String(format: "%02x", $0) }.joined() }
        if let expected = entry.md5, hex(md5.finalize()) != expected.lowercased() { throw DirectCloudError.changed }
        if let expected = entry.dropboxHash, hex(dropbox.finalize()) != expected.lowercased() { throw DirectCloudError.changed }
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
        var paths: [URL] = [], done: Int64 = 0
        for (index, file) in plan.files.enumerated() {
            try Task.checkCancellation()
            let already = done
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
            paths.append(target); done += file.entry.size ?? 0
            progress(.init(name: file.entry.name, completed: index + 1, total: plan.files.count, bytes: done, totalBytes: plan.bytes))
        }
        let expanded=try ZIPGameImport.expand(paths,temporaryRoot:root)
        let ready=try expanded.importFiles()
        try Task.checkCancellation(); keep = true
        return .init(root: root, files: ready)
    }
}
