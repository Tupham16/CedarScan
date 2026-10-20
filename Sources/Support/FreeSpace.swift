import SwiftUI

/// N5 (2.79, owner 20/10, mockup 74): free space before a scan opens. Saving needs about 1 GB of
/// scratch space and a 30-minute scan keeps about 300 MB, so below `minimum` the customer is told
/// before the camera opens and chooses (Scan anyway / Not now). The number stays on the phone:
/// privacy manifest, DiskSpace reason E174.1 — ✗ put it in scan-report.json or any request.
/// Checked at: the Scan tab (`HomeView.beginNewScan`), Scan more (`ProjectView.scanMoreTapped`,
/// also Orders' "Add a scan"), and "scan another area" after a save. ✗ the size-cap prompt's
/// "Scan the rest now": that is an alert's button, and a second alert from it is not shown
/// reliably; the next Scan checks again.
enum FreeSpace {
    /// 1.5 GB, decimal like iPhone Storage in Settings.
    static let minimum: Int64 = 1_500_000_000

    /// Free bytes when below `minimum`; nil when there is room, or when iOS does not say.
    /// "Important usage": what iOS can free for a task the customer started (it purges caches).
    static func low() -> Int64? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let free = values.volumeAvailableCapacityForImportantUsage,
              free < minimum else { return nil }
        return free
    }

    /// "1.2 GB" in the phone's language, decimal as in Settings. Always a number ("0 KB", ✗ the
    /// formatter's "Zero KB").
    static func text(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }
}

extension View {
    /// N5: "Your iPhone is almost full" while `free` holds a value; "Scan anyway" runs `scanAnyway`.
    /// `scanAnyway` may open a sheet (guide, address): an alert's button runs once the alert has
    /// gone (UIAlertController calls an action's handler after its dismissal), so that sheet is
    /// not presented over a closing alert. ⚠ Not yet seen on a device (needs < 1.5 GB free).
    func lowSpaceAlert(_ free: Binding<Int64?>, scanAnyway: @escaping () -> Void) -> some View {
        alert(
            String(localized: "Your iPhone is almost full"),
            isPresented: Binding(
                get: { free.wrappedValue != nil },
                set: { if !$0 { free.wrappedValue = nil } }
            ),
            presenting: free.wrappedValue
        ) { _ in
            Button(String(localized: "Not now"), role: .cancel) {}
            Button(String(localized: "Scan anyway"), action: scanAnyway)
        } message: { bytes in
            Text(String(localized: "Only \(FreeSpace.text(bytes)) free. Saving a scan needs about \(FreeSpace.text(FreeSpace.minimum)), so this scan may not save. Free up space in Settings › General › iPhone Storage."))
        }
    }
}
