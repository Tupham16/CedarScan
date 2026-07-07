import SwiftUI

/// Danh sách đơn đã đặt xử lý: trạng thái + file thành phẩm khi đã giao.
struct OrdersView: View {
    @EnvironmentObject private var account: AccountStore
    @State private var orders: [OrderDTO] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var revisionOrder: OrderDTO?

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
            .sheet(item: $revisionOrder) { order in
                RevisionSheet(order: order) {
                    Task { await load() }
                }
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
                HStack(spacing: 6) {
                    Text("\(order.orderNumber) · \(Self.formatDate(order.placedAt))")
                    if let total = order.total, total > 0 {
                        Text("· $\(total)")
                        if order.paid == true {
                            Label(L.t("Paid", "Đã trả"), systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if order.paid != true, let payString = order.paymentUrl, let payURL = URL(string: payString) {
                    Link(destination: payURL) {
                        Label(L.t("Pay Now", "Thanh toán ngay"), systemImage: "creditcard.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                }

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
                    Button {
                        revisionOrder = order
                    } label: {
                        Label(L.t("Request a revision", "Yêu cầu sửa"), systemImage: "pencil.and.outline")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
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

/// Form yêu cầu sửa: khách mô tả chỗ cần chỉnh → đơn quay lại hàng xử lý.
struct RevisionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let order: OrderDTO
    let onSent: () -> Void

    @State private var message = ""
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var sent = false

    var body: some View {
        NavigationStack {
            Form {
                if sent {
                    Section {
                        VStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 44))
                                .foregroundStyle(.green)
                            Text(L.t("Revision requested!", "Đã gửi yêu cầu sửa!"))
                                .font(.headline)
                            Text(L.t(
                                "Our team will update your floor plan and deliver a revised version.",
                                "Đội ngũ sẽ chỉnh sửa và giao lại bản cập nhật cho bạn."
                            ))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                } else {
                    Section {
                        TextField(
                            L.t("What should we change? (e.g. missing door on Floor 2, wrong room label…)",
                                "Cần sửa gì? (vd thiếu cửa ở Floor 2, sai tên phòng…)"),
                            text: $message,
                            axis: .vertical
                        )
                        .lineLimit(4...8)
                    } header: {
                        Text(order.orderNumber)
                    } footer: {
                        Text(L.t("Revisions for mistakes on our side are free.",
                                 "Sửa lỗi thuộc về chúng tôi là miễn phí."))
                    }
                    if let errorMessage {
                        Section {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle(L.t("Request a revision", "Yêu cầu sửa"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(sent ? L.t("Close", "Đóng") : L.t("Cancel", "Hủy")) { dismiss() }
                }
                if !sent {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            submit()
                        } label: {
                            if isBusy {
                                ProgressView()
                            } else {
                                Text(L.t("Send", "Gửi")).bold()
                            }
                        }
                        .disabled(isBusy || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    private func submit() {
        isBusy = true
        errorMessage = nil
        Task {
            do {
                _ = try await APIClient.shared.requestRevision(orderId: order.orderId, message: message)
                sent = true
                onSent()
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
        }
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
