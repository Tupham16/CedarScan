import SwiftUI

/// Tab **Learn** — nơi gom mọi thứ "học cách dùng app".
///
/// Hiện có đúng một mục: "Cách quét đẹp" (trước 2026-07-23 nó là nút dấu **?** ở góc trên trái màn
/// hình chính; nút đó đã gỡ để trên cùng chỉ còn tiêu đề + ô tìm kiếm). Chủ app sẽ bổ sung các mục
/// khác sau, nên màn này cố ý là một `List` có Section — thêm mục mới chỉ là thêm một `NavigationLink`.
struct LearnView: View {
    /// Đích điều hướng của tab này. Dùng enum + `navigationDestination` thay vì
    /// `NavigationLink { view }` để mỗi mục mới sau này chỉ phải thêm đúng một `case`.
    private enum Topic: Hashable {
        case scanGuide
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
                }
            }
        }
    }
}
