import Foundation
import simd

/// On-disk container for the small GREY PREVIEW MESH the in-app 3D viewer reads
/// (`mesh-preview.bin`, written once per mesh scan by `ColorMeshBuilder.exportPreviewMesh`).
///
/// 🔴 WHY THIS FILE EXISTS AT ALL — **THE APP CANNOT UNZIP.** The real model (`model.obj`)
/// only ever exists *inside* `model-colored.zip`; the only archive code in the app is the
/// WRITE-ONLY `NSFileCoordinator(.forUploading)` trick in `ColoredOBJExporter`, and there is
/// no zip reader and no third-party dependency in `project.yml`. So "let the customer look at
/// the mesh he just scanned" has to be answered with a file the app itself wrote in a format
/// it can read back. Adding a zip dependency was considered and rejected (2026-08-10): it
/// would mean inflating 40–200MB and parsing a ~2.5M-line ASCII OBJ on the phone — 10–30s and
/// hundreds of MB of RAM — every single time somebody taps "view", which is the opposite of
/// the owner's standing constraint ("nhẹ và nhanh cho khách").
///
/// LAYOUT (little-endian throughout; iOS is LE. Header = 40 bytes):
/// ```
///   0       UInt32   magic "CSMP"
///   4       UInt32   version (= 1)
///   8       UInt32   vertexCount   V
///   12      UInt32   triangleCount T
///   16      Float32 x3   bounds min (world space, metres)
///   28      Float32 x3   bounds max
///   40      Float32 x3 × V   positions, PACKED stride 12
///   40+12V  Float32 x3 × V   normals,   PACKED stride 12
///   40+24V  UInt32  x3 × T   triangle indices
/// ```
///
/// ⚠ The two float blocks are PACKED at stride 12 ON PURPOSE: `SCNGeometrySource(data:…)` in
/// `MeshPreviewView` maps straight onto them with `dataOffset`/`dataStride`, so opening the
/// viewer never converts or re-copies vertex data. **✗ do not "tidy" the writer into an
/// `[SIMD3<Float>]` blit** — `MemoryLayout<SIMD3<Float>>.stride` is **16**, not 12 (SIMD3 is
/// padded), so a blit writes a buffer the reader would silently misinterpret. Same trap as
/// §TECH NOTES "ARMeshGeometry vertices = float3 PACKED stride 12".
enum MeshPreviewFile {
    /// Name inside the SCAN FOLDER (`Documents/Scans/<uuid>/`).
    ///
    /// 🔴 THE SCAN FOLDER IS THE RIGHT PLACE, even though §Xem texture trong app says caches
    /// belong in `.cachesDirectory`. That rule exists for `TexturedModelCache`, which can
    /// always re-download from R2. This file CANNOT be rebuilt — the geometry it came from
    /// lives only inside `model-colored.zip` and the app has no zip reader — and
    /// `.cachesDirectory` is exactly the folder iOS is allowed to empty whenever it likes,
    /// which here would mean the 3D viewer silently dying forever. Something wiping the whole
    /// scan folder is fine: the ScanRecord disappears in the same breath, so there is no screen
    /// left to open. (Since 1.8 the only thing that does that is the CUSTOMER — deleting a
    /// property, `ScanStore.deleteProjectAndScans`, or swiping a scan row. The 14-day
    /// delivered-scan purge is off: `RootView.autoPurgeAfterDelivery`.)
    ///
    /// 🔴 It must NOT reach the delivery pipeline: ✗ add it to `extraFiles` in
    /// `ScanStore.saveMeshScan` (that is what goes into `model-colored.zip`, which the
    /// workstation bake and the floorplan cut both read), and ✗ add it to
    /// `ScanUploader.fileKinds`. Both are explicit allow-lists today, so simply writing the
    /// file into the folder leaks nowhere.
    static let fileName = "mesh-preview.bin"

    enum ReadError: Error { case unreadable, badHeader, truncated, badIndex }
    enum WriteError: Error { case badInput }

