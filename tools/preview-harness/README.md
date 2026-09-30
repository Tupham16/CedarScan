# Grey 3D preview — offline harness

Measures `mesh-preview.bin` (the in-app grey 3D viewer) against the full scan mesh, with the SAME
meshoptimizer C++ the app ships (`Packages/MeshOptimizer`), called through ctypes.

- `mirror2.py` = `Sources/Scan/PreviewSimplifier.swift` step by step. **Keep the two in step**: change one,
  change the other, re-measure.
- `preview_repro.py` = the pre-2.75 clustering (`ColorMeshBuilder.clusterPreview`), today the fallback.

## Build meshopt.dll (Windows, no compiler installed)
`pip install ziglang` into a venv on a SHORT path (the wheel breaks on long paths: `subst Z: <dir>` first), then from this folder:

```
python -m ziglang c++ -shared -O2 -DNDEBUG -target x86_64-windows-gnu "-DMESHOPTIMIZER_API=__declspec(dllexport)" -I ../../Packages/MeshOptimizer/Sources/CMeshOptimizer/include ../../Packages/MeshOptimizer/Sources/CMeshOptimizer/simplifier.cpp ../../Packages/MeshOptimizer/Sources/CMeshOptimizer/allocator.cpp ../../Packages/MeshOptimizer/Sources/CMeshOptimizer/indexgenerator.cpp ../../Packages/MeshOptimizer/Sources/CMeshOptimizer/vfetchoptimizer.cpp memshim.cpp -o meshopt.dll
```

`memshim.cpp` counts the library's allocations (`peakA_MB` / `peakB_MB`). This DLL does not fuse
multiply-adds; the iPhone build does, so phone output differs in ~half the triangles. An FMA build
(`-mfma`) moved the hole numbers by <= 0.03 points.

## Run (in a data folder)
Input: fast-save scan zips (`model.obj` == the app's anchor pieces in sorted-key order). Extract `TAG-model.obj`.

1. `python load_cache.py TAG` -> `TAG-mesh.npz`
2. `python preview_repro.py TAG` -> `TAG-raw.ply`, `TAG-preview.ply` (clustering), `TAG-bounds.npz` (camera framing)
3. `python mirror2.py TAG NAME` -> `TAG-NAME.ply` + `.json` (vertices, passes, library RAM) + `-normals.npy`
4. `blender --background --python render.py -- TAG raw preview NAME` -> app camera (55 deg, 30 deg elevation), culling on
5. `python metric.py TAG preview NAME` -> extra see-through area vs the full mesh, top / mean of four 30 deg views
6. Optional: `blender --background --python render_smooth.py -- TAG PX PY AZ DIST NAME...` smooth shading with
   the normals the app writes (`ELEV` env = elevation).

## Results (30/09, five owner houses)
| house | input verts | clustering (2.74): verts; top/30deg | quadric (2.75): verts; MB; top/30deg |
|---|---|---|---|
| MUNH | 1.55M | 39.5k; +4.52/+3.00 | 116.5k; 4.85; +0.60/+0.39 |
| MUKX | 1.10M | 37.3k; +4.11/+3.40 | 108.7k; 4.66; +0.42/+0.34 |
| MUMU | 0.46M | 37.0k; +2.43/+1.86 | 118.6k; 5.42; +0.06/+0.02 |
| MUNI | 1.72M | 37.4k; +5.47/+3.86 | 115.6k; 4.83; +0.78/+0.49 |
| MUJJ | 1.80M | 37.0k; +4.38/+3.61 | 113.4k; 4.78; +0.88/+0.52 |

The full culled mesh itself shows 4-8 % see-through from the top: real LiDAR holes, not the preview.
Library RAM: stage A 10-24 MB (densest 4 m cell), stage B ~35 MB; one whole-mesh call = 261 MB (MUNH).
Desktop Ryzen 7700: library 0.84 s (MUNH), whole harness ~1.2-1.5 s.
