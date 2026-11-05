import Compression
import Foundation

/// Writes the scan zip (`model-colored.zip`) itself so the save can show how far it has got
/// (owner 05/11: "Compressing…" sat at 85% under `NSFileCoordinator(.forUploading)`, which
/// reports nothing, and customers took the app for hung).
///
/// Same entries as that zipper (the owner's zip of 05/11 checked): every regular file below
/// `directory`, named `<directory name>/<relative path>`, no folder entries, all deflate; the
/// files inside are byte for byte what they were. Readers: texbake + openings (Python zipfile),
/// cut-worker (`tar -xf`), MeshCut (fflate); the server never opens it. The container differs:
/// sizes in the local headers (no data descriptors), no extra fields, no zip64 — past 4 GB or
/// 65,535 entries it throws and the caller falls back to the old zipper. Checked against Python
/// zipfile, bsdtar and unzip by `tools/zip-harness` (run on macOS CI: SESSION-HANDOFF).
enum ZipWriter {
    enum ZipError: Error { case unreadable, tooLarge }

    /// `progress`: bytes read so far / all bytes (0…1), at most ~200 calls, on this thread.
    static func write(_ directory: URL, to zipURL: URL, progress: (Double) -> Void) throws {
        let fm = FileManager.default
        guard let walker = fm.enumerator(atPath: directory.path) else { throw ZipError.unreadable }
        var files: [(path: String, size: Int64, date: Date)] = []
        while let path = walker.nextObject() as? String {
            guard let attrs = walker.fileAttributes,
                  attrs[.type] as? FileAttributeType == .typeRegular else { continue }
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            files.append((path, size, attrs[.modificationDate] as? Date ?? Date()))
        }
        guard files.count <= 0xFFFF else { throw ZipError.tooLarge }
        let total = max(1, files.reduce(0) { $0 + $1.size })
        let step = max(1, total / 200)
        let prefix = directory.lastPathComponent + "/"

        guard fm.createFile(atPath: zipURL.path, contents: nil) else { throw ZipError.unreadable }
        let out = try FileHandle(forWritingTo: zipURL)
        defer { try? out.close() }
        var offset: UInt64 = 0
        var central = Data()
        var done: Int64 = 0
        var reported: Int64 = 0

        for file in files {
            let name = Data((prefix + file.path).utf8)
            let flags: UInt16 = name.allSatisfy { $0 < 0x80 } ? 0 : 0x0800 // bit 11: UTF-8 name
            let stamp = dosStamp(file.date)
            let headerOffset = offset
            guard headerOffset < 0xFFFF_FFFF, name.count <= 0xFFFF else { throw ZipError.tooLarge }

            var header = Data()
            header.le32(0x0403_4B50)
            header.le16(20)
            header.le16(flags)
            header.le16(8)
            header.le16(stamp.time)
            header.le16(stamp.date)
            header.le32(0) // CRC and both sizes: patched once the file is through
            header.le32(0)
            header.le32(0)
            header.le16(UInt16(name.count))
            header.le16(0)
            header.append(name)
            try out.write(contentsOf: header)
            offset += UInt64(header.count)

            var crc: UInt32 = 0
            var read: UInt64 = 0
            var packed: UInt64 = 0
            let input = try FileHandle(forReadingFrom: directory.appendingPathComponent(file.path))
            defer { try? input.close() }
            // `.zlib` = raw DEFLATE (RFC 1951, no zlib header / Adler-32): zip method 8 as is.
            let filter = try OutputFilter(.compress, using: .zlib, bufferCapacity: 1 << 20) { chunk in
                guard let chunk, !chunk.isEmpty else { return }
                try out.write(contentsOf: chunk)
                packed += UInt64(chunk.count)
            }
            while true {
                let more = try autoreleasepool { () -> Bool in
                    guard let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
                    crc = crc32(crc, chunk)
                    try filter.write(chunk)
                    read += UInt64(chunk.count)
                    done += Int64(chunk.count)
                    return true
                }
                guard more else { break }
                if done - reported >= step {
                    reported = done
                    progress(min(1, Double(done) / Double(total)))
                }
            }
            try filter.finalize()
            guard read < 0xFFFF_FFFF, packed < 0xFFFF_FFFF else { throw ZipError.tooLarge }
            offset += packed

            var sizes = Data()
            sizes.le32(crc)
            sizes.le32(UInt32(packed))
            sizes.le32(UInt32(read))
            try out.seek(toOffset: headerOffset + 14)
            try out.write(contentsOf: sizes)
            try out.seek(toOffset: offset)

            central.le32(0x0201_4B50)
            central.le16(0x0314) // made by Unix, zip 2.0 (as the old zipper)
            central.le16(20)
            central.le16(flags)
            central.le16(8)
            central.le16(stamp.time)
            central.le16(stamp.date)
            central.le32(crc)
            central.le32(UInt32(packed))
            central.le32(UInt32(read))
            central.le16(UInt16(name.count))
            central.le16(0) // extra
            central.le16(0) // comment
            central.le16(0) // disk
            central.le16(0) // internal attributes
            central.le32(0x81A4_0000) // regular file, rw-r--r-- (as the old zipper)
            central.le32(UInt32(headerOffset))
            central.append(name)
        }

        guard offset < 0xFFFF_FFFF, offset + UInt64(central.count) < 0xFFFF_FFFF else {
            throw ZipError.tooLarge
        }
        try out.write(contentsOf: central)
        var end = Data()
        end.le32(0x0605_4B50)
        end.le16(0)
        end.le16(0)
        end.le16(UInt16(files.count))
        end.le16(UInt16(files.count))
        end.le32(UInt32(central.count))
        end.le32(UInt32(offset))
        end.le16(0)
        try out.write(contentsOf: end)
        progress(1)
    }

    /// MS-DOS date and time (local time, 2-second steps, years 1980…2107).
    private static func dosStamp(_ date: Date) -> (time: UInt16, date: UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        let year = min(max((c.year ?? 1980) - 1980, 0), 127)
        let time = (c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2
        let day = year << 9 | (c.month ?? 1) << 5 | (c.day ?? 1)
        return (UInt16(time), UInt16(day))
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    /// CRC-32 (zip / IEEE), continued from `crc` (0 to start). "123456789" → 0xCBF43926.
    static func crc32(_ crc: UInt32, _ data: Data) -> UInt32 {
        var c = ~crc
        crcTable.withUnsafeBufferPointer { table in
            data.withUnsafeBytes { bytes in
                for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
            }
        }
        return ~c
    }
}

private extension Data {
    mutating func le16(_ v: UInt16) {
        append(UInt8(truncatingIfNeeded: v))
        append(UInt8(truncatingIfNeeded: v >> 8))
    }

    mutating func le32(_ v: UInt32) {
        le16(UInt16(truncatingIfNeeded: v))
        le16(UInt16(truncatingIfNeeded: v >> 16))
    }
}
