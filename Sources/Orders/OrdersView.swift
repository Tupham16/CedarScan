import SwiftUI

/// Danh sách đơn đã đặt xử lý: trạng thái + file thành phẩm khi đã giao.
struct OrdersView: View {
    @EnvironmentObject private var account: AccountStore
    @State private var orders: [OrderDTO] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if !account.isSignedIn {
                    signedOutState
                } else if orders.isEmpty && !isLoading {
                    emptyState
                } else {
                    ordersList
                }
            }
            .navigationTitle(L.t("Orders", "Đơn hàng"))
            .task(id: account.isSignedIn) {
                if account.isSignedIn { await load() }
            }
            .refreshable {
                await load()
            }
        }
    }

    private func load() async {
        guard account.isSignedIn else { return }
        isLoading = true
        do {
            orders = try await APIClient.shared.listOrders().orders
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private var signedOutState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(L.t("Sign in to see your orders", "Đăng nhập để xem đơn hàng"))
                .font(.headline)
            Text(L.t("Go to the Account tab to sign in or create an account.",
                     "Vào mục Tài khoản để đăng nhập hoặc đăng ký."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            if let errorMessage {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(L.t("Retry", "Thử lại")) { Task { await load() } }
                    .buttonStyle(.bordered)
            } else {
                Image(systemName: "shippingbox")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text(L.t("No orders yet", "Chưa có đơn nào"))
                    .font(.headline)
                Text(L.t(
                    "Open a scan and tap \"Order Floor Plan\" to have our team create professional drawings.",
                    "Mở một bản quét và bấm \"Đặt làm mặt bằng\" để đội ngũ Cedar247 vẽ bản chuyên nghiệp cho bạn."
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
        }
        .padding(32)
    }

    private var ordersList: some View {
        List(orders) { order in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(order.scanName ?? order.orderNumber)
                        .font(.headline)
                    Spacer()
                    StatusBadge(status: order.status)
                }
                Text("\(order.orderNumber) · \(Self.formatDate(order.placedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if order.status == "delivered" {
                    if let deliveredUrl = order.deliveredUrl, let url = URL(string: deliveredUrl) {
                        Link(destination: url) {
                            Label(L.t("Download deliverables", "Tải file thành phẩm"), systemImage: "arrow.down.circle.fill")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    ForEach(order.deliveryFiles, id: \.self) { file in
                        if let url = URL(string: file.url) {
                            Link(destination: url) {
                                HStack {
                                    Image(systemName: "doc.fill")
                                    Text(file.fileName)
                                        .lineLimit(1)
                                    if let size = file.sizeLabel {
                                        Text(size)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .font(.caption)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private static func formatDate(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return "" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

struct StatusBadge: View {
    let status: String

    private var info: (String, Color) {
        switch status {
        case "delivered":
            return (L.t("Delivered", "Đã giao"), .green)
        case "in_production":
            return (L.t("In production", "Đang xử lý"), .blue)
        case "on_hold":
            return (L.t("On hold", "Tạm giữ"), .orange)
        case "refunded":
            return (L.t("Refunded", "Hoàn tiền"), .red)
        default:
            return (L.t("Received", "Đã nhận"), .gray)
        }
    }

    var body: some View {
        Text(info.0)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(info.1.opacity(0.15), in: Capsule())
            .foregroundStyle(info.1)
    }
}
