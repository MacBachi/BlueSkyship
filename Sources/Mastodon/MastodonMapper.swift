import Foundation

/// Mastodon identifiers inside the app. People are named by their full address, `name@server`,
/// which never looks like a Bluesky DID. Posts get a URI that names the server that was read,
/// because a Mastodon post id only means something on that server.
enum MastodonID {
    static let uriScheme = "mastodon"

    /// True for a Mastodon person or account, such as `anna@mastodon.social`.
    static func isActor(_ value: String?) -> Bool {
        guard let value, !value.hasPrefix("did:") else { return false }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".")
    }

    static func postURI(domain: String, statusID: String) -> String {
        "\(uriScheme)://\(domain)/statuses/\(statusID)"
    }

    static func isPostURI(_ uri: String) -> Bool {
        uri.hasPrefix("\(uriScheme)://")
    }

    /// The status id from a post URI, or nil for anything that is not one.
    static func statusID(fromURI uri: String) -> String? {
        guard isPostURI(uri), let id = uri.split(separator: "/").last,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return String(id)
    }
}

/// Converts Mastodon's answers into the app's own models.
struct MastodonMapper: Sendable {
    /// The server's own domain, which local account names leave out.
    let domain: String

    func acct(_ account: Mastodon.Account) -> String {
        MastodonHTML.fullAcct(account.acct, domain: domain)
    }

    func profile(_ account: Mastodon.Account) -> Profile {
        Profile(
            did: acct(account),
            handle: acct(account),
            displayName: account.display_name?.isEmpty == false ? account.display_name : account.username,
            avatar: account.avatar_static ?? account.avatar
        )
    }

    func profileDetail(_ account: Mastodon.Account, relationship: Mastodon.Relationship?) -> ProfileDetail {
        var detail = ProfileDetail(
            did: acct(account),
            handle: acct(account),
            displayName: account.display_name?.isEmpty == false ? account.display_name : account.username,
            description: account.note.map(MastodonHTML.plainText),
            avatar: account.avatar_static ?? account.avatar,
            banner: account.header_static ?? account.header,
            followersCount: account.followers_count,
            followsCount: account.following_count,
            postsCount: account.statuses_count
        )
        detail.externalURL = account.url
        detail.mastodonID = account.id
        if let relationship {
            detail.viewer = ProfileViewerState(
                following: relationship.following == true ? "following" : (relationship.requested == true ? "requested" : nil),
                followedBy: relationship.followed_by == true ? "followed" : nil,
                muted: relationship.muting,
                blocking: relationship.blocking == true ? "blocking" : nil
            )
        }
        return detail
    }

    /// Nil for a post the account's own filters say to hide.
    func feedItem(_ status: Mastodon.Status) -> FeedViewPost? {
        let shown = status.reblog ?? status
        guard let post = post(shown) else { return nil }
        var item = FeedViewPost(post: post)
        if status.reblog != nil {
            item.reason = FeedReason(by: profile(status.account))
        }
        if let parentAccount = shown.in_reply_to_account_id {
            let author = parentAccount == shown.account.id
                ? profile(shown.account)
                : (shown.mentions?.values.first { $0.id == parentAccount }).map {
                    Profile(did: MastodonHTML.fullAcct($0.acct, domain: domain), handle: MastodonHTML.fullAcct($0.acct, domain: domain))
                }
            item.reply = ReplyContext(parentAuthor: author)
        }
        return item
    }