    /// "CSMP" read back as a little-endian UInt32.
    private static let magic: UInt32 = 0x504D_5343
    private static let version: UInt32 = 1
    private static let headerBytes = 40

    /// Reader-side sanity caps. The writer stays far below these (the decimator targets
    /// 120k vertices); they only exist so a corrupt/foreign file cannot make the viewer try
    /// to allocate gigabytes before any other check runs.
    private static let maxVertexCount = 4_000_000
    private static let maxTriangleCount = 8_000_000

    /// Everything the viewer needs, in a form that crosses back to the main actor cheaply:
    /// plain `Data` + offsets, no SceneKit objects (those are built on main, where they cost
    /// microseconds because `SCNGeometrySource(data:…)` only retains the buffer).
    struct Decoded {
        /// The whole file. Held because both geometry sources read straight out of it.
        let raw: Data
        let vertexCount: Int
        let triangleCount: Int
        let positionOffset: Int
        let normalOffset: Int
        /// Copied out — `SCNGeometryElement(data:)` has no `dataOffset` parameter.
        let indexData: Data
        let boundsMin: SIMD3<Float>
        let boundsMax: SIMD3<Float>
    }

    // MARK: - Write

    /// Writes the preview file atomically. Caller guarantees positions/normals are finite and
    /// index values are in range — this is only a last line of defence.
    ///
    /// Bytes are gathered into `[UInt8]` and written once, NOT appended into a `Data`:
    /// `Data.append` goes through `RangeReplaceableCollection` machinery per call, which is
    /// the documented hot-spot in `ColoredOBJExporter.writeOBJ`. `Array` append after
    /// `reserveCapacity` is a pointer bump.
    static func write(
        positions: [SIMD3<Float>],
        normals: [SIMD3<Float>],
        indices: [UInt32],
        to url: URL
    ) throws {
        guard !positions.isEmpty,
              positions.count == normals.count,
              positions.count <= maxVertexCount,
              !indices.isEmpty,
              indices.count % 3 == 0,
              indices.count / 3 <= maxTriangleCount
        else { throw WriteError.badInput }

        let vertexCount = positions.count
        let triangleCount = indices.count / 3

        var minB = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxB = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for p in positions {
            minB = simd_min(minB, p)
            maxB = simd_max(maxB, p)
        }
        // A non-finite slipping through would give the viewer a camera at infinity (black
        // screen, no error). Cheaper to refuse the file than to ship that.
        guard minB.x.isFinite, minB.y.isFinite, minB.z.isFinite,
              maxB.x.isFinite, maxB.y.isFinite, maxB.z.isFinite,
              minB.x <= maxB.x, minB.y <= maxB.y, minB.z <= maxB.z
        else { throw WriteError.badInput }

        var out = [UInt8]()
        out.reserveCapacity(headerBytes + vertexCount * 24 + triangleCount * 12)
        appendU32(magic, to: &out)
        appendU32(version, to: &out)
        appendU32(UInt32(vertexCount), to: &out)
        appendU32(UInt32(triangleCount), to: &out)
        appendVec(minB, to: &out)
        appendVec(maxB, to: &out)
        for p in positions { appendVec(p, to: &out) }
        for n in normals { appendVec(n, to: &out) }
        for i in indices { appendU32(i, to: &out) }

        // .atomic: a half-written file after a disk-full at the end of a 10–30 minute scan
        // would be read back as a truncated mesh, and the reader's length check would only
        // turn that into "viewer unavailable" — better to leave no file at all.
        try Data(out).write(to: url, options: .atomic)
    }

    // MARK: - Read

    /// `nonisolated` + `async` ON PURPOSE (SE-0338): called from a `@MainActor` SwiftUI
    /// `.task`, an async function with no actor annotation runs on the cooperative pool, so
    /// the file read + index validation stay OFF the main thread without a `Task.detached`
    /// (which would drag a Sendable question over a SceneKit object).
    static func read(_ url: URL) async -> Decoded? {
        try? readSync(url)
    }

