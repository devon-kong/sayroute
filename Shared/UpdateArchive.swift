import Foundation
import zlib

/// Inspect both central and local ZIP headers before giving any path to ditto.
/// ZIP64, encrypted archives and symlinks are deliberately unsupported.
enum UpdateArchive {
    static let maximumArchiveBytes = 200 * 1024 * 1024
    static let maximumExpandedBytes = 500 * 1024 * 1024

    static func applicationRoot(in data: Data) throws -> String {
        guard data.count >= 22, data.count <= maximumArchiveBytes else { throw SafeUpdateError.unsafeArchive }
        func number(_ offset: Int, _ length: Int) throws -> UInt32 {
            guard offset >= 0, offset <= data.count - length else { throw SafeUpdateError.unsafeArchive }
            var value: UInt32 = 0
            for i in 0..<length { value |= UInt32(data[offset + i]) << (8 * i) }
            return value
        }
        func validateExtra(_ start: Int, _ length: Int) throws {
            var cursor = start
            guard start >= 0, length >= 0, start + length <= data.count else { throw SafeUpdateError.unsafeArchive }
            while cursor < start + length {
                guard cursor + 4 <= start + length else { throw SafeUpdateError.unsafeArchive }
                let kind = try number(cursor, 2), size = Int(try number(cursor + 2, 2))
                // Timestamps and Unix UID/GID only. Reject ZIP64, alternative
                // Unicode names and link metadata an extractor could interpret.
                guard [0x5455, 0x5855, 0x7875, 0x000a].contains(kind),
                      cursor + 4 + size <= start + length else { throw SafeUpdateError.unsafeArchive }
                cursor += 4 + size
            }
        }
        var end: Int?
        for i in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) {
            if try number(i, 4) == 0x06054b50, i + 22 + Int(try number(i + 20, 2)) == data.count { end = i; break }
        }
        guard let end, try number(end + 4, 2) == 0, try number(end + 6, 2) == 0 else { throw SafeUpdateError.unsafeArchive }
        let count = Int(try number(end + 10, 2)), size = Int(try number(end + 12, 4)), start = Int(try number(end + 16, 4))
        guard count > 0, count <= 10_000, try number(end + 8, 2) == count,
              start + size == end else { throw SafeUpdateError.unsafeArchive }
        var cursor = start, expanded = 0, roots: Set<String> = [], paths: Set<String> = [], ranges: [Range<Int>] = []
        for _ in 0..<count {
            guard try number(cursor, 4) == 0x02014b50 else { throw SafeUpdateError.unsafeArchive }
            let flags = try number(cursor + 8, 2), method = try number(cursor + 10, 2)
            let crc = try number(cursor + 16, 4)
            let compressed = Int(try number(cursor + 20, 4)), uncompressed = Int(try number(cursor + 24, 4))
            let length = Int(try number(cursor + 28, 2)), extra = Int(try number(cursor + 30, 2)), comment = Int(try number(cursor + 32, 2))
            let attributes = try number(cursor + 38, 4), local = Int(try number(cursor + 42, 4))
            let mode = attributes >> 16, type = mode & 0xF000
            guard flags & 1 == 0, method == 0 || method == 8, try number(cursor + 34, 2) == 0,
                  type == 0 || type == 0x8000 || type == 0x4000, mode & 0o6000 == 0,
                  length > 0, cursor + 46 + length + extra + comment <= end else { throw SafeUpdateError.unsafeArchive }
            expanded += uncompressed
            guard expanded <= maximumExpandedBytes else { throw SafeUpdateError.unsafeArchive }
            let pathData = data.subdata(in: (cursor + 46)..<(cursor + 46 + length))
            try validateExtra(cursor + 46 + length, extra)
            guard let name = String(data: pathData, encoding: .utf8), !name.hasPrefix("/"), !name.contains("\\"),
                  !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw SafeUpdateError.unsafeArchive }
            let trimmed = name.hasSuffix("/") ? String(name.dropLast()) : name
            let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  paths.insert(trimmed.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw SafeUpdateError.unsafeArchive }
            let root = String(parts[0])
            if root != "__MACOSX" {
                guard root.hasSuffix(".app") else { throw SafeUpdateError.unsafeArchive }
                roots.insert(root)
            }
            guard try number(local, 4) == 0x04034b50, try number(local + 6, 2) == flags,
                  try number(local + 8, 2) == method, Int(try number(local + 26, 2)) == length else { throw SafeUpdateError.unsafeArchive }
            let localExtra = Int(try number(local + 28, 2)), body = local + 30 + length + localExtra
            guard body + compressed <= start, local + 30 + length <= start,
                  data.subdata(in: (local + 30)..<(local + 30 + length)) == pathData else { throw SafeUpdateError.unsafeArchive }
            try validateExtra(local + 30 + length, localExtra)
            if flags & 8 == 0 {
                guard try number(local + 14, 4) == crc,
                      try number(local + 18, 4) == compressed,
                      try number(local + 22, 4) == uncompressed else { throw SafeUpdateError.unsafeArchive }
            }
            try validateContent(data.subdata(in: body..<(body + compressed)), method: method,
                                expectedSize: uncompressed, expectedCRC: crc)
            let range = local..<(body + compressed)
            guard !ranges.contains(where: { $0.overlaps(range) }) else { throw SafeUpdateError.unsafeArchive }
            ranges.append(range)
            cursor += 46 + length + extra + comment
        }
        guard cursor == end, roots.count == 1, let root = roots.first else { throw SafeUpdateError.unsafeArchive }
        return root
    }

    /// Bound actual decompression too: a forged size in ZIP metadata is not a
    /// resource limit. Validate in a small buffer before the filesystem extractor.
    private static func validateContent(_ data: Data, method: UInt32, expectedSize: Int, expectedCRC: UInt32) throws {
        if method == 0 {
            let crc = data.withUnsafeBytes { raw in
                crc32(0, raw.bindMemory(to: Bytef.self).baseAddress, uInt(raw.count))
            }
            guard data.count == expectedSize, UInt32(crc) == expectedCRC else { throw SafeUpdateError.unsafeArchive }
            return
        }
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw SafeUpdateError.unsafeArchive
        }
        defer { inflateEnd(&stream) }
        try data.withUnsafeBytes { raw in
            stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(raw.count)
            var buffer = [UInt8](repeating: 0, count: 32_768)
            var total = 0, crc: uLong = 0
            while true {
                let status = buffer.withUnsafeMutableBufferPointer { output -> Int32 in
                    stream.next_out = output.baseAddress
                    stream.avail_out = uInt(output.count)
                    let status = inflate(&stream, Z_NO_FLUSH)
                    let written = output.count - Int(stream.avail_out)
                    total += written
                    crc = crc32(crc, output.baseAddress, uInt(written))
                    return status
                }
                guard total <= expectedSize, status == Z_OK || status == Z_STREAM_END else { throw SafeUpdateError.unsafeArchive }
                if status == Z_STREAM_END {
                    guard total == expectedSize, stream.avail_in == 0, UInt32(crc) == expectedCRC else { throw SafeUpdateError.unsafeArchive }
                    return
                }
            }
        }
    }
}