    func post(_ status: Mastodon.Status) -> PostView? {
        let filter = status.filtered?.first
        if filter?.filter.filter_action == "hide" { return nil }

        let parsed = MastodonHTML.parse(
            status.content, mentions: status.mentions?.values ?? [], domain: domain, hidesQuoteFallback: status.quote != nil
        )
        var text = parsed.text
        if let poll = status.poll, !poll.options.isEmpty {
            let lines = poll.options.map { option in
                "◦ \(option.title)" + (option.votes_count.map { " (\($0))" } ?? "")
            }
            text += (text.isEmpty ? "" : "\n\n") + lines.joined(separator: "\n")
        }

        let parentRef = status.in_reply_to_id.map {
            StrongRef(uri: MastodonID.postURI(domain: domain, statusID: $0), cid: "")
        }
        let record = PostRecord(
            text: text,
            createdAt: status.created_at,
            facets: parsed.facets.isEmpty ? nil : parsed.facets,
            reply: parentRef.map { ReplyRef(root: $0, parent: $0) }
        )
        var post = PostView(
            uri: MastodonID.postURI(domain: domain, statusID: status.id),
            cid: "",
            author: profile(status.account),
            record: record,
            indexedAt: status.created_at,
            embed: embed(status),
            replyCount: status.replies_count,
            repostCount: status.reblogs_count,
            likeCount: status.favourites_count,
            quoteCount: status.quotes_count,
            viewer: PostViewer(
                like: status.favourited == true ? "favourited" : nil,
                repost: status.reblogged == true ? "reblogged" : nil,
                bookmarked: status.bookmarked
            )
        )
        post.mastodon = MastodonPostInfo(
            statusID: status.id,
            url: status.url,
            spoilerText: status.spoiler_text,
            sensitive: status.sensitive == true,
            visibility: status.visibility,
            filterTitle: filter?.filter.filter_action == "hide" ? nil : filter?.filter.title,
            authorID: status.account.id
        )
        return post
    }

    func embed(_ status: Mastodon.Status) -> Embed? {
        let media = mediaEmbed(status.media_attachments?.values ?? [])
        if let quote = status.quote {
            // Pending, rejected or deleted quotes name no post; the row then says so.
            var quoted: QuotedPost?
            if quote.state == nil || quote.state == "accepted", let inner = quote.quoted_status, let post = post(inner) {
                quoted = QuotedPost(
                    uri: post.uri, cid: "", author: post.author, value: post.record,
                    indexedAt: post.indexedAt, embeds: post.embed.map { [$0] }
                )
            }
            return media.map { .quoteWithMedia(quoted, media: $0) } ?? .quote(quoted)
        }
        if let media { return media }
        if let card = status.card {
            return .external(ExternalLink(uri: card.url, title: card.title, description: card.description, thumb: card.image))
        }
        return nil
    }

    /// Bluesky shows either pictures or one video, so a mixed Mastodon post shows its first video,
    /// or else all of its pictures.
    func mediaEmbed(_ attachments: [Mastodon.MediaAttachment]) -> Embed? {
        if let video = attachments.first(where: { $0.type == "video" || $0.type == "gifv" }),
           let url = video.url ?? video.remote_url {
            let size = video.meta?.original ?? video.meta?.small
            return .video(VideoEmbed(
                playlist: url,
                thumbnail: video.preview_url,
                alt: video.description,
                aspectRatio: ratio(size),
                presentation: video.type == "gifv" ? "gif" : nil
            ))
        }
        let images = attachments.filter { $0.type == "image" }.compactMap { image -> EmbedImage? in
            guard let full = image.url ?? image.remote_url else { return nil }
            return EmbedImage(
                thumb: image.preview_url ?? full,
                fullsize: full,
                alt: image.description,
                aspectRatio: ratio(image.meta?.small ?? image.meta?.original)
            )
        }
        if !images.isEmpty { return .images(images) }
        if let other = attachments.first, let url = other.url ?? other.remote_url {
            return .external(ExternalLink(
                uri: url,
                title: other.type == "audio" ? tr("Audio", "Audio") : tr("Anhang", "Attachment"),
                description: other.description,
                thumb: other.preview_url
            ))
        }
        return nil
    }

    private func ratio(_ size: Mastodon.MediaAttachment.Meta.Size?) -> AspectRatio? {
        guard let width = size?.width, let height = size?.height, width > 0, height > 0 else { return nil }
        return AspectRatio(width: width, height: height)
    }

    /// Mastodon's notification types in the words the app already uses for Bluesky.
    func notification(_ notification: Mastodon.Notification) -> NotificationItem {
        let reason: String
        switch notification.type {
        case "favourite": reason = "like"
        case "reblog": reason = "repost"
        case "follow": reason = "follow"
        case "follow_request": reason = "follow-request"
        case "quote": reason = "quote"
        case "mention": reason = notification.status?.in_reply_to_id == nil ? "mention" : "reply"
        default: reason = notification.type
        }
        let post = notification.status.flatMap { post($0) }
        let raw = RawNotification(
            uri: "\(MastodonID.uriScheme)://\(domain)/notifications/\(notification.id)",
            cid: "",
            author: profile(notification.account),
            reason: reason,
            reasonSubject: post?.uri,
            indexedAt: notification.created_at
        )
        return NotificationItem(raw: raw, post: post)
    }
}
