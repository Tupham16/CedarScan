import SwiftUI

/// Ba văn bản pháp lý bắt buộc cho App Store: Privacy Policy · Terms and Conditions · EULA.
///
/// **VĂN BẢN NẰM TRONG APP, KHÔNG PHẢI LINK WEB** — cố ý. App được dùng ở công trường sóng yếu,
/// và App Store review cũng mở mục này khi máy chưa đăng nhập; một cái link chết là một vòng bị
/// từ chối. Đổi lại: sửa câu chữ = phải build lại app.
///
/// **HAI BẢN TRỌN VẸN: TIẾNG ANH + TIẾNG PHÁP** (bản Pháp thêm 09/2026 khi chủ app chốt bán cho
/// người tiêu dùng Québec — Bill 96 đòi hợp đồng mẫu phải có bản tiếng Pháp). Đúng theo ghi chú
/// thiết kế cũ: dịch là dịch TRỌN VĂN BẢN kèm điều khoản "Language / Langue" nói rõ bản nào có
/// hiệu lực ở đâu — ✗ trộn lẫn từng câu qua String Catalog. Vì vậy nội dung các mảng *Sections /
/// *SectionsFR nằm NGOÀI Localizable.xcstrings, cố ý.
/// · App hiện bản Pháp khi ngôn ngữ app là tiếng Pháp (`AppLanguage.code == "fr"`), mọi ngôn ngữ
///   khác thấy bản Anh.
/// · SỬA BẢN ANH THÌ PHẢI SỬA BẢN PHÁP CÙNG LƯỢT — hai bản phải cùng số mục, cùng nghĩa. Bản
///   Pháp sinh từ `tools/legal-fr/` (kho dịch đã qua review đối kháng); đổi câu tiếng Anh mà
///   không cập nhật bản Pháp là hai bản lệch nhau — với khách Québec thì BẢN PHÁP mới là bản
///   có hiệu lực, nên lệch = tự viết lại hợp đồng của chính mình mà không biết.
/// · `governingState` chỉ nội suy vào bản Anh; bản Pháp viết cứng "Nouveau-Mexique" — đổi bang
///   đăng ký LLC thì sửa CẢ HAI.
///
/// ⚠ Nội dung dưới đây mô tả ĐÚNG những gì app/server đang làm thật (id thiết bị cho suất miễn
/// phí, **bản quét nằm trên máy tới khi khách tự xoá — mục "How long we keep it" sửa 10/08 ở bản
/// 1.8 khi việc tự xoá sau 14 ngày bị TẮT**, PDF+JPG mặc định / DWG tính tiền, MapKit/
/// CLGeocoder gửi dữ liệu sang Apple). Đổi hành vi app mà quên sửa ở đây là văn bản nói sai —
/// nguy hiểm hơn không có văn bản. Sửa nội dung thì sửa cả `lastUpdated`.
///
/// 🔴 HAI CÂU ĐÃ PHẢI VIẾT LẠI VÌ HỨA QUÁ (review đối kháng 2026-07-23 bắt, 4 lens độc lập):
/// bản đầu nói xoá tài khoản là xoá "uploaded files" và nói file được "removed from active storage"
/// sau vòng sửa. Server KHÔNG làm cả hai: `account/delete/route.ts` chỉ xoá prefix `scans/` và
/// `tours/`, **`order-files/` không có đường xoá nào trong toàn repo**, và không có job dọn định
/// kỳ nào cả. Nay câu chữ nói đúng sự thật + mời khách email để xoá tay.
/// → Việc CÒN NỢ phía server (chưa làm, có chủ đích): thêm `order-files/{customerId}/` vào
///   `deleteR2Prefixes` KÈM keep-list cho đơn chưa đóng sổ — ghép qua `Attachment.url` vì
///   `order-files` không mang `scanId`. Làm xong thì sửa lại hai đoạn dưới đây.
enum LegalDoc: String, CaseIterable, Identifiable {
    case privacy, terms, eula

    var id: String { rawValue }

    var title: String {
        switch self {
        case .privacy: return String(localized: "Privacy Policy")
        case .terms: return String(localized: "Terms and Conditions")
        case .eula: return String(localized: "End User Licence Agreement")
        }
    }

    var icon: String {
        switch self {
        case .privacy: return "hand.raised"
        case .terms: return "doc.text"
        case .eula: return "checkmark.seal"
        }
    }

    /// Ngày cập nhật in ở đầu mỗi văn bản. SỬA NỘI DUNG THÌ SỬA CẢ NGÀY NÀY — CẢ HAI BẢN.
    /// ⚠ SỬA 20/08: từng ghi nhầm "13 August 2026" — phiên làm việc kéo dài nhiều ngày và ngày
    /// đó được SUY RA chứ không phải đọc từ đồng hồ. Đổi nội dung thì lấy ngày bằng `date`,
    /// ✗ suy từ ngày ghi trong handoff.
    /// (01/09/2026: thêm mục Language/Langue + bản dịch tiếng Pháp trọn vẹn — lệnh `date` chạy
    /// lúc sửa: 2026-09-01.)
    static let lastUpdated = "1 September 2026"

    /// Ngày cập nhật viết theo lối Pháp, in trên bản Pháp. Đổi `lastUpdated` thì đổi cả đây.
    static let lastUpdatedFR = "1er septembre 2026"

    static let contactEmail = "hello@cedar247.com"

    /// 🔴 BA HẰNG SỐ NÀY LẤY TỪ GIẤY TỜ PHÁP NHÂN, ✗ TỰ SỬA, ✗ "dọn cho gọn".
    /// Chủ app cung cấp 13/08/2026, đọc thẳng từ hồ sơ thành lập LLC (New Mexico).
    /// Chúng xuất hiện ở SÁU chỗ: mục Contact của cả ba văn bản, mục "Apple" của EULA, và mục
    /// General của Terms + EULA. Sửa ở đây là sửa hết sáu chỗ VÀ cả ba trang web
    /// (`C:\Block\Cedar247Web\web-source\legal-to-web\` sinh trang từ chính file này).
    ///
    /// · `governingState` — bang đăng ký LLC. **Cả năm vùng luật đã soi (EU/UK · Mỹ · Canada · Úc
    ///   · NZ) đều đánh** câu cũ *"the laws applicable at Cedar247's place of business"*: nó không
    ///   gọi tên luật nào nên khách không thể biết mình đang đồng ý với cái gì, và điều khoản mù
    ///   mờ thì được giải thích CÓ LỢI CHO NGƯỜI TIÊU DÙNG.
    /// · `postalAddress` — 🔴 **APPLE BẮT BUỘC**, ✗ chuyện nội bộ: mục 8 của *Minimum Terms of
    ///   Developer's EULA* đòi EULA ghi TÊN và ĐỊA CHỈ nhà phát triển. Đây là địa chỉ đại lý đăng
    ///   ký (Northwest Registered Agent) — **cố ý**, vì LLC New Mexico là loại ẩn danh và đây cũng
    ///   là địa chỉ nằm trên hồ sơ công khai của bang, nên Apple đối chiếu là khớp.
    ///   ⚠ Viết hoa/thường theo lối văn bản; NỘI DUNG phải khớp hồ sơ bang từng chữ — đổi một chữ
    ///   là lệch với D-U-N-S và hồ sơ nhà nước, Apple bắt làm lại vòng xác minh.
    static let legalEntity = "Cedar247 LLC"
    static let governingState = "New Mexico"
    static let postalAddress = "1209 Mountain Road Pl NE, Ste N, Albuquerque, NM 87110"

    /// Ngôn ngữ app là tiếng Pháp thì hiện bản Pháp — quyết định MỘT LẦN lúc đọc, theo bundle
    /// localization đã resolve (khách Québec đặt máy tiếng Pháp rơi đúng vào đây).
    static var isFrench: Bool { AppLanguage.code == "fr" }

