import FediqoCore
import Foundation
import Observation
import SwiftUI

// The people and the hashtags a search found at the sources (#319), and somebody looked up
// through a source by their address: what is asked, when, and what the results are handed.
//
// **Nothing here asks on a Return.** The search a source is asked on Return is one ask, and
// it is `ShellReload`'s: the posts it brings are held as they always were, and the people and
// the hashtags the same answer carries are handed here, under the number this object gave
// that Return. A Return since, the search closed or its field emptied, and that answer is no
// longer awaited: it lands nowhere. **One band set a source, never merged**, each in its
// source's own order, and drawn only while the field still says the words that were asked.
//
// **As whoever asked, and let go with their sign-in** (`PageReaders`): what a source found is
// what it gave that reader. The sign-in is looked at when the Return goes out and again when
// its answer lands, so an answer that outlived its reader is not kept; and what stands is
// drawn only for whoever would ask now.
//
// **The look-up is the one ask this object makes**, and only at the person's press: one
// source — one they added, and are signed in to — asked to look one address up. It goes to
// that source and nowhere else; what the source then asks of anybody is its own doing. It is
// this object's and not a view's, numbered on the one count every page's asks are numbered
// on, and nothing is left asking with nothing on the wire. A press while it is out asks
// nothing.
//
// **Only of a source that says who people are** — the one fact per kind there is, read where
// a person's page reads it. A forum is asked as it always was, has no band and no press.

/// The hashtags one source found for some words, as the tab of the page of what it found
/// names them (`FoundAt.tags`).
struct FoundTags: Hashable, Sendable, Identifiable {
    /// The host of the source that found them.
    let source: String
    /// The words it was asked, as they were sent.
    let words: String

    var id: String { "\(source)\u{1e}found\u{1e}tags\u{1e}\(words)" }

    /// The words as a line of ours says them.
    var lineWords: String { LineText.oneLine(words, limit: SearchBands.wordsShown) }
}

/// One row of what a source found: somebody, a hashtag, or the press that opens all of one kind.
enum SearchFoundRow: Hashable, Sendable, Identifiable {
    case person(Person)
    case tag(RisingTag, source: String)
    /// All the people the source found: the page of what it found, on People — a list like
    /// any other, asked when that tab first comes in front.
    case allPeople(PeopleList, given: Int)
    /// All the hashtags the source's answer held: the same page, on Hashtags.
    case allTags(FoundTags, given: Int)

    /// **A person's row is that person, and a list's press is that list**: what opening either
    /// lights and the walk remembers, so leaving the page gives the row back.
    var id: String {
        switch self {
        case .person(let person): person.id
        case .tag(let tag, let source): "\(source)\u{1e}found\u{1e}tag\u{1e}\(MastodonRising.folded(tag.tag))"
        case .allPeople(let list, _): list.id
        case .allTags(let page, _): page.id
        }
    }
}

/// What one source found for the words of a Return: its people and its hashtags, each in its
/// own order and as many as its one answer held.
struct SearchBands: Equatable, Identifiable {
    /// The host of the source.
    let source: String
    /// The words it was asked.
    let words: String
    var people: [Person] = []
    var tags: [RisingTag] = []

    /// How many of each kind stand in a band before the press for all of them.
    static let shown = 3
    /// How much of what was typed a line of ours repeats.
    static let wordsShown = 80

    var id: String { source }

    var peopleRows: [SearchFoundRow] {
        var rows = people.prefix(Self.shown).map(SearchFoundRow.person)
        if people.count > Self.shown {
            rows.append(.allPeople(PeopleList(foundAt: source, words: words), given: people.count))
        }
        return rows
    }

    var tagRows: [SearchFoundRow] {
        var rows = tags.prefix(Self.shown).map { SearchFoundRow.tag($0, source: source) }
        if tags.count > Self.shown {
            rows.append(.allTags(FoundTags(source: source, words: words), given: tags.count))
        }
        return rows
    }

