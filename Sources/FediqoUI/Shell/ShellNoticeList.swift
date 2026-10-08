import FediqoCore
import Foundation
import Observation

// What every signed-in source says happened to the reader, as one list (#323).
//
// **Read when somebody asks, and never on a timer**: the page opening, its reload mark, a pull
// (`read`), the foot of the list reached or pressed (`readOn`), and a press on a source named
// as failed (`retry`). Nothing here starts by itself, and nothing is asked while the page is
// closed.
//
// **Held in memory and nowhere else.** A notice is not an item: nothing here reaches the store,
// so a read that fails or is refused has nothing on this device to undo, and after a relaunch
// the list is empty until its first read.
//
// **Several sources, each read to its own depth, drawn as one list without hiding a gap.**
// `LatestDate`'s rule the other way up — there, posts newer than the chosen day stay held and
// are only not shown. Here each source has reached down to the moment of the oldest notice read
// from it, and the list stops at the *latest* of those moments among the sources that still
// have more (`floor`): below it, a source not yet asked that far down may have something that
// belongs above what another has already handed over. So an older notice stays held and is not
// shown until reading on has brought every source down past it.
//
// **And nothing drawn is taken back by a source answering late.** While a source's first
// stretch is on the wire nobody knows where it will stop the list, so what is drawn stays as
// it was — nothing at all, on the first read of a run — until every source asked has answered
// or failed. After that the list only grows downward, but for a source read again from the top
// that answers with a stretch joined to nothing held: a real gap, said by cutting there.

/// Every signed-in source's notices, for as long as this run wants them.
///
/// On the session for `ShellConversations`' reason: what the page draws and what a sign-out or a
/// Clear lets go of have to be the same object. (`ShellNotice` is the empty-page view; this name
/// keeps clear of it.)
@MainActor
@Observable
final class ShellNoticeList {
    /// Why a source's notices could not be had — `ShellConversations.Absence`'s two that apply:
    /// there is always a source to ask here.
    enum Absence: Equatable, Sendable {
        /// The source answered and said this sign-in may not: a 401 it stood by, a 403.
        case refused
        /// Nothing answered, the source answered with a failure of its own or of the asking —
        /// too many requests among them — or with nothing this device could read as notices.
        case unreachable
    }

    /// Where the read of one source stands.
    enum Standing: Equatable, Sendable {
        /// Nothing has asked yet.
        case unread
        /// On the wire.
        case reading
        /// The source answered.
        case read
        /// The last ask did not come back, and why. What it had handed over before stays held.
        case failed(Absence)
    }

    /// What one source has handed over, and how far down that goes.
    struct Reach: Equatable, Sendable {
        /// Newest first, as the source handed them over, a line that came twice folded into one.
        var notices: [Notice] = []
        /// The id the next, older stretch is asked before. Nothing where the source has no more,
        /// or has not answered yet.
        var before: String?
        /// Which read this source answers with, remembered for the run so it is asked one way.
        var gathered: Bool?
        var standing: Standing = .unread
        /// Whether this source has answered at all this run: which read it answers with is
        /// known. One that has not, and is on the wire, is on its first stretch.
        var answered: Bool { gathered != nil }
        /// Whether the ask on the wire, or the one that failed, was for an older stretch and
        /// not the newest — what asking that source again asks for.
        var readingOn = false

        /// The moment this source has been read down to: the oldest moment any stretch read of
        /// it named. **Kept as each stretch lands, and not read off the lines held** — a
        /// gathered line stands at its newest notice wherever the source cut it, so a line that
        /// came again further down, or gained a notice at the top, says nothing of how far down
        /// the reading went.
        var reached: Date?

        /// Where this source stops the list: the moment it has reached, while it has more below.
        ///
        /// **Whether or not its last ask came back.** A source that failed has still not been
        /// asked below its reach, so a line drawn under that would stand below a stretch nobody
        /// has read; it is named as failed and holds the list where it stood, until it is
        /// asked again by name. One with no more to give holds nothing.
        ///
        /// **Not a source that can no longer be asked** — refused, or its sign-in no longer
        /// one that may read notices. Nothing would ever bring it further down, and holding
        /// the list there would stop every other source being read on for the rest of the
        /// run. It stays named, with what it had read, and the name is what says its older
        /// stretch is missing.
        ///
        /// **A source that has more and nothing this device could read** — a stretch whose
        /// every entry was past this build — has reached no moment it can name, and holds
        /// nothing: it cannot say where the list should stop. It is the first asked by
        /// reading on, which goes past the stretch it could not read.
        var holds: Date? { askable && before != nil ? reached : nil }

