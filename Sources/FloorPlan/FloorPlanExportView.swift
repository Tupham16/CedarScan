import SwiftUI

/// Bản mặt bằng dùng để xuất ảnh PNG: nền trắng, tiêu đề và diện tích.
struct FloorPlanExportView: View {
    let model: FloorPlanModel
    let title: String

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.system(size: 40, weight: .bold))
                .foregroundColor(.black)
            if model.areaSquareMeters > 0 {
                Text(String(format: "Diện tích: %.1f m²", model.areaSquareMeters))
                    .font(.system(size: 26))
                    .foregroundColor(.gray)
            }
            FloorPlanCanvas(model: model, backgroundColor: .white)
            Text("Tạo bằng CedarScan")
                .font(.system(size: 18))
                .foregroundColor(.gray)
        }
        .padding(48)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }
}
