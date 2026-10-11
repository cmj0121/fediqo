import AuthenticationServices
import FediqoCore
import Foundation
import Observation
import SwiftUI

/// Every Mastodon this device is signed in to.
///
/// **Signed in is "a token is in the Keychain for that host"** and nothing else — no store
/// column, no flag beside it. `grants` is that fact held for view bodies to read — who, and what
/// their sign-in bought (#69) — refreshed at the three places it can change: a sign-in saved, a
/// sign-out, and a server ending one.
@MainActor
@Observable
public final class MastodonSessions {
    @ObservationIgnored let tokens: any MastodonTokenStore
    @ObservationIgnored let sender: any HTTPSender
    /// Where each request this makes is shown while it runs (#164). The app's own; a test hands
    /// in another.
    @ObservationIgnored var work: SourceWork = .shared
    /// Bumped per host by every sign-out, so a sign-in still on the server's page when the source
    /// is cleared or removed does not save the token it comes back with.
    @ObservationIgnored private var signOuts: [String: Int] = [:]
    /// Told the folded host each time a server ends a sign-in on its own side, so whoever holds
    /// a question about that sign-in can put it down.
    @ObservationIgnored var onEnded: ((String) -> Void)?

    /// What this run has learnt of registering at each host (#347): its own list of words, a
    /// registration it refused, a page suspected of stranding. Never written down.
    @ObservationIgnored private var registering = MastodonRegistering()

    /// What each signed-in host's sign-in bought (#69) — **and, by its keys, who is signed in at
    /// all.**
    ///
    /// **Read from the items' attributes and never from a token**, which is what keeps the source
    /// page free of a Keychain access prompt per row — see `MastodonTokenStore.grants()`. A host
    /// with no entry is one this device holds no sign-in for at all.
    private(set) var grants: [String: MastodonGrant] = [:]

    /// Which hosts this device holds a sign-in for. **Derived and not stored beside `grants`**, so
    /// that "who is signed in" and "what their sign-in bought" cannot come to disagree by one of
    /// two assignments being forgotten — the store answers them in one query and this answers them
    /// from one value.
    var signedInHosts: Set<String> { Set(grants.keys) }

    /// Hosts that ended a sign-in on their own side, not yet told to the reader.
    private(set) var ended: [String] = []

    /// Hosts whose last write was turned away, until they are signed in again — cleared by a
    /// sign-in and by a sign-out, which are the two acts that replace what a write would use.
    private(set) var writeRefused: Set<String> = []

    /// The hosts whose sign-in may bookmark (#285) — read with `grants`, off the same attribute
    /// and never off a token. A sign-in made before bookmarks were asked for is not among them,
    /// and writes exactly as it did.
    private(set) var bookmarkHosts: Set<String> = []

    /// Hosts whose sign-in asked for bookmarks and was not given them (#285): a server with no
    /// such scope, or one that granted less than it was asked.
    /// The row and Account stop offering to ask there, since asking again would get the same
    /// answer. **Read with `grants`, off what the sign-in wrote down beside itself**, so it holds
    /// across a relaunch and goes with the sign-in; a later sign-in asks afresh.
    private(set) var bookmarksRefused: Set<String> = []

    /// Hosts that turned a bookmark away with a 403 this run (#285), until they are signed in to
    /// again — `writeRefused`'s shape, for the one act. Never written down.
    private(set) var bookmarkTurnedAway: Set<String> = []

    /// The hosts whose sign-in may read notices (#323) — `bookmarkHosts`' shape: read with
    /// `grants`, off the same attribute and never off a token. A sign-in made before notices were
    /// asked for is not among them, and reads, writes and bookmarks exactly as it did.
    private(set) var noticeHosts: Set<String> = []

    /// The hosts whose sign-in may dismiss notices (#323): those that asked for notices while
    /// asking to act.
    private(set) var dismissHosts: Set<String> = []

    /// Hosts whose sign-in asked for notices and was not given them (#323) —
    /// `bookmarksRefused`'s shape, read off what the sign-in wrote down beside itself, so the
    /// notices page stops offering to ask a source that has answered.
    private(set) var noticesRefused: Set<String> = []

    /// Hosts that turned a read of notices away with a 403 this run (#323), from a sign-in that
    /// says it may — `bookmarkTurnedAway`'s shape — **and hosts that refused the ask for them
    /// outright**: a server that knows no such scope issues no token to write a refusal beside,
    /// so it is kept here, and the source is not asked again. Never written down; a sign-in or
    /// a sign-out clears it.
    private(set) var noticesTurnedAway: Set<String> = []

    /// Hosts whose signed-in reader is no longer the one their rows were read as (#285): signed
    /// out, ended by the server, cleared, or signed in to as somebody not shown to be the same.
    /// The session takes them (`takeReadersChanged`) and lets go of what the source had said that
    /// reader did to its posts.
    @ObservationIgnored private var readersChanged: Set<String> = []

    /// Whether the last look at who is signed in could be had at all. A Keychain that cannot be
    /// read — a locked device at launch — is not everybody signing out.
    @ObservationIgnored private(set) var grantsKnown = false

