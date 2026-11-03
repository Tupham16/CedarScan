import SwiftUI

/// Picker mẫu cho color/siteplan: hàng thumbnail cuộn NGANG + bản PHÓNG TO mẫu đang chọn để khách
/// nhìn rõ (chủ app chốt 2026-07-21). Shared by the order form (`OrderSheet`) and "Add to this
/// order" (`AddToOrderSheet`, Orders v2 C) — moved here unchanged from `OrderSheet`.
struct TemplatePicker: View {
    let templates: [CatalogTemplate]
    /// The picked template id (nil = none yet).
    @Binding var selection: String?
    /// F9: a style picked before the row appeared (My brand's, the last order's) can sit past the
    /// screen edge — the row opens scrolled to it.
    @State private var scrolledTo: String?
    /// F9b: first pages of PDF own styles, by URL (`BrandLogoThumb.pdfPage`).
    @State private var pdfPages: [String: UIImage] = [:]

    private static let pdfType = "application/pdf"

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
                                Text(name(tpl))
                                    .font(.caption2)
                                    .fontWeight(selection == tpl.id ? .semibold : .regular)
                                    .foregroundStyle(selection == tpl.id ? Theme.accentText : Color.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        // N17: the template's name (the thumbnail has none) and which one is
                        // chosen — the blue ring alone said it to nobody using VoiceOver. F9b: the
                        // B&W tile in words ("S/W" would be read letter by letter).
                        .accessibilityLabel(tpl.id == BrandStyles.bwId ? String(localized: "Black & white") : name(tpl))
                        .accessibilityAddTraits(selection == tpl.id ? AccessibilityTraits.isSelected : AccessibilityTraits())
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, 4)
            }
            .scrollPosition(id: $scrolledTo, anchor: .center)
            .onAppear { scrolledTo = selection }
            if let selId = selection, let sel = templates.first(where: { $0.id == selId }) {
                templateLargePreview(sel)
            }
        }
        .task(id: pdfURLs) { await loadPDFs() }
    }

    /// F9b: the customer's own style reads "Your style" in the app's language (the server's is English).
    private func name(_ tpl: CatalogTemplate) -> String {
        tpl.id == BrandStyles.ownStyleId ? String(localized: "Your style") : tpl.name
    }

    /// F9b: an own style can be a PDF, which `AsyncImage` cannot show.
    private var pdfURLs: [String] {
        templates.compactMap { $0.contentType == Self.pdfType ? $0.imageUrl : nil }
    }

    private func loadPDFs() async {
        for url in pdfURLs where pdfPages[url] == nil {
            let page = await BrandLogoThumb.pdfPage(url, box: CGSize(width: 480, height: 480))
            if Task.isCancelled { return }
            pdfPages[url] = page
        }
    }

    /// A PDF's first page once drawn; a file mark until then, or when it cannot be read.
    @ViewBuilder
    private func pdfPage(_ tpl: CatalogTemplate, fill: Bool) -> some View {
        if let page = tpl.imageUrl.flatMap({ pdfPages[$0] }) {
            Image(uiImage: page).resizable().aspectRatio(contentMode: fill ? .fill : .fit)
        } else {
            Image(systemName: "doc.richtext")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.secondary.opacity(0.12))
        }
    }

    /// Bản phóng to của mẫu đang chọn: ảnh cao ~200pt (scaledToFit, không méo — hợp mọi tỉ lệ), hoặc
    /// ô placeholder khi chưa có ảnh thật.
    @ViewBuilder
    private func templateLargePreview(_ tpl: CatalogTemplate) -> some View {
        if tpl.contentType == Self.pdfType {
            pdfPage(tpl, fill: false)
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .background(Theme.thumbBg)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else if let s = tpl.imageUrl, !s.isEmpty, let url = URL(string: s) {
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
                        Text(name(tpl)).font(.subheadline.weight(.medium))
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
        if tpl.contentType == Self.pdfType {
            pdfPage(tpl, fill: true)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else if let s = tpl.imageUrl, !s.isEmpty, let url = URL(string: s) {
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
