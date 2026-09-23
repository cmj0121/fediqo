import FediqoCore
import Foundation
import Observation

/// What an opened blog has to say where its words go — #209, as a value the pane is drawn from.
///
/// **Four states, and the words are not one of them.** A blog read is kept with its row, and the
/// row draws the words it carries as any post's (`DummyItem.body`); what is left for the pane to
/// say is what a row cannot: that its page is being read, that it was read and held no words, or
/// why it could not be.
enum ForumBlogReading: Equatable, Sendable {
    /// Its page is being read, or is about to be — the pane opening asks.
    case coming
    /// Read, and kept: the row carries the words, and there is nothing to add to them.
    case read
    /// Read, and there were no words on it — a blog that is a picture. `ForumReading.silent`.
    case silent
    /// It could not be read, and why — `ForumPosts.Absence`'s four, for the reasons it gives.
    case absent(ForumPosts.Absence)

    /// Whether the forum's own page is what is left to offer: a blog this device holds no words
    /// of and could not read.
    var offersPage: Bool {
        if case .absent = self { return true }
        return false
    }
}

/// The ranked blogs read in the app rather than as their page (#209): **one page each, read when
/// the reader opens it, and kept with its row.**
///
/// **Only when opened.** A blog's row is what the forum's ranking list wrote of it and nothing
/// more: reaching it in Trends reads nothing — the points guard's rule for a ranked thread from a
/// board the reader does not read, and a blog is in no board at all. Opening it is the reader's
/// choice, and that is the one read (`open`), with `r` in its pane asking again (`again`).
///
/// **Kept, then drawn from what is kept.** What its page says lands on its row (`landing`) as a
/// thread's opening post does (#154) — so the pane draws the row, the row draws what this device
/// holds, and a blog read once still reads with the network off, a relaunch later. What is held
/// here is what is on the wire, why the last read came to nothing, and that a read landed — so
/// the pane never says it is reading while it waits for the row to be drawn again. The words
/// are the row's, and it is the row that draws them.
///
/// **Through the forum's sign-in, where it has one**, for `ForumPosts.client`'s reason: a blog a
/// signed-in reader may read comes back as the forum's notice if it is read around their cookies.
@MainActor
@Observable
final class ForumBlogs {
    /// Why the last read of each blog came to nothing, by row. Gone when a read lands.
    private(set) var missing: [NoteKey: ForumPosts.Absence] = [:]

    /// The read on the wire for each blog, so a pane opened twice waits on one page.
    private(set) var inFlight: [NoteKey: Task<Void, Never>] = [:]

    /// What each blog read this run brought, by row — **only so the pane never waits on a read
    /// that has already landed.** The words are the row's; this is what the pane says in the
    /// moment between a read landing and the row it opened on being drawn again with them.
    private(set) var landed: [NoteKey: ForumOpening] = [:]

    /// Where what a read brought is kept with its row — the session's store. Set by the session;
    /// nothing where there is none, which is a test's.
    @ObservationIgnored var landing: (@MainActor (NoteKey, DiscuzBlog) async -> Void)?

    /// Where each read is shown while it is on the wire (#164). The app's own; a test hands in
    /// another.
    @ObservationIgnored var work: SourceWork = .shared

    @ObservationIgnored private let http: any HTTPClient
    @ObservationIgnored private let forums: ForumSessions?
    /// Blogs whose forum was cleared while their page was on the wire. See `forget(host:)`.
    @ObservationIgnored private var cleared: Set<NoteKey> = []

    /// `ForumPosts.live`'s transport, with its ceiling: a blog page is a forum page.
    init(http: any HTTPClient = ForumPosts.live, through forums: ForumSessions? = nil) {
        self.http = http
        self.forums = forums
    }

    /// What the opened blog's pane says where its words go. Nothing for a row that is not a blog.
    func reading(of item: DummyItem) -> ForumBlogReading? {
        guard DiscuzBlogRow.isBlog(item.noteID) else { return nil }
        let key = Self.key(of: item)
        // A read on the wire is said first, so `r` over kept words shows that it took.
        if inFlight[key] != nil { return .coming }
        // What the row carries, or what landed for it where the row drawn is older than that.
        if let kept = item.opening ?? landed[key] { return kept.words.isEmpty ? .silent : .read }
        if let absence = missing[key] { return .absent(absence) }
        return .coming
    }

    /// The blog's pane opening: its page read, **unless this device already holds what it said**
    /// — a blog read once opens from what is kept, the network on or off.
    func open(_ item: DummyItem) async {
        guard item.opening == nil, landed[Self.key(of: item)] == nil else { return }
        await read(item)
    }

    /// `r` in the blog's pane, or its way in pressed after a read that did not arrive: its page
    /// read again whatever is kept. What is kept stays drawn until the answer replaces it, and a
    /// read that comes to nothing leaves it drawn.
    ///
    /// Returns whether it came back.
    @discardableResult
    func again(_ item: DummyItem) async -> Bool {
        await read(item)
        return missing[Self.key(of: item)] == nil
    }

    /// Everything this run holds of one forum's blogs let go — a Clear. A read on the wire lands
    /// nothing afterwards, `ForumPosts.forget(host:)`'s guard.
    func forget(host raw: String) {
        let host = raw.lowercased()
        for key in Array(inFlight.keys) where key.host == host { cleared.insert(key) }
        for key in Array(missing.keys) where key.host == host { missing.removeValue(forKey: key) }
        for key in Array(landed.keys) where key.host == host { landed.removeValue(forKey: key) }
    }

    private func read(_ item: DummyItem) async {
        let key = Self.key(of: item)
        if let running = inFlight[key] {
            await running.value
            return
        }
        guard let address = DiscuzBlogRow.address(noteID: item.noteID, url: item.url) else {
            // A blog's row always names its page; one that does not is not a page to ask for.
            missing[key] = .unreadable
            return
        }
        let task = Task { @MainActor in
            defer {
                self.inFlight[key] = nil
                self.cleared.remove(key)
            }
            // A forum still signing in is waited for, and the reader chosen after — `ForumPosts`'
            // order, so a blog is not read as a guest a moment before the sign-in lands.
            if let forums = self.forums { await forums.settled(host: key.host) }
            let transport = WatchedHTTP(
                self.forums?.readTransport(host: key.host, else: self.http) ?? self.http,
                for: .forumPost, in: self.work
            )
            let answer: Result<DiscuzBlog, ForumPosts.Absence>
            do {
                answer = .success(try await DiscuzClient(http: transport, host: key.host)
                    .blog(uid: address.uid, id: address.id))
            } catch {
                answer = .failure(ForumPosts.absence(for: error))
            }
            guard !self.cleared.contains(key) else { return }
            switch answer {
            case .success(let blog):
                await self.landing?(key, blog)
                guard !self.cleared.contains(key) else { return }
                self.landed[key] = blog.opening
                self.missing.removeValue(forKey: key)
            case .failure(let absence):
                self.missing[key] = absence
            }
        }
        inFlight[key] = task
        await task.value
    }

    private static func key(of item: DummyItem) -> NoteKey {
        NoteKey(host: item.source.host, id: item.noteID)
    }
}
