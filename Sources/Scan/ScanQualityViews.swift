import SwiftUI

/// Viền màn hình "đèn giao thông" + 1 dòng chữ ngắn — kênh cảnh báo chính khi đang quét.
/// Vàng nhấp nháy = chú ý (đi nhanh/xoay nhanh/thiếu sáng/dí quá gần/máy nóng),
/// đỏ = nghiêm trọng (mất tracking).
/// Không hiện gì khi quét tốt — màn hình sạch.
struct QualityAlertOverlay: View {
    @ObservedObject var monitor: ScanQualityMonitor
    @State private var pulsing = false

    var body: some View {
        ZStack {
            if let alert = monitor.alert {
                let color: Color = alert.severity == .critical ? .red : .yellow

                Rectangle()
                    .strokeBorder(color.opacity(pulsing ? 0.9 : 0.45), lineWidth: 6)
                    .ignoresSafeArea()
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulsing)
                    .onAppear { pulsing = true }
                    .onDisappear { pulsing = false }

                VStack {
                    Label(alert.message, systemImage: icon(for: alert.code))
                        .font(.title3.weight(.bold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(color.opacity(0.85), in: Capsule())
                        .foregroundStyle(alert.severity == .critical ? Color.white : Color.black)
                        .padding(.top, 64)
                    Spacer()
                }
                .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.25), value: monitor.alert)
    }

    private func icon(for code: QualityAlert.Code) -> String {
        switch code {
        case .trackingLost: return "exclamationmark.triangle.fill"
        case .slowDown: return "tortoise.fill"
        case .turnSlowly: return "arrow.triangle.2.circlepath"
        case .lowLight: return "lightbulb.fill"
        case .overheating: return "thermometer.high"
        case .tooClose: return "minus.magnifyingglass"
        }
    }
}
