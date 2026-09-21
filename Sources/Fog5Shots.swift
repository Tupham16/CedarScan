import SwiftUI

/// THROWAWAY (branch claude/fog5-shots only, never main): render the scan screen in the simulator.
enum Fog5 {
    static let on = ProcessInfo.processInfo.arguments.contains("-fog5shots")
    static let white = ProcessInfo.processInfo.arguments.contains("-fog5white")
    static let banner = ProcessInfo.processInfo.arguments.contains("-fog5banner")
    static let probe = ProcessInfo.processInfo.arguments.contains("-fog5probe")
    static let v1 = ProcessInfo.processInfo.arguments.contains("-fog5v1")
    static let v2 = ProcessInfo.processInfo.arguments.contains("-fog5v2")
}

/// THROWAWAY: frame outline + size label (points, 2 decimals).
struct Fog5Probe: ViewModifier {
    let tag: String
    let corner: Alignment

    @ViewBuilder
    func body(content: Content) -> some View {
        if Fog5.probe {
            content
                .border(Color.green, width: 0.5)
                .overlay(alignment: corner) {
                    GeometryReader { g in
                        Text(tag + " " + String(format: "%.2f x %.2f", g.size.width, g.size.height))
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.green)
                            .background(Color.black)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner)
                    }
                }
        } else {
            content
        }
    }
}

/// THROWAWAY: candidate fixes for the German note truncation.
struct Fog5NoteVariant: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if Fog5.v1 {
            content.frame(maxWidth: .infinity, alignment: .leading)
        } else if Fog5.v2 {
            content.minimumScaleFactor(0.9)
        } else {
            content
        }
    }
}

/// THROWAWAY: the German note in four isolated setups at exactly 326pt.
struct Fog5ControlPanel: View {
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            tag("A SwiftUI Text")
            Text(note).font(.caption).foregroundStyle(Color.white)
                .frame(width: 326, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .modifier(Fog5Probe(tag: "A", corner: .bottomTrailing))
            tag("B UILabel default")
            Fog5PlainLabel(text: note, strategy: .standard)
                .frame(width: 326, alignment: .leading)
                .modifier(Fog5Probe(tag: "B", corner: .bottomTrailing))
            tag("C UILabel strategy []")
            Fog5PlainLabel(text: note, strategy: [])
                .frame(width: 326, alignment: .leading)
                .modifier(Fog5Probe(tag: "C", corner: .bottomTrailing))
            tag("D SwiftUI Text, NBSP before last word")
            Text(nbspLast(note)).font(.caption).foregroundStyle(Color.white)
                .frame(width: 326, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .modifier(Fog5Probe(tag: "D", corner: .bottomTrailing))
        }
        .padding(8)
        .background(Color.black.opacity(0.75))
    }

    private func tag(_ s: String) -> some View {
        Text(s).font(.system(size: 9, weight: .bold)).foregroundStyle(Color.green)
    }

    private func nbspLast(_ s: String) -> String {
        guard let r = s.range(of: " ", options: .backwards) else { return s }
        return s.replacingCharacters(in: r, with: "\u{00A0}")
    }
}

/// THROWAWAY: plain UILabel with a given line-break strategy.
struct Fog5PlainLabel: UIViewRepresentable {
    let text: String
    let strategy: NSParagraphStyle.LineBreakStrategy

    func makeUIView(context: Context) -> UILabel {
        let l = UILabel()
        l.numberOfLines = 0
        l.lineBreakStrategy = strategy
        l.font = UIFont.preferredFont(forTextStyle: .caption1)
        l.textColor = .white
        l.text = text
        return l
    }

    func updateUIView(_ l: UILabel, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
        let w = min(proposal.width ?? .greatestFiniteMagnitude, .greatestFiniteMagnitude)
        let s = uiView.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude))
        return CGSize(width: min(ceil(s.width), w), height: ceil(s.height))
    }
}
