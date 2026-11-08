import SwiftUI

/// The list of chats. Chat needs an app password with its own permission, but only blames that when
/// the server does, and always shows what the server said.
struct ConversationsPanel: View {
    @Environment(DeckStore.self) private var deck
    @Environment(\.openURL) private var openURL
    let accountDID: String
    let onOpen: (Conversation) -> Void

    @State private var conversations: [Conversation] = []
    @State private var errorMessage: String?
    @State private var lacksPermission = false
    @State private var isWritingNew = false
    @State private var personQuery = ""
    @State private var isOpeningConversation = false
    @FocusState private var personFieldHasFocus: Bool
    @State private var hasLoaded = false

    var body: some View {
        VStack(spacing: 0) {
            if errorMessage == nil {
                newMessageBar
                Divider()
            }
            content
        }
        .task(id: accountDID) {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    @ViewBuilder
    private var newMessageBar: some View {
        if isWritingNew {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    TextField(tr("Name oder @Handle", "Name or @handle"), text: $personQuery)
                        .textFieldStyle(.roundedBorder)
                        .focused($personFieldHasFocus)
                        .onExitCommand(perform: closeNewMessage)
                    Button(tr("Abbrechen", "Cancel"), action: closeNewMessage)
                }
                PersonSuggestions(term: personQuery, excluding: accountDID, onPick: startConversation)
            }
            .padding(8)
            .onAppear { personFieldHasFocus = true }
        } else {
            Button {
                isWritingNew = true
            } label: {
                Label(tr("Neue Nachricht", "New Message"), systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .help(tr("Eine Person suchen und anschreiben", "Find a person and write to them"))
        }
    }

    private func closeNewMessage() {
        isWritingNew = false
        personQuery = ""
    }

    /// Opens the conversation. Nothing is sent until someone writes a message there.
    private func startConversation(with person: Profile) {
        guard !isOpeningConversation else { return }
        isOpeningConversation = true
        Task {
            defer { isOpeningConversation = false }
            guard let (conversation, _) = await deck.openConversation(with: person.did, accountDID: accountDID) else { return }
            closeNewMessage()
            onOpen(conversation)
        }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if let errorMessage, conversations.isEmpty {
                ContentUnavailableView {
                    Label(
                        lacksPermission
                            ? tr("Kein Zugriff auf Direktnachrichten", "No access to direct messages")
                            : tr("Direktnachrichten nicht geladen", "Direct messages not loaded"),
                        systemImage: "envelope.badge.shield.half.filled"
                    )
                } description: {
                    VStack(spacing: 10) {
                        if lacksPermission {
                            Text(tr(
                                "Dein App-Passwort braucht die Option „Allow access to your direct messages“. Erstelle ein neues damit und melde dich erneut an.",
                                "Your app password needs the option “Allow access to your direct messages”. Create a new one with it and sign in again."
                            ))
                        }
                        Text(errorMessage).font(.caption.monospaced()).textSelection(.enabled)
                    }
                } actions: {
                    Button(tr("Erneut versuchen", "Try Again")) { Task { await load() } }
                    if lacksPermission {
                        Button(tr("App-Passwörter öffnen", "Open App Passwords")) { openURL(DeckStore.appPasswordsURL) }
                    }
                }
            } else if conversations.isEmpty {
                if hasLoaded {
                    Text(tr("Noch keine Unterhaltungen", "No conversations yet")).foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(conversations) { conversation in
                            row(conversation)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ conversation: Conversation) -> some View {
        let others = conversation.others(excluding: accountDID)
        return Button {
            onOpen(conversation)
        } label: {
            HStack(spacing: 10) {
                Avatar(url: others.first?.avatarURL, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(others.map(\.bestName).joined(separator: ", "))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(conversation.lastMessage?.text ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                if let unread = conversation.unreadCount, unread > 0 {
                    Text(unread, format: .number)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        guard let client = deck.accounts.client(for: accountDID) else { return }
        do {
            conversations = try await client.conversations().conversations
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch let error as XRPCError {
            lacksPermission = error.isMissingChatPermission
            errorMessage = error.diagnostic
        } catch {
            lacksPermission = false
            errorMessage = error.localizedDescription
        }
        hasLoaded = true
    }
}

struct ConversationPanel: View {
    @Environment(DeckStore.self) private var deck
    let conversation: Conversation
    let accountDID: String
    let onBack: () -> Void

    @State private var messages: [ChatMessage] = []
    @State private var errorMessage: String?
    @State private var draft = ""
    @State private var isSending = false

    private var client: XRPCClient? { deck.accounts.client(for: accountDID) }
    private var title: String {
        conversation.others(excluding: accountDID).map(\.bestName).joined(separator: ", ")
    }
    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            ColumnPanelBar(title: title, onBack: onBack)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(messages) { bubble($0).id($0.id) }
                    }
                    .padding(10)
                }
                .onChange(of: messages.last?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.secondary).padding(4)
            }
            Divider()
            HStack(spacing: 6) {
                TextField(tr("Nachricht", "Message"), text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "paperplane.fill")
                }
                .disabled(trimmedDraft.isEmpty || isSending)
                .accessibilityLabel(tr("Senden", "Send"))
            }
            .padding(8)
        }
        .task(id: conversation.id) {
            var isFirstLoad = true
            while !Task.isCancelled {
                await load(markRead: isFirstLoad)
                isFirstLoad = false
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private func bubble(_ message: ChatMessage) -> some View {
        let isMine = message.sender.did == accountDID
        return HStack {
            if isMine { Spacer(minLength: 30) }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
                Text(message.text.map(RichText.linkifiedPlainText) ?? AttributedString(tr("Nachricht gelöscht", "Message deleted")))
                    .font(.callout)
                    .textSelection(.enabled)
                    .foregroundStyle(message.text == nil ? Color.secondary : (isMine ? Color.white : Color.primary))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        isMine ? Color.accentColor : Color(nsColor: .quaternaryLabelColor).opacity(0.5),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                Text(ATDate.age(of: message.date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !isMine { Spacer(minLength: 30) }
        }
    }

    private func load(markRead: Bool) async {
        guard let client else { return }
        do {
            messages = try await client.messages(conversation: conversation.id).messages.reversed()
            errorMessage = nil
            if markRead { try? await client.markConversationRead(conversation.id) }
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func send() {
        let text = trimmedDraft
        guard !text.isEmpty, !isSending, let client else { return }
        isSending = true
        Task {
            defer { isSending = false }
            do {
                let facets = await RichText.resolveMentions(in: RichText.detectFacets(in: text)) { handle in
                    try? await client.resolveHandle(handle)
                }
                let sent = try await client.send(message: text, facets: facets, conversation: conversation.id)
                messages.append(sent)
                draft = ""
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