    /// Every row, top to bottom as the bands draw them.
    var rows: [SearchFoundRow] { peopleRows + tagRows }

    // MARK: - Words

    static func peopleHead(_ source: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("search.band.people", language: language), source)
    }

    static func tagsHead(_ source: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("search.band.tags", language: language), source)
    }

    /// What stands over the posts once a band stands over them: which timeline they are of.
    static func postsHead(_ timeline: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("search.band.posts", language: language), timeline)
    }

    /// What the press for all of one kind says. **The count is what the source's one answer
    /// held**: where that is as many as an answer holds, there may be more, and the press
    /// says "the first" and not "all".
    static func all(_ given: Int, language: DummyLanguage? = nil) -> String {
        String(
            format: L10n.t(given >= MastodonSearch.longest ? "search.band.first" : "search.band.all", language: language),
            L10n.grouped(given, language: language)
        )
    }

    /// The same press as a listener hears it: which kind, and whose answer.
    static func spoken(_ row: SearchFoundRow, language: DummyLanguage? = nil) -> String? {
        switch row {
        case .person, .tag: return nil
        case .allPeople(let list, let given):
            return String(format: L10n.t("search.band.all.people", language: language), all(given, language: language), list.host)
        case .allTags(let page, let given):
            return String(format: L10n.t("search.band.all.tags", language: language), all(given, language: language), page.source)
        }
    }
}

/// The tab of all the hashtags one source's answer held, as it is handed them.
struct FoundTagsSaid: Equatable {
    let page: FoundTags
    let tags: [RisingTag]

    var rows: [SearchFoundRow] { tags.map { .tag($0, source: page.source) } }

    /// What stands under the rows: that these are what one answer held — and, where it held
    /// as many as an answer holds, that the source may have found more.
    func foot(language: DummyLanguage? = nil) -> String {
        String(
            format: L10n.t(tags.count >= MastodonSearch.longest ? "search.tags.foot.first" : "search.tags.foot.end", language: language),
            page.source, L10n.grouped(tags.count, language: language)
        )
    }
}

/// The one line under the search field — and on the page of somebody a source has not heard
/// of — about looking an address up through a source: the press, or where the asking stands,
/// or why there is none.
struct SearchLookUpLine: Equatable {
    enum Press: Equatable {
        /// Ask `through` to look the address up.
        case lookUp(PersonAddress, through: String)
        /// Open the page of whoever the source found.
        case open(Person)
    }

    /// A sentence, or nothing where the press says it all.
    var words: String?
    /// What the press says, and what it does.
    var press: Press?
    var pressWords: String?
    /// Whether the sentence is about a failure, and so in full ink.
    var failed = false
}

extension ShellWalk {
    /// The hashtags a source found in front, where the page of what it found stands on their
    /// tab (#319, F10).
    var openedFoundTags: FoundTags? {
        guard case .found(let at, .tags) = standing else { return nil }
        return at.tags
    }
}

/// What the sources found for the last Return, and the one address looked up.
///
/// Held by `ShellPersonPages`, on its count of asks, and handed the session at each call: the
/// session's own stored state is not this unit's to add to.
@MainActor
@Observable
final class ShellSearchFound {
    typealias AskedAs = ShellPersonPages.AskedAs

    /// One Return's ask of the sources, as the answers it awaits are told from any other's.
    struct Sent: Sendable {
        let errand: Int
        let words: String
        let askedAs: [String: AskedAs]
    }

    private struct Held {
        let askedAs: AskedAs
        var bands: SearchBands
    }

    /// Where a look-up stands.
    enum Looking: Equatable {
        case asking
        case found(Person)
        /// The source found nobody at the address. It does not say whether it asked anybody.
        case unheardOf
        case failed
    }

    private struct LookUp {
        let address: PersonAddress
        let host: String
        let askedAs: AskedAs
        var state: Looking = .asking
        /// Whether whoever was found is at the address typed, and not only of its name.
        var asTyped = true
        let awaits: Int
    }

