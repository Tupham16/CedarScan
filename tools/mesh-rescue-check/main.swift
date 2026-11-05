// Checks Sources/Scan/MeshRescue.swift on synthetic walls and shots (CI, build.yml "Mesh rescue check"):
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

/// Grid wall in the plane x = `x`, y 0…`height`, z `z0`…`z1`, spacing `step`, two triangles per cell,
/// facing +x (`facing` = 1) or -x (-1).
func wall(x: Float, z0: Float, z1: Float, facing: Float = 1, height: Float = 2.5, step: Float = 0.04) -> MeshRescue.Piece {
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
    return MeshRescue.Piece(vertices: v, normals: Array(repeating: SIMD3<Float>(facing, 0, 0), count: v.count), faces: f)
}

func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tol: Float = 1e-4) -> Bool { simd_distance(a, b) < tol }

func cells(_ pieces: [MeshRescue.Piece]) -> MeshRescue.Cells {
    var c = MeshRescue.Cells()
    for p in pieces { MeshRescue.add(p.vertices, p.normals, to: &c, stride: 2) }
    return c
}

let window = MeshRescue.Window.standard

// --- shots: A main map (never moves); B and B2 one sub-map merged at t = 400; C refined 6 cm; D moved 12 cm
let firstA = translation(5.5, 0, 0)
let firstB = translation(5, 0, 0)
let merge = translation(0.02, 0.02, -0.26) * rotationY(3)
let shotA = MeshRescue.Shot(seenAt: 249, pose: firstA)
var shotB = MeshRescue.Shot(seenAt: 299, pose: firstB)
shotB.update(translation(5.004, 0, 0), at: 350)              // < 1 cm: no history entry
check(shotB.poses.count == 1 && near(MeshRescue.position(shotB.now), SIMD3(5.004, 0, 0)), "sub-cm moves update now, not the history")
shotB.update(merge * firstB, at: 400)
check(shotB.poses.count == 2, "a merge adds a history entry")
check(near(MeshRescue.position(shotB.pose(at: 399)), MeshRescue.position(firstB)), "pose before the merge = capture pose")
check(near(MeshRescue.position(shotB.pose(at: 401)), MeshRescue.position(merge * firstB)), "pose after the merge = corrected pose")
var shotB2 = MeshRescue.Shot(seenAt: 398, pose: translation(5.2, 0, 0))
shotB2.update(merge * translation(5.2, 0, 0), at: 400)
let shotLate = MeshRescue.Shot(seenAt: 400.5, pose: merge * translation(5.1, 0, 0))   // first seen after the merge
var shotC = MeshRescue.Shot(seenAt: 499, pose: translation(-20, 0, 0))
shotC.update(translation(-20.06, 0, 0), at: 520)
var shotD = MeshRescue.Shot(seenAt: 699, pose: translation(40, 0, 0))
shotD.update(translation(40.12, 0, 0), at: 720)
let shots = [shotA, shotB, shotB2, shotLate, shotC, shotD]
let c = SIMD3<Float>(6, 1, 0)

// --- correction: only a piece built in the sub-map, removed with the merge, comes back
func corr(_ first: Double, _ last: Double, _ removed: Double, _ at: SIMD3<Float> = c) -> simd_float4x4? {
    MeshRescue.correction(builtFirst: first, builtLast: last, removedAt: removed, center: at, shots: shots, window: window)
}
if let m = corr(295, 300, 400.3) {
    check(near(MeshRescue.apply(m, c), MeshRescue.apply(merge, c)), "dropped at the merge: back by the sub-map's move")
} else {
    check(false, "dropped at the merge: qualifies")
}
check(corr(295, 300, 399) != nil, "removed up to 2 s before the merge still qualifies")
check(corr(295, 300, 395) == nil, "removed 5 s before the merge = ARKit's clean-up, not back")
check(corr(295, 300, 480) == nil, "removed long after the merge (kept, carved later) = not back")
check(corr(401, 402, 405) == nil, "built after the merge (already corrected) = not back")
check(corr(250, 300, 400.3) == nil, "built partly in the main map = not back")
check(corr(515, 518, 520.5, SIMD3(-21, 1, 0)) == nil, "a 6 cm refinement = not back")
check(corr(715, 718, 720.5, SIMD3(41, 1, 0)) == nil, "a 12 cm move inside the window = under the 15 cm minimum, not back")
check(corr(295, 300, 400.3, SIMD3(30, 0, 0)) == nil, "no shot within 8 m = not back")
check(corr(398.8, 399.9, 400.3) != nil, "updated just before the merge: an older shot is preferred over one seen after it")
if let s = MeshRescue.nearestShot(to: 399.9, center: c, shots: shots) {
    check(s.seenAt == 398, "nearestShot prefers a shot seen before the time")
}
let wide = MeshRescue.Window(before: 10, after: 40)
check(MeshRescue.correction(builtFirst: 295, builtLast: 300, removedAt: 370, center: c, shots: shots, window: wide) != nil,
      "a wider server window catches a removal 30 s before the merge")