    /// Whether the last look at who may read notices could be had (#323). Where it could not,
    /// `noticeHosts` is empty for want of an answer, and a sign-in that would carry notices reads
    /// the sign-in held instead of taking that for a no.
    @ObservationIgnored private var noticesKnown = false

    /// The hosts whose reader changed and whose sweep has not run yet, without taking them:
    /// what a quit lets go of from the store before it saves, the rest being the next launch's.
    public var readersChangedWaiting: Set<String> { readersChanged }

    /// The hosts whose reader changed since this was last asked, handed over once.
    func takeReadersChanged() -> Set<String> {
        defer { readersChanged = [] }
        return readersChanged
    }

    /// Who the reader is on each signed-in host, as `@user@host`, **as that source said this run**
    /// (#109) — what tells a post the reader wrote from one they did not.
    ///
    /// **Asked, never kept.** It is learnt from the account check at launch and after a sign-in,
    /// and dropped with the sign-in, so a second account signed in on the same host is never
    /// handed the first one's posts to take back. A host not yet answered has no entry, and
    /// then nothing there is offered for taking back — the safe side of not knowing.
    private(set) var handles: [String: String] = [:]

    /// An account as its source named it, and the sign-in the answer came through.
    ///
    /// **Who it is, is the id** — what a text's writer is told by (`ShellOutbox.writes`). The
    /// handle is the source's own spelling of a name: compared as sent with the handle a post
    /// of that source carries, and never drawn as sent (`shown`).
    struct Reader: Equatable {
        let id: String
        let handle: String
        fileprivate let accessToken: String

        /// `handle`, made fit to stand in a sentence of ours: no control or format character,
        /// no line break, and no longer than a name may run (`LineText.oneLine`).
        var shown: String { LineText.oneLine(handle) }
    }

    /// Who each sign-in is, by the id its source gives the account, as the account check said
    /// through that very sign-in.
    @ObservationIgnored private var readers: [String: Reader] = [:]
    /// Moved when `readers` is, so a page drawn from `reader(host:)` is drawn again.
    private var readersLearnt = 0

    /// Who is signed in at `host`, where its source has said — **through the sign-in held
    /// now**. Read off the sign-in itself, where it was written down with it (`learnWho`), so it
    /// is known with no network; and otherwise what this run was told through that very token.
    /// A sign-in replaced under this object's feet, by a read back or another device's
    /// package, is somebody nobody has asked about yet, and this answers nothing for it: what
    /// was learnt of the sign-in before is never laid on the one that took its place.
    func reader(host raw: String) -> Reader? {
        _ = readersLearnt
        let host = raw.lowercased()
        guard let held = token(host: host) else { return nil }
        if let id = held.accountID, let handle = held.handle {
            return Reader(id: id, handle: handle, accessToken: held.accessToken)
        }
        guard let reader = readers[host], held.accessToken == reader.accessToken else { return nil }
        return reader
    }

    /// Hosts whose account check found the network dark (#222) — a launch with no network, most
    /// often — and so are asked again as soon as a read gets through to them, rather than going
    /// unknown until a relaunch. `learnWhoAgain(among:)` is that second ask.
    @ObservationIgnored private var unlearned: Set<String> = []

    public init(
        tokens: any MastodonTokenStore = KeychainMastodonTokens(),
        sender: any HTTPSender = URLSessionClient.signedIn()
    ) {
        self.tokens = tokens
        self.sender = sender
        refresh()
    }

    func isSignedIn(host: String) -> Bool {
        grants[host.lowercased()] != nil
    }

