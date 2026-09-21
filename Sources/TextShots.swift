import SwiftUI

/// THROWAWAY (branch claude/textcut-audit only, never main): open one screen with long content
/// for simulator screenshots. `-textshot <screen>`.
enum TextShots {
    static let screen: String? = {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-textshot"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }()

    static let project1 = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let project2 = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let projectName = "Wohnhaus Familie Schmidt-Hoffmann, Hauptstraße 123, 80331 München-Altstadt"
    static let floor1 = "Erdgeschoss mit Wintergarten und Terrasse"
    static let floor2 = "Obergeschoss und ausgebauter Dachboden"

    /// Runs in `CedarScanApp.init`, before `ScanStore()` reads Documents.
    static func seed() {
        guard let screen else { return }
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let scans = docs.appendingPathComponent("Scans", isDirectory: true)
        try? fm.removeItem(at: scans)
        try? fm.removeItem(at: docs.appendingPathComponent("projects.json"))
        UserDefaults.standard.set(true, forKey: ScanGuideView.seenKey)
        if screen == "home-empty" { return }
        try? fm.createDirectory(at: scans, withIntermediateDirectories: true)
        let now = Date()
        let projects = [
            ScanProject(id: project1, name: projectName, createdAt: now),
            ScanProject(id: project2, name: "Ferienhaus am See, Uferweg 7, 82211 Herrsching am Ammersee", createdAt: now.addingTimeInterval(-86400)),
        ]
        try? JSONEncoder().encode(projects).write(to: docs.appendingPathComponent("projects.json"))
        let records = [
            ScanRecord(id: UUID(), name: floor1, createdAt: now, roomCount: 0, areaSqm: 142.5, projectId: project1, qualityScore: 48, qualityGrade: "D", qualityRescan: true),
            ScanRecord(id: UUID(), name: floor2, createdAt: now.addingTimeInterval(-600), roomCount: 0, areaSqm: 98, cloudScanId: "x", cloudOrderNumber: "#LS-MRAT7XNG6", projectId: project1),
            ScanRecord(id: UUID(), name: "Keller, Heizungsraum und Garage mit Werkstatt", createdAt: now.addingTimeInterval(-1200), roomCount: 0, areaSqm: 61),
        ]
        for r in records {
            let dir = scans.appendingPathComponent(r.id.uuidString, isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? JSONEncoder().encode(r).write(to: dir.appendingPathComponent("meta.json"))
        }
    }
}

struct TextShotRoot: View {
    @EnvironmentObject private var store: ScanStore
    @EnvironmentObject private var account: AccountStore
    @State private var name = ""
    @State private var alert = true

    var body: some View {
        switch TextShots.screen ?? "" {
        case "legal-privacy": NavigationStack { LegalDocumentView(doc: .privacy) }
        case "legal-terms": NavigationStack { LegalDocumentView(doc: .terms) }
        case "legal-eula": NavigationStack { LegalDocumentView(doc: .eula) }
        case "faq": NavigationStack { OrderFAQContent().navigationTitle(String(localized: "Order Q&A")) }
        case "guide": ScanGuideView(onStart: {})
        case "learn": LearnView()
        case "account": NavigationStack { AccountView() }
        case "forgot": NavigationStack { ForgotPasswordView() }
        case "delete": NavigationStack { DeleteAccountView() }
        case "home", "home-empty":
            HomeView(scanRequest: 0, openProjectRequest: nil, store: store, account: account)
        case "project":
            NavigationStack {
                ProjectView(store: store, account: account, projectId: TextShots.project1,
                            projectName: TextShots.projectName, path: .constant(NavigationPath()))
            }
        case "project-empty":
            NavigationStack {
                ProjectView(store: store, account: account, projectId: TextShots.project2,
                            projectName: "Ferienhaus am See, Uferweg 7, 82211 Herrsching am Ammersee", path: .constant(NavigationPath()))
            }
        case "detail":
            if let r = store.records.first(where: { $0.name == TextShots.floor1 }) {
                NavigationStack { ScanDetailView(record: r, autoOpenOrder: false, store: store, account: account) }
            }
        case "supplement":
            SupplementSheet(records: Array(store.records.prefix(2)), orderNumber: "#LS-MRAT7XNG6")
        case "orders": OrdersView(store: store, onOpenProject: { _ in })
        case "preview":
            ScanPreviewView(addressName: TextShots.projectName, scanName: TextShots.floor1, videoURL: nil,
                            meshPreviewURL: nil, onScanMore: {}, onOrderLater: {}, onOrderNow: {})
        case "name":
            ScanNameOverlay(name: $name, subtitle: String(localized: "Which area of the property is this?"),
                            suggestions: [String(localized: "Main floor"), String(localized: "Basement"), String(localized: "Upper floor"),
                                          String(localized: "Shed"), String(localized: "Garage"), String(localized: "Storage")],
                            typeAheadSuggestions: [], onSave: {}, onBack: {})
        case "alert-part":
            Color.gray.opacity(0.2).alert(String(localized: "Part of the home is missing"), isPresented: $alert) {
                Button(String(localized: "Scan the rest now")) {}
                Button(String(localized: "Scan later"), role: .cancel) {}
            } message: {
                Text(String(localized: "The 3D model hit its size limit before you finished — the saved part is safe. Scan the remaining area as another scan (name them \"Part 1\", \"Part 2\"…) and they can be merged later."))
            }
        case "alert-delete":
            Color.gray.opacity(0.2).alert(DeleteProjectPrompt.title, isPresented: $alert) {
                Button(DeleteProjectPrompt.confirmLabel(scanCount: 3), role: .destructive) {}
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text(DeleteProjectPrompt.message(scanCount: 3))
            }
        case "dialog-lowquality":
            Color.gray.opacity(0.2).confirmationDialog(String(localized: "Some scans have low quality"), isPresented: $alert, titleVisibility: .visible) {
                Button(String(localized: "Order anyway")) {}
                Button(String(localized: "I'll rescan first"), role: .cancel) {}
            } message: {
                Text(String(localized: "Rescanning the flagged floors usually gives a more accurate floor plan: \(TextShots.floor1). You can still order — our team will be notified."))
            }
        case "dialog-scanquality":
            Color.gray.opacity(0.2).confirmationDialog(String(localized: "Scan quality is low"), isPresented: $alert, titleVisibility: .visible) {
                Button(String(localized: "Order anyway")) {}
                Button(String(localized: "I'll rescan first"), role: .cancel) {}
            } message: {
                Text(String(localized: "This scan scored \(48)/100. Rescanning usually gives a more accurate floor plan. You can still order — our team will be notified about the quality."))
            }
        default: Text(verbatim: "unknown screen")
        }
    }
}
