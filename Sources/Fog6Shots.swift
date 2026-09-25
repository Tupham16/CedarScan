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

    /// Harness only: `init() { Fog6.seed() }` leaves the window tint at system blue (trap #48).
    @MainActor static func applyAccentTint() {
        let accent = UIColor(named: "AccentColor")
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for window in scenes.flatMap(\.windows) {
            window.tintColor = accent
        }
    }

    static let maple = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let oak = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let rMain = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    static let rOrdered = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!
    static let rExtra = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000003")!
    static let rLow = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000004")!
    static let rNoModel = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000005")!
    static let rOakOrdered = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000006")!
    static let rUpper = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000007")!
    static let rBase = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000008")!

    // MARK: 6b — order sheet stubs (no server)

    static let palettes: [(String, [UInt32])] = [
        ("Classic", [0xE9E2D0, 0xD9E4DC, 0xDDE3EC, 0xCFE0E8, 0xEFEAE0]),
        ("Warm", [0xF3D9B8, 0xEBC3A0, 0xF0E0C8, 0xE2B49A, 0xF6EAD8]),
        ("Cool", [0xCFE1F2, 0xBBD3EA, 0xDCE9F5, 0xA9C7E3, 0xE8F1F9]),
        ("Pastel", [0xF7D6E0, 0xD6EBD8, 0xE0DAF2, 0xFCEBC7, 0xD3ECEF]),
        ("Bold", [0xF2B134, 0x4FA3A5, 0xE4572E, 0x5B6FA8, 0xA8C686]),
    ]

    static func templateURL(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fog6-tpl-\(name.lowercased()).png")
    }

    /// Template image stand-in: a small coloured plan on white.
    static func writeTemplate(_ colors: [UInt32], to url: URL) {
        let size = CGSize(width: 240, height: 160)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let rooms = [
                CGRect(x: 24, y: 20, width: 110, height: 70), CGRect(x: 134, y: 20, width: 82, height: 62),
                CGRect(x: 24, y: 90, width: 66, height: 50), CGRect(x: 90, y: 90, width: 44, height: 50),
                CGRect(x: 134, y: 82, width: 82, height: 58),
            ]
            for (r, c) in zip(rooms, colors) {
                UIColor(red: CGFloat((c >> 16) & 0xFF) / 255, green: CGFloat((c >> 8) & 0xFF) / 255,
                        blue: CGFloat(c & 0xFF) / 255, alpha: 1).setFill()
                ctx.fill(r)
            }
            UIColor(red: 0.29, green: 0.33, blue: 0.41, alpha: 1).setStroke()
            for r in rooms {
                let p = UIBezierPath(rect: r)
                p.lineWidth = 4
                p.stroke()
            }
        }
        try? image.pngData()?.write(to: url)
    }

    /// DEFAULT_CATALOG prices. `order` / `order-busy` = FREE (2 of 3 left), the rest paid.
    static func catalog() -> CatalogResponse {
        let free = screen == "order" || screen == "order-busy"
        let addons = screen == "order" ? "[\"color\",\"dwg\",\"express\",\"tour\"]" : "[\"color\",\"dwg\",\"tour\"]"
        let tpls = palettes.map { p in
            "{\"id\":\"\(p.0.lowercased())\",\"name\":\"\(p.0)\",\"imageUrl\":\"\(templateURL(p.0).absoluteString)\"}"
        }.joined(separator: ",")
        let json = """
        {"currency":"USD",
         "packages":[{"id":"2d","name":"2D Floor Plan","price":6,"isDefault":true},
                     {"id":"3d","name":"3D Floor Plan","price":40,"isDefault":false}],
         "addons":[{"id":"color","name":"Color floor plan","price":2,"templates":[\(tpls)]},
                   {"id":"siteplan","name":"Site plan","price":2,"templates":[\(tpls)]},
                   {"id":"dwg","name":"CAD File","price":1},
                   {"id":"express","name":"Express 12h turnaround","price":6},
                   {"id":"gla","name":"GLA report (ANSI)","price":10},
                   {"id":"tour","name":"Virtual Tour","price":10}],
         "areaSurcharges":[],
         "freeFirstOrders":3,"freeOrdersRemaining":\(free ? 2 : 0),
         "defaults":{"packageIds":["2d"],"addonIds":\(addons),"templates":{"color":"classic"},
                     "unitSystem":"metric","language":"English"}}
        """
        return try! JSONDecoder().decode(CatalogResponse.self, from: Data(json.utf8))
    }

    /// Canned "Order placed" answers (#10483). nil = stay on the form.
    static func placed() -> OrderScanResponse? {
        let json: String
        switch screen {
        case "placed":
            json = ##"{"orderId":"h1","orderNumber":"#10483","status":"pending","total":19,"currency":"USD","paymentUrl":"https://example.invalid/pay/h1","free":false,"hasTour":true,"payInApp":false}"##
        case "placed-free":
            json = ##"{"orderId":"h2","orderNumber":"#10484","status":"pending","total":0,"currency":"USD","free":true,"hasTour":false}"##
        case "placed-coupon":
            json = ##"{"orderId":"h3","orderNumber":"#10485","status":"pending","total":14,"currency":"USD","paymentUrl":"https://example.invalid/pay/h3","discount":5,"couponApplied":true,"free":false,"hasTour":false,"payInApp":false}"##
        case "placed-tall":
            json = ##"{"orderId":"h5","orderNumber":"#10487","status":"pending","total":14,"currency":"USD","paymentUrl":"https://example.invalid/pay/h5","discount":5,"couponApplied":true,"free":false,"hasTour":true,"payInApp":false}"##
        case "placed-awaiting":
            json = ##"{"orderId":"h6","orderNumber":"#LS-MS5M4941E","status":"awaiting_payment","payBy":"2026-10-02T10:00:00.000Z","total":129,"currency":"USD","paymentUrl":"https://example.invalid/pay/h6","free":false,"hasTour":true,"payInApp":false}"##
        case "placed-awaiting-test":
            json = ##"{"orderId":"h7","orderNumber":"#LS-MS5M4941F","status":"awaiting_payment","payBy":null,"total":129,"currency":"USD","paymentUrl":"https://example.invalid/pay/h7","free":false,"hasTour":false,"payInApp":false}"##
        case "placed-awaiting-nolink":
            json = ##"{"orderId":"h8","orderNumber":"#LS-MS5M4941G","status":"awaiting_payment","payBy":"2026-10-02T10:00:00.000Z","total":129,"currency":"USD","couponApplied":false,"free":false,"hasTour":false}"##
        case "placed-awaiting-coupon":
            json = ##"{"orderId":"h9","orderNumber":"#LS-MS5M4941H","status":"awaiting_payment","payBy":"2026-10-02T10:00:00.000Z","total":124,"currency":"USD","paymentUrl":"https://example.invalid/pay/h9","discount":5,"couponApplied":true,"free":false,"hasTour":true,"payInApp":false}"##
        case "placed-badcoupon":
            json = ##"{"orderId":"h4","orderNumber":"#10486","status":"pending","total":19,"currency":"USD","couponApplied":false,"free":false,"hasTour":true}"##
        default:
            return nil
        }
        return try? JSONDecoder().decode(OrderScanResponse.self, from: Data(json.utf8))
    }

    // MARK: Orders v2 C — "Add to this order" stubs

    static var addonScreen: Bool { screen?.hasPrefix("addon") == true }

    static func extrasOffer() -> ExtrasOffer {
        let tpls = palettes.enumerated().map { i, p in
            "{\"id\":\"style-\(i + 1)\",\"name\":\"Style \(i + 1)\",\"imageUrl\":\"\(templateURL(p.0).absoluteString)\"}"
        }.joined(separator: ",")
        let blocked = screen == "addon-blocked"
        let code = blocked ? "\"extra_awaiting\"" : "null"
        let json = """
        {"orderId":"a7","orderNumber":"#LS-MS5UP7AUN","canAdd":\(!blocked),"code":\(code),"awaitingOrderId":null,
         "packages":[{"id":"2d","name":"2D Floor Plan","price":10,"included":true},
                     {"id":"3d","name":"3D Floor Plan","price":40,"included":false}],
         "addons":[{"id":"color","name":"Color floor plan","price":2,"included":true,"templates":[\(tpls)]},
                   {"id":"siteplan","name":"Site plan","price":3,"included":false,"templates":[\(tpls)]},
                   {"id":"dwg","name":"CAD File","price":1,"included":false}]}
        """
        return try! JSONDecoder().decode(ExtrasOffer.self, from: Data(json.utf8))
    }

    /// The purchase the sheet made: `addon-coupon` = a customer coupon took 40 cents off (the button
    /// shows the exact amount and waits for a tap); `addon-done*` = paid.
    static func extrasPurchase() -> AddExtrasResponse? {
        let json: String
        switch screen {
        case "addon-coupon":
            json = ##"{"orderId":"x9","orderNumber":"#LS-MS5UP7AUN_A2","status":"awaiting_payment","total":43,"amountCents":4260,"items":["3D Floor Plan","Site plan · Style 2"],"discount":0.4,"free":false,"paymentUrl":"https://example.invalid/pay/x9","payInApp":false,"payBy":"2026-10-02T10:00:00.000Z"}"##
        case "addon-done", "addon-done-notdelivered":
            json = ##"{"orderId":"x9","orderNumber":"#LS-MS5UP7AUN_A2","status":"received","total":43,"amountCents":4300,"items":["3D Floor Plan","Site plan · Style 2"],"discount":0,"free":false,"paymentUrl":null,"payInApp":false,"payBy":null}"##
        default:
            return nil
        }
        return try? JSONDecoder().decode(AddExtrasResponse.self, from: Data(json.utf8))
    }

    // MARK: Orders v2 B — canned Orders tab

    /// `orders` = the list; `orders-<orderId>` = that order pushed.
    static var ordersScreen: Bool { screen?.hasPrefix("orders") == true }
    static var openOrderId: String? {
        guard let screen, screen.hasPrefix("orders-") else { return nil }
        return String(screen.dropFirst("orders-".count))
    }

    static let orders: [OrderDTO] = {
        let json = ##"""
        {"orders":[
         {"orderId":"a1","orderNumber":"#LS-MS5M4941E","scanId":"s3","scanIds":["s3"],"scanName":"Main floor","projectName":"12 Oak Street","items":["2D Floor Plan","3D Floor Plan","Site plan","Express 12h turnaround"],"status":"awaiting_payment","placedAt":"2026-09-14T10:00:00.000Z","payBy":"2026-09-21T10:00:00.000Z","cancelledAt":null,"cancelReason":null,"deliveredAt":null,"deliveredUrl":null,"deliveryFiles":[],"total":129,"currency":"USD","paid":false,"paymentUrl":"https://example.invalid/pay/a1","payInApp":false,"hasTour":false,"tourPhotoCount":0,"tourUrl":null,"texturedScans":[]},
         {"orderId":"a2","orderNumber":"#LS-MS5M4941F","scanId":"s8","scanIds":["s8"],"scanName":"Main floor","projectName":"Demo House (App Review)","items":["2D Floor Plan"],"status":"awaiting_payment","placedAt":"2026-09-13T10:00:00.000Z","payBy":null,"cancelledAt":null,"cancelReason":null,"deliveredAt":null,"deliveredUrl":null,"deliveryFiles":[],"total":6,"currency":"USD","paid":false,"paymentUrl":"https://example.invalid/pay/a2","payInApp":false,"hasTour":true,"tourPhotoCount":0,"tourUrl":null,"texturedScans":[]},
         {"orderId":"a3","orderNumber":"#LS-MS5M4941G","scanId":"s9","scanIds":["s9"],"scanName":"Garage","projectName":"3 Birch Lane","items":["2D Floor Plan","CAD File"],"status":"awaiting_payment","placedAt":"2026-09-12T10:00:00.000Z","payBy":"2026-09-19T10:00:00.000Z","cancelledAt":null,"cancelReason":null,"deliveredAt":null,"deliveredUrl":null,"deliveryFiles":[],"total":7,"currency":"USD","paid":false,"paymentUrl":null,"payInApp":false,"hasTour":false,"tourPhotoCount":0,"tourUrl":null,"texturedScans":[]},
         {"orderId":"a4","orderNumber":"#LS-MRQL7MXNA","scanId":"s4","scanIds":["s4"],"scanName":"Main floor","projectName":"7 Pine Court","items":["2D Floor Plan"],"status":"in_production","placedAt":"2026-09-10T10:00:00.000Z","payBy":null,"cancelledAt":null,"cancelReason":null,"deliveredAt":null,"deliveredUrl":null,"deliveryFiles":[],"total":6,"currency":"USD","paid":true,"paymentUrl":null,"payInApp":false,"hasTour":false,"tourPhotoCount":0,"tourUrl":null,"texturedScans":[],"canAddItems":false,
          "extras":[{"orderId":"x2","orderNumber":"#LS-MRQL7MXNA_A1","scanId":null,"scanIds":[],"scanName":null,"projectName":"7 Pine Court","items":["Site plan · Style 2","CAD File"],"status":"awaiting_payment","placedAt":"2026-09-20T10:00:00.000Z","payBy":"2026-09-27T10:00:00.000Z","cancelledAt":null,"cancelReason":null,"deliveredAt":null,"deliveredUrl":null,"deliveryFiles":[],"total":4,"currency":"USD","paid":false,"paymentUrl":"https://example.invalid/pay/x2","payInApp":false,"hasTour":false,"tourPhotoCount":0,"tourUrl":null,"texturedScans":[]}]},
         {"orderId":"a5","orderNumber":"#LS-MRAT7XNG6","scanId":"s6","scanIds":["s6","s7"],"scanName":"Main floor + Basement","projectName":"5 Elm Way","items":["2D Floor Plan","Color floor plan · Classic"],"status":"cancelled","placedAt":"2026-09-03T10:00:00.000Z","payBy":null,"cancelledAt":"2026-09-10T10:00:00.000Z","cancelReason":"expired","deliveredAt":null,"deliveredUrl":null,"deliveryFiles":[],"total":8,"currency":"USD","paid":false,"paymentUrl":null,"payInApp":false,"hasTour":false,"tourPhotoCount":0,"tourUrl":null,"texturedScans":[]},
         {"orderId":"a6","orderNumber":"#LS-MRAT7XNG7","scanId":"s10","scanIds":["s10"],"scanName":"Shed","projectName":"9 Cedar Road","items":["2D Floor Plan"],"status":"cancelled","placedAt":"2026-09-02T10:00:00.000Z","payBy":null,"cancelledAt":"2026-09-04T10:00:00.000Z","cancelReason":"customer","deliveredAt":null,"deliveredUrl":null,"deliveryFiles":[],"total":6,"currency":"USD","paid":true,"paymentUrl":null,"payInApp":false,"hasTour":false,"tourPhotoCount":0,"tourUrl":null,"texturedScans":[]},
         {"orderId":"a7","orderNumber":"#LS-MS5UP7AUN","scanId":"s1","scanIds":["s1"],"scanName":"Main floor","projectName":"48 Harbor View","items":["2D Floor Plan"],"status":"delivered","placedAt":"2026-09-01T10:00:00.000Z","payBy":null,"cancelledAt":null,"cancelReason":null,"deliveredAt":"2026-09-02T10:00:00.000Z","deliveredUrl":"https://example.invalid/d/a7.zip","deliveryFiles":[{"fileName":"48-Harbor-View-floorplan.pdf","url":"https://example.invalid/d/a.pdf","sizeLabel":"2.4 MB"}],"total":6,"currency":"USD","paid":true,"paymentUrl":null,"payInApp":false,"hasTour":false,"tourPhotoCount":0,"tourUrl":null,"texturedScans":[],"canAddItems":true,
          "extras":[{"orderId":"x1","orderNumber":"#LS-MS5UP7AUN_A1","scanId":null,"scanIds":[],"scanName":null,"projectName":"48 Harbor View","items":["3D Floor Plan","Site plan · Style 2"],"status":"delivered","placedAt":"2026-09-20T10:00:00.000Z","payBy":null,"cancelledAt":null,"cancelReason":null,"deliveredAt":"2026-09-23T10:00:00.000Z","deliveredUrl":"https://example.invalid/d/x1.zip","deliveryFiles":[{"fileName":"48-Harbor-View-3D.pdf","url":"https://example.invalid/d/x1a.pdf","sizeLabel":"3.1 MB"},{"fileName":"48-Harbor-View-siteplan.pdf","url":"https://example.invalid/d/x1b.pdf","sizeLabel":"0.9 MB"}],"total":42,"currency":"USD","paid":true,"paymentUrl":null,"payInApp":false,"hasTour":false,"tourPhotoCount":0,"tourUrl":null,"texturedScans":[]}]},
         {"orderId":"a8","orderNumber":"#LS-MS3KQ2ZT4","scanId":"s11","scanIds":["s11"],"scanName":"Main floor","projectName":"210 Lake Road","items":["2D Floor Plan","Color floor plan · Style 2"],"status":"in_production","placedAt":"2026-08-21T10:00:00.000Z","payBy":null,"cancelledAt":null,"cancelReason":null,"deliveredAt":null,"deliveredUrl":null,"deliveryFiles":[],"total":8,"currency":"USD","paid":true,"paymentUrl":null,"payInApp":false,"hasTour":false,"tourPhotoCount":0,"tourUrl":null,"texturedScans":[],"canAddItems":true,
          "extras":[{"orderId":"x3","orderNumber":"#LS-MS3KQ2ZT4_A1","scanId":null,"scanIds":[],"scanName":null,"projectName":"210 Lake Road","items":["3D Floor Plan"],"status":"received","placedAt":"2026-09-01T10:00:00.000Z","payBy":null,"cancelledAt":null,"cancelReason":null,"deliveredAt":null,"deliveredUrl":null,"deliveryFiles":[],"total":40,"currency":"USD","paid":true,"paymentUrl":null,"payInApp":false,"hasTour":false,"tourPhotoCount":0,"tourUrl":null,"texturedScans":[]}]}
        ]}
        """##
        do {
            return try JSONDecoder().decode(OrdersResponse.self, from: Data(json.utf8)).orders
        } catch {
            fatalError("harness orders: \(error)")
        }
    }()

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
            ScanRecord(id: rUpper, name: "Upper floor", createdAt: now, roomCount: 0, projectId: maple,
                       qualityScore: 90, qualityGrade: "A", qualityRescan: false),
            ScanRecord(id: rBase, name: "Basement", createdAt: now, roomCount: 0, projectId: maple,
                       qualityScore: 90, qualityGrade: "A", qualityRescan: false),
        ]
        for p in palettes {
            writeTemplate(p.1, to: templateURL(p.0))
        }
        // Orders v2 B: the Oak order #10482 awaits payment (Home / property / scan page badges).
        if ["home", "project", "detail-awaiting"].contains(screen) {
            UserDefaults.standard.set(["#10482"], forKey: "awaitingOrderNumbers.v1")
        } else {
            UserDefaults.standard.removeObject(forKey: "awaitingOrderNumbers.v1")
        }
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
    @State private var name = Fog6.screen == "naming-typing" ? "c" : "Main floor"
    @State private var sheet = true
    @State private var path = NavigationPath()

    private var screen: String { Fog6.screen ?? "" }

    var body: some View {
        switch screen {
        case "detail", "detail-signedout", "detail-verify": detail(Fog6.rMain)
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
        case "naming", "naming-typing":
            ZStack {
                Image("Fog5Room").resizable().scaledToFill().ignoresSafeArea()
                ScanNameOverlay(
                    name: $name,
                    subtitle: String(localized: "Which area of the property is this?"),
                    suggestions: ["Main floor", "Basement", "Upper floor", "Shed", "Garage", "Storage"],
                    typeAheadSuggestions: [
                        "Ground floor", "First floor", "Second floor", "Attic", "Lower Floor",
                        "Conservatory", "Sunroom", "Tool Shed", "Detached Garage", "Roof floor",
                        "Carport", "Basement", "Kitchen", "Bedroom", "Patio", "Deck", "Porch",
                    ],
                    onSave: {}, onBack: {}
                )
            }
        case "guide":
            Color.gray.opacity(0.35).ignoresSafeArea()
                .sheet(isPresented: $sheet) { ScanGuideView(onStart: {}) }
        case "learn":
            LearnView()
                .overlay(alignment: .bottom) { CedarTabBar(selection: .constant(.learn), onScan: {}) }
        case "home":
            HomeView(scanRequest: 0, openProjectRequest: nil, store: store, account: account)
                .overlay(alignment: .bottom) { CedarTabBar(selection: .constant(.home), onScan: {}) }
        case "project":
            NavigationStack(path: $path) {
                Color.clear
                    .navigationDestination(for: ScanProject.self) { p in
                        ProjectView(store: store, account: account, projectId: p.id, projectName: p.name, path: $path)
                    }
            }
            .overlay(alignment: .bottom) { CedarTabBar(selection: .constant(.home), onScan: {}) }
            .onAppear {
                if path.isEmpty, let p = store.projects.first(where: { $0.id == Fog6.oak }) {
                    path.append(p)
                }
            }
        case "detail-awaiting": detail(Fog6.rOakOrdered)
        case let s where s.hasPrefix("orders"):
            OrdersView(store: store, account: account, onOpenProject: { _ in })
                .overlay(alignment: .bottom) { CedarTabBar(selection: .constant(.orders), onScan: {}) }
        case "order", "order-busy", "order-error", "placed", "placed-free", "placed-coupon", "placed-badcoupon", "placed-tall",
             "placed-awaiting", "placed-awaiting-test", "placed-awaiting-nolink", "placed-awaiting-coupon":
            Color.gray.opacity(0.35).ignoresSafeArea()
                .sheet(isPresented: $sheet) { orderSheet(project: false) }
        case "addon", "addon-coupon", "addon-done", "addon-blocked", "addon-notdelivered", "addon-done-notdelivered":
            Color.gray.opacity(0.35).ignoresSafeArea()
                .sheet(isPresented: $sheet) {
                    AddToOrderSheet(
                        target: AddToOrderTarget(
                            orderId: "a7",
                            orderNumber: "#LS-MS5UP7AUN",
                            title: "48 Harbor View",
                            delivered: !screen.hasSuffix("notdelivered")
                        ),
                        onChanged: {}
                    )
                }
        case "order-paid":
            Color.gray.opacity(0.35).ignoresSafeArea()
                .sheet(isPresented: $sheet) { orderSheet(project: true) }
        default:
            Text(verbatim: "unknown screen \(screen)")
        }
    }

    /// Record mode (Main floor + 2 unordered floors of the same home) or project mode (all ticked).
    @ViewBuilder
    private func orderSheet(project: Bool) -> some View {
        if let r = store.records.first(where: { $0.id == Fog6.rMain }) {
            OrderSheet(
                record: r,
                projectName: "7 Maple Court",
                candidateScans: project ? store.records.filter { $0.projectId == Fog6.maple } : nil
            )
            .environmentObject(store)
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
