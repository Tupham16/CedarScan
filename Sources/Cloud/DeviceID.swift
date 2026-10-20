import Foundation
import UIKit

/// Mã định danh thiết bị — dùng để giới hạn khuyến mãi (suất miễn phí, Invite a friend) theo máy.
/// 2.79 (PLAN-MA-THIET-BI): a Keychain copy ("device-id") of identifierForVendor, made the first time
/// it is read. iOS gives a new vendor id once every Cedar247 app is deleted; the Keychain item outlives
/// the app, so a reinstall keeps counting on the same phone. Erasing the iPhone removes it.
/// 🔴 ✗ delete it on sign-out, account deletion or the N8 first-run wipe (those delete `app-token` only).
enum DeviceID {
    private static let key = "device-id"
    private static let lock = NSLock()
    private static var cached: String?

    static var current: String {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        if let saved = Keychain.read(key) {
            cached = saved
            return saved
        }
        guard let vendor = UIDevice.current.identifierForVendor?.uuidString else { return "unknown" }
        // Cached only once the Keychain holds it: before the first unlock after a reboot neither the
        // read above nor this add works (an existing copy is never replaced), and the next call tries again.
        if Keychain.add(vendor, for: key) { cached = vendor }
        return vendor
    }
}
