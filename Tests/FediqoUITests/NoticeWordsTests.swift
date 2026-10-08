import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #323 — what a notice's row says and what the page says around its rows, asked of the
/// functions the views draw from. What is drawn is `NoticesHostedTests`.
@MainActor
@Suite("What the notices page says")
struct NoticeWordsTests {
    private static let source = Source(host: "a.example", kind: .mastodon)
    private static let at = Date(timeIntervalSince1970: 1_717_200_000)
    private static let ada = NoticePerson(handle: "@ada@a.example", name: "Ada")
    private static let bo = NoticePerson(handle: "@bo@a.example", name: "Bo")

    private static func post(_ body: String = "The words of the post", answering: String? = nil) -> Note {
        Note(
            id: "https://a.example/p/30", source: source, author: "Me", handle: "@me@a.example", body: body,
            postedAt: at, categories: [], reply: answering.map { Reply(inReplyToId: $0) }, statusID: "30"
        )
    }

    private static func notice(
        _ kind: Notice.Kind, people: [NoticePerson] = [ada], count: Int = 1, post: Note? = nil, id: String = "1"
    ) -> Notice {
        Notice(
            source: source, handle: .one(id: id), kind: kind, people: people, count: count, post: post, at: at,
            newestID: id, oldestID: id
        )
    }

    // MARK: - A row

    @Test("Every kind the issue names says what happened, and an answer is told from a mention by its post")
    func whatHappened() {
        let said: [(Notice, String)] = [
            (Self.notice(.mention, post: Self.post(answering: "9")), "answered you"),
            (Self.notice(.mention, post: Self.post()), "mentioned you"),
            (Self.notice(.reblog, post: Self.post()), "boosted your post"),
            (Self.notice(.favourite, post: Self.post()), "favourited your post"),
            (Self.notice(.follow), "followed you"),
            (Self.notice(.followRequest), "asked to follow you"),
            (Self.notice(.quote, post: Self.post()), "quoted your post"),
            (Self.notice(.poll, post: Self.post()), "ran a poll that has ended"),
            (Self.notice(.update, post: Self.post()), "edited a post you boosted"),
            (Self.notice(.server("moderation_warning"), people: []), "The server's moderators sent you a warning"),
            (Self.notice(.server("severed_relationships"), people: []), "The server cut some of your follows"),
            (Self.notice(.server("admin.report")), "filed a report on this server"),
            (Self.notice(.server("admin.report"), people: []), "A report was filed on this server"),
            (Self.notice(.server("admin.sign_up")), "signed up on this server"),
            (Self.notice(.server("admin.sign_up"), people: []), "Somebody signed up on this server"),
        ]
        for (notice, words) in said {
            #expect(NoticeWords.what(notice, language: .english) == words)
            let ours = NoticeWords.what(notice, language: .taiwanese)
            #expect(!ours.isEmpty && ours != words && !ours.hasPrefix("notices."), "\(words) is not said in 繁體中文")
            #expect(!NoticeWords.symbol(notice).isEmpty)
        }
    }

    @Test("A glyph says what happened by itself only for a kind with a glyph of its own: the server's words share one, and unknown kinds another")
    func aGlyphOfItsOwn() {
        let own = NoticeWords.named.map { Self.notice($0, post: Self.post()) } + [Self.notice(.mention, post: Self.post(answering: "29"))]
        #expect(own.allSatisfy(NoticeWords.symbolSays))
        #expect(Set(own.map(NoticeWords.symbol)).count == own.count, "two kinds are drawn as one glyph")
        let shared = [
            Self.notice(.server("moderation_warning"), people: []), Self.notice(.server("admin.sign_up")),
            Self.notice(.server("admin.report")), Self.notice(.unknown("annual_report")),
        ]
        #expect(!shared.contains(where: NoticeWords.symbolSays))
        #expect(Set(shared.map(NoticeWords.symbol)).count == 2)
    }

    @Test("A kind this build does not know is said as unknown, under the word its source used")
    func unknownIsSaidAsUnknown() {
        let notice = Self.notice(Notice.Kind(type: "annual_report"), people: [])
        #expect(NoticeWords.what(notice, language: .english) == "A notice of a kind Fediqo does not know yet: annual_report")
        #expect(NoticeWords.what(notice, language: .taiwanese).contains("annual_report"))
        #expect(NoticeWords.symbol(notice) == "questionmark.circle")
    }

