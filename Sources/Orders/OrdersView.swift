import SwiftUI
import UniformTypeIdentifiers // UTType — suy ra MIME cho file đính kèm của "Yêu cầu sửa"

/// Danh sách đơn đã đặt xử lý: trạng thái + file thành phẩm khi đã giao.
/// Orders v2: compact rows (title · date · status); tap = `OrderDetailView`, pushed.
struct OrdersView: View {
    /// 🔴 TRUYỀN TAY từ `RootView`, cùng khuôn `HomeView`: since Orders v2 this tab PUSHES
    /// (`OrderDetailView`), and a pushed screen must not read `@EnvironmentObject` (SIGTRAP,
    /// `ProjectView.store`). Looks up order → project on this device: the row title / search
    /// fallback (display only), and "Add a scan" in the detail.
    @ObservedObject var store: ScanStore
    /// Passed by hand for the same reason (it was `@EnvironmentObject` while the tab pushed nothing).
    @ObservedObject var account: AccountStore
    /// Nhảy sang tab Home và mở dự án — `RootView.requestOpenProject`. Tab này ✗ tự đổi tab.
    let onOpenProject: (_ project: ScanProject, _ startScan: Bool) -> Void
    /// Pushed orders: 0 or 1 entry, IDs only (`OrderRoute`).
    @State private var path: [OrderRoute] = []
    @State private var orders: [OrderDTO] = []
    /// Search text, matched against `searchKeys(of:)`: order #, house name, scan names.
    @State private var searchText = ""
    /// Danh tính khách mà `orders` hiện thuộc về — để chỉ XOÁ cache khi tài khoản đổi THẬT, không
    /// xoá trên mỗi lần `.task` chạy lại (tránh chớp trắng + giữ được banner "dữ liệu cũ" của [17]).
    @State private var loadedCustomerId: String?
    @State private var isLoading = false
    /// The last load started, the last one whose answer is on screen, and the last failure shown
    /// (see `load()`).
    @State private var loadSeq = 0
    @State private var appliedSeq = 0
    @State private var failedSeq = 0
    /// When this account's list last came back (`load()`): the return-to-app refresh reads it.
    /// nil = not yet for this account.
    @State private var loadedAt: Date?
    @State private var errorMessage: String?
    @State private var filter: OrderFilter = .all
    /// N15: the sign-in sheet of the order flow, opened from the signed-out screen.
    @State private var showAccountGate = false
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Orders v2 B: back from the browser pay page (see `refreshUnpaid`).
    @Environment(\.scenePhase) private var scenePhase
    /// Push notifications: a tapped one's order (`openPushedOrder`), arrivals on screen (reload).
    @ObservedObject private var push = PushNotifications.shared

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !account.isSignedIn {
                    signedOutState
                } else if ownOrders.isEmpty && (!isLoading || loadedAt != nil || errorMessage != nil) {
                    // Once loaded, a reload keeps this screen (a pull here, the return-to-app
                    // refresh): ✗ swap to the list's "Loading…" row under the customer's finger.
                    // Same after a failed first load: its error screen stays while Retry or a pull
                    // reloads (Retry greys out meanwhile).
                    emptyState
                } else {
                    ordersList
                }
            }
            .navigationTitle(String(localized: "Orders"))
            // 🔴 Search goes HERE, level with `.navigationTitle` — ✗ back inside `ordersList`
            // (trap #10). It sat in that branch while this tab pushed nothing; since Orders v2 it
            // pushes `OrderDetailView`, so the reason in the 🔴 block of `HomeView.body` applies:
            // `.searchable` is a UISearchController on the ROOT navigationItem, and a branch that
            // SwiftUI rebuilds can tear it down in the middle of a push.
            // Price, accepted as on Home: the signed-out and empty screens show the field too.
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: String(localized: "Search property or order #")
            )
            // Its own task, as in `OrderDetailView`: tapping a row during a refresh must not cancel
            // it into a false "Couldn't refresh".
            .refreshable {
                await Task { await load() }.value
            }
            .navigationDestination(for: OrderRoute.self, destination: orderDetail)
        }
        // N15: on the stack, ✗ on `signedOutState`: that branch is gone the moment the sign-in
        // lands, and a sheet hung on it would be torn down mid-flow (the email-code step of a
        // new account). The sheet closes itself once the account can order.
        .sheet(isPresented: $showAccountGate) {
            AccountGateSheet()
                .environmentObject(account)
        }
        // Khoá theo DANH TÍNH khách chứ không chỉ theo cờ `isSignedIn`: một máy có thể dùng
        // >1 tài khoản (A đăng xuất → B đăng nhập). Với `id: isSignedIn` thì cache `orders`
        // của A đứng nguyên suốt lúc B chờ mạng — B thấy đơn, tên bản quét, và bấm được
        // "Thanh toán ngay" trỏ vào link chưa-trả của A.
        //
        // XOÁ cache CHỈ khi danh tính đổi thật (so `loadedCustomerId`), KHÔNG xoá vô điều kiện
        // mỗi lần task chạy: nếu TabView cho `.task` chạy lại lúc quay về tab (hành vi tuỳ phiên
        // bản SwiftUI), `orders = []` vô điều kiện sẽ chớp trắng danh sách VÀ phá luôn banner
        // "đang xem dữ liệu cũ" của [17] khi refresh lỗi. `.task(id:)` luôn chạy lại khi id đổi
        // (A→B, đăng xuất→nil) nên nhánh này vẫn bắt được đổi tài khoản.
        //
        // 🔴 On the STACK, ✗ on its root view: the root disappears while an order is pushed, which
        // would cancel a load in flight (a false "Couldn't refresh") and hold this wipe back until
        // Back is tapped — account B shown A's order, with A's Pay Now.
        .task(id: account.customer?.id) {
            let currentId = account.customer?.id
            if loadedCustomerId != currentId {
                orders = []
                errorMessage = nil
                // Dọn CẢ ô tìm kiếm và bộ lọc, không chỉ `orders`: cả hai là `@State` của
                // OrdersView nên chúng sống suốt vòng đời app, không chết theo tài khoản.
                // A đăng xuất → B đăng nhập, B thấy ô tìm kiếm ĐÃ ĐIỀN SẴN số đơn của A (một
                // mẩu dữ liệu của người khác) và danh sách rỗng kèm câu "không có đơn nào
                // khớp" — B kết luận mình không có đơn nào.
                searchText = ""
                filter = .all
                // And the open order: it belongs to the previous account.
                path = []
                // A load still out answers for the previous account: its answer is dropped.
                loadSeq += 1
                appliedSeq = loadSeq
                isLoading = false
                loadedAt = nil
                loadedCustomerId = currentId
            }
            if account.isSignedIn { await load() }
            // A notification tapped before this account's first load (cold start): its turn now.
            await openPushedOrder(reload: false)
        }
        .onChange(of: orders.map(\.orderId)) { _, ids in
            leaveGoneOrder(ids)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshOnActive() }
        }
        .onChange(of: push.openOrder) { _, request in
            if request != nil { Task { await openPushedOrder(reload: true) } }
        }
        // A push while the app is on screen = news about an order (delivered, cancelled…).
        .onChange(of: push.arrivals) { _, _ in
            if account.isSignedIn { Task { await load() } }
        }
    }

    /// A tapped notification's order (`RootView` switched to this tab): reload (the push is news),
    /// then push it — the only screen on the stack. Not in the list (another account's, gone) = the
    /// list alone. Waits for this account's first load: before it `orders` may be empty or the
    /// previous account's (`.task(id:)` calls back after that load).
    private func openPushedOrder(reload: Bool) async {
        guard let request = push.openOrder else { return }
        guard account.isSignedIn else {
            push.openOrder = nil
            return
        }
        guard loadedCustomerId == account.customer?.id else { return }
        if reload { await load() }
        // A newer tap took over, or another call already handled this one.
        guard push.openOrder == request, loadedCustomerId == account.customer?.id else { return }
        push.openOrder = nil
        guard let order = ownOrders.first(where: { $0.orderId == request.orderId }),
              !PushNotifications.somethingOnTop else { return }
        // Already open (by id: a reloaded house name must not pop and re-push it, cancelling a Pay Now).
        guard path.first?.orderId != order.orderId else { return }
        path = [OrderRoute(orderId: order.orderId, title: title(of: order), customerId: account.customer?.id)]
    }

    /// Back in the app (2.78): an unpaid order listed → `refreshUnpaid` as before; otherwise the list
    /// is read again once older than `staleAfter`. A customer who opens the app from its icon after
    /// the "plan ready" email saw "Processing" and no files until a pull.
    private func refreshOnActive() {
        guard account.isSignedIn else { return }
        if hasUnpaid {
            refreshUnpaid()
        } else if isStale {
            Task { await load() }
        }
    }

    /// Wall clock; `abs` so a clock set back cannot stop the refresh (as `RootView`'s config fetch).
    private static let staleAfter: TimeInterval = 60

    private var isStale: Bool {
        guard let loadedAt else { return true }
        return abs(Date().timeIntervalSince(loadedAt)) > Self.staleAfter
    }

    /// Orders v2 B: a customer who paid on the browser pay page comes back to a list (or an open
    /// order) that still says "Awaiting payment · not placed · cancelled after 7 days" — nothing
    /// else reloads it (`PaymentFlow` never hears of a browser payment). Only while an unpaid order
    /// (or an unpaid purchase added to one, Orders v2 C) is listed. WordPress reports the payment a
    /// moment later (fire-and-forget callback), so once more after a few seconds if it still reads
    /// unpaid. Through `load()`: its guards apply.
    private func refreshUnpaid() {
        guard account.isSignedIn, hasUnpaid else { return }
        Task {
            await load()
            guard hasUnpaid else { return }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await load()
        }
    }

    /// An order awaiting payment is listed, or items added to one (Orders v2 C) that are.
    private var hasUnpaid: Bool {
        ownOrders.contains { order in
            order.isAwaitingPayment || (order.extras ?? []).contains { $0.isAwaitingPayment }
        }
    }

    /// The pushed screen. The ID only (`OrderDTO` is not Hashable): the detail reads the LIVE
    /// order through the binding. `store` passed by hand, ✗ `@EnvironmentObject`.
    private func orderDetail(_ route: OrderRoute) -> some View {
        OrderDetailView(
            route: route,
            orders: $orders,
            errorMessage: $errorMessage,
            store: store,
            account: account,
            reload: { await load() },
            onOpenProject: onOpenProject
        )
    }

    /// An open order the list no longer has (a refresh dropped it): back to the list. One tick
    /// later and checked again — a pop in the middle of a push is trap #9.
    private func leaveGoneOrder(_ ids: [String]) {
        guard path.contains(where: { !ids.contains($0.orderId) }) else { return }
        Task { @MainActor in
            let live = Set(orders.map(\.orderId))
            path.removeAll { !live.contains($0.orderId) }
        }
    }

    private func load() async {
        // Only for the account the cached list belongs to: a reload fired after a sign-out or an
        // account switch (Pay Now's `onPaid`, a revision sent) waits for the wipe's own load.
        guard account.isSignedIn, account.customer?.id == loadedCustomerId else { return }
        // Refreshes run in their own task (`.refreshable`) and Retry / reloads never were tied to a
        // view, so answers can land late and out of order. An answer is dropped when the account
        // changed meanwhile or a newer answer is already on screen — ✗ account A's orders shown
        // to B, ✗ an older list over a newer one.
        let owner = account.customer?.id
        loadSeq += 1
        let seq = loadSeq
        isLoading = true
        // Card payments the server has not confirmed yet. Not awaited: the list must never wait on
        // it, and the order detail shows "Paid" from `PaymentFlow` either way.
        Task { await PaymentFlow.shared.confirmPending() }
        let answer: Result<[OrderDTO], Error>
        do {
            answer = .success(try await APIClient.shared.listOrders().orders)
        } catch {
            answer = .failure(error)
        }
        guard owner == account.customer?.id, seq > appliedSeq else { return }
        let newest = seq == loadSeq
        switch answer {
        case .success(let fresh):
            orders = fresh
            loadedAt = Date()
            // Push notifications: an account that has orders is asked once, on this tab only.
            if !fresh.isEmpty, PaymentFlow.visibleTab == .orders {
                PushNotifications.shared.askIfUndetermined()
            }
            // Orders v2 B: awaiting / cancelled states onto this device's scans (positive signals
            // only — see `ScanStore.syncOrders`).
            store.syncOrders(fresh)
            // An answer older than the failure shown is not the refresh that failed.
            if seq > failedSeq { errorMessage = nil }
            appliedSeq = seq
        case .failure(let error):
            // Only the newest load may say "Couldn't refresh": an older one is still followed by
            // an answer. A cancelled load (tab switched away) brought no answer at all.
            if newest, !Self.isCancellation(error) {
                errorMessage = error.localizedDescription
                failedSeq = seq
            }
        }
        if newest { isLoading = false }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// N15 (owner 20/10, mockup 75): a Sign in button instead of "Go to the Account tab…". It opens
    /// the order flow's sheet (sign in, create an account, verify the email) right here.
    private var signedOutState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(String(localized: "Sign in to see your orders"))
                .font(.headline)
                .multilineTextAlignment(.center)
            Button {
                showAccountGate = true
            } label: {
                Text(String(localized: "Sign in"))
                    .font(.headline)
                    .padding(.horizontal, 34)
                    .padding(.vertical, 14)
            }
            .buttonStyle(FogPrimary())
            .padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.ignoresSafeArea())
    }

    /// In a ScrollView so it can be pulled to refresh: `.refreshable` in `body` only reaches scroll
    /// views, and a plain VStack left this screen with no reload but Retry. Centred as before
    /// (`minHeight` = the visible height); bounces even when it fits — the pull is the gesture.
    private var emptyState: some View {
        GeometryReader { proxy in
            ScrollView {
                emptyContent
                    .padding(32)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.always)
        }
        .background(Theme.bg.ignoresSafeArea())
    }

    private var emptyContent: some View {
        VStack(spacing: 12) {
            if let errorMessage {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    Task { await load() }
                } label: {
                    Text(String(localized: "Retry"))
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                }
                .buttonStyle(FogTint(radius: 12))
                // This screen now stays during the reload: grey = it is trying.
                .disabled(isLoading)
            } else {
                Image(systemName: "shippingbox")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text(String(localized: "No orders yet"))
                    .font(.headline)
                Text(String(localized: "Open a scan and tap \"Order Floor Plan\" to have our team create professional drawings."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
        }
    }

    /// Đơn khớp ô TÌM KIẾM (chưa áp bộ lọc trạng thái).
    ///
    /// Số đếm trên các nút lọc tính TRÊN TẬP NÀY, không phải trên toàn bộ `orders`: nút ghi "(3)"
    /// mà bấm vào chỉ ra 1 đơn — vì 2 đơn kia bị ô tìm kiếm loại — là con số nói dối.
    private var searchedOrders: [OrderDTO] {
        let key = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return ownOrders }
        return ownOrders.filter { order in
            searchKeys(of: order).contains { TextMatch.contains($0, key) }
        }
    }

    /// `orders` as the signed-in account may see them. They belong to `loadedCustomerId`, and after
    /// a sign-out or an account switch the wipe in `.task(id:)` can run a frame late (it waits for
    /// the tab to show): until then nothing, ✗ the previous account's list. Same gate as the one
    /// in `OrderDetailView.order`.
    private var ownOrders: [OrderDTO] {
        loadedCustomerId == account.customer?.id ? orders : []
    }

    /// House name of an order: the server's, else the project on this device that holds its
    /// scans. `nil` = neither has one (older order, other device). Display and search only.
    private func projectName(of order: OrderDTO) -> String? {
        if let sent = Self.nonBlank(order.projectName) { return sent }
        return Self.nonBlank(store.project(withOrderNumber: order.orderNumber)?.name)
    }

    /// Row title. Scan names alone ("Main floor") cannot tell two houses apart.
    private func title(of order: OrderDTO) -> String {
        projectName(of: order) ?? Self.nonBlank(order.scanName) ?? order.orderNumber
    }

    /// Everything a customer may type to find an order. The local name is listed even when the
    /// server sent one: the project may have been renamed since.
    private func searchKeys(of order: OrderDTO) -> [String] {
        let local = store.project(withOrderNumber: order.orderNumber)?.name
        let keys: [String?] = [order.orderNumber, order.projectName, local, order.scanName]
        return keys.compactMap { $0 }
    }

    /// Also `OrderDetailView.recreatedName(of:)` (same title chain for a recreated property).
    static func nonBlank(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Đơn đang hiển thị: khớp cả ô tìm kiếm lẫn bộ lọc trạng thái đang chọn.
    /// (`supplementProject(for:)`, which sat here, moved to `OrderDetailView` with Orders v2.)
    private var filteredOrders: [OrderDTO] {
        searchedOrders.filter { filter.matches($0.status) }
    }

    /// Câu giải thích khi danh sách rỗng — phải nói đúng NGUYÊN NHÂN.
    ///
    /// Có đơn khớp từ khoá nhưng bị chip trạng thái chặn mà lại báo "không khớp từ khoá" thì khách
    /// đi sửa từ khoá, trong khi việc phải làm là bấm sang chip khác. (Con số trên chip vốn đã
    /// đúng — nó đếm trên `searchedOrders` — chỉ mỗi câu này từng chỉ sai hướng.)
    private var emptyListNote: String {
        // Đang tải LẦN ĐẦU (chưa có đơn nào trong tay) cũng rơi vào đây — `ordersList` được chọn
        // khi `ownOrders.isEmpty && isLoading`. Không có nhánh này thì màn hình khẳng định "Không có
        // đơn nào" đúng lúc dữ liệu còn đang trên đường về.
        if isLoading && ownOrders.isEmpty {
            return String(localized: "Loading your orders…")
        }
        let hasQuery = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasQuery && searchedOrders.isEmpty {
            return String(localized: "No orders match your search.")
        }
        if filter != .all {
            return String(localized: "No orders in this category — try another filter above.")
        }
        return String(localized: "No orders in this category.")
    }

    /// Các nút lọc thật sự hiện ra.
    ///
    /// "Tất cả" LUÔN hiện; trạng thái khác chỉ hiện khi có đơn — bày 5 nút mà 4 nút ghi (0) là màn
    /// hình bẩn với khách chỉ có một đơn. NHƯNG nút ĐANG CHỌN luôn được giữ lại kể cả khi về 0:
    /// nút biến mất ngay dưới ngón tay là danh sách rỗng mà không còn gì nói cho khách biết vì sao.
    private var visibleFilters: [OrderFilter] {
        OrderFilter.allCases.filter { f in
            f == .all || f == filter || searchedOrders.contains { f.matches($0.status) }
        }
    }

    /// Hàng nút lọc theo trạng thái + số đếm. Cuộn ngang để không tràn trên máy nhỏ.
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(visibleFilters) { f in
                    filterChip(f)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    /// Tách thành hàm riêng — CI của repo này từng chết vì "Swift type-check timeout" với biểu
    /// thức SwiftUI lớn, mà đây là chỗ có `let` cục bộ + nhiều modifier điều kiện.
    private func filterChip(_ f: OrderFilter) -> some View {
        let count = searchedOrders.filter { f.matches($0.status) }.count
        let isOn = filter == f
        // Fog chip: selected = soft badge colours; others = card + hairline.
        let chip = Capsule()
        return Button {
            filter = f
        } label: {
            Text("\(f.title) (\(count))")
                .font(.subheadline.weight(isOn ? .semibold : .medium))
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(chip.fill(isOn ? Theme.Badge.soft.bg : Theme.card))
                .overlay(chip.strokeBorder(isOn ? Color.clear : Theme.hairline, lineWidth: 1))
                .foregroundStyle(isOn ? Theme.Badge.soft.fg : Color.primary)
        }
        .buttonStyle(.plain)
        // N17: the chosen filter was shown by colour only. Both branches typed (see
        // `CedarTabBar.tabItem`).
        .accessibilityAddTraits(isOn ? AccessibilityTraits.isSelected : AccessibilityTraits())
    }

    private var ordersList: some View {
        VStack(spacing: 0) {
            filterBar
            List {
            // Đã có đơn rồi thì `emptyState` (nơi DUY NHẤT render `errorMessage` trước đây) không
            // bao giờ hiện nữa, nên mọi lần refresh lỗi (mất sóng, pull-to-refresh ở công trường)
            // đều im lặng: danh sách CŨ đứng như dữ liệu mới. Banner này báo "đang xem dữ liệu cũ"
            // + cho đường Thử lại chủ động, thay vì để khách tin trạng thái/link thanh toán lỗi thời.
            if let errorMessage {
                Section {
                    RefreshFailedNote { Task { await load() } }
                        .fogCardRow(trailing: 32)
                }
                .listSectionSeparator(.hidden)
            }
            if filteredOrders.isEmpty {
                Text(emptyListNote)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(filteredOrders) { order in
                orderRow(order)
                    .fogCardRow(trailing: 28, edge: StatusBadge.kind(order.status).edge)
            }
            }
            .listStyle(.plain)
            .tabRootBarRoom()
        }
        .fogScreen()
        // `.searchable` is NOT here any more: it moved up to `body`, level with `.navigationTitle`
        // (Orders v2 pushes). Read the 🔴 note there before moving it back.
    }

    /// One order card (2.52, mockup 48; 2.53 no min height, mockup 49 A; before: the compact row of mockup 30/31). Top: the street
    /// in bold + the rest of the address in grey (`AddressLines`), status badge beside the street.
    /// Bottom: date + chevron. Left edge in the badge's colour. Tap = the order detail.
    /// A `Button` + `path.append`, ✗ `NavigationLink`: same reason as `HomeView.projectRow` — a List
    /// draws its own chevron and a full-width grey highlight across the Fog card.
    /// Everything the 2.45 card showed (Pay Now, files, tour, revision, add a scan) is in
    /// `OrderDetailView`, with the same conditions.
    private func orderRow(_ order: OrderDTO) -> some View {
        let name = title(of: order)
        let lines = AddressLines(name)
        // Accessibility sizes: the badge under the date — beside the street the title breaks at
        // every syllable (simulator renders, AX3).
        let badgeBelow = typeSize.isAccessibilitySize
        return Button {
            // One order at a time: a quick double tap must not stack the same screen twice.
            guard path.isEmpty else { return }
            path.append(OrderRoute(orderId: order.orderId, title: name, customerId: account.customer?.id))
        } label: {
            // Card height = its content (owner 26/09, mockup 49 A): ✗ a min height, it left a gap
            // between the address and the date.
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    CardAddress(lines: lines)
                    Spacer(minLength: 8)
                    if !badgeBelow {
                        StatusBadge(status: order.status)
                    }
                }
                HStack(alignment: .bottom, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        dateLine(order)
                        if badgeBelow {
                            StatusBadge(status: order.status)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        // `.plain`: no accent tint over the row's own colours (see `HomeView.projectRow`).
        .buttonStyle(.plain)
    }

    /// The row's date, or while the team works on the order the time it should be ready (F1,
    /// owner 20/10, mockup 77: in place of the date, so the card does not grow).
    @ViewBuilder
    private func dateLine(_ order: OrderDTO) -> some View {
        if let due = order.readyBy {
            HStack(spacing: 5) {
                Image(systemName: "clock")
                    .foregroundStyle(Theme.Badge.soft.fg)
                    .accessibilityHidden(true)
                Text(Self.readyByText(due))
                    .foregroundStyle(Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.footnote.weight(.medium))
        } else {
            Text(Self.formatDate(order.placedAt))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    static func formatDate(_ iso: String) -> String {
        // Server timestamps carry milliseconds, which a default ISO8601DateFormatter rejects.
        guard let date = OrderDTO.isoDate(iso) else { return "" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// F1: "Ready by tomorrow at 3:40 PM" in the phone's language and time zone. Today and
    /// tomorrow by name (the system's own words), a later day as weekday + date.
    static func readyByText(_ due: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = appLanguageLocale()
        let calendar = Calendar.current
        if calendar.isDateInToday(due) || calendar.isDateInTomorrow(due) {
            formatter.doesRelativeDateFormatting = true
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            formatter.formattingContext = .middleOfSentence
        } else {
            formatter.setLocalizedDateFormatFromTemplate("EEEMMMdjmm")
        }
        let when = formatter.string(from: due)
        return String(localized: "Ready by \(when)")
    }

    /// The phone's locale in the app's language: on a phone set to a language the app lacks the
    /// sentence is English, and "Ready by domani alle 15:40" mixed the two. Region formats stay.
    private static func appLanguageLocale() -> Locale {
        let current = Locale.current
        guard current.language.languageCode?.identifier != AppLanguage.code else { return current }
        // Only the language: the region sits in `languageComponents` too ("it_IT" → "en_IT").
        var parts = Locale.Components(locale: current)
        parts.languageComponents.languageCode = Locale.LanguageCode(AppLanguage.code)
        parts.languageComponents.script = nil
        return Locale(components: parts)
    }
}

/// The last refresh failed: the screen still shows the orders from before (list and order detail).
/// ✗ drop it from either: a failed refresh must never pass for fresh data — status, Pay Now link.
struct RefreshFailedNote: View {
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(Theme.Badge.warn.fg)
            Text(String(localized: "Couldn't refresh — showing saved data."))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button(String(localized: "Retry"), action: onRetry)
                .font(.footnote.weight(.semibold))
        }
    }
}

/// Form yêu cầu sửa: khách mô tả chỗ cần chỉnh → đơn quay lại hàng xử lý.
struct RevisionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let order: OrderDTO
    let onSent: () -> Void

    @State private var message = ""
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var sent = false
    /// File khách gửi kèm yêu cầu sửa (ảnh chụp chỗ sai, PDF đánh dấu…). Đã upload xong lên R2,
    /// chờ gửi metadata {name,url} kèm lời nhắn. Cùng endpoint `/order-files` với form đặt hàng.
    @State private var files: [OrderFileItem] = []
    @State private var showFileImporter = false
    @State private var uploadingFile = false
    @State private var fileUploadError: String?

    var body: some View {
        NavigationStack {
            Form {
                if sent {
                    Section {
                        VStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 44))
                                .foregroundStyle(Theme.Badge.ok.fg)
                            Text(String(localized: "Revision requested!"))
                                .font(.headline)
                            Text(String(localized: "Our team will update your floor plan and deliver a revised version."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .listRowBackground(Theme.card)
                    }
                } else {
                    Section {
                        TextField(
                            String(localized: "What should we change? (e.g. missing door on Floor 2, wrong room label…)"),
                            text: $message,
                            axis: .vertical
                        )
                        .lineLimit(4...8)
                        // N10 (2.79): the server keeps 2,000 UTF-16 units of it (`revision/route.ts`)
                        // and cuts the rest silently: stops there, as the order note.
                        .onChange(of: message) { _, text in
                            let cut = TextLimit.cut(text, 2000)
                            if cut != text { message = cut }
                        }
                        .listRowBackground(Theme.card)
                    } header: {
                        Text(order.orderNumber)
                    } footer: {
                        Text(String(localized: "Revisions for mistakes on our side are free."))
                    }
                    attachmentsSection
                    if let errorMessage {
                        Section {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .listRowBackground(Theme.card)
                        }
                    }
                }
            }
            .fogScreen()
            .navigationTitle(String(localized: "Request a revision"))
            .navigationBarTitleDisplayMode(.inline)
            // Vuốt xuống lúc ĐANG GỬI thì sheet đóng mà request vẫn bay tiếp: khách tin là đã
            // hủy, thực tế đội vẽ vẫn nhận yêu cầu (và `onSent` không chạy nên danh sách đơn không
            // được làm tươi). Cùng bài học với [3] ở `OrderSheet`: cửa "đang gửi" KHÔNG hủy an
            // toàn được, nên khoá đường đóng thay vì giả vờ hủy.
            // 2.78 review: ✗ also locked during an attachment upload (up to an hour on a slow
            // line): the file reaches the team only with Send, so leaving then changes nothing on
            // the server. The upload's task just ends writing this closed sheet's own state.
            .interactiveDismissDisabled(isBusy)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // Locked like the swipe above (and the other sheets' Cancel): a tap here while
                    // sending closed the sheet with the request still in flight.
                    Button(sent ? String(localized: "Close") : String(localized: "Cancel")) { dismiss() }
                        .disabled(isBusy)
                }
                if !sent {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            submit()
                        } label: {
                            if isBusy {
                                ProgressView()
                            } else {
                                Text(String(localized: "Send")).bold()
                            }
                        }
                        // Khoá luôn khi ĐANG TẢI FILE: gửi lúc đó là lời nhắn tới nơi mà file
                        // thì chưa, và sheet đóng mất — khách không còn đường gửi lại file đó
                        // vào đúng yêu cầu này.
                        .disabled(isBusy || uploadingFile || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    /// Mục đính kèm — cùng khuôn với mục "Đính kèm file" ở form đặt hàng (`OrderSheet`).
    private var attachmentsSection: some View {
        Section {
            ForEach(files) { file in
                HStack {
                    Image(systemName: "doc.fill").foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(file.name).lineLimit(1)
                    Spacer()
                    Button {
                        files.removeAll { $0.id == file.id }
                    } label: {
                        // N17: a named 44pt target (was the bare ~17pt icon), row height kept;
                        // less to the left, ✗ over the end of a long file name.
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            .padding(EdgeInsets(top: 14, leading: 10, bottom: 14, trailing: 18))
                            .contentShape(Rectangle())
                            .padding(EdgeInsets(top: -14, leading: -10, bottom: -14, trailing: -18))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Remove attachment"))
                }
                .listRowBackground(Theme.card)
            }
            Button {
                fileUploadError = nil
                showFileImporter = true
            } label: {
                if uploadingFile {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(String(localized: "Uploading…")).foregroundStyle(.secondary)
                    }
                } else {
                    Label(String(localized: "Add a file (photo, PDF…)"), systemImage: "paperclip")
                }
            }
            // Khoá cả khi ĐANG GỬI (`isBusy`): thêm file lúc đó là file lên R2 SAU khi POST đã
            // bay, không bao giờ vào đơn — mà `sent == true` thì cả mục này biến mất nên khách
            // không thấy gì bất thường. Và khoá theo TRẦN SERVER (10): server trả 400 nếu vượt,
            // chặn ở đây thì lỗi đó không bao giờ với tới khách.
            .disabled(uploadingFile || isBusy || files.count >= Self.maxFiles)
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.image, .pdf],
                allowsMultipleSelection: false
            ) { result in
                handleFilePick(result)
            }
            .listRowBackground(Theme.card)
            if let fileUploadError {
                Text(fileUploadError).font(.footnote).foregroundStyle(.red)
                    .listRowBackground(Theme.card)
            }
        } header: {
            // "(không bắt buộc)" bỏ theo mục cùng tên ở form đặt hàng (`ScanDetailView`, 13/08):
            // hai mục này cố ý CÙNG KHUÔN, để lệch chữ là hai màn nói hai kiểu về cùng một việc.
            // Ở đây cũng đúng nghĩa — nút Gửi chỉ đòi có LỜI NHẮN, file thì không.
            Text(String(localized: "Attachments"))
        } footer: {
            Text(files.count >= Self.maxFiles
                 ? String(localized: "Maximum \(Self.maxFiles) files per request.")
                 : String(localized: "A marked-up photo or PDF helps us find exactly what to fix."))
        }
    }

    /// Trần số file — PHẢI khớp `MAX_REVISION_FILES` ở server (`revision/route.ts`), nơi vượt trần
    /// là bị từ chối 400 chứ không cắt lặng lẽ.
    private static let maxFiles = 10

    private func handleFilePick(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        Task { await upload(url) }
    }

    /// Upload 1 file lên R2 qua presigned URL rồi thêm vào `files`. Cùng đường với `OrderSheet`.
    private func upload(_ url: URL) async {
        uploadingFile = true
        fileUploadError = nil
        // File từ .fileImporter nằm ngoài sandbox → phải xin quyền truy cập (và nhả sau).
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
            uploadingFile = false
        }
        let name = url.lastPathComponent
        do {
            let slot = try await APIClient.shared.presignOrderFile(
                fileName: name,
                contentType: OrderFileItem.mimeType(for: url)
            )
            try await APIClient.shared.uploadFile(at: url, to: slot.putUrl, contentType: slot.contentType) { _ in }
            files.append(OrderFileItem(id: slot.fileId, name: slot.name, url: slot.publicUrl))
        } catch {
            fileUploadError = error.localizedDescription
        }
    }

    private func submit() {
        isBusy = true
        errorMessage = nil
        Task {
            do {
                _ = try await APIClient.shared.requestRevision(
                    orderId: order.orderId,
                    message: message,
                    files: files.map { ["name": $0.name, "url": $0.url] }
                )
                sent = true
                onSent()
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
        }
    }
}

/// Bộ lọc trạng thái ở đầu tab Đơn hàng.
///
/// MỖI TRẠNG THÁI SERVER TRẢ VỀ ĐỀU CÓ ĐÚNG MỘT Ô (chủ app chốt 2026-07-23). Server có 5 trạng
/// thái (`customerOrderStatus` trong `app-api.ts`): received · in_production · on_hold · delivered
/// · refunded. Ở đây received+in_production gộp thành "Đang xử lý" — chủ app đã chốt bỏ nhãn "Đã
/// nhận" để khách bớt nôn nóng — còn ba cái kia mỗi cái một ô.
///
/// 🔴 Ô "Khác" tồn tại để TỔNG LUÔN KHỚP. Bản trước để `.processing` ôm "mọi thứ chưa giao chưa
/// hoàn" nên trạng thái mới của server tự rơi vào đó; nay `.processing` liệt kê tường minh (bắt
/// buộc, vì `.onHold` phải tách ra thì mới đếm riêng được), và nếu server thêm trạng thái thứ sáu
/// mà không có ô "Khác" thì đơn đó KHÔNG nằm trong ô nào — khách mở tab Đơn hàng thấy nó ở "Tất
/// cả" rồi bấm lọc là mất tích. Ô "Khác" chỉ hiện khi thật sự có đơn như vậy (xem `visibleFilters`).
/// Orders v2 B added `awaiting_payment` (not placed until paid) and `cancelled` (cancelled unpaid;
/// listed because the app asks `include=cancelled`) — one chip each, same rule.
enum OrderFilter: String, CaseIterable, Identifiable {
    case all, awaitingPayment, processing, onHold, ready, refunded, cancelled, other
    var id: String { rawValue }

    /// Các trạng thái app BIẾT tên. Dùng cho ô "Khác" — đừng sửa một mình nó, phải sửa cùng `matches`.
    private static let known: Set<String> = [
        "received", "in_production", "on_hold", "delivered", "refunded", "awaiting_payment", "cancelled",
    ]

    var title: String {
        switch self {
        case .all: return String(localized: "All")
        case .awaitingPayment: return String(localized: "Awaiting payment")
        case .processing: return String(localized: "Processing")
        case .onHold: return String(localized: "On hold")
        case .ready: return String(localized: "Ready")
        case .refunded: return String(localized: "Refunded")
        case .cancelled: return String(localized: "Cancelled")
        case .other: return String(localized: "Other")
        }
    }

    func matches(_ status: String) -> Bool {
        switch self {
        case .all: return true
        case .awaitingPayment: return status == "awaiting_payment"
        case .processing: return status == "received" || status == "in_production"
        case .onHold: return status == "on_hold"
        case .ready: return status == "delivered"
        case .refunded: return status == "refunded"
        case .cancelled: return status == "cancelled"
        case .other: return !Self.known.contains(status)
        }
    }
}

/// Street in bold + the rest of the address in grey, for the Home and Orders cards (2.52).
/// The grey line is footnote = the size of the date under it (owner 26/09).
struct CardAddress: View {
    let lines: AddressLines

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(lines.street)
                .font(.headline)
            if let rest = lines.rest {
                Text(rest)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct StatusBadge: View {
    let status: String

    /// The badge colours of a status; the order card's left edge reads them too.
    static func kind(_ status: String) -> Theme.Badge {
        info(status).1
    }

    private static func info(_ status: String) -> (String, Theme.Badge) {
        switch status {
        // "Ready" (owner 26/09, 2.52), the filter chip's word; was "Delivered".
        case "delivered":
            return (String(localized: "Ready"), .ok)
        case "on_hold":
            return (String(localized: "On hold"), .warn)
        case "refunded":
            return (String(localized: "Refunded"), .danger)
        // Orders v2 B: not placed until paid (Fog `warn`, mockups 34/35) · cancelled unpaid.
        case "awaiting_payment":
            return (String(localized: "Awaiting payment"), .warn)
        case "cancelled":
            return (String(localized: "Cancelled"), .neutral)
        // "in_production" VÀ "received"/mặc định đều hiện "Đang xử lý" — chủ app chốt bỏ nhãn
        // "Đã nhận" (khiến khách nôn nóng), gộp vào "đang xử lý".
        //
        // Fog `soft` = the selected filter chip's colours. Green/amber/red above keep their meaning.
        default:
            return (String(localized: "Processing"), .soft)
        }
    }

    var body: some View {
        let info = Self.info(status)
        return FogBadge(info.0, info.1)
    }
}