    /// Ngày in đầu văn bản, theo ngôn ngữ của chính văn bản đang hiện.
    static var displayLastUpdated: String { isFrench ? lastUpdatedFR : lastUpdated }

    var sections: [LegalSection] {
        let raw: [(String, String)]
        switch self {
        case .privacy: raw = Self.isFrench ? Self.privacySectionsFR : Self.privacySections
        case .terms: raw = Self.isFrench ? Self.termsSectionsFR : Self.termsSections
        case .eula: raw = Self.isFrench ? Self.eulaSectionsFR : Self.eulaSections
        }
        return raw.map { LegalSection(heading: $0.0, text: $0.1) }
    }
}

/// Một mục trong văn bản.
///
/// Là STRUCT chứ không phải tuple vì `ForEach(_:id:)` cần key path, mà **Swift không có key path
/// vào phần tử tuple** (`\.0` không biên dịch được). Nội dung vẫn khai bằng tuple cho gọn rồi
/// `map` sang đây.
struct LegalSection: Identifiable {
    let heading: String
    let text: String
    var id: String { heading }
}

// MARK: - Privacy Policy

extension LegalDoc {
    static let privacySections: [(String, String)] = [
        ("Who we are",
         "CedarScan is a mobile application published by Cedar247. When you scan a property and order drawings through the app, Cedar247 is the controller of the personal data described below. Write to us at \(contactEmail) about anything in this policy."),
        ("The short version",
         "We collect what we need to turn your scan into a floor plan, to run your account, and to stop the free-order allowance from being abused. We do not sell your data, we do not show advertising, and we do not track you across other apps or websites."),
        ("Information you give us",
         "Account details: your name, email address and a password (stored only as a cryptographic hash). Property details: the address or label you type for each home, so the drafting team knows which building a drawing belongs to. Order details: the packages and add-ons you choose, drawing preferences, notes you write, coupon codes, and any files you attach, such as a logo or a marked-up PDF."),
        ("Information the app captures",
         "Scan data: the 3D geometry produced by the LiDAR sensor, a colour video recorded while you walk through the space, and the model files derived from them. These capture the inside of the property, so please treat them as you would photographs of the same rooms. Anything visible while you scan will be in the file, including people, documents and screens. Ask everyone present before you start, and put private items away first."),
        ("Location",
         "The app can fill in a property address from your device location, but only in the moment you tap the button that asks for it. There is no background or continuous location tracking. The coordinates are turned into a street address, the address is what gets stored, and you can always type the address by hand instead — the app works fully without location permission."),
        ("Device identifier",
         "The app reads the identifier iOS gives to apps from the same developer on your device, and sends it when you create your account, when you view prices and when you place an order. It exists for one purpose: to apply the limited free-order allowance per device as well as per account. It is not the advertising identifier and it is not shared with third parties for marketing. iOS resets it once you remove every Cedar247 app from the device. We keep a record of the identifier and how many free orders it has used even after an account is deleted, otherwise the allowance could be reset simply by making a new account; write to us if you want that record removed."),
        ("Technical records",
         "Our servers keep ordinary operational records — timestamps, request paths, error messages, network address and approximate file sizes — to keep the service running, investigate faults and detect abuse."),
        ("What we never collect",
         "We do not access your contacts, calendar, photo library (beyond a file you deliberately attach), health data, or advertising identifiers, and the app does not record audio. The scan video has no sound track."),
        ("Why we use your data",
         "To perform our contract with you: producing and delivering the drawings you order, taking payment, and supporting you afterwards. For our legitimate interests: keeping the service secure, preventing abuse of promotions, and improving the accuracy of the capture guidance. To meet legal obligations: tax, accounting and record-keeping. Where the law requires consent — for example device location — we ask for it and you may refuse or withdraw it in your device settings."),
        ("Who sees your data",
         "The Cedar247 production team and the drafting specialists working on your order see the scan files, the property label and your order notes, under confidentiality obligations. We also use service providers who process data on our behalf: cloud hosting and object storage, our payment provider, and an email delivery provider. They act on our instructions only, and we only work with providers whose terms require them to protect your data to at least the standard set out in this policy and to use it only for the service they provide to us. We may disclose data if the law requires it, or to establish or defend legal claims. We do not sell personal data and we do not share it with data brokers."),
        ("Address look-up uses Apple",
         "The address screen is powered by Apple's mapping services. When you tap the location button, your coordinates are sent to Apple to be turned into a street address; that button is entirely optional. Address suggestions work differently: from the third character onwards, what you type in the address field is sent to Apple to fetch the suggestion list, and that happens as you type whether or not you tap a suggestion. The same is true of the map at the top of that screen: it loads map imagery from Apple, and once you have typed at least five characters the address is sent to Apple to find the point it marks. There is no switch for any of this in this version. Apple handles that data under its own privacy policy and we receive nothing from it beyond the address text you end up with — the coordinates behind the map pin stay on your device and never reach us."),
        ("Where your data is held",
         "Our hosting and storage providers operate in the United States and the European Union, so your data may be transferred outside your own country. Where transfers are covered by European or United Kingdom rules, we rely on standard contractual clauses with those providers."),
        ("How long we keep it",
         "On your phone, scans stay until you delete them — nothing is removed on a timer. Deleting a property in the app deletes that property's scans from the phone, and that cannot be undone; the copies we hold for your order are not affected. Each scan is large, so delete the properties you have finished with to reclaim space. On our side we currently keep scan files, order attachments and order records for as long as they are needed for the order and its records; a delivered drawing can come back for revision, and order records are required for tax and accounting. We do not run an automatic purge on our storage today. Finished drawings stay available for you to download for at least 365 days from delivery; after that we may remove them, so keep your own copy. Order attachments and order records outlive the account itself — see \"Deleting your account\" below for exactly what goes and what stays. If you want your scan files removed sooner, delete your account; for order attachments, email us and we will remove them once the order is closed."),
        ("Deleting your account",
         "Account, Delete account removes your account and, from our storage, your scan files and any virtual tour photos. Three things deliberately survive it. First, orders already placed stay in our business records: the order number, date and amount, and also the name and email that were on the order, the property address or label you gave it, your order notes and the list of files that came with it — tax law requires the record, and a delivered drawing can still come back for revision. Second, files still needed to finish an order you have paid for stay until that order is closed; destroying a paid job halfway is not something we can undo either. Third, files you attached to an order yourself — a logo, a marked-up PDF sent with a revision request — stay attached to that order. Email \(contactEmail) if you want those attachments and the personal details on closed orders removed, and we will do it wherever the law lets us. Deletion of the account itself cannot be undone."),
        ("Your rights",
         "Depending on where you live, you may ask us for a copy of your data, ask us to correct it, ask us to delete it, ask us to restrict or object to certain processing, or ask for it in a portable format. Email \(contactEmail) and we will answer within the period the law allows. If you are in the European Economic Area or the United Kingdom you may also complain to your data protection authority; if you are in California you may exercise the rights given by state law without being treated differently for doing so."),
        ("Security",
         "Traffic between the app and our servers is encrypted in transit. Uploads use short-lived, single-purpose links, and each link is bound to the account that requested it. Passwords are stored only as hashes. One thing to be aware of: once a file is uploaded it lives at a long, unguessable web address that works without a password, so that our drafting team and your download links keep working — treat a link to your scan or drawing as you would the file itself, and tell us if one has been shared by mistake so we can move or remove the file. No system is perfect, so please use a strong, unique password and tell us at once if you think someone else has reached your account."),
        ("Children",
         "CedarScan is a professional tool and is not directed at children. We do not knowingly collect data from anyone under sixteen. If you believe a child has given us data, write to us and we will remove it."),
        ("Changes",
         "If we change this policy we will update the date at the top and, for anything significant, tell you in the app or by email. Continuing to use CedarScan after a change means you accept the updated policy."),
        ("Language",
         "This document exists in English and in French. If you are a consumer in Québec, the French version is made available to you and applies; the English version binds you only if you expressly choose it after receiving the French version. Everywhere else, if the two versions ever differ, the English version prevails to the extent your local law allows. You may write to us in English or in French."),
        ("Contact",
         "\(legalEntity), \(postalAddress) — \(contactEmail)"),
    ]
}

