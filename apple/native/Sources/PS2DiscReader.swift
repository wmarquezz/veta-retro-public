import Foundation
import Darwin
import zlib

/// Read-only logical disc transport. CSO v1 uses logical 2048-byte sectors and raw
/// DEFLATE; plain ISO/ELF data retains its original byte offsets. No extraction,
/// repair, save writes or engine selection occurs here. Caller validates its
/// library directory; the reader rejects final symlinks and non-regular files.
final class PS2DiscReader: @unchecked Sendable {
    enum Failure: Error {
        case invalidFile, invalidHeader, unsupportedCSO, invalidIndex
        case invalidRead, truncated, corruptBlock, fileChanged, io
    }
    static let maximumDiscBytes: UInt64 = 8 * 1024 * 1024 * 1024
    static let maximumReadBytes = 8 * 1024 * 1024
    let logicalSize: UInt64
    private let descriptor: Int32
    private let physicalSize: UInt64
    private let modification: timespec
    private let change: timespec
    private let index: [UInt32]?
    private let shift: UInt8
    private let blockSize: Int
    private let lock = NSLock()
    // At most 128 KiB of immutable decoded blocks, independent of disc size.
    private var cache: [Int: Data] = [:]
    private var recency: [Int] = []

    init(url: URL) throws {
        guard url.isFileURL else { throw Failure.invalidFile }
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard fd >= 0 else { throw Failure.invalidFile }
        var retained = false
        defer { if !retained { Darwin.close(fd) } }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, UInt64(info.st_size) <= Self.maximumDiscBytes else { throw Failure.invalidFile }
        let fileSize = UInt64(info.st_size)
        let signature = try Self.readPhysical(fd, size: fileSize, offset: 0, count: Int(min(4, fileSize)))
        var parsedIndex: [UInt32]?, parsedShift: UInt8 = 0, parsedBlockSize = 2048
        var size = fileSize
        if signature == Data("CISO".utf8) {
            guard fileSize >= 24 else { throw Failure.invalidHeader }
            let header = try Self.readPhysical(fd, size: fileSize, offset: 0, count: 24)
            func u32(_ position: Int) -> UInt32 {
                header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: position, as: UInt32.self)) }
            }
            let headerBytes = u32(4)
            size = header.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self)) }
            guard headerBytes == 24, size > 0, size <= Self.maximumDiscBytes,
                  size % 2048 == 0 else { throw Failure.invalidHeader }
            let blockBytes = u32(16)
            guard blockBytes >= 2048, blockBytes <= 65536, blockBytes.nonzeroBitCount == 1,
                  header[20] == 1, header[21] <= 16,
                  header[22] == 0, header[23] == 0 else { throw Failure.unsupportedCSO }
            parsedShift = header[21]
            parsedBlockSize = Int(blockBytes)
            let sectors = Int((size + UInt64(blockBytes) - 1) / UInt64(blockBytes)), count = sectors + 1
            let tableEnd = UInt64(headerBytes) + UInt64(count) * 4
            guard tableEnd <= fileSize else { throw Failure.invalidIndex }
            let raw = try Self.readPhysical(fd, size: fileSize, offset: UInt64(headerBytes), count: count * 4)
            let entries: [UInt32] = raw.withUnsafeBytes { bytes in
                (0..<count).map { UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)) }
            }
            let alignment = UInt64(1) << parsedShift
            var previous = UInt64(entries[0] & 0x7fffffff) << parsedShift
            guard previous >= tableEnd, previous <= fileSize,
                  previous - tableEnd < alignment else { throw Failure.invalidIndex }
            // Validate every offset/span before any sector can be served. The
            // final index is an offset only, never a stored-sector flag.
            guard entries[sectors] & 0x80000000 == 0 else { throw Failure.invalidIndex }
            for sector in 0..<sectors {
                let next = UInt64(entries[sector + 1] & 0x7fffffff) << parsedShift
                guard next > previous, next <= fileSize else { throw Failure.invalidIndex }
                let span = next - previous
                if entries[sector] & 0x80000000 != 0 {
                    let decodedBytes = min(UInt64(blockBytes), size - UInt64(sector) * UInt64(blockBytes))
                    guard span >= decodedBytes, span <= decodedBytes + alignment - 1 else { throw Failure.invalidIndex }
                } else {
                    // Bound hostile compressed input independently of output.
                    guard span <= 131072 + alignment - 1 else { throw Failure.invalidIndex }
                }
                previous = next
            }
            guard fileSize - previous < alignment else { throw Failure.invalidIndex }
            parsedIndex = entries
        } else if url.pathExtension.lowercased() == "cso" {
            throw Failure.invalidHeader
        }
        descriptor = fd; physicalSize = fileSize; logicalSize = size
        modification = info.st_mtimespec; change = info.st_ctimespec
        index = parsedIndex; shift = parsedShift; blockSize = parsedBlockSize; retained = true
    }

    deinit { Darwin.close(descriptor) }

    func read(offset: UInt64, length: Int) throws -> Data {
        guard length >= 0, length <= Self.maximumReadBytes, offset <= logicalSize,
              UInt64(length) <= logicalSize - offset else { throw Failure.invalidRead }
        lock.lock(); defer { lock.unlock() }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw Failure.io }
        guard info.st_size >= 0, UInt64(info.st_size) == physicalSize,
              info.st_mtimespec.tv_sec == modification.tv_sec, info.st_mtimespec.tv_nsec == modification.tv_nsec,
              info.st_ctimespec.tv_sec == change.tv_sec, info.st_ctimespec.tv_nsec == change.tv_nsec else { throw Failure.fileChanged }
        if length == 0 { return Data() }
        guard let index else { return try Self.readPhysical(descriptor, size: physicalSize, offset: offset, count: length) }
        var result = Data(count: length), written = 0
        while written < length {
            let position = offset + UInt64(written), sector = Int(position / UInt64(blockSize)), within = Int(position % UInt64(blockSize))
            let data = try block(sector, index: index), count = min(length - written, data.count - within)
            result.replaceSubrange(written..<(written + count), with: data[within..<(within + count)])
            written += count
        }
        return result
    }

    /// Called only under lock; a failed decode never enters the cache.
    private func block(_ sector: Int, index: [UInt32]) throws -> Data {
        if let data = cache[sector] {
            recency.removeAll { $0 == sector }; recency.append(sector)
            return data
        }
        let start = UInt64(index[sector] & 0x7fffffff) << shift
        let end = UInt64(index[sector + 1] & 0x7fffffff) << shift
        let decodedBytes = min(blockSize, Int(logicalSize - UInt64(sector) * UInt64(blockSize)))
        let data: Data
        if index[sector] & 0x80000000 != 0 {
            data = try Self.readPhysical(descriptor, size: physicalSize, offset: start, count: decodedBytes)
        } else {
            let compressed = try Self.readPhysical(descriptor, size: physicalSize, offset: start, count: Int(end - start))
            data = try Self.inflateBlock(compressed, expectedBytes: decodedBytes, alignment: 1 << Int(shift))
        }
        if cache.count == 131072 / blockSize { cache.removeValue(forKey: recency.removeFirst()) }
        cache[sector] = data; recency.append(sector)
        return data
    }

    private static func readPhysical(_ fd: Int32, size: UInt64, offset: UInt64, count: Int) throws -> Data {
        guard count >= 0, offset <= size, UInt64(count) <= size - offset else { throw Failure.truncated }
        var result = Data(count: count)
        try result.withUnsafeMutableBytes { buffer in
            var completed = 0
            while completed < count {
                let read = pread(fd, buffer.baseAddress!.advanced(by: completed), count - completed, off_t(offset) + off_t(completed))
                if read < 0 { if errno == EINTR { continue }; throw Failure.io }
                guard read > 0 else { throw Failure.truncated }
                completed += read
            }
        }
        return result
    }

    private static func inflateBlock(_ compressed: Data, expectedBytes: Int, alignment: Int) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw Failure.corruptBlock }
        defer { inflateEnd(&stream) }
        // One extra byte detects streams producing more than the declared block.
        var result = Data(count: expectedBytes + 1)
        let status: Int32 = compressed.withUnsafeBytes { source in
            result.withUnsafeMutableBytes { destination in
                stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress!)
                stream.avail_in = uInt(compressed.count)
                stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress!
                stream.avail_out = uInt(expectedBytes + 1)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END, stream.total_out == expectedBytes,
              stream.avail_in < alignment else { throw Failure.corruptBlock }
        result.removeLast()
        return result
    }
}
