import ImageIO
import PDFKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// F9 "My brand" (2.79, owner 20/10; mockups `PLAN-GIAO-DIEN-mockups\f9\`). Server: order-webapp
// `src/lib/brand.ts`. The customer saves a logo once and a default colour style; every order then
// gets the logo (the order form has a per-order switch) and the form pre-selects the style when
// "Color floor plan" is on.
// Plans carry no logo unless the customer asks (owner, F4): saving one here is that request.
//
// F9b "Order defaults" (2.79.3, owner 03/11; mockups `PLAN-GIAO-DIEN-mockups\f9b\`): the screen also
// sets what every order form starts with (presets): the colour style or Black & white (= no colour),
// 3D, site plan + its style, CAD; ✗ express. Saved presets win; never saved = the last order's
// choices, as before (server `withPresets`). A colour default now ticks Color (reverses F9). The
// customer can upload their own style: the colour style "custom" of their catalog, usable at once.
// Colour is free since 03/11: every price shown here is the catalog's, ✗ written in the app.

/// The colour add-on and the style a form pre-selects for it. Shared by `MyBrandView`, `OrderSheet`
/// and `AddToOrderSheet`. No agency styles (owner 21/10): a customer who asks gets a custom one.
enum BrandStyles {
    static let colorAddonId = "color"
    /// F9b: Order defaults' Black & white tile = no colour (the plain 2D plan). App-only, never sent.
    static let bwId = "bw"
    /// F9b: the customer's own style in their catalog (server `OWN_STYLE_ID`).
    static let ownStyleId = "custom"
    /// F9b: what presets may hold (server `PRESET_ADDONS`; ✗ express: it depends on the home).
    static let presetAddonIds: Set<String> = [colorAddonId, "siteplan", "dwg"]

    /// The saved default style when `list` offers it.
    static func preferred(_ brand: BrandSettings?, in list: [CatalogTemplate]) -> String? {
        guard let id = brand?.styleId, list.contains(where: { $0.id == id }) else { return nil }
        return id
    }
}

/// What a new order form starts with: packages, add-ons and their styles.
struct OrderPresets: Equatable {
    var packageIds: Set<String>
    var addonIds: Set<String>
    /// addonId → templateId, for the chosen add-ons with styles.
    var templates: [String: String]
}

extension OrderPresets {
    /// The catalog's `defaults` (F9b: the saved presets, else the last order's choices) checked
    /// against what it sells now. `OrderSheet.loadCatalog` and Order defaults both read this one, so
    /// the screen shows what the form opens with.
    init(_ catalog: CatalogResponse) {
        // Điền mặc định gói: `packageIds` (app mới) > `packageId` (default cũ) > gói default > gói đầu.
        let d = catalog.defaults
        let validPkgIds = Set(catalog.packages.map(\.id))
        var pkgs = Set((d?.packageIds ?? []).filter { validPkgIds.contains($0) })
        if pkgs.isEmpty, let saved = d?.packageId, validPkgIds.contains(saved) {
            pkgs = [saved]
        }
        if pkgs.isEmpty, let def = catalog.packages.first(where: { $0.isDefault })?.id ?? catalog.packages.first?.id {
            pkgs = [def]
        }
        let validAddonIds = Set(catalog.addons.map(\.id))
        let addons = Set((d?.addonIds ?? []).filter { validAddonIds.contains($0) })
        // Mẫu mặc định cho addon đã chọn sẵn + có picker: lấy mẫu lần trước nếu còn hợp lệ, không
        // thì mẫu đầu. Addon chưa chọn thì để trống — tự chọn mẫu đầu khi khách bật (xem toggle).
        // F9: the saved default style comes first for colour.
        var tpls: [String: String] = [:]
        for addon in catalog.addons {
            guard let templates = addon.templates, !templates.isEmpty, addons.contains(addon.id) else { continue }
            let saved = d?.templates?[addon.id]
            let brandStyle = addon.id == BrandStyles.colorAddonId ? BrandStyles.preferred(catalog.brand, in: templates) : nil
            tpls[addon.id] = brandStyle ?? ((saved != nil && templates.contains { $0.id == saved }) ? saved! : templates.first!.id)
        }
        self.init(packageIds: pkgs, addonIds: addons, templates: tpls)
    }

    /// PUT account/brand `presets`: only what presets may hold, in catalog order (the server gives
    /// apps before multi-package `packageIds[0]` as their one package).
    func json(in catalog: CatalogResponse) -> [String: Any] {
        let addons = catalog.addons.map(\.id).filter { addonIds.contains($0) && BrandStyles.presetAddonIds.contains($0) }
        return [
            "packageIds": catalog.packages.map(\.id).filter { packageIds.contains($0) },
            "addonIds": addons,
            "templates": templates.filter { addons.contains($0.key) },
        ]
    }
}