// MARK: - Terms and Conditions

extension LegalDoc {
    static let termsSections: [(String, String)] = [
        ("These terms",
         "These terms form the agreement between you and Cedar247 for the CedarScan app and the drawing services ordered through it. By creating an account or placing an order you accept them. If you are ordering for a company, you confirm you may accept these terms on its behalf."),
        ("Your account",
         "Give accurate details, keep your password to yourself, and tell us promptly if you suspect someone else has access. You are responsible for what happens under your account. We may suspend or close an account that is used to abuse the service, to evade promotion limits, or to break these terms."),
        ("What the service is",
         "You capture a three-dimensional scan of a property with the app. Our team then draws the deliverables you have ordered from that scan, by hand. Unless your order says otherwise, plans are delivered as PDF and JPG; SVG or PNG are available on request; a DWG CAD file is a paid add-on. Optional extras such as colour styling, site plans, express turnaround and virtual tours are priced separately and are only included when you select them."),
        ("Your part of the job",
         "The drawing can only be as good as the scan. Follow the guidance in the Learn tab: scan the whole property in one continuous walk where you can, keep every wall, corner, door and window in view, and check the preview before you order. You confirm that you are entitled to scan the property and to send us the result — that you own it, or you have the permission of the owner or occupier — and that anyone present has been told the space is being recorded in 3D."),
        ("Prices and promotions",
         "Prices are shown in the app, in United States dollars, at the moment you order, and that is the price that applies to that order. New accounts may receive a limited number of free orders; the allowance is counted per account and per device, may be changed or withdrawn at any time, and may not be split across extra accounts created to obtain more of it. Very large properties may attract a surcharge, which we work out once the area has been measured and which we will always tell you about before we ask you to pay it."),
        ("Payment",
         "Paid orders are settled through our payment page and payment provider. Production starts once payment is confirmed, unless the order is covered by a free allowance, in which case it starts immediately. If a payment is reversed or charged back, we may pause the order or withhold the deliverables until the matter is resolved."),
        ("Turnaround",
         "The times we quote are targets based on normal workload, not guarantees, and they start when payment is confirmed and the scan files have finished uploading. Express is a faster target for ordinary homes; it does not apply to very large properties, and a scan that turns out to be unusable will always take longer because we have to come back to you first."),
        ("Revisions",
         "If we made a mistake — a missing door, a mislabelled room, a wrong dimension we could have read from your scan — tell us through Orders, Request a revision, and we will fix it free of charge. Attach a photo or a marked-up file if it helps us find the spot. Requests that change what you originally ordered, or that ask us to draw an area your scan does not cover, are new work and are quoted as such. Revisions are available for 90 days after delivery, up to three per order, matching the revision policy published on our website; after that, or once you have asked us to delete the files, we may no longer have the source data."),
        ("Refunds",
         "You can cancel and be refunded in full at any time before we start drawing. Once drawing has begun we will refund a fair part of the price, judged by how much work has been done. If we cannot deliver at all, you get everything back. If a scan is too incomplete to draw, we will tell you before we take the work on rather than deliver something unusable."),
        ("What the drawings are and are not",
         "Deliverables are produced from the scan you supply and are intended for marketing, planning, space assessment and similar everyday purposes. They are not a land survey, a structural report, or a certified measurement, and they should not be relied on for legal boundaries, permit submissions, structural work or anything else where an error would matter, unless a qualified professional has verified them on site. Small differences between the drawing and the building are normal and inherent to scanning."),
        ("Who owns what",
         "Your scans, your photos and the files you attach stay yours. You grant Cedar247 a licence to store, process and adapt them so far as needed to produce and deliver your order, to handle support and revisions, and to keep the records this agreement requires. Once your order is paid — or delivered under a free allowance — the finished deliverables are yours to use as you wish, including commercially. We may keep anonymous technical measurements about scans, such as file sizes and capture quality figures, to improve the service; these do not identify you or your property. We will not publish, market with, or show a third party any image or drawing of your property without asking you first."),
        ("Acceptable use",
         "Do not use CedarScan to scan a property you have no right to scan, to capture people covertly, to break the law, to overload or probe our systems, to obtain deliverables you have not paid for, or to resell access to the app itself. Reselling the drawings we make for you, as part of your own service to your own client, is expressly allowed and is what many of our customers do."),
        ("Availability",
         "We work to keep the service running but we do not promise it will be uninterrupted. Maintenance, network faults and changes by Apple or our suppliers can all interrupt it. We may add, change or withdraw features; if a change materially reduces something you have already paid for and not yet received, tell us and we will make it right."),
        ("Liability",
         "Nothing in these terms excludes, restricts or modifies any right, guarantee or remedy you have under a law that cannot lawfully be excluded — including liability for death or personal injury caused by our negligence, and liability for fraud. If you are a consumer in Australia, our services come with guarantees under the Australian Consumer Law that cannot be excluded; if you are a consumer in New Zealand, the Consumer Guarantees Act 1993 applies; and consumers in the European Union, the United Kingdom and Canada keep the mandatory rights given by their own law. The monetary limits below do not apply to any liability we have under those laws. Subject to that, and only so far as the law allows: the service and the deliverables are provided without warranties beyond those the law implies; Cedar247 is not liable for indirect or consequential loss, for lost profit, revenue, data or opportunity, or for decisions taken in reliance on a drawing without independent verification; and our total liability arising from an order is limited to the amount you paid for that order, or to fifty United States dollars where the order was free. Where the law lets us limit liability for failing to meet a consumer guarantee for services not ordinarily acquired for personal, domestic or household use, that liability is limited, at our option, to supplying the services again or paying the cost of having them supplied again."),
        ("Indemnity",
         "You will cover us against claims brought by a third party because you scanned a property without the right to do so, or because the material you sent us infringed someone's rights."),
        ("Ending the agreement",
         "You may stop using CedarScan and delete your account at any time. We may end this agreement if you break these terms seriously or repeatedly. Ending it does not affect orders already delivered or amounts already owed."),
        ("General",
         "If any part of these terms is unenforceable, the rest still applies. Failing to enforce a term is not a waiver of it. These terms are governed by the law of the State of \(governingState), United States, without regard to its conflict-of-law rules. If you are a consumer, that choice does not deprive you of the protection of any provision of the law of your country of residence that cannot be departed from by agreement; a consumer may bring proceedings in the courts of their own country of residence, and we will bring proceedings against a consumer only in the courts of the country where that consumer lives. We may update these terms and will show the new date at the top; material changes will be notified in the app or by email."),
        ("Language",
         "This document exists in English and in French. If you are a consumer in Québec, the French version is made available to you and applies; the English version binds you only if you expressly choose it after receiving the French version. Everywhere else, if the two versions ever differ, the English version prevails to the extent your local law allows. You may write to us in English or in French."),
        ("Contact",
         "\(legalEntity), \(postalAddress) — \(contactEmail)"),
    ]
}

// MARK: - End User Licence Agreement

