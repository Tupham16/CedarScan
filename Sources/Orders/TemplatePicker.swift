import SwiftUI

/// Picker mẫu cho color/siteplan: hàng thumbnail cuộn NGANG + bản PHÓNG TO mẫu đang chọn để khách
/// nhìn rõ (chủ app chốt 2026-07-21). Shared by the order form (`OrderSheet`) and "Add to this
/// order" (`AddToOrderSheet`, Orders v2 C) — moved here unchanged from `OrderSheet`.
struct TemplatePicker: View {
    let templates: [CatalogTemplate]
    /// The picked template id (nil = none yet).
    @Binding var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(templates) { tpl in
                        Button {
                            selection = tpl.id
                        } label: {
                            VStack(spacing: 4) {
                                templateThumb(tpl)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(
                                            selection == tpl.id ? Theme.accentText : Theme.ghostBorder,
                                            lineWidth: selection == tpl.id ? 2.5 : 1
                                        )
                                    )
                                Text(tpl.name)
                                    .font(.caption2)
                                    .fontWeight(selection == tpl.id ? .semibold : .regular)
                                    .foregroundStyle(selection == tpl.id ? Theme.accentText : Color.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
            if let selId = selection, let sel = templates.first(where: { $0.id == selId }) {
                templateLargePreview(sel)
            }
        }
    }

    /// Bản phóng to của mẫu đang chọn: ảnh cao ~200pt (scaledToFit, không méo — hợp mọi tỉ lệ), hoặc
    /// ô placeholder khi chưa có ảnh thật.
    @ViewBuilder
    private func templateLargePreview(_ tpl: CatalogTemplate) -> some View {
        if let s = tpl.imageUrl, !s.isEmpty, let url = URL(string: s) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                } else if phase.error != nil {
                    Color.secondary.opacity(0.1)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 200)
            .background(Theme.thumbBg)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.1))
                .frame(maxWidth: .infinity)
                .frame(height: 150)
                .overlay(
                    VStack(spacing: 6) {
                        Image(systemName: "paintpalette").font(.title2)
                        Text(tpl.name).font(.subheadline.weight(.medium))
                        Text(String(localized: "Preview image coming soon"))
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                )
        }
    }

    /// Ô ảnh mẫu 64pt. Có imageUrl → AsyncImage; chưa có (placeholder) → ô màu + icon.
    @ViewBuilder
    private func templateThumb(_ tpl: CatalogTemplate) -> some View {
        if let s = tpl.imageUrl, !s.isEmpty, let url = URL(string: s) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Color.secondary.opacity(0.12)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
                .frame(width: 64, height: 64)
                .overlay(Image(systemName: "paintpalette").foregroundStyle(.secondary))
        }
    }
}
