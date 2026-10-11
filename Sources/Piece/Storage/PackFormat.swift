import CryptoKit
import Foundation

/// What's inside a `.piecepack`: one entry per original file.
struct PackedFile: Codable, Equatable {
    var name: String
    var size: Int64
    var sha256: String
    var modified: Date
}

struct PackManifest: Codable, Equatable {
    var version = 1
    var files: [PackedFile]
}

enum PackError: LocalizedError {
    case cancelled
    case corrupt(String)
    case mismatch(String)
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: "Cancelled."
        case .corrupt(let why): "The packed file is damaged (\(why))."
        case .mismatch(let name): "“\(name)” didn't match its checksum, so nothing was changed."
        case .missing(let name): "“\(name)” can't be found."
        }
    }
}

/// A simple chunked container: files are read in 4 MB pieces, each LZMA-compressed (or stored raw when that
/// doesn't help). A JSON manifest with SHA-256 checksums sits at the end so a pack can be verified without
/// trusting the disk, and unpacking is byte-identical.
///
/// Layout: `PIECEPK1` · chunks (`flag:u8 · raw:u32 · stored:u32 · bytes`) · manifest JSON · manifest length (u64) · `PIECEPK1`
enum PackFormat {
    static let magic = Data("PIECEPK1".utf8)
    static let chunkSize = 4 * 1024 * 1024

    /// Packs `files` into `destination`. `progress` gets 0...1; return `true` from `isCancelled` to stop.
    static func pack(files: [(url: URL, name: String)], to destination: URL,
                     progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { false }) throws -> PackManifest {
        let fm = FileManager.default
        let partial = destination.appendingPathExtension("partial")
        fm.createFile(atPath: partial.path, contents: nil)
        let out = try FileHandle(forWritingTo: partial)
        defer { try? out.close() }
        var succeeded = false
        defer { if !succeeded { try? fm.removeItem(at: partial) } }

        try out.write(contentsOf: magic)
        let total = max(1, files.reduce(Int64(0)) { $0 + ((try? $1.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0) })
        var done: Int64 = 0
        var entries: [PackedFile] = []

        for (url, name) in files {
            guard fm.fileExists(atPath: url.path) else { throw PackError.missing(name) }
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            var hasher = SHA256()
            var size: Int64 = 0
            while true {
                if isCancelled() { throw PackError.cancelled }
                let chunk = try autoreleasepool { try input.read(upToCount: chunkSize) } ?? Data()
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
                size += Int64(chunk.count)
                done += Int64(chunk.count)
                let packed = try? (chunk as NSData).compressed(using: .lzma) as Data
                var header = Data()
                if let packed, packed.count < chunk.count {
                    header.append(1)
                    header.append(littleEndian: UInt32(chunk.count))
                    header.append(littleEndian: UInt32(packed.count))
                    try out.write(contentsOf: header + packed)
                } else {
                    header.append(0)
                    header.append(littleEndian: UInt32(chunk.count))
                    header.append(littleEndian: UInt32(chunk.count))
                    try out.write(contentsOf: header + chunk)
                }
                progress(Double(done) / Double(total))
            }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            entries.append(PackedFile(name: name, size: size, sha256: hasher.finalize().hex, modified: modified))
        }

        let manifest = PackManifest(files: entries)
        let json = try JSONEncoder().encode(manifest)
        try out.write(contentsOf: json)
        var tail = Data()
        tail.append(littleEndian: UInt64(json.count))
        try out.write(contentsOf: tail + magic)
        try out.close()
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: partial, to: destination)
        succeeded = true
        return manifest
    }

    static func manifest(of pack: URL) throws -> PackManifest {
        let input = try FileHandle(forReadingFrom: pack)
        defer { try? input.close() }
        let end = try input.seekToEnd()
        guard end > UInt64(magic.count * 2 + 8) else { throw PackError.corrupt("too short") }
        try input.seek(toOffset: end - UInt64(magic.count) - 8)
        guard let tail = try input.read(upToCount: 8 + magic.count), tail.suffix(magic.count) == magic else { throw PackError.corrupt("no footer") }
        let length = tail.prefix(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
        guard length < end else { throw PackError.corrupt("bad manifest size") }
        try input.seek(toOffset: end - UInt64(magic.count) - 8 - length)
        guard let json = try input.read(upToCount: Int(length)),
              let manifest = try? JSONDecoder().decode(PackManifest.self, from: json) else { throw PackError.corrupt("bad manifest") }
        return manifest
    }

    /// Reads every file out of `pack`, checking each against its checksum. `destination(name)` says where
    /// to write; pass `nil` to only verify. Nothing is left behind if a checksum fails.
    @discardableResult
    static func unpack(_ pack: URL, destination: ((String) -> URL)?, progress: (Double) -> Void = { _ in },
                       isCancelled: () -> Bool = { false }) throws -> PackManifest {
        let manifest = try manifest(of: pack)
        let input = try FileHandle(forReadingFrom: pack)
        defer { try? input.close() }
        guard try input.read(upToCount: magic.count) == magic else { throw PackError.corrupt("bad header") }
        let fm = FileManager.default
        let total = max(1, manifest.files.reduce(Int64(0)) { $0 + $1.size })
        var done: Int64 = 0
        var finished: [(partial: URL, final: URL, modified: Date)] = []
        defer { for item in finished where fm.fileExists(atPath: item.partial.path) { try? fm.removeItem(at: item.partial) } }

        for entry in manifest.files {
            var writer: FileHandle?
            if let destination {
                let final = destination(entry.name)
                try fm.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
                let partial = final.appendingPathExtension("piece-partial")
                fm.createFile(atPath: partial.path, contents: nil)
                writer = try FileHandle(forWritingTo: partial)
                finished.append((partial, final, entry.modified))
            }
            defer { try? writer?.close() }
            var hasher = SHA256()
            var remaining = entry.size
            while remaining > 0 {
                if isCancelled() { throw PackError.cancelled }
                guard let header = try input.read(upToCount: 9), header.count == 9 else { throw PackError.corrupt("truncated") }
                let flag = header[header.startIndex]
                let raw = Int(header.subdata(in: header.startIndex + 1..<header.startIndex + 5).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
                let stored = Int(header.subdata(in: header.startIndex + 5..<header.startIndex + 9).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
                guard let body = try input.read(upToCount: stored), body.count == stored else { throw PackError.corrupt("truncated") }
                let chunk: Data
                if flag == 1 {
                    guard let inflated = try? (body as NSData).decompressed(using: .lzma) as Data, inflated.count == raw else {
                        throw PackError.corrupt("bad chunk")
                    }
                    chunk = inflated
                } else {
                    chunk = body
                }
                hasher.update(data: chunk)
                try writer?.write(contentsOf: chunk)
                remaining -= Int64(chunk.count)
                done += Int64(chunk.count)
                progress(Double(done) / Double(total))
            }
            guard hasher.finalize().hex == entry.sha256 else { throw PackError.mismatch(entry.name) }
        }
        for item in finished {
            try? fm.removeItem(at: item.final)
            try fm.moveItem(at: item.partial, to: item.final)
            try? fm.setAttributes([.modificationDate: item.modified], ofItemAtPath: item.final.path)
        }
        return manifest
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

private extension SHA256.Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
