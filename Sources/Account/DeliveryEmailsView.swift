import SwiftUI

/// Account → "Delivery emails" (F6, 2.79, owner-approved mockups 86–88): up to 5 other addresses
/// that also get the download links of every order once it is delivered — no price, no payment
/// link (server `lib/delivery-copies.ts`, list read at delivery time). Every change PUTs the whole
/// list and shows the server's answer (lowercased, deduped), never a local guess.
struct DeliveryEmailsView: View {
    /// Passed in, ✗ `@EnvironmentObject`: a pushed screen reading one crashed at push time
    /// (`ProjectView.store`, see OrdersView's note).
    let accountEmail: String

    private enum Phase { case loading, failed, ready }

    @State private var phase = Phase.loading
    @State private var emails: [String] = []
    /// The server's cap (5); `max` absent = 5.
    @State private var limit = 5
    /// The "Add email" row is a text field.
    @State private var adding = false
    @State private var draft = ""
    /// Red line under the list: a refused address or a failed save.
    @State private var problem: String?
    @State private var saving = false
    /// Bumped by every save the server took: a list read that started before it is stale.
    @State private var revision = 0
    /// The address the "Remove this email?" alert is about.
    @State private var removal: String?
    @FocusState private var fieldFocused: Bool

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
                        Text(String(localized: "Couldn't load your delivery emails."))
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
                listSection
            }
        }
        .fogScreen()
        .navigationTitle(String(localized: "Delivery emails"))
        .navigationBarTitleDisplayMode(.inline)
        // Also re-runs when the Account tab comes back: a quiet refresh (see `load`).
        .task { await load() }
        .onChange(of: problem) { _, text in
            // VoiceOver hears the red line (as MeshScanFlowView's coach announcements).
            if let text { UIAccessibility.post(notification: .announcement, argument: text) }
        }
        .alert(
            String(localized: "Remove this email?"),
            isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
            presenting: removal
        ) { email in
            Button(String(localized: "Remove email"), role: .destructive) {
                Task { await save(emails.filter { $0 != email }) }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { email in
            Text(verbatim: email)
        }
    }

    private var listSection: some View {
        Section {
            ForEach(emails, id: \.self) { email in
                HStack(spacing: 12) {
                    Button {
                        removal = email
                    } label: {
                        // 44pt target, row height kept (as RevisionSheet's remove button, N17).
                        Image(systemName: "minus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.red)
                            .padding(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 10))
                            .contentShape(Rectangle())
                            .padding(EdgeInsets(top: -12, leading: -12, bottom: -12, trailing: -10))
                    }
                    .buttonStyle(.borderless)
                    .disabled(saving)
                    .accessibilityLabel(String(localized: "Remove email"))
                    .accessibilityValue(Text(verbatim: email))
                    Text(verbatim: email)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .listRowBackground(Theme.card)
            }
            addRow
                .listRowBackground(Theme.card)
        } header: {
            Text(String(localized: "Also send finished files to"))
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let problem {
                    Text(problem)
                        .foregroundStyle(.red)
                }
                // WrappedText: a plain footer Text of this length lost its last line in German at
                // xxxLarge (trap #44, the Delete account footer).
                WrappedText(String(localized: "When your floor plans are ready, we also email the download links to these addresses, for every order. They don't see prices."),
                            style: .footnote, color: .secondaryLabel)
            }
        }
    }

    /// The plus icon is the same size and place open or closed (the text does not jump).
    private var plusIcon: some View {
        Image(systemName: "plus.circle")
            .font(.title3)
            .foregroundStyle(Theme.accentText)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var addRow: some View {
        if adding {
            HStack(spacing: 12) {
                plusIcon
                TextField(String(localized: "Email address"), text: $draft)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($fieldFocused)
                    // Focus once the row exists (set in the same tap as `adding`, the field is not
                    // there yet and the keyboard would not open).
                    .task { fieldFocused = true }
                    .onSubmit { Task { await add() } }
                    .onChange(of: draft) { problem = nil }
                if saving {
                    ProgressView()
                } else {
                    Button(String(localized: "Add")) {
                        Task { await add() }
                    }
                    .buttonStyle(.borderless)
                    .fontWeight(.semibold)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onChange(of: fieldFocused) { _, focused in
                // Tapping away from an empty field puts the "Add email" row back.
                if !focused, draft.trimmingCharacters(in: .whitespaces).isEmpty, !saving { adding = false }
            }
        } else {
            Button {
                draft = ""
                problem = nil
                adding = true
            } label: {
                HStack(spacing: 12) {
                    plusIcon
                    Text(String(localized: "Add email"))
                    Spacer()
                    // Concrete colour: a hierarchical `.secondary` inside a Button label takes the
                    // button's tint (faded blue; traps #45, #47a). Mockup: grey.
                    Text("\(emails.count) of \(limit)")
                        .foregroundStyle(Color.secondary)
                }
            }
            .disabled(saving || emails.count >= limit)
        }
    }

    /// First load: spinner, then the list or the retry row. Later loads (the tab coming back) are
    /// quiet: a failure keeps the list on screen, and an answer older than a save is dropped.
    private func load() async {
        if phase != .ready { phase = .loading }
        let started = revision
        do {
            let list = try await APIClient.shared.deliveryEmails()
            guard !saving, revision == started else { return }
            emails = list.emails
            limit = list.max ?? 5
            phase = .ready
        } catch {
            // Leaving the screen cancels the request: nothing to show, ✗ the retry row.
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { return }
            if phase != .ready { phase = .failed }
        }
    }

    private func add() async {
        guard !saving else { return }
        let email = draft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if email.isEmpty {
            // Done on an empty field: nothing to add, the "Add email" row comes back.
            fieldFocused = false
            adding = false
            return
        }
        if !Self.looksValid(email) {
            problem = String(localized: "Please enter a valid email address.")
        } else if email == accountEmail.lowercased() {
            problem = String(localized: "This is your account email. You already get these emails.")
        } else if emails.contains(email) {
            problem = String(localized: "This email is already on the list.")
        } else if await save(emails + [email]) {
            draft = ""
            // Reset first: a focus left `true` on the removed field would make the next
            // "Add email" tap set true → true and the keyboard would not open.
            fieldFocused = false
            adding = false
            return
        }
        // Refused: keep typing (mockup ④ keeps the keyboard up).
        fieldFocused = true
    }

    /// PUTs the whole list; on success the list is the server's echo. False = refused or failed
    /// (the reason is the red line).
    @discardableResult
    private func save(_ next: [String]) async -> Bool {
        guard !saving else { return false }
        saving = true
        problem = nil
        defer { saving = false }
        do {
            let list = try await APIClient.shared.setDeliveryEmails(next)
            emails = list.emails
            limit = list.max ?? 5
            revision += 1
            return true
        } catch let error as APIError {
            switch error.code {
            case "invalid_email": problem = String(localized: "Please enter a valid email address.")
            case "own_email": problem = String(localized: "This is your account email. You already get these emails.")
            case "too_many": problem = String(localized: "You can add up to \(limit) email addresses.")
            default: problem = String(localized: "Something went wrong. Please try again.")
            }
        } catch {
            problem = String(localized: "Something went wrong. Please try again.")
        }
        return false
    }

    /// The server's rule (`delivery-copies.ts` EMAIL), on the lowercased address: HTML5's valid email
    /// address with a letters-only top-level domain, ≤ 254 (local part ≤ 64). Stricter than sign-up:
    /// "a@b.cc," "<a@b.cc>" "mailto:a@b.cc" are refused here, not stored and bounced later.
    static func looksValid(_ email: String) -> Bool {
        email.utf8.count <= 254
            && email.range(of: #"^[a-z0-9.!#$%&'*+/=?^_`{|}~-]{1,64}@[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*\.[a-z]{2,63}$"#, options: .regularExpression) != nil
    }
}
