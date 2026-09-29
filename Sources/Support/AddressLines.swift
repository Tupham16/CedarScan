import Foundation

/// A property name split for a card (2.52, owner 26/09): "63 Saint James Road, Cowbridge, CF71 7QW,
/// GB" → `street` "63 Saint James Road" (the bold line) + `rest` "Cowbridge, CF71 7QW, GB" (grey,
/// under it). Cut at the FIRST comma; no comma (a free name like "Mum's flat", a scan name, an
/// order number) or an empty side = the whole name, no second line. Display only: search, the
/// order form and the pushed title keep the full name.
struct AddressLines {
    let street: String
    let rest: String?

    init(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comma = trimmed.firstIndex(of: ",") {
            let head = trimmed[..<comma].trimmingCharacters(in: .whitespaces)
            let tail = trimmed[trimmed.index(after: comma)...].trimmingCharacters(in: .whitespaces)
            if !head.isEmpty && !tail.isEmpty {
                street = head
                rest = tail
                return
            }
        }
        street = trimmed
        rest = nil
    }
}
