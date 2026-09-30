import CoreGraphics
import Foundation
import ImageIO
import simd

/// Colours the GREY PREVIEW on the phone during save, from the texture shots the app already
/// records (2.77, owner 30/09, `PLAN-XEM-3D-TANG-MAU.md` build 2), so the viewer's Texture
/// switch works before the scan is ordered. The baked workstation texture still wins when the
/// scan has one (`ModelViewerScreen`).
///
/// WHEN: the shots live only in tmp during `ScanStore.saveMeshScan` (its `defer` deletes them
/// after the zip) and the app has no zip reader ⇒ colour DURING save, on `PreviewColorJob`'s
/// own queue, in parallel with the OBJ/zip step. Old scans: no colours.
///
/// ALGORITHM = offline sim `scratch_texpreview/color_sim.py` (gitignored), per preview vertex:
/// project into every shot with the shots.json convention (q = inverse(m)·P, u = fx·q.x/(−q.z)
/// + cx, v = fy·(−q.y)/(−q.z) + cy), keep it when in front (q.z < −0.05), inside the image
/// (1 ≤ u < w − 2, 1 ≤ v < h − 2), ≤ 6 m, seen by the shot's LiDAR depth (|d − z| <
/// max(0.12, 0.06·z), nearest depth pixel) and facing it (cos > 0.2); weight cos²/max(dist,
/// 0.6)²; blend the 3 best. Uncoloured vertices: edge diffusion from coloured neighbours, ≤ 60
/// passes; the rest stays grey 150. #LS-MTR8E4ZI5 (118.6k-vertex preview, 187 shots): 56%
/// direct, 95% after fill, 3.8 s desktop numpy. Shots decoded at ≤ 720 px (decoder subsample):
/// review port of this file vs the sim on MTR8: 56.2% / 95.5%, per vertex mean |Δ| 0.8/255,
/// p99 7 (01/10).
///
/// VALVES (promised to the owner): phone `.critical` hot, or > 10 s ⇒ stop, keep the grey
/// preview as today. Any failure = grey, never a failed save: the only output is a separate
/// small file written at the very end. All-or-nothing ON PURPOSE (the promise). If device
/// reports show big hot scans ending "timeout", the lever is: interleave the shot order and
/// blend what exists at the deadline (a "partial" status) — an owner call, it changes the promise.
/// Cost (review 01/10, C port of `project` on a desktop): ~3 ns per vertex × shot, decode
/// ~2 ms per shot at half size ⇒ MTR8 ~1–2 s on an iPhone 12 Pro, 800 shots × 150k ~4–8 s,
/// more when hot and next to the zip step. RAM ~14 MB (the preview bytes are dropped first).
enum PreviewColorizer {
    /// Outcome for scan-report.json `previewColour` (the owner's device numbers).
    struct Stats {
        var status = "failed"
        var seconds: Double = 0
        var shots = 0
        var shotsUsed = 0
        var vertices = 0
        /// Fraction of vertices coloured straight from a shot / after the fill.
        var direct: Double = 0
        var filled: Double = 0
        var thermal = ""

        var json: [String: Any] {
            [
                "status": status,
                "ms": Int((seconds * 1000).rounded()),
                "shots": shots,
                "shotsUsed": shotsUsed,
                "vertices": vertices,
                "direct": (direct * 1000).rounded() / 1000,
                "filled": (filled * 1000).rounded() / 1000,
                "thermal": thermal,
            ]
        }
    }

    static let budgetSeconds: Double = 10
    static let maxImageSide = 720
    /// The app writes ≤ ~150k-vertex previews; anything far bigger (a foreign or corrupt file)
    /// is not worth the RAM next to the save's own PLY parse.
    static let maxVertices = 300_000
    /// Below this many directly coloured vertices the fill would smear a few shots over the
    /// whole house: keep it grey.
    static let minDirectFraction = 0.2
    static let fillPasses = 60
    static let grey: UInt8 = 150

    private struct Shot: Decodable {
        let file: String
        let m: [Float]
        let fx: Float
        let fy: Float
        let cx: Float
        let cy: Float
        let w: Int
        let h: Int
        let depth: String?
        let dw: Int?
        let dh: Int?
    }

    private struct ShotsFile: Decodable {
        let shots: [Shot]
    }

