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
                                Text(String(localized: "How to scan well"))
                                Text(String(localized: "Lighting, walking speed, stairs, and what to do when you finish."))
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
                    Text(String(localized: "Scanning"))
                }
                // Mục thứ hai, TÁCH SECTION RIÊNG chứ ✗ nối vào Section "Quét": hai mục nói về hai
                // việc khác hẳn nhau (cầm máy đi quét · trả tiền và nhận hàng), và khách vào đây
                // tìm một trong hai chứ không đọc lần lượt.
                Section {
                    NavigationLink(value: Topic.orderFAQ) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(localized: "Order Q&A"))
                                Text(String(localized: "How to order, extra scans at no charge, payment, files and revisions."))
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
                    Text(String(localized: "Orders"))
                } footer: {
                    Text(String(localized: "More guides are on the way."))
                }
            }
            .navigationTitle(String(localized: "Learn"))
            .navigationDestination(for: Topic.self) { topic in
                switch topic {
                case .scanGuide:
                    // RUỘT của hướng dẫn (không kèm NavigationStack riêng) — lồng hai
                    // NavigationStack là mất nút Back và có hai thanh tiêu đề chồng nhau.
                    ScanGuideContent()
                        .navigationTitle(String(localized: "How to scan well"))
                        .navigationBarTitleDisplayMode(.inline)
                case .orderFAQ:
                    OrderFAQContent()
                        .navigationTitle(String(localized: "Order Q&A"))
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
    }
}
