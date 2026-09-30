# Line-by-line mirror of Sources/Scan/PreviewSimplifier.swift — KEEP THE TWO IN STEP.
# Input = a fast-save model.obj (== ColorMeshBuilder.pieces in sorted-key order, coordinates on the 0.1 mm
# grid the OBJ writer uses), cached by load_cache.py. Same meshoptimizer calls in the same order: the weld and
# stage A get the same input bytes as in the app; stage B starts from a slightly different mesh on the phone
# (the iPhone build fuses multiply-adds, this DLL does not).
# Usage (in the data folder): python <this dir>/mirror2.py TAG NAME [budget=120000]
#   -> TAG-NAME.ply (Blender axes, for render.py), TAG-NAME.json (stats), TAG-NAME-normals.npy (app normals)
import sys, json, time, math, ctypes
import numpy as np
from ctypes import c_float
from meshopt_ctypes import lib, ptr, Sparse, FLT_MAX

BUDGET = 120_000
GRID = 10_000.0          # gridPerMetre
MAX_COORD = 500.0        # maxCoordinate
CELL = 4.0               # cellSize
FIRST_VT = 0.7           # firstVertexPerTriangle
STAGE_A_SLACK = 2.0      # stageASlack
MAX_PASSES = 3           # maxPasses
MAX_STAGE_VERTS = 600_000  # maxStageVertices


def simplify(pos, idx, target_idx, options, lock=None):
    dest = np.empty(len(idx), np.uint32)
    err = c_float(0)
    if lock is None:
        n = lib.meshopt_simplify(ptr(dest), ptr(idx), len(idx), ptr(pos), len(pos), 12, int(target_idx), FLT_MAX, options, ctypes.byref(err))
    else:
        n = lib.meshopt_simplifyWithAttributes(ptr(dest), ptr(idx), len(idx), ptr(pos), len(pos), 12,
                                               None, 0, None, 0, ptr(lock), int(target_idx), FLT_MAX, options, ctypes.byref(err))
    return dest[:n].copy(), float(err.value)


def compact(pos, idx):
    # = PreviewSimplifier.compact: meshopt_optimizeVertexFetchRemap, first-use order
    remap = np.empty(len(pos), np.uint32)
    u = lib.meshopt_optimizeVertexFetchRemap(ptr(remap), ptr(idx), len(idx), len(pos))
    out = np.empty((u, 3), np.float32)
    used = remap != 0xFFFFFFFF
    out[remap[used]] = pos[used]
    return out, np.ascontiguousarray(remap[idx].astype(np.uint32))