// --- coverage with normals: live wall at x = 0 facing +x, z 0…4 (and one at negative coordinates)
let live = wall(x: 0, z0: 0, z1: 4)
let liveNeg = wall(x: -5, z0: -4, z1: -1)
let liveCells = cells([live, liveNeg])
let plusX = SIMD3<Float>(1, 0, 0)
check(MeshRescue.covered(SIMD3(0.05, 1, 1), plusX, liveCells), "5 cm from live mesh, same facing = covered")
check(!MeshRescue.covered(SIMD3(0.05, 1, 1), -plusX, liveCells), "a thin wall's other face is not covered")
check(!MeshRescue.covered(SIMD3(0.05, 1, 1), SIMD3(0, 1, 0), liveCells), "a floor next to a wall is not covered by it")
check(!MeshRescue.covered(SIMD3(0.35, 1, 1), plusX, liveCells), "35 cm from live mesh = not covered")
check(MeshRescue.covered(SIMD3(-5.03, 1, -2), plusX, liveCells), "negative coordinates are covered")
check(!MeshRescue.covered(SIMD3(-5.4, 1, -2), plusX, liveCells), "negative coordinates 40 cm away are not covered")
let shiftedWall = wall(x: 0.30, z0: 0, z1: 4)
check(MeshRescue.coveredShare(shiftedWall.vertices, shiftedWall.normals, translation(-0.30, 0, 0), liveCells, stride: 8) > 0.9,
      "the same wall once moved back counts as covered")
check(MeshRescue.coveredShare(shiftedWall.vertices, shiftedWall.normals, matrix_identity_float4x4, liveCells, stride: 8) < 0.1,
      "the same wall 30 cm away is not covered")

// --- place: keep only what live mesh covers neither where it sat nor where it goes
check(MeshRescue.place(wall(x: 0.04, z0: 1, z1: 3), m: matrix_identity_float4x4, cells: liveCells, minFaces: 20) == nil,
      "a piece lying on live mesh is cut away entirely")
let backFace = wall(x: -0.10, z0: 1, z1: 3, facing: -1)
check(MeshRescue.place(backFace, m: matrix_identity_float4x4, cells: liveCells, minFaces: 20)?.faces.count == backFace.faces.count,
      "the other face of a 10 cm wall is kept whole")
let away = wall(x: 3, z0: 0, z1: 2)
let turn = translation(0.1, 0, -0.2) * rotationY(90)
if let p = MeshRescue.place(away, m: turn, cells: liveCells, minFaces: 20) {
    check(p.faces.count == away.faces.count && p.vertices.count == away.vertices.count, "a piece in empty space is kept whole")
    check(near(p.vertices[0], MeshRescue.apply(turn, away.vertices[0])), "kept vertices are moved by the correction")
    check(near(p.normals[0], SIMD3(0, 0, -1)), "normals are rotated, not translated")
} else {
    check(false, "a piece in empty space is kept")
}
// Half of it still live where it sat (ARKit kept that part in place): only the emptied half moves.
let partly = wall(x: 0.02, z0: 2, z1: 6)
if let p = MeshRescue.place(partly, m: translation(3, 0, 0), cells: liveCells, minFaces: 20) {
    check(p.faces.count < partly.faces.count && p.vertices.allSatisfy { $0.z > 3.9 }, "only what ARKit emptied comes back")
    var badFace = false
    for (a, b, cc) in p.faces where Int(a) >= p.vertices.count || Int(b) >= p.vertices.count || Int(cc) >= p.vertices.count {
        badFace = true
    }
    var used = Array(repeating: false, count: p.vertices.count)
    for (a, b, cc) in p.faces where !badFace {
        used[Int(a)] = true
        used[Int(b)] = true
        used[Int(cc)] = true
    }
    check(!badFace && !used.contains(false), "indices in range, no unused vertex after compaction")
} else {
    check(false, "the emptied part of a half-live piece is kept")
}

// --- putBack: the Stop-time pass (walls of 64 x 201 = 12,864 vertices: two pass the 20k event minimum)
let roomLeft = 10_000_000
func job(_ p: MeshRescue.Piece, _ m: simd_float4x4) -> MeshRescue.Job {
    MeshRescue.Job(piece: p, m: m, shift: MeshRescue.shift(m, at: p.vertices[p.vertices.count / 2]))
}
let move = translation(0, 0, -0.3)
let liveBig = wall(x: 0, z0: 0, z1: 8)
let left = wall(x: 3, z0: 10, z1: 18)
let right = wall(x: 3, z0: 18, z1: 26)
check(left.vertices.count < MeshRescue.minEventVertices && left.vertices.count * 2 >= MeshRescue.minEventVertices,
      "test walls pass the event minimum together, not alone")
let side = MeshRescue.putBack([job(left, move), job(right, move)], live: [liveBig], room: roomLeft)
check(side.placed.count == 2 && side.placed.allSatisfy { $0.piece.faces.count == left.faces.count },
      "two neighbouring pieces are both put back whole (no crack at the seam)")
let dup = MeshRescue.putBack([job(left, move), job(left, move)], live: [liveBig], room: roomLeft)
check(dup.placed.count == 1 && dup.duplicate == left.vertices.count, "a second copy of a piece is dropped as a duplicate")
let replaced = MeshRescue.putBack([job(left, move), job(wall(x: 0.02, z0: 0, z1: 8), move)], live: [liveBig], room: roomLeft)
check(replaced.placed.count == 1 && replaced.inPlace == left.vertices.count, "a piece ARKit replaced in place is skipped")
let tiny = wall(x: 3, z0: 30, z1: 30.6, height: 0.6)
let small = MeshRescue.putBack([job(tiny, move)], live: [liveBig], room: roomLeft)
check(small.placed.isEmpty && small.smallEvent == tiny.vertices.count, "a few hundred vertices (carved noise) never come back")
let capped = MeshRescue.putBack([job(left, move), job(right, move)], live: [liveBig], room: left.vertices.count)
check(capped.placed.count == 1 && capped.capped == right.vertices.count, "the vertex cap keeps the first piece and counts the rest")

print(failures == 0 ? "mesh rescue check: all passed" : "mesh rescue check: \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