/// Account → Order defaults ("My brand" until 2.79.3).
struct MyBrandView: View {
    /// The parts of the screen: where a refusal shows, which file goes up.
    private enum Part {
        case logo, style, extras
    }

    @State private var catalog: CatalogResponse?
    @State private var brand = BrandSettings.empty
    /// F9b: what every order form starts with, as the form opens. Each change saves the whole set.
    @State private var presets = OrderPresets(packageIds: [], addonIds: [], templates: [:])
    @State private var loadError: String?
    /// A settings save is out: the controls wait for it (two quick changes must not cross).
    @State private var saving = false
    /// The file going up (logo or own style); the controls wait for it too.
    @State private var uploading: Part?
    /// The last refusal, shown in the section of the control that met it.
    @State private var problem: (part: Part, text: String)?
    /// The file menu and pickers below serve the logo and the own style: the one asked for.
    @State private var fileTarget = Part.logo
    @State private var showFileMenu = false
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var photoItem: PhotosPickerItem?

    private static let maxFileBytes = 5 * 1024 * 1024

    private var busy: Bool { saving || uploading != nil }

    private var colorAddon: CatalogAddon? {
        catalog?.addons.first { $0.id == BrandStyles.colorAddonId }
    }

    /// The colour styles as the server lists them for this customer (`withOwnStyle`): "Your style"
    /// first while a sample is saved — made from `brand`, so an upload or a removal shows at once.
    private var styles: [CatalogTemplate] {
        let listed = (colorAddon?.templates ?? []).filter { $0.id != BrandStyles.ownStyleId }
        guard !listed.isEmpty, let sample = brand.styleSample else { return listed }
        let own = CatalogTemplate(id: BrandStyles.ownStyleId, name: String(localized: "Your style"),
                                  imageUrl: sample.url, contentType: sample.contentType)
        return [own] + listed
    }

    /// F9b: no colour = the plain 2D plan, first in the row (its picture is the server's).
    private var bwTile: CatalogTemplate {
        CatalogTemplate(id: BrandStyles.bwId, name: String(localized: "B&W"), imageUrl: colorAddon?.bwImageUrl, contentType: nil)
    }

    /// The package every order has unless the customer picks others (2D).
    private var basePackageId: String? {
        guard let packages = catalog?.packages else { return nil }
        return (packages.first(where: \.isDefault) ?? packages.first)?.id
    }

    /// "Add to every order": the other packages (3D) …
    private var extraPackages: [CatalogPackage] {
        (catalog?.packages ?? []).filter { $0.id != basePackageId }
    }

