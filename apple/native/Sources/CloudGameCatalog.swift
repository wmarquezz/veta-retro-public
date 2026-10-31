import Foundation
import SwiftUI

/// User-owned, relative-path catalog. It never contains credentials or arbitrary download URLs.
struct CloudGameCatalog: Codable {
    static let filename = "veta-catalog.json"
    let format: String
    let version: Int
    let title: String
    let generatedAt: String
    let consoles: [Console]
    struct File: Codable {
        let path: String
        let bytes: Int64
        let sha256: String
        var components: [String] { path.components(separatedBy: "/") }
    }
    struct GameItem: Codable {
        let id: String // SHA-256 of the imported ROM, not of its ZIP container.
        let title: String
        let file: File
        let cover: File?
        let validation: String
    }
    struct Console: Codable {
        let id: String
        let name: String
        let folder: String
        let games: [GameItem]
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 16 * 1024 * 1024 else { throw DirectCloudError.limit }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.format == "veta.catalog", value.version == 1,
              !value.title.isEmpty, value.title.count <= 200, value.consoles.count <= 40 else { throw DirectCloudError.invalidResponse }
        var consoles = Set<String>(), games = Set<String>(), paths = Set<String>(), count = 0
        func digest(_ s: String) -> Bool { s.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }
        func check(_ file: File, folder: String, image: Bool) throws {
            let parts = file.components
            guard parts.count == 2, parts[0] == folder,
                  file.bytes > 0, file.bytes <= (image ? 30 * 1024 * 1024 : 16 * 1024 * 1024 * 1024),
                  digest(file.sha256), paths.insert(file.path.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw DirectCloudError.invalidResponse }
            for part in parts { _ = try DirectCloudAPI.safeName(part) }
            let ext = (parts[1] as NSString).pathExtension.lowercased()
            let allowed = image ? Set(LocalCoverImport.imageExtensions) : LocalCoverImport.gameExtensions.union(NativeGameFile.extensions).subtracting(["cue", "m3u", "vetanes", "vetaretro"])
            guard allowed.contains(ext) else { throw DirectCloudError.invalidResponse }
        }
        for console in value.consoles {
            guard GameConsole.allCases.contains(where: { $0.rawValue == console.id }), consoles.insert(console.id).inserted,
                  !console.name.isEmpty, console.name.count <= 100 else { throw DirectCloudError.invalidResponse }
            _ = try DirectCloudAPI.safeName(console.folder)
            for game in console.games {
                count += 1
                guard count <= 20_000, digest(game.id), games.insert(game.id).inserted,
                      !game.title.isEmpty, game.title.count <= 300,
                      ["import", "boot", "user"].contains(game.validation) else { throw DirectCloudError.invalidResponse }
                try check(game.file, folder: console.folder, image: false)
                if let cover = game.cover { try check(cover, folder: console.folder, image: true) }
            }
        }
        return value
    }
}