extension LegalDoc {
    static let eulaSections: [(String, String)] = [
        ("This licence",
         "This End User Licence Agreement governs your use of the CedarScan application itself. The services you order through the app are covered by our Terms and Conditions, and the handling of your data by our Privacy Policy. Installing or using the app means you accept this licence; if you do not accept it, delete the app."),
        ("What you may do",
         "Cedar247 grants you a personal, non-exclusive, non-transferable, revocable licence to install and use CedarScan on Apple-branded devices that you own or control, for your own business or private purposes, in accordance with the Usage Rules of the Apple Media Services Terms and Conditions. The app may also be accessed and used by other accounts associated with you, as the purchaser, through Family Sharing or volume purchasing. The licence covers use of the app, not ownership of it."),
        ("What you may not do",
         "Do not copy, sell, rent, sublicense or redistribute the app. Do not modify, translate, decompile, disassemble or reverse engineer it, or try to derive its source code, except to the extent the law expressly permits despite this restriction. Do not remove or obscure any notice of ownership. Do not work around technical limits such as the free-order allowance or upload restrictions, and do not access our servers with anything other than the app itself."),
        ("Ownership",
         "CedarScan, its interface, its code and everything in it belong to Cedar247 or its licensors and are protected by copyright and other laws. You receive only the rights this licence states; nothing else is granted, by implication or otherwise."),
        ("Your content",
         "Scans, photos and files you create or upload remain yours. The licence you give us to process them, and the limits on what we may do with them, are set out in our Terms and Conditions and Privacy Policy."),
        ("What the app needs",
         "CedarScan requires an iPhone with a LiDAR sensor — an iPhone 12 Pro or a later Pro model — running iOS 17 or later. It needs camera access to scan; without it, scanning cannot run. Location access is optional and used only to fill in a property address when you ask it to. Uploading scans and placing orders require an internet connection and an account."),
        ("Updates and changes",
         "We may release updates, and some may be required for the app to keep working with our servers. Features may be added, changed or removed over time. Updates are covered by this licence unless they come with their own terms."),
        ("Third-party services",
         "The app relies on services we do not control, including Apple's platform frameworks, our cloud hosting and storage providers, and our payment provider. Their terms apply to their part of the service, and we are not responsible for how those third parties operate. You agree to comply with any third-party terms that apply to your use of the app."),
        ("No warranty",
         "We provide the app with reasonable care and skill. We do not warrant that the app will be uninterrupted or error-free, or that a scan will always succeed on every property or in every lighting condition. Nothing in this licence excludes, restricts or modifies any guarantee, right or remedy you have under a law that cannot lawfully be excluded. If you are in Australia, our goods and services come with guarantees that cannot be excluded under the Australian Consumer Law; if you are in New Zealand, the Consumer Guarantees Act 1993 applies; and consumers in the European Union, the United Kingdom and Canada keep their mandatory local rights. Any disclaimer of merchantability, fitness for a particular purpose or non-infringement in this licence does not apply to you to the extent it would exclude, restrict or modify such a guarantee. Outside those cases, and to the fullest extent your local law allows, the app is provided as is and as available."),
        ("Limitation of liability",
         "Nothing in this clause excludes or limits liability that cannot lawfully be excluded or limited, and the fifty United States dollar cap below does not apply where your law does not allow it — including to consumers in Australia and New Zealand. Subject to that, and to the fullest extent the law allows, Cedar247 is not liable for indirect or consequential loss arising from your use of the app, including lost profit, lost data or a scan that has to be repeated, and our total liability under this licence is limited to fifty United States dollars, which reflects the fact that the app is supplied free of charge."),
        ("Term and termination",
         "This licence runs until terminated. It ends automatically if you break any of its terms, and you may end it at any time by deleting the app. The sections on ownership, warranty, liability and general provisions survive termination."),
        ("Apple",
         "This licence is between you and Cedar247 only, not with Apple, and Cedar247 alone is responsible for the app and its content. Cedar247, not Apple, is solely responsible for providing any maintenance and support services for the app, and Apple has no obligation to provide any. If the app fails to conform to any applicable warranty, you may notify Apple, and Apple will refund the purchase price of the app, if any; to the maximum extent permitted by law, Apple has no other warranty obligation whatsoever with respect to the app, and any other claims, losses, liabilities, damages, costs or expenses attributable to a failure to conform to a warranty are the sole responsibility of Cedar247. Cedar247, not Apple, is responsible for addressing any claim by you or a third party relating to the app, including product liability claims, any claim that the app fails to conform to a legal or regulatory requirement, and claims arising under consumer protection, privacy, or similar legislation. Cedar247, not Apple, is responsible for the investigation, defence, settlement and discharge of any third-party claim that the app infringes intellectual property rights. Apple and its subsidiaries are third-party beneficiaries of this licence, and upon your acceptance of it Apple will have the right, and will be deemed to have accepted the right, to enforce it against you as a third-party beneficiary. Any questions, complaints or claims about the app should be sent to \(legalEntity), \(postalAddress), \(contactEmail)."),
        ("Export and compliance",
         "You confirm that you are not located in a country subject to a United States government embargo or designated as a terrorist-supporting country, and that you are not listed on any United States government list of prohibited or restricted parties. You will use the app only in compliance with applicable law."),
        ("General",
         "If any provision of this licence is unenforceable, the rest remains in force. This licence is governed by the law of the State of \(governingState), United States, without regard to its conflict-of-law rules. If you are a consumer, that choice does not deprive you of the protection of any provision of the law of your country of residence that cannot be departed from by agreement, and you may bring proceedings in the courts of your own country of residence. It is the entire agreement between you and Cedar247 about the app itself."),
        ("Language",
         "This document exists in English and in French. If you are a consumer in Québec, the French version is made available to you and applies; the English version binds you only if you expressly choose it after receiving the French version. Everywhere else, if the two versions ever differ, the English version prevails to the extent your local law allows. You may write to us in English or in French."),
        ("Contact",
         "\(legalEntity), \(postalAddress) — \(contactEmail)"),
    ]
}

// MARK: - Bản tiếng Pháp (SINH BẰNG MÁY từ tools/legal-fr — ✗ SỬA TAY, chạy tools/gen_legal_fr.py)