    static func readSync(_ url: URL) throws -> Decoded {
        guard let raw = try? Data(contentsOf: url) else { throw ReadError.unreadable }
        guard raw.count >= headerBytes else { throw ReadError.truncated }

        var vertexCount = 0
        var triangleCount = 0
        var boundsMin = SIMD3<Float>(repeating: 0)
        var boundsMax = SIMD3<Float>(repeating: 0)
        var headerOK = false
        raw.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            guard base.loadUnaligned(fromByteOffset: 0, as: UInt32.self) == Self.magic,
                  base.loadUnaligned(fromByteOffset: 4, as: UInt32.self) == Self.version
            else { return }
            vertexCount = Int(base.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
            triangleCount = Int(base.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
            boundsMin = SIMD3<Float>(
                base.loadUnaligned(fromByteOffset: 16, as: Float.self),
                base.loadUnaligned(fromByteOffset: 20, as: Float.self),
                base.loadUnaligned(fromByteOffset: 24, as: Float.self)
            )
            boundsMax = SIMD3<Float>(
                base.loadUnaligned(fromByteOffset: 28, as: Float.self),
                base.loadUnaligned(fromByteOffset: 32, as: Float.self),
                base.loadUnaligned(fromByteOffset: 36, as: Float.self)
            )
            headerOK = true
        }
        guard headerOK else { throw ReadError.badHeader }
        guard vertexCount > 0, vertexCount <= maxVertexCount,
              triangleCount > 0, triangleCount <= maxTriangleCount,
              boundsMin.x.isFinite, boundsMin.y.isFinite, boundsMin.z.isFinite,
              boundsMax.x.isFinite, boundsMax.y.isFinite, boundsMax.z.isFinite
        else { throw ReadError.badHeader }

        let positionOffset = headerBytes
        let normalOffset = headerBytes + vertexCount * 12
        let indexStart = headerBytes + vertexCount * 24
        let indexBytes = triangleCount * 12
        guard raw.count >= indexStart + indexBytes else { throw ReadError.truncated }

        // 🔴 VALIDATE EVERY INDEX. An out-of-range index in an `SCNGeometryElement` is not a
        // Swift crash you can catch — SceneKit hands the buffer to Metal and the GPU reads
        // past the vertex buffer. ~3T comparisons ≈ 1ms at this size; cheap insurance against
        // a truncated/foreign file.
        var indicesOK = true
        raw.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else {
                indicesOK = false
                return
            }
            let limit = UInt32(vertexCount)
            var off = indexStart
            let end = indexStart + indexBytes
            while off < end {
                if base.loadUnaligned(fromByteOffset: off, as: UInt32.self) >= limit {
                    indicesOK = false
                    return
                }
                off += 4
            }
        }
        guard indicesOK else { throw ReadError.badIndex }

        return Decoded(
            raw: raw,
            vertexCount: vertexCount,
            triangleCount: triangleCount,
            positionOffset: positionOffset,
            normalOffset: normalOffset,
            indexData: raw.subdata(in: indexStart..<(indexStart + indexBytes)),
            boundsMin: boundsMin,
            boundsMax: boundsMax
        )
    }

    // MARK: - Byte helpers

    private static func appendU32(_ value: UInt32, to buffer: inout [UInt8]) {
        withUnsafeBytes(of: value.littleEndian) { buffer.append(contentsOf: $0) }
    }

    private static func appendF32(_ value: Float, to buffer: inout [UInt8]) {
        withUnsafeBytes(of: value.bitPattern.littleEndian) { buffer.append(contentsOf: $0) }
    }

    private static func appendVec(_ v: SIMD3<Float>, to buffer: inout [UInt8]) {
        appendF32(v.x, to: &buffer)
        appendF32(v.y, to: &buffer)
        appendF32(v.z, to: &buffer)
    }
}
