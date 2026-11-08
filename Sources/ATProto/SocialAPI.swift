import Foundation

// Moderation, bookmarks, notifications and chat. Field names follow the official atproto lexicons.

struct Conversation: Decodable, Hashable, Identifiable, Sendable {
    struct LastMessage: Decodable, Hashable, Sendable {
        var text: String?
    }

    let id: String
    let members: [Profile]
    var unreadCount: Int?
    var lastMessage: LastMessage?

    private enum CodingKeys: String, CodingKey { case id, members, unreadCount, lastMessage }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        members = try container.decode([Profile].self, forKey: .members)
        unreadCount = try? container.decodeIfPresent(Int.self, forKey: .unreadCount)
        // A union: the preview may be a deleted message or something else without text.
        lastMessage = try? container.decodeIfPresent(LastMessage.self, forKey: .lastMessage)
    }

    /// Everyone except the viewer, for titles and pictures.
    func others(excluding did: String) -> [Profile] {
        let others = members.filter { $0.did != did }
        return others.isEmpty ? members : others
    }
}

struct ChatMessage: Decodable, Hashable, Identifiable, Sendable {
    struct Sender: Decodable, Hashable, Sendable {
        let did: String
    }

    let id: String
    /// Missing on a deleted message.
    var text: String?
    let sender: Sender
    let sentAt: String

    var date: Date? { ATDate.parse(sentAt) }
}

extension XRPCClient {
    private struct ActorBody: Encodable, Sendable { let actor: String }

    // MARK: Moderation

    func mute(actor: String) async throws {
        try await postIgnoringResponse("app.bsky.graph.muteActor", body: ActorBody(actor: actor))
    }

    func unmute(actor: String) async throws {
        try await postIgnoringResponse("app.bsky.graph.unmuteActor", body: ActorBody(actor: actor))
    }

    /// Blocks an account and returns the block record's URI. Undo it with `deleteRecord`.
    func block(did: String, repo: String) async throws -> String {
        struct Record: Encodable, Sendable {
            let type = "app.bsky.graph.block"
            let subject: String
            let createdAt: String
            private enum CodingKeys: String, CodingKey {
                case type = "$type", subject, createdAt
            }
        }
        let created: CreatedRecord = try await post(
            "com.atproto.repo.createRecord",
            body: CreateRecord(
                repo: repo, collection: "app.bsky.graph.block",
                record: Record(subject: did, createdAt: ATDate.string())
            )
        )
        return created.uri
    }

    // MARK: Bookmarks

    func addBookmark(_ ref: StrongRef) async throws {
        try await postIgnoringResponse("app.bsky.bookmark.createBookmark", body: ref)
    }

    func removeBookmark(uri: String) async throws {
        struct Body: Encodable, Sendable { let uri: String }
        try await postIgnoringResponse("app.bsky.bookmark.deleteBookmark", body: Body(uri: uri))
    }

    func bookmarksPage(cursor: String?, limit: String) async throws -> FeedPage {
        struct Bookmark: Decodable, Sendable { let item: PostView }
        struct Response: Decodable, Sendable {
            // A bookmarked post may be deleted or blocked by now; those entries drop out.
            let bookmarks: LossyList<Bookmark>
            let cursor: String?
        }
        let response: Response = try await get(
            "app.bsky.bookmark.getBookmarks", query: [("limit", limit), ("cursor", cursor)]
        )
        return FeedPage(
            items: response.bookmarks.values.map { .post(FeedViewPost(post: $0.item)) },
            cursor: response.cursor
        )
    }

    // MARK: Notifications

    func unreadNotificationCount() async throws -> Int {
        struct Response: Decodable, Sendable { let count: Int }
        let response: Response = try await get("app.bsky.notification.getUnreadCount")
        return response.count
    }