extension LegalDoc {
    static let privacySectionsFR: [(String, String)] = [
        ("Qui nous sommes",
         "CedarScan est une application mobile publiée par Cedar247. Lorsque vous numérisez une propriété et commandez des plans par l'intermédiaire de l'application, Cedar247 est le responsable du traitement des renseignements personnels décrits ci-dessous. Écrivez-nous à \(contactEmail) pour tout ce qui concerne la présente politique."),
        ("La version courte",
         "Nous recueillons ce qui nous est nécessaire pour transformer votre numérisation en plan d'étage, pour gérer votre compte et pour empêcher que le quota de commandes gratuites ne fasse l'objet d'abus. Nous ne vendons pas vos renseignements, nous n'affichons pas de publicité et nous ne suivons pas vos activités dans d'autres applications ni sur d'autres sites web."),
        ("Renseignements que vous nous fournissez",
         "Renseignements sur le compte : votre nom, votre adresse courriel et un mot de passe (conservé uniquement sous forme d'empreinte cryptographique). Renseignements sur la propriété : l'adresse ou le libellé que vous saisissez pour chaque habitation, afin que l'équipe de dessin sache à quel bâtiment un plan se rapporte. Renseignements sur la commande : les forfaits et options que vous choisissez, vos préférences de dessin, les notes que vous rédigez, les codes promotionnels et les fichiers que vous joignez, par exemple un logo ou un PDF annoté."),
        ("Renseignements que l'application capte",
         "Données de numérisation : la géométrie 3D produite par le capteur LiDAR, une vidéo en couleur enregistrée pendant que vous parcourez les lieux, et les fichiers de modèle qui en sont dérivés. Ces éléments captent l'intérieur de la propriété ; veuillez donc les traiter comme vous traiteriez des photographies des mêmes pièces. Tout ce qui est visible pendant la numérisation figurera dans le fichier, y compris les personnes, les documents et les écrans. Consultez toutes les personnes présentes avant de commencer, et rangez d'abord les objets privés."),
        ("Localisation",
         "L'application peut remplir l'adresse d'une propriété à partir de la position de votre appareil, mais uniquement au moment où vous touchez le bouton qui le demande. Il n'y a aucun suivi de localisation en arrière-plan ni en continu. Les coordonnées sont converties en adresse municipale — c'est cette adresse qui est conservée — et vous pouvez toujours saisir l'adresse à la main à la place : l'application fonctionne entièrement sans l'autorisation de localisation."),
        ("Identifiant de l'appareil",
         "L'application lit l'identifiant qu'iOS attribue, sur votre appareil, aux applications provenant du même développeur, et le transmet lorsque vous créez votre compte, lorsque vous consultez les prix et lorsque vous passez une commande. Il n'a qu'un seul but : appliquer le quota limité de commandes gratuites non seulement par compte, mais aussi par appareil. Il ne s'agit pas de l'identifiant publicitaire et il n'est pas communiqué à des tiers à des fins de marketing. iOS le réinitialise dès que vous supprimez toutes les applications Cedar247 de l'appareil. Nous conservons une trace de l'identifiant et du nombre de commandes gratuites qu'il a utilisées même après la suppression d'un compte, faute de quoi le quota pourrait être remis à zéro par la simple création d'un nouveau compte ; écrivez-nous si vous souhaitez que cette trace soit supprimée."),
        ("Journaux techniques",
         "Nos serveurs conservent des journaux d'exploitation ordinaires — horodatages, chemins des requêtes, messages d'erreur, adresses réseau et tailles approximatives des fichiers — pour maintenir le service en fonctionnement, analyser les pannes et détecter les abus."),
        ("Ce que nous ne recueillons jamais",
         "Nous n'accédons ni à vos contacts, ni à votre calendrier, ni à votre photothèque (au-delà d'un fichier que vous joignez délibérément), ni à vos données de santé, ni aux identifiants publicitaires, et l'application n'enregistre pas de son. La vidéo de numérisation ne comporte aucune piste audio."),
        ("Pourquoi nous utilisons vos renseignements",
         "Pour exécuter notre contrat avec vous : produire et livrer les plans que vous commandez, encaisser le paiement et vous assister ensuite. Pour nos intérêts légitimes : maintenir la sécurité du service, prévenir les abus des promotions et améliorer la précision des consignes de capture. Pour respecter nos obligations légales : fiscalité, comptabilité et tenue de registres. Lorsque la loi exige un consentement — par exemple pour la localisation de l'appareil — nous le demandons, et vous pouvez le refuser ou le retirer dans les réglages de votre appareil."),
        ("Qui voit vos renseignements",
         "L'équipe de production de Cedar247 et les spécialistes du dessin qui travaillent sur votre commande voient les fichiers de numérisation, le libellé de la propriété et vos notes de commande, et sont tenus à des obligations de confidentialité. Nous faisons aussi appel à des prestataires de services qui traitent des données pour notre compte : hébergement infonuagique et stockage d'objets, notre prestataire de paiement et un prestataire d'envoi de courriels. Ils agissent uniquement sur nos instructions, et nous ne travaillons qu'avec des prestataires dont les conditions les obligent à protéger vos renseignements à un niveau au moins équivalent à celui prévu par la présente politique et à ne les utiliser que pour le service qu'ils nous fournissent. Nous pouvons divulguer des données si la loi l'exige, ou pour faire valoir ou défendre des droits en justice. Nous ne vendons pas de renseignements personnels et nous ne les communiquons pas à des courtiers en données."),
        ("La recherche d'adresse passe par Apple",
         "L'écran d'adresse s'appuie sur les services cartographiques d'Apple. Lorsque vous touchez le bouton de localisation, vos coordonnées sont envoyées à Apple pour être converties en adresse municipale ; ce bouton est entièrement facultatif. Les suggestions d'adresse fonctionnent différemment : à partir du troisième caractère, ce que vous tapez dans le champ d'adresse est envoyé à Apple pour obtenir la liste de suggestions, et cela se produit au fil de la frappe, que vous touchiez ou non une suggestion. Il en va de même pour la carte affichée en haut de l'écran d'adresse : elle charge les images cartographiques depuis Apple et, dès que vous avez tapé au moins cinq caractères, l'adresse est envoyée à Apple pour situer le repère affiché sur la carte. Cette version ne comporte aucun réglage pour désactiver l'une ou l'autre de ces fonctions. Apple traite ces données selon sa propre politique de confidentialité et nous n'en recevons rien d'autre que le texte d'adresse que vous obtenez en fin de compte — les coordonnées derrière le repère de la carte restent sur votre appareil et ne nous parviennent jamais."),
        ("Où vos renseignements sont conservés",
         "Nos prestataires d'hébergement et de stockage exercent leurs activités aux États-Unis et dans l'Union européenne ; vos renseignements peuvent donc être transférés hors de votre propre pays. Lorsque les transferts relèvent des règles européennes ou du Royaume-Uni, nous nous appuyons sur des clauses contractuelles types conclues avec ces prestataires."),
        ("Combien de temps nous les conservons",
         "Sur votre téléphone, les numérisations restent jusqu'à ce que vous les supprimiez — rien n'est supprimé automatiquement au bout d'un délai. Supprimer une propriété dans l'application supprime du téléphone les numérisations de cette propriété, et cela ne peut pas être annulé ; les copies que nous détenons pour votre commande ne sont pas concernées. Chaque numérisation est volumineuse ; supprimez donc les propriétés dont vous n'avez plus besoin pour récupérer de l'espace. De notre côté, nous conservons actuellement les fichiers de numérisation, les pièces jointes de commande et les dossiers de commande aussi longtemps qu'ils sont nécessaires à la commande et à ses registres ; un plan livré peut revenir pour révision, et les dossiers de commande sont exigés à des fins fiscales et comptables. Nous n'effectuons pas aujourd'hui de purge automatique de notre stockage. Les plans terminés restent disponibles en téléchargement pendant au moins 365 jours à compter de la livraison ; passé ce délai, nous pouvons les supprimer — conservez donc votre propre copie. Les pièces jointes de commande et les dossiers de commande survivent au compte lui-même — voyez \"Suppression de votre compte\" ci-dessous pour savoir exactement ce qui disparaît et ce qui reste. Si vous voulez que vos fichiers de numérisation soient supprimés plus tôt, supprimez votre compte ; pour les pièces jointes de commande, écrivez-nous par courriel et nous les supprimerons une fois la commande clôturée."),
        ("Suppression de votre compte",
         "Dans Compte, l'option Supprimer le compte supprime votre compte et, de notre stockage, vos fichiers de numérisation ainsi que vos éventuelles photos de visite virtuelle. Trois éléments y survivent délibérément. Premièrement, les commandes déjà passées restent dans nos registres commerciaux : le numéro, la date et le montant de la commande, ainsi que le nom et l'adresse courriel figurant sur la commande, l'adresse ou le libellé de la propriété que vous lui avez donné, vos notes de commande et la liste des fichiers qui l'accompagnaient — le droit fiscal exige ce registre, et un plan livré peut encore revenir pour révision. Deuxièmement, les fichiers encore nécessaires pour achever une commande que vous avez payée restent jusqu'à la clôture de cette commande ; détruire à mi-parcours un travail que vous avez payé serait, lui aussi, irréversible. Troisièmement, les fichiers que vous avez vous-même joints à une commande — un logo, un PDF annoté envoyé avec une demande de révision — restent attachés à cette commande. Écrivez à \(contactEmail) si vous souhaitez que ces pièces jointes et les renseignements personnels figurant sur les commandes clôturées soient supprimés, et nous le ferons partout où la loi nous le permet. La suppression du compte lui-même ne peut pas être annulée."),
        ("Vos droits",
         "Selon votre lieu de résidence, vous pouvez nous demander une copie de vos renseignements, nous demander de les rectifier, nous demander de les supprimer, demander la limitation de certains traitements ou vous y opposer, ou les demander dans un format portable. Écrivez à \(contactEmail) et nous vous répondrons dans les délais prévus par la loi. Si vous vous trouvez dans l'Espace économique européen ou au Royaume-Uni, vous pouvez aussi déposer une plainte auprès de votre autorité de contrôle ; si vous vous trouvez en Californie, vous pouvez exercer les droits conférés par la loi de cet État sans être traité différemment pour l'avoir fait."),
        ("Sécurité",
         "Le trafic entre l'application et nos serveurs est chiffré en transit. Les téléversements utilisent des liens de courte durée servant chacun à une seule fin, et chaque lien est rattaché au compte qui l'a demandé. Les mots de passe sont conservés uniquement sous forme d'empreintes. Un point à connaître : une fois un fichier téléversé, il réside à une adresse web longue et impossible à deviner qui fonctionne sans mot de passe, afin que notre équipe de dessin et vos liens de téléchargement continuent de fonctionner — traitez un lien vers votre numérisation ou votre plan comme vous traiteriez le fichier lui-même, et prévenez-nous si un lien a été partagé par erreur afin que nous puissions déplacer ou supprimer le fichier. Aucun système n'est parfait ; utilisez donc un mot de passe fort et unique et prévenez-nous immédiatement si vous pensez que quelqu'un d'autre a accédé à votre compte."),
        ("Enfants",
         "CedarScan est un outil professionnel et ne s'adresse pas aux enfants. Nous ne recueillons pas sciemment de renseignements auprès de personnes de moins de seize ans. Si vous pensez qu'un enfant nous a fourni des renseignements, écrivez-nous et nous les supprimerons."),
        ("Modifications",
         "Si nous modifions la présente politique, nous mettrons à jour la date figurant en haut et, pour toute modification substantielle, nous vous en informerons dans l'application ou par courriel. Continuer à utiliser CedarScan après une modification vaut acceptation de la politique mise à jour."),
        ("Langue",
         "Le présent document existe en anglais et en français. Si vous êtes un consommateur au Québec, la version française vous est remise et s'applique ; la version anglaise ne vous lie que si vous la choisissez expressément après avoir reçu la version française. Ailleurs, en cas de divergence entre les deux versions, la version anglaise prévaut dans la mesure où votre loi locale le permet. Vous pouvez nous écrire en anglais ou en français."),
        ("Contact",
         "\(legalEntity), \(postalAddress) — \(contactEmail)"),
    ]
}

