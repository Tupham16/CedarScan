import SwiftUI

/// Overlay đặt tên bản quét (tầng/khu nào) — tách riêng để các luồng quét dùng chung
/// (hiện dùng ở MeshScanFlowView; ScanFlowView có bản riêng từ trước).
struct ScanNameOverlay: View {
    @Binding var name: String
    let subtitle: String
    let suggestions: [String]
    let onSave: () -> Void
    let onBack: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 14) {
                Text(L.t("Name this scan", "Đặt tên bản quét"))
                    .font(.headline)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                suggestionGrid

                TextField(L.t("Or type a name (e.g. Floor 1)", "Hoặc tự gõ tên (vd Floor 1)"), text: $name)
                    .textFieldStyle(.roundedBorder)

                Button(action: onSave) {
                    Text(L.t("Save scan", "Lưu bản quét"))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)

                Button(L.t("Back", "Quay lại"), action: onBack)
                    .font(.subheadline)
            }
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .padding(24)
        }
    }

    private var suggestionGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 8) {
            ForEach(suggestions, id: \.self) { suggestion in
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