    private var held: [String: Held] = [:]
    /// The number of the Return whose answers are awaited, or none.
    @ObservationIgnored private var awaits = 0
    /// The sources whose sign-in is known to have been made without search: by its own words
    /// where they are written down, or by the source's refusal this run.
    private var withoutSearch: Set<String> = []
    private var lookedUp: LookUp?
    /// The look-up on the wire.
    @ObservationIgnored private var looking: Task<Void, Never>?
    @ObservationIgnored private let errands: PageErrands
    @ObservationIgnored private let readers: PageReaders
    /// The lists of people opened this run: where the people a source found are asked, as
    /// the page of what it found shows them on its first tab.
    @ObservationIgnored let lists: ShellPeoplePages
    /// Where the lamp stood on each tab of the page of what a source found when the tab was
    /// left. Not observed: it is read only as a tab is brought in front.
    @ObservationIgnored var lamps: [FoundWhich: String] = [:]
    /// How long the look-up may take. A test shortens it.
    @ObservationIgnored var deadline: Duration = .seconds(30)
    /// Another way to a source's search, where a test reaches it by one — a wire that goes on
    /// answering an ask that was called off, as a transfer already ended does. Nothing in the app.
    @ObservationIgnored var reaching: ((MastodonToken) -> MastodonSearch)?

    init(errands: PageErrands, readers: PageReaders, lists: ShellPeoplePages) {
        self.errands = errands
        self.readers = readers
        self.lists = lists
    }

    /// Everything of `host` let go, and a look-up through it called off: its reader is no
    /// longer who it was given to (`PageReaders`).
    func letGo(at host: String) {
        held[host] = nil
        withoutSearch.remove(host)
        if lookedUp?.host == host {
            looking?.cancel()
            looking = nil
            lookedUp = nil
        }
    }

    // MARK: - What a Return brought

    /// A Return going out to `hosts` with `words`: what the last one brought goes, and the
    /// number its answers are awaited under is taken. Who asks at each source is taken here,
    /// before anything waits.
    func sending(_ words: String, to hosts: [String], in session: ShellSession) -> Sent {
        held = [:]
        var askedAs: [String: AskedAs] = [:]
        for host in hosts where ShellPersonPages.source(at: host, in: session) != nil {
            note(readers.look(at: host, in: session).held, at: host)
            askedAs[host] = ShellPersonPages.askedAs(at: host, in: session)
        }
        awaits = errands.next()
        return Sent(errand: awaits, words: words, askedAs: askedAs)
    }

    /// The answer of `host` to the Return `sent`. **It lands only where that Return is still
    /// the one awaited, at a source that says who people are, and for the reader it was asked
    /// as**: looked at once more here, since an answer may outlive the sign-in it was given to.
    func landed(_ finds: SearchFinds, at host: String, of sent: Sent, in session: ShellSession) {
        guard awaits == sent.errand, let askedAs = sent.askedAs[host],
              ShellPersonPages.source(at: host, in: session) != nil,
              !readers.look(at: host, in: session).changed,
              askedAs.isTheSame(as: ShellPersonPages.askedAs(at: host, in: session))
        else { return }
        guard !finds.people.isEmpty || !finds.tags.isEmpty else { return }
        held[host] = Held(
            askedAs: askedAs, bands: SearchBands(source: host, words: sent.words, people: finds.people, tags: finds.tags)
        )
    }

    /// The source at `host` refused the Return `sent` for want of search: learnt for the run,
    /// so the look-up is not offered through it. **Learnt of the sign-in that was refused, and
    /// of no other**: as an answer lands, a refusal come after that sign-in was replaced says
    /// nothing of the one there now.
    func refused(at host: String, of sent: Sent, in session: ShellSession) {
        guard awaits == sent.errand, let askedAs = sent.askedAs[host],
              !readers.look(at: host, in: session).changed,
              askedAs.isTheSame(as: ShellPersonPages.askedAs(at: host, in: session))
        else { return }
        withoutSearch.insert(host)
    }

