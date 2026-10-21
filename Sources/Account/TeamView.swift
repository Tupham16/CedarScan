import SwiftUI

/// Account → "Team" (F10b, owner-approved mockups f10b-1/2): the team this account is on,
/// read-only — members (admins also see open invitations), the card that pays the team's orders,
/// and a link to manage it on the web (invites, card, leaving: owner 20/10 "management stays on
/// the web"). `GET team` on every open.
struct TeamView: View {
    private enum Phase { case loading, failed, ready }

    @State private var phase = Phase.loading
    @State private var answer: TeamResponse?
    @Environment(\.dynamicTypeSize) private var typeSize

    private static let manageURL = URL(string: "https://app.cedar247.com/my/team")!

    var body: some View {
        List {
            switch phase {
            case .loading:
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Theme.card)
                }
            case .failed:
                Section {
                    VStack(spacing: 10) {
                        Text(String(localized: "Couldn't load your team."))
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                            .multilineTextAlignment(.center)
                        Button(String(localized: "Try again")) {
                            Task { await load() }
                        }
                        .buttonStyle(.borderless)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Theme.card)
                }
            case .ready:
                if let answer, let team = answer.team {
                    teamSections(team, answer)
                } else {
                    // Left or removed since the Account tab last asked (its row goes on the next refresh).
                    Section {
                        Text(String(localized: "You're not on a team."))
                            .foregroundStyle(Color.secondary)
                            .listRowBackground(Theme.card)
                    }
                }
            }
            Section {
                Link(destination: Self.manageURL) {
                    Label(String(localized: "Manage on app.cedar247.com"), systemImage: "arrow.up.right.square")
                }
                .listRowBackground(Theme.card)
            }
        }
        .fogScreen()
        .navigationTitle(String(localized: "Team"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    @ViewBuilder
    private func teamSections(_ team: TeamSummaryDTO, _ answer: TeamResponse) -> some View {
        Section {
            HStack(spacing: 12) {
                Text(Self.initials(team.name))
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.accentFill))
                    .accessibilityHidden(true)
                Text(team.name)
                    .font(.title3.weight(.semibold))
            }
            .padding(.vertical, 4)
            .listRowBackground(Theme.card)
        }
        Section {
            ForEach(answer.members ?? []) { member in
                personRow(
                    avatar { Text(Self.initials(member.name)) },
                    title: member.name,
                    subtitle: member.isYou == true ? String(localized: "You") : nil,
                    badge: member.role == "admin" ? FogBadge(String(localized: "Admin"), .neutral) : nil
                )
            }
            // Admins only (the server sends none to members).
            ForEach(answer.invites ?? []) { invite in
                personRow(
                    avatar(.warn) { Image(systemName: "envelope") },
                    title: invite.email,
                    subtitle: nil,
                    badge: FogBadge(String(localized: "Invited"), .warn)
                )
            }
        } header: {
            Text(String(localized: "Members"))
        } footer: {
            // WrappedText: a plain footer Text lost its last line in German at xxxLarge (trap #44).
            WrappedText(String(localized: "Everyone on the team sees the team's orders and can order any scan the team uploaded."),
                        style: .footnote, color: .secondaryLabel)
        }
        if let card = team.card {
            Section {
                Label(card.label, systemImage: "creditcard")
                    .listRowBackground(Theme.card)
            } header: {
                Text(String(localized: "Team card"))
            } footer: {
                // ✗ while the server would not charge it (card keys / in-app switch), or while the
                // company's account pays first (F10c `billing.mode` "wallet" / "invoice").
                if answer.cardsAvailable == true, (answer.billing?.mode ?? "card") == "card" {
                    WrappedText(String(localized: "Your orders are paid with this card."), style: .footnote, color: .secondaryLabel)
                }
            }
        }
    }

    /// Avatar, name (+ "You"), badge. At accessibility sizes the badge goes under the name (as
    /// `OrdersView.orderRow`): beside it an email was squeezed to "an…m".
    private func personRow(_ avatar: some View, title: String, subtitle: String?, badge: FogBadge?) -> some View {
        HStack(spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    .truncationMode(.middle)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                }
                if typeSize.isAccessibilitySize, let badge {
                    badge
                }
            }
            Spacer(minLength: 8)
            if !typeSize.isAccessibilitySize, let badge {
                badge
            }
        }
        .accessibilityElement(children: .combine)
        .listRowBackground(Theme.card)
    }

    /// `kind` nil = a person (grey), `.warn` = an open invitation (mockup f10b-2).
    private func avatar<Content: View>(_ kind: Theme.Badge? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.footnote.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            // Decorative (hidden from VoiceOver): past xxxLarge the envelope symbol outgrew its circle.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .foregroundStyle(kind?.fg ?? Theme.thumbLine)
            .frame(width: 34, height: 34)
            .background(Circle().fill(kind?.bg ?? Theme.thumbBg))
            .accessibilityHidden(true)
    }

    /// "John Smith" → "JS": the first letter of the first two words.
    static func initials(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first).map { String($0) }.joined().uppercased()
    }

    /// Spinner, then the team or the retry row. A reload keeps what is on screen if it fails.
    private func load() async {
        if phase != .ready { phase = .loading }
        do {
            answer = try await APIClient.shared.team()
            phase = .ready
        } catch {
            // Leaving the screen cancels the request: nothing to show, ✗ the retry row.
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { return }
            if phase != .ready { phase = .failed }
        }
    }
}
