import SwiftUI
import ImageIO

/// Pair only sibling files with the same normalized stem; never fetch game bytes for previews.
struct DirectCloudArtworkIndex {
    let folders: [DirectCloudEntry]
    let games: [DirectCloudEntry]
    let unpairedImages: [DirectCloudEntry]
    let covers: [String: DirectCloudEntry]
    static func stem(_ name: String) -> String {
        (name as NSString).deletingPathExtension.precomposedStringWithCanonicalMapping.lowercased()
    }
    static func isImage(_ item: DirectCloudEntry) -> Bool {
        !item.folder && LocalCoverImport.imageExtensions.contains((item.name as NSString).pathExtension.lowercased())
    }
    init(_ entries: [DirectCloudEntry]) {
        folders = entries.filter(\.folder)
        games = entries.filter { !$0.folder && !Self.isImage($0) }
        let images = entries.filter(Self.isImage)
        let grouped = Dictionary(grouping: images, by: { Self.stem($0.name) })
        var result: [String: DirectCloudEntry] = [:], paired = Set<String>()
        let byID = Dictionary(images.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for game in games {
            if game.catalogGameID != nil {
                if let id = game.artworkID, let image = byID[id] { result[game.id] = image; paired.insert(id) }
                continue
            }
            let matches = grouped[Self.stem(game.name)] ?? []
            let preferred = matches.sorted {
                let order = ["png", "jpg", "jpeg", "heic", "webp"]
                let a = order.firstIndex(of: ($0.name as NSString).pathExtension.lowercased()) ?? 99
                let b = order.firstIndex(of: ($1.name as NSString).pathExtension.lowercased()) ?? 99
                return a == b ? $0.name < $1.name : a < b
            }.first
            result[game.id] = preferred
            paired.formUnion(matches.map(\.id))
        }
        covers = result
        unpairedImages = images.filter { !paired.contains($0.id) }
    }
}

/// Per-connection memory cache. No cloud images or credentials are written to a persistent cache.
actor DirectCloudArtworkLoader {
    private let source: DirectCloudSource
    private let cache = NSCache<NSString, UIImage>()
    private var active = 0
    init(source: DirectCloudSource) { self.source = source; cache.totalCostLimit = 24 * 1024 * 1024; cache.countLimit = 80 }
    func image(_ item: DirectCloudEntry, large: Bool = false) async throws -> UIImage {
        guard DirectCloudArtworkIndex.isImage(item), let size = item.size, size > 0, size <= 30 * 1024 * 1024 else { throw DirectCloudError.noPreview }
        let key = "\(item.id)|\(item.revision ?? item.md5 ?? item.dropboxHash ?? "")|\(size)|\(large)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        while active >= 2 { try await Task.sleep(nanoseconds: 50_000_000) }
        try Task.checkCancellation()
        if let hit = cache.object(forKey: key) { return hit }
        active += 1; defer { active -= 1 }
        let file = try await source.download(item) { _, _ in }
        defer { try? FileManager.default.removeItem(at: file) }
        try Task.checkCancellation()
        try DirectCloudTransfer.validateFile(file, entry: item)
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: large ? 1200 : 320,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw DirectCloudError.noPreview }
        let image = UIImage(cgImage: cg)
        try Task.checkCancellation()
        cache.setObject(image, forKey: key, cost: cg.bytesPerRow * cg.height)
        return image
    }
}

struct DirectCloudThumbnail: View {
    let entry: DirectCloudEntry?
    let loader: DirectCloudArtworkLoader?
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(VetaTheme.panel)
            if let image { Image(uiImage: image).resizable().scaledToFit().padding(4) }
            else { Image(systemName: "gamecontroller.fill").font(.system(size: 32)).foregroundStyle(VetaTheme.mint) }
        }
        .frame(height: 140).clipped().accessibilityHidden(true)
        .task(id: entry) {
            image = nil
            if let entry, let loader { image = try? await loader.image(entry) }
        }
    }
}

struct DirectCloudArtworkPreview: View {
    let entry: DirectCloudEntry
    let loader: DirectCloudArtworkLoader?
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let image { Image(uiImage: image).resizable().scaledToFit() }
                else if failed { ContentUnavailableView("Vista previa no disponible", systemImage: "photo") }
                else { ProgressView() }
                Text(entry.name).font(.footnote).multilineTextAlignment(.center).textSelection(.enabled)
            }.padding().navigationTitle("Vista previa").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Cerrar") { dismiss() } } }
                .task {
                    guard let loader else { failed = true; return }
                    do { image = try await loader.image(entry, large: true) }
                    catch is CancellationError {} catch { failed = true }
                }
        }
    }
}
