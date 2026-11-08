import Foundation

struct ContentLabel: Decodable, Hashable, Sendable {
    let val: String
    /// True when this entry takes a label back.
    var neg: Bool?
}

/// What the account has set in Bluesky: muted words and how to treat labeled content.
struct ModerationPrefs: Decodable, Equatable, Sendable {
    struct MutedWord: Decodable, Equatable, Sendable {
        let value: String
        let targets: [String]
        var actorTarget: String?
        var expiresAt: String?
    }

    enum Decision: Equatable {
        case show
        /// Only the pictures stay covered until asked for.
        case warn(String)
        case hide
    }

    var mutedWords: [MutedWord] = []
    var labelVisibility: [String: String] = [:]
    var adultContentEnabled = false

    /// Works without an account too: adult content stays hidden until someone opts in.
    init() {}

    private struct Preference: Decodable {
        let type: String
        var items: [MutedWord]?
        var label: String?
        var labelerDid: String?
        var visibility: String?
        var enabled: Bool?

        private enum CodingKeys: String, CodingKey {
            case type = "$type", items, label, labelerDid, visibility, enabled
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
            items = try? container.decodeIfPresent(LossyList<MutedWord>.self, forKey: .items)?.values
            label = try? container.decodeIfPresent(String.self, forKey: .label)
            labelerDid = try? container.decodeIfPresent(String.self, forKey: .labelerDid)
            visibility = try? container.decodeIfPresent(String.self, forKey: .visibility)
            enabled = try? container.decodeIfPresent(Bool.self, forKey: .enabled)
        }
    }

    private enum CodingKeys: String, CodingKey { case preferences }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let preferences = try container.decode(LossyList<Preference>.self, forKey: .preferences).values
        for preference in preferences {
            switch preference.type {
            case "app.bsky.actor.defs#mutedWordsPref":
                mutedWords += preference.items ?? []
            case "app.bsky.actor.defs#adultContentPref":
                adultContentEnabled = preference.enabled ?? false
            case "app.bsky.actor.defs#contentLabelPref":
                // Settings for a single labeler service do not apply to the general labels handled here.
                if preference.labelerDid == nil, let label = preference.label, let visibility = preference.visibility {
                    labelVisibility[label] = visibility
                }
            default:
                break
            }
        }
    }

    private static let adultLabels: Set<String> = ["porn", "sexual", "nudity"]
    private static let defaultVisibility = ["porn": "warn", "sexual": "warn", "nudity": "show", "graphic-media": "warn"]

    private func decision(forLabel label: String) -> Decision {
        switch label {
        case "!hide": return .hide
        case "!warn": return .warn(label)
        default: break
        }
        if Self.adultLabels.contains(label), !adultContentEnabled { return .hide }
        let visibility = labelVisibility[label] ?? Self.defaultVisibility[label] ?? "show"
        switch visibility {
        case "hide": return .hide
        case "warn": return .warn(label)
        default: return .show
        }
    }

    private func mutedWordFilter(authorFollowed: Bool, now: Date) -> ColumnFilter? {
        let active = mutedWords.filter { word in
            if word.actorTarget == "exclude-following", authorFollowed { return false }
            if let expiry = word.expiresAt.flatMap(ATDate.parse), expiry <= now { return false }
            return true
        }
        var terms: [String] = []
        for word in active {
            // A word muted for content also catches its hashtag, and a tag-only word only the hashtag.
            let bare = word.value.hasPrefix("#") ? String(word.value.dropFirst()) : word.value
            if word.targets.contains("content") { terms.append(bare) }
            terms.append("#\(bare)")
        }
        return terms.isEmpty ? nil : ColumnFilter(excludeTerms: terms)
    }

    func decision(for post: PostView, isOwn: Bool, now: Date = Date()) -> Decision {
        if isOwn { return .show }
        if let filter = mutedWordFilter(authorFollowed: post.author.viewer?.following != nil, now: now),
           filter.apply([.post(FeedViewPost(post: post))]).isEmpty {
            return .hide
        }
        let removed = Set((post.labels ?? []).filter { $0.neg == true }.map(\.val))
        var result = Decision.show
        for label in (post.labels ?? []) where label.neg != true && !removed.contains(label.val) {
            switch decision(forLabel: label.val) {
            case .hide: return .hide
            case .warn(let name): result = .warn(name)
            case .show: break
            }
        }
        return result
    }
}

