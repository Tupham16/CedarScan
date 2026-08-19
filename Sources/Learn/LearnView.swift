import SwiftUI

/// Tab **Learn** — nơi gom mọi thứ "học cách dùng app".
///
/// Hai mục: "Cách quét đẹp" (trước 2026-07-23 nó là nút dấu **?** ở góc trên trái màn hình chính;
/// nút đó đã gỡ để trên cùng chỉ còn tiêu đề + ô tìm kiếm) và "Hỏi đáp về đơn hàng" (chủ app đặt
/// 19/08 — xem `OrderFAQContent`).
///
/// Khuôn đã dùng đúng như dự tính: thêm mục mới = thêm một `case` vào `Topic`, một
/// `NavigationLink` và một nhánh `switch`. ✗ nhét NavigationStack riêng vào màn con — lồng hai
/// NavigationStack là mất nút Back và có hai thanh tiêu đề chồng nhau.
struct LearnView: View {
    /// Đích điều hướng của tab này. Dùng enum + `navigationDestination` thay vì
    /// `NavigationLink { view }` để mỗi mục mới sau này chỉ phải thêm đúng một `case`.
    private enum Topic: Hashable {
        case scanGuide
        case orderFAQ
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink(value: Topic.scanGuide) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L.t("How to scan well", "Cách quét đẹp"))
                                Text(L.t(
                                    "Lighting, walking speed, stairs, and what to do when you finish.",
                                    "Ánh sáng, tốc độ đi, cầu thang, và việc phải làm khi quét xong."
                                ))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "viewfinder")
                                .foregroundStyle(.tint)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text(L.t("Scanning", "Quét"))
                }
                // Mục thứ hai, TÁCH SECTION RIÊNG chứ ✗ nối vào Section "Quét": hai mục nói về hai
                // việc khác hẳn nhau (cầm máy đi quét · trả tiền và nhận hàng), và khách vào đây
                // tìm một trong hai chứ không đọc lần lượt.
                Section {
                    NavigationLink(value: Topic.orderFAQ) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L.t("Order Q&A", "Hỏi đáp về đơn hàng"))
                                Text(L.t(
                                    "How to order, extra scans at no charge, payment, files and revisions.",
                                    "Cách đặt hàng, gửi bổ sung không mất phí, thanh toán, file nhận được và yêu cầu sửa."
                                ))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        } icon: {
                            // "questionmark.circle" — SF Symbol có từ iOS 13, chắc chắn tồn tại
                            // trên target iOS 17. ⚠ Tên SF Symbol SAI không gây lỗi compile: CI
                            // vẫn xanh và chỉ lộ ra ô trống lúc sideload (bẫy đã ghi ở
                            // `ScanGuideView.floorsSection`) — nên chỗ này chọn cái cũ, chắc chắn.
                            Image(systemName: "questionmark.circle")
                                .foregroundStyle(.tint)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text(L.t("Orders", "Đơn hàng"))
                } footer: {
                    Text(L.t(
                        "More guides are on the way.",
                        "Các hướng dẫn khác sẽ được bổ sung."
                    ))
                }
            }
            .navigationTitle(L.t("Learn", "Learn"))
            .navigationDestination(for: Topic.self) { topic in
                switch topic {
                case .scanGuide:
                    // RUỘT của hướng dẫn (không kèm NavigationStack riêng) — lồng hai
                    // NavigationStack là mất nút Back và có hai thanh tiêu đề chồng nhau.
                    ScanGuideContent()
                        .navigationTitle(L.t("How to scan well", "Cách quét đẹp"))
                        .navigationBarTitleDisplayMode(.inline)
                case .orderFAQ:
                    OrderFAQContent()
                        .navigationTitle(L.t("Order Q&A", "Hỏi đáp về đơn hàng"))
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
    }
}
