import SwiftUI

@main
struct CedarScanApp: App {
    @StateObject private var store = ScanStore()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
        }
    }
}
