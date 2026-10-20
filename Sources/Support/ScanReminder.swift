import Foundation
import UserNotifications

/// F2 (2.79, owner yes 20/10) — the FIFTH notification type (the four pushes:
/// `PLAN-THONG-BAO-DAY.md`): ONE local reminder 24 h after a scan is saved, if it has not been
/// sent by then — "Your scan of <street> hasn't been sent yet." A tap opens that scan's page
/// (`AppDelegate` → `PushNotifications.tappedScan` → `RootView` → `HomeView.openScan`).
///
/// · Only scans saved by this build (`scanSaved`, called by the two save call sites) — ✗ any
///   scan saved before it, ✗ a backfill at launch.
/// · ONE request per property: a house scanned floor by floor (or with "Scan more") gets one
///   reminder, 24 h after its LAST save, naming its newest unsent scan. A scan outside any
///   property has its own.
/// · Derived state: `refresh` rebuilds a property's request from the store whenever one of its
///   scans is stamped (ordered, sent as an extra scan, adopted from a list), released (a cancelled
///   unpaid order), moved, renamed or deleted — `ScanStore` calls it. Sent / deleted ⇒ withdrawn
///   (also from Notification Center once nothing of the property is left unsent); released
///   within the 24 h ⇒ back.
/// · Local: made and shown on this iPhone — nothing goes to our server or through Apple's push
///   service (the Privacy Policy's "Notifications" paragraph is about pushes). Same permission as
///   the pushes, asked only after a first order (`PushNotifications.askIfUndetermined`); ✗ a new
///   prompt for this (owner's call). Not allowed ⇒ iOS keeps it silent; allowed within the
///   24 h ⇒ it shows.
@MainActor
enum ScanReminder {
    static let delay: TimeInterval = 24 * 3600
    /// `userInfo` key: the local id of the scan a tap opens. Read by `AppDelegate` (nonisolated).
    nonisolated static let recordIdKey = "scanRecordId"
    /// Request identifiers: this prefix + the property's id (or the scan's, outside a property).
    nonisolated private static let idPrefix = "scan-reminder."
    /// Ids of scans saved by this build that are still inside their 24 h (pruned on every
    /// `refresh`). UserDefaults: survives relaunches, small (a few ids).
    private static let pendingKey = "scanReminder.pending.v1"

    /// The two save call sites (HomeView, ProjectView), with the record `saveMeshScan` returned.
    static func scanSaved(_ record: ScanRecord, store: ScanStore) {
        var ids = pending
        ids.insert(record.id.uuidString)
        pending = ids
        refresh([key(record)], store: store, withdrawDelivered: false)
    }

    /// The request identifier a scan belongs to.
    nonisolated static func key(_ record: ScanRecord) -> String {
        idPrefix + (record.projectId ?? record.id).uuidString
    }

    nonisolated static func key(project id: UUID) -> String {
        idPrefix + id.uuidString
    }

    /// Rebuilds the requests `keys` from the store. `withdrawDelivered`: a scan of theirs was sent
    /// or deleted — a reminder already shown leaves Notification Center too once nothing of that
    /// property is left unsent on this device.
    static func refresh(_ keys: Set<String>, store: ScanStore, withdrawDelivered: Bool) {
        guard !keys.isEmpty else { return }
        let now = Date()
        var byId: [String: ScanRecord] = [:]
        for record in store.records { byId[record.id.uuidString] = record }
        // Gone from the device, or past its 24 h (its reminder came or will never come).
        let live = pending.filter { id in
            guard let record = byId[id] else { return false }
            return record.createdAt.addingTimeInterval(delay) > now
        }
        if live != pending { pending = live }
        let center = UNUserNotificationCenter.current()
        for k in keys {
            let unsent = live.compactMap { byId[$0] }
                .filter { key($0) == k && $0.cloudOrderNumber == nil }
            if let newest = unsent.max(by: { $0.createdAt < $1.createdAt }) {
                schedule(newest, key: k, store: store, now: now, center: center)
            } else {
                center.removePendingNotificationRequests(withIdentifiers: [k])
            }
            if withdrawDelivered,
               !store.records.contains(where: { key($0) == k && $0.cloudOrderNumber == nil }) {
                center.removeDeliveredNotifications(withIdentifiers: [k])
            }
        }
    }

    /// Same identifier = replaces the pending one (a new save moves the time, a rename the text).
    private static func schedule(
        _ record: ScanRecord, key: String, store: ScanStore, now: Date, center: UNUserNotificationCenter
    ) {
        let interval = record.createdAt.addingTimeInterval(delay).timeIntervalSince(now)
        // Inside the 24 h by construction (`live`); a clock set back must not fire it now.
        guard interval > 60 else { return }
        // The street, as the cards show it (`AddressLines`); a scan outside a property: its name.
        let place = store.project(with: record.projectId).map { AddressLines($0.name).street } ?? record.name
        let content = UNMutableNotificationContent()
        content.body = String(localized: "Your scan of \(place) hasn't been sent yet.")
        content.sound = .default
        content.userInfo = [recordIdKey: record.id.uuidString]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        center.add(
            UNNotificationRequest(identifier: key, content: content, trigger: trigger),
            withCompletionHandler: nil
        )
    }

    /// The scan a tapped notification opens; nil for any other notification (the pushes).
    nonisolated static func recordId(in userInfo: [AnyHashable: Any]) -> UUID? {
        (userInfo[recordIdKey] as? String).flatMap(UUID.init(uuidString:))
    }

    private static var pending: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: pendingKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: pendingKey) }
    }
}
