# Parse model.obj once (numpy) and cache V (float64 as written, 4 decimals) + F (int32) to .npz.
# Also recover the ARKit anchor PIECES: buildPLY appends piece by piece (sorted UUID), so a piece
# is a contiguous vertex range and its faces are a contiguous face range that never reference
# another piece's vertices. Split points = vertex positions no face spans across.
import sys, time
import numpy as np

def load_obj(path):
    t = time.time()
    data = open(path, "rb").read()
    lines = data.split(b"\n")
    vl = [l[2:] for l in lines if l.startswith(b"v ")]
    fl = [l[2:] for l in lines if l.startswith(b"f ")]
    V = np.array(b" ".join(vl).split(), dtype=np.float64).reshape(len(vl), -1)[:, :3]
    F = np.array(b" ".join(fl).split(), dtype=np.int64).reshape(len(fl), 3) - 1
    print(f"loaded {path}: {len(V)} v, {len(F)} f in {time.time()-t:.1f}s", flush=True)
    return V, F

for tag in sys.argv[1:]:
    V, F = load_obj(f"{tag}-model.obj")
    bad = (F < 0).any(1) | (F >= len(V)).any(1)
    print("bad faces", int(bad.sum()))
    F = F[~bad]
    fmin, fmax = F.min(1), F.max(1)
    # coverage: a vertex boundary b (between b-1 and b) is spanned if some face has fmin < b <= fmax
    diff = np.zeros(len(V) + 1, np.int64)
    np.add.at(diff, fmin + 1, 1)
    np.add.at(diff, fmax + 1, -1)
    span = np.cumsum(diff)[:len(V)]  # span[b] > 0 => boundary before vertex b is inside some face range
    starts = np.flatnonzero(span == 0)  # includes 0
    print("pieces (upper bound)", len(starts))
    np.savez(f"{tag}-mesh.npz", V=V, F=F.astype(np.int32), piece_starts=starts.astype(np.int64))