    /// Signs in on the server's own page and keeps the token. Nothing where it worked, or where the
    /// reader closed the page or said no there; otherwise why it did not.
    ///
    /// **One registration per host, made for every word a sign-in may come to be asked for**
    /// (#347, `registration`), and kept, so signing out and in again — or asking for more —
    /// does not leave a trail of apps on the reader's account. **The page asks for less than
    /// that**: what the reader's answer asks, and no word more.
    ///
    /// **One page a press, whatever the server answers.** A word a server does not know is
    /// found where the app is registered, before any page; no page is opened to find it.
    ///
    /// **A registration an earlier build made is left as it is**, and used wherever it holds
    /// what this sign-in asks; it is made again only at a press that asks for a word it lacks.
    /// A sign-in held was made with its own registration, which it carries, so making another
    /// takes nothing from it.
    ///
    /// The registration is dropped — and the next attempt registers afresh — where the server
    /// rejects it at the token exchange or answers `invalid_scope`, or where a sign-in through
    /// one kept from before ends with the page closed: a server that no longer knows the client
    /// shows an error page with no way back, and closing it is the only thing the reader can do
    /// there.
    ///
    /// **A page closed on a registration nothing confirmed is suspected of the same**
    /// (`MastodonRegistering.strand`): the next press registers for exactly what it asks
    /// where a sign-in is held, and for the least a sign-in can be where none is; where that
    /// page ends the same way the source is not asked again this run — `stranded(host:)` says
    /// so, and every later press is answered without asking it. **A sign-in that came back
    /// through a registration confirms it**: a page closed under it later is a page closed.
    ///
    /// **A sign-in held never comes out of a press with fewer of the words that press asked**:
    /// no registration is made, and none kept from before is used, whose page would leave it
    /// less, and a server that answers with less has its token ended and the one held stays.
    /// Reading alone, chosen over a sign-in that acts, asks for less and is kept.
    ///
    /// **`writing` is the reader's own answer and is never assumed** (#69). It decides what the
    /// server's page asks for, and it is written down with the token. `false` asks for exactly
    /// the scopes this app asked for before it could write at all, so refusing the writing part
    /// leaves reading as it was, down to the string. A server that has no writing part to give
    /// fails the sign-in and says so — it is **never** quietly made one for reading alone,
    /// because a reader who asked to write and was handed a read-only sign-in without being
    /// told has been answered for.
    ///
    /// **A sign-in to read and act asks for bookmarks too** (#285), and a server that has none,
    /// or no search (Decision 32), leaves the reader with the sign-in they asked for without
    /// it. What the server itself has none of is still written down as asked, so the row
    /// stops offering it; what was only left off a page is not, and stays a lock at its place.
    ///
    /// **A sign-in made while a token is already held replaces it here and revokes it there**
    /// (#69). `tokens.save` is delete-then-add, so the superseded token would otherwise stay live
    /// on the server — and a reader narrowing their answer from writing back to reading would
    /// have left a write-capable grant behind, which is the opposite of what they just asked for.
    ///
    /// **Notices are asked for only where the reader pressed for them** (#323): `notices` is
    /// `true` from the notices page's press and from nowhere else. Left out, the sign-in
    /// **carries what the one held has** — so adding the writing part or bookmarks never takes
    /// notices away, and a sign-in with nothing held, or after a sign-out, asks for none. A
    /// server with no such scope fails the ask, and the sign-in held is still held.
    ///
    /// **What is carried is what the last look said the sign-in held has** — and only where that
    /// look could not be had, the held token's own scopes, read here — so a look at the Keychain
    /// that failed cannot quietly take notices out of the next sign-in, and a sign-in on a source
    /// with no notices reads nothing it did not read before. A sign-in whose notices were refused
    /// holds none, so it carries none: the next ordinary sign-in asks for what the reader agreed
    /// to and no more, and the refusal goes with the sign-in it was an answer to.
    ///
    /// **A source that has answered the ask is not asked again**: where it refused the scope
    /// outright, or granted the sign-in without it, a second press sends nothing and is told the
    /// same thing, until a sign-in or a sign-out. **Only the press itself is read that way**: a
    /// sign-in that merely carried notices and was refused — for the writing part, say — says
    /// nothing about notices, and the sign-in held goes on reading them.
    ///
    /// **`noticesSaid` is what the question this answers said of notices**, where one was put:
    /// said to carry none, the sign-in asks for none, whatever the sign-in held has come to
    /// have while the question stood open — the page never asks for what the person was not
    /// told. It only ever narrows: notices are carried where they were said and are still held.
    func signIn(
        host raw: String, through browser: any OAuthBrowser, writing: Bool = false,
        notices wanted: Bool? = nil, noticesSaid said: Bool? = nil
    ) async -> MastodonSignInError? {
        let host = raw.lowercased()
        let pressed = wanted == true
        if pressed, noticesGaveNone(host) { return .invalidScope }
        if registering.stranded(host) { return .invalidScope }
        let notices = wanted ?? (said != false && carriesNotices(host: host))
        let before = signOuts[host, default: 0]
        // Whether the reader still wants this sign-in: not signed out, cleared or removed since.
        var stillWanted: Bool { signOuts[host, default: 0] == before }
        let oauth = MastodonOAuth(host: host, sender: WatchedHTTP(sender: sender, for: .signIn, in: work))
        // What the reader's answer asks, and the same with less, a part a sign-in is whole
        // without at a time: without bookmarks, then without search as well — the least.
        let chosen = MastodonOAuth.scopes(writing: writing, notices: notices)
        let narrower = [
            MastodonOAuth.scopes(writing: writing, bookmarks: false, notices: notices),
            MastodonOAuth.scopes(search: false, writing: writing, bookmarks: false, notices: notices),
        ]
        let made: Registration
        do {
            guard let found = try await registration(host: host, for: chosen, orLess: narrower, since: before)
            else { return nil }
            made = found
        } catch let error as MastodonSignInError {
            // The press for notices itself, and the server would register for none of them.
            // Never a sign-in that only carried them, whose refusal may be about anything.
            if error == .invalidScope, pressed, stillWanted { noticesTurnedAway.insert(host) }
            return error == .cancelled ? nil : error
        } catch {
            return .unreachable
        }
        // A part left off a page for want of proof that the host has it was not asked; one the
        // host itself said it has none of was, and the row stops offering it.
        let asked = MastodonRegistration.asked(chosen, on: made.page) { registering.hasNone(of: $0, at: host) }
        var token: MastodonToken
        do {
            let signed = try await oauth.signIn(as: made.app, asking: made.page, through: browser)
            // The page came back and its code was traded: the host knows this registration.
            registering.made(at: host, confirmed: true)
            // A token that failed its check is no sign-in — and may be the one held.
            if let failed = signed.failed {
                await end(signed.token, why: .notKept)
                throw failed
            }
            token = signed.token.recorded(asked: asked)
        } catch let error as MastodonSignInError {
            // No server's page sends `invalid_scope` back; one that did has said what a page
            // of its own, closed, says of a registration nothing confirmed.
            let strand = error == .invalidScope || (error == .cancelled && registering.isUnconfirmed(host))
            if error == .clientRejected || strand || (made.wasKept && error == .cancelled) {
                drop(made.app)
            }
            // Cleared or removed while the page was up: nothing is concluded about a source
            // the reader has let go of, and nothing said under a row that is gone.
            let unsaid = error == .cancelled || error == .denied
            guard stillWanted else { return strand || unsaid ? nil : error }
            if strand { registering.strand(host) }
            if error == .invalidScope, pressed { noticesTurnedAway.insert(host) }
            if strand, registering.stranded(host) { return .invalidScope }
            return unsaid ? nil : error
        } catch {
            return .unreachable
        }
        guard stillWanted else {
            await end(token, why: .notKept)
            return nil
        }
        // The token this one supersedes, read before `save` deletes it.
        let superseded = (try? tokens.token(host: host)) ?? nil
        // A server cannot talk this device out of a sign-in it holds: one that answers with
        // fewer of the words asked than the sign-in held has is not kept.
        if let superseded, !MastodonRegistration.keeps(superseded.scopes, asking: chosen, in: token.scopes) {
            await end(token, why: .notKept)
            return .unreadable
        }
        do {
            try tokens.save(token)
        } catch {
            // **The sign-in the reader had, put back before anything is awaited** (#285). `save`
            // deletes before it adds, so an add that fails has taken the old token from this
            // device with it still live at the server, on a press that promised nobody is signed
            // out first. Put back here and not after the round trip below: a sign-out landing
            // during that wait would find nothing to forget or revoke, and the token put back
            // after it would sign the reader in again behind their sign-out. Where it cannot be
            // put back either, it is revoked, so nothing is live there that this device has lost.
            // Where it was put back and the new token is that very string, nothing is revoked.
            var lost: MastodonToken?
            if let superseded, ((try? tokens.token(host: host)) ?? nil) == nil {
                do { try tokens.save(superseded) } catch { lost = superseded }
            }
            refresh()
            await end(token, why: .notKept)
            if let lost { await end(lost, why: .notKept) }
            return .keychain
        }
        // What is held is read again **before the wait below** (#323): a second sign-in started
        // while the server is being asked to forget the old token carries what this one holds,
        // not what the one it replaced did.
        refresh()
        // **After the new one is safely kept**, and never a token with the same string (`end`).
        if let superseded { await end(superseded, why: .notKept) }
        // A fresh sign-in is a fresh answer from the server about what this device may do, so
        // whatever it turned away before this is spent.
        writeRefused.remove(host)
        bookmarkTurnedAway.remove(host)
        noticesTurnedAway.remove(host)
        registering.signedIn(host)
        let reader = handles[host]
        handles[host] = nil
        refresh()
        // Who the reader is matters only to taking back what they wrote, which needs the writing
        // part — so a sign-in that did not buy it asks nothing more than it always did.
        if grants[host] == .writing { await learnWho(host: host) }
        // **Not shown to be the reader who was here before** (#285): another account, or one
        // nobody could name on either side. What the source said that reader had done to its
        // posts is not this one's to be told.
        if reader == nil || handles[host] != reader { readersChanged.insert(host) }
        return nil
    }

