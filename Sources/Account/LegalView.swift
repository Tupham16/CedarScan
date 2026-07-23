import SwiftUI

/// Ba văn bản pháp lý bắt buộc cho App Store: Privacy Policy · Terms and Conditions · EULA.
///
/// **VĂN BẢN NẰM TRONG APP, KHÔNG PHẢI LINK WEB** — cố ý. App được dùng ở công trường sóng yếu,
/// và App Store review cũng mở mục này khi máy chưa đăng nhập; một cái link chết là một vòng bị
/// từ chối. Đổi lại: sửa câu chữ = phải build lại app.
///
/// **TIẾNG ANH, KHÔNG song ngữ** — khác mọi màn khác trong app. Khách của Cedar247 là khách nước
/// ngoài (giá USD, địa chỉ Mỹ), và một văn bản pháp lý dịch hai thứ tiếng thì phải ghi rõ bản nào
/// có hiệu lực khi hai bản lệch nhau. Nếu sau này cần bản tiếng Việt thì thêm bản dịch KÈM một
/// câu "bản tiếng Anh là bản có hiệu lực", đừng dùng `L.t` trộn lẫn từng câu.
///
/// ⚠ Nội dung dưới đây mô tả ĐÚNG những gì app/server đang làm thật (id thiết bị cho suất miễn
/// phí, tự xoá bản quét TRÊN MÁY sau khi giao 14 ngày, PDF+JPG mặc định / DWG tính tiền, MapKit/
/// CLGeocoder gửi dữ liệu sang Apple). Đổi hành vi app mà quên sửa ở đây là văn bản nói sai —
/// nguy hiểm hơn không có văn bản.
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
        case .privacy: return "Privacy Policy"
        case .terms: return "Terms and Conditions"
        case .eula: return "End User Licence Agreement"
        }
    }

    var icon: String {
        switch self {
        case .privacy: return "hand.raised"
        case .terms: return "doc.text"
        case .eula: return "checkmark.seal"
        }
    }

    /// Ngày cập nhật in ở đầu mỗi văn bản. SỬA NỘI DUNG THÌ SỬA CẢ NGÀY NÀY.
    static let lastUpdated = "23 July 2026"

    static let contactEmail = "hello@cedar247.com"

    var sections: [LegalSection] {
        let raw: [(String, String)]
        switch self {
        case .privacy: raw = Self.privacySections
        case .terms: raw = Self.termsSections
        case .eula: raw = Self.eulaSections
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
         "The Cedar247 production team and the drafting specialists working on your order see the scan files, the property label and your order notes, under confidentiality obligations. We also use service providers who process data on our behalf: cloud hosting and object storage, our payment provider, and an email delivery provider. They act on our instructions only. We may disclose data if the law requires it, or to establish or defend legal claims. We do not sell personal data and we do not share it with data brokers."),
        ("Address look-up uses Apple",
         "The two shortcuts on the address screen are powered by Apple's mapping services. When you tap the location button, your coordinates are sent to Apple to be turned into a street address; that button is entirely optional. Address suggestions work differently: from the third character onwards, what you type in the address field is sent to Apple to fetch the suggestion list, and that happens as you type whether or not you tap a suggestion. There is no switch for it in this version. Apple handles that data under its own privacy policy and we receive nothing from it beyond the address text you end up with."),
        ("Where your data is held",
         "Our hosting and storage providers operate in the United States and the European Union, so your data may be transferred outside your own country. Where transfers are covered by European or United Kingdom rules, we rely on standard contractual clauses with those providers."),
        ("How long we keep it",
         "On your phone, the app clears the scans of an order automatically about fourteen days after that order has been delivered, so a finished job does not sit on your device forever — download anything you still need before then. On our side we currently keep scan files, order attachments and order records for as long as they are needed for the order and its records; a delivered drawing can come back for revision, and order records are required for tax and accounting. We do not run an automatic purge on our storage today. Order attachments and order records outlive the account itself — see \"Deleting your account\" below for exactly what goes and what stays. If you want your scan files removed sooner, delete your account; for order attachments, email us and we will remove them once the order is closed."),
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
        ("Contact",
         "Cedar247 — \(contactEmail)"),
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
         "If we made a mistake — a missing door, a mislabelled room, a wrong dimension we could have read from your scan — tell us through Orders, Request a revision, and we will fix it free of charge. Attach a photo or a marked-up file if it helps us find the spot. Requests that change what you originally ordered, or that ask us to draw an area your scan does not cover, are new work and are quoted as such. Revisions are available for a reasonable period after delivery; after that, or once you have asked us to delete the files, we may no longer have the source data."),
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
         "Nothing in these terms limits liability for death or personal injury caused by negligence, for fraud, or for anything else that cannot lawfully be limited. Subject to that, the service and the deliverables are provided without any warranty beyond those the law implies, and Cedar247 is not liable for indirect or consequential loss, for lost profit, revenue, data or opportunity, or for decisions taken in reliance on a drawing without independent verification. Our total liability arising from an order is limited to the amount you paid for that order; where the order was free, it is limited to fifty United States dollars."),
        ("Indemnity",
         "You will cover us against claims brought by a third party because you scanned a property without the right to do so, or because the material you sent us infringed someone's rights."),
        ("Ending the agreement",
         "You may stop using CedarScan and delete your account at any time. We may end this agreement if you break these terms seriously or repeatedly. Ending it does not affect orders already delivered or amounts already owed."),
        ("General",
         "If any part of these terms is unenforceable, the rest still applies. Failing to enforce a term is not a waiver of it. These terms are governed by the laws applicable at Cedar247's place of business, and the courts there have jurisdiction; if you deal with us as a consumer, this does not take away rights you have under the law of your own country. We may update these terms and will show the new date at the top; material changes will be notified in the app or by email."),
        ("Contact",
         "Cedar247 — \(contactEmail)"),
    ]
}