    /// The search's ask ended — another Return, the field emptied, the search closed: what it
    /// brought goes, and an answer still out lands nowhere.
    func ended() {
        awaits = 0
        held = [:]
    }

    /// Whether the source at `host` is not known this run to refuse its sign-in search — by
    /// that sign-in's own words, or by its answer.
    func searches(at host: String) -> Bool { !withoutSearch.contains(host) }

    /// The search closed, or its field emptied: its bands go, and so does a look-up — called
    /// off where it is still out.
    func closed() {
        ended()
        looking?.cancel()
        looking = nil
        lookedUp = nil
    }

    /// The search opening: the sign-in at each source that says who people are is looked at
    /// once, so a sign-in made without search is known before anything is offered through it.
    func opened(in session: ShellSession) {
        for source in session.sources where ShellPersonPages.saysPeople(source) {
            note(readers.look(at: source.host, in: session).held, at: source.host)
        }
    }

    /// Writes down whether the sign-in `token` says in its own words that it may not search.
    /// One whose words were never written down is not known to lack it.
    private func note(_ token: MastodonToken?, at host: String) {
        if let scopes = token?.scopes, !MastodonOAuth.searches(scopes) {
            withoutSearch.insert(host)
        } else if token?.scopes != nil {
            withoutSearch.remove(host)
        }
    }

    /// The bands over the results of `pattern`: one set a source, in the order the sources
    /// stand, **for whoever would ask now** and only while `pattern` still says the words the
    /// sources were asked.
    func said(for pattern: String, in session: ShellSession) -> [SearchBands] {
        guard !held.isEmpty, let words = MastodonSearch.words(of: pattern) else { return [] }
        return session.sources.compactMap { source in
            guard let found = held[source.host], found.bands.words == words,
                  ShellPersonPages.source(at: source.host, in: session) != nil,
                  found.askedAs.isTheSame(as: ShellPersonPages.askedAs(at: source.host, in: session))
            else { return nil }
            return found.bands
        }
    }

    /// The rows `j` and `k` walk over the posts, top to bottom.
    func walked(for pattern: String, in session: ShellSession) -> [String] {
        said(for: pattern, in: session).flatMap(\.rows).map(\.id)
    }

    /// The row `id` of the bands, where the bands as they are drawn hold it.
    func row(_ id: String, for pattern: String, in session: ShellSession) -> SearchFoundRow? {
        said(for: pattern, in: session).lazy.flatMap(\.rows).first { $0.id == id }
    }

    /// The answer a source gave for the words `page` names, or nothing: the answer is gone,
    /// was for other words, or was given to somebody else.
    func bands(of page: FoundTags, in session: ShellSession) -> SearchBands? {
        guard let found = held[page.source], found.bands.words == page.words,
              ShellPersonPages.source(at: page.source, in: session) != nil,
              found.askedAs.isTheSame(as: ShellPersonPages.askedAs(at: page.source, in: session))
        else { return nil }
        return found.bands
    }

    /// All the hashtags a source's answer held, or nothing where the answer is not (`bands`).
    func said(of page: FoundTags, in session: ShellSession) -> FoundTagsSaid? {
        bands(of: page, in: session).map { FoundTagsSaid(page: page, tags: $0.tags) }
    }

    func walked(_ page: FoundTags, in session: ShellSession) -> [String] {
        said(of: page, in: session)?.rows.map(\.id) ?? []
    }

    func row(_ id: String, of page: FoundTags, in session: ShellSession) -> SearchFoundRow? {
        said(of: page, in: session)?.rows.first { $0.id == id }
    }

