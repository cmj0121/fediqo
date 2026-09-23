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
    /// It could not be read, and why — `ForumPosts.Absence`'s, the forum's own reason among them
    /// (#213).
    case absent(ForumPosts.Absence)
    /// Behind its author's password, and where the reader's typing of it stands (#213).
    case locked(ForumLock)

    /// Whether the forum's own page is what is left to offer: a blog this device holds no words
    /// of and could not read, where its page could show it — `ForumRefusalView.actions(for:)`.
    var offersPage: Bool {
        if case .absent(let absence) = self { return ForumRefusalView.actions(for: absence).contains(.page) }
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
///
/// **A refusal a sign-in could change is read again when one lands** (#213) — `ForumPosts`' rule
/// (#153) — so a blog that said "sign in" reads once the reader has.
///
/// **A password is used once and kept nowhere** (#213). `unlock` hands it to the forum's
/// signed-in browser (`unlocking`), reads the blog again, and lets go of the cookie the forum
/// answered a right one with (`forgetting`); it is a parameter and never a property, so nothing
/// this holds, lands or logs has it in it.
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

    /// Where each password blog's typing stands, by row, while the reader is at it (#213).
    private(set) var locks: [NoteKey: ForumLock] = [:]

    /// Where a password goes: the forum's signed-in browser, which types it into the blog page's
    /// own form (`ForumSessions.sendBlogPassword`). Set from the forum's sessions; a test hands in
    /// another. Throws `NotSignedIn` where the forum has no sign-in to send it through.
    @ObservationIgnored var unlocking: (@MainActor (_ host: String, _ page: URL, _ password: String) async throws -> Void)?

    /// Where what a right password left behind is let go of once the blog is read.
    @ObservationIgnored var forgetting: (@MainActor (_ host: String, _ blog: Int) async -> Void)?

    /// A password asked to be sent to a forum with no sign-in to send it through.
    struct NotSignedIn: Error {}

    /// The rows whose last read came to a refusal a sign-in could change, kept so the read can be
    /// asked again when one lands.
    @ObservationIgnored private var refusedAsGuest: [NoteKey: DummyItem] = [:]

    @ObservationIgnored private let http: any HTTPClient
    @ObservationIgnored private let forums: ForumSessions?
    /// Blogs whose forum was cleared while their page was on the wire. See `forget(host:)`.
    @ObservationIgnored private var cleared: Set<NoteKey> = []

    /// `ForumPosts.live`'s transport, with its ceiling: a blog page is a forum page.
    init(http: any HTTPClient = ForumPosts.live, through forums: ForumSessions? = nil) {
        self.http = http
        self.forums = forums
        guard let forums else { return }
        // Weak: `forums` outlives this and holds the listener, and this holds `forums`.
        forums.whenSignedIn { [weak self] host in self?.signedIn(host: host) }
        unlocking = { [weak forums] host, page, password in
            guard let forums else { throw NotSignedIn() }
            try await forums.sendBlogPassword(password, host: host, page: page)
        }
        forgetting = { [weak forums] host, blog in await forums?.forgetBlogPassword(host: host, blog: blog) }
    }

    /// What the opened blog's pane says where its words go. Nothing for a row that is not a blog.
    func reading(of item: DummyItem) -> ForumBlogReading? {
        guard DiscuzBlogRow.isBlog(item.noteID) else { return nil }
        let key = Self.key(of: item)
        // A password on its way is said as the lock's, so the form stays where the reader is.
        if locks[key] == .trying { return .locked(.trying) }
        // A read on the wire is said first, so `r` over kept words shows that it took.
        if inFlight[key] != nil { return .coming }
        // What the row carries, or what landed for it where the row drawn is older than that.
        if let kept = item.opening ?? landed[key] { return kept.words.isEmpty ? .silent : .read }
        if missing[key] == .refusal(.password) { return .locked(locks[key] ?? .asking) }
        if let absence = missing[key] { return .absent(absence) }
        return .coming
    }

    /// The author's password, typed by the reader, sent to that forum once and the blog read
    /// again (#213). **Nothing of it is kept**: it goes to `unlocking` and nowhere else, the cookie
    /// a right one earns is let go of once the blog is read, and what lands is the blog, kept as
    /// any read blog is.
    ///
    /// A forum with no sign-in to send it through is told to sign in first; a wrong password
    /// leaves the form up, saying so. Returns whether the blog read.
    @discardableResult
    func unlock(_ item: DummyItem, password: String) async -> Bool {
        let key = Self.key(of: item)
        guard locks[key] != .trying, !password.isEmpty,
              let address = DiscuzBlogRow.address(noteID: item.noteID, url: item.url),
              let page = DiscuzBlogRow.page(host: key.host, uid: address.uid, id: address.id)
        else { return false }
        guard let unlocking else {
            missing[key] = .refusal(.signIn)
            refusedAsGuest[key] = item
            return false
        }
        locks[key] = .trying
        do {
            try await unlocking(key.host, page, password)
        } catch is NotSignedIn {
            locks[key] = nil
            missing[key] = .refusal(.signIn)
            refusedAsGuest[key] = item
            return false
        } catch {
            locks[key] = nil
            missing[key] = ForumPosts.absence(for: error)
            return false
        }
        await read(item)
        await forgetting?(key.host, address.id)
        if missing[key] == .refusal(.password) {
            locks[key] = .wrong
            return false
        }
        locks[key] = nil
        return missing[key] == nil
    }

    /// A sign-in landed on this forum: every blog whose last read came to a refusal a sign-in
    /// could change is read again, as the member the reader now is.
    func signedIn(host raw: String) {
        let host = raw.lowercased()
        for (key, item) in refusedAsGuest where key.host == host {
            refusedAsGuest.removeValue(forKey: key)
            missing.removeValue(forKey: key)
            locks.removeValue(forKey: key)
            Task { await self.read(item) }
        }
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
        for key in Array(locks.keys) where key.host == host { locks.removeValue(forKey: key) }
        for key in Array(refusedAsGuest.keys) where key.host == host { refusedAsGuest.removeValue(forKey: key) }
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
                self.refusedAsGuest.removeValue(forKey: key)
            case .failure(let absence):
                self.missing[key] = absence
                if absence.signInMayChange { self.refusedAsGuest[key] = item } else { self.refusedAsGuest.removeValue(forKey: key) }
            }
        }
        inFlight[key] = task
        await task.value
    }

    private static func key(of item: DummyItem) -> NoteKey {
        NoteKey(host: item.source.host, id: item.noteID)
    }
}
