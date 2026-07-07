import SwiftUI
import RoomPlan

struct RoomCaptureViewRepresentable: UIViewRepresentable {
    let controller: ScanSessionController

    func makeUIView(context: Context) -> RoomCaptureView {
        controller.captureView
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}
