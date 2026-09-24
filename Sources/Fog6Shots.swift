import AVFoundation
import SwiftUI
import UIKit
import simd

/// THROWAWAY (branch claude/fog6-shots only, never main): Fog step 6 screens in the simulator.
/// `-fog6shot <screen>`. Seeds scans, a fake signed-in account, a video and a small mesh.
enum Fog6 {
    static let screen: String? = {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-fog6shot"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }()
    static var on: Bool { screen != nil }

    static let maple = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let oak = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let rMain = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    static let rOrdered = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!
    static let rExtra = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000003")!
    static let rLow = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000004")!
    static let rNoModel = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000005")!
    static let rOakOrdered = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000006")!

    static var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static func folder(_ id: UUID) -> URL {
        docs.appendingPathComponent("Scans", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Runs in `CedarScanApp.init`, before `ScanStore()` / `AccountStore()` read disk.
    static func seed() {
        guard let screen else { return }
        let fm = FileManager.default
        let scans = docs.appendingPathComponent("Scans", isDirectory: true)
        try? fm.removeItem(at: scans)
        try? fm.removeItem(at: docs.appendingPathComponent("projects.json"))
        UserDefaults.standard.set(true, forKey: ScanGuideView.seenKey)
        if screen.hasSuffix("-signedout") {
            Keychain.delete("app-token")
            UserDefaults.standard.removeObject(forKey: "app-customer")
        } else {
            Keychain.save("harness", for: "app-token")
            let c = CustomerDTO(id: "harness", email: "harness@example.com", name: "Harness")
            UserDefaults.standard.set(try? JSONEncoder().encode(c), forKey: "app-customer")
            UserDefaults.standard.set(true, forKey: "app-email-verified")
        }
        try? fm.createDirectory(at: scans, withIntermediateDirectories: true)
        let now = Date()
        let projects = [
            ScanProject(id: maple, name: "7 Maple Court", createdAt: now),
            ScanProject(id: oak, name: "12 Oak Street", createdAt: now.addingTimeInterval(-86400)),
        ]
        try? JSONEncoder().encode(projects).write(to: docs.appendingPathComponent("projects.json"))
        let records = [
            ScanRecord(id: rMain, name: "Main floor", createdAt: now, roomCount: 0, projectId: maple,
                       qualityScore: 92, qualityGrade: "A", qualityRescan: false),
            ScanRecord(id: rOrdered, name: "Upper floor", createdAt: now, roomCount: 0,
                       cloudOrderNumber: "#10483", projectId: nil,
                       qualityScore: 88, qualityGrade: "B", qualityRescan: false),
            ScanRecord(id: rExtra, name: "Garage", createdAt: now, roomCount: 0, projectId: oak,
                       qualityScore: 92, qualityGrade: "A", qualityRescan: false),
            ScanRecord(id: rOakOrdered, name: "Main floor", createdAt: now, roomCount: 0,
                       cloudOrderNumber: "#10482", projectId: oak,
                       qualityScore: 90, qualityGrade: "A", qualityRescan: false),
            ScanRecord(id: rLow, name: "Basement", createdAt: now, roomCount: 0, projectId: nil,
                       qualityScore: 58, qualityGrade: "C", qualityRescan: true),
            ScanRecord(id: rNoModel, name: "Shed", createdAt: now, roomCount: 0, projectId: nil),
        ]
        for r in records {
            let dir = folder(r.id)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? JSONEncoder().encode(r).write(to: dir.appendingPathComponent("meta.json"))
            if r.id != rNoModel {
                fm.createFile(atPath: dir.appendingPathComponent("model-colored.zip").path, contents: Data([0]))
                writeMesh(to: dir.appendingPathComponent(MeshPreviewFile.fileName))
            }
        }
        if let room = UIImage(named: "Fog5Room") {
            makeVideo(at: folder(rMain).appendingPathComponent("scan-video.mp4"), image: room)
            for id in [rOrdered, rExtra, rLow, rNoModel] {
                try? fm.copyItem(at: folder(rMain).appendingPathComponent("scan-video.mp4"),
                                 to: folder(id).appendingPathComponent("scan-video.mp4"))
            }
        }
    }

    /// A 6 x 4 m flat: floor, outer walls, two inner walls (both faces of every wall).
    static func writeMesh(to url: URL) {
        var p: [SIMD3<Float>] = []
        var n: [SIMD3<Float>] = []
        var idx: [UInt32] = []
        func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>) {
            let normal = simd_normalize(simd_cross(b - a, d - a))
            for (face, nn) in [([a, b, c, d], normal), ([a, d, c, b], -normal)] {
                let base = UInt32(p.count)
                p += face
                n += Array(repeating: nn, count: 4)
                idx += [base, base + 1, base + 2, base, base + 2, base + 3]
            }
        }
        func wall(_ x0: Float, _ z0: Float, _ x1: Float, _ z1: Float) {
            quad([x0, 0, z0], [x1, 0, z1], [x1, 2.5, z1], [x0, 2.5, z0])
        }
        quad([-3, 0, -2], [3, 0, -2], [3, 0, 2], [-3, 0, 2])
        wall(-3, -2, 3, -2); wall(3, -2, 3, 2); wall(3, 2, -3, 2); wall(-3, 2, -3, -2)
        wall(0, -2, 0, 0.6); wall(0, 0.6, 3, 0.6)
        try? MeshPreviewFile.write(positions: p, normals: n, indices: idx, to: url)
    }

    /// 2 s portrait H.264 of a still image (the walkthrough video stand-in).
    static func makeVideo(at url: URL, image: UIImage) {
        try? FileManager.default.removeItem(at: url)
        let w = 720, h = 960
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4), let cg = image.cgImage else { return }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(input)
        guard writer.startWriting() else { return }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else { return }
        let scale = max(CGFloat(w) / CGFloat(cg.width), CGFloat(h) / CGFloat(cg.height))
        let dw = CGFloat(cg.width) * scale, dh = CGFloat(cg.height) * scale
        let rect = CGRect(x: (CGFloat(w) - dw) / 2, y: (CGFloat(h) - dh) / 2, width: dw, height: dh)
        for i in 0..<20 {
            while !input.isReadyForMoreMediaData { usleep(2000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
            ctx?.draw(cg, in: rect)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(i), timescale: 10))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        _ = done.wait(timeout: .now() + 20)
    }
}

/// THROWAWAY: the screen named by `-fog6shot`.
struct Fog6ShotRoot: View {
    @EnvironmentObject private var store: ScanStore
    @EnvironmentObject private var account: AccountStore
    @StateObject private var textured = TexturedModelCache()
    @State private var name = "Main floor"
    @State private var sheet = true
    @State private var path = NavigationPath()

    private var screen: String { Fog6.screen ?? "" }

    var body: some View {
        switch screen {
        case "detail", "detail-signedout": detail(Fog6.rMain)
        case "detail-ordered": detail(Fog6.rOrdered)
        case "detail-extra": detail(Fog6.rExtra)
        case "detail-low": detail(Fog6.rLow)
        case "detail-nomodel": detail(Fog6.rNoModel)
        case "viewer":
            ModelViewerScreen(
                greyURL: Fog6.folder(Fog6.rMain).appendingPathComponent(MeshPreviewFile.fileName),
                texturedRemote: URL(string: "https://example.invalid/textured.usdz"),
                cloudScanId: "harness",
                textured: textured
            )
        case "saved", "saved-extra", "saved-novideo":
            ScanPreviewView(
                addressName: "7 Maple Court",
                scanName: "Main floor",
                videoURL: screen == "saved-novideo" ? nil : Fog6.folder(Fog6.rMain).appendingPathComponent("scan-video.mp4"),
                meshPreviewURL: Fog6.folder(Fog6.rMain).appendingPathComponent(MeshPreviewFile.fileName),
                isSupplement: screen == "saved-extra",
                onScanMore: {}, onOrderLater: {}, onOrderNow: {}
            )
        case "address":
            Color.gray.opacity(0.35).ignoresSafeArea()
                .sheet(isPresented: $sheet) { ScanAddressView(onStart: { _ in }).environmentObject(store) }
        case "naming":
            ZStack {
                Image("Fog5Room").resizable().scaledToFill().ignoresSafeArea()
                ScanNameOverlay(
                    name: $name,
                    subtitle: String(localized: "Which area of the property is this?"),
                    suggestions: ["Main floor", "Basement", "Upper floor", "Shed", "Garage", "Storage"],
                    typeAheadSuggestions: ["Ground floor", "First floor", "Second floor", "Attic", "Lower Floor"],
                    onSave: {}, onBack: {}
                )
            }
        case "guide":
            Color.gray.opacity(0.35).ignoresSafeArea()
                .sheet(isPresented: $sheet) { ScanGuideView(onStart: {}) }
        case "learn":
            LearnView()
                .overlay(alignment: .bottom) { CedarTabBar(selection: .constant(.learn), onScan: {}) }
        default:
            Text(verbatim: "unknown screen \(screen)")
        }
    }

    /// Pushed like the real app (Back button), tab bar drawn over the bottom.
    private func detail(_ id: UUID) -> some View {
        NavigationStack(path: $path) {
            Color.clear
                .navigationDestination(for: ScanRecord.self) { r in
                    ScanDetailView(record: r, autoOpenOrder: false, store: store, account: account)
                }
        }
        .overlay(alignment: .bottom) { CedarTabBar(selection: .constant(.home), onScan: {}) }
        .onAppear {
            if path.isEmpty, let r = store.records.first(where: { $0.id == id }) {
                path.append(r)
            }
        }
    }
}
