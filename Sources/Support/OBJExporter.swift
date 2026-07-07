import Foundation
import SceneKit
import SceneKit.ModelIO
import ModelIO

/// Chuyển mô hình USDZ (RoomPlan xuất) sang OBJ ngay trên máy.
/// ModelIO tự ghi kèm file .mtl cùng tên bên cạnh file .obj.
enum OBJExporter {
    static func export(usdzURL: URL, to objURL: URL) throws {
        let scene = try SCNScene(url: usdzURL, options: nil)
        let asset = MDLAsset(scnScene: scene)
        guard MDLAsset.canExportFileExtension("obj") else {
            throw NSError(
                domain: "OBJExporter", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "OBJ export is not supported on this device."]
            )
        }
        try asset.export(to: objURL)
    }
}
