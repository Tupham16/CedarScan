# Rebuild the 2.74 app's mesh-preview.bin (voxel clustering, ColorMeshBuilder.clusterPreview) from model.obj
# and write both meshes as binary PLY in Blender axes (z-up) for rendering. SPACING = 0.05 is the 2.74 guess;
# since 2.75 clustering is only the fallback (ColorMeshBuilder.clusterWithRetries) and guesses 0.03.
# fastSave scans: model.obj == builder `pieces` verbatim (report vertexCount == OBJ v count).
import sys, json, time
import numpy as np

BUDGET = 120_000
MIN_VOXEL = 0.03
SPACING = 0.05
MAX_PASSES = 4


def load_obj(path):
    t = time.time()
    with open(path, "rb") as f:
        data = f.read()
    lines = data.split(b"\n")
    vl = [l[2:] for l in lines if l.startswith(b"v ")]
    fl = [l[2:] for l in lines if l.startswith(b"f ")]
    V = np.array(b" ".join(vl).split(), dtype=np.float64).reshape(len(vl), -1)[:, :3]
    F = np.array(b" ".join(fl).split(), dtype=np.int64).reshape(len(fl), 3) - 1
    print(f"loaded {path}: {len(V)} v, {len(F)} f in {time.time()-t:.1f}s", flush=True)
    return V.astype(np.float32), F


def cluster(V, F, voxel):
    # Same maths as clusterPreview: exact cell key, centroid per cell, drop faces with 2 corners in one cell.
    inv = np.float32(1.0) / np.float32(voxel)
    c = np.floor(V * inv).astype(np.int64)
    key = ((c[:, 0] & 0x1FFFFF) << 42) | ((c[:, 1] & 0x1FFFFF) << 21) | (c[:, 2] & 0x1FFFFF)
    uniq, remap = np.unique(key, return_inverse=True)
    n = len(uniq)
    cnt = np.bincount(remap, minlength=n).astype(np.float64)
    P = np.stack([np.bincount(remap, weights=V[:, k].astype(np.float64), minlength=n) for k in range(3)], 1) / cnt[:, None]
    R = remap[F]
    keep = (R[:, 0] != R[:, 1]) & (R[:, 1] != R[:, 2]) & (R[:, 0] != R[:, 2])
    return P.astype(np.float32), R[keep], keep


def build_preview(V, F):
    total = len(V)
    voxel = MIN_VOXEL
    if total > BUDGET:
        voxel = max(MIN_VOXEL, SPACING * (total / BUDGET) ** 0.5)
    passes = []
    p = 0
    while True:
        P, FI, keep = cluster(V, F, voxel)
        p += 1
        passes.append({"voxel_m": round(float(voxel), 4), "verts": int(len(P)), "faces": int(len(FI))})
        if len(P) <= BUDGET or p >= MAX_PASSES:
            break
        over = len(P) / BUDGET
        voxel *= max(1.35, over ** 0.5)
    return P, FI, keep, voxel, passes


def face_normals(V, F):
    a, b, c = V[F[:, 0]], V[F[:, 1]], V[F[:, 2]]
    n = np.cross(b - a, c - a)
    area2 = np.linalg.norm(n, axis=1)
    return n, area2


def to_blender(V):
    # ARKit y-up -> Blender z-up: (x, y, z) -> (x, -z, y); proper rotation, winding kept.
    return np.stack([V[:, 0], -V[:, 2], V[:, 1]], 1).astype(np.float32)


def write_ply(path, V, F):
    V = to_blender(V)
    with open(path, "wb") as f:
        f.write(
            (
                "ply\nformat binary_little_endian 1.0\n"
                f"element vertex {len(V)}\nproperty float x\nproperty float y\nproperty float z\n"
                f"element face {len(F)}\nproperty list uchar int vertex_indices\nend_header\n"
            ).encode()
        )
        f.write(V.astype("<f4").tobytes())
        rec = np.zeros(len(F), dtype=[("n", "u1"), ("i", "<i4", (3,))])
        rec["n"] = 3
        rec["i"] = F.astype(np.int32)
        f.write(rec.tobytes())


def main(tag):
    V, F = load_obj(f"{tag}-model.obj")
    bad = (F < 0).any(1) | (F >= len(V)).any(1)
    F = F[~bad]
    P, FI, keep, voxel, passes = build_preview(V, F)

    # Winding flips: original face normal vs its clustered triangle's normal.
    n0, a0 = face_normals(V, F[keep])
    n1, a1 = face_normals(P, FI)
    dot = (n0 * n1).sum(1)
    flipped = dot < 0
    # Faces that exist with BOTH windings on the same 3 cells = welded two-sided sheet.
    s = np.sort(FI, axis=1)
    # canonical orientation sign: +1 if (FI) is an even permutation of sorted, else -1
    def parity(row_f, row_s):
        # rotate so that min comes first; even permutation iff second equals s[1]
        i = np.argmin(row_f, axis=1)
        second = row_f[np.arange(len(row_f)), (i + 1) % 3]
        return np.where(second == row_s[:, 1], 1, -1)
    par = parity(FI, s)
    key = s[:, 0].astype(np.int64) * (len(P) ** 2) + s[:, 1].astype(np.int64) * len(P) + s[:, 2].astype(np.int64)
    order = np.argsort(key, kind="stable")
    ks, ps = key[order], par[order]
    # group by key, check if both parities present
    starts = np.r_[0, np.flatnonzero(np.diff(ks)) + 1]
    has_pos = np.maximum.reduceat((ps > 0).astype(np.int8), starts)
    has_neg = np.maximum.reduceat((ps < 0).astype(np.int8), starts)
    both = (has_pos & has_neg).astype(bool)
    grp = np.repeat(np.arange(len(starts)), np.diff(np.r_[starts, len(ks)]))
    in_both = np.zeros(len(FI), bool)
    in_both[order] = both[grp]

    dropped_area = face_normals(V, F[~keep])[1].sum()
    stats = {
        "tag": tag,
        "raw_verts": int(len(V)),
        "raw_faces": int(len(F)),
        "raw_area_m2": round(float(face_normals(V, F)[1].sum() / 2), 1),
        "passes": passes,
        "final_voxel_m": round(float(voxel), 4),
        "preview_verts": int(len(P)),
        "preview_faces": int(len(FI)),
        "src_faces_dropped_degenerate_pct": round(100 * float((~keep).mean()), 1),
        "src_area_dropped_degenerate_pct": round(100 * float(dropped_area / face_normals(V, F)[1].sum()), 1),
        "preview_faces_flipped_pct": round(100 * float(flipped.mean()), 1),
        "preview_area_flipped_pct": round(100 * float(a1[flipped].sum() / a1.sum()), 1),
        "preview_faces_in_two_sided_sheets_pct": round(100 * float(in_both.mean()), 1),
    }
    print(json.dumps(stats, indent=1), flush=True)
    json.dump(stats, open(f"{tag}-stats.json", "w"), indent=1)
    write_ply(f"{tag}-raw.ply", V, F)
    write_ply(f"{tag}-preview.ply", P, FI)
    np.savez_compressed(f"{tag}-bounds.npz", lo=V.min(0), hi=V.max(0), plo=P.min(0), phi=P.max(0))


if __name__ == "__main__":
    for t in sys.argv[1:]:
        main(t)
