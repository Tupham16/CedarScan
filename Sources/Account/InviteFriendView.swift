import SwiftUI
import UIKit

/// Account → "Invite a friend" (F8, owner 20/10/2026; mockups `PLAN-GIAO-DIEN-mockups` 86 light /
/// 87 dark). The rules live on the server (`lib/referrals.ts` in order-webapp): a friend who enters
/// this account's code while creating their account gets the usual free first orders; when the
/// friend's first order is delivered, this account gets one free 2D floor plan, which the order
/// form then uses by itself (`OrderSheet.referralCreditApplies`).
///
/// · The code is made by the server on the first visit (`GET referral`); the screen shows only
///   counts — the server never says who joined (Privacy Policy, "Information you give us").
/// · Nothing here is bought or sold, and a free floor plan has no cash value (App Store 3.1.1,
///   Terms "Invite a friend").
/// · Share = the system share sheet with ONE string (text + App Store link): an app that keeps only
///   the URL item of a text + URL pair would drop the code.
/// · `enabled: false` (server switch `referral-config`) = the programme is closed to new sign-ups:
///   the Account row goes away (`AccountStore.referralWentAway`) and this screen says so.
struct InviteFriendView: View {
    @EnvironmentObject private var account: AccountStore
    @State private var info: ReferralResponse?
    @State private var closed = false
    @State private var failed = false
    @State private var copied = false
    @State private var copiedReset: Task<Void, Never>?

    var body: some View {
        ScrollView {
            Group {
                if let info, let code = info.code, !code.isEmpty {
                    loaded(info, code: code)
                } else if closed {
                    message(String(localized: "Invite a friend isn't available right now."))
                } else if failed {
                    VStack(spacing: 12) {
                        message(String(localized: "Something went wrong. Please try again."))
                        Button {
                            Task { await load() }
                        } label: {
                            Text(String(localized: "Retry"))
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 18)
                                .padding(.vertical, 9)
                        }
                        .buttonStyle(FogTint(radius: 12))
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 260)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .fogScreen()
        .navigationTitle(String(localized: "Invite a friend"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onDisappear { copiedReset?.cancel() }
    }

    private func load() async {
        failed = false
        do {
            let response = try await APIClient.shared.referral()
            if response.enabled == false {
                closed = true
                info = nil
                account.referralWentAway()
                return
            }
            closed = false
            info = response
        } catch {
            // Keep what is on screen (a refresh that failed); nothing yet = the retry state.
            if info == nil { failed = true }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 200)
    }

    @ViewBuilder
    private func loaded(_ info: ReferralResponse, code: String) -> some View {
        let available = info.freeOrdersAvailable ?? 0
        VStack(spacing: 0) {
            Image(systemName: "gift")
                .font(.system(size: 27, weight: .regular))
                .foregroundStyle(Theme.accentText)
                .frame(width: 64, height: 64)
                .background(Circle().fill(Theme.accentTint))
                .accessibilityHidden(true)
            Text(String(localized: "Get a free floor plan"))
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .padding(.top, 14)
            // WrappedText: iOS 26 can cut the last line of a centred paragraph (trap #44).
            WrappedText(heroText(freeFirstOrders: info.freeFirstOrders ?? 0), style: .subheadline,
                        alignment: .center, color: .secondaryLabel)
                .padding(.top, 8)

            codeBox(code)
                .padding(.top, 20)
            Text(copied ? String(localized: "Invite code copied") : String(localized: "Tap the code to copy it"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 7)
                .accessibilityHidden(true)

            ShareLink(item: shareText(info, code: code)) {
                Label(String(localized: "Share invite"), systemImage: "square.and.arrow.up")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(FogPrimary())
            .padding(.top, 14)

            stats(friends: info.friendsJoined ?? 0, earned: info.freeOrdersEarned ?? 0)
                .padding(.top, 14)

            if available > 0 {
                HStack(alignment: .top, spacing: 9) {
                    Text(verbatim: "🎁")
                        .accessibilityHidden(true)
                    Text(available == 1
                         ? String(localized: "1 free 2D floor plan ready — it is used on your next order.")
                         : String(localized: "\(available) free 2D floor plans ready — one is used on each of your next orders."))
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(Theme.Badge.ok.fg)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.Badge.ok.bg))
                .padding(.top, 12)
            }

            WrappedText(String(localized: "Your friend enters the code when they create their account. Free floor plans have no cash value."),
                        style: .footnote, color: .secondaryLabel)
                .padding(.top, 12)
                .padding(.horizontal, 4)
        }
    }

    private func heroText(freeFirstOrders: Int) -> String {
        freeFirstOrders > 0
            ? String(localized: "Your friend gets \(freeFirstOrders) free orders, like every new customer. When their first order is delivered, you get a free 2D floor plan.")
            : String(localized: "When a friend you invite gets their first order delivered, you get a free 2D floor plan.")
    }

    /// One string, link last: see the type comment. The link comes from the server (nil until the
    /// owner sets it); the text says "Get it on the App Store" so it works without one.
    private func shareText(_ info: ReferralResponse, code: String) -> String {
        let free = info.freeFirstOrders ?? 0
        let text = free > 0
            ? String(localized: "I use CedarScan to get floor plans from a quick iPhone scan. Get it on the App Store and sign up with my invite code \(code): new customers get their first \(free) orders free.")
            : String(localized: "I use CedarScan to get floor plans from a quick iPhone scan. Get it on the App Store and sign up with my invite code \(code).")
        guard let url = httpsURL(info.shareUrl) else { return text }
        return text + "\n" + url.absoluteString
    }

    private func codeBox(_ code: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return Button {
            copy(code)
        } label: {
            HStack(spacing: 12) {
                Text(verbatim: code)
                    .font(.system(size: 26, weight: .bold, design: .monospaced))
                    .tracking(2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(Color.primary)
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.accentText)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(shape.fill(Theme.card))
            .overlay(shape.strokeBorder(Theme.ghostBorder, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        // VoiceOver: "Invite code, JOHN-7Q2" + the hint; the caption under it is hidden (same words).
        .accessibilityLabel(Text(String(localized: "Invite code")) + Text(verbatim: ", \(code)"))
        .accessibilityHint(String(localized: "Tap the code to copy it"))
    }

    private func copy(_ code: String) {
        UIPasteboard.general.string = code
        copied = true
        UIAccessibility.post(notification: .announcement, argument: String(localized: "Invite code copied"))
        copiedReset?.cancel()
        copiedReset = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }

    private func stats(friends: Int, earned: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return HStack(spacing: 0) {
            stat(friends, String(localized: "Friends joined"))
            Rectangle()
                .fill(Theme.hairline)
                .frame(width: 1)
                .padding(.vertical, 10)
            stat(earned, String(localized: "Free floor plans earned"))
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(shape.fill(Theme.card))
        .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 1))
    }

    private func stat(_ value: Int, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(verbatim: "\(value)")
                .font(.title2.weight(.bold))
                .monospacedDigit()
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
    }
}
