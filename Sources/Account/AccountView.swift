import SwiftUI

struct AccountView: View {
    @EnvironmentObject private var account: AccountStore

    var body: some View {
        NavigationStack {
            Group {
                if account.needsVerification {
                    ScrollView { VerifyEmailView() }
                } else if let customer = account.customer {
                    List {
                        Section {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(customer.name)
                                    .font(.headline)
                                Text(customer.email)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                        Section {
                            Link(destination: URL(string: "https://cedar247.com")!) {
                                Label("cedar247.com", systemImage: "globe")
                            }
                        } header: {
                            Text(L.t("About", "Giới thiệu"))
                        } footer: {
                            Text(L.t(
                                "Scan your space with LiDAR, send it to Cedar247, and our team will produce professional 2D floor plans (PDF/PNG/DWG) for you.",
                                "Quét không gian bằng LiDAR, gửi cho Cedar247 — đội ngũ của chúng tôi sẽ làm bản vẽ mặt bằng chuyên nghiệp (PDF/PNG/DWG) cho bạn."
                            ))
                        }
                        Section {
                            Button(role: .destructive) {
                                account.signOut()
                            } label: {
                                Label(L.t("Sign out", "Đăng xuất"), systemImage: "rectangle.portrait.and.arrow.right")
                            }
                        }
                    }
                } else {
                    ScrollView {
                        AuthView()
                    }
                }
            }
            .navigationTitle(L.t("Account", "Tài khoản"))
        }
    }
}