extension LegalDoc {
    static let termsSectionsFR: [(String, String)] = [
        ("Les présentes conditions",
         "Les présentes conditions constituent le contrat entre vous et Cedar247 concernant l'application CedarScan et les services de dessin commandés par son intermédiaire. En créant un compte ou en passant une commande, vous les acceptez. Si vous commandez pour une société, vous confirmez que vous êtes autorisé à accepter les présentes conditions en son nom."),
        ("Votre compte",
         "Fournissez des renseignements exacts, gardez votre mot de passe pour vous et informez-nous rapidement si vous soupçonnez qu'une autre personne y a accès. Vous êtes responsable de ce qui se passe sous votre compte. Nous pouvons suspendre ou fermer un compte utilisé pour abuser du service, pour contourner les limites des promotions ou pour enfreindre les présentes conditions."),
        ("En quoi consiste le service",
         "Vous réalisez une numérisation tridimensionnelle d'une propriété avec l'application. Notre équipe dessine ensuite à la main, à partir de cette numérisation, les livrables que vous avez commandés. Sauf indication contraire dans votre commande, les plans sont livrés aux formats PDF et JPG ; les formats SVG ou PNG sont disponibles sur demande ; un fichier CAO DWG est une option payante. Les options supplémentaires telles que la mise en couleur, les plans d'implantation, le délai express et les visites virtuelles sont facturées séparément et ne sont incluses que lorsque vous les sélectionnez."),
        ("Votre part du travail",
         "Le dessin ne peut être meilleur que la numérisation. Suivez les consignes de l'onglet Apprendre : numérisez toute la propriété en un seul parcours continu lorsque c'est possible, gardez chaque mur, coin, porte et fenêtre dans le champ de vision, et vérifiez l'aperçu avant de commander. Vous confirmez que vous êtes en droit de numériser la propriété et de nous en transmettre le résultat — parce que vous en êtes propriétaire ou parce que vous avez la permission du propriétaire ou de l'occupant — et que toute personne présente a été informée que l'espace est enregistré en 3D."),
        ("Prix et promotions",
         "Les prix sont affichés dans l'application, en dollars américains, au moment où vous commandez, et c'est ce prix qui s'applique à cette commande. Les nouveaux comptes peuvent recevoir un nombre limité de commandes gratuites ; ce quota est compté par compte et par appareil, peut être modifié ou retiré à tout moment et ne peut pas être réparti entre des comptes supplémentaires créés pour en obtenir davantage. Les très grandes propriétés peuvent donner lieu à un supplément : nous en calculons le montant une fois la superficie mesurée et nous vous le communiquerons toujours avant de vous demander de le payer."),
        ("Paiement",
         "Les commandes payantes sont réglées par l'intermédiaire de notre page de paiement et de notre prestataire de paiement. La production commence une fois le paiement confirmé, sauf si la commande est couverte par le quota de commandes gratuites, auquel cas elle commence immédiatement. Si un paiement est annulé ou fait l'objet d'une rétrofacturation, nous pouvons suspendre la commande ou retenir les livrables jusqu'à ce que la situation soit résolue."),
        ("Délais de réalisation",
         "Les délais que nous indiquons sont des objectifs fondés sur une charge de travail normale, non des garanties, et ils courent à compter de la confirmation du paiement et de la fin du téléversement des fichiers de numérisation. L'option de délai express est un objectif plus rapide pour les habitations ordinaires ; elle ne s'applique pas aux très grandes propriétés, et une numérisation qui se révèle inutilisable prendra toujours plus de temps, car nous devons d'abord revenir vers vous."),
        ("Révisions",
         "Si nous avons commis une erreur — une porte manquante, une pièce mal étiquetée, une dimension erronée alors que la bonne mesure était lisible dans votre numérisation — signalez-le-nous via Commandes, Demander une révision, et nous la corrigerons gratuitement. Joignez une photo ou un fichier annoté si cela nous aide à repérer l'endroit. Les demandes qui modifient ce que vous aviez commandé à l'origine, ou qui nous demandent de dessiner une zone que votre numérisation ne couvre pas, constituent un nouveau travail et font l'objet d'un devis en conséquence. Les révisions sont disponibles pendant 90 jours après la livraison, à raison de trois au maximum par commande, conformément à la politique de révision publiée sur notre site web ; au-delà, ou une fois que vous nous avez demandé de supprimer les fichiers, il se peut que nous ne disposions plus des données sources."),
        ("Remboursements",
         "Vous pouvez annuler et être remboursé intégralement à tout moment avant que nous commencions à dessiner. Une fois le dessin commencé, nous rembourserons une part équitable du prix, appréciée selon la quantité de travail déjà effectuée. Si nous ne pouvons pas livrer du tout, vous récupérez la totalité. Si une numérisation est trop incomplète pour que nous puissions en tirer un dessin, nous vous en informerons avant d'accepter le travail, plutôt que de livrer quelque chose d'inutilisable."),
        ("Ce que les dessins sont et ne sont pas",
         "Les livrables sont produits à partir de la numérisation que vous fournissez et sont destinés au marketing, à la planification, à l'évaluation d'espaces et à d'autres usages courants du même ordre. Ils ne constituent ni un plan d'arpentage, ni un rapport structural, ni une mesure certifiée, et il ne faut pas s'y fier pour les limites légales de propriété, les demandes de permis, les travaux de structure ou tout autre usage où une erreur porterait à conséquence, à moins qu'un professionnel qualifié ne les ait vérifiés sur place. De petits écarts entre le dessin et le bâtiment sont normaux et inhérents à la numérisation."),
        ("À qui appartient quoi",
         "Vos numérisations, vos photos et les fichiers que vous joignez restent votre propriété. Vous accordez à Cedar247 une licence pour les stocker, les traiter et les adapter dans la mesure nécessaire pour produire et livrer votre commande, pour assurer l'assistance et les révisions, et pour conserver les registres que le présent contrat exige. Une fois votre commande payée — ou livrée dans le cadre du quota de commandes gratuites — les livrables finis vous appartiennent et vous pouvez les utiliser comme vous l'entendez, y compris à des fins commerciales. Nous pouvons conserver des mesures techniques anonymes concernant les numérisations, telles que la taille des fichiers et des indicateurs de qualité de capture, afin d'améliorer le service ; ces mesures ne vous identifient pas et n'identifient pas votre propriété. Nous ne publierons aucune image ni aucun dessin de votre propriété, ne les utiliserons à des fins de marketing ni ne les montrerons à un tiers sans vous le demander au préalable."),
        ("Utilisation acceptable",
         "N'utilisez pas CedarScan pour numériser une propriété que vous n'avez pas le droit de numériser, pour enregistrer des personnes à leur insu, pour enfreindre la loi, pour surcharger ou sonder nos systèmes, pour obtenir des livrables que vous n'avez pas payés, ou pour revendre l'accès à l'application elle-même. Revendre les dessins que nous réalisons pour vous, dans le cadre de votre propre service à votre propre client, est expressément autorisé — c'est ce que font bon nombre de nos clients."),
        ("Disponibilité",
         "Nous nous efforçons de maintenir le service en fonctionnement, mais nous ne promettons pas qu'il sera ininterrompu. La maintenance, les pannes de réseau et les changements apportés par Apple ou par nos fournisseurs peuvent tous l'interrompre. Nous pouvons ajouter, modifier ou retirer des fonctionnalités ; si un changement réduit de façon substantielle quelque chose que vous avez déjà payé mais que vous n'avez pas encore reçu, dites-le-nous et nous y remédierons."),
        ("Responsabilité",
         "Rien dans les présentes conditions n'exclut, ne restreint ni ne modifie un droit, une garantie ou un recours dont vous disposez en vertu d'une loi à laquelle il ne peut être légalement dérogé — y compris la responsabilité en cas de décès ou de préjudice corporel causés par notre négligence, et la responsabilité en cas de fraude. Si vous êtes un consommateur en Australie, nos services sont assortis de garanties au titre de l'Australian Consumer Law qui ne peuvent être exclues ; si vous êtes un consommateur en Nouvelle-Zélande, le Consumer Guarantees Act 1993 s'applique ; et les consommateurs de l'Union européenne, du Royaume-Uni et du Canada conservent les droits impératifs que leur confère leur propre loi. Les plafonds monétaires ci-dessous ne s'appliquent à aucune responsabilité qui nous incombe en vertu de ces lois. Sous cette réserve, et seulement dans la mesure où la loi le permet : le service et les livrables sont fournis sans autres garanties que celles que la loi implique ; Cedar247 n'est pas responsable des pertes indirectes ou consécutives, du manque à gagner, de la perte de revenus, de données ou d'occasions, ni des décisions prises sur la foi d'un dessin sans vérification indépendante ; et notre responsabilité totale découlant d'une commande est limitée au montant que vous avez payé pour cette commande, ou à cinquante dollars américains lorsque la commande était gratuite. Lorsque la loi nous permet de limiter la responsabilité pour manquement à une garantie du consommateur portant sur des services qui ne sont pas habituellement acquis à des fins personnelles, domestiques ou ménagères, cette responsabilité est limitée, à notre choix, à la fourniture des services à nouveau ou au paiement du coût d'une nouvelle fourniture de ces services."),
        ("Indemnisation",
         "Vous nous garantissez contre les réclamations formées par un tiers au motif que vous avez numérisé une propriété sans en avoir le droit, ou que les éléments que vous nous avez envoyés portaient atteinte aux droits d'autrui."),
        ("Fin du contrat",
         "Vous pouvez cesser d'utiliser CedarScan et supprimer votre compte à tout moment. Nous pouvons mettre fin au présent contrat si vous enfreignez les présentes conditions de manière grave ou répétée. La fin du contrat n'affecte ni les commandes déjà livrées ni les montants déjà dus."),
        ("Dispositions générales",
         "Si une partie des présentes conditions est inapplicable, le reste demeure applicable. Le fait de ne pas faire valoir une clause ne vaut pas renonciation à celle-ci. Les présentes conditions sont régies par le droit de l'État du Nouveau-Mexique, États-Unis, sans égard à ses règles de conflit de lois. Si vous êtes un consommateur, ce choix ne vous prive pas de la protection des dispositions de la loi de votre pays de résidence auxquelles il ne peut être dérogé par convention ; un consommateur peut engager une procédure devant les tribunaux de son propre pays de résidence, et nous n'engagerons de procédure contre un consommateur que devant les tribunaux du pays où ce consommateur vit. Nous pouvons mettre à jour les présentes conditions et afficherons la nouvelle date en haut du document ; les modifications substantielles seront notifiées dans l'application ou par courriel."),
        ("Langue",
         "Le présent document existe en anglais et en français. Si vous êtes un consommateur au Québec, la version française vous est remise et s'applique ; la version anglaise ne vous lie que si vous la choisissez expressément après avoir reçu la version française. Ailleurs, en cas de divergence entre les deux versions, la version anglaise prévaut dans la mesure où votre loi locale le permet. Vous pouvez nous écrire en anglais ou en français."),
        ("Contact",
         "\(legalEntity), \(postalAddress) — \(contactEmail)"),
    ]
}

