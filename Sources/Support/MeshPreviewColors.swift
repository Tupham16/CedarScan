import Foundation

/// Per-vertex colours of the grey preview (`PreviewColorizer`, 2.77), a small file NEXT TO
/// `mesh-preview.bin` in the scan folder.
///
/// A SEPARATE file on purpose (the plan said "new mesh-preview.bin version"): the grey preview
/// is never rewritten (a colour failure cannot damage it) and an older app build still opens
/// the scan (the owner often installs the main IPA over a branch build). Same leak rules as
/// `mesh-preview.bin`: ✗ `extraFiles` of `ScanStore.saveMeshScan` (the delivery zip), ✗
/// `ScanUploader.fileKinds`, ✗ Share. All three are explicit lists, so the file leaks nowhere.
///
/// LAYOUT (little-endian, header 12 bytes):
/// ```
///   0   UInt32  magic "CSMC"
///   4   UInt32  version (= 1)
///   8   UInt32  vertexCount V (must equal the preview's)
///   12  UInt8 x4 × V   sRGB R, G, B, 255
/// ```
enum MeshPreviewColors {
    static let fileName = "mesh-preview-colors.bin"

    enum FormatError: Error { case badInput, unreadable, badHeader }

    /// "CSMC" read back as a little-endian UInt32.
    private static let magic: UInt32 = 0x434D_5343
    private static let version: UInt32 = 1
    private static let headerBytes = 12

    static func write(_ rgba: [UInt8], vertexCount: Int, to url: URL) throws {
        guard vertexCount > 0, rgba.count == vertexCount * 4 else { throw FormatError.badInput }
        var out = [UInt8]()
        out.reserveCapacity(headerBytes + rgba.count)
        for value in [magic, version, UInt32(vertexCount)] {
            withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        }
        out.append(contentsOf: rgba)
        try Data(out).write(to: url, options: .atomic)
    }

    /// The RGBA8 block, or nil when the file is missing, foreign, or for another mesh.
    static func read(_ url: URL, vertexCount: Int) -> Data? {
        guard vertexCount > 0,
              let raw = try? Data(contentsOf: url),
              raw.count == headerBytes + vertexCount * 4
        else { return nil }
        let ok: Bool = raw.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return false }
            return base.loadUnaligned(fromByteOffset: 0, as: UInt32.self) == magic
                && base.loadUnaligned(fromByteOffset: 4, as: UInt32.self) == version
                && base.loadUnaligned(fromByteOffset: 8, as: UInt32.self) == UInt32(vertexCount)
        }
        return ok ? raw.subdata(in: headerBytes..<raw.count) : nil
    }

    /// sRGB byte → linear. SceneKit renders in linear space and a `.color` geometry source has
    /// no colour space, so its values are taken as LINEAR while the photos' bytes are sRGB:
    /// unconverted they would look washed out. Belief, not measured on a device — if the
    /// phone's colours look darker than the photos, this table is the one lever
    /// (make it `Float(i) / 255`).
    private static let srgbToLinear: [Float] = (0..<256).map { i in
        let c = Float(i) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// The colours as a packed Float RGB (linear) block for `SCNGeometrySource`, or nil.
    /// Non-isolated async (SE-0338): off main. ✗ move it into a View type (its statics are
    /// `@MainActor`, the file read would run on main — see `TexturedSceneLoader`).
    static func loadLinear(_ url: URL, vertexCount: Int) async -> Data? {
        guard let rgba = read(url, vertexCount: vertexCount) else { return nil }
        var floats = [Float](repeating: 0, count: vertexCount * 3)
        rgba.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard buf.count >= vertexCount * 4 else { return }
            for i in 0..<vertexCount {
                floats[i * 3] = srgbToLinear[Int(buf[i * 4])]
                floats[i * 3 + 1] = srgbToLinear[Int(buf[i * 4 + 1])]
                floats[i * 3 + 2] = srgbToLinear[Int(buf[i * 4 + 2])]
            }
        }
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
