import Foundation

/// THROWAWAY (branch claude/orders2-shots, never main): canned orders for simulator screenshots.
enum Orders2Shots {
    private static let args = ProcessInfo.processInfo.arguments
    static let on = args.contains("-orders2shots")
    static let error = args.contains("-orders2error")
    /// `-orders2open <orderId>` pushes that order at launch.
    static var openId: String? {
        guard let i = args.firstIndex(of: "-orders2open"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static let orders: [OrderDTO] = {
        let json = """
        {"orders":[
         {"orderId":"o1","orderNumber":"#LS-MS5UP7AUN","scanId":"s1","scanIds":["s1","s2"],"scanName":"Main floor + Basement","projectName":"48 Harbor View","items":["2D Floor Plan","Color floor plan · Classic","Virtual Tour"],"status":"delivered","placedAt":"2026-09-02T10:00:00.000Z","deliveredAt":"2026-09-03T10:00:00.000Z","deliveredUrl":"https://app.cedar247.com/d/o1.zip","deliveryFiles":[{"fileName":"48-Harbor-View-floorplan.pdf","url":"https://app.cedar247.com/d/a.pdf","sizeLabel":"2.4 MB"},{"fileName":"48-Harbor-View-floorplan.dwg","url":"https://app.cedar247.com/d/b.dwg","sizeLabel":"1.1 MB"}],"total":89,"currency":"USD","paid":true,"paymentUrl":null,"payInApp":false,"hasTour":true,"tourPhotoCount":6,"tourUrl":"https://app.cedar247.com/tour/abc","texturedScans":[]},
         {"orderId":"o2","orderNumber":"#LS-MS5M4941E","scanId":"s3","scanIds":["s3"],"scanName":"Main floor","projectName":"12 Oak Street","items":["2D Floor Plan","3D Floor Plan","Site plan · Style 4","Express 12h turnaround"],"status":"received","placedAt":"2026-09-14T10:00:00.000Z","deliveredAt":null,"deliveredUrl":null,"deliveryFiles":[],"total":129,"currency":"USD","paid":false,"paymentUrl":"https://app.cedar247.com/pay/o2","payInApp":false,"hasTour":false,"tourPhotoCount":0,"tourUrl":null,"texturedScans":[]},
         {"orderId":"o3","orderNumber":"#LS-MRQL7MXNA","scanId":"s4","scanIds":["s4"],"scanName":"Main floor","projectName":"7 Pine Court","items":["2D Floor Plan","CAD File","Virtual Tour"],"status":"in_production","placedAt":"2026-09-10T10:00:00.000Z","deliveredAt":null,"deliveredUrl":null,"deliveryFiles":[],"total":23,"currency":"USD","paid":true,"paymentUrl":null,"payInApp":false,"hasTour":true,"tourPhotoCount":2,"tourUrl":null,"texturedScans":[]},
         {"orderId":"o4","orderNumber":"#LS-MRP15SN2K","scanId":"s5","scanIds":["s5"],"scanName":"Main floor","projectName":"210 Lake Road","items":["2D Floor Plan","Express 8h turnaround","Color floor plan","CAD file (DWG)","GLA report (ANSI)","Site plan · Style 1"],"status":"delivered","placedAt":"2026-08-21T10:00:00.000Z","deliveredAt":"2026-08-22T10:00:00.000Z","deliveredUrl":"https://app.cedar247.com/d/o4.zip","deliveryFiles":[{"fileName":"210-Lake-Road-floorplan-with-a-very-long-file-name.pdf","url":"https://app.cedar247.com/d/c.pdf","sizeLabel":"3.0 MB"}],"total":15,"currency":"USD","paid":true,"paymentUrl":null,"payInApp":false,"hasTour":true,"tourPhotoCount":0,"tourUrl":null,"texturedScans":[]},
         {"orderId":"o5","orderNumber":"#LS-MRAT7XNG6","scanId":"s6","scanIds":["s6"],"scanName":"Main floor","projectName":"5 Elm Way","items":["2D Floor Plan"],"status":"refunded","placedAt":"2026-08-01T10:00:00.000Z","deliveredAt":null,"deliveredUrl":null,"deliveryFiles":[],"total":6,"currency":"USD","paid":true,"paymentUrl":null,"payInApp":false,"hasTour":true,"tourPhotoCount":0,"tourUrl":null,"texturedScans":[]},
         {"orderId":"o6","orderNumber":"#LS-MRKFYHRBV","scanId":"s7","scanIds":["s7"],"scanName":"Garage","projectName":"99 Very Long Avenue Name, Springfield Heights","status":"on_hold","placedAt":"2026-07-15T10:00:00.000Z","deliveredAt":null,"deliveredUrl":null,"deliveryFiles":[],"total":0,"currency":"USD","paid":true,"paymentUrl":null,"payInApp":false,"hasTour":false,"tourPhotoCount":0,"tourUrl":null,"texturedScans":[]}
        ]}
        """
        return (try? JSONDecoder().decode(OrdersResponse.self, from: Data(json.utf8)).orders) ?? []
    }()
}