extension LegalDoc {
    static let eulaSectionsFR: [(String, String)] = [
        ("La présente licence",
         "Le présent Contrat de licence d'utilisateur final régit votre utilisation de l'application CedarScan elle-même. Les services que vous commandez par l'intermédiaire de l'application sont régis par nos Conditions générales, et le traitement de vos données par notre Politique de confidentialité. En installant ou en utilisant l'application, vous acceptez la présente licence ; si vous ne l'acceptez pas, supprimez l'application."),
        ("Ce que vous pouvez faire",
         "Cedar247 vous concède une licence personnelle, non exclusive, non transférable et révocable vous autorisant à installer et à utiliser CedarScan sur des appareils de marque Apple que vous possédez ou contrôlez, pour vos propres besoins professionnels ou privés, conformément aux Règles d'utilisation des Apple Media Services Terms and Conditions (conditions générales des services multimédias d'Apple). L'application peut également être consultée et utilisée par d'autres comptes qui vous sont associés, en votre qualité d'acheteur, par l'intermédiaire du Family Sharing (partage familial) ou des achats en volume. La licence porte sur l'utilisation de l'application, non sur sa propriété."),
        ("Ce que vous ne pouvez pas faire",
         "Vous ne devez pas copier, vendre, louer, sous-licencier ni redistribuer l'application. Vous ne devez pas la modifier, la traduire, la décompiler, la désassembler ni en faire l'ingénierie inverse, ni tenter d'en reconstituer le code source, sauf dans la mesure où la loi le permet expressément malgré cette restriction. Vous ne devez pas retirer ni masquer les mentions de propriété. Vous ne devez pas contourner les limites techniques, telles que le quota de commandes gratuites ou les restrictions de téléversement, et vous ne devez pas accéder à nos serveurs par un autre moyen que l'application elle-même."),
        ("Propriété",
         "CedarScan, son interface, son code et tout ce qu'elle contient appartiennent à Cedar247 ou à ses concédants de licence et sont protégés par le droit d'auteur et d'autres lois. Vous ne recevez que les droits énoncés dans la présente licence ; rien d'autre ne vous est concédé, ni implicitement ni autrement."),
        ("Votre contenu",
         "Les numérisations, photos et fichiers que vous créez ou téléversez demeurent les vôtres. La licence que vous nous accordez pour les traiter, ainsi que les limites de ce que nous pouvons en faire, sont énoncées dans nos Conditions générales et notre Politique de confidentialité."),
        ("Ce dont l'application a besoin",
         "CedarScan nécessite un iPhone doté d'un capteur LiDAR — un iPhone 12 Pro ou un modèle Pro ultérieur — fonctionnant sous iOS 17 ou une version ultérieure. L'application a besoin de l'accès à la caméra pour numériser ; sans cet accès, la numérisation ne peut pas fonctionner. L'accès à la localisation est facultatif et sert uniquement à préremplir l'adresse d'une propriété lorsque vous le demandez. Le téléversement des numérisations et la passation de commandes nécessitent une connexion Internet et un compte."),
        ("Mises à jour et modifications",
         "Nous pouvons publier des mises à jour, et certaines peuvent être nécessaires pour que l'application continue de fonctionner avec nos serveurs. Des fonctionnalités peuvent être ajoutées, modifiées ou supprimées au fil du temps. Les mises à jour sont régies par la présente licence, sauf si elles sont accompagnées de leurs propres conditions."),
        ("Services de tiers",
         "L'application repose sur des services que nous ne contrôlons pas, notamment les cadres logiciels de la plateforme d'Apple, nos fournisseurs d'hébergement infonuagique et de stockage et notre prestataire de paiement. Leurs conditions s'appliquent à leur partie du service, et nous ne sommes pas responsables de la manière dont ces tiers exercent leurs activités. Vous vous engagez à respecter toutes les conditions de tiers applicables à votre utilisation de l'application."),
        ("Absence de garantie",
         "Nous fournissons l'application avec un soin et une compétence raisonnables. Nous ne garantissons pas que l'application fonctionnera sans interruption ni sans erreur, ni qu'une numérisation réussira toujours, quels que soient la propriété et les conditions d'éclairage. Rien dans la présente licence n'exclut, ne restreint ni ne modifie une garantie, un droit ou un recours dont vous bénéficiez en vertu d'une loi et qui ne peut pas être légalement exclu. Si vous êtes en Australie, nos biens et services sont assortis de garanties qui ne peuvent pas être exclues en vertu de l'Australian Consumer Law ; si vous êtes en Nouvelle-Zélande, le Consumer Guarantees Act 1993 s'applique ; et les consommateurs de l'Union européenne, du Royaume-Uni et du Canada conservent les droits impératifs que leur confère leur propre loi. Toute exclusion de garantie de qualité marchande, d'adéquation à un usage particulier ou d'absence de contrefaçon figurant dans la présente licence ne s'applique pas à vous dans la mesure où elle exclurait, restreindrait ou modifierait une telle garantie. En dehors de ces cas, et dans toute la mesure permise par votre loi locale, l'application est fournie telle quelle et selon sa disponibilité."),
        ("Limitation de responsabilité",
         "Rien dans la présente clause n'exclut ni ne limite une responsabilité qui ne peut pas être légalement exclue ou limitée, et le plafond de cinquante dollars américains ci-dessous ne s'applique pas lorsque votre loi locale ne le permet pas — y compris aux consommateurs d'Australie et de Nouvelle-Zélande. Sous cette réserve, et dans toute la mesure permise par la loi, Cedar247 n'est pas responsable des pertes indirectes ou consécutives découlant de votre utilisation de l'application, y compris un manque à gagner, une perte de données ou une numérisation devant être recommencée, et notre responsabilité totale au titre de la présente licence est limitée à cinquante dollars américains, ce qui reflète le fait que l'application est fournie gratuitement."),
        ("Durée et résiliation",
         "La présente licence demeure en vigueur jusqu'à sa résiliation. Elle prend fin automatiquement si vous enfreignez l'une de ses conditions, et vous pouvez y mettre fin à tout moment en supprimant l'application. Les articles relatifs à la propriété, à la garantie, à la responsabilité et aux dispositions générales survivent à la résiliation."),
        ("Apple",
         "La présente licence est conclue entre vous et Cedar247 uniquement, et non avec Apple, et Cedar247 est seule responsable de l'application et de son contenu. Cedar247, et non Apple, est seule responsable de la fourniture de tout service de maintenance et d'assistance relatif à l'application, et Apple n'a aucune obligation d'en fournir. Si l'application ne se conforme pas à une garantie applicable, vous pouvez en aviser Apple, et Apple vous remboursera le prix d'achat de l'application, le cas échéant ; dans toute la mesure permise par la loi, Apple n'a aucune autre obligation de garantie, quelle qu'elle soit, à l'égard de l'application, et toute autre réclamation, perte, responsabilité et tout autre dommage, coût ou frais attribuables à un défaut de conformité à une garantie relèvent de la seule responsabilité de Cedar247. Cedar247, et non Apple, est responsable du traitement de toute réclamation de votre part ou de la part d'un tiers relative à l'application, y compris les réclamations en responsabilité du fait des produits, toute réclamation selon laquelle l'application ne se conforme pas à une exigence légale ou réglementaire, et les réclamations fondées sur la législation en matière de protection des consommateurs ou de protection des renseignements personnels, ou sur toute législation similaire. Cedar247, et non Apple, est responsable de l'enquête, de la défense, du règlement et de la décharge de toute réclamation d'un tiers selon laquelle l'application porte atteinte à des droits de propriété intellectuelle. Apple et ses filiales sont des tiers bénéficiaires de la présente licence et, dès votre acceptation de celle-ci, Apple aura le droit — et sera réputée avoir accepté le droit — de la faire valoir à votre encontre en qualité de tiers bénéficiaire. Toute question, plainte ou réclamation concernant l'application doit être adressée à \(legalEntity), \(postalAddress), \(contactEmail)."),
        ("Exportation et conformité",
         "Vous confirmez que vous n'êtes pas situé dans un pays faisant l'objet d'un embargo du gouvernement des États-Unis ou désigné par celui-ci comme un pays soutenant le terrorisme, et que vous ne figurez sur aucune liste du gouvernement des États-Unis recensant des parties interdites ou soumises à des restrictions. Vous n'utiliserez l'application qu'en conformité avec la loi applicable."),
        ("Dispositions générales",
         "Si une disposition de la présente licence est inapplicable, le reste demeure en vigueur. La présente licence est régie par le droit de l'État du Nouveau-Mexique, États-Unis, sans égard à ses règles de conflit de lois. Si vous êtes un consommateur, ce choix ne vous prive pas de la protection des dispositions de la loi de votre pays de résidence auxquelles il ne peut être dérogé par convention, et vous pouvez engager une procédure devant les tribunaux de votre propre pays de résidence. La présente licence constitue l'intégralité de l'accord entre vous et Cedar247 au sujet de l'application elle-même."),
        ("Langue",
         "Le présent document existe en anglais et en français. Si vous êtes un consommateur au Québec, la version française vous est remise et s'applique ; la version anglaise ne vous lie que si vous la choisissez expressément après avoir reçu la version française. Ailleurs, en cas de divergence entre les deux versions, la version anglaise prévaut dans la mesure où votre loi locale le permet. Vous pouvez nous écrire en anglais ou en français."),
        ("Contact",
         "\(legalEntity), \(postalAddress) — \(contactEmail)"),
    ]
}

// MARK: - Hết bản tiếng Pháp

// MARK: - Views

/// Một văn bản pháp lý, cuộn được. Đẩy vào NavigationStack của tab Tài khoản.
struct LegalDocumentView: View {
    let doc: LegalDoc

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Last updated: \(LegalDoc.displayLastUpdated)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(doc.sections) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.heading)
                            .font(.headline)
                        Text(section.text)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            // Văn bản dài + chọn được chữ: khách copy được đoạn cần gửi cho luật sư/kế toán của họ.
            .textSelection(.enabled)
        }
        .navigationTitle(doc.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Ba dòng link, dùng trong `List` của tab Tài khoản.
///
/// Là `View` chứ không phải `Section` để dùng lại được ở cả nhánh CHƯA đăng nhập (nơi màn hình là
/// `ScrollView`, không phải `List`) — App Store review mở app lần đầu là chưa đăng nhập, mà văn
/// bản pháp lý thì phải với tới được ngay lúc đó.
struct LegalLinks: View {
    var body: some View {
        ForEach(LegalDoc.allCases) { doc in
            NavigationLink {
                LegalDocumentView(doc: doc)
            } label: {
                Label(doc.title, systemImage: doc.icon)
            }
        }
    }
}
