// Checks Sources/Scan/MeshRescue.swift on synthetic walls (CI, build.yml "Mesh rescue check"):
//   swiftc -O Sources/Scan/MeshRescue.swift tools/mesh-rescue-check/main.swift -o mrc && ./mrc
import Foundation
import simd

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "ok    \(what)" : "FAIL  \(what)")
    if !ok { failures += 1 }
}

func translation(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
    var m = matrix_identity_float4x4
    m.columns.3 = SIMD4(x, y, z, 1)
    return m
}

func rotationY(_ degrees: Float) -> simd_float4x4 {
    simd_float4x4(simd_quatf(angle: degrees * .pi / 180, axis: SIMD3(0, 1, 0)))
}

/// Grid wall in the plane x = `x`, y 0…`height`, z `z0`…`z1`, spacing `step`, two triangles per cell.
func wall(x: Float, z0: Float, z1: Float, height: Float = 2.5, step: Float = 0.04)
    -> (vertices: [SIMD3<Float>], normals: [SIMD3<Float>], faces: [MeshRescue.Face]) {
    let ny = Int((height / step).rounded()) + 1
    let nz = Int(((z1 - z0) / step).rounded()) + 1
    var v: [SIMD3<Float>] = []
    for iy in 0..<ny {
        for iz in 0..<nz {
            v.append(SIMD3(x, Float(iy) * step, z0 + Float(iz) * step))
        }
    }
    var f: [MeshRescue.Face] = []
    for iy in 0..<(ny - 1) {
        for iz in 0..<(nz - 1) {
            let a = UInt32(iy * nz + iz), b = a + 1, c = a + UInt32(nz), d = c + 1
            f.append((a, b, c))
            f.append((b, d, c))
        }
    }
    return (v, Array(repeating: SIMD3<Float>(1, 0, 0), count: v.count), f)
}

func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tol: Float = 1e-4) -> Bool { simd_distance(a, b) < tol }

// --- correction: nearest shot in time, within distance and gap; rigid move of that shot
let firstA = translation(0, 0, 0)
let firstB = translation(5, 0, 0)
let moveB = translation(0.02, 0.02, -0.26) * rotationY(3)
let shots = [
    MeshRescue.Shot(seenAt: 100, first: firstA, now: firstA),
    MeshRescue.Shot(seenAt: 200, first: firstB, now: moveB * firstB),
]
let center = SIMD3<Float>(6, 1, 0)
if let m = MeshRescue.correction(builtAt: 201, center: center, shots: shots) {
    check(near(MeshRescue.apply(m, center), MeshRescue.apply(moveB, center)), "correction = the nearest shot's move")
    check(MeshRescue.shift(m, at: center) > MeshRescue.minShift, "corrected piece passes the min shift")
} else {
    check(false, "correction found for a piece next to a shot")
}
check(MeshRescue.correction(builtAt: 150, center: center, shots: shots) == nil, "no shot within the time gap = nil")
check(MeshRescue.correction(builtAt: 201, center: SIMD3(30, 0, 0), shots: shots) == nil, "no shot within the distance = nil")
if let still = MeshRescue.correction(builtAt: 99, center: SIMD3(0, 1, 1), shots: shots) {
    check(MeshRescue.shift(still, at: SIMD3(0, 1, 1)) < MeshRescue.minShift, "uncorrected sub-map stays under the min shift")
} else {
    check(false, "correction found for a piece next to an unmoved shot")
}

// --- coverage: live wall at x = 0, z 0…4 (and one at negative coordinates)
let live = wall(x: 0, z0: 0, z1: 4)
let liveNeg = wall(x: -5, z0: -4, z1: -1)
let cells = MeshRescue.cells([live.vertices, liveNeg.vertices], stride: 2)
check(MeshRescue.covered(SIMD3(0.05, 1, 1), cells), "point 5 cm from live mesh is covered")
check(!MeshRescue.covered(SIMD3(0.35, 1, 1), cells), "point 35 cm from live mesh is not covered")
check(MeshRescue.covered(SIMD3(-5.03, 1, -2), cells), "negative coordinates are covered")
check(!MeshRescue.covered(SIMD3(-5.4, 1, -2), cells), "negative coordinates 40 cm away are not covered")

let shiftedWall = wall(x: 0.30, z0: 0, z1: 4)
check(MeshRescue.coveredShare(shiftedWall.vertices, translation(-0.30, 0, 0), cells, stride: 8) >= MeshRescue.coveredToDrop,
      "a replaced chunk (same wall once corrected) counts as covered")
check(MeshRescue.coveredShare(shiftedWall.vertices, matrix_identity_float4x4, cells, stride: 8) < 0.1,
      "the same wall 30 cm away is not covered")

// --- place: cut what live mesh covers, keep the rest, move rigidly, compact
let onLive = wall(x: 0.04, z0: 1, z1: 3)
check(MeshRescue.place(vertices: onLive.vertices, normals: onLive.normals, faces: onLive.faces,
                       m: matrix_identity_float4x4, cells: cells, minFaces: 20) == nil,
      "a piece lying on live mesh is cut away entirely")

let away = wall(x: 3, z0: 0, z1: 2)
let turn = translation(0.1, 0, -0.2) * rotationY(90)
if let p = MeshRescue.place(vertices: away.vertices, normals: away.normals, faces: away.faces,
                            m: turn, cells: cells, minFaces: 20) {
    check(p.faces.count == away.faces.count && p.vertices.count == away.vertices.count, "a piece in empty space is kept whole")
    check(near(p.vertices[0], MeshRescue.apply(turn, away.vertices[0])), "kept vertices are moved by the correction")
    check(near(p.normals[0], SIMD3(0, 0, -1)), "normals are rotated, not translated")
} else {
    check(false, "a piece in empty space is kept")
}

let half = wall(x: 0.02, z0: 3, z1: 6)
if let p = MeshRescue.place(vertices: half.vertices, normals: half.normals, faces: half.faces,
                            m: matrix_identity_float4x4, cells: cells, minFaces: 20) {
    check(p.faces.count > 0 && p.faces.count < half.faces.count, "a half-covered piece keeps only its uncovered part")
    var used = Array(repeating: false, count: p.vertices.count)
    var badFace = false
    for (a, b, c) in p.faces {
        for i in [a, b, c] {
            guard Int(i) < p.vertices.count else { badFace = true; continue }
            used[Int(i)] = true
        }
        var corners = 0
        for i in [a, b, c] where Int(i) < p.vertices.count && MeshRescue.covered(p.vertices[Int(i)], cells) { corners += 1 }
        if corners >= 2 { badFace = true }
    }
    check(!badFace, "no kept face has 2+ covered corners; indices in range")
    check(!used.contains(false), "no unused vertex left after compaction")
    check(p.vertices.allSatisfy { $0.z > 3.9 }, "kept part lies beyond the live wall's end")
} else {
    check(false, "a half-covered piece is kept in part")
}

print(failures == 0 ? "mesh rescue check: all passed" : "mesh rescue check: \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
