import SwiftUI

/// Overlay đặt tên bản quét (tầng/khu nào). Dùng ở MeshScanFlowView — luồng quét duy nhất
/// còn lại sau khi gỡ RoomPlan.
struct ScanNameOverlay: View {
    @Binding var name: String
    let subtitle: String
    /// Nút bấm sẵn, LUÔN hiện — danh sách ngắn chủ app chốt 13/08.
    let suggestions: [String]
    /// Kho tên để GỢI Ý THEO CHỮ ĐANG GÕ (chủ app 13/08: *"khi gõ hãy hiển thị gợi ý để khách
    /// không phải gõ toàn bộ"*). Dài hơn `suggestions` nhiều và CỐ Ý không hiện sẵn: hiện cả 17
    /// cái là màn hình phình ra, mà chúng chỉ có ích khi khách đã gõ vài chữ.
    let typeAheadSuggestions: [String]
    let onSave: () -> Void
    let onBack: () -> Void

    /// Số gợi ý-theo-chữ tối đa hiện cùng lúc. ✗ nâng: thẻ này nằm giữa màn và bàn phím đang mở
    /// đẩy nó lên; mỗi hàng thêm là một hàng có thể bị đẩy khuất. 4 = tối đa 2 hàng.
    private static let maxTypeAhead = 4

    /// Tên khớp với chữ đang gõ: khớp ĐẦU CHUỖI trước ("gar" → Garage), rồi mới tới khớp GIỮA
    /// ("floor" → Ground floor, First floor…) để cái khách đang gõ dở luôn đứng đầu.
    /// Bỏ dấu + bỏ hoa thường khi so: khách gõ tiếng Việt không dấu vẫn ra.
    ///
    /// Rỗng khi ô trống (chưa gõ thì chưa gợi ý được gì) và khi chữ đã gõ TRÙNG KHÍT tên duy
    /// nhất còn khớp — lúc đó gợi ý chỉ là lặp lại chính nó, giữ lại là thẻ nhấp nháy một hàng
    /// thừa đúng lúc khách sắp bấm Lưu.
    private var typeAheadMatches: [String] {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return [] }
        let starts = typeAheadSuggestions.filter {
            $0.range(of: key, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil
        }
        let contains = typeAheadSuggestions.filter {
            $0.range(of: key, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                && !starts.contains($0)
        }
        let matches = starts + contains
        if matches.count == 1,
           matches[0].compare(key, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return []
        }
        return Array(matches.prefix(Self.maxTypeAhead))
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 14) {
                Text(String(localized: "Name this scan"))
                    .font(.headline)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                suggestionGrid

                TextField(
                    String(localized: "Or type a name (e.g. Attic)"),
                    text: $name
                )
                .textFieldStyle(.roundedBorder)
                // Tên riêng của khu vực, ✗ câu tiếng Anh: TẮT sửa lỗi tự động để bàn phím thôi
                // "chữa" chữ khách vừa gõ hoặc vừa chọn từ gợi ý. Viết hoa thì KHÔNG tắt — để
                // `.words` cho giống ô địa chỉ (`ScanAddressView`), tên khu vực vốn viết hoa đầu
                // từ. ⚠ Hệ quả đã biết: tự gõ ra "Ground Floor" trong khi thẻ gợi ý ghi "Ground
                // floor" — danh sách giữ NGUYÊN cách viết hoa của chủ app nên hai đường lệch nhau.
                .autocorrectionDisabled()
                .textInputAutocapitalization(.words)

                // Gợi ý theo chữ đang gõ — CHỈ hiện khi có thứ để gợi. Nằm ngay dưới ô nhập
                // (đúng chỗ mắt đang nhìn), ✗ trộn vào lưới nút sẵn ở trên: hai vai khác nhau.
                if !typeAheadMatches.isEmpty {
                    chipGrid(typeAheadMatches)
                }

                Button(action: onSave) {
                    Text(String(localized: "Save scan"))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)

                Button(String(localized: "Back"), action: onBack)
                    .font(.subheadline)
            }
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .padding(24)
        }
    }

    private var suggestionGrid: some View {
        chipGrid(suggestions)
    }

    private func chipGrid(_ items: [String]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 8) {
            ForEach(items, id: \.self) { suggestion in
                SuggestionChip(title: suggestion, isSelected: name == suggestion) {
                    name = suggestion
                }
            }
        }
    }
}

private struct SuggestionChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let background: Color = isSelected ? Color.accentColor.opacity(0.2) : Color(.tertiarySystemFill)
        return Button(action: action) {
            Text(title)
                .font(.subheadline)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(background, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