    /// A registration to sign in through, and what its page asks.
    private struct Registration {
        let app: MastodonApp
        let page: String
        /// Whether it was kept from before this press, and not made by it.
        let wasKept: Bool
    }

    /// The registration a sign-in asking for `chosen` goes through, and what its page asks —
    /// the one kept where that holds every word of `chosen`, and otherwise one made here.
    /// Nothing, where the reader let go of the source meanwhile.
    ///
    /// **Made for everything, less what the host's own list lacks** — asked for here, once a
    /// run, and only ever taking away. **Refused, one kept from before that can carry the page
    /// serves**; with none, it is made for exactly `chosen`, and then for each of `narrower`
    /// in turn. Every refusal is remembered for the run: a host is never asked twice for a
    /// registration it refused, so a first sign-in costs it one more registration than
    /// `narrower` has, at most, and a later press none.
    ///
    /// **Nothing here takes a word from a sign-in held**: a registration whose page would
    /// leave it fewer of the words `chosen` asks is neither made nor used.
    ///
    /// **After a page with no way back** (`MastodonRegistering.strand`) one registration is
    /// made: for exactly `chosen` where a sign-in is held, and for the least where none is.
    ///
    /// **What is stored is looked at again after every wait**, and a registration made here is
    /// kept only where the one stored is still the one this looked at: a sign-out, a Clear, a
    /// Remove or another sign-in meanwhile is not written over. One this press could not keep
    /// still serves its own page.
    private func registration(
        host: String, for chosen: String, orLess narrower: [String], since before: Int
    ) async throws -> Registration? {
        var stillWanted: Bool { signOuts[host, default: 0] == before }
        // The sign-in held, as its attributes say it: no token is read before a page opens, and
        // what the token itself says is looked at once its answer is in (`signIn`).
        let held = ((try? tokens.parts()) ?? [:])[host]
        // Whether a page asking `words` leaves the sign-in held every word of it this one asks.
        func keeps(_ words: String) -> Bool { MastodonRegistration.keeps(held?.scopes, asking: chosen, in: words) }
        // What is stored now, and the page it serves: where it holds all of `chosen`, was made
        // for exactly `words`, or — everything being no longer tried here — carries a page
        // that takes nothing from the sign-in held.
        func kept(for words: String? = nil) -> (stored: MastodonApp?, page: String?) {
            let stored = (try? tokens.app(host: host)) ?? nil
            guard let stored, let scopes = stored.scopes,
                  let page = MastodonRegistration.page(chosen, on: scopes)
            else { return (stored, nil) }
            let carries = !registering.mayTryWhole(host) && keeps(page)
            return (stored, page == chosen || scopes == words || carries ? page : nil)
        }
        var seen = kept()
        if let app = seen.stored, let page = seen.page { return Registration(app: app, page: page, wasKept: true) }

        let oauth = MastodonOAuth(host: host, sender: WatchedHTTP(sender: sender, for: .signIn, in: work))
        var tries: [String] = []
        if registering.mayTryWhole(host) {
            let listed = await listedWords(host: host)
            guard stillWanted else { return nil }
            let whole = MastodonRegistration.superset(listed: listed)
            // The host's own list has none of something this sign-in cannot do without: it is
            // not registered with to be told so again.
            guard MastodonRegistration.page(chosen, on: whole) != nil else { throw MastodonSignInError.invalidScope }
            tries.append(whole)
        }
        let everything = tries.first
        // After a page with no way back, one try: what is asked, to the word, where a sign-in
        // is held — and the least, where none is, so that no one part can strand both tries.
        let after = held == nil ? Array(narrower.suffix(1)) : [chosen]
        let less = registering.suspected(host) ? after : [chosen] + narrower
        for words in less where !tries.contains(words) && keeps(words) { tries.append(words) }

        for (step, words) in tries.enumerated() where !registering.refused(words, at: host) {
            seen = kept(for: words)
            if let app = seen.stored, let page = seen.page { return Registration(app: app, page: page, wasKept: true) }
            do {
                let answer = try await oauth.registered(for: words)
                guard stillWanted else { return nil }
                // What the page asks is read off what the server says it registered, which may
                // be less than it was asked — and too little for this sign-in at all.
                guard let page = MastodonRegistration.page(chosen, on: answer.app.scopes) else {
                    throw MastodonSignInError.invalidScope
                }
                // What the host has none of, where it said: by naming what it registered, or
                // by refusing the try before this one for a single word more.
                if answer.echoed { registering.named(answer.app.scopes, of: words, at: host) }
                if step > 0 { registering.made(words, after: tries[step - 1], at: host) }
                registering.made(at: host, confirmed: answer.echoed || registering.list(host) != nil)
                let stored = try? tokens.app(host: host) as MastodonApp??
                if let stored, stored == seen.stored { try? tokens.save(answer.app) }
                return Registration(app: answer.app, page: page, wasKept: false)
            } catch MastodonSignInError.invalidScope {
                if words == everything { registering.refusedWhole(host) }
                registering.refuse(words, at: host)
                guard stillWanted else { return nil }
            }
        }
        throw MastodonSignInError.invalidScope
    }

