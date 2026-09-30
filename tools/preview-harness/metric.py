# Extra see-through area of candidate meshes vs the full mesh, as in the 30/09 diagnosis:
# silhouette S = raw two-sided render > 23/255; see-through(X) = S & culled render of X <= 23;
# extra = % of S see-through for X minus the same % for the raw culled render.
# Usage: python metric.py TAG name [name...]   (renders r-TAG-VIEW-name-cull.png must exist)
import sys, json
import numpy as np
from PIL import Image

VIEWS = ["persp0", "persp90", "persp180", "persp270", "top0"]

def gray(path):
    return np.asarray(Image.open(path).convert("L"), dtype=np.int16)

def seethrough(tag, view, name):
    S = gray(f"r-{tag}-{view}-raw-2side.png") > 23
    X = gray(f"r-{tag}-{view}-{name}-cull.png") <= 23
    return 100.0 * (S & X).sum() / S.sum()

tag, names = sys.argv[1], sys.argv[2:]
out = {}
for name in ["raw"] + names:
    out[name] = {v: seethrough(tag, v, name) for v in VIEWS}
res = {}
for name in names:
    ex = {v: out[name][v] - out["raw"][v] for v in VIEWS}
    res[name] = {"top": round(ex["top0"], 2), "persp_mean": round(float(np.mean([ex[v] for v in VIEWS[:4]])), 2),
                 "persp": [round(ex[v], 2) for v in VIEWS[:4]]}
res["raw_seethrough"] = {"top": round(out["raw"]["top0"], 2),
                         "persp_mean": round(float(np.mean([out["raw"][v] for v in VIEWS[:4]])), 2)}
print(tag, json.dumps(res))
