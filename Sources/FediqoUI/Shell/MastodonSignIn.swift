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
    /// says it may — `bookmarkTurnedAway`'s shape. Never written down; a sign-in or a sign-out
    /// clears it.
    private(set) var noticesTurnedAway: Set<String> = []

    /// What each sign-in is known to hold, by what rides beside it (#347) — read with `grants`
    /// and never off a token: what a place draws a part's standing from (`standing`).
    private(set) var heldParts: [String: MastodonHeld] = [:]

    /// The parts each host was asked for in place this run and has none of (#347): its
    /// registration was refused for them. Never written down; a sign-out clears it, and any
    /// sign-in but one asked for more where it stood.
    private(set) var gaveNone: [String: Set<MastodonPart>] = [:]

    /// Hosts with an ask in place on its way (#347): one at a time, claimed before anything
    /// is awaited, so a second press opens no second page.
    private(set) var asking: Set<String> = []

    /// The sign-in at each host whose words this device has had from its source this run
    /// (#347), by its token string: made here, or asked about (`MastodonOAuth.words(of:)`).
    /// What is written beside any other is somebody's word for it — a package's, most often.
    @ObservationIgnored private var wordsConfirmed: [String: String] = [:]

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
    /// **What the sign-in's own check said, for every sign-in** (#347): off the check a sign-in
    /// makes as it is kept, and off the account check at launch — a sign-in that only reads is
    /// named as one that acts is. It goes with the sign-in it was said through: dropped at a
    /// sign-out, and at the first look that finds another sign-in held there (`refresh`), so a
    /// second account on the same host is never handed the first one's posts to take back. A
    /// host not yet answered has no entry — nor has one whose source gave the account no name
    /// of its own there (`MastodonWho.ownHandle`) — and then nothing there is offered for
    /// taking back, and there is no page of the reader's own: the safe side of not knowing.
    private(set) var handles: [String: String] = [:]

    /// An account as its source named it, and the sign-in the answer came through.
    ///
    /// **Who it is, is the id** — what a text's writer is told by (`ShellOutbox.writes`). The
    /// handle is the source's own spelling of a name: compared as sent with the handle a post
    /// of that source carries, and never drawn as sent (`shown`).
    struct Reader: Equatable {
        let id: String
        /// Nothing where the source gave the account no name of its own there.
        let handle: String?
        fileprivate let accessToken: String
        /// How many ask to follow them, as the check that named them said. Nothing where it
        /// said none, and nothing for a reader known only from what was written down.
        fileprivate var asking: Int? = nil

        /// `handle`, made fit to stand in a sentence of ours: no control or format character,
        /// no line break, and no longer than a name may run (`LineText.oneLine`).
        var shown: String? { handle.map { LineText.oneLine($0) } }
    }

    /// Who each sign-in is, by the id its source gives the account, as its own check said as
    /// it was kept, or the account check said through that very sign-in — **this run**: what
    /// tells a sign-in this device has asked about from one it has only been handed.
    @ObservationIgnored private var readers: [String: Reader] = [:]
    /// Moved when `readers` is, so a page drawn from `reader(host:)` is drawn again.
    private var readersLearnt = 0
    /// How many account checks have answered at each host this run: what tells a figure of
    /// `asking` said after something was answered from one said before it.
    @ObservationIgnored private var askingChecks: [String: Int] = [:]

    /// Who is signed in at `host`, where its source has said — **through the sign-in held
    /// now**. Read off the sign-in itself, where it was written down with it (`signIn`, `name`),
    /// so it is known with no network; and otherwise what this run was told through that very
    /// token.
    /// A sign-in replaced under this object's feet, by a read back or another device's
    /// package, is somebody nobody has asked about yet, and this answers nothing for it: what
    /// was learnt of the sign-in before is never laid on the one that took its place.
    func reader(host raw: String) -> Reader? {
        _ = readersLearnt
        let host = raw.lowercased()
        guard let held = token(host: host) else { return nil }
        if let id = held.accountID {
            // By today's rule: a build before it wrote whatever handle its source sent.
            let handle = held.handle.flatMap { MastodonWho.kept($0, at: host) }
            return Reader(id: id, handle: handle, accessToken: held.accessToken)
        }
        guard let reader = readers[host], held.accessToken == reader.accessToken else { return nil }
        return reader
    }

    /// How many people ask to follow whoever is signed in at `host` (#313), **as that
    /// sign-in's own account check last said this run** — the source's figure at that check:
    /// it does not count down when a request is answered here, and changes when the check
    /// next runs. Nothing where the check said none, has not run for the sign-in held now, or
    /// was another sign-in's: what one reader's check said is never laid on the next.
    func asking(host raw: String) -> Int? {
        _ = readersLearnt
        let host = raw.lowercased()
        guard let held = token(host: host), let reader = readers[host], held.accessToken == reader.accessToken else { return nil }
        return reader.asking
    }

    /// How many ask to follow the reader at `host`, as a change to their own account was just
    /// answered (#312) — **through the sign-in held now**, and only where the answer said: a
    /// figure not said leaves the one the check said. Counted as an account check, since it is
    /// the source's own figure of the same thing.
    /// **Only for the account `accountID` names**: the figure is about that account and no other.
    func askingAnswered(_ asking: Int?, of accountID: String, host raw: String) {
        let host = raw.lowercased()
        guard let asking, let held = token(host: host) else { return }
        if let reader = readers[host], reader.accessToken == held.accessToken {
            guard reader.id == accountID else { return }
            readers[host]?.asking = asking
        } else if let id = held.accountID, id == accountID {
            let handle = held.handle.flatMap { MastodonWho.kept($0, at: host) }
            readers[host] = Reader(id: id, handle: handle, accessToken: held.accessToken, asking: asking)
        } else {
            return
        }
        askingChecks[host, default: 0] += 1
        askingAnswers[host, default: 0] += 1
        readersLearnt += 1
    }

    /// How many times a change has said this run how many ask to follow the reader at each
    /// host: what tells an account check set out before such an answer from one set out after.
    @ObservationIgnored private var askingAnswers: [String: Int] = [:]

    /// Which account check at `host` this run `asking` is the word of: one more each time the
    /// check answers, so whoever saw a figure grow old by its own press knows when a newer one
    /// has come.
    func askingCheck(host raw: String) -> Int {
        _ = readersLearnt
        return askingChecks[raw.lowercased(), default: 0]
    }

    /// How many sign-ins are on their way at each host: a sign-in made and not yet kept is
    /// that sign-in's own to keep or end, and nothing else ends it meanwhile.
    @ObservationIgnored private var signingIn: [String: Int] = [:]

    /// Sign-ins a source was asked to end and did not say it had, after everything of them
    /// left this device (#347). **In memory and nowhere else**: asked again while the app
    /// runs, and forgotten with it. **None of them is a sign-in held, or one written down
    /// again**: a string the source hands back to a later sign-in leaves this as it is kept
    /// or journalled, and is looked for again before each ask (`end`).
    @ObservationIgnored private var unended: [MastodonLeft] = []

    /// The most sign-ins asked again from memory: two sign-outs' worth, each a sign-in
    /// held and all it may have left. Beyond it the oldest is let go of, and told.
    static let mostUnended = 2 * (mostLeft + 1)

    /// Whether the journals are being gone through, so that a launch and a coming to the
    /// front that land together ask each source once.
    @ObservationIgnored private var settlingLeft = false

    /// Whether a going-through asked for by a coming to the front has yet to start: one
    /// waits behind the one running, and a second is not lined up behind it.
    @ObservationIgnored private var frontWaiting = false

    /// The least time between two goings-through of what was left at one host, and between
    /// two asks from memory of it: what a source is left alone for after a load of it failed
    /// (`LoadLimits.backoff`). A Mac comes to the front at every click on its window.
    static let leftPause = LoadLimits().backoff

    /// When what was left at each host was last gone through, on `clock`.
    @ObservationIgnored private var leftAsked: [String: TimeInterval] = [:]

    /// Time as that pause is counted. A seam, so a test turns the hands itself.
    @ObservationIgnored var clock: any PacerClock = SystemPacerClock()

    /// Which hosts' sources said in their own words that the sign-in held there is over,
    /// noted by the door that heard it (`authorized`).
    @ObservationIgnored private let endings = MastodonEndings()

    /// The ends started from a place that cannot wait for them, one after another.
    @ObservationIgnored private var ending: Task<Void, Never>?

    /// How many earlier sign-ins at each host the source has not yet said it ended — the
    /// journal's owed ones, as this object last read or wrote them. Never read to draw.
    private(set) var owed: [String: Int] = [:]

    /// Hosts whose sign-in this device could not keep and has not been able to file again.
    private(set) var lost: Set<String> = []

    /// Hosts with a journal, as this object last read or wrote one. Never read to draw.
    private(set) var journalled: Set<String> = []

    /// Whether a sign-out, a Clear or a Remove at `host` ends a sign-in at its source: one
    /// held, one this device could not keep, or any it left there.
    func endsSignIns(host raw: String) -> Bool {
        let host = raw.lowercased()
        return grants[host] != nil || lost.contains(host) || journalled.contains(host)
    }

    /// Of the hosts in `ended`, those where this device had left earlier sign-ins, which
    /// are ended with it: the notice says other devices are signed out too.
    private(set) var endedLeft: Set<String> = []

    /// What the person is yet to be told of sign-ins a source was asked to end.
    private(set) var leftTold: [LeftTold] = []

    /// One thing to tell of a source asked to end a sign-in.
    struct LeftTold: Equatable {
        enum Kind: Equatable {
            /// Everything left this device, and the source did not say it ended it all.
            case unconfirmed
            /// The source refused to end an earlier sign-in while one is still held.
            case refused
            /// Earlier sign-ins were another account's than the one now held, and were ended.
            case others
        }

        let kind: Kind
        let host: String
    }

    /// Hosts whose account check found the network dark (#222) — a launch with no network, most
    /// often — and so are asked again as soon as a read gets through to them, rather than going
    /// unknown until a relaunch. `learnWhoAgain(among:)` is that second ask.
    @ObservationIgnored private var unlearned: Set<String> = []

    /// How many times the sign-in held at each host has become another, as this object's
    /// looks found it (#347): kept, widened, narrowed, replaced from outside, ended, signed
    /// out. Never moved by the same sign-in written again.
    ///
    /// **A signal to draw again, and nothing else.** A page drawn for one reader reads it to
    /// know it may no longer be drawn (`ShellPersonPages`); what is let go, asked, kept or
    /// ended is decided by the sign-in itself, looked at where that is done.
    private(set) var changes: [String: Int] = [:]

    /// The mark of the filing of each host's sign-in (`MastodonToken.stamp`) as the last look
    /// that could be had found it — the empty string for one an earlier build filed with
    /// none. Nothing until a look could be had. Read beside the sign-ins, never off a token.
    @ObservationIgnored private var filings: [String: String]?

    /// The mark this build's first note gave a sign-in an earlier build filed with none, a
    /// host each (`name`): written over that very token string, so the sign-in a question
    /// raised before the mark was about (`isSame`).
    @ObservationIgnored private var firstMarks: [String: String] = [:]

    /// Whether a question raised about the sign-in marked `stamp` is about the one `host`
    /// now holds under `held`: the same mark — or none then, and since then the one this
    /// device's own note gave that very sign-in. **A sign-in an earlier build filed is no
    /// other sign-in that has a mark**: one filed since is somebody nobody pressed about.
    func isSame(_ stamp: String?, as held: String?, host: String) -> Bool {
        stamp == held || (stamp == nil && held != nil && firstMarks[host] == held)
    }

    /// Told the folded host each time the sign-in held there has become another, or none
    /// (`changes`), so whoever holds a question about the one before can put it down.
    @ObservationIgnored var onBecameAnother: ((String) -> Void)?

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
    /// **A sign-in made while a token is already held replaces it here, and ends it there
    /// where the new one has less** (#69): a reader narrowing their answer from writing back
    /// to reading who left a write-capable grant live at the server would have been given the
    /// opposite of what they just asked for. So is one not shown to be the same account's.
    ///
    /// **A wider one of the same account leaves it live** (#347). One that holds every word
    /// the token it replaces held, for the account whose id both checks named, leaves that
    /// token live at the source and written down as left (`MastodonLeft`): another device
    /// carrying it goes on working until the person signs out here. A token is noted as made
    /// before it is checked, and put where the held one was only while that one is still the
    /// one held; a note that cannot be taken is a sign-in not kept.
    ///
    /// **Who the reader is comes off the sign-in's own check** (#347), for a sign-in that only
    /// reads as for one that acts: the id and the handle are written with the sign-in in the
    /// one write that keeps it, and the source is asked nothing more for them.
    ///
    /// **No sign-in held is asked for more by this door**: that is `ask`'s, for every part.
    ///
    /// **Notices are never pressed for here** (#323): the sign-in **carries what the one held
    /// has** — so adding the writing part or bookmarks never takes notices away, and a sign-in
    /// with nothing held, or after a sign-out, asks for none.
    ///
    /// **What is carried is what the last look said the sign-in held has** — and only where that
    /// look could not be had, the held token's own scopes, read here — so a look at the Keychain
    /// that failed cannot quietly take notices out of the next sign-in, and a sign-in on a source
    /// with no notices reads nothing it did not read before. A sign-in whose notices were refused
    /// holds none, so it carries none: the next ordinary sign-in asks for what the reader agreed
    /// to and no more, and the refusal goes with the sign-in it was an answer to.
    ///
    /// **A sign-in that carried notices and was refused** — for the writing part, say — says
    /// nothing about notices, and the sign-in held goes on reading them.
    ///
    /// **`noticesSaid` is what the question this answers said of notices**, where one was put:
    /// said to carry none, the sign-in asks for none, whatever the sign-in held has come to
    /// have while the question stood open — the page never asks for what the person was not
    /// told. It only ever narrows: notices are carried where they were said and are still held.
    ///
    /// **What the sign-in held was asked for where it stood is carried too** (#347,
    /// `SignInDrawn`): reading and acting keeps every word of it, so the sign-in that comes
    /// back is a wider one and the one before is left live; reading alone keeps the words
    /// that read and gives up the ones that act — the person's own narrowing, which the
    /// question lists by name before the page opens.
    func signIn(
        host raw: String, through browser: any OAuthBrowser, writing: Bool = false, noticesSaid said: Bool? = nil
    ) async -> MastodonSignInError? {
        guard case .landed(let failure) = await signIn(
            host: raw, through: browser, writing: writing, noticesSaid: said, answering: nil
        ) else { return nil }
        return failure
    }

    /// What answering the read-or-act question came to.
    enum SignInAnswer: Equatable {
        /// What is held is not what the question was drawn from: no page was opened, and the
        /// question is to be put again, from what is held now.
        case changed
        /// The sign-in held became another while the page was up: what came back was not
        /// kept, and nothing held was ended.
        case replaced
        /// The sign-in was gone through; why it did not work, where it did not.
        case landed(MastodonSignInError?)
    }

    /// `signIn`, as the answer to the question `question` — **which is held to what it was
    /// drawn from**: the sign-in it was about, the words that one holds, what it said either
    /// answer ends, and the parts it ticked. Any of them other by the yes — signed out of,
    /// removed, replaced, read back from a package — and no page opens: the page would ask,
    /// or its sign-in end, what the person was not told.
    ///
    /// **What is held is read here from the sign-in itself**, not from what rides beside it,
    /// and nothing is awaited between that look and the page's words being settled. **A
    /// Keychain that cannot be read is said, and opens no page**: nothing can be built from
    /// what cannot be seen, and nothing could be kept after it.
    ///
    /// **A sign-in that cannot be read as one — no value, or one this build cannot decode,
    /// while what rides beside it still says signed in — is held to nothing**: its question
    /// could be drawn from nothing true of it, and putting it again would draw the same. The
    /// page is the one a sign-in holding nothing gets, so signing in again repairs it.
    ///
    /// **And the page's answer is kept only over the sign-in it was built from** (`sign`):
    /// one filed while the registration or the page was up is another the question never
    /// was about.
    func signIn(
        host raw: String, through browser: any OAuthBrowser, writing: Bool, noticesSaid said: Bool?,
        answering question: SignInDrawn?
    ) async -> SignInAnswer {
        let host = raw.lowercased()
        let notices = said != false && carriesNotices(host: host)
        let held: MastodonToken?
        do {
            held = try tokens.token(host: host)
        } catch {
            return .landed(.keychain)
        }
        let now = drawn(
            host: host, held: held?.held, signedIn: held != nil, named: held.flatMap { accountID(of: $0) } != nil,
            notices: notices, ticked: question?.ticked ?? []
        )
        // Signed in by what rides beside it, and no sign-in to be read: held to no question.
        let unreadable = held == nil && grants[host] != nil
        if let question, !unreadable {
            guard now.isWhat(question, wasDrawnFrom: isSame(question.stamp, as: now.stamp, host: host)) else {
                refresh()
                return .changed
            }
        }
        // What the reader's answer asks, and the same with less, a part a sign-in is whole
        // without at a time: without bookmarks, then without search as well — the least.
        let chosen = now.page(writing: writing)
        let narrower = [
            now.page(writing: writing, bookmarks: false),
            now.page(search: false, writing: writing, bookmarks: false),
        ]
        let signed = await sign(host: host, through: browser, for: chosen, orLess: narrower, over: question.map { _ in now })
        return switch signed {
        case .replaced: .replaced
        case .kept, .unsaid, .refusedOnPage: .landed(nil)
        case .hasNone, .stranded: .landed(.invalidScope)
        case .another, .less, .unnamed: .landed(.unreadable)
        case .failed(let error): .landed(error)
        }
    }

    /// What one page, and the keeping of what came back from it, came to.
    private enum Signed {
        /// The sign-in that came back is the one held.
        case kept
        /// Nothing to say: the page was closed, or the person let go of the source meanwhile.
        case unsaid
        /// The person said no on the source's page to a sign-in asked for more where it stood.
        case refusedOnPage
        /// The source would register for none of what was asked.
        case hasNone
        /// The source cannot be asked again this run (`stranded(host:)`).
        case stranded
        /// The page came back as another account's than the one held. Not kept.
        case another
        /// The source answered with less than the sign-in held has. Not kept.
        case less
        /// The source did not say whose the sign-in that came back is. Not kept.
        case unnamed
        /// The sign-in the page was built from was no longer the one held. Not kept.
        case replaced
        case failed(MastodonSignInError)
    }

    /// The sign-in an ask in place widens (#347), as it stood when its page was decided on.
    private struct Place {
        /// The token string held. Anything else held by the time a page comes back, and
        /// what came back is not kept.
        let held: String
        /// Whose it is, as its source said this run.
        let account: String
        /// The parts the page asks for beyond what is held.
        let ticked: Set<MastodonPart>
    }

    /// The body of every sign-in: the registration, the source's page for exactly `chosen`,
    /// the trade, the check, and the keeping — `signIn`'s rules, to the letter.
    ///
    /// **`place` is a sign-in asked for more where it stands** (`ask`). Its page is `chosen`
    /// and nothing less; a no on it is written beside the sign-in held and touches nothing
    /// else; and what comes back is kept only over the very sign-in the ask began with, for
    /// the account that sign-in was confirmed to be.
    ///
    /// **`over` is what the page answering the read-or-act question was built from**
    /// (`signIn`): what comes back is kept only while the sign-in held is still that one —
    /// or still none. Another filed meanwhile was asked nothing, and is neither replaced
    /// nor ended.
    private func sign(
        host: String, through browser: any OAuthBrowser, for chosen: String, orLess narrower: [String],
        place: Place? = nil, over built: SignInDrawn? = nil
    ) async -> Signed {
        signingIn[host, default: 0] += 1
        defer { signingIn[host] = signingIn[host].flatMap { $0 > 1 ? $0 - 1 : nil } }
        if registering.stranded(host) { return .stranded }
        let before = signOuts[host, default: 0]
        // Whether the reader still wants this sign-in: not signed out, cleared or removed since.
        var stillWanted: Bool { signOuts[host, default: 0] == before }
        // Whether the sign-in an ask in place began with is still the one held.
        var stillPlaced: Bool { place.map { self.token(host: host)?.accessToken == $0.held } ?? true }
        let oauth = MastodonOAuth(host: host, sender: WatchedHTTP(sender: sender, for: .signIn, in: work))
        let made: Registration
        do {
            guard let found = try await registration(
                host: host, for: chosen, orLess: narrower, since: before, exactly: place != nil
            ) else { return .unsaid }
            made = found
        } catch let error as MastodonSignInError {
            // Asked in place, a host that has none of a word the sign-in **holds** has not
            // said it has none of what was pressed for.
            if error == .invalidScope, let place, lacksHeld(of: chosen, beyond: place.ticked, at: host) {
                return .failed(error)
            }
            if error == .invalidScope { return .hasNone }
            return error == .cancelled ? .unsaid : .failed(error)
        } catch {
            return .failed(.unreachable)
        }
        // Replaced while the registration was asked for: no page opens about another sign-in.
        guard stillPlaced else { return .unsaid }
        // A part left off a page for want of proof that the host has it was not asked; one the
        // host itself said it has none of was, and the row stops offering it.
        let asked = MastodonRegistration.asked(chosen, on: made.page) { registering.hasNone(of: $0, at: host) }
        var token: MastodonToken
        // Whose sign-in it is, as its own check said: the account's id, and its handle where
        // the source gave it one of its own.
        let account: String?
        let handle: String?
        // Whether the source handed back a token made before this sign-in: somebody's working
        // sign-in, on this device or another, and never ended for not being kept here.
        let handedBack: Bool
        do {
            let signed = try await oauth.signIn(as: made.app, asking: made.page, through: browser) {
                [weak self] issued in try await self?.pend(issued)
            }
            // The page came back and its code was traded: the host knows this registration.
            registering.made(at: host, confirmed: true)
            // A token that failed its check is no sign-in — and may be the one held.
            if let failed = signed.failed {
                if !signed.handedBack { await end(MastodonLeft(signed.token, as: .pending), why: .notKept) }
                throw failed
            }
            // Named as its own check named it, so who it is is written as it is kept: in the
            // one write that keeps it, and only over the sign-in that write expects.
            let issued = signed.token.recorded(asked: asked)
            token = signed.accountID.map { issued.named(accountID: $0, handle: signed.handle) } ?? issued
            account = signed.accountID
            handle = signed.handle
            handedBack = signed.handedBack
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
            guard stillWanted else { return strand || unsaid ? .unsaid : .failed(error) }
            if strand { registering.strand(host) }
            if strand, registering.stranded(host) { return .stranded }
            // The state was checked before the no was read (`MastodonOAuth.code`): it is this
            // page's own answer, and no token was made by it.
            if let place, error == .denied {
                noteRefused(place, asked: made.page, host: host)
                return .refusedOnPage
            }
            return unsaid ? .unsaid : .failed(error)
        } catch {
            return .failed(.unreachable)
        }
        let fresh = MastodonLeft(token, as: .pending, accountID: account)
        guard stillWanted else {
            await discard(fresh, handedBack)
            return .unsaid
        }
        // The sign-in held, which this one takes the place of. **Nothing is awaited between
        // this look and the swap below**, and the swap keeps nothing where another thread
        // has filed a sign-in in between.
        let held: MastodonToken?
        do {
            held = try tokens.token(host: host)
        } catch {
            // What is held cannot be seen, so nothing can be put in its place — or ended.
            await discard(fresh, handedBack)
            return .failed(.keychain)
        }
        // Filed while the registration or the page was up — a package read back: the page
        // was built from another sign-in, and what came back is put over nobody's.
        if let built, !isSame(built.stamp, as: held?.stamp, host: host) {
            await discard(fresh, handedBack)
            return .replaced
        }
        if let place {
            // Signed out and in again, replaced or read back while the page was up: what came
            // back was asked of another sign-in, and is not put over this one.
            guard held?.accessToken == place.held else {
                await discard(fresh, handedBack)
                return .unsaid
            }
            // The source's page signs in afresh each time, so it may come back as somebody
            // else — or as nobody its check names. Only the same account's is kept.
            guard let account else {
                await discard(fresh, handedBack)
                return .unnamed
            }
            guard account == place.account else {
                await discard(fresh, handedBack)
                return .another
            }
        }
        // A server cannot talk this device out of a sign-in it holds: one that answers with
        // fewer of the words asked than the sign-in held has is not kept.
        if let held, !MastodonRegistration.keeps(held.scopes, asking: chosen, in: token.scopes) {
            await discard(fresh, handedBack)
            return .less
        }
        // Asked in place, what the sign-in has been asked is every page's words, this one's
        // among them: the callback came back, so the page was shown.
        if place != nil { token = token.recorded(asked: MastodonParts.union(held?.asked, token.asked)) }
        // The token this one replaces — nothing, where the source handed the held one back.
        let replaced = held.flatMap { fresh.isToken($0) ? nil : $0 }
        // Whose each is, by the id its own check named, and by nothing else. Not known on
        // either side, they are not shown to be one account. **Asked in place, the sign-in
        // held is the account its ask confirmed** (`Place.account`), whatever has been let
        // go of since: it is never ended for want of an id written beside it.
        //
        // **What is written beside a sign-in that rode a package may be the package's word**
        // (`MastodonToken.packaged`): whose such a one is, is only what its source said
        // through it this run.
        let owner = place?.account ?? replaced.flatMap { $0.packaged ? confirmedAccount(of: $0) : accountID(of: $0) }
        let sameAccount = owner != nil && owner == account
        // One that rode a package and whose source has not said whose it is: not shown to
        // be this account's, so no earlier form of the new sign-in — and not shown to be
        // another's, so not ended on a package's word. It is written down as a read back's
        // own are, saying nothing of whose it was, and stays until the person signs out.
        //
        // **Only where it may do nothing the new sign-in cannot.** One that may is ended
        // whoever it is — a narrowing, or another account — so whose it is decides nothing
        // there, and the question said it would end.
        let unsaid = place == nil && owner == nil
            && replaced.map { $0.packaged && !MastodonLeft($0, as: .left).holdsMore(than: token.scopes) } == true
        // Who read this source before, the sign-in handed back as it was included.
        let reader = place?.account ?? held.flatMap { accountID(of: $0) }
        // Left live only where it is the same account's and can do nothing the new one cannot.
        let widening = sameAccount && replaced.map { !MastodonLeft($0, as: .left).holdsMore(than: token.scopes) } == true
        if widening, let replaced {
            // Written down before the new one is kept: a token left with no note of it is one
            // no sign-out here would end.
            do {
                try tokens.journal(MastodonLeft(replaced, as: .left, accountID: owner))
            } catch {
                await discard(fresh, handedBack)
                return .failed(.keychain)
            }
            unended.removeAll { $0.isToken(replaced) }
        }
        if unsaid, let replaced {
            let unnamed = MastodonToken(
                host: host, accessToken: replaced.accessToken, clientID: replaced.clientID,
                clientSecret: replaced.clientSecret, scopes: replaced.scopes
            )
            do {
                try tokens.journal(MastodonLeft(unnamed, as: .replaced))
            } catch {
                await discard(fresh, handedBack)
                return .failed(.keychain)
            }
            unended.removeAll { $0.isToken(replaced) }
        }
        // What the sign-in replaced was refused goes with the account it was refused for.
        // — and stays with a sign-in handed back as it was.
        let filed = sameAccount || replaced == nil ? held.map { token.carrying(refusedFrom: $0.held) } ?? token : token
        var kept = false
        var unkeepable: MastodonLeft?
        do {
            kept = try tokens.swap(expecting: held?.accessToken, with: filed)
        } catch {
            // **The sign-in the reader had, put back before anything is awaited** (#285): a
            // sign-out landing during the wait below would otherwise find nothing to forget
            // or end. A swap that fails has let go of nothing, so there is nothing to put
            // back unless the Keychain lost it all the same.
            if let held { unkeepable = fileAgain(held) }
        }
        guard kept else {
            // Still held, the replaced token is not one left behind.
            if widening || unsaid, let replaced, MastodonLeft(replaced, as: .left).isToken(self.token(host: host)) {
                try? tokens.unjournal(MastodonLeft(replaced, as: .left))
            }
            refresh()
            noteLeft(host)
            await discard(fresh, handedBack)
            if let unkeepable { await end(unkeepable, why: .leftBehind) }
            return .failed(.keychain)
        }
        // Held, it is nothing this device let go of — whatever a sign-out before left unended.
        unended.removeAll { $0.isToken(filed) }
        _ = endings.takeSaid(host)
        // What is held is read again **before the wait below** (#323): a second sign-in started
        // while the server is being asked to forget the old token carries what this one holds,
        // not what the one it replaced did.
        refresh()
        // **Who the reader is, off the check this sign-in has already made** (#347): no ask of
        // its own, whatever the sign-in may do, and no moment after it in which nobody is
        // named. After the look, which lets go of what was known of the sign-in before —
        // **and only where that look found this very sign-in**: one filed from another thread
        // since the swap is nobody until its own source says (`noteFilings`).
        if self.token(host: host)?.accessToken == token.accessToken {
            // Its words are the ones its own trade named, to this device and nobody else.
            wordsConfirmed[host] = token.accessToken
            readers[host] = account.map { Reader(id: $0, handle: handle, accessToken: token.accessToken) }
            handles[host] = handle
            unlearned.remove(host)
            readersLearnt += 1
        }
        // **After the new one is safely kept**, and never a token with the same string (`end`).
        if let replaced, !widening, !unsaid {
            // The read-or-act question says this first (`signInEnds`).
            await end(MastodonLeft(replaced, as: .left, accountID: owner), why: .leftBehind)
        }
        await endLeft(host: host) { left in
            // The one just asked about is not asked twice in one sign-in.
            if let replaced, left.isToken(replaced) { return false }
            // The earlier forms of a sign-in a read back may yet put back go back with it.
            if left.state == .left, self.mayBePutBack(at: host) { return false }
            return switch left.state {
            // One made and never kept is this sign-in's own while it is on its way (`endLeft`).
            case .pending, .owed: true
            // Another account's, or one that may do what the sign-in now held may not.
            case .left, .lost: left.accountID == nil || left.accountID != account || left.holdsMore(than: token.scopes)
            // A read back's own: never while it may yet be put back, and once it has held,
            // by the one rule for them (`settleReplaced`), on what this sign-in's own
            // source has just said of it.
            case .replacing, .replaced: false
            }
        }
        if let account { await settleReplaced(host: host, account: account, words: token.scopes, telling: false) }
        leaveLost(host)
        await endLeft(host: host, beyond: Self.mostLeft)
        noteLeft(host)
        // A fresh sign-in is a fresh answer from the server about what this device may do, so
        // whatever it turned away before this is spent.
        writeRefused.remove(host)
        bookmarkTurnedAway.remove(host)
        noticesTurnedAway.remove(host)
        // What the source would register for none of is no answer about a token: it stands
        // through a sign-in asked for more where it stood, and goes with any other.
        if place == nil { gaveNone[host] = nil }
        registering.signedIn(host)
        refresh()
        // **Not shown to be the reader who was here before** (#285): another account, or one
        // nobody could name on either side — by the id, never by a handle. What the source
        // said that reader had done to its posts is not this one's to be told.
        if reader == nil || reader != account { readersChanged.insert(host) }
        return .kept
    }

    /// Writes down beside the sign-in held that `place`'s parts were refused on the source's
    /// own page, and that the page asked what it asked — **in place, and only while the
    /// sign-in held is still the one the page was about** (`MastodonTokenStore.update`). Never
    /// a save: a no on the page must not be able to cost the sign-in it promised to leave. A
    /// note the Keychain refuses changes nothing, and the part reads as never asked.
    private func noteRefused(_ place: Place, asked page: String, host: String) {
        guard let held = token(host: host), held.accessToken == place.held else { return }
        let note = MastodonToken(
            host: host, accessToken: place.held, clientID: held.clientID, clientSecret: held.clientSecret,
            asked: MastodonParts.union(held.asked, page),
            refused: MastodonParts.union(held.refused, MastodonParts.words(of: place.ticked))
        )
        _ = try? tokens.update(note)
        refresh()
    }

    /// Whether `host` has itself said it has none of a word of `page` that is no part of
    /// `ticked`: a word the sign-in asked in place already holds.
    private func lacksHeld(of page: String, beyond ticked: Set<MastodonPart>, at host: String) -> Bool {
        let pressed = Set(ticked.flatMap { $0.words + $0.wordsBesideActing })
        return page.split(separator: " ").map(String.init)
            .contains { !pressed.contains($0) && registering.hasNone(of: $0, at: host) }
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
    ///
    /// **`exactly` is a page that must ask every word of `chosen`** — a sign-in asked for a
    /// part where it stands: a registration that would carry it only with a word left off
    /// does not serve, since the word left off is the one pressed for.
    private func registration(
        host: String, for chosen: String, orLess narrower: [String], since before: Int, exactly: Bool = false
    ) async throws -> Registration? {
        var stillWanted: Bool { signOuts[host, default: 0] == before }
        // The sign-in held, as its attributes say it. The value itself was read once before
        // this, to build the page from what is held (`signIn`, `ask`) — a read that fails
        // ends there, with no page — and is looked at again once the page's answer is in.
        let held = ((try? tokens.parts()) ?? [:])[host]
        // Whether a page asking `words` leaves the sign-in held every word of it this one asks.
        func keeps(_ words: String) -> Bool { MastodonRegistration.keeps(held?.scopes, asking: chosen, in: words) }
        // The page a registration made for `registered` serves, or nothing where it cannot
        // carry it — or would leave the sign-in held less: such a page's token is one this
        // device then refuses to keep, at every press.
        func paged(_ registered: String?) -> String? {
            let page = exactly
                ? (MastodonRegistration.holds(chosen, on: registered) ? chosen : nil)
                : MastodonRegistration.page(chosen, on: registered)
            return page.flatMap { keeps($0) ? $0 : nil }
        }
        // What is stored now, and the page it serves: where it holds all of `chosen`, was made
        // for exactly `words`, or — everything being no longer tried here — carries a page
        // that takes nothing from the sign-in held.
        func kept(for words: String? = nil) -> (stored: MastodonApp?, page: String?) {
            let stored = (try? tokens.app(host: host)) ?? nil
            guard let stored, let scopes = stored.scopes, let page = paged(scopes) else { return (stored, nil) }
            let carries = !registering.mayTryWhole(host)
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
            let carries = exactly
                ? MastodonRegistration.holds(chosen, on: whole) : MastodonRegistration.page(chosen, on: whole) != nil
            guard carries else { throw MastodonSignInError.invalidScope }
            if paged(whole) != nil { tries.append(whole) }
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
                guard let page = paged(answer.app.scopes) else {
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
    /// What every deadline built here is waited on (`Deadline`) — the word list's wait, and a
    /// door's `within:`: `Task.sleep` but for a test, which turns it by hand.
    @ObservationIgnored var deadlineSleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    /// The host's own list of the scope words it knows, asked once a run and with no sign-in;
    /// nothing where it gave none in time (`MastodonOAuth.listedWords`). Listed among the
    /// run's requests as part of signing in.
    private func listedWords(host: String) async -> Set<String>? {
        if let known = registering.list(host) { return known }
        let watched = WatchedHTTP(sender: SourceReach.wordList(sender), for: .signIn, in: work)
        let asked = MastodonOAuth(host: host, sender: Deadline(watched as any HTTPSender, within: wordListWait, sleep: deadlineSleep))
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
    /// tells it. **A source that refuses the check** — a sign-in without the word that reads
    /// the account is answered 403 — **names nobody**: the sign-in stays, unnamed.
    func learnWho(host raw: String, within limit: Duration? = nil) async {
        let host = raw.lowercased()
        unlearned.remove(host)
        guard let door = authorized(host: host, within: limit, for: .signInCheck) else { return }
        let answered = askingAnswers[host, default: 0]
        do {
            name(door.token, as: try await door.who(), askingAnsweredAt: answered)
        } catch MastodonAuthError.signedOut {
            endedByServer(host: host)
        } catch where DarkNetwork.caused(error) {
            if isSignedIn(host: host) { unlearned.insert(host) }
        } catch {}
    }

    /// Lays what the account check said through `asked` on the sign-in held — **only where
    /// that is still the very sign-in it was asked through** (#347). Looked at after the wait:
    /// a sign-out, a Remove, another sign-in or a package read back meanwhile leaves the
    /// answer on nobody, and what took that sign-in's place is named by its own check.
    ///
    /// **Written beside the sign-in in place** (`MastodonTokenStore.update`), which writes
    /// only over the token string it is handed and cannot lose the sign-in it is a note on;
    /// never a save. Only the id and the handle are named, so everything else held stays as
    /// it is — **and the handle goes with the id**: a check that names the account and no
    /// handle of its own unwrites the one written before. A note the Keychain refuses changes
    /// nothing held, and the reader is still known for this run, by the token the answer came
    /// through.
    ///
    /// **A figure of who asks that a change answered after this check set out stays**
    /// (`askingAnswered`): the check's own is older than it.
    private func name(_ asked: MastodonToken, as who: MastodonWho, askingAnsweredAt answered: Int) {
        let host = asked.host
        guard let held = token(host: host), held.accessToken == asked.accessToken else { return }
        if let id = who.id, held.accountID != id || held.handle != who.handle {
            let note = MastodonToken(
                host: host, accessToken: asked.accessToken, clientID: asked.clientID, clientSecret: asked.clientSecret
            ).named(accountID: id, handle: who.handle)
            // Not written over another string: replaced between the look above and the write.
            if (try? tokens.update(note)) == false { return }
            // A sign-in an earlier build filed is marked by this build's first write beside
            // it: the same sign-in still, and not to be taken for another at the next look.
            if held.stamp == nil, filings?[host] == "", let marked = token(host: host),
               marked.accessToken == asked.accessToken {
                filings?[host] = marked.stamp ?? ""
                firstMarks[host] = marked.stamp
                // What rides beside it is read again, so a question raised from here on
                // carries the mark.
                refresh()
            }
        }
        if who.handle != handles[host] { handles[host] = who.handle }
        let newer = askingAnswers[host, default: 0] != answered ? readers[host].flatMap { $0.id == who.id ? $0.asking : nil } : nil
        readers[host] = who.id.map { Reader(id: $0, handle: who.handle, accessToken: asked.accessToken, asking: newer ?? who.asking) }
        askingChecks[host, default: 0] += 1
        readersLearnt += 1
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
        // A host that has just answered a read is one to ask again to end what it left unended.
        let waiting = Set(unended.map(\.host)).intersection(hosts.map { $0.lowercased() })
        await retryUnended(among: dueAgain(among: waiting))
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
        return mayAsk(.bookmarks, host: host) ? .unasked : .unavailable
    }

    /// How the sign-in at `host` stands to `part` (#347), or nothing where none is held —
    /// **the one answer** a place goes by to offer the part's acts, lock them, or leave them
    /// out. Read off what rides beside the sign-in, never off a token.
    func standing(_ part: MastodonPart, host raw: String) -> MastodonPartStanding? {
        let host = raw.lowercased()
        guard let held = heldParts[host] else { return nil }
        return standing(part, of: held, host: host)
    }

    private func standing(_ part: MastodonPart, of held: MastodonHeld, host: String) -> MastodonPartStanding {
        let standing = MastodonParts.standing(part, of: held)
        let asked = standing == .unasked || standing == .refused
        return asked && gaveNone[host]?.contains(part) == true ? .notGiven : standing
    }

    /// Whether the sign-in at `host` may be asked for `part` where it stands: never asked, or
    /// refused on the source's page — and, for a part that only adds to acting, one that acts.
    ///
    /// **And held in part, for the rest of it** (`MastodonParts.asksRest`) — as signing in
    /// again to read only leaves a part that also acts — unless the source has said this run
    /// that it has none of it.
    func mayAsk(_ part: MastodonPart, host raw: String) -> Bool {
        let host = raw.lowercased()
        guard let held = heldParts[host] else { return false }
        return mayAsk(part, of: held, host: host)
    }

    private func mayAsk(_ part: MastodonPart, of held: MastodonHeld, host: String) -> Bool {
        if part.needsActing, !MastodonParts.holds(.acting, in: held.scopes) { return false }
        let standing = standing(part, of: held, host: host)
        if standing == .partly {
            return MastodonParts.asksRest(part, of: held) && gaveNone[host]?.contains(part) != true
        }
        return standing == .unasked || standing == .refused
    }

    /// What asking a sign-in for more, where it stands, came to (#347).
    enum PartAnswer: Equatable {
        /// The source's page allowed it, and the wider sign-in is the one held.
        case allowed
        /// The page was allowed and the sign-in that came back is the one held — without the
        /// part: the source gave everything else and not that.
        case notGiven
        /// What is held is not what the question was drawn from. No page was opened, and the
        /// question is to be put again, from what is held now.
        case changed
        /// Nothing was asked of the person's sign-in and there is nothing to say: the page
        /// was closed, the sign-in is no longer the one the question was about, or it has
        /// nothing left to be asked for.
        case putDown
        /// The sign-in is still the one asked about, and has nothing left of this to be asked
        /// for: held already, or not one to ask. No page was opened.
        case nothingLeft
        /// Another ask of this source is on its way; this one opened nothing.
        case busy
        /// The person said no on the source's page. Written beside the sign-in.
        case refused
        /// The source has none of it to allow.
        case hasNone
        /// The source has none of some of it, which is noted, and that says nothing of the
        /// rest: no page was opened, and the question is to be put again for the rest alone.
        case hasNoneOfSome
        /// The page signed in another account. Not kept.
        case another
        /// The source answered with less than the sign-in held has. Not kept.
        case less
        /// Whose sign-in this is could not be confirmed, so no page was opened.
        case unconfirmed
        /// The sign-in does not read by the words a page is built over — it holds the
        /// source's one word for every read, or fewer than every word of reading — so no
        /// page can add to it where it stands, now or later. No page was opened.
        case coarse
        /// The page was allowed, and the sign-in that came back named nobody. Not kept.
        case unnamed
        /// The source cannot be asked for this in this run.
        case stranded
        case failed(MastodonSignInError)
    }

    /// Asks the sign-in held at `host` for `ticked`, **where it stands**: the source's own
    /// page for what the sign-in holds and those parts (`MastodonParts.page`), and nothing
    /// signed out, ended or forgotten to ask it. **The one way a held sign-in comes to hold a
    /// further part** (#347).
    ///
    /// **Whatever this answers but `allowed` and `notGiven`, the sign-in held is exactly the
    /// one it was.**
    ///
    /// **Before any page:**
    /// - the sign-in is read as its value says it, not as what rides beside it;
    /// - its account check must have answered with an id through this very token, this run —
    ///   asked now where it has not. The source's page signs in afresh, so only an id tells a
    ///   sign-in that comes back as the same account's from one that is somebody else's;
    /// - its words must be ones this device had from the source this run. Those of a sign-in
    ///   it did not make this run — a package's, an earlier run's — are read from the
    ///   source's own account of the token, and written over what was filed; no such
    ///   account, no page. **An account is believed only where it reads**
    ///   (`MastodonParts.reads`): an empty list, or one without the words every sign-in is
    ///   asked for, is written over nothing;
    /// - it must read by every word of reading (`MastodonParts.reads`), as filed and as its
    ///   source says: the page is built over those words, and one built over a sign-in that
    ///   reads by the source's one word for every read would carry no reading at all;
    /// - each part must still be one to ask (`mayAsk`), and the page must ask a word more
    ///   than is held.
    ///
    /// **`question` is the question the person said yes to**, where one was put: the page
    /// opens only for the sign-in that question was about (`isSame`), and only where it is,
    /// word for word, the page the question was drawn for, gives up exactly what the question said
    /// (`MastodonParts.unknown`), and brings in beside acting exactly the acts the question
    /// named (`MastodonParts.beside`). Held otherwise than the question was drawn from, no page
    /// opens and the answer is `changed`. With none put, a sign-in holding a word this build
    /// does not know is not asked.
    ///
    /// **What is held is read again after every wait**, and what comes back is kept only by
    /// a swap over the token string the ask began with (`sign`).
    func ask(
        _ ticked: Set<MastodonPart>, host raw: String, through browser: any OAuthBrowser,
        answering question: PartAsk? = nil
    ) async -> PartAnswer {
        let host = raw.lowercased()
        guard asking.insert(host).inserted else { return .busy }
        defer { asking.remove(host) }
        let began: MastodonToken
        do {
            guard let held = try tokens.token(host: host) else { return .putDown }
            began = held
        } catch {
            return .failed(.keychain)
        }
        // Another sign-in than the question was about. One from an earlier build that this
        // build's first note has marked since is the same one, and its question stands: the
        // words it named are held to the page below as any question's are.
        if let question, !isSame(question.stamp, as: began.stamp, host: host) { return .putDown }
        // Nothing of it left to ask, as the sign-in is filed: no source is asked to find so.
        guard ticked.contains(where: { mayAsk($0, of: began.held, host: host) }) else { return .nothingLeft }
        if registering.stranded(host) { return .stranded }
        let string = began.accessToken
        var stillHeld: Bool { token(host: host)?.accessToken == string }
        // Whose it is, as its source said through this token this run.
        var confirmed: String? { readers[host].flatMap { $0.accessToken == string ? $0.id : nil } }
        if confirmed == nil {
            await learnWho(host: host)
            guard stillHeld else { return .putDown }
        }
        guard let account = confirmed else { return .unconfirmed }
        if wordsConfirmed[host] != string {
            let watched = WatchedHTTP(sender: SourceReach.wordList(sender), for: .signInCheck, in: work)
            let listed = try? await MastodonOAuth(host: host, sender: watched).words(of: began)
            guard let filed = token(host: host), filed.accessToken == string else { return .putDown }
            guard let listed else { return .unconfirmed }
            let words = MastodonParts.believed(listed, asked: filed.asked)
            // A server cannot talk this device out of what a sign-in holds with a list that
            // is no account of one: nothing is written, and nothing asked. One that names its
            // one word for every read is an account, of a sign-in no page can be built over.
            guard MastodonParts.reads(words) else {
                return MastodonParts.holdsEveryRead(in: words) ? .coarse : .unconfirmed
            }
            if filed.scopes == nil || !MastodonParts.same(words, filed.scopes) {
                let note = MastodonToken(
                    host: host, accessToken: string, clientID: filed.clientID, clientSecret: filed.clientSecret,
                    scopes: words
                )
                do {
                    guard try tokens.update(note) else { return .putDown }
                } catch {
                    return .failed(.keychain)
                }
                refresh()
            }
            wordsConfirmed[host] = string
        }
        guard let held = token(host: host), held.accessToken == string else { return .putDown }
        // A page keeps only the words of reading it knows: a sign-in that reads by another
        // would come back unable to read Home, in the place of the one that can.
        guard MastodonParts.reads(held.scopes) else { return .coarse }
        let wanted = ticked.filter { mayAsk($0, of: held.held, host: host) }
        let page = MastodonParts.page(held: held.scopes, ticked: wanted)
        let more = MastodonParts.more(on: page, than: held.scopes)
        let givesUp = Set(MastodonParts.unknown(in: held.scopes))
        // The page the question was drawn for and no other, whatever the sign-in has turned
        // out to hold: not a word more, not a word the question said it has that it has not.
        if let question {
            let beside = MastodonParts.beside(on: page, than: held.scopes)
            guard MastodonParts.same(page, question.said), givesUp == Set(question.givesUp), beside == question.beside
            else { return .changed }
        }
        guard !wanted.isEmpty, !more.isEmpty else { return .nothingLeft }
        guard question != nil || givesUp.isEmpty else { return .putDown }
        let place = Place(held: string, account: account, ticked: wanted)
        switch await sign(host: host, through: browser, for: page, orLess: [], place: place) {
        case .kept:
            // Kept for holding everything held before — which is not the part pressed for.
            // This answer's fact, and not the host's: nothing is noted of the source.
            let now = token(host: host)?.scopes
            return wanted.allSatisfy { MastodonParts.holds($0, in: now) } ? .allowed : .notGiven
        case .unsaid: return .putDown
        case .refusedOnPage: return .refused
        case .hasNone:
            // Refused for several parts at once, the source has not said it has none of
            // each. Those it named itself are noted — and where it named none, those ticked
            // beside what was pressed for (`PartAsk.with`), never the part pressed for.
            let named = wanted.filter { part in part.words.contains { registering.hasNone(of: $0, at: host) } }
            let beside = wanted.intersection(question?.with ?? [])
            let none = !named.isEmpty ? named : beside.isEmpty ? wanted : beside
            noteNone(of: none, at: host, held: string)
            return none.isSuperset(of: wanted.subtracting(beside)) ? .hasNone : .hasNoneOfSome
        case .stranded: return .stranded
        case .another: return .another
        case .less: return .less
        case .unnamed: return .unnamed
        // Only the answer to the read-or-act question is held to what its page was built from.
        case .replaced: return .putDown
        case .failed(let error): return .failed(error)
        }
    }

    /// A source that would register for none of `parts`: not asked for them again this run,
    /// and — where the source itself said which words it lacks — written beside the sign-in
    /// as asked, in place and only over the token string the ask was about, so the place
    /// stops offering across a relaunch as a sign-in's own answer does.
    private func noteNone(of parts: Set<MastodonPart>, at host: String, held string: String) {
        guard let held = token(host: host), held.accessToken == string else { return }
        gaveNone[host, default: []].formUnion(parts)
        let lacking = MastodonParts.words(of: parts) { registering.hasNone(of: $0, at: host) }
        guard !lacking.isEmpty else { return }
        let note = MastodonToken(
            host: host, accessToken: string, clientID: held.clientID, clientSecret: held.clientSecret,
            asked: MastodonParts.union(held.asked, lacking)
        )
        _ = try? tokens.update(note)
        refresh()
    }

    /// Whether the sign-in on one source may read notices (#323) — beside `bookmarks(host:)`,
    /// and for a sign-in that lacks this, nothing else is changed by it.
    ///
    /// **`unasked` for every sign-in that has not asked**, and here it parts from
    /// `bookmarks(host:)`: reading a notice needs no writing part, so a sign-in to read, one to
    /// read and act, and one kept before either was asked about are all owed the question —
    /// when the reader presses for it, and not before.
    ///
    /// **A source asked in place that has none** is `standing`'s to say (`ask`), and is read
    /// here with the rest. Refused on the source's own page is still `unasked` — asking again
    /// is what changes it — and the page tells the two apart by `standing`.
    func notices(host raw: String) -> NoticeStanding {
        let host = raw.lowercased()
        if noticesGaveNone(host) || standing(.notices, host: host) == .notGiven { return .unavailable }
        if noticeHosts.contains(host) { return .allowed }
        return grants[host] == nil ? .unavailable : .unasked
    }

    /// Whether a source asked for notices gave none: turned a read of them away this run, or
    /// granted the sign-in without them. `host` is folded already.
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
    /// **Every earlier sign-in this device left there goes with it** (#347): the journal
    /// leaves the Keychain with the token, at once, and the source is asked to end each —
    /// the one held first, each whatever the one before was answered. So another device
    /// carrying any of them is signed out too, which the question says first.
    ///
    /// **An end the source does not confirm is not kept to be asked again later.** It is
    /// asked again from memory while the app runs (`retryUnended`), and the person is told
    /// what was not confirmed and what to do about it (`leftTold`). **So is a journal that
    /// cannot be read**: it leaves the device with the rest, nothing in it can be ended,
    /// and that is not passed over in silence.
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
        // A sign-in still on its way is its own to end, once it sees the reader has gone.
        var left: [MastodonLeft] = []
        var unread = false
        do {
            left = try tokens.left(host: host).filter { $0.state != .pending || signingIn[host] == nil }
        } catch {
            unread = true
            NetLog.auth.error("\(NetLog.line("sign-out, earlier sign-ins unread", host: host, error: error), privacy: .public)")
        }
        do {
            try tokens.forget(host: host)
        } catch {
            // The token is still in the Keychain, so the row still reads signed in — `refresh`
            // reads it back rather than claiming a sign-out that did not happen. The server is
            // still asked to forget it.
            NetLog.auth.error("\(NetLog.line("sign-out", host: host, error: error), privacy: .public)")
        }
        do {
            try tokens.forgetLeft(host: host)
        } catch {
            NetLog.auth.error("\(NetLog.line("sign-out, earlier sign-ins", host: host, error: error), privacy: .public)")
        }
        if forgettingApp {
            try? tokens.forgetApp(host: host)
            registering.forget(host)
        }
        writeRefused.remove(host)
        bookmarkTurnedAway.remove(host)
        noticesTurnedAway.remove(host)
        gaveNone[host] = nil
        handles[host] = nil
        _ = endings.takeSaid(host)
        refresh()
        noteLeft(host)
        if unread { tell(.unconfirmed, host: host) }
        if let token { await end(MastodonLeft(token, as: .left), why: .signedOut) }
        for entry in left { await end(entry, why: .leftBehind, forgotten: true) }
    }

    /// Why a source is asked to end a sign-in.
    private enum Ending {
        /// A token a sign-in made and did not keep: ended only where it is neither the one
        /// held nor one written down as left or lost.
        case notKept
        /// One this device no longer uses — replaced by a narrower sign-in or another
        /// account's, left for a sign-in since ended, or owed an end: ended only where it
        /// is not the one held.
        case leftBehind
        /// The person asked for this very sign-in to end — a sign-out, Clear or Remove.
        case signedOut
        /// One asked again from memory: ended only where it is neither the one held nor
        /// written down again since it left this device.
        case unended
    }

    /// Asks a source to end a sign-in — **the one place that does** (#347).
    ///
    /// **A token the person did not ask to end is never ended while it is the one held.** A
    /// server answers the same words on the same registration with the token it already
    /// issued, so a token a sign-in could not keep may be, string for string, the one the row
    /// says the person has: ending it would sign them out behind a row that reads signed in.
    /// **Nor is one not kept ended while it is written down as left or lost, or as one a
    /// read back took out**: handed back the same way, it is a sign-in another device may
    /// be carrying.
    /// What is held and what is journalled are read here, with nothing awaited between the
    /// look and the send, so a token put back or kept a moment ago is seen. Where the
    /// Keychain cannot be read nothing is sent: that can leave a token nobody kept live at
    /// the source, which is rare and better than ending one that is held.
    ///
    /// **The sign-in the person signed out of is ended whatever this device still holds**
    /// (#221): it was read before it was forgotten, and a Keychain that would not delete it, or
    /// cannot be read now, is no reason to leave it live at the source.
    ///
    /// **`forgotten` is an end that came of a sign-out**, as one asked again from memory
    /// and the signed-out sign-in's own are, and as any is that a sign-out overtook while
    /// the source was asked: whatever is answered, nothing of it is written down again.
    ///
    /// What the source answers is written down by `settle`, after the wait.
    private func end(_ left: MastodonLeft, why ending: Ending, forgotten: Bool = false) async {
        let host = left.host
        if ending != .signedOut {
            do {
                if try left.isToken(tokens.token(host: host)) {
                    // The journal is a set by token string: the one held is not in it.
                    try? tokens.unjournal(left)
                    unended.removeAll { $0.isSame(as: left) }
                    return
                }
                if ending == .notKept, try tokens.left(host: host).contains(where: {
                    $0.isSame(as: left) && [MastodonLeft.State.left, .lost, .replacing, .replaced].contains($0.state)
                }) { return }
                // Written down again, it is the journal's to end, and by the journal's rules.
                if ending == .unended, try tokens.left(host: host).contains(where: left.isSame) {
                    unended.removeAll { $0.isSame(as: left) }
                    return
                }
            } catch {
                NetLog.auth.error("\(NetLog.line("end", host: host, error: error), privacy: .public)")
                return
            }
        }
        let since = signOuts[host, default: 0]
        let purpose: SourceWork.Purpose = ending == .signedOut ? .signOut : .signIn
        let answer = await MastodonOAuth(host: host, sender: WatchedHTTP(sender: sender, for: purpose, in: work))
            .revoke(left)
        let overtaken = signOuts[host, default: 0] != since
        settle(left, answered: answer, forgotten: forgotten || overtaken || ending == .signedOut || ending == .unended)
    }

    /// What a source's answer to an end leaves of that sign-in on this device (#347).
    ///
    /// **Read after the wait**: whether a sign-in is held at that host now decides it, not
    /// whether one was when the source was asked.
    ///
    /// - Ended: it leaves the journal.
    /// - Refused for good: it leaves the journal, and the person is told — there is nothing
    ///   more this device can ask.
    /// - No answer, and a sign-in is held there: it stays, owed, and is asked again at the
    ///   next launch and whenever the app comes to the front.
    /// - No answer, and none is held: **nothing waits on a device that shows no sign-in**.
    ///   It leaves the Keychain, is asked again from memory while the app runs, and the
    ///   person is told once.
    /// - No answer to an end that came of a sign-out (`forgotten`): **it never comes back
    ///   to the Keychain**, whoever has signed in there since — the person was told this
    ///   device has forgotten it. It is asked again from memory, as above.
    private func settle(_ left: MastodonLeft, answered: MastodonEnd, forgotten: Bool) {
        let host = left.host
        let held: MastodonToken?
        do {
            held = try tokens.token(host: host)
        } catch {
            return
        }
        let waiting = unended.contains { $0.isSame(as: left) }
        switch answered {
        case .ended:
            try? tokens.unjournal(left)
            unended.removeAll { $0.isSame(as: left) }
        case .refused:
            try? tokens.unjournal(left)
            unended.removeAll { $0.isSame(as: left) }
            tell(held == nil ? .unconfirmed : .refused, host: host)
        case .unanswered:
            // Kept or put back meanwhile, it is the sign-in held and no leaving of this device's.
            if left.isToken(held) {
                unended.removeAll { $0.isSame(as: left) }
            } else if held != nil, !forgotten {
                try? tokens.journal(left.marked(.owed))
                unended.removeAll { $0.isSame(as: left) }
            } else if forgotten, (try? tokens.left(host: host))?.contains(where: left.isSame) == true {
                // Written down again while the source was asked: the journal's, as it stands.
                unended.removeAll { $0.isSame(as: left) }
            } else {
                if !forgotten { try? tokens.unjournal(left) }
                if !waiting {
                    remember(left)
                    tell(.unconfirmed, host: host)
                }
            }
        }
        noteLeft(host)
    }

    /// Keeps `left` to be asked about again from memory — and no more than `mostUnended`
    /// of them: the oldest beyond that is let go of unended, and told as not confirmed.
    private func remember(_ left: MastodonLeft) {
        unended.append(left)
        while unended.count > Self.mostUnended {
            tell(.unconfirmed, host: unended.removeFirst().host)
        }
    }

    private func tell(_ kind: LeftTold.Kind, host: String) {
        let told = LeftTold(kind: kind, host: host)
        if !leftTold.contains(told) { leftTold.append(told) }
    }

    /// The first thing told has been seen.
    func leftToldSeen() {
        if !leftTold.isEmpty { leftTold.removeFirst() }
    }

    /// Lets go of a sign-in that is not kept: the source is asked to end it (`end`), unless
    /// it was shown to be handed back — made before this sign-in, and somebody's to use.
    private func discard(_ fresh: MastodonLeft, _ handedBack: Bool) async {
        if !handedBack { await end(fresh, why: .notKept) }
    }

    /// Notes a sign-in just made, **before its check**, as one to end unless it comes to be
    /// kept: a quit during the check leaves the note for the next launch. Nothing is noted
    /// of a token handed back that is the one held, or one already written down.
    ///
    /// Throws where the note cannot be taken, and the sign-in is then not kept.
    private func pend(_ made: MastodonToken) throws {
        let entry = MastodonLeft(made, as: .pending)
        if entry.isToken(token(host: made.host)) { return }
        guard try !tokens.left(host: made.host).contains(where: entry.isSame) else { return }
        try tokens.journal(entry)
    }

    /// Puts back the sign-in the person held, where a keeping that failed took it from the
    /// Keychain. Where it cannot be put back it is written down as lost, to be filed again
    /// when it can be and ended only when the person signs out; and where not even that
    /// can be written, it is handed back to be ended — nothing stays live at a source that
    /// this device has no way left to end.
    private func fileAgain(_ held: MastodonToken) -> MastodonLeft? {
        do {
            guard try tokens.token(host: held.host) == nil else { return nil }
        } catch {
            return nil
        }
        if (try? tokens.swap(expecting: nil, with: held)) != nil { return nil }
        let account = accountID(of: held)
        do {
            try tokens.journalLost(held, accountID: account)
            return nil
        } catch {
            return MastodonLeft(held, as: .left, accountID: account)
        }
    }

    /// A sign-in written down as lost, where another has just been kept for the same account
    /// with everything it had: it is now one that sign-in took the place of, and left.
    private func leaveLost(_ host: String) {
        for left in (try? tokens.left(host: host)) ?? [] where left.state == .lost {
            try? tokens.journal(left.marked(.left))
        }
    }

    /// Whose sign-in `token` is, by the id its source gives the account: as written down
    /// with it, or as the account check said through that very token this run. Nothing where
    /// nobody has said.
    private func accountID(of token: MastodonToken) -> String? {
        if let id = token.accountID { return id }
        if let reader = readers[token.host], reader.accessToken == token.accessToken { return reader.id }
        return nil
    }

    /// The most sign-ins left at one host: one a part, about, and a bound on what a device
    /// may leave live at a source.
    static let mostLeft = 16

    /// Asks `host` to end each journalled sign-in `due` picks, one at a time. **The journal
    /// is read again after every wait**, so one a sign-out or another sign-in dealt with
    /// meanwhile is not asked about again, and each is asked whatever the one before was
    /// answered. One made by a sign-in still on its way is that sign-in's own.
    private func endLeft(host: String, _ due: (MastodonLeft) -> Bool) async {
        var asked: [MastodonLeft] = []
        while let next = ((try? tokens.left(host: host)) ?? []).first(where: { left in
            due(left) && !(left.state == .pending && signingIn[host] != nil)
                && !asked.contains { $0.isSame(as: left) }
        }) {
            asked.append(next)
            await end(next, why: next.state == .pending ? .notKept : .leftBehind)
        }
    }

    /// Ends the oldest sign-ins left at `host` beyond the `most` newest — those a read back
    /// that held took out counted with them. **None, while a read back there may yet be
    /// undone**: its sign-in goes back with every earlier form of it.
    /// Called only where the sign-in held has just been named by its own source.
    private func endLeft(host: String, beyond most: Int) async {
        let left = ((try? tokens.left(host: host)) ?? []).filter { $0.state == .left || $0.state == .replaced }
        let oldest = left.dropLast(most)
        guard !oldest.isEmpty, !mayBePutBack(at: host) else { return }
        await endLeft(host: host) { entry in oldest.contains { $0.isSame(as: entry) } }
    }

    /// Reads how many sign-ins at `host` are owed an end, and whether one is lost, for the
    /// row to say. Called where this object has just read or written the journal, never to
    /// draw.
    private func noteLeft(_ host: String) {
        guard let entries = try? tokens.left(host: host) else { return }
        let count = entries.count { $0.state == .owed }
        if owed[host, default: 0] != count { owed[host] = count == 0 ? nil : count }
        let isLost = entries.contains { $0.state == .lost }
        if isLost != lost.contains(host) {
            if isLost { lost.insert(host) } else { lost.remove(host) }
        }
        if entries.isEmpty == journalled.contains(host) {
            if entries.isEmpty { journalled.remove(host) } else { journalled.insert(host) }
        }
    }

    /// Goes through what this device left at each source (#347): at launch, and whenever
    /// the app comes to the front.
    ///
    /// **Only where the Keychain could be read.** A locked device ends nothing, restores
    /// nothing and drops nothing: what it cannot read it cannot tell from what is held.
    ///
    /// For each host with a journal, each step whatever the one before came to:
    /// - a sign-in written down as lost is filed again as the one held, where none is;
    /// - with no sign-in held, everything else journalled is asked to end, once — and what
    ///   the source does not confirm leaves the device and is told (`settle`) — **but for
    ///   what a read back took out** (`endsWithNoneHeld`);
    /// - with one held, sign-ins left by another account are ended and said, one made and
    ///   never kept is ended, each one owed is asked again, and what a read back that held
    ///   took out is settled by what the source says of the one now held
    ///   (`confirmReplaced`).
    ///
    /// **Whose the sign-in held is, is what its source said through it this run**, and
    /// nothing written beside it: a package writes there too, and no sign-in is ended as
    /// another account's on a package's word. Not yet said, nothing is ended for it.
    ///
    /// What is owed in memory alone is asked again before any of it.
    ///
    /// **A host gone through is left alone for `leftPause`**, however often the app comes
    /// to the front meanwhile.
    func settleLeft() async {
        guard !settlingLeft else { return }
        settlingLeft = true
        defer { settlingLeft = false }
        refresh()
        tellDropped()
        guard grantsKnown, let hosts = try? tokens.leftHosts() else { return }
        if journalled != hosts { journalled = hosts }
        let due = dueAgain(among: hosts.union(unended.map(\.host)))
        // First, so what this pass itself finds unconfirmed is not asked about twice in it.
        await retryUnended(among: due)
        for host in hosts.sorted() where due.contains(host) {
            if (try? tokens.restoreLost(host: host)) == true { refresh() }
            let held: MastodonToken?
            do {
                held = try tokens.token(host: host)
            } catch {
                // Not gone through, so not left alone for it.
                leftAsked[host] = nil
                continue
            }
            guard let held else {
                await endLeft(host: host) { left in
                    Self.endsWithNoneHeld(left, among: (try? self.tokens.left(host: host)) ?? [])
                }
                noteLeft(host)
                continue
            }
            // While a read back there may yet be undone, the sign-in it took out goes back
            // with every earlier form of it: none is ended as another account's meanwhile.
            if let account = confirmedAccount(of: held), !mayBePutBack(at: host) {
                let others = ((try? tokens.left(host: host)) ?? []).contains { Self.isAnothers($0, than: account) }
                await endLeft(host: host) { Self.isAnothers($0, than: account) }
                if others { tell(.others, host: host) }
            }
            await endLeft(host: host) { $0.state == .pending || $0.state == .owed }
            await confirmReplaced(host: host)
            noteLeft(host)
        }
    }

    /// **Decided by the person (2026-10-13): written down and left, not ended — and still
    /// the one place it is made.** A read back that brought no sign-in for a source this
    /// device was signed in to takes that sign-in off the device and writes it down. With
    /// this `false` it is left as it is: live at the source, written down here, and ended
    /// when the person clears or removes the source, or signs in there again as somebody
    /// else. The other choice was to end it once the read back has held (`true`) — which
    /// signs out every other device carrying it, and so must be said in the read-back
    /// question before it is done. It stays one named switch so that choice remains one
    /// switch and one sentence away.
    static let endsWhatAReadBackLeftBare = false

    /// Whether a sign-in journalled at a host where none is held is asked to end, by a
    /// going-through — `entries` being everything journalled there: never one lost, which
    /// is the person's own; never one a read back may yet put back; and one a read back
    /// that held took out only as `endingBare` says, which is
    /// `endsWhatAReadBackLeftBare` wherever the app asks.
    ///
    /// **The earlier forms of a sign-in a read back took out follow it**: left, they are
    /// not ended while it may yet be put back, and once the read back has held they are
    /// ended only where it is — so the one switch decides for the whole chain.
    static func endsWithNoneHeld(
        _ left: MastodonLeft, among entries: [MastodonLeft], endingBare: Bool = endsWhatAReadBackLeftBare
    ) -> Bool {
        switch left.state {
        case .lost, .replacing: return false
        case .replaced: return endingBare
        case .left:
            if entries.contains(where: { $0.state == .replacing }) { return false }
            return entries.contains { $0.state == .replaced } ? endingBare : true
        case .pending, .owed: return true
        }
    }

    /// Whether a read back took a sign-in out at `host` and may yet put it back — it has
    /// not held, or its undo waits on a locked device. Where what was left there cannot be
    /// read, it may.
    private func mayBePutBack(at host: String) -> Bool {
        guard let entries = try? tokens.left(host: host) else { return true }
        return entries.contains { $0.state == .replacing }
    }

    /// Whose sign-in `token` is, as its source said through that very token this run —
    /// and by nothing written beside it. Nothing where the source has not been heard.
    private func confirmedAccount(of token: MastodonToken) -> String? {
        readers[token.host].flatMap { $0.accessToken == token.accessToken ? $0.id : nil }
    }

    /// Settles what a read back that held took out at `host`, where a sign-in is held
    /// there now (#347) — **on its source's own word and no other**: whose the sign-in
    /// held is, asked now where this run has not heard, and what it holds, read from the
    /// source's own account of the token. Until both are had nothing is ended and nothing
    /// is called an earlier form of the one held: what the package said of either decides
    /// nothing, and the next going-through asks again.
    ///
    /// **The source's list is taken whole**, not cut to what the sign-in is filed as having
    /// asked — a package's word too, which could make the one held look to hold less. And
    /// only a list that reads word by word (`MastodonParts.reads`) is gone by: against the
    /// source's one word for every read nothing can be shown to do more. Nothing is
    /// written beside the sign-in here.
    private func confirmReplaced(host: String) async {
        guard ((try? tokens.left(host: host)) ?? []).contains(where: { $0.state == .replaced }),
              let held = token(host: host)
        else { return }
        if confirmedAccount(of: held) == nil { await learnWho(host: host) }
        guard let asked = token(host: host), asked.accessToken == held.accessToken,
              let account = confirmedAccount(of: asked)
        else { return }
        let watched = WatchedHTTP(sender: SourceReach.wordList(sender), for: .signInCheck, in: work)
        guard let listed = try? await MastodonOAuth(host: host, sender: watched).words(of: asked),
              token(host: host)?.accessToken == held.accessToken
        else { return }
        let words = MastodonParts.believed(listed, asked: nil)
        guard MastodonParts.reads(words) else { return }
        await settleReplaced(host: host, account: account, words: words, telling: true)
        // The bound on what is left is kept here and at a sign-in, where the source has
        // answered. A source that never gives a usable list is never asked to end one for
        // it, so read backs over a sign-in there can leave more than `mostLeft` written
        // down, each until the person signs out: accepted, and better than ending on no word.
        await endLeft(host: host, beyond: Self.mostLeft)
    }

    /// What becomes of each sign-in a read back that held took out at `host`, now that the
    /// source has said the one held is `account`'s and holds `words`:
    /// - another account's is ended, and said where `telling`;
    /// - the same account's that may do what the one held may not is ended;
    /// - the same account's otherwise is an earlier form of the one held, and left.
    ///
    /// **One that says nothing of whose it was stays as it is**: it cannot be shown to be
    /// another's or the same one's, so it is neither ended nor called an earlier form —
    /// written down until the person signs out, clears or removes, which ends it.
    private func settleReplaced(host: String, account: String, words: String?, telling: Bool) async {
        func over(_ left: MastodonLeft) -> Bool {
            guard left.state == .replaced, let owner = left.accountID else { return false }
            return owner != account || left.holdsMore(than: words)
        }
        let others = ((try? tokens.left(host: host)) ?? []).contains {
            $0.state == .replaced && $0.accountID != nil && $0.accountID != account
        }
        await endLeft(host: host, over)
        if others, telling { tell(.others, host: host) }
        for left in (try? tokens.left(host: host)) ?? []
            where left.state == .replaced && left.accountID == account && !left.holdsMore(than: words) {
            try? tokens.journal(left.marked(.left))
        }
    }

    /// Whether `left` is a sign-in left by an account other than `account`: only where it
    /// says whose it was. A chain that is not the held account's is ended and never added
    /// to. What a read back took out is no part of it (`settleReplaced`).
    private static func isAnothers(_ left: MastodonLeft, than account: String) -> Bool {
        left.state == .left && left.accountID != nil && left.accountID != account
    }

    /// Asks again to end what was not confirmed after it left this device, at `hosts`. One
    /// that has since come to be the sign-in held is the person's again, and one written
    /// down again is the journal's: `end` looks for both just before it asks, and asks
    /// nothing about either.
    private func retryUnended(among hosts: Set<String>) async {
        for left in unended where hosts.contains(left.host) {
            guard unended.contains(where: left.isSame) else { continue }
            await end(left, why: .unended)
        }
    }

    /// Those of `hosts` not gone through within `leftPause`, noted as gone through now.
    private func dueAgain(among hosts: Set<String>) -> Set<String> {
        let moment = clock.elapsed()
        let due = hosts.filter { host in leftAsked[host].map { moment - $0 >= Self.leftPause } ?? true }
        for host in due { leftAsked[host] = moment }
        return due
    }

    /// The app has come to the front: who is signed in is read again — a Keychain read at
    /// launch on a locked device finds nothing — and what was left at each source is gone
    /// through, now that it can be read. **One going-through runs and one waits**: a
    /// coming to the front while one already waits lines up nothing more.
    func cameToFront() {
        refresh()
        guard !frontWaiting else { return }
        frontWaiting = true
        after {
            $0.frontWaiting = false
            await $0.settleLeft()
        }
    }

    /// A package was read back (#347): who is signed in is read again, and what the read
    /// back took out where it put a sign-in is settled now, not at the next launch
    /// (`confirmReplaced`) — on what each source answers of the sign-in now held.
    ///
    /// **Only the sources the read back took a sign-in out at are asked anything**, and of
    /// those only where one is held now: what it took out with nothing put in its place
    /// stays written down (`endsWhatAReadBackLeftBare`).
    func readBack() {
        refresh()
        guard grantsKnown, let hosts = try? tokens.leftHosts() else { return }
        let touched = hosts.filter { host in
            grants[host] != nil && ((try? tokens.left(host: host)) ?? []).contains { $0.state == .replaced }
        }
        for host in hosts { noteLeft(host) }
        guard !touched.isEmpty else { return }
        after { sessions in
            for host in touched.sorted() {
                await sessions.confirmReplaced(host: host)
                sessions.noteLeft(host)
            }
        }
    }

    /// Runs `work` after whatever was started here before it, without being waited for.
    private func after(_ work: @escaping @MainActor (MastodonSessions) async -> Void) {
        let before = ending
        ending = Task { [weak self] in
            await before?.value
            guard let self else { return }
            await work(self)
        }
    }

    /// Waits for every end started without being waited for.
    func leftSettled() async {
        await ending?.value
    }

    /// What Account says under a source's row of the sign-ins this device left there:
    /// that the one it held could not be kept, or how many the source has not yet ended.
    func leftLine(host raw: String, language: DummyLanguage? = nil) -> String? {
        let host = raw.lowercased()
        if lost.contains(host), grants[host] == nil {
            return String(format: L10n.t("account.mastodon.failed.keychain", language: language), host)
        }
        guard let count = owed[host], grants[host] != nil else { return nil }
        let one = L10n.t("account.left.owed.one", language: language)
        let format = count == 1 && one != "account.left.owed.one" ? one : L10n.t("account.left.owed", language: language)
        return String(format: format, count, host)
    }

    /// What answering the read-or-act question may end of the sign-in held.
    enum SignInEnds: Equatable {
        /// Reading alone asks for less than is held; so does another account.
        case reading
        /// Either answer: what is held, or whose it is, cannot be shown to be kept.
        case either
        /// Only signing in as another account.
        case another
    }

    /// What the read-or-act question about `host` must say first of the sign-in held:
    /// which answer ends it at the source, and with it every other device carrying it.
    /// Nothing where none is held. Read as `signInDrawn` reads it.
    func signInEnds(host raw: String, notices: Bool) -> SignInEnds? {
        signInDrawn(host: raw, notices: notices).ends
    }

    /// What the read-or-act question about `host` is drawn from (`SignInDrawn`): the sign-in
    /// held, as what rides beside it says, `notices` where the sign-in asked for carries
    /// them, and `ticked` beside either answer.
    ///
    /// **Whose it is, is read as the keeping reads it** (`reader`): written down with the
    /// sign-in, or said through it this run. So a sign-in the question says an answer
    /// leaves live is one that answer leaves live, with or without a network since launch.
    func signInDrawn(host raw: String, notices: Bool, ticking ticked: Set<MastodonPart> = []) -> SignInDrawn {
        let host = raw.lowercased()
        let held = ((try? tokens.parts()) ?? [:])[host]
        return drawn(
            host: host, held: held, signedIn: grants[host] != nil, named: reader(host: host) != nil, notices: notices,
            ticked: ticked
        )
    }

    /// The pages signing in again at `host` would put over `held`, and which answer ends
    /// the sign-in held — **the one reading the question is drawn from and its yes is held
    /// to**, whether `held` was read beside the sign-in or from it.
    ///
    /// An answer ends the sign-in held where the one it leads to lacks a word of it; and
    /// either does where what is held, or whose it is, is not known: only a sign-in shown
    /// to be the same account's, holding everything the one before did, leaves it live.
    ///
    /// **`named` is whether whose it is is known as the keeping knows it** (`accountID(of:)`,
    /// which is what `sign` leaves a sign-in live by): the one rule, here and there.
    private func drawn(
        host: String, held: MastodonHeld?, signedIn: Bool, named: Bool, notices: Bool, ticked: Set<MastodonPart>
    ) -> SignInDrawn {
        var drawn = SignInDrawn(
            host: host, stamp: signedIn ? held?.stamp : nil, scopes: signedIn ? held?.scopes : nil,
            carried: signedIn ? MastodonParts.carried(of: held, beside: MastodonOAuth.chosen) : nil,
            notices: notices, ticked: ticked
        )
        guard signedIn else { return drawn }
        guard let words = held?.scopes, named else {
            drawn.ends = .either
            return drawn
        }
        let read = MastodonRegistration.holds(words, on: drawn.page(writing: false))
        let act = MastodonRegistration.holds(words, on: drawn.page(writing: true))
        drawn.ends = act ? (read ? .another : .reading) : .either
        return drawn
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
        let wire: any HTTPSender = limit.map { Deadline(watched as any HTTPSender, within: $0, sleep: deadlineSleep) } ?? watched
        return MastodonAuthorized(token: token, sender: wire, store: tokens, endings: endings)
    }

    /// A request answered `.signedOut`: the token is already gone, so the row and the reader are
    /// told.
    func endedByServer(host raw: String) {
        let host = raw.lowercased()
        refresh()
        if !ended.contains(host) { ended.append(host) }
        onEnded?(host)
        tellDropped()
        endLeftOfEnded(host)
    }

    /// Tells of each host where a 401 that was not the source's own took the sign-ins left
    /// there off this device unended (`MastodonTokenStore.forget(_:saidBySource:)`): done in
    /// the store with the forgetting, so all that is left to do here is say so.
    private func tellDropped() {
        for host in endings.takeDropped().sorted() {
            noteLeft(host)
            tell(.unconfirmed, host: host)
        }
    }

    /// The sign-ins this device left for one its source has ended are ended at once (#347):
    /// nothing is kept, unseen, on a device that shows no sign-in. The notice says other
    /// devices carrying an earlier form are signed out too. Never where a sign-in is held
    /// there again, whose own keeping dealt with what was left.
    ///
    /// **Only where the source said so in its own words** (`MastodonEndings`). A 401 that
    /// is anything else — a page, a password asked for by something in front of the source
    /// — still takes the sign-in held off this device, as it always has, and **ends
    /// nothing**: what was left went from the device unended in the store's own step, so
    /// nothing that goes through the journal ends it either, and the person is told
    /// (`tellDropped`).
    private func endLeftOfEnded(_ host: String) {
        guard endings.takeSaid(host), grantsKnown, grants[host] == nil,
              let left = try? tokens.left(host: host), left.contains(where: { $0.state == .left }),
              // The earlier forms of a sign-in a read back took out follow it: not ended
              // while it may yet be put back, nor while it stands written down as replaced.
              !left.contains(where: { $0.state == .replacing || $0.state == .replaced })
        else { return }
        endedLeft.insert(host)
        after { await $0.endLeft(host: host) { $0.state == .left || $0.state == .owed } }
    }

    /// At launch: asks each server whether it still honours its token. Only a 401 signs out; a
    /// server that cannot be reached leaves the sign-in as it was, and is asked again by the first
    /// read that reaches it (`learnWhoAgain`).
    ///
    /// **The same answer says who the reader is there** (#109), so asking it is not a second
    /// request: `learnWho` reads the account check's own body.
    ///
    /// **The sign-ins held first, then what was left** (#347, `settleLeft`): a sign-in the
    /// source has ended is known before anything left for it is gone through.
    public func verifyAll() async {
        if grantsKnown {
            for host in (try? tokens.leftHosts()) ?? [] where (try? tokens.restoreLost(host: host)) == true {
                refresh()
            }
        }
        for host in grants.keys.sorted() {
            await learnWho(host: host)
        }
        await leftSettled()
        // The launch's own going-through waits on no pause: who is signed in was only now asked.
        leftAsked = [:]
        await settleLeft()
    }

    func endedSeen() {
        ended = []
        endedLeft = []
    }

    /// Sets the filings a look has just found against the ones the look before found, and
    /// counts each host whose sign-in has become another (`changes`): one filed, one gone, or
    /// one under another mark — the mark is made when a token string is first filed and
    /// carried through every later write of that string, so this turns on the string and no
    /// token is read for it.
    ///
    /// **What was known of the sign-in before is not laid on the next**: the reader's handle
    /// goes, and so does this device's having heard its words from its source. Where one
    /// sign-in took another's place the source is asked who reads it now by
    /// the first read that reaches it (`learnWhoAgain`) — a sign-in made here has said
    /// already, and takes itself off that list.
    ///
    /// The first look only notes: nothing was drawn before it.
    private func noteFilings(_ found: [String: String]) {
        defer { filings = found }
        guard let before = filings else { return }
        for host in Set(before.keys).union(found.keys) where before[host] != found[host] {
            changes[host, default: 0] += 1
            handles[host] = nil
            readers[host] = nil
            // Nor its words: a package may file the very string held, saying other of it.
            wordsConfirmed[host] = nil
            if before[host] != nil, found[host] != nil { unlearned.insert(host) }
            onBecameAnother?(host)
        }
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
        if read != nil, let parts = try? tokens.parts() {
            noteFilings(Dictionary(uniqueKeysWithValues: grants.keys.map { ($0, parts[$0]?.stamp ?? "") }))
            let held = parts.filter { grants[$0.key] != nil }
            if held != heldParts { heldParts = held }
        }
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
        // Who the reader is goes with the sign-in it was learnt through — where the look could
        // be had: one a locked device refused is not a sign-out, and lets go of nobody.
        guard read != nil else { return }
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
