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


/// THROWAWAY: the German note in isolated setups at exactly 326pt (green border = frame).
struct Fog5ControlPanel: View {
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            tag("A SwiftUI Text")
            box(Text(note).font(.caption).foregroundStyle(Color.white).fixedSize(horizontal: false, vertical: true))
            tag("B UILabel default")
            box(Fog5PlainLabel(text: note, strategy: .standard, plain: true, slack: 0))
            tag("C UILabel strategy [] + no hyphenation")
            box(Fog5PlainLabel(text: note, strategy: [], plain: false, slack: 0))
            tag("D SwiftUI Text, NBSP before last word")
            box(Text(nbspLast(note)).font(.caption).foregroundStyle(Color.white).fixedSize(horizontal: false, vertical: true))
            tag("E = C measured 12pt narrower than drawn")
            box(Fog5PlainLabel(text: note, strategy: [], plain: false, slack: 12))
            tag("F SwiftUI Text, dash -> comma")
            box(Text(note.replacingOccurrences(of: " \u{2014}", with: ",")).font(.caption).foregroundStyle(Color.white).fixedSize(horizontal: false, vertical: true))
        }
        .padding(8)
        .background(Color.black.opacity(0.8))
    }

    private func box<V: View>(_ v: V) -> some View {
        v.frame(width: 326, alignment: .leading).border(Color.green, width: 0.5)
    }

    private func tag(_ s: String) -> some View {
        Text(s).font(.system(size: 9, weight: .bold)).foregroundStyle(Color.green)
    }

    private func nbspLast(_ s: String) -> String {
        guard let r = s.range(of: " ", options: .backwards) else { return s }
        return s.replacingCharacters(in: r, with: "\u{00A0}")
    }
}

/// THROWAWAY: UILabel variants.
struct Fog5PlainLabel: UIViewRepresentable {
    let text: String
    let strategy: NSParagraphStyle.LineBreakStrategy
    let plain: Bool
    let slack: CGFloat

    func makeUIView(context: Context) -> UILabel {
        let l = UILabel()
        l.numberOfLines = 0
        l.lineBreakStrategy = strategy
        if plain {
            l.font = UIFont.preferredFont(forTextStyle: .caption1)
            l.textColor = .white
            l.text = text
        } else {
            let p = NSMutableParagraphStyle()
            p.lineBreakStrategy = strategy
            p.usesDefaultHyphenation = false
            p.hyphenationFactor = 0
            l.attributedText = NSAttributedString(string: text, attributes: [
                .font: UIFont.preferredFont(forTextStyle: .caption1),
                .foregroundColor: UIColor.white,
                .paragraphStyle: p,
            ])
        }
        return l
    }

    func updateUIView(_ l: UILabel, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
        let w = min(proposal.width ?? .greatestFiniteMagnitude, .greatestFiniteMagnitude)
        let s = uiView.sizeThatFits(CGSize(width: max(w - slack, 1), height: .greatestFiniteMagnitude))
        return CGSize(width: min(ceil(s.width) + slack, w), height: ceil(s.height))
    }
}