    /// Where `j` or `k` lights a first row among a search's results over which bands stand,
    /// with nothing lit: Return lit the first post there was, and where there was none — the
    /// sources' answers came after it — a key lights the first post now, or the first row of
    /// the bands where no post was found at all. **Only once Return has handed the keys to
    /// the results** — the field does not have them — and only with the search itself in
    /// front. With no band, a search's results are lit as they always were, and this lights
    /// nothing.
    static func firstLit(
        _ rows: [String], firstPost: String?, selected: String?, fieldFocused: Bool, open: Set<DummyLayer>
    ) -> String? {
        guard selected == nil, !rows.isEmpty, !fieldFocused, DummyCommand.outermost(of: open) == .search else { return nil }
        return firstPost ?? rows.first
    }

    // MARK: - Looking somebody up

    /// The line about looking `typed` up, or nothing: it is no address of a person, or no
    /// source here says who people are. With `only`, of that source alone — the page of
    /// somebody it has not heard of.
    ///
    /// **It reads no sign-in**: which sources are signed in to is what the session already
    /// holds, and which were signed in to without search is what this object learnt at a press.
    func line(
        typed: String, through only: String? = nil, in session: ShellSession, language: DummyLanguage? = nil
    ) -> SearchLookUpLine? {
        guard let address = PersonAddress(typed: typed) else { return nil }
        let sources = session.sources.compactMap { ShellPersonPages.source(at: $0.host, in: session) }
            .filter { only == nil || $0.host == only }
        guard !sources.isEmpty else { return nil }
        if let lookedUp, lookedUp.address == address, sources.contains(where: { $0.host == lookedUp.host }),
           lookedUp.askedAs.isTheSame(as: ShellPersonPages.askedAs(at: lookedUp.host, in: session))
        {
            return Self.line(lookedUp.state, asTyped: lookedUp.asTyped, of: address, through: lookedUp.host, language: language)
        }
        let signedIn = sources.filter { session.mastodon.signedInHosts.contains($0.host) }
        guard let first = signedIn.first else {
            // Of one source alone, that source is named: others may well be signed in to.
            let said = only.map { String(format: L10n.t("search.lookup.signedOut.there", language: language), $0, address.shown) }
                ?? String(format: L10n.t("search.lookup.signedOut", language: language), address.shown)
            return SearchLookUpLine(words: said)
        }
        let able = signedIn.filter { !withoutSearch.contains($0.host) }
        // Through the source the address itself names where that is one of them: it knows its own.
        guard let through = able.first(where: { $0.host == address.host }) ?? able.first else {
            return SearchLookUpLine(words: String(format: L10n.t("search.lookup.scope", language: language), first.host))
        }
        return SearchLookUpLine(
            press: .lookUp(address, through: through.host),
            pressWords: String(format: L10n.t("search.lookup.offer", language: language), address.shown, through.host)
        )
    }

    private static func line(
        _ state: Looking, asTyped: Bool, of address: PersonAddress, through host: String, language: DummyLanguage?
    ) -> SearchLookUpLine {
        switch state {
        case .asking:
            return SearchLookUpLine(
                words: String(format: L10n.t("search.lookup.asking", language: language), host, address.shown)
            )
        case .found(let person):
            // Who was found is said by the handle the source gave, not by what was typed — and
            // where that is not the address typed, the line says so.
            let key = asTyped ? "search.lookup.found" : "search.lookup.found.other"
            return SearchLookUpLine(
                words: String(format: L10n.t(key, language: language), host, foundHandle(person)),
                press: .open(person), pressWords: L10n.t("search.lookup.open", language: language)
            )
        case .unheardOf:
            return SearchLookUpLine(
                words: String(format: L10n.t("search.lookup.unheardOf", language: language), host, address.shown),
                press: .lookUp(address, through: host), pressWords: L10n.t("person.retry", language: language)
            )
        case .failed:
            return SearchLookUpLine(
                words: String(format: L10n.t("search.lookup.failed", language: language), host, address.shown),
                press: .lookUp(address, through: host), pressWords: L10n.t("person.retry", language: language), failed: true
            )
        }
    }