    @Test("Who is one name, or the newest name and how many others for a line gathered from several")
    func who() {
        #expect(NoticeWords.who(Self.notice(.favourite), language: .english) == "Ada")
        #expect(NoticeWords.who(Self.notice(.favourite, people: [Self.ada, Self.bo], count: 2), language: .english) == "Ada and 1 other")
        // The source sent a sample of two and says the line stands for five.
        let five = Self.notice(.favourite, people: [Self.ada, Self.bo], count: 5)
        #expect(NoticeWords.who(five, language: .english) == "Ada and 4 others")
        #expect(NoticeWords.who(five, language: .taiwanese) == "Ada 和另外 4 人")
        #expect(NoticeWords.who(Self.notice(.server("moderation_warning"), people: [])) == nil)
        let nameless = NoticePerson(handle: "@cy@a.example", name: "")
        #expect(NoticeWords.who(Self.notice(.follow, people: [nameless])) == "@cy@a.example")
    }

    @Test("The post is a quiet run of its words, and nothing where the notice is about no post")
    func excerpt() {
        #expect(NoticeWords.excerpt(Self.notice(.favourite, post: Self.post("One\n\n two  three"))) == "One two three")
        #expect(NoticeWords.excerpt(Self.notice(.favourite, post: Self.post("  "))) == nil)
        #expect(NoticeWords.excerpt(Self.notice(.follow)) == nil)
    }

    private static func covered(_ body: String = "What was put under the cover", sensitive: Bool?, spoiler: String?) -> Note {
        Note(
            id: "https://a.example/p/31", source: source, author: "Me", handle: "@me@a.example", body: body,
            postedAt: at, categories: [], sensitive: sensitive, spoiler: spoiler, statusID: "31"
        )
    }

    @Test("A post its author covered shows what it was covered with and never its words, to the eye and to a listener")
    func aCoveredPostKeepsItsCover() {
        let warned = Self.notice(.mention, post: Self.covered(sensitive: false, spoiler: "Spoilers\n for  the finale"))
        let flagged = Self.notice(.mention, post: Self.covered(sensitive: true, spoiler: ""))
        let both = Self.notice(.mention, post: Self.covered(sensitive: true, spoiler: "Food"))
        #expect(NoticeWords.excerpt(warned, language: .english) == "Author's warning: Spoilers for the finale")
        #expect(NoticeWords.excerpt(flagged, language: .english) == "Covered")
        #expect(NoticeWords.excerpt(both, language: .english) == "Author's warning: Food")
        #expect(NoticeWords.excerpt(warned, language: .taiwanese) == "作者的警告：Spoilers for the finale")
        #expect(NoticeWords.excerpt(flagged, language: .taiwanese) == "已蓋住")
        // A cover with no words under it is still a cover, and is said.
        #expect(NoticeWords.excerpt(Self.notice(.mention, post: Self.covered("", sensitive: true, spoiler: nil)), language: .english) == "Covered")

        let when = DummyItemRow.exact(Self.at)
        #expect(
            NoticeWords.spoken(warned, language: .english)
                == "Ada mentioned you: Author's warning: Spoilers for the finale. From a.example, \(when)."
        )
        #expect(NoticeWords.spoken(flagged, language: .english) == "Ada mentioned you: Covered. From a.example, \(when).")
        for language in [DummyLanguage.english, .taiwanese] {
            for notice in [warned, flagged, both] {
                #expect(NoticeWords.excerpt(notice, language: language)?.contains("under the cover") == false)
                #expect(!NoticeWords.spoken(notice, language: language).contains("under the cover"), "the cover was lifted for a listener")
            }
        }

