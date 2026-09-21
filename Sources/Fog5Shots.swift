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