    /// Synchronous: run it on a queue of its own (`PreviewColorJob`), never on main and never
    /// on the cooperative pool (it can take up to `budgetSeconds`).
    static func run(previewURL: URL, shotsDir: URL, isCancelled: () -> Bool) -> Stats {
        let start = ProcessInfo.processInfo.systemUptime
        var stats = Stats()
        func elapsed() -> Double { ProcessInfo.processInfo.systemUptime - start }
        func finish(_ status: String) -> Stats {
            stats.status = status
            stats.seconds = elapsed()
            stats.thermal = thermalName(ProcessInfo.processInfo.thermalState)
            return stats
        }

        if ProcessInfo.processInfo.thermalState == .critical { return finish("hot") }
        guard let mesh = loadMesh(previewURL) else { return finish("noPreview") }
        guard mesh.vertexCount <= maxVertices else { return finish("tooBig") }
        guard let shotsData = try? Data(contentsOf: shotsDir.appendingPathComponent("shots.json")),
              let shots = try? JSONDecoder().decode(ShotsFile.self, from: shotsData).shots,
              !shots.isEmpty
        else { return finish("noShots") }
        stats.shots = shots.count

        let n = mesh.vertexCount
        stats.vertices = n
        let geo = mesh.geo

        // Top-3 per vertex: weight + packed 0xBBGGRR colour.
        var bestW = [Float](repeating: 0, count: n * 3)
        var bestC = [UInt32](repeating: 0, count: n * 3)
        // One reusable RGBA8 buffer for every decoded shot.
        var pixels = [UInt8](repeating: 0, count: maxImageSide * maxImageSide * 4)
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return finish("failed") }