extension XRPCClient {
    func moderationPrefs() async throws -> ModerationPrefs {
        try await get("app.bsky.actor.getPreferences")
    }
}

/// Who may answer a new thread, stored as a separate record next to its first post.
enum ReplyRule: String, CaseIterable, Sendable {
    case everyone, mentioned, followers, following, nobody

    var label: String {
        switch self {
        case .everyone: return tr("Alle dürfen antworten", "Everyone can reply")
        case .mentioned: return tr("Nur Erwähnte", "Only mentioned people")
        case .followers: return tr("Nur meine Follower", "Only my followers")
        case .following: return tr("Nur Leute, denen ich folge", "Only people I follow")
        case .nobody: return tr("Niemand", "Nobody")
        }
    }

    /// `nil` means no restriction, so no record at all.
    var allowTypes: [String]? {
        switch self {
        case .everyone: return nil
        case .nobody: return []
        case .mentioned: return ["app.bsky.feed.threadgate#mentionRule"]
        case .followers: return ["app.bsky.feed.threadgate#followerRule"]
        case .following: return ["app.bsky.feed.threadgate#followingRule"]
        }
    }
}

extension XRPCClient {
    func setReplyRule(_ rule: ReplyRule, post uri: String, repo: String) async throws {
        guard let types = rule.allowTypes, let rkey = uri.split(separator: "/").last.map(String.init) else { return }
        struct Allow: Encodable, Sendable {
            let type: String
            private enum CodingKeys: String, CodingKey { case type = "$type" }
        }
        struct Record: Encodable, Sendable {
            let type = "app.bsky.feed.threadgate"
            let post: String
            let allow: [Allow]
            let createdAt: String
            private enum CodingKeys: String, CodingKey {
                case type = "$type", post, allow, createdAt
            }
        }
        struct Body: Encodable, Sendable {
            let repo: String
            let collection = "app.bsky.feed.threadgate"
            // The record must carry the same key as the post it restricts.
            let rkey: String
            let record: Record
        }
        try await postIgnoringResponse("com.atproto.repo.createRecord", body: Body(
            repo: repo, rkey: rkey,
            record: Record(post: uri, allow: types.map(Allow.init), createdAt: ATDate.string())
        ))
    }

    // MARK: People

    func followers(of actor: String, cursor: String?) async throws -> (people: [Profile], cursor: String?) {
        struct Response: Decodable, Sendable {
            let followers: LossyList<Profile>
            let cursor: String?
        }
        let response: Response = try await get("app.bsky.graph.getFollowers", query: [
            ("actor", actor), ("limit", "50"), ("cursor", cursor),
        ])
        return (response.followers.values, response.cursor)
    }

    func follows(of actor: String, cursor: String?) async throws -> (people: [Profile], cursor: String?) {
        struct Response: Decodable, Sendable {
            let follows: LossyList<Profile>
            let cursor: String?
        }
        let response: Response = try await get("app.bsky.graph.getFollows", query: [
            ("actor", actor), ("limit", "50"), ("cursor", cursor),
        ])
        return (response.follows.values, response.cursor)
    }

    func suggestPeople(matching term: String) async throws -> [Profile] {
        struct Response: Decodable, Sendable { let actors: LossyList<Profile> }
        let response: Response = try await get("app.bsky.actor.searchActorsTypeahead", query: [
            ("q", term), ("limit", "6"),
        ])
        return response.actors.values
    }

    /// Finds the conversation with this person, or creates it if there is none yet.
    func conversation(with did: String) async throws -> Conversation {
        struct Response: Decodable, Sendable { let convo: Conversation }
        let response: Response = try await get("chat.bsky.convo.getConvoForMembers", query: [("members", did)])
        return response.convo
    }

    func send(message text: String, facets: [Facet], conversation id: String) async throws -> ChatMessage {
        struct Input: Encodable, Sendable {
            let text: String
            let facets: [Facet]?
        }
        struct Body: Encodable, Sendable {
            let convoId: String
            let message: Input
        }
        return try await post("chat.bsky.convo.sendMessage", body: Body(
            convoId: id, message: Input(text: text, facets: facets.isEmpty ? nil : facets)
        ))
    }
}