    /// How long a host's own list of words is waited for before the registration is asked
    /// without it.
    @ObservationIgnored var wordListWait: Duration = .seconds(8)

    /// The host's own list of the scope words it knows, asked once a run and with no sign-in;
    /// nothing where it gave none in time (`MastodonOAuth.listedWords`). Listed among the
    /// run's requests as part of signing in.
    private func listedWords(host: String) async -> Set<String>? {
        if let known = registering.list(host) { return known }
        let watched = WatchedHTTP(sender: SourceReach.wordList(sender), for: .signIn, in: work)
        let asked = MastodonOAuth(host: host, sender: Deadline(watched as any HTTPSender, within: wordListWait))
        guard let listed = await asked.listedWords() else { return nil }
        registering.learnt(listed, of: host)
        return listed
    }

    /// Forgets a registration a sign-in went through — where it is still the one stored, so
    /// one another sign-in made meanwhile is left.
    private func drop(_ app: MastodonApp) {
        guard let stored = try? tokens.app(host: app.host), stored == app else { return }
        try? tokens.forgetApp(host: app.host)
    }

    /// Whether `host` cannot be asked to sign in again this run: two pages there ended with
    /// nothing sent back. Every press is then answered as a refusal, and sends nothing, until
    /// the source is cleared or removed.
    func stranded(host raw: String) -> Bool {
        registering.stranded(raw.lowercased())
    }