        for shot in shots {
            if isCancelled() { return finish("cancelled") }
            if elapsed() > budgetSeconds { return finish("timeout") }
            if ProcessInfo.processInfo.thermalState == .critical { return finish("hot") }
            // autoreleasepool: ImageIO / CoreGraphics objects of one shot die with it.
            let used: Bool = autoreleasepool {
                guard shot.m.count == 16, shot.m.allSatisfy({ $0.isFinite }),
                      shot.w > 3, shot.h > 3,
                      shot.fx.isFinite, shot.fy.isFinite, shot.cx.isFinite, shot.cy.isFinite
                else { return false }
                let m = simd_float4x4(columns: (
                    SIMD4<Float>(shot.m[0], shot.m[1], shot.m[2], shot.m[3]),
                    SIMD4<Float>(shot.m[4], shot.m[5], shot.m[6], shot.m[7]),
                    SIMD4<Float>(shot.m[8], shot.m[9], shot.m[10], shot.m[11]),
                    SIMD4<Float>(shot.m[12], shot.m[13], shot.m[14], shot.m[15])
                ))
                let inv = m.inverse
                guard inv.columns.0.x.isFinite, inv.columns.3.z.isFinite else { return false }
                let camera = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)

                guard let image = decodeShot(shotsDir.appendingPathComponent(shot.file),
                                             width: shot.w, height: shot.h,
                                             into: &pixels, colorSpace: sRGB)
                else { return false }
                // Listed but unreadable depth: skip the shot. Without the occlusion test it
                // would paint surfaces behind walls.
                let depth = loadDepth(shot, dir: shotsDir)
                if shot.depth != nil, depth == nil { return false }
                return project(shot: shot, inverse: inv, camera: camera, image: image,
                               pixels: pixels, depth: depth, geo: geo, count: n,
                               bestW: &bestW, bestC: &bestC)
            }
            if used { stats.shotsUsed += 1 }
        }

        // Blend.
        var rgb = [Float](repeating: Float(grey), count: n * 3)
        var have = [Bool](repeating: false, count: n)
        var direct = 0
        for i in 0..<n {
            let w0 = bestW[i * 3], w1 = bestW[i * 3 + 1], w2 = bestW[i * 3 + 2]
            let total = w0 + w1 + w2
            guard total > 0 else { continue }
            var acc = SIMD3<Float>(0, 0, 0)
            for k in 0..<3 {
                let c = bestC[i * 3 + k]
                let red = Float(c & 0xFF)
                let green = Float((c >> 8) & 0xFF)
                let blue = Float((c >> 16) & 0xFF)
                acc += bestW[i * 3 + k] * SIMD3<Float>(red, green, blue)
            }
            acc /= total
            rgb[i * 3] = acc.x
            rgb[i * 3 + 1] = acc.y
            rgb[i * 3 + 2] = acc.z
            have[i] = true
            direct += 1
        }
        bestW = []
        bestC = []
        pixels = []
        stats.direct = Double(direct) / Double(max(n, 1))
        guard stats.direct >= minDirectFraction else { return finish("sparse") }

        // Edge diffusion (sim: both directions of every triangle edge, duplicates included).
        var filledCount = direct
        var acc = [Float](repeating: 0, count: n * 3)
        var cnt = [Float](repeating: 0, count: n)
        func spread(_ src: Int, _ dst: Int) {
            acc[dst * 3] += rgb[src * 3]
            acc[dst * 3 + 1] += rgb[src * 3 + 1]
            acc[dst * 3 + 2] += rgb[src * 3 + 2]
            cnt[dst] += 1
        }
        mesh.indexData.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            let t = mesh.triangleCount
            for _ in 0..<fillPasses {
                if isCancelled() || elapsed() > budgetSeconds { return }
                var added = false
                for tri in 0..<t {
                    let o = tri * 12
                    let a = Int(base.loadUnaligned(fromByteOffset: o, as: UInt32.self))
                    let b = Int(base.loadUnaligned(fromByteOffset: o + 4, as: UInt32.self))
                    let c = Int(base.loadUnaligned(fromByteOffset: o + 8, as: UInt32.self))
                    // Indices were range-checked by `readSync`. Unrolled: an array of pairs
                    // here would allocate per triangle per pass.
                    let ha = have[a], hb = have[b], hc = have[c]
                    if ha != hb || hb != hc {
                        if ha && !hb { spread(a, b) }
                        if hb && !ha { spread(b, a) }
                        if hb && !hc { spread(b, c) }
                        if hc && !hb { spread(c, b) }
                        if hc && !ha { spread(c, a) }
                        if ha && !hc { spread(a, c) }
                        added = true
                    }
                }
                guard added else { return }
                for i in 0..<n where cnt[i] > 0 {
                    rgb[i * 3] = acc[i * 3] / cnt[i]
                    rgb[i * 3 + 1] = acc[i * 3 + 1] / cnt[i]
                    rgb[i * 3 + 2] = acc[i * 3 + 2] / cnt[i]
                    acc[i * 3] = 0
                    acc[i * 3 + 1] = 0
                    acc[i * 3 + 2] = 0
                    cnt[i] = 0
                    have[i] = true
                    filledCount += 1
                }
            }
        }
        if isCancelled() { return finish("cancelled") }
        if elapsed() > budgetSeconds { return finish("timeout") }
        stats.filled = Double(filledCount) / Double(max(n, 1))

        var colors = [UInt8](repeating: 255, count: n * 4)
        for i in 0..<n {
            colors[i * 4] = UInt8(max(0, min(255, rgb[i * 3].rounded())))
            colors[i * 4 + 1] = UInt8(max(0, min(255, rgb[i * 3 + 1].rounded())))
            colors[i * 4 + 2] = UInt8(max(0, min(255, rgb[i * 3 + 2].rounded())))
        }
        let out = previewURL.deletingLastPathComponent().appendingPathComponent(MeshPreviewColors.fileName)
        do {
            try MeshPreviewColors.write(colors, vertexCount: n, to: out)
        } catch {
            try? FileManager.default.removeItem(at: out)
            return finish("writeFailed")
        }
        return finish("done")
    }

    // MARK: - Inputs

    private struct Mesh {
        let vertexCount: Int
        let triangleCount: Int
        /// Positions + unit normals, packed xyz xyz (6 floats per vertex).
        let geo: [Float]
        let indexData: Data
    }

    /// Reads the preview and keeps only what colouring needs: the ~5 MB file bytes die here.
    private static func loadMesh(_ url: URL) -> Mesh? {
        guard let decoded = try? MeshPreviewFile.readSync(url) else { return nil }
        let n = decoded.vertexCount
        var geo = [Float](repeating: 0, count: n * 6)
        decoded.raw.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            for i in 0..<n {
                let p = decoded.positionOffset + i * 12
                let q = decoded.normalOffset + i * 12
                var nx = base.loadUnaligned(fromByteOffset: q, as: Float.self)
                var ny = base.loadUnaligned(fromByteOffset: q + 4, as: Float.self)
                var nz = base.loadUnaligned(fromByteOffset: q + 8, as: Float.self)
                let len = (nx * nx + ny * ny + nz * nz).squareRoot()
                if len > 1e-12, len.isFinite {
                    nx /= len
                    ny /= len
                    nz /= len
                } else {
                    // Defensive only (the writers put (0, 1, 0) for a degenerate normal): a
                    // zero normal never passes the facing test.
                    nx = 0
                    ny = 0
                    nz = 0
                }
                geo[i * 6] = base.loadUnaligned(fromByteOffset: p, as: Float.self)
                geo[i * 6 + 1] = base.loadUnaligned(fromByteOffset: p + 4, as: Float.self)
                geo[i * 6 + 2] = base.loadUnaligned(fromByteOffset: p + 8, as: Float.self)
                geo[i * 6 + 3] = nx
                geo[i * 6 + 4] = ny
                geo[i * 6 + 5] = nz
            }
        }
        return Mesh(vertexCount: n, triangleCount: decoded.triangleCount, geo: geo,
                    indexData: decoded.indexData)
    }

    // MARK: - One shot

    /// Size of the decoded thumbnail in `pixels`.
    private struct Thumb {
        let width: Int
        let height: Int
    }

    /// Decoded at 1/2, 1/4… size IN the JPEG decoder (`kCGImageSourceSubsampleFactor`; 1440 ⇒
    /// 720 px, ~2 ms), the smallest factor that fits `maxImageSide`. Sensor orientation kept
    /// (no EXIF orientation; intrinsics match stored pixels). Drawn into `pixels` as sRGB
    /// RGBA8, row 0 = top.
    private static func decodeShot(_ url: URL, width: Int, height: Int, into pixels: inout [UInt8],
                                   colorSpace: CGColorSpace) -> Thumb? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var factor = 1
        while max(width, height) / factor > maxImageSide, factor < 8 {
            factor *= 2
        }
        let options: [CFString: Any] = [
            kCGImageSourceSubsampleFactor: factor,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let w = image.width
        let h = image.height
        guard w > 3, h > 3, w <= maxImageSide, h <= maxImageSide else { return nil }
        let drawn: Bool = pixels.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) in
            guard let base = buf.baseAddress,
                  let context = CGContext(
                    data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                  )
            else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? Thumb(width: w, height: h) : nil
    }

    /// The shot's LiDAR depth (raw DEFLATE Float32, `TextureShotRecorder`). nil = no occlusion
    /// test for this shot (as the sim).
    private static func loadDepth(_ shot: Shot, dir: URL) -> (values: [Float], w: Int, h: Int)? {
        guard let name = shot.depth, let dw = shot.dw, let dh = shot.dh, dw > 0, dh > 0,
              dw <= 1024, dh <= 1024,
              let packed = try? Data(contentsOf: dir.appendingPathComponent(name)),
              let raw = try? (packed as NSData).decompressed(using: .zlib) as Data,
              raw.count == dw * dh * 4
        else { return nil }
        var values = [Float](repeating: 0, count: dw * dh)
        raw.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            for i in 0..<(dw * dh) {
                values[i] = base.loadUnaligned(fromByteOffset: i * 4, as: Float.self)
            }
        }
        return (values, dw, dh)
    }

    /// Every vertex against one shot. Returns whether any vertex took a colour from it.
    /// Hot loop (vertices × shots, ~20–100M): per-shot constants hoisted, raw buffer pointers,
    /// no allocation inside.
    private static func project(
        shot: Shot, inverse inv: simd_float4x4, camera: SIMD3<Float>, image: Thumb,
        pixels: [UInt8], depth: (values: [Float], w: Int, h: Int)?, geo: [Float], count n: Int,
        bestW: inout [Float], bestC: inout [UInt32]
    ) -> Bool {
        let w = Float(shot.w)
        let h = Float(shot.h)
        let fx = shot.fx
        let fy = shot.fy
        let cx = shot.cx
        let cy = shot.cy
        // Stored-pixel coords → thumbnail coords (pixel centres: +0.5 / −0.5).
        let sx = Float(image.width) / w
        let sy = Float(image.height) / h
        let iw = image.width
        let ih = image.height
        let maxTu = Float(iw) - 1.001
        let maxTv = Float(ih) - 1.001
        let depthValues = depth?.values ?? []
        let dw = depth?.w ?? 0
        let dh = depth?.h ?? 0
        let hasDepth = dw > 0 && dh > 0 && depthValues.count == dw * dh
        let duScale = Float(dw) / w
        let dvScale = Float(dh) / h
        var any = false
        pixels.withUnsafeBufferPointer { px in
            geo.withUnsafeBufferPointer { g in
                depthValues.withUnsafeBufferPointer { dm in
                    bestW.withUnsafeMutableBufferPointer { bw in
                        bestC.withUnsafeMutableBufferPointer { bc in
                            for i in 0..<n {
                                let p = SIMD4<Float>(g[i * 6], g[i * 6 + 1], g[i * 6 + 2], 1)
                                let q = inv * p
                                guard q.z < -0.05 else { continue }
                                let z = -q.z
                                guard z < 6 else { continue }
                                let u = fx * q.x / z + cx
                                let v = fy * (-q.y) / z + cy
                                guard u >= 1, u < w - 2, v >= 1, v < h - 2 else { continue }
                                if hasDepth {
                                    let du = min(max(Int(u * duScale), 0), dw - 1)
                                    let dv = min(max(Int(v * dvScale), 0), dh - 1)
                                    let d = dm[dv * dw + du]
                                    guard d.isFinite, abs(d - z) < max(0.12, 0.06 * z) else { continue }
                                }
                                let view = camera - SIMD3<Float>(p.x, p.y, p.z)
                                let dist = simd_length(view)
                                guard dist > 1e-6 else { continue }
                                let normal = SIMD3<Float>(g[i * 6 + 3], g[i * 6 + 4], g[i * 6 + 5])
                                let cosine = simd_dot(normal, view) / dist
                                guard cosine > 0.2 else { continue }
                                let reach = max(dist, 0.6)
                                let weight = cosine * cosine / (reach * reach)
                                let b = i * 3
                                guard weight > bw[b + 2] else { continue }

                                // Bilinear sample in the thumbnail, four taps unrolled.
                                let tu = min(max((u + 0.5) * sx - 0.5, 0), maxTu)
                                let tv = min(max((v + 0.5) * sy - 0.5, 0), maxTv)
                                let x0 = Int(tu)
                                let y0 = Int(tv)
                                let x1 = min(x0 + 1, iw - 1)
                                let y1 = min(y0 + 1, ih - 1)
                                let ax = tu - Float(x0)
                                let ay = tv - Float(y0)
                                let o00 = (y0 * iw + x0) * 4
                                let o10 = (y0 * iw + x1) * 4
                                let o01 = (y1 * iw + x0) * 4
                                let o11 = (y1 * iw + x1) * 4
                                let c00 = SIMD3<Float>(Float(px[o00]), Float(px[o00 + 1]), Float(px[o00 + 2]))
                                let c10 = SIMD3<Float>(Float(px[o10]), Float(px[o10 + 1]), Float(px[o10 + 2]))
                                let c01 = SIMD3<Float>(Float(px[o01]), Float(px[o01 + 1]), Float(px[o01 + 2]))
                                let c11 = SIMD3<Float>(Float(px[o11]), Float(px[o11 + 1]), Float(px[o11 + 2]))
                                let upper = c00 * (1 - ax) + c10 * ax
                                let lower = c01 * (1 - ax) + c11 * ax
                                let rgb = upper * (1 - ay) + lower * ay
                                let red = UInt32(min(max(rgb.x.rounded(), 0), 255))
                                let green = UInt32(min(max(rgb.y.rounded(), 0), 255))
                                let blue = UInt32(min(max(rgb.z.rounded(), 0), 255))
                                let packed = red | (green << 8) | (blue << 16)

                                // Insert into the sorted top-3.
                                if weight > bw[b] {
                                    bw[b + 2] = bw[b + 1]
                                    bc[b + 2] = bc[b + 1]
                                    bw[b + 1] = bw[b]
                                    bc[b + 1] = bc[b]
                                    bw[b] = weight
                                    bc[b] = packed
                                } else if weight > bw[b + 1] {
                                    bw[b + 2] = bw[b + 1]
                                    bc[b + 2] = bc[b + 1]
                                    bw[b + 1] = weight
                                    bc[b + 1] = packed
                                } else {
                                    bw[b + 2] = weight
                                    bc[b + 2] = packed
                                }
                                any = true
                            }
                        }
                    }
                }
            }
        }
        return any
    }

    private static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