// MARK: - Video

struct VideoDraft: Sendable {
    let data: Data
    let width: Int
    let height: Int
    var alt: String
}

struct VideoUploadError: LocalizedError {
    let reason: String
    var errorDescription: String? { tr("Video-Upload fehlgeschlagen: \(reason)", "Video upload failed: \(reason)") }
}

extension XRPCClient {
    static let videoService = URL(string: "https://video.bsky.app")!

    private struct VideoJob: Decodable, Sendable {
        let jobId: String
        let state: String
        var blob: BlobRef?
        var error: String?
        var message: String?
    }

    private struct VideoJobEnvelope: Decodable, Sendable {
        let job: VideoJob

        private enum CodingKeys: String, CodingKey { case jobStatus }

        init(from decoder: any Decoder) throws {
            // Depending on the path the status comes wrapped or directly.
            if let container = try? decoder.container(keyedBy: CodingKeys.self),
               let wrapped = try? container.decode(VideoJob.self, forKey: .jobStatus) {
                job = wrapped
            } else {
                job = try VideoJob(from: decoder)
            }
        }
    }

    /// The video service checks and converts the file, then hands back a blob for the post.
    /// It accepts a short-lived token that the account's own server issues for this one purpose.
    func uploadVideo(_ video: VideoDraft, repo: String, videoService: URL = XRPCClient.videoService, pollInterval: Duration = .seconds(2)) async throws -> BlobRef {
        struct RepoInfo: Decodable, Sendable {
            struct DidDoc: Decodable, Sendable {
                struct Service: Decodable, Sendable {
                    let id: String
                    let serviceEndpoint: String
                }
                let service: [Service]
            }
            let didDoc: DidDoc
        }
        struct ServiceAuth: Decodable, Sendable { let token: String }

        let info: RepoInfo = try await get("com.atproto.repo.describeRepo", query: [("repo", repo)])
        guard let endpoint = info.didDoc.service.first(where: { $0.id.hasSuffix("#atproto_pds") })?.serviceEndpoint,
              let host = URL(string: endpoint)?.host else {
            throw VideoUploadError(reason: tr("Server des Kontos nicht gefunden.", "Account server not found."))
        }
        let expires = Int(Date().addingTimeInterval(30 * 60).timeIntervalSince1970)
        let auth: ServiceAuth = try await get("com.atproto.server.getServiceAuth", query: [
            ("aud", "did:web:\(host)"), ("lxm", "com.atproto.repo.uploadBlob"), ("exp", String(expires)),
        ])

        let uploadURL = try Self.url(service: videoService, nsid: "app.bsky.video.uploadVideo", query: [
            ("did", repo), ("name", "\(UUID().uuidString).mp4"),
        ])
        let (uploadData, status) = try await rawRequest(
            url: uploadURL, method: "POST", body: video.data,
            headers: ["Authorization": "Bearer \(auth.token)", "Content-Type": "video/mp4"]
        )
        // 409 means this exact file is already known; the answer still names its job.
        guard (200..<300).contains(status) || status == 409,
              var job = try? JSONDecoder().decode(VideoJobEnvelope.self, from: uploadData).job else {
            throw VideoUploadError(reason: String(decoding: uploadData.prefix(200), as: UTF8.self))
        }

        // Five minutes at the usual interval; the service converts while this waits.
        for _ in 0..<150 {
            if let blob = job.blob, job.state == "JOB_STATE_COMPLETED" { return blob }
            if job.state == "JOB_STATE_FAILED" {
                throw VideoUploadError(reason: job.message ?? job.error ?? tr("Unbekannter Fehler.", "Unknown error."))
            }
            try await Task.sleep(for: pollInterval)
            let statusURL = try Self.url(service: videoService, nsid: "app.bsky.video.getJobStatus", query: [("jobId", job.jobId)])
            let (data, _) = try await rawRequest(url: statusURL, method: "GET", body: nil, headers: [:])
            if let update = try? JSONDecoder().decode(VideoJobEnvelope.self, from: data).job { job = update }
        }
        throw VideoUploadError(reason: tr("Zeitüberschreitung.", "Timed out."))
    }
}