def build(V64, F, budget=BUDGET, stats=None):
    st = {} if stats is None else stats
    t0 = time.perf_counter()
    # 1. quantise on the OBJ grid, invalid vertices -> one sentinel point, weld identical grid points.
    # Swift `.rounded()` = half away from zero (np.round is half to even; ties only matter on raw floats)
    x = V64 * GRID
    xt = np.trunc(x)
    k = xt + np.where(np.abs(x - xt) >= 0.5, np.sign(x), 0.0)
    valid = np.all(np.abs(V64) <= MAX_COORD, axis=1)
    k[~valid] = -2147483648
    k = np.ascontiguousarray(k.astype(np.int32))
    n = len(k)
    remap = np.empty(n, np.uint32)
    lib.shim_reset_peak()
    u = lib.meshopt_generateVertexRemap(ptr(remap), None, n, ptr(k), n, 12)
    st["weld_peak_MB"] = round(lib.shim_peak() / 1e6, 1)
    pos = np.empty((u, 3), np.float32)
    pos[remap] = (k.astype(np.float64) / GRID).astype(np.float32)
    # 3. faces: welded, degenerate + invalid dropped, piece order kept
    fv = valid[F].all(1)
    R = remap[F[fv]]
    keep = (R[:, 0] != R[:, 1]) & (R[:, 1] != R[:, 2]) & (R[:, 0] != R[:, 2])
    tri = R[keep]
    total_tris = len(tri)
    st.update({"in_verts": int(n), "welded_verts": int(u), "tris": int(total_tris), "dropped_faces": int(len(F) - total_tris)})
    if total_tris == 0:
        return None
    first_target = min(total_tris, int(budget / FIRST_VT))
    used = np.zeros(u, bool)
    used[tri.ravel()] = True
    if int(used.sum()) <= budget:
        st["path"] = "as-is"
        return compact(pos, np.ascontiguousarray(tri.ravel()))
    t1 = time.perf_counter()
    if total_tris > int(first_target * STAGE_A_SLACK):
        # 2. + 4. stage A: 4 m cell of each welded vertex, block ids in first-seen vertex order; a face belongs
        # to the cell of its FIRST corner; vertices used by faces of two cells are locked.
        c = np.floor(pos / np.float32(CELL)).astype(np.int64)
        key = (c[:, 0] + (1 << 20)) * (1 << 42) + (c[:, 1] + (1 << 20)) * (1 << 21) + (c[:, 2] + (1 << 20))
        uk, first_idx, inv = np.unique(key, return_index=True, return_inverse=True)
        rank = np.empty(len(uk), np.int64)
        rank[np.argsort(first_idx, kind="stable")] = np.arange(len(uk))
        vblock = rank[inv]
        fblock = vblock[tri[:, 0]]
        flat_v = tri.ravel()
        flat_b = np.repeat(fblock, 3)
        vb_first = np.full(u, -1, np.int64)
        vb_first[flat_v[::-1]] = flat_b[::-1]   # any owner choice gives the same lock set
        lock = np.zeros(u, np.uint8)
        lock[flat_v[flat_b != vb_first[flat_v]]] = 1
        order = np.argsort(fblock, kind="stable")
        counts = np.bincount(fblock, minlength=len(uk))
        starts = np.r_[0, np.cumsum(counts)]
        sorted_idx = np.ascontiguousarray(tri[order].ravel())
        ratio = min(1.0, STAGE_A_SLACK * first_target / total_tris)
        parts = []
        peakA = 0
        for b in range(len(uk)):
            cnt = int(counts[b])
            if cnt == 0:
                continue
            sub = sorted_idx[starts[b] * 3:(starts[b] + cnt) * 3]
            lib.shim_reset_peak()
            out, _ = simplify(pos, sub, int(cnt * ratio) * 3, Sparse, lock)
            peakA = max(peakA, lib.shim_peak())
            parts.append(out)
        st.update({"blocks": int(len(uk)), "max_block_tris": int(counts.max()), "locked": int(lock.sum()), "peakA_MB": round(peakA / 1e6, 1)})
        spos, sidx = compact(pos, np.concatenate(parts))
    else:
        spos, sidx = compact(pos, np.ascontiguousarray(tri.ravel()))
    st["stageA_s"] = round(time.perf_counter() - t1, 3)
    st["stage_verts"] = int(len(spos))
    st["stage_tris"] = int(len(sidx) // 3)
    # 5. stage B: whole mesh, target moved until the vertex count lands in [0.9, 1] x budget
    t2 = time.perf_counter()
    stage_tris = len(sidx) // 3
    if stage_tris == 0 or len(spos) > MAX_STAGE_VERTS:
        st["path"] = "stage-B valve -> nil"
        return None
    target = min(stage_tris, first_target)
    best = None
    passes = []
    peakB = 0
    for p in range(MAX_PASSES):
        lib.shim_reset_peak()
        out, err = simplify(spos, sidx, target * 3, 0)
        peakB = max(peakB, lib.shim_peak())
        if len(out) == 0 or len(out) % 3:
            # Swift: a failed later pass keeps the earlier result, a failed first pass returns nil
            if best is not None:
                break
            return None
        cpos, cidx = compact(spos, out)
        v, t = len(cpos), len(cidx) // 3
        passes.append({"target": int(target), "verts": int(v), "tris": int(t)})
        better = best is None
        if not better:
            bv = best[0]
            better = (v <= budget and (bv > budget or v > bv)) or (v > budget and bv > budget and v < bv)
        if better:
            best = (v, cpos, cidx)
        if v <= budget and (v * 10 >= budget * 9 or target >= stage_tris):
            break
        r = budget / v
        target = max(1, min(stage_tris, int(t * min(1.3, r * math.sqrt(math.sqrt(r))) * 0.99)))
    st.update({"passes": passes, "stageB_s": round(time.perf_counter() - t2, 3), "peakB_MB": round(peakB / 1e6, 1),
               "total_s": round(time.perf_counter() - t0, 3), "path": "quadric"})
    return best[1], best[2]


def app_normals(pos, idx):
    # = PreviewSimplifier.finish: area-weighted face normals, zero -> (0, 1, 0)
    t = idx.reshape(-1, 3).astype(np.int64)
    a, b, c = pos[t[:, 0]], pos[t[:, 1]], pos[t[:, 2]]
    fn = np.cross(b - a, c - a)
    N = np.zeros_like(pos)
    for k in range(3):
        np.add.at(N, t[:, k], fn)
    ln = np.linalg.norm(N, axis=1)
    ok = ln > 1e-12
    N[ok] /= ln[ok, None]
    N[~ok] = (0, 1, 0)
    return N


if __name__ == "__main__":
    from preview_repro import write_ply
    tag, name = sys.argv[1], sys.argv[2]
    kw = dict(a.split("=") for a in sys.argv[3:])
    d = np.load(f"{tag}-mesh.npz")
    st = {"tag": tag, "name": name}
    budget = int(kw.get("budget", BUDGET))
    built = build(d["V"], d["F"], budget=budget, stats=st)
    if built is None:
        import os
        for stale in (f"{tag}-{name}.ply", f"{tag}-{name}.json", f"{tag}-{name}-normals.npy"):
            if os.path.exists(stale):
                os.remove(stale)  # an older run's output must not be rendered as this one
        sys.exit(f"{tag}: nil -> the app would use the clustering fallback. {json.dumps(st)}")
    cpos, cidx = built
    st.update({"out_verts": int(len(cpos)), "out_tris": int(len(cidx) // 3),
               "file_MB": round((40 + len(cpos) * 24 + len(cidx) * 4) / 1e6, 2),
               # ColorMeshBuilder.previewQuadricCeiling (vertices, and 2x as many triangles): above it the app
               # ships the clustering fallback
               "over_ceiling_app_uses_fallback": bool(len(cpos) > budget * 5 // 4 or len(cidx) > budget * 5 // 4 * 6)})
    print(json.dumps(st), flush=True)
    write_ply(f"{tag}-{name}.ply", cpos, cidx.reshape(-1, 3))
    np.save(f"{tag}-{name}-normals.npy", app_normals(cpos, cidx).astype(np.float32))
    json.dump(st, open(f"{tag}-{name}.json", "w"), indent=1)
