import SwiftUI

@main
struct CedarScanApp: App {
    @StateObject private var store = ScanStore()
    @StateObject private var account = AccountStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(account)
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label(L.t("Scans", "Bản quét"), systemImage: "viewfinder")
                }
            OrdersView()
                .tabItem {
                    Label(L.t("Orders", "Đơn hàng"), systemImage: "shippingbox")
                }
            AccountView()
                .tabItem {
                    Label(L.t("Account", "Tài khoản"), systemImage: "person.circle")
                }
        }
    }
}