        /// Whether this source's sign-in may still be asked for notices, as `settle(in:)` last
        /// found it. **What decides whether it holds the list, and not the word its failure
        /// was named with**: a source that answered 401 or 403 and may still be asked is asked
        /// again by name, and holds the list until then.
        var askable = true

        /// This reach with one more moment a stretch named.
        mutating func reach(to moment: Date?) {
            reached = [reached, moment].compactMap { $0 }.min()
        }

        /// Whether nobody knows yet where this source will stop the list.
        var isOnFirstStretch: Bool { standing == .reading && !answered }

        /// Whether this source has handed over as many lines as are held of one for a run
        /// (`capacity`): it is not read on, and the foot says why. A read from the top that is
        /// joined to nothing held starts it again.
        var full = false

        /// This reach kept to `capacity` lines: the newest of them, and **reading on ended
        /// for it** where there are more — lines past the bound, or a source that has more to
        /// give. A source read to its own end at exactly the bound is not full; it has no more.
        mutating func bound(to capacity: Int) {
            guard notices.count > capacity || (notices.count == capacity && before != nil) else { return }
            notices = Array(notices.prefix(capacity))
            before = nil
            full = true
        }

        /// This reach once its source has dismissed everything it had: nothing held, and
        /// nothing older to read on to.
        mutating func empty() {
            notices = []
            before = nil
            reached = nil
            full = false
        }
    }

    /// How many lines are held of one source for a run. Nothing here is kept between runs and
    /// nothing lets a line go by age, so without a bound a source read on and on — or one that
    /// answers every ask with more — is held whole. Thousands of lines is months of a busy
    /// account; past it the foot says the limit was reached, and a reload still reads the newest.
    static let capacity = 2_000

    /// `capacity`, where a test wants a bound it can reach.
    @ObservationIgnored var capacity = ShellNoticeList.capacity

    /// Each source's notices, by its folded host.
    private(set) var reaches: [String: Reach] = [:]
    /// What the page draws: every source's notices at or after `floor`, newest first, less
    /// the lines an act the person said yes to is taking away (`ShellNoticeActs.hidden`) —
    /// each still held in `reaches`, and drawn again where it was if its source says no. Left as
    /// it was while a source's first stretch is on the wire — **so one source that does not
    /// answer keeps a first read blank until its request ends at `deadline`**, and twice that
    /// where its gathered read answered 404 slowly and the single read then hangs. The page
    /// says who is on the wire meanwhile (`readingHosts`).
    private(set) var lines: [Notice] = []
    /// Where the list stops: the latest moment every source that has more has been read down
    /// to. Nothing where every source has handed over all it has, and then everything is shown.
    private(set) var floor: Date?
    /// Hosts whose token could not be read at the last ask — a locked Keychain. Reading on
    /// leaves them be until a read from the top finds the token again.
    private(set) var locked: Set<String> = []

    /// How long one request may take before the source counts as unreachable. `ShellReload`
    /// says the same in the same words.
    @ObservationIgnored var deadline: Duration = .seconds(30)

