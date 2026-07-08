import SwiftUI

/// Viền màn hình "đèn giao thông" + 1 dòng chữ ngắn — kênh cảnh báo chính khi đang quét.
/// Vàng nhấp nháy = chú ý (đi nhanh/tối/qua cửa), đỏ = nghiêm trọng (mất tracking).
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
        case .doorAhead, .doorTooFast: return "door.left.hand.open"
        case .slowDown: return "tortoise.fill"
        case .turnSlowly: return "arrow.triangle.2.circlepath"
        case .lowLight: return "lightbulb.fill"
        }
    }
}

/// Report card sau khi quét: điểm + hạng + từng lời khuyên. Khách tự học cách quét tốt hơn.
struct ScanReportCardView: View {
    let report: ScanQualityReport
    let onDone: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(spacing: 16) {
                Text(L.t("Scan quality", "Chất lượng bản quét"))
                    .font(.headline)

                ZStack {
                    Circle()
                        .stroke(Color(.tertiarySystemFill), lineWidth: 10)
                    Circle()
                        .trim(from: 0, to: CGFloat(report.score) / 100)
                        .stroke(gradeColor, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("\(report.score)")
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                        Text(report.grade)
                            .font(.headline)
                            .foregroundStyle(gradeColor)
                    }
                }
                .frame(width: 120, height: 120)

                if report.rescanRecommended {
                    Label(
                        L.t(
                            "We recommend rescanning for the most accurate floor plan.",
                            "Nên quét lại để bản vẽ chính xác nhất."
                        ),
                        systemImage: "arrow.counterclockwise"
                    )
                    .font(.footnote.weight(.semibold))
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(Color.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
                }

                if report.deductions.isEmpty {
                    Label(
                        L.t("Excellent scan — nothing to improve!", "Bản quét xuất sắc — không có gì cần cải thiện!"),
                        systemImage: "checkmark.seal.fill"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.green)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(report.deductions.enumerated()), id: \.offset) { _, d in
                                HStack(alignment: .top, spacing: 8) {
                                    Text("−\(trimmed(d.points))")
                                        .font(.footnote.weight(.bold).monospacedDigit())
                                        .foregroundStyle(.orange)
                                        .frame(width: 40, alignment: .trailing)
                                    Text(report.localizedAdvice(d))
                                        .font(.footnote)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            if report.walls.total > 0 {
                                Text(L.t(
                                    "Walls verified against raw LiDAR: \(report.walls.ok) OK · \(report.walls.suspect) suspect · \(report.walls.misaligned) misaligned",
                                    "Đối chiếu tường với LiDAR thô: \(report.walls.ok) đạt · \(report.walls.suspect) nghi ngờ · \(report.walls.misaligned) lệch"
                                ))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.top, 2)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }

                Button {
                    onDone()
                } label: {
                    Text(L.t("Done", "Xong"))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .padding(24)
        }
    }

    private var gradeColor: Color {
        switch report.grade {
        case "A": return .green
        case "B": return .blue
        case "C": return .orange
        default: return .red
        }
    }

    private func trimmed(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}
