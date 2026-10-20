import Foundation
import UserNotifications

/// F2 (2.79, owner yes 20/10) — the FIFTH notification type (the four pushes:
/// `PLAN-THONG-BAO-DAY.md`): ONE local reminder 24 h after a scan is saved, if it has not been
/// sent by then — "Your scan of <street> hasn't been sent yet." A tap opens that scan's page, or
/// its property when the scan is gone (`AppDelegate` → `PushNotifications.tappedScan` →
/// `RootView` → `HomeView.openScan`).
///
/// · Only scans saved by this build (`scanSaved`, called by the two save call sites) — ✗ any
///   scan saved before it, ✗ a backfill at launch.
/// · ONE request per property: a house scanned floor by floor (or with "Scan more") gets one
///   reminder, 24 h after its LAST save, naming that newest scan — and none once that newest scan
///   is sent (the customer has dealt with the house; ✗ nag about an older take left out). A scan
///   outside any property has its own.
/// · Derived state: `refresh` rebuilds a property's request from the store whenever one of its
///   scans is stamped (ordered, sent as an extra scan, adopted from a list), released (a cancelled
///   unpaid order), moved, renamed or deleted — `ScanStore` calls it. A reminder already shown
///   leaves Notification Center once the scan it names is sent or gone.
/// · Permission: the same as the pushes, asked only after a first order
///   (`PushNotifications.askIfUndetermined`); ✗ a new prompt for this (owner's call). iOS DROPS a
///   request added while notifications are not allowed, so `refreshAll` (launch, every return to
///   the foreground) adds the pending ones again — allowed within the 24 h ⇒ it still comes.
/// · Local: made and shown on this iPhone — nothing goes to our server or through Apple's push
///   service.
@MainActor
enum ScanReminder {
    static let delay: TimeInterval = 24 * 3600
    /// `userInfo` keys: the scan a tap opens, and its property (the fallback). Read by
    /// `AppDelegate` (nonisolated).
    nonisolated static let recordIdKey = "scanRecordId"
    nonisolated static let projectIdKey = "scanProjectId"
    /// Request identifiers: this prefix + the property's id (or the scan's, outside a property).
    nonisolated static let idPrefix = "scan-reminder."
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

    /// `RootView`: launch, sign-in / out and every return to the foreground. Adds the pending
    /// reminders again (a request added while notifications were not allowed was dropped; the
    /// same identifier and the same fire time — from the save — make a repeat harmless), and
    /// withdraws shown ones whose scan was sent or deleted meanwhile.
    static func refreshAll(store: ScanStore) {
        var byId: [String: ScanRecord] = [:]
        for record in store.records { byId[record.id.uuidString] = record }
        let keys = Set(pending.compactMap { byId[$0] }.map { key($0) })
        refresh(keys, store: store, withdrawDelivered: false)
        withdrawShown(nil, store: store)
    }

    /// Rebuilds the requests `keys` from the store. `withdrawDelivered`: a scan of theirs was sent
    /// or deleted — shown reminders naming a scan that is now sent or gone leave Notification
    /// Center too.
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
            let newest = live.compactMap { byId[$0] }
                .filter { key($0) == k }
                .max { $0.createdAt < $1.createdAt }
            if let newest, newest.cloudOrderNumber == nil {
                schedule(newest, key: k, store: store, now: now, center: center)
            } else {
                center.removePendingNotificationRequests(withIdentifiers: [k])
            }
        }
        if withdrawDelivered { withdrawShown(keys, store: store) }
    }

    /// Shown reminders (`keys`; nil = all of them) whose scan is sent or no longer on this device.
    /// Matched on the scan each one names, ✗ its property: another unsent scan there keeps
    /// nothing alive that is no longer true.
    private static func withdrawShown(_ keys: Set<String>?, store: ScanStore) {
        let unsent = Set(store.records.filter { $0.cloudOrderNumber == nil }.map { $0.id })
        // `@Sendable`: called on a background queue — ✗ inferred main-actor isolation.
        UNUserNotificationCenter.current().getDeliveredNotifications { @Sendable shown in
            let stale = shown.compactMap { note -> String? in
                let id = note.request.identifier
                guard id.hasPrefix(idPrefix), keys?.contains(id) ?? true else { return nil }
                guard let scan = recordId(in: note.request.content.userInfo) else { return id }
                return unsent.contains(scan) ? nil : id
            }
            if !stale.isEmpty {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: stale)
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
        var info: [String: String] = [recordIdKey: record.id.uuidString]
        if let projectId = record.projectId { info[projectIdKey] = projectId.uuidString }
        content.userInfo = info
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: key, content: content, trigger: trigger)
        center.add(request) { @Sendable error in
            // Not allowed (yet) is the usual one: `refreshAll` adds it again later.
            if let error { print("[reminder] not scheduled:", error.localizedDescription) }
        }
    }

    /// The scan a tapped notification opens; nil for any other notification (the pushes).
    nonisolated static func recordId(in userInfo: [AnyHashable: Any]) -> UUID? {
        (userInfo[recordIdKey] as? String).flatMap(UUID.init(uuidString:))
    }

    /// Its property (the tap's fallback when the scan is gone).
    nonisolated static func projectId(in userInfo: [AnyHashable: Any]) -> UUID? {
        (userInfo[projectIdKey] as? String).flatMap(UUID.init(uuidString:))
    }

    private static var pending: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: pendingKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: pendingKey) }
    }
}