        // The source's three answers, as a timeline's row reads them: only a yes covers.
        for open in [Self.covered(sensitive: false, spoiler: ""), Self.covered(sensitive: nil, spoiler: nil)] {
            #expect(NoticeWords.excerpt(Self.notice(.mention, post: open)) == "What was put under the cover")
            #expect(DummyItem(open).covered == false)
        }
        for post in [warned, flagged, both].compactMap(\.post) {
            #expect(DummyItem(post).covered, "a timeline's row and a notice's line disagree about a cover")
        }
    }

    @Test("A cover line and a post's words are held to one line as a name is: nothing that turns or hides, and no longer than a sentence, to a listener too")
    func aCoverLineIsMadeFitForALine() {
        let turning = Self.notice(.mention, post: Self.covered(sensitive: true, spoiler: "\u{202E}gninraw\u{202C} \u{2066}on\u{2069}e\u{200B}\nline"))
        #expect(NoticeWords.excerpt(turning, language: .english) == "Author's warning: gninraw one line")
        let endless = Self.notice(.mention, post: Self.covered(sensitive: false, spoiler: String(repeating: "w", count: 5_000)))
        let cover = try? #require(NoticeWords.excerpt(endless, language: .english))
        #expect(cover == "Author's warning: " + String(repeating: "w", count: NoticeWords.excerptLength) + "…")
        // A line of nothing but what is stripped still covers, as it does in a timeline: the
        // line says only that the post is covered, and never the words beneath.
        let empty = Self.covered(sensitive: nil, spoiler: "\u{200B}\u{202E}")
        #expect(DummyItem(empty).covered)
        #expect(NoticeWords.excerpt(Self.notice(.mention, post: empty), language: .english) == L10n.t("item.covered.mark", language: .english))

        let body = Self.notice(.mention, post: Self.post("\u{202E}sdrow\u{202C} of\u{200B} the\npost " + String(repeating: "x", count: 5_000)))
        let words = NoticeWords.excerpt(body) ?? ""
        #expect(words.hasPrefix("sdrow of the post xxx") && words.hasSuffix("…") && words.count == NoticeWords.excerptLength + 1)
        for notice in [turning, endless, body] {
            let heard = NoticeWords.spoken(notice, language: .english)
            #expect(heard.unicodeScalars.allSatisfy { ![.control, .format].contains($0.properties.generalCategory) })
            #expect(heard.count < NoticeWords.excerptLength + 200, "a listener is read a line of any length")
        }
    }

    @Test("Somebody met through a notice is named cleanly wherever they go on to: their page, a tooltip, an action's name")
    func aNoticesPersonIsCleanFromTheStart() throws {
        let hostile = NoticePerson(handle: "@eve@b.example", name: "\u{202E}adA\u{202C}\nOpen Ada's page" + String(repeating: "!", count: 5_000))
        let person = try #require(DummyPerson(hostile, host: "a.example"))
        #expect(person.name == NoticeWords.oneLine(hostile.name) && person.name.count == NoticeWords.nameLength + 1)
        #expect(person.handle == "@eve@b.example" && person.id == "a.example\u{1e}@eve@b.example")
        let spoken = NoticeRow.spokenPerson(person)
        #expect(spoken == DummyItemRow.spokenPerson(person) && spoken.contains("adA Open Ada's page!"))
        #expect(spoken.unicodeScalars.allSatisfy { ![.control, .format].contains($0.properties.generalCategory) })
        #expect(spoken.count < 200)

        // A name of nothing that draws is no name: they are called by their handle, held to a line.
        let nameless = try #require(DummyPerson(NoticePerson(handle: "@e\u{202E}ve@b.example", name: "\u{200B}"), host: "a.example"))
        #expect(nameless.name.isEmpty && nameless.handle == "@e\u{202E}ve@b.example", "the handle they are matched by was changed")
        #expect(NoticeRow.spokenPerson(nameless).contains("@eve@b.example") && !NoticeRow.spokenPerson(nameless).contains("\u{202E}"))
        #expect(DummyPerson(NoticePerson(handle: "", name: "\u{200B}\u{202E}"), host: "a.example") == nil)
        // An ordinary person is as they were.
        let ada = try #require(DummyPerson(Self.ada, host: "a.example"))
        #expect(ada.name == "Ada" && NoticeRow.spokenPerson(ada) == DummyItemRow.spokenPerson(ada))
    }

    // MARK: - A name a source sent

    @Test("A name is set in one line with nothing in it that turns, hides or breaks the line, and no longer than a name")
    func aNameIsMadeFitForALine() {
        // The overrides, the embeddings and the isolates, with what closes them.
        let turning = "\u{202E}evE\u{202C} \u{202D}Eve\u{202C} \u{202A}a\u{202B}b \u{2066}c\u{2067}d\u{2068}e\u{2069} \u{200E}f\u{200F}\u{061C}"
        #expect(NoticeWords.oneLine(turning) == "evE Eve ab cde f")
        // Zero-width marks, a soft hyphen and a byte-order mark draw nothing and hide a difference.
        #expect(NoticeWords.oneLine("A\u{200B}d\u{200C}a\u{2060}\u{FEFF}\u{00AD}") == "Ada")
        #expect(NoticeWords.oneLine("\u{200B}\u{202E}") == "")
        // Every way a line ends, and the controls beside them.
        #expect(NoticeWords.oneLine("Eve\nLet go of\r\neverything?\u{2028}yes\u{2029}\u{0085}no\tor\u{0007}\u{0000}so") == "Eve Let go of everything? yes no or so")
        // A joiner between two pictures makes one picture of them, and stays; between letters it goes.
        #expect(NoticeWords.oneLine("Ada 👩\u{200D}💻") == "Ada 👩\u{200D}💻")
        #expect(NoticeWords.oneLine("A\u{200D}da") == "Ada")
        #expect(NoticeWords.oneLine("  Ada   Lovelace ") == "Ada Lovelace")

        let long = NoticeWords.oneLine(String(repeating: "A", count: 5_000))
        #expect(long == String(repeating: "A", count: NoticeWords.nameLength) + "…")
        let marks = NoticeWords.oneLine("A" + String(repeating: "\u{0301}", count: 5_000) + "da")
        #expect(marks.unicodeScalars.count <= NoticeWords.nameLength * 16, "one letter under any number of marks is as long as it was")
        #expect(NoticeWords.oneLine("Ada") == "Ada")
    }

    @Test("A row names somebody by the name they chose, made fit; a sentence about an act names them by their handle first")
    func whoIsNamed() {
        let hostile = NoticePerson(handle: "@eve@b.example", name: "\u{202E}adA\nfavourited your post from a.example")
        #expect(NoticeWords.name(hostile) == "adA favourited your post from a.example")
        #expect(NoticeWords.who(Self.notice(.follow, people: [hostile]), language: .english) == "adA favourited your post from a.example")
        #expect(NoticeWords.who(Self.notice(.follow, people: [hostile, Self.bo], count: 2), language: .english)
            == "adA favourited your post from a.example and 1 other")
        #expect(!NoticeWords.spoken(Self.notice(.follow, people: [hostile]), language: .english).contains("\u{202E}"))

        #expect(NoticeWords.named(Self.ada, language: .english) == "@ada@a.example (Ada)")
        #expect(NoticeWords.named(Self.ada, language: .taiwanese) == "@ada@a.example（Ada）")
        #expect(NoticeWords.named(hostile, language: .english) == "@eve@b.example (adA favourited your post from a.example)")
        #expect(NoticeWords.named(NoticePerson(handle: "@cy@a.example", name: "\u{200B}"), language: .english) == "@cy@a.example")
        #expect(NoticeWords.named(NoticePerson(handle: "", name: "Di"), language: .english) == "Di")
        // The handle is the source's word too, and is held to the same line.
        let handle = NoticeWords.named(NoticePerson(handle: "@e\u{202E}ve\n@b.example", name: ""), language: .english)
        #expect(handle == "@eve @b.example")
        let endless = NoticePerson(handle: "@eve@b.example", name: String(repeating: "x", count: 5_000))
        #expect(NoticeWords.named(endless, language: .english).count <= "@eve@b.example ()".count + NoticeWords.nameLength + 1)
    }

    @Test("A row is heard as who, what, the post, its source and when")
    func spoken() {
        let gathered = Self.notice(.favourite, people: [Self.ada, Self.bo], count: 3, post: Self.post())
        let when = DummyItemRow.exact(Self.at)
        #expect(
            NoticeWords.spoken(gathered, language: .english)
                == "Ada and 2 others favourited your post: The words of the post. From a.example, \(when)."
        )
        #expect(NoticeWords.spoken(Self.notice(.follow), language: .english) == "Ada followed you. From a.example, \(when).")
        #expect(
            NoticeWords.spoken(Self.notice(.server("moderation_warning"), people: []), language: .english)
                == "The server's moderators sent you a warning. From a.example, \(when)."
        )
        #expect(NoticeWords.spoken(gathered, language: .taiwanese).contains("來自 a.example"))
    }

    @Test("Who and what read as a sentence in every arrangement: a predicate after the name, a whole sentence beside it")
    func sentences() {
        let when = DummyItemRow.exact(Self.at)
        #expect(NoticeWords.spoken(Self.notice(.server("admin.report")), language: .english) == "Ada filed a report on this server. From a.example, \(when).")
        #expect(NoticeWords.spoken(Self.notice(.server("admin.report"), people: []), language: .english) == "A report was filed on this server. From a.example, \(when).")
        // A sentence of the server's own, with somebody named beside it, is not run on from the name.
        let warned = Self.notice(.server("moderation_warning"))
        #expect(!NoticeWords.readsOnFromWho(warned))
        #expect(NoticeWords.spoken(warned, language: .english) == "The server's moderators sent you a warning (Ada). From a.example, \(when).")
        #expect(NoticeWords.spoken(Self.notice(.unknown("annual_report")), language: .english)
            == "A notice of a kind Fediqo does not know yet: annual_report (Ada). From a.example, \(when).")
        // 繁體中文: what happened is said apart from the name, and does not open on 的.
        for kind in [Notice.Kind.mention, .reblog, .favourite, .follow, .followRequest, .quote, .poll, .update] {
            let line = NoticeWords.what(Self.notice(kind, post: Self.post()), language: .taiwanese)
            #expect(!line.hasPrefix("的"), "\(kind.type) opens on 的: \(line)")
            #expect(NoticeWords.readsOnFromWho(Self.notice(kind)))
        }
        #expect(NoticeWords.what(Self.notice(.poll, post: Self.post()), language: .taiwanese) == "發起的投票結束了")
    }

    @Test("A line opens its post where it has one, else the person, else nothing")
    func opens() {
        let post = Self.post()
        #expect(NoticeWords.opens(Self.notice(.favourite, post: post)) == .post(post))
        #expect(NoticeWords.opens(Self.notice(.mention, post: post)) == .post(post))
        let follower = NoticeWords.opens(Self.notice(.followRequest))
        guard case .person(let person) = follower else {
            Issue.record("a request to follow leads to the person")
            return
        }
        #expect(person.host == "a.example" && person.handle == "@ada@a.example" && person.name == "Ada")
        #expect(NoticeWords.opens(Self.notice(.server("moderation_warning"), people: [])) == .nothing)
        #expect(NoticeWords.opens(Self.notice(.unknown("annual_report"), people: [])) == .nothing)
    }

    @Test("A press lights a line and a second opens it; under a finger one press opens; a line of words alone is only lit")
    func pressed() {
        let line = Self.notice(.favourite, post: Self.post())
        #expect(NoticesPane.pressed(line, selected: nil, touch: false) == .select)
        #expect(NoticesPane.pressed(line, selected: line.id, touch: false) == .open)
        #expect(NoticesPane.pressed(line, selected: nil, touch: true) == .open)
        let words = Self.notice(.server("moderation_warning"), people: [])
        #expect(NoticesPane.pressed(words, selected: nil, touch: false) == .select)
        #expect(NoticesPane.pressed(words, selected: words.id, touch: false) == nil)
        #expect(NoticesPane.pressed(words, selected: nil, touch: true) == nil)
    }

    // MARK: - The page

    @Test("The page answers in order: nobody signed in, nobody allowed, then its lines")
    func standing() {
        #expect(NoticesStanding.standing([], held: false) == .nobody)
        #expect(
            NoticesStanding.standing([("a.example", .unasked), ("b.example", .unavailable)], held: false)
                == .notAllowed(unasked: ["a.example"], refused: ["b.example"])
        )
        #expect(NoticesStanding.standing([("a.example", .unasked), ("b.example", .allowed)], held: false) == .list)
        // A sign-in that could read and no longer may keeps what it read on the page.
        #expect(NoticesStanding.standing([("a.example", .unavailable)], held: true) == .list)
    }

    @Test("With nobody signed in the page says what would make it fill")
    func nobodySignedIn() {
        #expect(L10n.t("notices.empty.title", language: .english) == "No notices")
        #expect(
            L10n.t("notices.empty.line", language: .english)
                == "Sign in to a Mastodon on Account, and what happens to you there is read here."
        )
        #expect(L10n.t("notices.empty.line", language: .taiwanese).contains("帳號"))
    }

    @Test("Signed in and not allowed, the page names the sources and says what more would be asked")
    func notAllowed() {
        let unasked = NoticesPane.notAllowedWords(unasked: ["a.example", "b.example"], language: .english)
        #expect(unasked.title == "Notices are not read yet")
        #expect(unasked.line == "No sign-in on this device may read notices yet.")
        #expect(unasked.help.contains("to read your notifications there"))
        #expect(unasked.help.contains("before the source's own page opens"))
        let refused = NoticesPane.notAllowedWords(unasked: [], language: .english)
        #expect(refused.title == "No notices to read")
        #expect(refused.line == "No sign-in on this device may read notices.")
        // Which source is which is a line each under it: all of them, whatever is true of each.
        let named = NoticesLine.lines(
            reading: [], failures: [], askable: [],
            hosts: [("a.example", .unasked), ("b.example", .unasked), ("c.example", .unavailable)]
        )
        #expect(named == [.unasked(host: "a.example"), .unasked(host: "b.example"), .refused(host: "c.example")])
    }

    @Test("Above the lines: who is on the wire, who failed and whether asking again may help, who was never asked")
    func sourceLines() {
        let lines = NoticesLine.lines(
            reading: ["a.example", "b.example"],
            failures: [("c.example", .unreachable), ("d.example", .refused), ("e.example", .refused)],
            askable: ["c.example", "e.example"],
            hosts: [
                ("a.example", .allowed), ("b.example", .allowed), ("c.example", .allowed), ("d.example", .unavailable),
                ("e.example", .allowed), ("f.example", .unasked), ("g.example", .unavailable), ("h.example", .allowed),
            ],
            locked: ["h.example"], unread: ["i.example"]
        )
        #expect(lines == [
            .reading(["a.example", "b.example"]),
            .failed(host: "c.example", why: .unreachable, again: true),
            .failed(host: "d.example", why: .refused, again: false),
            .failed(host: "e.example", why: .refused, again: true),
            .locked(host: "h.example"),
            .unread(host: "i.example"),
            .unasked(host: "f.example"),
            .refused(host: "g.example"),
        ])
        #expect(lines.map { $0.words(language: .english) } == [
            "Reading notices from a.example, b.example…",
            "Could not read notices from c.example. What it sent before is still here.",
            "d.example would not let this sign-in read notices. What it sent before is still here.",
            "e.example would not let this sign-in read notices. What it sent before is still here.",
            "This device could not read the sign-in for h.example, so it was not asked.",
            "i.example was not read: the read was stopped before it answered. Press the reload mark, or r, to read again.",
            "f.example has not been asked for your notices.",
            "g.example was asked for your notices and gave none.",
        ])
        #expect(Set(lines.map(\.id)).count == lines.count)
        #expect(NoticesLine.lines(reading: [], failures: [], askable: [], hosts: [("a.example", .allowed)]).isEmpty)
    }

    @Test("With no line to draw the page says why: nothing happened, or lines are hidden and how many; and nothing while a source is unread")
    func none() {
        #expect(NoticesNone.none(isReading: true, held: 0, said: false, answered: false, unread: false) == .reading)
        #expect(NoticesNone.none(isReading: false, held: 0, said: false, answered: true, unread: false) == .nothing)
        #expect(NoticesNone.none(isReading: false, held: 3, said: false, answered: true, unread: false) == .narrowed(3))
        #expect(NoticesNone.none(isReading: false, held: 0, said: true, answered: false, unread: false) == .unread)
        // One source answered with nothing and another was never read: not "nothing has happened".
        #expect(NoticesNone.none(isReading: false, held: 0, said: false, answered: true, unread: true) == .unread)
        #expect(NoticesNone.none(isReading: false, held: 0, said: false, answered: false, unread: true) == .unread)
        #expect(NoticesNone.nothing.words(language: .english) == "Nothing has happened to you on these sources yet.")
        // The words send the reader to the foot only where it has older notices to give.
        #expect(NoticesNone.narrowed(1).words(language: .english, older: true)
            == "1 notice read so far is of a kind you left out. Show that kind again above, or read older ones below.")
        #expect(NoticesNone.narrowed(1).words(language: .english) == "1 notice read so far is of a kind you left out. Show that kind again above.")
        let ours = NoticesNone.narrowed(3).words(language: .taiwanese), older = NoticesNone.narrowed(3).words(language: .taiwanese, older: true)
        #expect(ours?.contains("3") == true && older?.contains("3") == true && ours != older)
        // The line above says it is reading, or why a source was not read: nothing is said twice.
        #expect(NoticesNone.reading.words() == nil && NoticesNone.unread.words() == nil)
    }

    @Test("A key is named as a way to read again only where there is one")
    func touchNamesNoKey() {
        for language in [DummyLanguage.english, .taiwanese] {
            let keys = NoticesLine.unread(host: "a.example").words(language: language)
            let finger = NoticesLine.unread(host: "a.example").words(language: language, touch: true)
            #expect(keys.contains("or r,") || keys.contains("或 r"))
            #expect(!finger.contains("or r,") && !finger.contains("或 r"))
            #expect(finger.contains("a.example") && !finger.hasPrefix("notices."))
        }
    }

    @Test("j on the last line reads on, one stretch a press and never while a read is on the wire; the lamp otherwise walks")
    func jOnTheLastLine() {
        let ids = ["a", "b", "c"]
        #expect(FediqoRootView.noticesStep(in: ids, from: nil, by: 1, hasMore: true) == .lamp("a"))
        #expect(FediqoRootView.noticesStep(in: ids, from: "a", by: 1, hasMore: true) == .lamp("b"))
        // Arriving on the last line reads nothing — nor does a pointer that selects it, which
        // is not this function at all; the press after it does.
        #expect(FediqoRootView.noticesStep(in: ids, from: "b", by: 1, hasMore: true) == .lamp("c"))
        #expect(FediqoRootView.noticesStep(in: ids, from: "c", by: 1, hasMore: true) == .readOn)
        // A stretch that brought only kinds left out leaves the lamp where it was: again.
        #expect(FediqoRootView.noticesStep(in: ids, from: "c", by: 1, hasMore: true) == .readOn)
        // `hasMore` is false while a read is on the wire, and at the end.
        #expect(FediqoRootView.noticesStep(in: ids, from: "c", by: 1, hasMore: false) == .nothing)
        #expect(FediqoRootView.noticesStep(in: ids, from: "c", by: -1, hasMore: true) == .lamp("b"))
        #expect(FediqoRootView.noticesStep(in: ids, from: "a", by: -1, hasMore: true) == .nothing)
        // Narrowed to nothing, there is no line to stand on and `j` is the press on the foot.
        #expect(FediqoRootView.noticesStep(in: [], from: nil, by: 1, hasMore: true) == .readOn)
        #expect(FediqoRootView.noticesStep(in: [], from: nil, by: -1, hasMore: true) == .nothing)
    }

    @Test("The foot says there is more, that it is on its way, where the list is held, or that there is no more")
    func foot() {
        let floor = Self.at
        #expect(NoticesFoot.foot(hasMore: true, isReading: false, floor: floor) == .more)
        #expect(NoticesFoot.foot(hasMore: false, isReading: true, floor: floor) == .reading)
        #expect(NoticesFoot.foot(hasMore: false, isReading: false, floor: floor) == .held)
        #expect(NoticesFoot.foot(hasMore: false, isReading: false, floor: nil) == .end)
        #expect(NoticesFoot.more.words(language: .english) == "Older notices can be read. Press here, or scroll to here, to read them.")
        #expect(NoticesFoot.end.words(language: .english) == "No older notices: every source has sent all it has.")
        for foot in [NoticesFoot.more, .reading, .held, .end] {
            #expect(!foot.words(language: .taiwanese).hasPrefix("notices."))
        }
    }

    // MARK: - Narrowing

    @Test("The choice lists each named kind, the server's words that are held or left out, and everything else as one")
    func narrowable() {
        let fixed = ["mention", "reblog", "favourite", "follow", "follow_request", "quote", "poll", "update"]
        #expect(NoticeWords.narrowable(held: [], hidden: []) == fixed + ["unknown"])
        let held = [Self.notice(.server("moderation_warning"), people: []), Self.notice(.unknown("annual_report"), people: [])]
        #expect(
            NoticeWords.narrowable(held: held, hidden: ["admin.report", "favourite"])
                == fixed + ["admin.report", "moderation_warning", "unknown"]
        )
        for kind in fixed + ["unknown", "moderation_warning", "admin.report", "admin.sign_up", "severed_relationships"] {
            for language in [DummyLanguage.english, .taiwanese] {
                #expect(NoticeWords.kindName(kind, language: language) != kind, "\(kind) has no name in \(language)")
            }
        }
        #expect(NoticeWords.kindName("some_new_word", language: .english) == "some_new_word")
        #expect(NoticeWords.kindName("unknown", language: .english) == "Everything else")
    }

    @Test("Choosing a kind leaves it out or shows it again, and the head says how many are left out")
    func choosing() {
        #expect(NoticeKindsMenu.choosing("favourite", shown: false, among: []) == ["favourite"])
        #expect(NoticeKindsMenu.choosing("favourite", shown: true, among: ["favourite", "poll"]) == ["poll"])
        #expect(NoticeWords.narrowed([], language: .english) == "Every kind")
        #expect(NoticeWords.narrowed(["poll"], language: .english) == "1 kind left out")
        #expect(NoticeWords.narrowed(["poll", "favourite"], language: .english) == "2 kinds left out")
        #expect(NoticeWords.narrowed(["poll", "favourite"], language: .taiwanese) == "略過 2 種")
    }

    // MARK: - The keys, and the walk a line begins

    @Test("The keys act on Notices only with it in front and nothing drawn over it; r needs somebody to ask")
    func inFront() {
        #expect(FediqoRootView.noticesInFront(place: .notices, open: []))
        // The timeline's own walk, search and lamp are not on screen here.
        #expect(FediqoRootView.noticesInFront(place: .notices, open: [.thread, .search, .selection]))
        #expect(!FediqoRootView.noticesInFront(place: .notices, open: [.shortcuts]))
        #expect(!FediqoRootView.noticesInFront(place: .notices, open: [.viewer]))
        #expect(!FediqoRootView.noticesInFront(place: .timeline, open: []))
        #expect(FediqoRootView.canReadNotices(place: .notices, open: [], asked: true))
        #expect(!FediqoRootView.canReadNotices(place: .notices, open: [], asked: false))
        #expect(!FediqoRootView.canReadNotices(place: .notices, open: [.shortcuts], asked: true))
        #expect(NoticesPane.reloadName(.reload) == "notices.reload" && NoticesPane.reloadName(.stop) == "notices.reload.stop")
    }

    @Test("A line's walk is one step over whatever the timeline's walk held, and is over when that step is left")
    func errand() throws {
        var walk = ShellWalk()
        let stood = walk.walk(to: .thread("held\u{1e}1"), from: "lamp")
        #expect(stood)
        let errand = try #require(
            NoticeErrand.setOut(to: .thread("a.example\u{1e}30"), for: "line", on: &walk, lamp: "held\u{1e}1")
        )
        #expect(errand == NoticeErrand(notice: "line", base: 1))
        #expect(walk.openedThread == "a.example\u{1e}30" && walk.depth == 2)
        #expect(!errand.isOver(walk))

        // A step further out from the conversation, and back: still on the errand.
        let person = DummyPerson(Self.ada, host: "a.example")!
        let further = walk.walk(to: .person(person), from: "a.example\u{1e}30")
        #expect(further)
        let inner = walk.back()
        #expect(inner?.lamp == "a.example\u{1e}30")
        #expect(!errand.isOver(walk))

        // Leaving the step the line took hands the timeline its own lamp back, and ends it.
        let left = walk.back()
        #expect(left?.lamp == "held\u{1e}1")
        #expect(errand.isOver(walk))
        #expect(walk.openedThread == "held\u{1e}1", "what the walk held before the errand was touched")
    }

    @Test("A line whose post the timeline's walk already stands on takes no step, so there is none to come back to Notices by")
    func noErrandToTheStepInFront() {
        var walk = ShellWalk()
        let step = ShellStep.thread("a.example\u{1e}30")
        let stood = walk.walk(to: step, from: "lamp")
        #expect(stood)
        #expect(NoticeErrand.setOut(to: step, for: "line", on: &walk, lamp: nil) == nil)
        #expect(walk.depth == 1, "a second step was taken")
        // Leaving it is leaving the timeline's own step, with the timeline's own lamp.
        let left = walk.back()
        #expect(left?.lamp == "lamp")
    }

    // MARK: - The place

    @Test("Notices is always entered, and nothing says why it is off")
    func alwaysEntered() {
        #expect(ShellAvailability.empty.allows(.notices))
        #expect(ShellAvailability.empty.reasonKey(for: .notices) == nil)
        #expect(ShellAvailability.empty.placing(.account, as: .notices) == .notices)
        #expect(L10n.t("shell.notices.disabled", language: .english) == "shell.notices.disabled", "the reason is gone")
    }

    @Test("Where a source is held to the most kept of one for a run, the foot says that and not that there are no more")
    func theFootSaysTheBoundWasReached() {
        #expect(NoticesFoot.foot(hasMore: false, isReading: false, floor: nil, full: true) == .full)
        #expect(NoticesFoot.foot(hasMore: false, isReading: false, floor: nil, full: false) == .end)
        // What is still to be read, or held up by a source named above, is said first.
        #expect(NoticesFoot.foot(hasMore: true, isReading: false, floor: nil, full: true) == .more)
        #expect(NoticesFoot.foot(hasMore: false, isReading: true, floor: nil, full: true) == .reading)
        #expect(NoticesFoot.foot(hasMore: false, isReading: false, floor: Self.at, full: true) == .held)
        #expect(NoticesFoot.full.words(language: .english)
            == "Older notices are not read: Fediqo holds as many of one source as it keeps. They are read again once there is room — when notices are dismissed, or the months limit lets old ones go.")
        #expect(NoticesFoot.full.words(language: .english) != NoticesFoot.end.words(language: .english))
        let ours = NoticesFoot.full.words(language: .taiwanese)
        #expect(!ours.hasPrefix("notices.") && ours != NoticesFoot.end.words(language: .taiwanese))
        #expect(!NoticesFoot.full.symbol.isEmpty && NoticesFoot.full.symbol != NoticesFoot.end.symbol)
    }

    // MARK: - Three languages

    @Test("Every line of the page is in en, zh-TW and zh-Hant")
    func stringsInEveryLanguage() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI/Resources")
        func keys(_ lproj: String) throws -> Set<String> {
            let strings = try String(
                contentsOf: resources.appendingPathComponent("\(lproj).lproj/Localizable.strings"), encoding: .utf8
            )
            return Set(strings.split(separator: "\n").compactMap { line -> String? in
                guard line.hasPrefix("\"notices."), let end = line.dropFirst().firstIndex(of: "\"") else { return nil }
                return String(line[line.index(after: line.startIndex)..<end])
            })
        }
        // A language with no grammatical number carries no `.one`.
        let english = try keys("en").filter { !$0.hasSuffix(".one") }
        #expect(english.count > 50)
        for lproj in ["zh-TW", "zh-Hant"] {
            let missing = english.subtracting(try keys(lproj)).sorted()
            #expect(missing.isEmpty, "\(lproj) is missing \(missing)")
        }
    }
}
