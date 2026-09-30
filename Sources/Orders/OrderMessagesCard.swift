import SwiftUI

/// Messages from the team about an order ("Nhắn khách" on the board, PLAN-THONG-BAO-DAY.md §5,
/// mockups 68–70), right under the order summary. The newest one in a collapsible card; the others
/// behind "N earlier messages", inline. Every message was also emailed: replying = answering that
/// email (✗ in-app reply). Attachments are `Link`s to the browser (App Store rule: no in-app viewer).
///
/// Open or collapsed (owner 30/09): a message this device has not shown yet (new, or the push that
/// was just tapped) opens the card; one already shown leaves it collapsed, unless the customer
/// opened it themselves last time (`OrderMessageMemory`, per order).
struct OrderMessagesCard: View {
    let orderId: String
    /// Newest first (server order), only those with something to show.
    let messages: [OrderMessageDTO]
    /// nil until decided on appear.
    @State private var expanded: Bool?
    @State private var showEarlier = false
    @Environment(\.dynamicTypeSize) private var typeSize

    init(orderId: String, messages: [OrderMessageDTO]) {
        self.orderId = orderId
        self.messages = messages.filter(Self.hasContent)
    }

    var body: some View {
        if let newest = messages.first {
            card(newest, isOpen: expanded == true)
                .padding(.top, 12) // mockup 68: under the summary, no section title
                .onAppear { decide() }
                .onChange(of: newest.id) { _, _ in decide() }
        }
    }

    /// A message not shown on this device yet opens the card (and is now shown); otherwise the
    /// customer's own last choice for this order, collapsed by default.
    private func decide() {
        guard let newest = messages.first else { return }
        if OrderMessageMemory.seenMessageId(orderId) != newest.id {
            OrderMessageMemory.setSeen(orderId, messageId: newest.id)
            expanded = true
        } else if expanded == nil {
            expanded = OrderMessageMemory.keptOpen(orderId)
        }
    }

    private func toggle() {
        let open = expanded != true
        expanded = open
        OrderMessageMemory.setKeptOpen(orderId, open)
        if !open { showEarlier = false }
    }