    /// The handle of whoever a look-up found, as its line says it: **whole, server and all**,
    /// as long as a handle that can be asked for is. It may not be the one typed, and a server's
    /// name cut short reads as another's — so it is not cut where a row cuts a handle.
    static func foundHandle(_ person: Person) -> String {
        LineText.oneLine(person.handle, limit: MastodonPerson.handleLength + 1)
    }

    /// The line on the page of `who`, where their source has not heard of them and they live
    /// elsewhere: the press that asks that source to look them up.
    func line(of who: DummyPerson, said: PersonSaid?, in session: ShellSession) -> SearchLookUpLine? {
        guard let said, said.reading == .unheardOf, let handle = who.handle,
              let address = PersonAddress(typed: handle), address.host != said.source
        else { return nil }
        return line(typed: handle, through: said.source, in: session)
    }

    /// Whether the page of `who` is the page of `person`, whom a source found by the address
    /// that page was opened by: the same page, or the same source and the very handle, server
    /// and all. Somebody found at another server than the page names has a page of their own —
    /// asking this one again would ask for whoever was not heard of.
    static func isThePage(_ who: DummyPerson, of person: Person) -> Bool {
        if who.id == DummyPerson(person).id { return true }
        guard who.host == person.source.host, let address = who.handle.flatMap(PersonAddress.init(typed:)) else { return false }
        return address.exactly(person)
    }

    /// Where the look-up of `address` stands, for a test.
    func looked(_ address: PersonAddress) -> Looking? {
        lookedUp?.address == address ? lookedUp?.state : nil
    }

    /// The press: the source at `host` asked to look `address` up. **A press while that very
    /// look-up is out asks nothing**; another address pressed calls the one out off. Nothing
    /// is asked of a source that does not say who people are, with no sign-in there, or
    /// through a sign-in that says it may not search.
    func lookUp(_ address: PersonAddress, through host: String, in session: ShellSession) async {
        guard let source = ShellPersonPages.source(at: host, in: session) else { return }
        let token = readers.look(at: host, in: session).held
        note(token, at: host)
        guard let token, !withoutSearch.contains(host) else { return }
        if let lookedUp, lookedUp.address == address, lookedUp.host == host, lookedUp.state == .asking {
            await looking?.value
            return
        }
        looking?.cancel()
        let errand = errands.next()
        let askedAs = ShellPersonPages.askedAs(at: host, in: session)
        lookedUp = LookUp(address: address, host: host, askedAs: askedAs, awaits: errand)
        let through = reaching?(token)
            ?? session.reach.search(session.mastodon.authorized(token: token, within: deadline, for: .lookUp))
        let task = Task { await self.look(address, of: through, at: source, as: askedAs, errand: errand, in: session) }
        looking = task
        await task.value
    }

    private func look(
        _ address: PersonAddress, of through: MastodonSearch, at source: Source, as askedAs: AskedAs, errand: Int,
        in session: ShellSession
    ) async {
        defer { if lookedUp?.awaits == errand { looking = nil } }
        do {
            let found = try await through.resolved(address, source: source)
            guard lookedUp?.awaits == errand else { return }
            // An answer that outlived the sign-in it was given to is nobody's.
            guard !readers.look(at: source.host, in: session).changed else { return }
            lookedUp?.asTyped = found.asTyped
            lookedUp?.state = .found(found.person)
        } catch {
            guard lookedUp?.awaits == errand else { return }
            // Nor is a refusal or a failure: it says nothing of the sign-in there now.
            guard !readers.look(at: source.host, in: session).changed else { return }
            if (error as? PersonReadError) == .unheardOf {
                lookedUp?.state = .unheardOf
            } else if (error as? MastodonScopeError) == .outside {
                // Refused for want of search: said in place of the press from now on.
                withoutSearch.insert(source.host)
                lookedUp = nil
            } else if Cancellation.happened(error) {
                // Called off before it answered: nothing is left asking with nothing on the wire.
                lookedUp = nil
            } else {
                ShellPersonPages.concluded(error, at: source, askedAs: askedAs, in: session)
                lookedUp?.state = .failed
            }
        }
    }
}