    /// … and the add-ons presets may hold besides colour (site plan, CAD), as the catalog sells them.
    private var extraAddons: [CatalogAddon] {
        (catalog?.addons ?? []).filter { $0.id != BrandStyles.colorAddonId && BrandStyles.presetAddonIds.contains($0.id) }
    }

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
        .navigationTitle(String(localized: "Order defaults"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var form: some View {
        List {
            logoSection
            if !styles.isEmpty {
                styleSection
            }
            if !extraPackages.isEmpty || !extraAddons.isEmpty {
                extrasSection
            }
        }
        .fogScreen()
        // Pushed screens get no room from the TabView's inset (`CedarTabBar.reservedHeight`).
        .tabRootBarRoom()
        .confirmationDialog(fileTarget == .style ? String(localized: "Your style") : String(localized: "Your logo"),
                            isPresented: $showFileMenu, titleVisibility: .hidden) {
            // A picker opened while the action sheet is still leaving can be dropped: one beat later.
            Button(String(localized: "Choose from Photos")) { present { showPhotos = true } }
            Button(String(localized: "Choose from Files")) { present { showFiles = true } }
            if fileTarget == .logo, brand.logo != nil {
                Button(String(localized: "Remove logo"), role: .destructive) { removeLogo() }
            }
            if fileTarget == .style, brand.styleSample != nil {
                Button(String(localized: "Remove your style"), role: .destructive) { removeStyle() }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            let part = fileTarget
            Task { await uploadPhoto(item, as: part) }
        }
        // An own style is a plan to look at: no SVG (iOS cannot show one; the server refuses it).
        .fileImporter(isPresented: $showFiles,
                      allowedContentTypes: fileTarget == .style ? [.png, .jpeg, .pdf] : [.png, .jpeg, .svg, .pdf],
                      allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let part = fileTarget
            Task { await uploadFile(url, as: part) }
        }
    }

    // MARK: Sections

    private var logoSection: some View {
        Section {
            Group {
                Button {
                    openFileMenu(.logo)
                } label: {
                    HStack(spacing: 14) {
                        BrandLogoThumb(logo: brand.logo)
                            .frame(width: 92, height: 56)
                        if uploading == .logo {
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
                .disabled(busy)
                if brand.logo != nil {
                    Toggle(String(localized: "Add my logo to every plan"), isOn: addLogoBinding)
                        .disabled(busy)
                }
                problemRow(.logo)
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
            Group {
                TemplatePicker(templates: [bwTile] + styles, selection: styleBinding)
                ownStyleRow
                problemRow(.style)
            }
            .disabled(busy)
            .listRowBackground(Theme.card)
        } header: {
            Text(String(localized: "Default style"))
        } footer: {
            // A price sentence: read whole in every language (trap #44).
            WrappedText(styleFooter, style: .footnote, color: .secondaryLabel)
        }
    }

    /// What a colour style costs, from the catalog (free since 03/11).
    private var styleFooter: String {
        let price = colorAddon?.price ?? 0
        return price == 0
            ? String(localized: "Black & white and color styles are included.")
            : String(localized: "Black & white is included. Each color style adds $\(price) to an order.")
    }

    /// F9b: the customer's own style — Photos, Files and (once saved) Remove, as the logo.
    private var ownStyleRow: some View {
        Button {
            openFileMenu(.style)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "square.and.arrow.up")
                    .font(.title3)
                    .foregroundStyle(Theme.accentText)
                    .accessibilityHidden(true)
                if uploading == .style {
                    ProgressView()
                    Text(String(localized: "Uploading…"))
                        .foregroundStyle(Color.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(brand.styleSample == nil ? String(localized: "Upload your own style") : String(localized: "Change your style"))
                            .fontWeight(.medium)
                            .foregroundStyle(Theme.accentText)
                            // A wrapped label in a VStack can be squeezed to one cut line (trap #47d).
                            .fixedSize(horizontal: false, vertical: true)
                        WrappedText(brand.styleSample == nil
                                    ? String(localized: "A floor plan whose look you like. We match it.")
                                    : String(localized: "Our team draws your plans to match it."),
                                    style: .footnote, color: .secondaryLabel)
                    }
                    // As every WrappedText in an HStack: the width it may wrap in.
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// F9b "Add to every order": priced rows as the order form's add-ons; site plan shows its styles
    /// while on.
    private var extrasSection: some View {
        Section {
            Group {
                ForEach(extraPackages) { pkg in
                    Toggle(isOn: packageBinding(pkg.id)) {
                        priceRow(pkg.name, pkg.price)
                    }
                }
                ForEach(extraAddons) { addon in
                    Toggle(isOn: addonBinding(addon)) {
                        priceRow(addon.name, addon.price)
                    }
                    if presets.addonIds.contains(addon.id), let templates = addon.templates, !templates.isEmpty {
                        TemplatePicker(templates: templates, selection: templateBinding(addon.id))
                    }
                }
                problemRow(.extras)
            }
            .disabled(busy)
            .listRowBackground(Theme.card)
        } header: {
            Text(String(localized: "Add to every order"))
        } footer: {
            WrappedText(String(localized: "Every order starts with these. You can still change them on each order."),
                        style: .footnote, color: .secondaryLabel)
        }
    }

    private func priceRow(_ name: String, _ price: Int) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(price == 0 ? String(localized: "Free") : "+$\(price)")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func problemRow(_ part: Part) -> some View {
        if let problem, problem.part == part {
            Text(problem.text)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    // MARK: Settings

    private var addLogoBinding: Binding<Bool> {
        Binding(
            get: { brand.addLogo },
            set: { on in save(["addLogo": on], brand: brand.with(addLogo: on), in: .logo) }
        )
    }

    /// The Default style row: the colour style the form opens with, or Black & white (no colour).
    private var styleSelection: String {
        guard presets.addonIds.contains(BrandStyles.colorAddonId),
              let id = presets.templates[BrandStyles.colorAddonId] else { return BrandStyles.bwId }
        return id
    }

    private var styleBinding: Binding<String?> {
        Binding(
            get: { styleSelection },
            set: { id in
                guard let id, id != styleSelection else { return }
                pickStyle(id)
            }
        )
    }

    /// Black & white = presets without colour; a style = colour on with that style, also saved as
    /// `styleId` (F9: the form picks it when the customer turns colour on).
    private func pickStyle(_ id: String) {
        let color = BrandStyles.colorAddonId
        var next = presets
        if id == BrandStyles.bwId {
            next.addonIds.remove(color)
            next.templates.removeValue(forKey: color)
            save([:], presets: next, in: .style)
        } else {
            next.addonIds.insert(color)
            next.templates[color] = id
            save(["styleId": id], brand: brand.with(styleId: .some(id)), presets: next, in: .style)
        }
    }

    private func packageBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { presets.packageIds.contains(id) },
            set: { on in
                var next = presets
                if on {
                    next.packageIds.insert(id)
                } else {
                    next.packageIds.remove(id)
                    // An order needs a package (the server refuses none): the base one then.
                    if next.packageIds.isEmpty, let base = basePackageId { next.packageIds = [base] }
                }
                save([:], presets: next, in: .extras)
            }
        )
    }

    /// As `OrderSheet.addonBinding`: switching on an add-on with styles picks its first one.
    private func addonBinding(_ addon: CatalogAddon) -> Binding<Bool> {
        Binding(
            get: { presets.addonIds.contains(addon.id) },
            set: { on in
                var next = presets
                if on {
                    next.addonIds.insert(addon.id)
                    if next.templates[addon.id] == nil, let first = addon.templates?.first?.id {
                        next.templates[addon.id] = first
                    }
                } else {
                    next.addonIds.remove(addon.id)
                    next.templates.removeValue(forKey: addon.id)
                }
                save([:], presets: next, in: .extras)
            }
        )
    }

    private func templateBinding(_ addonId: String) -> Binding<String?> {
        Binding(
            get: { presets.templates[addonId] },
            set: { id in
                guard let id, id != presets.templates[addonId] else { return }
                var next = presets
                next.templates[addonId] = id
                save([:], presets: next, in: .extras)
            }
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
            presets = OrderPresets(result)
            catalog = result
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Shows the change at once; the server's answer replaces the brand, a refusal puts the old
    /// values back. `presets` = the whole new set, sent as `presets` (F9b).
    private func save(_ fields: [String: Any], brand changed: BrandSettings? = nil, presets next: OrderPresets? = nil, in part: Part) {
        guard !saving, let catalog else { return }
        var fields = fields
        if let next { fields["presets"] = next.json(in: catalog) }
        let before = brand
        let presetsBefore = presets
        if let changed { brand = changed }
        if let next { presets = next }
        saving = true
        problem = nil
        Task { @MainActor in
            defer { saving = false }
            do {
                brand = try await APIClient.shared.saveBrand(fields)
            } catch {
                var back = brand
                if fields["addLogo"] != nil { back = back.with(addLogo: before.addLogo) }
                if fields["styleId"] != nil { back = back.with(styleId: .some(before.styleId)) }
                brand = back
                if next != nil { presets = presetsBefore }
                problem = (part, message(for: error))
                // A style or an item left the catalog: what is on screen is old, read it again (the
                // controls wait: a change made meanwhile would be overwritten).
                let code = (error as? APIError)?.code
                if code == "unknown_style" || code == "invalid",
                   let fresh = try? await APIClient.shared.brandCatalog() {
                    self.catalog = fresh
                    if let saved = fresh.brand { brand = saved }
                    presets = OrderPresets(fresh)
                }
            }
        }
    }

    // MARK: Files (logo, own style)

    private func openFileMenu(_ part: Part) {
        problem = nil
        fileTarget = part
        showFileMenu = true
    }

    private func present(_ open: @escaping () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            open()
        }
    }

    private func uploadPhoto(_ item: PhotosPickerItem, as part: Part) async {
        uploading = part
        problem = nil
        defer { uploading = nil }
        do {
            let maxBytes = Self.maxFileBytes
            guard let raw = try await item.loadTransferable(type: Data.self),
                  let file = await Task.detached(priority: .userInitiated, operation: {
                      LogoImageEncoder.encode(raw, maxBytes: maxBytes)
                  }).value else {
                problem = (part, String(localized: "Could not read that photo."))
                return
            }
            let name = part == .style ? "style" : "logo"
            try await upload(file.data, fileName: "\(name).\(file.ext)", contentType: file.mimeType, as: part)
        } catch {
            problem = (part, message(for: error, upload: part))
        }
    }

    private func uploadFile(_ url: URL, as part: Part) async {
        uploading = part
        problem = nil
        defer { uploading = nil }
        // Outside the sandbox (fileImporter): ask for access, give it back after.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > Self.maxFileBytes {
                problem = (part, String(localized: "This file is larger than 5 MB. Please choose a smaller one."))
                return
            }
            let data = try Data(contentsOf: url)
            guard data.count <= Self.maxFileBytes else {
                problem = (part, String(localized: "This file is larger than 5 MB. Please choose a smaller one."))
                return
            }
            try await upload(data, fileName: url.lastPathComponent, contentType: OrderFileItem.mimeType(for: url), as: part)
        } catch {
            problem = (part, message(for: error, upload: part))
        }
    }

    /// A new own style becomes the default style at once (approved mockup f9b-3).
    private func upload(_ data: Data, fileName: String, contentType: String, as part: Part) async throws {
        if part == .style {
            brand = try await APIClient.shared.uploadStyleSample(data, fileName: fileName, contentType: contentType)
            if styleSelection != BrandStyles.ownStyleId { pickStyle(BrandStyles.ownStyleId) }
        } else {
            brand = try await APIClient.shared.uploadBrandLogo(data, fileName: fileName, contentType: contentType)
        }
    }

    private func removeLogo() {
        guard !busy else { return }
        saving = true
        problem = nil
        Task { @MainActor in
            do {
                brand = try await APIClient.shared.deleteBrandLogo()
            } catch {
                problem = (.logo, message(for: error))
            }
            saving = false
        }
    }

    private func removeStyle() {
        guard !busy else { return }
        saving = true
        problem = nil
        Task { @MainActor in
            do {
                brand = try await APIClient.shared.deleteStyleSample()
                // As the server: a preset on the own style loses it, colour stays on with the first style.
                if presets.templates[BrandStyles.colorAddonId] == BrandStyles.ownStyleId {
                    presets.templates[BrandStyles.colorAddonId] = styles.first?.id
                }
            } catch {
                problem = (.style, message(for: error))
            }
            saving = false
        }
    }

    /// The server's refusals this screen can meet, in the app's language (`code`, ✗ the English text).
    private func message(for error: Error, upload part: Part = .logo) -> String {
        switch (error as? APIError)?.code {
        case "too_large": return String(localized: "This file is larger than 5 MB. Please choose a smaller one.")
        case "unsupported_type":
            return part == .style
                ? String(localized: "Please choose a PNG, JPG or PDF file.")
                : String(localized: "Please choose a PNG, JPG, SVG or PDF file.")
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

    private func loadPDF() async {
        guard let logo, logo.contentType == "application/pdf" else {
            pdfImage = nil
            return
        }
        // A page drawn before shows at once; else the file mark while it downloads.
        pdfImage = Self.pdfThumbs.object(forKey: Self.pdfKey(logo.url, Self.logoBox))
        guard pdfImage == nil, let page = await Self.pdfPage(logo.url, box: Self.logoBox), !Task.isCancelled else { return }
        pdfImage = page
    }

    private static let logoBox = CGSize(width: 240, height: 150)

    /// First page of a PDF (a logo; F9b an own style in `TemplatePicker`), ≤ 5 MB, drawn to fit
    /// `box`: downloaded once per URL, box and app run — the tiles reappear often (the order form's
    /// rows, every pop back to Order defaults). nil = the download or the PDF failed.
    static func pdfPage(_ url: String, box: CGSize) async -> UIImage? {
        let key = pdfKey(url, box)
        if let cached = pdfThumbs.object(forKey: key) { return cached }
        guard let address = URL(string: url),
              let download = try? await URLSession.shared.data(from: address),
              let page = PDFDocument(data: download.0)?.page(at: 0) else { return nil }
        let thumb = page.thumbnail(of: box, for: .mediaBox)
        pdfThumbs.setObject(thumb, forKey: key)
        return thumb
    }

    private static func pdfKey(_ url: String, _ box: CGSize) -> NSString {
        "\(Int(box.width))x\(Int(box.height)) \(url)" as NSString
    }

    private static let pdfThumbs = NSCache<NSString, UIImage>()
}

/// A photo from the library as a logo file: at most 2048 px on the long side, upright (the photo's
/// orientation applied); PNG when it has transparency (a logo cut-out), else JPEG; a transparent
/// one too big as PNG goes onto white first (✗ black corners in a JPEG). ImageIO decodes only what
/// 2048 px needs (a 48 MP photo would be ~200 MB as a full UIImage). Runs off the main thread.
/// F9b: an own-style photo goes the same way.
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
        BrandSettings(logo: logo, addLogo: addLogo ?? self.addLogo, styleId: styleId ?? self.styleId, styleSample: styleSample)
    }
}