    private func card(_ newest: OrderMessageDTO, isOpen: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                VStack(alignment: .leading, spacing: 4) {
                    header(newest, isOpen: isOpen)
                    if !isOpen {
                        Text(Self.preview(newest))
                            .font(.footnote)
                            .foregroundStyle(Color.secondary)
                            .lineLimit(1)
                            .padding(.leading, typeSize.isAccessibilitySize ? 0 : 42)
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, isOpen ? 10 : 13)
                .padding(.leading, 16)
                .padding(.trailing, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                VStack(alignment: .leading, spacing: 10) {
                    messageBody(newest)
                    WrappedText(
                        String(localized: "We also emailed you this message. To reply, answer that email."),
                        style: .caption1,
                        color: .secondaryLabel
                    )
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                earlier
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.shape.fill(Theme.card))
        .overlay(Self.shape.strokeBorder(Theme.hairline, lineWidth: 1))
    }

    private static let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    /// Icon · "Message from Cedar247" · time · chevron (mockups 68/70). Accessibility sizes put
    /// the time under the title: side by side the title was cut.
    private func header(_ newest: OrderMessageDTO, isOpen: Bool) -> some View {
        HStack(spacing: 10) {
            if !typeSize.isAccessibilitySize {
                Image(systemName: "message")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.accentText)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Theme.accentTint))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                // Concrete colours in a Button label (trap #45).
                Text(String(localized: "Message from Cedar247"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)
                if typeSize.isAccessibilitySize {
                    time(newest)
                }
            }
            Spacer(minLength: 8)
            if !typeSize.isAccessibilitySize {
                time(newest)
            }
            Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(uiColor: .tertiaryLabel))
                .accessibilityHidden(true)
        }
    }

    private func time(_ message: OrderMessageDTO) -> some View {
        Text(Self.shortTime(message.sentAt))
            .font(.caption)
            .foregroundStyle(Color.secondary)
            .lineLimit(1)
            .fixedSize()
    }

    /// Text (selectable: an address or a link in it can be copied), then its files.
    private func messageBody(_ message: OrderMessageDTO) -> some View {
        messageBody(text: Self.text(message), files: Self.files(message))
    }

    /// The state as parameters: a local `let` inside a ViewBuilder is where this CI has died of
    /// "type-check timeout" (`OrderDetailView.orderedItemsCard`).
    @ViewBuilder
    private func messageBody(text: String, files: [MessageFile]) -> some View {
        if !text.isEmpty {
            WrappedText(text, style: .subheadline, selectable: true)
        }
        if !files.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(files.indices, id: \.self) { index in
                    fileLink(files[index])
                }
            }
        }
    }

    private func fileLink(_ file: MessageFile) -> some View {
        Link(destination: file.url) {
            HStack(spacing: 8) {
                Image(systemName: "doc")
                Text(file.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .font(.footnote)
            .foregroundStyle(Theme.accentText)
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .overlay(alignment: .top) { Self.hairline }
    }

    // MARK: Earlier messages

    /// "N earlier messages" (mockup 70), opening them inline under it, newest first.
    private var earlier: some View {
        earlierList(Array(messages.dropFirst()))
    }

    @ViewBuilder
    private func earlierList(_ older: [OrderMessageDTO]) -> some View {
        if !older.isEmpty {
            Button {
                showEarlier.toggle()
            } label: {
                HStack(spacing: 8) {
                    Text(older.count == 1
                         ? String(localized: "1 earlier message")
                         : String(localized: "\(older.count) earlier messages"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.accentText)
                    Spacer(minLength: 0)
                    Image(systemName: showEarlier ? "chevron.up" : "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color(uiColor: .tertiaryLabel))
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .padding(.leading, 16)
                .padding(.trailing, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .top) { Self.hairline }
            if showEarlier {
                ForEach(older) { message in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Self.fullTime(message.sentAt))
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                        messageBody(message)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .overlay(alignment: .top) { Self.hairline }
                }
            }
        }
    }

    // MARK: Data

    /// Only https links leave the app (`httpsURL`); a file without a name shows its URL's.
    private static func files(_ message: OrderMessageDTO) -> [MessageFile] {
        (message.attachments ?? []).compactMap { file -> MessageFile? in
            guard let url = httpsURL(file.url) else { return nil }
            let name = file.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return MessageFile(name: name.isEmpty ? url.lastPathComponent : name, url: url)
        }
    }

    private static func text(_ message: OrderMessageDTO) -> String {
        message.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func hasContent(_ message: OrderMessageDTO) -> Bool {
        !text(message).isEmpty || !files(message).isEmpty
    }

    /// Collapsed card: the text on one line, or the number of files when there is no text.
    private static func preview(_ message: OrderMessageDTO) -> String {
        let text = (message.text ?? "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !text.isEmpty { return text }
        let count = files(message).count
        return count == 1 ? String(localized: "1 attachment") : String(localized: "\(count) attachments")
    }

    /// Mail style: today = the time, this year = day + month, else the date.
    private static func shortTime(_ iso: String?) -> String {
        guard let iso, let date = OrderDTO.isoDate(iso) else { return "" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private static func fullTime(_ iso: String?) -> String {
        guard let iso, let date = OrderDTO.isoDate(iso) else { return "" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private static var hairline: some View {
        Theme.hairline.frame(height: 1)
    }
}

private struct MessageFile {
    let name: String
    let url: URL
}

/// Per order on this device: the newest message already shown, and whether the customer left the
/// card open. Cleared at sign-out (`AccountStore.signOut`): order and message ids only.
enum OrderMessageMemory {
    private static let seenKey = "orderMessages.seen.v1"
    private static let openKey = "orderMessages.open.v1"

    static func seenMessageId(_ orderId: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: seenKey) as? [String: String])?[orderId]
    }

    static func setSeen(_ orderId: String, messageId: String) {
        var all = (UserDefaults.standard.dictionary(forKey: seenKey) as? [String: String]) ?? [:]
        all[orderId] = messageId
        UserDefaults.standard.set(all, forKey: seenKey)
    }

    static func keptOpen(_ orderId: String) -> Bool {
        (UserDefaults.standard.dictionary(forKey: openKey) as? [String: Bool])?[orderId] ?? false
    }

    static func setKeptOpen(_ orderId: String, _ open: Bool) {
        var all = (UserDefaults.standard.dictionary(forKey: openKey) as? [String: Bool]) ?? [:]
        all[orderId] = open ? true : nil
        UserDefaults.standard.set(all, forKey: openKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: seenKey)
        UserDefaults.standard.removeObject(forKey: openKey)
    }
}