// MARK: - Drawn

/// The line about looking an address up, drawn: its sentence, and the press beside or under it.
struct SearchLookUpView: View {
    let line: SearchLookUpLine
    var onPress: (SearchLookUpLine.Press) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
                words.fixedSize()
                press
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                words
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                press
            }
        }
    }

    @ViewBuilder
    private var words: some View {
        if let said = line.words {
            Text(said)
                .shellFont(.meta)
                .foregroundStyle(line.failed ? ShellChrome.ink(colorScheme) : ShellChrome.inkDim(colorScheme))
        }
    }

    @ViewBuilder
    private var press: some View {
        if let act = line.press, let said = line.pressWords {
            ShellLinkButton(said) { onPress(act) }
                .multilineTextAlignment(.leading)
        }
    }
}

/// The bands over a search's posts: under one head a source and kind, the first few of what
/// that source found, and the press for all of them where there are more.
///
/// It draws what it is handed and asks nothing: which kind of source this is is never looked at.
struct SearchBandsView: View {
    let bands: [SearchBands]
    /// The name of the timeline the posts under the bands are of.
    let timeline: String
    @Binding var selectedID: String?
    var onOpen: (SearchFoundRow) -> Void
    @Environment(\.shellTouch) private var touch

    var body: some View {
        ForEach(bands) { band in
            if !band.people.isEmpty {
                ShellBandHead(SearchBands.peopleHead(band.source), pinned: true)
                rows(band.peopleRows)
            }
            if !band.tags.isEmpty {
                ShellBandHead(SearchBands.tagsHead(band.source), pinned: true)
                rows(band.tagRows)
            }
        }
        ShellBandHead(SearchBands.postsHead(timeline), pinned: true)
    }

    private func rows(_ rows: [SearchFoundRow]) -> some View {
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            SearchFoundRowView(row: row, selected: row.id == selectedID, onPress: { press(row) }, onOpen: { onOpen(row) })
                .id(row.id)
            if index < rows.count - 1 { ShellRule() }
        }
    }

    /// A press lights the row, and a second on the row it is already on opens it —
    /// `DummyCommand.tapped`, as on every list; under a finger one press opens.
    private func press(_ row: SearchFoundRow) {
        switch DummyCommand.tapped(row.id, selected: selectedID, touch: touch) {
        case .select: selectedID = row.id
        case .open: onOpen(row)
        }
    }
}

/// One row of what a source found: a person's row, a hashtag's row, or the press for all.
struct SearchFoundRowView: View {
    let row: SearchFoundRow
    var selected = false
    var onPress: () -> Void
    var onOpen: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch row {
        case .person(let person):
            PersonRow(person: person, selected: selected, onPress: onPress, onOpen: onOpen)
        case .tag(let tag, let source):
            RisingRowView(row: .tag(tag, source: source), selected: selected, onPress: onPress, onOpen: onOpen)
        case .allPeople(_, let given), .allTags(_, let given):
            all(given)
        }
    }

    /// The press for all of one kind: a line of the page's own, lit as a row is.
    private func all(_ given: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ShellSpace.tight) {
            Text(SearchBands.all(given))
            Image(systemName: "chevron.right")
                .shellFont(.mark)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
        }
        .shellFont(.meta, weight: .medium)
        .foregroundStyle(ShellChrome.selectInk(colorScheme))
        .padding(.horizontal, ShellSpace.pad)
        .padding(.vertical, ShellSpace.snug)
        .background(selected ? ShellChrome.floatFill(colorScheme) : .clear)
        .overlay(alignment: .leading) {
            if selected {
                Rectangle()
                    .fill(ShellChrome.phosphor(colorScheme))
                    .frame(width: DummyItemRow.Box.lamp)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: selected)
        .contentShape(Rectangle())
        .onTapGesture(perform: onPress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SearchBands.spoken(row) ?? SearchBands.all(given))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, onOpen)
    }
}
