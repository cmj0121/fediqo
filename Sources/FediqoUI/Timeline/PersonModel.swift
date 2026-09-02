import Foundation
import Observation
import FediqoCore

/// Somebody the reader has opened, as much of them as is known before anybody is asked.
///
/// A row already holds a name, a handle, a picture and the server that handed the post over, so
/// the page opens drawn rather than empty and fills in. Carried as a value because that is all
/// it is: which person, and which server to ask about them.
struct PersonSubject: Hashable, Identifiable {
    /// `@somebody@their.server` — what every request about them takes.
    let handle: String
    /// The server that handed one of their posts over. Not their own: a page about somebody is
    /// no reason to introduce their home server to a new visitor (#88).
    let host: String
    let authorId: String
    let name: String
    let avatarURL: URL?
    /// The custom emoji that name is partly written in.
    ///
    /// Carried because the name is. A page that took the words from the row and the pictures
    /// from a profile that has not arrived draws `Tove :spark: Rasmussen` for as long as the
    /// request is out — which is #39's whole complaint, reintroduced by a page that thought it
    /// only needed the words.
    let emojis: [CustomEmoji]

    var id: String { "\(host)|\(handle)" }

    init(post: Post) {
        self.handle = post.authorHandle
        self.host = URL(string: post.sourceURL)?.host() ?? ""
        self.authorId = post.authorId
        self.name = post.authorName
        self.avatarURL = post.authorAvatarURL
        self.emojis = post.emojis
    }
}

/// The two questions a page about somebody asks, kept apart because they go to two servers and
/// either can fail without the other.
///
/// **Who they are and what they wrote** is asked of `subject.host` — a server the reader added.
/// **What the reader is to them** is asked of the account `acting` chose, which is the only place
/// a relationship exists. A reader signed in nowhere has no answer to the second and every answer
/// to the first, and the page says so rather than refusing to open.
@MainActor
@Observable
final class PersonModel {
    let subject: PersonSubject

    private(set) var profile: Profile?
    private(set) var posts: [Post] = []
    /// What the reader is to them, or `nil` for two different reasons the page must keep apart:
    /// nobody is signed in anywhere, or the acting server has never heard of them. `known` says
    /// which.
    private(set) var relationship: Relationship?
    private(set) var known = false

    private(set) var loading = false
    /// A press that is still out. The control says so and goes on saying what it currently is —
    /// a follow that has not landed has not happened.
    private(set) var following = false
    private(set) var failure: SourceFailure?

    private let client: any SourceClient
    private let acting: () async -> ActingAccount?
    /// Told when a follow has landed, so that home stops being answered by what it said before
    /// there was anybody to read. Nothing on an unfollow that failed and nothing on a read.
    private let changed: () async -> Void
    private var hasRead = false

    init(subject: PersonSubject, client: any SourceClient,
         acting: @escaping () async -> ActingAccount?,
         changed: @escaping () async -> Void = {}) {
        self.subject = subject
        self.client = client
        self.acting = acting
        self.changed = changed
    }

    /// Everything the page needs, once per opening. Asked when the page appears, and a second
    /// appearance — coming back to it from a post opened out of it — asks nobody again.
    func read() async {
        guard !hasRead else { return }
        hasRead = true
        loading = true
        defer { loading = false }

        do {
            profile = try await client.profile(handle: subject.handle, host: subject.host, token: nil)
            if let profile {
                posts = try await client.posts(by: profile.id, host: subject.host,
                                               limit: 20, before: nil, token: nil)
            }
        } catch {
            failure = SourceFailure.of(error)
        }
        await readRelationship()
    }

    /// What the reader is to them, asked of their own server and of nothing else.
    ///
    /// A failure here is not the page's failure: the profile is still true and still on screen.
    /// It leaves the relationship unknown, which is what the control draws when it cannot say.
    func readRelationship() async {
        guard let account = await acting() else {
            known = false
            relationship = nil
            return
        }
        do {
            relationship = try await client.relationship(with: subject.handle, as: account)
            known = relationship != nil
        } catch {
            known = false
            relationship = nil
        }
    }

    /// Follow, or stop.
    ///
    /// **Nothing is moved before the server answers**, unlike a star. A star is a mark on a post
    /// and the reader is the authority on it; whether somebody has accepted a follower is that
    /// somebody's answer, and a control that showed "following" on the press would be announcing
    /// an approval nobody has given. A locked account is exactly the case that would be lied
    /// about, and it is not a rare one.
    func setFollow(_ wanted: Bool) async {
        guard let account = await acting() else {
            failure = .needsSignIn(subject.host)
            return
        }
        guard !following else { return }
        following = true
        defer { following = false }
        do {
            relationship = try await client.setFollow(wanted, with: subject.handle, as: account)
            known = true
            // Both ways round: following somebody puts their posts into home and unfollowing
            // takes them out, and a home still holding somebody the reader has just let go is
            // as wrong as one that never gained them.
            await changed()
        } catch {
            failure = SourceFailure.of(error)
        }
    }

    /// The name to draw: what the server said, and what the row already knew until it answers.
    var name: String { profile?.name ?? subject.name }
    var handle: String { profile?.handle ?? subject.handle }
    var avatarURL: URL? { profile?.avatarURL ?? subject.avatarURL }
    /// The pictures the name is written in, from whichever of the two answered. A profile that
    /// arrived carrying none of its own is a server that sent none, so the row's are not kept
    /// alongside — it is one answer or the other, the way the name itself is.
    var emojis: [CustomEmoji] { profile.map(\.emojis) ?? subject.emojis }

    /// Whether the acting server has an answer about this person at all. `false` covers both
    /// "nobody is signed in" and "the server has never heard of them" — the control offers to
    /// follow in either case, and following is what resolves the second.
    var hasRelationship: Bool { known && relationship != nil }
}