    /// The read on the wire: which hosts it set out to ask where it reads from the top, and
    /// what each source held before it — put back where the read is stopped rather than answered.
    @ObservationIgnored private var work: (task: Task<Void, Never>, fromTop: Set<String>?, was: [String: Reach])?
    /// The hosts whose answer the read on the wire still waits for. One let go of meanwhile is
    /// taken out, and its answer lands nowhere.
    @ObservationIgnored private var asking: Set<String> = []
    /// Counts the reads started and stopped, so an answer to one that was stopped is dropped.
    @ObservationIgnored private var generation = 0
    /// The lines each source has dismissed, by host and line, each with the moment its
    /// source's yes landed here in the run's order of reads (`ReadMoment`) — #291's guard, for
    /// notices: a stretch sent before that moment was asked for before the dismissal and may
    /// still name the line, so the line is left out of it; one sent after is the source's
    /// later word. A mark goes once a later-sent stretch of its source has landed.
    ///
    /// **The moment is when the yes landed here, which is later than when the source acted.**
    /// A read sent in between was answered after the dismissal and is still weighed as before
    /// it: where it names a new notice under the same group key, that line is left out until
    /// the next read — and after dismissing all, so are the lines that arrived in between.
    /// Accepted: the other way round a line the source dismissed would be drawn, and nothing
    /// here knows when the source acted.
    @ObservationIgnored private var struck: [String: [String: UInt64]] = [:]
    /// The same, for a source that dismissed everything it had: a stretch sent before that
    /// moment is not taken.
    @ObservationIgnored private var emptied: [String: UInt64] = [:]
    /// What `cut` last said is the list, with nothing an act is taking away left out. Kept so
    /// that a line whose act failed is drawn again where it was, even while what is drawn is
    /// held still for a source's first stretch.
    @ObservationIgnored private var whole: [Notice] = []
    /// The lines that left what is drawn at a yes of the person's, each until it is drawn
    /// again: what the lamp is moved by (`leftAtYes`). **Taken at the yes and not asked for
    /// afterwards** — by the time the page has drawn, the source may have answered and the
    /// line be struck, and nothing held would say any more why it went.
    @ObservationIgnored private var pressed: Set<String> = []

    /// The acts on what is listed, and what each source holds back. Beside the list because
    /// what an act has on its way is left out of what is drawn here, a line leaves what is
    /// held only on its source's answer, and a sign-out lets go of both at once.
    @ObservationIgnored let acts = ShellNoticeActs()

    /// One source asked for one stretch.
    private struct Ask: Sendable {
        let source: Source
        let before: String?
        let gathered: Bool?

        var host: String { source.host.lowercased() }
    }

    // MARK: - What the page reads

    /// Whether any source is being asked right now.
    var isReading: Bool { !readingHosts.isEmpty }

    /// The sources on the wire, in host order.
    var readingHosts: [String] {
        reaches.filter { $0.value.standing == .reading }.keys.sorted()
    }

    /// The sources whose last ask did not come back, in host order, and why — named above the
    /// list while the others' notices stand in it.
    var failures: [(host: String, why: Absence)] {
        reaches.compactMap { host, reach -> (host: String, why: Absence)? in
            if case .failed(let why) = reach.standing { (host, why) } else { nil }
        }.sorted { $0.host < $1.host }
    }

    func standing(host: String) -> Standing {
        reaches[host.lowercased()]?.standing ?? .unread
    }

    /// Whether reading on would ask anybody: what the foot of the list says and presses. The
    /// one answer `readOn` goes by, so a foot is never drawn that asks nobody.
    func hasMore(in session: ShellSession) -> Bool {
        !isReading && !due(in: session).isEmpty
    }

    /// Whether a source is held to `capacity` and read on no further: what the foot says where
    /// it would otherwise say every source has handed over all it has.
    var isFull: Bool { reaches.values.contains(where: \.full) }

    /// The sources held to `capacity`, in host order: named above the list from the moment
    /// they are. **A full source does not hold the list** (`Reach.holds`) — it would stop every
    /// other source being read on for the rest of the run — so another's older lines may stand
    /// below a stretch of its own that is not shown, and its name is what says so.
    var fullHosts: [String] {
        reaches.filter(\.value.full).keys.sorted()
    }

    /// `lines` without the kinds the reader narrowed away (`DummyPrefs.noticesHidden`). Done
    /// here at the draw, and no source is asked anything for it: what each has been read down
    /// to does not depend on what is shown.
    func shown(hiding hidden: Set<String>) -> [Notice] {
        hidden.isEmpty ? lines : lines.filter { !hidden.contains($0.kind.narrowedAs) }
    }

    /// The sources the page asks: those of a kind that has notices, whose sign-in may read
    /// them. **A source merely signed in is not asked** — a sign-in never asked for notices
    /// would only be refused, and nothing here provokes that.
    static func asked(in session: ShellSession) -> [Source] {
        session.sources.filter { $0.kind.offers.notices && session.mastodon.notices(host: $0.host) == .allowed }
    }

    // MARK: - Reading

