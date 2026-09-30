// swift-tools-version:5.9
// Vendored meshoptimizer (MIT, see LICENSE.md and README.md): only the simplifier and the two
// remap helpers the grey 3D preview uses (`Sources/Scan/PreviewSimplifier.swift`).
import PackageDescription

let package = Package(
    name: "MeshOptimizer",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "CMeshOptimizer", targets: ["CMeshOptimizer"]),
    ],
    targets: [
        .target(
            name: "CMeshOptimizer",
            path: "Sources/CMeshOptimizer",
            cxxSettings: [
                .headerSearchPath("include"),
                // Library asserts compiled out in every configuration: a debug assert firing inside
                // the save path would abort the app before the scan is stored. The Swift caller
                // validates every count and index it passes in.
                .define("NDEBUG"),
            ]
        ),
    ]
)
