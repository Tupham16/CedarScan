import SwiftUI

/// Account → "Team" (F10b, owner-approved mockups f10b-1/2): the team this account is on,
/// read-only — members (admins also see open invitations), the card that pays the team's orders,
/// and a link to manage it on the web (invites, card, leaving: owner 20/10 "management stays on
/// the web"). `GET team` on every open.
struct TeamView: View {
    private enum Phase { case loading, failed, ready }

    @State private var phase = Phase.loading
    @State private var answer: TeamResponse?

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
                HStack(spacing: 12) {
                    avatar { Text(Self.initials(member.name)) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(member.name)
                        if member.isYou == true {
                            Text(String(localized: "You"))
                                .font(.footnote)
                                .foregroundStyle(Color.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    if member.role == "admin" {
                        FogBadge(String(localized: "Admin"), .neutral)
                    }
                }
                .accessibilityElement(children: .combine)
                .listRowBackground(Theme.card)
            }
            // Admins only (the server sends none to members).
            ForEach(answer.invites ?? []) { invite in
                HStack(spacing: 12) {
                    avatar { Image(systemName: "envelope") }
                    Text(verbatim: invite.email)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    FogBadge(String(localized: "Invited"), .warn)
                }
                .accessibilityElement(children: .combine)
                .listRowBackground(Theme.card)
            }
        } header: {
            Text(String(localized: "Members"))
        } footer: {
            Text(String(localized: "Everyone on the team sees the team's orders and can order any scan the team uploaded."))
        }
        if let card = team.card {
            Section {
                Label(card.label, systemImage: "creditcard")
                    .listRowBackground(Theme.card)
            } header: {
                Text(String(localized: "Team card"))
            } footer: {
                Text(String(localized: "Your orders are paid with this card."))
            }
        }
    }

    private func avatar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.thumbLine)
            .frame(width: 34, height: 34)
            .background(Circle().fill(Theme.thumbBg))
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