    /// Every source's newest stretch: the page opening, its reload mark, a pull.
    ///
    /// **What a source answers is joined to what it had, where the two meet** — a line of the
    /// new stretch already held — so coming back to the page keeps how far down it was read.
    /// Where they do not meet there is a stretch between them nobody has read, and what the
    /// source had is replaced by what it answers now. A source that does not answer keeps what
    /// it had and is named.
    ///
    /// A second call while one is on the wire waits on that one, and reads again only where a
    /// source may be asked now that it did not ask. A reading on still out is ended first.
    func read(in session: ShellSession) async {
        if let work, let set = work.fromTop {
            await work.task.value
            let now = Set(Self.asked(in: session).map { $0.host.lowercased() })
            if !now.isSubset(of: set), !Task.isCancelled { await read(in: session) }
            return
        }
        stop()
        settle(in: session)
        let asks = Self.asked(in: session).map {
            Ask(source: $0, before: nil, gathered: reaches[$0.host.lowercased()]?.gathered)
        }
        locked = []
        await run(asks, fromTop: Set(asks.map(\.host)), in: session)
    }

    /// The next, older stretch: the foot of the list reached or pressed.
    ///
    /// **Asked only of the sources standing at the floor** — those the list stops at. One read
    /// further down already is not asked again until the others have caught up with it, and one
    /// that failed is asked again by `retry`, not here, so a dark network is not asked over and
    /// over by a foot in view. Nothing while another read is on the wire.
    func readOn(in session: ShellSession) async {
        guard work == nil else { return }
        settle(in: session)
        await run(due(in: session), fromTop: nil, in: session)
    }

    /// What is held brought into line with who may be asked now, before anybody is asked and
    /// as each answer lands. A source that left, or whose sign-in did, by a way that told
    /// nobody here is let go of. One still signed in whose sign-in may no longer read notices
    /// is named as refused: it keeps what it had read and stops holding the list (`Reach.holds`).
    private func settle(in session: ShellSession) {
        let here = Set(session.sources.map { $0.host.lowercased() }).intersection(session.mastodon.signedInHosts)
        let askable = Set(Self.asked(in: session).map { $0.host.lowercased() })
        for (host, reach) in reaches {
            guard here.contains(host) else {
                forget(host: host)
                continue
            }
            let may = askable.contains(host)
            if reach.askable != may { reaches[host]?.askable = may }
            if !may, reach.standing != .reading, reach.standing != .failed(.refused) {
                reaches[host]?.standing = .failed(.refused)
            }
        }
        rebuild()
    }

    /// A source named as failed, asked again for what it did not hand over: the older stretch
    /// where reading on failed, from where it stood, and its newest where that did. The press
    /// beside its name, and nothing else. Nothing while another read is on the wire, and
    /// nothing for a source whose sign-in may no longer read notices.
    func retry(host raw: String, in session: ShellSession) async {
        let host = raw.lowercased()
        guard work == nil, let reach = reaches[host], case .failed = reach.standing,
              let source = Self.asked(in: session).first(where: { $0.host.lowercased() == host })
        else { return }
        locked.remove(host)
        let ask = Ask(source: source, before: reach.readingOn ? reach.before : nil, gathered: reach.gathered)
        await run([ask], fromTop: nil, in: session)
    }

    /// Ends the read on the wire: every source still waited on is as it was before it was
    /// asked. Whether there was one.
    @discardableResult
    func stop() -> Bool {
        guard let work else { return false }
        work.task.cancel()
        // What a source dismissed meanwhile is struck from `was` already (`took`), and its
        // mark stands: a stopped read's answer lands nowhere, and the next one is weighed.
        for host in asking { reaches[host] = work.was[host] }
        asking = []
        generation += 1
        self.work = nil
        rebuild()
        return true
    }

    /// Lets go of what one source said: a sign-out, a Clear, a Remove, a server ending the
    /// sign-in, or the reader there becoming somebody else. An answer still on its way from it
    /// lands nowhere.
    func forget(host raw: String) {
        let host = raw.lowercased()
        asking.remove(host)
        locked.remove(host)
        struck[host] = nil
        emptied[host] = nil
        acts.forget(host: host)
        guard reaches[host] != nil else { return }
        reaches[host] = nil
        rebuild()
    }

    // MARK: - What a source dismissed

