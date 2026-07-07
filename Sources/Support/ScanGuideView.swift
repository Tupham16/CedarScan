import SwiftUI

/// Hướng dẫn quét đẹp — hiện lần đầu trước khi quét + mở lại được từ nút (?).
struct ScanGuideView: View {
    @Environment(\.dismiss) private var dismiss
    /// Có thì hiện nút "Bắt đầu quét" (luồng lần đầu); nil = chỉ xem.
    var onStart: (() -> Void)? = nil

    static let seenKey = "hasSeenScanGuide"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    tipSection(
                        icon: "checklist",
                        title: L.t("Before you scan", "Trước khi quét"),
                        tips: [
                            L.t("Turn on all the lights and open interior doors.",
                                "Bật hết đèn, mở các cửa trong nhà."),
                            L.t("Clear walking paths — you will walk through every room.",
                                "Dọn lối đi — bạn sẽ đi qua mọi phòng."),
                            L.t("A full scan takes 5–15 minutes. Make sure you have battery.",
                                "Một lần quét mất 5–15 phút. Nhớ đủ pin."),
                        ]
                    )
                    tipSection(
                        icon: "figure.walk",
                        title: L.t("While scanning", "Trong lúc quét"),
                        tips: [
                            L.t("Hold the phone at chest height, tilted slightly down.",
                                "Cầm máy ngang ngực, hơi chúc xuống."),
                            L.t("Walk SLOWLY along the walls. Slow is accurate.",
                                "Đi CHẬM men theo tường. Chậm = chính xác."),
                            L.t("Point the camera at every wall, corner, door and window.",
                                "Hướng camera vào mọi bức tường, góc phòng, cửa và cửa sổ."),
                            L.t("Avoid pointing at mirrors and large glass for too long.",
                                "Tránh chĩa lâu vào gương và kính lớn."),
                        ]
                    )
                    tipSection(
                        icon: "door.left.hand.open",
                        title: L.t("Moving between rooms — MOST IMPORTANT", "Đi qua phòng khác — QUAN TRỌNG NHẤT"),
                        tips: [
                            L.t("Walk through doorways EXTRA slowly, keeping the door frame in view.",
                                "Bước qua cửa THẬT chậm, giữ khung cửa trong khung hình."),
                            L.t("This keeps rooms aligned straight with each other on the floor plan.",
                                "Làm vậy các phòng sẽ thẳng hàng với nhau trên mặt bằng."),
                            L.t("Tap \"Done with this room\" then \"Scan next room\" — don't close the app mid-scan.",
                                "Bấm \"Xong phòng này\" rồi \"Quét phòng tiếp theo\" — đừng tắt app giữa chừng."),
                        ]
                    )
                    tipSection(
                        icon: "building.2",
                        title: L.t("Homes with several floors", "Nhà nhiều tầng"),
                        tips: [
                            L.t("Scan ONE floor per scan, and name it (Floor 1, Floor 2, Basement…).",
                                "Mỗi tầng quét MỘT bản riêng, đặt tên rõ (Floor 1, Floor 2, Basement…)."),
                            L.t("Create a Property for the home and keep all floors inside it, then order them together.",
                                "Tạo Dự án cho căn nhà, gom các tầng vào đó rồi đặt hàng chung."),
                        ]
                    )

                    if let onStart {
                        Button {
                            UserDefaults.standard.set(true, forKey: Self.seenKey)
                            dismiss()
                            onStart()
                        } label: {
                            Text(L.t("Got it — start scanning", "Hiểu rồi — bắt đầu quét"))
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 4)
                    }
                }
                .padding(20)
            }
            .navigationTitle(L.t("How to scan well", "Cách quét đẹp"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L.t("Close", "Đóng")) {
                        UserDefaults.standard.set(true, forKey: Self.seenKey)
                        dismiss()
                    }
                }
            }
        }
    }

    private func tipSection(icon: String, title: String, tips: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.headline)
            ForEach(tips, id: \.self) { tip in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                        .padding(.top, 2)
                    Text(tip)
                        .font(.subheadline)
                }
            }
        }
    }
}
