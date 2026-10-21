import ImageIO
import PDFKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// F9 "My brand" (2.79, owner 20/10; mockups `PLAN-GIAO-DIEN-mockups\f9\`). Server: order-webapp
// `src/lib/brand.ts`. The customer saves a logo once and a default colour style; every order then
// gets the logo (the order form has a per-order switch) and the form pre-selects the style when
// "Color floor plan" is on. A style never adds a charge and never switches the add-on on by itself.
// Plans carry no logo unless the customer asks (owner, F4): saving one here is that request.

/// The colour add-on and the style a form pre-selects for it. Shared by `MyBrandView`, `OrderSheet`
/// and `AddToOrderSheet`. No agency styles (owner 21/10): a customer who asks gets a custom one.
enum BrandStyles {
    static let colorAddonId = "color"

    /// The saved default style when `list` offers it.
    static func preferred(_ brand: BrandSettings?, in list: [CatalogTemplate]) -> String? {
        guard let id = brand?.styleId, list.contains(where: { $0.id == id }) else { return nil }
        return id
    }
}

/// Account → My brand.
struct MyBrandView: View {
    @State private var catalog: CatalogResponse?
    @State private var brand = BrandSettings.empty
    @State private var loadError: String?
    /// A settings save is out: the controls wait for it (two quick changes must not cross).
    @State private var saving = false
    @State private var uploading = false
    @State private var errorText: String?
    @State private var showLogoMenu = false
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var photoItem: PhotosPickerItem?

    private static let maxLogoBytes = 5 * 1024 * 1024

    private var colorAddon: CatalogAddon? {
        catalog?.addons.first { $0.id == BrandStyles.colorAddonId }
    }

    private var styles: [CatalogTemplate] { colorAddon?.templates ?? [] }