    /// One line its source has dismissed: gone from what is held. It left what is drawn at
    /// the person's yes (`ShellNoticeActs.hidden`).
    ///
    /// **Called only once the source has answered** (`ShellNoticeActs.dismiss`). The line is
    /// struck by the moment that answer landed, against every read sent before it: one on the
    /// wire now — from what it set out with, which a stopped read is put back to, and from its
    /// answer when that lands — whether it was sent before the person's yes or after it.
    func took(_ notice: Notice) {
        let host = notice.source.host.lowercased()
        guard let held = reaches[host] else { return }
        reaches[host]?.notices = held.notices.without(notice)
        if asking.contains(host), let was = work?.was[host] {
            work?.was[host]?.notices = was.notices.without(notice)
        }
        if let moment = ReadMoment.now().place { struck[host, default: [:]][notice.id] = moment }
        // Straight out of the list, with no cut made for it: one line gone moves neither
        // where a source has been read down to nor whether it has more, so the floor and
        // every other line stand where they did. (The act that called this draws again after
        // it — `redraw` — for the entry it then lets go of, which changes nothing here.)
        whole = whole.without(notice)
        if lines.contains(where: { $0.id == notice.id }) { lines = lines.without(notice) }
    }

    /// Every notice one source had, dismissed there at once: nothing of it is held, and it has
    /// no more to read on to. Another source's lines stand. A read of it sent before this was
    /// asked for before the source emptied, so its answer is not taken; the next read says
    /// what has happened since.
    func tookAll(host raw: String) {
        let host = raw.lowercased()
        guard reaches[host] != nil else { return }
        reaches[host]?.empty()
        if asking.contains(host) { work?.was[host]?.empty() }
        emptied[host] = ReadMoment.now().place
        struck[host] = nil
        whole.removeAll { $0.source.host.lowercased() == host }
        rebuild()
    }

    /// What is drawn made again from what is held, after what the acts have on their way
    /// changed (`ShellNoticeActs.hidden`): a line leaving at the person's yes, and one drawn
    /// again where it was because its source said no. Nothing held moves.
    ///
    /// `atYes` is the person's yes itself: the lines it takes out of what is drawn are
    /// remembered as theirs (`leftAtYes`).
    func redraw(atYes: Bool = false) {
        let before = atYes ? Set(lines.map(\.id)) : []
        rebuild()
        if atYes { pressed.formUnion(before.subtracting(lines.map(\.id))) }
    }

    /// Whether a line left what is drawn at a yes of the person's — its own dismissal, or
    /// its source's dismissing of all — and has not been drawn since: whether or not the
    /// source has answered yet.
    func leftAtYes(_ id: String) -> Bool {
        pressed.contains(id)
    }

    /// What one source held before a read, less what it has dismissed since: what a read
    /// that fails, is refused or is walked away from puts back, and what an answer is joined to.
    ///
    /// **Every mark still held is struck, whenever the read was sent.** A mark goes when a
    /// later-sent stretch lands, so one still here is newer than every stretch `was` is made of.
    private func left(of was: Reach?, host: String) -> Reach? {
        guard var was else { return nil }
        if emptied[host] != nil { was.empty() }
        if let marks = struck[host] { was.notices.removeAll { marks[$0.id] != nil } }
        return was
    }

    /// The lines of a stretch its source had not dismissed when the stretch was sent, and the
    /// marks a later-sent stretch has now landed past let go of. A stretch that cannot say
    /// when it was sent is taken for one sent before every mark.
    private func undismissed(_ page: NoticePage, host: String) -> [Notice] {
        guard let marks = struck[host] else { return page.notices }
        let sent = page.sent.place
        let later = marks.filter { mark in sent.map { mark.value > $0 } ?? true }
        struck[host] = later.isEmpty ? nil : later
        return page.notices.filter { later[$0.id] == nil }
    }

    /// Whether a stretch was sent before its source dismissed everything it had: it is not
    /// taken. One sent after lets go of the mark.
    private func outrun(_ page: NoticePage, host: String) -> Bool {
        guard let mark = emptied[host] else { return false }
        if let sent = page.sent.place, sent > mark {
            emptied[host] = nil
            return false
        }
        return true
    }

    /// What reading on asks: each source that answered, has more, and has been read down to
    /// exactly where the list stops — or has nothing this device could read yet, and so has
    /// reached nowhere — while its sign-in may still read notices and its token could be read.
    private func due(in session: ShellSession) -> [Ask] {
        Self.asked(in: session).compactMap { source -> Ask? in
            let host = source.host.lowercased()
            guard let reach = reaches[host], reach.standing == .read, let before = reach.before,
                  !locked.contains(host), reach.reached.map({ $0 == floor }) ?? true
            else { return nil }
            return Ask(source: source, before: before, gathered: reach.gathered)
        }
    }

