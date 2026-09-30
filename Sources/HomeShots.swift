import SwiftUI
import UIKit

/// THROWAWAY (branch claude/home-bottom-shots, never main): Home with N properties on the REAL
/// launch path (RootView + CedarTabBar). `-homeShots N`, optional `-homeFix <variant>`.
enum HomeShots {
    static let count: Int? = {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-homeShots"), i + 1 < a.count else { return nil }
        return Int(a[i + 1])
    }()
    static var on: Bool { count != nil }
    static let fix: String = {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-homeFix"), i + 1 < a.count else { return "none" }
        return a[i + 1]
    }()

    static let streets = ["Elm Street", "Maple Court", "Oak Avenue", "Birch Lane", "Cedar Road",
                          "Pine Drive", "Willow Way", "Aspen Place"]

    /// JSON only (no images/video): nothing here touches UIKit before the app is up.
    static func seed() {
        guard let count else { return }
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let scans = docs.appendingPathComponent("Scans", isDirectory: true)
        try? fm.removeItem(at: scans)
        try? fm.removeItem(at: docs.appendingPathComponent("projects.json"))
        try? fm.createDirectory(at: scans, withIntermediateDirectories: true)
        UserDefaults.standard.set(true, forKey: ScanGuideView.seenKey)
        let now = Date()
        var projects: [ScanProject] = []
        for i in 0..<count {
            let id = UUID()
            let name = "\(100 + i) \(streets[i % streets.count]), Springfield, IL 62701"
            projects.append(ScanProject(id: id, name: name, createdAt: now.addingTimeInterval(Double(-i) * 86400)))
            let r = ScanRecord(id: UUID(), name: "Main floor", createdAt: now, roomCount: 0,
                               cloudOrderNumber: i % 3 == 1 ? "#1\(i)00" : nil, projectId: id)
            let dir = scans.appendingPathComponent(r.id.uuidString, isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? JSONEncoder().encode(r).write(to: dir.appendingPathComponent("meta.json"))
        }
        let a = ProcessInfo.processInfo.arguments
        if let i = a.firstIndex(of: "-homeLoose"), i + 1 < a.count, let loose = Int(a[i + 1]) {
            for k in 0..<loose {
                let r = ScanRecord(id: UUID(), name: "Old scan \(k + 1)", createdAt: now, roomCount: 0,
                                   cloudOrderNumber: nil, projectId: nil)
                let dir = scans.appendingPathComponent(r.id.uuidString, isDirectory: true)
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try? JSONEncoder().encode(r).write(to: dir.appendingPathComponent("meta.json"))
            }
        }
        try? JSONEncoder().encode(projects).write(to: docs.appendingPathComponent("projects.json"))
    }

    /// A/B on Home's list.
    struct Fix: ViewModifier {
        func body(content: Content) -> some View {
            switch HomeShots.fix {
            case "margins":
                content.contentMargins(.bottom, CedarTabBar.reservedHeight, for: .scrollContent)
            case "padding":
                content.safeAreaPadding(.bottom, CedarTabBar.reservedHeight)
            default:
                content
            }
        }
    }
}

extension HomeShots {
    /// A/B on the list style: "grouped" = non-sticky headers; "row" = plain + small min row height.
    struct Style: ViewModifier {
        func body(content: Content) -> some View {
            switch HomeShots.fix {
            case "grouped":
                content.listStyle(.grouped)
            case "row":
                content.listStyle(.plain).environment(\.defaultMinListRowHeight, 10)
            default:
                content.listStyle(.plain)
            }
        }
    }
}

/// Every visible vertical scroll view: frame in window, insets, content size, offset.
struct HomeProbe: View {
    @State private var text = "probe"
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(text)
            .font(.system(size: 6, design: .monospaced))
            .foregroundStyle(Color.gray.opacity(0.6))
            .frame(maxWidth: 200, alignment: .leading)
            .allowsHitTesting(false)
            .accessibilityIdentifier("homeProbe")
            .accessibilityLabel(text)
            .onReceive(timer) { _ in text = Self.measure() }
    }

    @MainActor static func measure() -> String {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).filter { $0.isKeyWindow }
        guard let window = windows.first else { return "no window" }
        var out = ["win h\(Int(window.bounds.height)) safeB\(Int(window.safeAreaInsets.bottom))"]
        func walk(_ v: UIView) {
            if let s = v as? UIScrollView, s.window != nil, !s.isHidden, s.alpha > 0.01,
               s.bounds.height > 200, s.bounds.width > 200 {
                let f = s.convert(s.bounds, to: window)
                if f.intersects(window.bounds) {
                    let maxOff = s.contentSize.height + s.adjustedContentInset.bottom - s.bounds.height
                    out.append("\(type(of: s)) y\(Int(f.minY))-\(Int(f.maxY)) cs\(Int(s.contentSize.height)) off\(Int(s.contentOffset.y)) maxOff\(Int(maxOff)) adjT\(Int(s.adjustedContentInset.top)) adjB\(Int(s.adjustedContentInset.bottom)) ciB\(Int(s.contentInset.bottom)) safeB\(Int(s.safeAreaInsets.bottom)) beh\(s.contentInsetAdjustmentBehavior.rawValue)")
                }
            }
            v.subviews.forEach(walk)
        }
        walk(window)
        return out.joined(separator: " | ")
    }
}
