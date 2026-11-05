// Harness for Sources/Support/ZipWriter.swift (macOS, no Xcode project):
//   swiftc -O -o zipharness Sources/Support/ZipWriter.swift tools/zip-harness/main.swift
//   ./zipharness <empty work dir> && python3 tools/zip-harness/check.py <same dir>
// Builds a scan-like folder (OBJ text, random "JPEG"/depth files, chunk-edge sizes, an empty
// file), zips it with ZipWriter (ours.zip) and with the old NSFileCoordinator zipper (old.zip),
// checks the progress calls, prints both timings. check.py then reads ours.zip with every reader.
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("FAIL " + message + "\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count == 2 else { fail("usage: zipharness <work dir>") }
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fm = FileManager.default
let scan = root.appendingPathComponent("CedarScan-3D-TEST01", isDirectory: true)
try? fm.removeItem(at: root)
try fm.createDirectory(at: scan.appendingPathComponent("texture-shots"), withIntermediateDirectories: true)

if ZipWriter.crc32(0, Data("123456789".utf8)) != 0xCBF4_3926 { fail("crc32 check value") }

var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
func next() -> UInt64 {
    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return seed >> 33
}
func noise(_ count: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: next()) }
    return Data(bytes)
}

// model.obj: ~40 MB of OBJ-like text (many 1 MiB read chunks).
var obj = "# CedarScan colored LiDAR mesh\nmtllib model.mtl\no CedarScanMesh\nusemtl vertexcolor\n"
obj.reserveCapacity(42_000_000)
for _ in 0..<600_000 {
    obj += "v \(Double(next() % 200_000) / 10_000 - 10) \(Double(next() % 30_000) / 10_000) \(Double(next() % 200_000) / 10_000 - 10) 0.\(next() % 1000) 0.\(next() % 1000) 0.\(next() % 1000)\n"
}
for i in 0..<1_000_000 { obj += "f \(i % 600_000 + 1) \((i + 1) % 600_000 + 1) \((i + 2) % 600_000 + 1)\n" }
try Data(obj.utf8).write(to: scan.appendingPathComponent("model.obj"))
try Data("newmtl vertexcolor\nKd 1.000 1.000 1.000\n".utf8).write(to: scan.appendingPathComponent("model.mtl"))
try Data("{\"version\":1,\"frames\":[]}".utf8).write(to: scan.appendingPathComponent("camera-track.json"))
try Data().write(to: scan.appendingPathComponent("scan-report.json")) // empty file
for n in 1...60 {
    let shots = scan.appendingPathComponent("texture-shots")
    try noise(150_000 + Int(next() % 250_000)).write(to: shots.appendingPathComponent(String(format: "shot-%04d.jpg", n)))
    try noise(45_000 + Int(next() % 25_000)).write(to: shots.appendingPathComponent(String(format: "shot-%04d.depth", n)))
}
try noise(1 << 20).write(to: scan.appendingPathComponent("texture-shots/edge-1MiB.bin"))
try noise((1 << 20) + 1).write(to: scan.appendingPathComponent("texture-shots/edge-1MiB-plus1.bin"))
try Data(String(repeating: "{\"shot\":1}", count: 20_000).utf8).write(to: scan.appendingPathComponent("texture-shots/shots.json"))

// Ours, with the progress calls checked.
var calls: [Double] = []
var t0 = Date()
try ZipWriter.write(scan, to: root.appendingPathComponent("ours.zip")) { calls.append($0) }
let oursMs = Int(Date().timeIntervalSince(t0) * 1000)
if calls.isEmpty || calls.last != 1 { fail("progress must end at 1, got \(calls.last ?? -1)") }
if calls.count > 202 { fail("progress called \(calls.count) times") }
if zip(calls, calls.dropFirst()).contains(where: { $0 > $1 }) { fail("progress went backwards") }
if calls.contains(where: { !(0...1).contains($0) }) { fail("progress out of 0…1") }

// The old zipper (ColoredOBJExporter.zipDirectory, copied).
t0 = Date()
var coordError: NSError?
var copyError: Error?
NSFileCoordinator().coordinate(readingItemAt: scan, options: .forUploading, error: &coordError) { temp in
    do { try fm.copyItem(at: temp, to: root.appendingPathComponent("old.zip")) } catch { copyError = error }
}
if let coordError { fail("old zipper: \(coordError)") }
if let copyError { fail("old zipper copy: \(copyError)") }
let oldMs = Int(Date().timeIntervalSince(t0) * 1000)

func size(_ name: String) -> Int64 {
    ((try? fm.attributesOfItem(atPath: root.appendingPathComponent(name).path)[.size]) as? NSNumber)?.int64Value ?? -1
}
print("ours.zip \(size("ours.zip")) B in \(oursMs) ms (\(calls.count) progress calls) · old.zip \(size("old.zip")) B in \(oldMs) ms")