    /// One read: a door per source built here, on the main actor, from the token held; each
    /// source asked beside the others, off it; each answer landed here as it arrives.
    private func run(_ asks: [Ask], fromTop: Set<String>?, in session: ShellSession) async {
        var sent: [String: MastodonToken] = [:]
        var was: [String: Reach] = [:]
        var doors: [(ask: Ask, notices: MastodonNotices)] = []
        for ask in asks {
            // No token to be read — a locked Keychain — is nothing asked and nothing changed.
            guard let token = session.mastodon.token(host: ask.host) else {
                locked.insert(ask.host)
                continue
            }
            let door = session.mastodon.authorized(token: token, within: deadline, for: .notices)
            doors.append((ask, session.reach.notices(door)))
            sent[ask.host] = token
            was[ask.host] = reaches[ask.host]
            reaches[ask.host, default: Reach()].standing = .reading
            reaches[ask.host]?.readingOn = ask.before != nil
        }
        guard !doors.isEmpty else { return }
        generation += 1
        let mine = generation
        asking = Set(sent.keys)
        let task = Task { @MainActor [sent, was, doors] in
            await withTaskGroup(of: (Ask, Result<NoticePage, any Error>).self) { group in
                for door in doors {
                    group.addTask {
                        let ask = door.ask
                        return (ask, await ShellNoticeActs.run(door.notices) {
                            try await $0.page(source: ask.source, before: ask.before, gathered: ask.gathered)
                        })
                    }
                }
                for await (ask, result) in group {
                    // Stopped, or the source let go of, while this was on the wire.
                    guard self.generation == mine, self.asking.remove(ask.host) != nil,
                          let token = sent[ask.host]
                    else { continue }
                    self.land(result, of: ask, sentWith: token, was: was[ask.host], in: session)
                }
            }
            // Here and not after the wait below: whoever else waits on this read must find it
            // over the moment it is.
            if self.generation == mine { self.work = nil }
        }
        work = (task, fromTop, was)
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// One source's answer, folded into what is held.
    ///
    /// **Only where the token it was asked with is still the one held** (`refusedBookmark`'s
    /// rule), whatever the answer: notices handed to a sign-in the reader has since replaced
    /// are not shown to be this reader's, and a failure or a refusal of that sign-in says
    /// nothing about the one held now. The one answer that leaves no token to compare is the
    /// server ending the sign-in, which the door took the token for.
    ///
    /// **A failure empties nothing.** The source keeps what it had and is named; a 403 from a
    /// sign-in that says it may read notices is remembered for the run, so it is not asked
    /// again; a sign-in the server ended goes the way every ended sign-in goes. A reader
    /// walking away leaves the source as it was.
    private func land(
        _ result: Result<NoticePage, any Error>, of ask: Ask, sentWith sent: MastodonToken, was: Reach?,
        in session: ShellSession
    ) {
        let host = ask.host
        let was = left(of: was, host: host)
        defer {
            settle(in: session)
            acts.settle(host: host, in: session)
        }
        switch ShellNoticeActs.counts(result, of: host, sentWith: sent, in: session) {
        case .ended: return
        case .replaced:
            reaches[host] = was
            return
        case .held: break
        }
        switch result {
        case .success(let page):
            var reach = was ?? Reach()
            // Off the stretch as it came, before any line of it is folded into one held.
            let moment = page.notices.map(\.at).min()
            // And what it brings, less what its source dismissed after it was sent.
            let outrun = outrun(page, host: host)
            let brought = undismissed(page, host: host)
            if let asked = ask.before {
                reach.notices = reach.notices.readingOn(brought)
                // A stretch that names nothing older than it was asked before is the end: a
                // source that ignored the ask would otherwise be asked the same thing for ever.
                reach.before = page.before.flatMap { StatusID.later(asked, than: $0) ? $0 : nil }
                reach.reach(to: moment)
            } else {
                let top = [Notice]().readingOn(brought)
                // **Whether the new top meets what is held is read off notice ids, as numbers,
                // and never off a line's name.** A gathered line is named by its group, and the
                // source cuts one group across stretches: one held from far down that gains a
                // notice comes back at the top under the same name, with everything between
                // unread. The two meet only where the new stretch reaches down to, or past,
                // the newest notice held.
                if let lowest = page.before,
                   reach.notices.contains(where: { !StatusID.later(lowest, than: $0.newestID) }) {
                    // Down to where it stops the new stretch is the source's whole word — a
                    // line held there that it no longer names is gone at the source — and
                    // below that what is held stands, with how far down it goes.
                    let named = Set(top.map(\.id))
                    reach.notices = top.readingOn(reach.notices.filter {
                        named.contains($0.id) || StatusID.later(lowest, than: $0.newestID)
                    })
                    if let held = reach.before, StatusID.later(held, than: lowest) { reach.before = lowest }
                    reach.reach(to: moment)
                } else {
                    reach.notices = top
                    reach.before = page.before
                    reach.reached = moment
                    reach.full = false
                }
            }
            reach.bound(to: capacity)
            if outrun { reach.empty() }
            reach.gathered = page.gathered
            reach.standing = .read
            reaches[host] = reach
            if ask.before == nil { acts.read(host: host) }
        case .failure(let error) where Cancellation.happened(error):
            reaches[host] = was
        case .failure(let error):
            if case .http(403)? = error as? MastodonAuthError {
                session.mastodon.refusedNotices(host: host, sentWith: sent)
            }
            var reach = was ?? Reach()
            // Refused only where the source said this sign-in may not. Any other answer — too
            // many requests, a failure of its own — is a failure, which asking again may get past.
            reach.standing = .failed(WriteWhy.refuses(error) ? .refused : .unreachable)
            reach.readingOn = ask.before != nil
            reaches[host] = reach
        }
    }

    // MARK: - The one list

    /// `lines` and `floor` made again from what is held. Nothing is assigned where nothing moved.
    ///
    /// **Not while a source's first stretch is on the wire**: where it will stop the list is
    /// not known, and a line drawn now might have to be taken back when it answers. The list
    /// stays, less the lines of a source let go of meanwhile.
    ///
    /// **What an act has on its way is left out last, of whichever list that is** — so the
    /// floor, how far each source was read, the bound and every count of what is held are
    /// what they were, and only what is drawn is short of the lines that are leaving.
    private func rebuild() {
        if reaches.values.contains(where: \.isOnFirstStretch) {
            let kept = whole.filter { reaches[$0.source.host.lowercased()] != nil }
            if kept.count != whole.count { whole = kept }
        } else {
            let cut = Self.cut(reaches)
            if cut.floor != floor { floor = cut.floor }
            whole = cut.lines
        }
        let hidden = acts.hidden
        let drawn = hidden.isEmpty ? whole : whole.filter { !hidden.hides($0) }
        if drawn != lines { lines = drawn }
        // A line drawn again is no longer one the person sent away.
        if !pressed.isEmpty { pressed.subtract(lines.map(\.id)) }
    }

    /// The one list of several sources' notices, and where it stops — **the one place the rule
    /// is kept**: the floor is the latest moment among those the sources that have more have
    /// reached, and the lines are every notice at or after it, newest first; two of one moment
    /// stand by host, then the newer id first.
    static func cut(_ reaches: [String: Reach]) -> (lines: [Notice], floor: Date?) {
        let floor = reaches.values.compactMap(\.holds).max()
        let lines = reaches.values.flatMap(\.notices)
            .filter { notice in floor.map { notice.at >= $0 } ?? true }
            .sorted { a, b in
                if a.at != b.at { return a.at > b.at }
                if a.source.host != b.source.host { return a.source.host < b.source.host }
                if a.newestID != b.newestID { return StatusID.later(a.newestID, than: b.newestID) }
                return a.id < b.id
            }
        return (lines, floor)
    }
}

extension Notice.Kind {
    /// The one word every kind this build does not know is narrowed under.
    static let unknownKinds = "unknown"

    /// The word this kind is narrowed away by: the source's own, and one word for every kind
    /// this build does not know — a reader can leave "everything else" out, and cannot be asked
    /// to choose among words nobody here has heard of.
    var narrowedAs: String {
        if case .unknown = self { Self.unknownKinds } else { type }
    }
}