/// Resolves only children of the folder whose catalog was opened. Each folder is listed once.
actor CatalogCloudSource: DirectCloudSource {
    nonisolated let catalog: CloudGameCatalog
    nonisolated let rootID: String
    nonisolated let folders: [DirectCloudEntry]
    nonisolated let allFiles: [DirectCloudEntry]
    nonisolated let consoleFiles: [String: [DirectCloudEntry]]
    private let source: any DirectCloudSource
    private let files: [String: CloudGameCatalog.File]
    private var listingTasks: [String: Task<[DirectCloudEntry], Error>] = [:]
    init(catalog: CloudGameCatalog, rootID: String, source: any DirectCloudSource) {
        self.catalog = catalog; self.rootID = rootID; self.source = source
        var folders: [DirectCloudEntry] = [], all: [DirectCloudEntry] = [], grouped: [String: [DirectCloudEntry]] = [:], files: [String: CloudGameCatalog.File] = [:]
        for console in catalog.consoles {
            let folderID = "catalog-console:" + console.id
            folders.append(.init(id: folderID, name: console.name, folder: true))
            var entries: [DirectCloudEntry] = []
            for game in console.games {
                let gameID = "catalog-game:" + game.id, coverID = game.cover.map { _ in "catalog-cover:" + game.id }
                let rom = DirectCloudEntry(id: gameID, name: game.file.components.last!, folder: false,
                    size: game.file.bytes, sha256: game.file.sha256, catalogGameID: game.id,
                    catalogTitle: game.title, artworkID: coverID, catalogConsole: console.id)
                entries.append(rom); files[gameID] = game.file
                if let cover = game.cover, let coverID {
                    entries.append(.init(id: coverID, name: cover.components.last!, folder: false,
                        size: cover.bytes, sha256: cover.sha256, catalogGameID: game.id))
                    files[coverID] = cover
                }
            }
            grouped[folderID] = entries; all += entries
        }
        self.folders = folders; allFiles = all; consoleFiles = grouped; self.files = files
    }
    func list(folder: String) async throws -> [DirectCloudEntry] {
        if folder == rootID { return folders }
        guard let entries = consoleFiles[folder] else { throw DirectCloudError.invalidResponse }
        return entries
    }
    private func listing(_ folder: String) async throws -> [DirectCloudEntry] {
        if let task = listingTasks[folder] { return try await task.value }
        let source = source
        let task = Task { try await source.list(folder: folder) }
        listingTasks[folder] = task
        do { return try await task.value } catch { listingTasks[folder] = nil; throw error }
    }
    private func resolve(_ file: CloudGameCatalog.File) async throws -> DirectCloudEntry {
        var parent = rootID
        for (index, name) in file.components.enumerated() {
            try Task.checkCancellation()
            let matches = try await listing(parent).filter { $0.name == name }
            if index == file.components.count - 1 {
                // Drive permits duplicate filenames. Size can disambiguate an older cover;
                // the selected download still must match the catalog SHA-256 before use.
                let candidates = matches.filter { !$0.folder && $0.size == file.bytes }
                guard candidates.count == 1, let item = candidates.first else { throw DirectCloudError.changed }
                return item
            }
            guard matches.count == 1, let item = matches.first, item.folder else { throw DirectCloudError.changed }
            parent = item.id
        }
        throw DirectCloudError.invalidResponse
    }
    func download(_ entry: DirectCloudEntry, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        guard let file = files[entry.id] else { throw DirectCloudError.invalidResponse }
        let actual = try await resolve(file)
        return try await source.download(actual, progress: progress)
    }
    nonisolated func available(_ entry: DirectCloudEntry, installed: Set<String>) -> Bool {
        if entry.folder { return (consoleFiles[entry.id] ?? []).contains { !DirectCloudArtworkIndex.isImage($0) && !installed.contains($0.catalogGameID ?? "") } }
        return !installed.contains(entry.catalogGameID ?? "")
    }
    nonisolated func plan(selection: Set<String>, installed: Set<String>) throws -> DirectCloudPlan {
        var chosen: [DirectCloudPlannedFile] = [], total: Int64 = 0
        for folder in folders {
            let entries = consoleFiles[folder.id] ?? []
            let selectedGames = entries.filter { !DirectCloudArtworkIndex.isImage($0) && !installed.contains($0.catalogGameID ?? "") && (selection.contains(folder.id) || selection.contains($0.id)) }
            let ids = Set(selectedGames.map(\.id) + selectedGames.compactMap(\.artworkID))
            for entry in entries where ids.contains(entry.id) {
                guard let file = files[entry.id], total <= 32 * 1024 * 1024 * 1024 - file.bytes else { throw DirectCloudError.limit }
                total += file.bytes; chosen.append(.init(entry: entry, components: file.components))
            }
        }
        guard !chosen.isEmpty else { throw DirectCloudError.noGames }
        return .init(files: chosen, bytes: total)
    }
}

private struct CloudInstalledGamesKey: EnvironmentKey { static let defaultValue: Set<String> = [] }
extension EnvironmentValues {
    var cloudInstalledGameIDs: Set<String> {
        get { self[CloudInstalledGamesKey.self] }
        set { self[CloudInstalledGamesKey.self] = newValue }
    }
}