    /// A bookmark this source turned away with a 403 (#285), **remembered for this run and written
    /// nowhere**, as a write turned away is (`refusedWrite`): the bookmark is not offered on that
    /// source again until it is signed in to again or the app is opened again, and every other
    /// act the sign-in could do, it still does. One refusal is not proof — a proxy in front of
    /// one path, an account limited for a day — so nothing the sign-in wrote down is touched.
    ///
    /// **Only where `sent` is still the token held**: a refusal that comes back about a sign-in
    /// the reader has since replaced says nothing about the one they have now.
    func refusedBookmark(host raw: String, sentWith sent: MastodonToken) {
        let host = raw.lowercased()
        guard token(host: host)?.accessToken == sent.accessToken else { return }
        bookmarkTurnedAway.insert(host)
    }

    /// A read of notices this source turned away with a 403 (#323), remembered for this run and
    /// written nowhere — `refusedBookmark`'s rule and for its reasons: notices are not asked of
    /// that source again until it is signed in to again or the app is opened again, nothing the
    /// sign-in wrote down is touched, and a refusal about a sign-in since replaced is not laid on
    /// the one held now.
    func refusedNotices(host raw: String, sentWith sent: MastodonToken) {
        let host = raw.lowercased()
        guard token(host: host)?.accessToken == sent.accessToken else { return }
        noticesTurnedAway.insert(host)
    }

    /// Asks the source who the reader is on it (#109). Silent on any failure: not knowing offers
    /// nothing for taking back, which is the one safe answer, and a 401 is told as `verifyAll`
    /// tells it.
    func learnWho(host raw: String, within limit: Duration? = nil) async {
        let host = raw.lowercased()
        unlearned.remove(host)
        guard let door = authorized(host: host, within: limit, for: .signInCheck) else { return }
        do {
            let who = try await door.who()
            if isSignedIn(host: host) {
                handles[host] = who.handle
                readers[host] = who.id.map { Reader(id: $0, handle: who.handle, accessToken: door.token.accessToken) }
                // Written down with the sign-in it was said through, where that is still the
                // one held: the next run knows whose it is before any source answers.
                if let id = who.id, let held = token(host: host), held.accessToken == door.token.accessToken,
                   held.accountID != id || held.handle != who.handle {
                    try? tokens.save(held.named(accountID: id, handle: who.handle))
                }
                readersLearnt += 1
            }
        } catch MastodonAuthError.signedOut {
            endedByServer(host: host)
        } catch where DarkNetwork.caused(error) {
            if isSignedIn(host: host) { unlearned.insert(host) }
        } catch {}
    }

    /// Asks who the reader is again on each of `hosts` whose last account check the network was
    /// dark for (#222). A reload calls it with the hosts it just read, so the network coming back
    /// is noticed by the first read that gets through; a host asked and answered is not asked
    /// again, and one never dark is never asked here at all.
    func learnWhoAgain(among hosts: Set<String>, within limit: Duration) async {
        let due = unlearned.intersection(hosts.map { $0.lowercased() })
        // Claimed before the first await, so two reloads landing together ask each host once.
        unlearned.subtract(due)
        for host in due.sorted() {
            await learnWho(host: host, within: limit)
        }
    }

    /// A write this source turned away (#69). The row says so and keeps saying it until the source
    /// is signed in again — **it does not sign the reader out**, because reading is untouched by
    /// it and a 403 is not a revoked token.
    func refusedWrite(host raw: String) {
        writeRefused.insert(raw.lowercased())
    }

    /// What may be done on one source, from what its sign-in bought and what it has refused since.
    ///
    /// **The one place the three facts meet**, so the row, its spoken sentence and anything that
    /// later asks whether a write may be attempted read one answer rather than three derivations
    /// of it.
    func writing(host raw: String, kind: ProtocolKind) -> SourceWriting {
        let host = raw.lowercased()
        return SourceWriting.of(
            kind: kind, grant: grants[host], refused: writeRefused.contains(host)
        )
    }

    /// Whether the sign-in on one source may bookmark (#285) — beside `writing(host:kind:)` and
    /// not inside it, since a sign-in that lacks this still writes everything it wrote.
    ///
    /// `unasked` only for a sign-in that writes and has not been asked this run: one that reads
    /// has nothing to add bookmarks to, and its row already says to sign in to act.
    func bookmarks(host raw: String) -> BookmarkStanding {
        let host = raw.lowercased()
        if bookmarkTurnedAway.contains(host) { return .unavailable }
        if bookmarkHosts.contains(host) { return .allowed }
        guard grants[host] == .writing, !bookmarksRefused.contains(host) else { return .unavailable }
        return .unasked
    }