// MARK: - End User Licence Agreement

extension LegalDoc {
    static let eulaSections: [(String, String)] = [
        ("This licence",
         "This End User Licence Agreement governs your use of the CedarScan application itself. The services you order through the app are covered by our Terms and Conditions, and the handling of your data by our Privacy Policy. Installing or using the app means you accept this licence; if you do not accept it, delete the app."),
        ("What you may do",
         "Cedar247 grants you a personal, non-exclusive, non-transferable, revocable licence to install and use CedarScan on Apple-branded devices that you own or control, for your own business or private purposes, in accordance with the Usage Rules of the Apple Media Services Terms and Conditions. The licence covers use of the app, not ownership of it."),
        ("What you may not do",
         "Do not copy, sell, rent, sublicense or redistribute the app. Do not modify, translate, decompile, disassemble or reverse engineer it, or try to derive its source code, except to the extent the law expressly permits despite this restriction. Do not remove or obscure any notice of ownership. Do not work around technical limits such as the free-order allowance or upload restrictions, and do not access our servers with anything other than the app itself."),
        ("Ownership",
         "CedarScan, its interface, its code and everything in it belong to Cedar247 or its licensors and are protected by copyright and other laws. You receive only the rights this licence states; nothing else is granted, by implication or otherwise."),
        ("Your content",
         "Scans, photos and files you create or upload remain yours. The licence you give us to process them, and the limits on what we may do with them, are set out in our Terms and Conditions and Privacy Policy."),
        ("What the app needs",
         "CedarScan requires an Apple device with a LiDAR sensor — an iPhone 12 Pro or a later Pro model, or an iPad Pro from 2020 onwards — running iOS or iPadOS 17 or later. It needs camera access to scan; without it, scanning cannot run. Location access is optional and used only to fill in a property address when you ask it to. Uploading scans and placing orders require an internet connection and an account."),
        ("Updates and changes",
         "We may release updates, and some may be required for the app to keep working with our servers. Features may be added, changed or removed over time. Updates are covered by this licence unless they come with their own terms."),
        ("Third-party services",
         "The app relies on services we do not control, including Apple's platform frameworks, our cloud hosting and storage providers, and our payment provider. Their terms apply to their part of the service, and we are not responsible for how those third parties operate. You agree to comply with any third-party terms that apply to your use of the app."),
        ("No warranty",
         "The app is provided as is and as available. To the fullest extent the law allows, Cedar247 disclaims all warranties, express or implied, including merchantability, fitness for a particular purpose and non-infringement. We do not warrant that the app will be uninterrupted or error-free, or that a scan will always succeed on every property or in every lighting condition."),
        ("Limitation of liability",
         "To the fullest extent the law allows, Cedar247 is not liable for indirect or consequential loss arising from your use of the app, including lost profit, lost data or a scan that has to be repeated. Our total liability under this licence is limited to fifty United States dollars, which reflects the fact that the app is supplied free of charge. Nothing here limits liability that cannot lawfully be limited."),
        ("Term and termination",
         "This licence runs until terminated. It ends automatically if you break any of its terms, and you may end it at any time by deleting the app. The sections on ownership, warranty, liability and general provisions survive termination."),
        ("Apple",
         "This licence is between you and Cedar247 only, not with Apple, and Cedar247 alone is responsible for the app and its content. Cedar247, not Apple, is solely responsible for providing any maintenance and support services for the app, and Apple has no obligation to provide any. If the app fails to conform to any applicable warranty, you may notify Apple, and Apple will refund the purchase price of the app, if any; to the maximum extent permitted by law, Apple has no other warranty obligation whatsoever with respect to the app. Cedar247, not Apple, is responsible for addressing any claim by you or a third party relating to the app, including product liability claims, any claim that the app fails to conform to a legal or regulatory requirement, and claims arising under consumer protection or similar legislation. Cedar247, not Apple, is responsible for the investigation, defence, settlement and discharge of any third-party claim that the app infringes intellectual property rights. Apple and its subsidiaries are third-party beneficiaries of this licence and may enforce it against you. Any questions, complaints or claims about the app should be sent to \(contactEmail)."),
        ("Export and compliance",
         "You confirm that you are not located in a country subject to a United States government embargo or designated as a terrorist-supporting country, and that you are not listed on any United States government list of prohibited or restricted parties. You will use the app only in compliance with applicable law."),
        ("General",
         "If any provision of this licence is unenforceable, the rest remains in force. This licence is governed by the laws applicable at Cedar247's place of business, without regard to conflict-of-law rules. It is the entire agreement between you and Cedar247 about the app itself."),
        ("Contact",
         "Cedar247 — \(contactEmail)"),
    ]
}

// MARK: - Views

/// Một văn bản pháp lý, cuộn được. Đẩy vào NavigationStack của tab Tài khoản.
struct LegalDocumentView: View {
    let doc: LegalDoc

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Last updated: \(LegalDoc.lastUpdated)")
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
