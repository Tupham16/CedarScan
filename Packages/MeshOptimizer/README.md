# MeshOptimizer (vendored)

meshoptimizer by Arseny Kapoulkine, MIT (`LICENSE.md`).
Upstream: https://github.com/zeux/meshoptimizer, tag **v1.3**, commit `9e1f07b159d3cb777f1c67ed31fc11fd117986f4`.

Used only by `Sources/Scan/PreviewSimplifier.swift` (grey 3D preview, `mesh-preview.bin`).

- Files are byte-identical copies of upstream `src/`: `meshoptimizer.h` (in `include/`), `simplifier.cpp`,
  `allocator.cpp`, `indexgenerator.cpp`, `vfetchoptimizer.cpp`. Do not edit them; `module.modulemap` and
  `Package.swift` are ours.
- Vendored, not a remote SPM package: upstream has no `Package.swift`.
- `NDEBUG` is defined for every configuration (see `Package.swift`).
- Swift sees the WHOLE header, but only functions defined in the four `.cpp` files link. Calling another
  one (e.g. `meshopt_optimizeVertexCache`) compiles and then fails at link time: vendor its upstream
  `.cpp` too.
- Update: copy the same five files from a new tag, record tag + commit here, then re-run the offline
  harness (`tools/preview-harness/`, README there) before shipping.