    /// Whether the sign-in on one source may read notices (#323) — beside `bookmarks(host:)`,
    /// and for a sign-in that lacks this, nothing else is changed by it.
    ///
    /// **`unasked` for every sign-in that has not asked**, and here it parts from
    /// `bookmarks(host:)`: reading a notice needs no writing part, so a sign-in to read, one to
    /// read and act, and one kept before either was asked about are all owed the question —
    /// when the reader presses for it, and not before.
    func notices(host raw: String) -> NoticeStanding {
        let host = raw.lowercased()
        if noticesGaveNone(host) { return .unavailable }
        if noticeHosts.contains(host) { return .allowed }
        return grants[host] == nil ? .unavailable : .unasked
    }

    /// Whether a source asked for notices gave none: turned the ask away this run, or granted
    /// the sign-in without them. `host` is folded already.
    private func noticesGaveNone(_ host: String) -> Bool {
        noticesTurnedAway.contains(host) || noticesRefused.contains(host)
    }

    /// Whether the sign-in on one source may dismiss notices (#323): it asked for them while
    /// asking to act.
    func dismisses(host raw: String) -> Bool {
        dismissHosts.contains(raw.lowercased())
    }

    /// Whether an ordinary sign-in on `host` — one nobody pressed for notices on — asks for
    /// them all the same, because the sign-in held has them (`signIn`'s carry). **The one
    /// answer the sign-in goes by and the question before it reads**, so what the person is
    /// told the source's page will ask is what it asks.
    func carriesNotices(host raw: String) -> Bool {
        let host = raw.lowercased()
        return noticesKnown ? noticeHosts.contains(host) : MastodonOAuth.notices(token(host: host)?.scopes)
    }

    /// The token leaves this device first; then the server is asked to forget it, and whatever it
    /// answers changes nothing here.
    ///
    /// **Nothing is left that could sign in as the reader there** (#221). The sign-in page runs
    /// in a session of its own that keeps nothing (`WebAuthBrowser`), so no website session of
    /// this sign-in outlives it either.
    ///
    /// `forgettingApp` drops the app registration too — Clear and Remove, after which nothing of
    /// this source's sign-in is left on the device, nor anything this run learnt of registering
    /// there. A plain sign-out keeps it for next time: it names
    /// this app to the server and signs nobody in without the reader on the server's own page
    /// (#221), and one made afresh at every sign-in would pile up on a server that has no way to
    /// drop one.
    func signOut(host raw: String, forgettingApp: Bool = false) async {
        let host = raw.lowercased()
        signOuts[host, default: 0] += 1
        let token = (try? tokens.token(host: host)) ?? nil
        do {
            try tokens.forget(host: host)
        } catch {
            // The token is still in the Keychain, so the row still reads signed in — `refresh`
            // reads it back rather than claiming a sign-out that did not happen. The server is
            // still asked to forget it.
            NetLog.auth.error("\(NetLog.line("sign-out", host: host, error: error), privacy: .public)")
        }
        if forgettingApp {
            try? tokens.forgetApp(host: host)
            registering.forget(host)
        }
        writeRefused.remove(host)
        bookmarkTurnedAway.remove(host)
        noticesTurnedAway.remove(host)
        handles[host] = nil
        refresh()
        if let token { await end(token, why: .signedOut) }
    }

    /// Why a source is asked to end a sign-in.
    private enum Ending {
        /// A token a sign-in made and did not keep, or one it replaced: ended only where it is
        /// not the one held.
        case notKept
        /// The person asked for this very sign-in to end — a sign-out, Clear or Remove.
        case signedOut
    }

    /// Asks a source to end a sign-in — **the one place that does** (#347).
    ///
    /// **A token the person did not ask to end is never ended while it is the one held.** A
    /// server answers the same words on the same registration with the token it already
    /// issued, so a token a sign-in could not keep may be, string for string, the one the row
    /// says the person has: ending it would sign them out behind a row that reads signed in.
    /// What is held is read here, with nothing awaited between the look and the send, so a
    /// token put back or kept a moment ago is seen. Where the Keychain cannot be read nothing
    /// is sent: that can leave a token nobody kept live at the source, which is rare and
    /// better than ending one that is held.
    ///
    /// **The sign-in the person signed out of is ended whatever this device still holds**
    /// (#221): it was read before it was forgotten, and a Keychain that would not delete it, or
    /// cannot be read now, is no reason to leave it live at the source.
    private func end(_ token: MastodonToken, why ending: Ending) async {
        if ending == .notKept {
            do {
                guard try tokens.token(host: token.host)?.accessToken != token.accessToken else { return }
            } catch {
                NetLog.auth.error("\(NetLog.line("end", host: token.host, error: error), privacy: .public)")
                return
            }
        }
        let purpose: SourceWork.Purpose = ending == .signedOut ? .signOut : .signIn
        await MastodonOAuth(host: token.host, sender: WatchedHTTP(sender: sender, for: purpose, in: work))
            .revoke(token)
    }