    /// Clears the unread state on the account, so it also applies in other Bluesky apps.
    func markNotificationsSeen(at date: Date = Date()) async throws {
        struct Body: Encodable, Sendable { let seenAt: String }
        try await postIgnoringResponse(
            "app.bsky.notification.updateSeen", body: Body(seenAt: ATDate.string(date))
        )
    }

    func latestNotifications(limit: Int) async throws -> [RawNotification] {
        struct Response: Decodable, Sendable { let notifications: LossyList<RawNotification> }
        let response: Response = try await get(
            "app.bsky.notification.listNotifications", query: [("limit", String(limit))]
        )
        return response.notifications.values
    }

    // MARK: Chat

    func conversations(cursor: String? = nil) async throws -> (conversations: [Conversation], cursor: String?) {
        struct Response: Decodable, Sendable {
            let convos: LossyList<Conversation>
            let cursor: String?
        }
        let response: Response = try await get(
            "chat.bsky.convo.listConvos", query: [("limit", "50"), ("cursor", cursor)]
        )
        // Showing "no conversations" here would be false.
        if response.convos.values.isEmpty, response.convos.skipped > 0 {
            throw XRPCError(
                status: 200, code: "UnreadableConversations",
                message: tr("\(response.convos.skipped) Unterhaltungen konnten nicht gelesen werden.", "Could not read \(response.convos.skipped) conversations.")
            )
        }
        return (response.convos.values, response.cursor)
    }

    /// The server sends the newest message first.
    func messages(conversation id: String, cursor: String? = nil) async throws -> (messages: [ChatMessage], cursor: String?) {
        struct Response: Decodable, Sendable {
            let messages: LossyList<ChatMessage>
            let cursor: String?
        }
        let response: Response = try await get(
            "chat.bsky.convo.getMessages", query: [("convoId", id), ("limit", "50"), ("cursor", cursor)]
        )
        return (response.messages.values, response.cursor)
    }

    func send(message text: String, conversation id: String) async throws -> ChatMessage {
        struct Input: Encodable, Sendable { let text: String }
        struct Body: Encodable, Sendable {
            let convoId: String
            let message: Input
        }
        return try await post(
            "chat.bsky.convo.sendMessage", body: Body(convoId: id, message: Input(text: text))
        )
    }

    func markConversationRead(_ id: String) async throws {
        struct Body: Encodable, Sendable { let convoId: String }
        try await postIgnoringResponse("chat.bsky.convo.updateRead", body: Body(convoId: id))
    }
}

/// The result of sending a thread. Posts already sent stay sent, so a failure must say how far it got.
struct ThreadResult: Sendable {
    var sent = 0
    /// Where a remaining part of the thread would have to attach.
    var continuation: ReplyRef?
    var error: (any Error)?
    /// The posts went out, but limiting replies failed. They are open to everyone until fixed.
    var replyRuleFailed = false
}

extension XRPCClient {
    /// Sends the texts as a chain of replies. A quote and a video belong to the first post;
    /// `laterImages` holds the pictures of the following posts by position.
    func createThread(
        texts: [String],
        first: PostDraft,
        laterImages: [Int: [DraftImage]] = [:],
        replyRule: ReplyRule = .everyone,
        repo: String
    ) async -> ThreadResult {
        var result = ThreadResult(continuation: first.reply)
        for text in texts {
            var draft = PostDraft(text: text, langs: first.langs, reply: result.continuation)
            if result.sent == 0 {
                draft.quote = first.quote
                draft.images = first.images
                draft.video = first.video
            } else {
                draft.images = laterImages[result.sent] ?? []
            }
            do {
                let ref = try await createPost(draft, repo: repo)
                if result.sent == 0, first.reply == nil, replyRule != .everyone {
                    do {
                        try await setReplyRule(replyRule, post: ref.uri, repo: repo)
                    } catch {
                        result.replyRuleFailed = true
                    }
                }
                result.continuation = ReplyRef(root: result.continuation?.root ?? ref, parent: ref)
                result.sent += 1
            } catch {
                result.error = error
                return result
            }
        }
        return result
    }
}