    var body: some View {
        Group {
            if catalog != nil {
                form
            } else if let loadError {
                VStack(spacing: 12) {
                    Text(loadError)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button {
                        self.loadError = nil
                        Task { await load() }
                    } label: {
                        Text(String(localized: "Retry"))
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(FogTint(radius: 12))
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(String(localized: "My brand"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var form: some View {
        List {
            logoSection
            if !styles.isEmpty {
                styleSection
            }
        }
        .fogScreen()
        // Pushed screens get no room from the TabView's inset (`CedarTabBar.reservedHeight`).
        .tabRootBarRoom()
        .confirmationDialog(String(localized: "Your logo"), isPresented: $showLogoMenu, titleVisibility: .hidden) {
            // A picker opened while the action sheet is still leaving can be dropped: one beat later.
            Button(String(localized: "Choose from Photos")) { present { showPhotos = true } }
            Button(String(localized: "Choose from Files")) { present { showFiles = true } }
            if brand.logo != nil {
                Button(String(localized: "Remove logo"), role: .destructive) { removeLogo() }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task { await uploadPhoto(item) }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.png, .jpeg, .svg, .pdf], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await uploadFile(url) }
        }
    }

    // MARK: Sections

    private var logoSection: some View {
        Section {
            Group {
                Button {
                    errorText = nil
                    showLogoMenu = true
                } label: {
                    HStack(spacing: 14) {
                        BrandLogoThumb(logo: brand.logo)
                            .frame(width: 92, height: 56)
                        if uploading {
                            ProgressView()
                            Text(String(localized: "Uploading…"))
                                .foregroundStyle(Color.secondary)
                        } else {
                            Text(brand.logo == nil ? String(localized: "Add your logo") : String(localized: "Change logo"))
                                .fontWeight(.medium)
                                .foregroundStyle(Theme.accentText)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(uploading || saving)
                if brand.logo != nil {
                    Toggle(String(localized: "Add my logo to every plan"), isOn: addLogoBinding)
                        .disabled(uploading || saving)
                }
                if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .listRowBackground(Theme.card)
        } header: {
            Text(String(localized: "Your logo"))
        } footer: {
            Text(brand.logo == nil
                 ? String(localized: "PNG, JPG, SVG or PDF, up to 5 MB.")
                 : String(localized: "You can still turn it off on each order."))
        }
    }

    private var styleSection: some View {
        Section {
            TemplatePicker(templates: styles, selection: styleBinding)
                .disabled(saving || uploading)
                .listRowBackground(Theme.card)
        } header: {
            Text(String(localized: "Default style"))
        } footer: {
            Text(String(localized: "Used when you order a color floor plan. You can still change it on each order."))
        }
    }

    // MARK: Settings

    private var styleBinding: Binding<String?> {
        Binding(
            get: { brand.styleId },
            set: { id in
                guard let id, id != brand.styleId else { return }
                save(["styleId": id], optimistic: brand.with(styleId: .some(id)))
            }
        )
    }

    private var addLogoBinding: Binding<Bool> {
        Binding(
            get: { brand.addLogo },
            set: { on in save(["addLogo": on], optimistic: brand.with(addLogo: on)) }
        )
    }

    private func load() async {
        // `.task` runs again whenever the screen reappears, maybe while a save is out: one load per
        // visit (Retry clears `loadError` and comes here with no catalog).
        guard catalog == nil else { return }
        do {
            let result = try await APIClient.shared.brandCatalog()
            // A server without F9 has no `brand`: nothing here would work.
            guard let saved = result.brand else {
                loadError = String(localized: "Something went wrong. Please try again.")
                return
            }
            brand = saved
            catalog = result
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Shows the change at once; the server's answer replaces it, a refusal puts the old one back.
    private func save(_ fields: [String: Any], optimistic: BrandSettings) {
        guard !saving else { return }
        let before = brand
        brand = optimistic
        saving = true
        errorText = nil
        Task { @MainActor in
            do {
                brand = try await APIClient.shared.saveBrand(fields)
            } catch {
                var back = brand
                if fields["addLogo"] != nil { back = back.with(addLogo: before.addLogo) }
                if fields["styleId"] != nil { back = back.with(styleId: .some(before.styleId)) }
                brand = back
                errorText = message(for: error)
                saving = false
                // The style left the catalog: the list on screen is old, read it again (the
                // controls are free meanwhile).
                if (error as? APIError)?.code == "unknown_style",
                   let fresh = try? await APIClient.shared.brandCatalog() {
                    catalog = fresh
                }
                return
            }
            saving = false
        }
    }

    // MARK: Logo

    private func present(_ open: @escaping () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            open()
        }
    }

    private func uploadPhoto(_ item: PhotosPickerItem) async {
        uploading = true
        errorText = nil
        defer { uploading = false }
        do {
            let maxBytes = Self.maxLogoBytes
            guard let raw = try await item.loadTransferable(type: Data.self),
                  let file = await Task.detached(priority: .userInitiated, operation: {
                      LogoImageEncoder.encode(raw, maxBytes: maxBytes)
                  }).value else {
                errorText = String(localized: "Could not read that photo.")
                return
            }
            brand = try await APIClient.shared.uploadBrandLogo(file.data, fileName: "logo.\(file.ext)", contentType: file.mimeType)
        } catch {
            errorText = message(for: error)
        }
    }

    private func uploadFile(_ url: URL) async {
        uploading = true
        errorText = nil
        defer { uploading = false }
        // Outside the sandbox (fileImporter): ask for access, give it back after.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > Self.maxLogoBytes {
                errorText = String(localized: "This file is larger than 5 MB. Please choose a smaller one.")
                return
            }
            let data = try Data(contentsOf: url)
            guard data.count <= Self.maxLogoBytes else {
                errorText = String(localized: "This file is larger than 5 MB. Please choose a smaller one.")
                return
            }
            brand = try await APIClient.shared.uploadBrandLogo(data, fileName: url.lastPathComponent, contentType: OrderFileItem.mimeType(for: url))
        } catch {
            errorText = message(for: error)
        }
    }

    private func removeLogo() {
        guard !saving, !uploading else { return }
        saving = true
        errorText = nil
        Task { @MainActor in
            do {
                brand = try await APIClient.shared.deleteBrandLogo()
            } catch {
                errorText = message(for: error)
            }
            saving = false
        }
    }

    /// The server's refusals this screen can meet, in the app's language (`code`, ✗ the English text).
    private func message(for error: Error) -> String {
        switch (error as? APIError)?.code {
        case "too_large": return String(localized: "This file is larger than 5 MB. Please choose a smaller one.")
        case "unsupported_type": return String(localized: "Please choose a PNG, JPG, SVG or PDF file.")
        case "unknown_style": return String(localized: "This style is no longer available. Please choose another.")
        // Server-side storage down, or an account the app would not show this screen to.
        case "storage", "email_unverified": return String(localized: "Something went wrong. Please try again.")
        default: return error.localizedDescription
        }
    }
}

/// The saved logo as a tile: the picture (PNG / JPEG, the first page of a PDF) on white, as it sits
/// on a plan; SVG shows a file mark (iOS has no SVG decoder). No logo = the "add" tile.
struct BrandLogoThumb: View {
    let logo: BrandLogo?
    @State private var pdfImage: UIImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        ZStack {
            if let logo {
                shape.fill(Color.white)
                content(logo)
                    .padding(6)
            } else {
                shape.fill(Theme.thumbBg)
                Image(systemName: "photo.badge.plus")
                    .font(.title3)
                    .foregroundStyle(Theme.accentText)
            }
        }
        .overlay {
            if logo == nil {
                shape.strokeBorder(Theme.ghostBorder, style: StrokeStyle(lineWidth: 1.5, dash: [4]))
            } else {
                shape.strokeBorder(Theme.ghostBorder)
            }
        }
        .accessibilityHidden(true)
        .task(id: logo?.url) { await loadPDF() }
    }

    @ViewBuilder
    private func content(_ logo: BrandLogo) -> some View {
        switch logo.contentType {
        case "image/png", "image/jpeg":
            AsyncImage(url: URL(string: logo.url)) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                } else if phase.error != nil {
                    fileMark(logo)
                } else {
                    ProgressView()
                        .tint(Color(white: 0.45))
                }
            }
        case "application/pdf":
            if let pdfImage {
                Image(uiImage: pdfImage).resizable().scaledToFit()
            } else {
                fileMark(logo)
            }
        default:
            fileMark(logo)
        }
    }

    private func fileMark(_ logo: BrandLogo) -> some View {
        VStack(spacing: 2) {
            Image(systemName: "doc.richtext")
            Text(verbatim: logo.contentType == "image/svg+xml" ? "SVG" : (logo.contentType == "application/pdf" ? "PDF" : ""))
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(Color(white: 0.45))
    }

    /// First page of a PDF logo, drawn small: downloaded (≤ 5 MB) once per URL and app run — the
    /// tile reappears often (the order form's row, every pop back to My brand).
    private func loadPDF() async {
        guard let logo, logo.contentType == "application/pdf", let url = URL(string: logo.url) else {
            pdfImage = nil
            return
        }
        if let cached = Self.pdfThumbs.object(forKey: logo.url as NSString) {
            pdfImage = cached
            return
        }
        pdfImage = nil
        guard let download = try? await URLSession.shared.data(from: url),
              let page = PDFDocument(data: download.0)?.page(at: 0) else { return }
        let thumb = page.thumbnail(of: CGSize(width: 240, height: 150), for: .mediaBox)
        Self.pdfThumbs.setObject(thumb, forKey: logo.url as NSString)
        pdfImage = thumb
    }

    private static let pdfThumbs = NSCache<NSString, UIImage>()
}

/// A photo from the library as a logo file: at most 2048 px on the long side, upright (the photo's
/// orientation applied); PNG when it has transparency (a logo cut-out), else JPEG; a transparent
/// one too big as PNG goes onto white first (✗ black corners in a JPEG). ImageIO decodes only what
/// 2048 px needs (a 48 MP photo would be ~200 MB as a full UIImage). Runs off the main thread.
enum LogoImageEncoder {
    struct File {
        let data: Data
        let mimeType: String
        let ext: String
    }

    static func encode(_ raw: Data, maxBytes: Int) -> File? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let source = CGImageSourceCreateWithData(raw as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = UIImage(cgImage: cgImage)
        let alpha = hasAlpha(cgImage)
        if alpha, let png = image.pngData(), png.count <= maxBytes {
            return File(data: png, mimeType: "image/png", ext: "png")
        }
        let opaque = alpha ? onWhite(image) : image
        for quality in [0.9, 0.7, 0.5] as [CGFloat] {
            if let jpeg = opaque.jpegData(compressionQuality: quality), jpeg.count <= maxBytes {
                return File(data: jpeg, mimeType: "image/jpeg", ext: "jpg")
            }
        }
        return nil
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast: return true
        default: return false
        }
    }

    private static func onWhite(_ image: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: image.size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: image.size))
            image.draw(at: .zero)
        }
    }
}

extension BrandSettings {
    /// A copy with some fields changed (`.some(nil)` clears a style).
    func with(addLogo: Bool? = nil, styleId: String?? = nil) -> BrandSettings {
        BrandSettings(logo: logo, addLogo: addLogo ?? self.addLogo, styleId: styleId ?? self.styleId)
    }
}