    /// The door a signed-in request goes through, or nothing where no token can be read.
    /// `within` puts a deadline on each request — a reload's (#29). `purpose` is what each request
    /// through it is shown as while it runs (#164): only the caller knows what it is for — and,
    /// where it reads one timeline, which, by the name the reader knows it by (#170).
    func authorized(
        host: String, within limit: Duration? = nil, for purpose: SourceWork.Purpose,
        name: SourceWork.Name? = nil
    ) -> MastodonAuthorized? {
        guard let token = token(host: host) else { return nil }
        return authorized(token: token, within: limit, for: purpose, name: name)
    }

    /// The token kept for a host, or nothing where none can be read. One Keychain read, for a
    /// caller about to build several doors with `authorized(token:within:for:name:)`.
    func token(host: String) -> MastodonToken? {
        (try? tokens.token(host: host)) ?? nil
    }

    /// A door through a token already read — `authorized(host:within:for:name:)` without the
    /// Keychain, so a reload building one door per timeline reads the token once.
    func authorized(
        token: MastodonToken, within limit: Duration? = nil, for purpose: SourceWork.Purpose,
        name: SourceWork.Name? = nil
    ) -> MastodonAuthorized {
        let watched = WatchedHTTP(sender: sender, for: purpose, name: name, in: work)
        let wire: any HTTPSender = limit.map { Deadline(watched as any HTTPSender, within: $0) } ?? watched
        return MastodonAuthorized(token: token, sender: wire, store: tokens)
    }

    /// A request answered `.signedOut`: the token is already gone, so the row and the reader are
    /// told.
    func endedByServer(host raw: String) {
        let host = raw.lowercased()
        refresh()
        if !ended.contains(host) { ended.append(host) }
        onEnded?(host)
    }

    /// At launch: asks each server whether it still honours its token. Only a 401 signs out; a
    /// server that cannot be reached leaves the sign-in as it was, and is asked again by the first
    /// read that reaches it (`learnWhoAgain`).
    ///
    /// **The same answer says who the reader is there** (#109), so asking it is not a second
    /// request: `learnWho` reads the account check's own body.
    public func verifyAll() async {
        for host in grants.keys.sorted() {
            await learnWho(host: host)
        }
    }

    func endedSeen() {
        ended = []
    }

    /// Reads who is signed in again. Also asked when the app comes to the front: a Keychain read
    /// at launch on a locked device finds nothing, and that is not a sign-out.
    func refresh() {
        // **One query, one value, and it reads no token** — see `MastodonTokenStore.grants()`. Who
        // is signed in is this dictionary's keys, so a row can never draw a sign-in this object
        // does not also have a grant for.
        let read = try? tokens.grants()
        grantsKnown = read != nil
        let grants = read ?? [:]
        // A host that held a sign-in and no longer does, however it went (#285) — and only where
        // the look itself could be had.
        if read != nil { readersChanged.formUnion(Set(self.grants.keys).subtracting(grants.keys)) }
        if grants != self.grants { self.grants = grants }
        let bookmarking = ((try? tokens.bookmarking()) ?? []).intersection(grants.keys)
        if bookmarking != bookmarkHosts { bookmarkHosts = bookmarking }
        let refused = ((try? tokens.bookmarksRefused()) ?? []).intersection(grants.keys)
        if refused != bookmarksRefused { bookmarksRefused = refused }
        // The three questions about notices, in the one look a store can answer them from.
        let noticed = tokens.noticeGrants()
        // Known only where who is signed in was read too: without it every host is cut from the
        // answer below, and an empty answer would pass for a no.
        noticesKnown = noticed.noticing != nil && read != nil
        let noticing = (noticed.noticing ?? []).intersection(grants.keys)
        if noticing != noticeHosts { noticeHosts = noticing }
        let dismissing = (noticed.dismissing ?? []).intersection(grants.keys)
        if dismissing != dismissHosts { dismissHosts = dismissing }
        let unnoticed = (noticed.refused ?? []).intersection(grants.keys)
        if unnoticed != noticesRefused { noticesRefused = unnoticed }
        // Who the reader is goes with the sign-in it was learnt through.
        let kept = handles.filter { grants[$0.key] != nil }
        if kept != handles { handles = kept }
    }
}

/// The system's web authentication sheet, **in a session of its own that keeps nothing** (#221).
///
/// It used to share Safari's session (decision 9), so a reader already signed in there was one
/// tap from done — and the server's web session this sign-in made outlived a sign-out here: the
/// token was gone and revoked, and the device could still sign in as the reader, one tap away.
/// Signing out now leaves nothing that can. The cost, said out loud: each sign-in asks for the
/// reader's password on the server's page (a password manager can still fill it), and a
/// session the reader already has in Safari is neither used nor touched.
struct WebAuthBrowser: OAuthBrowser {
    let session: WebAuthenticationSession

    func authorize(_ url: URL, callbackScheme: String) async throws -> URL {
        do {
            return try await session.authenticate(
                using: url,
                callback: .customScheme(callbackScheme),
                preferredBrowserSession: .ephemeral,
                additionalHeaderFields: [:]
            )
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            throw MastodonSignInError.cancelled
        } catch {
            // The sheet could not be shown or could not finish: the row's generic sentence.
            throw MastodonSignInError.unreadable
        }
    }
}
