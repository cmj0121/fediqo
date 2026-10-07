import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// The person can see what they keep, and let all of it go at once (#294).
///
/// What a test can reach: the lines the Keep tab draws from — count and weight for every source
/// together and for each, a removed source's under its name; the one act that stops keeping and
/// the question before it; what every question that lets posts go, or brings posts in, says of
/// the kept ones, in every language and inside a line. What it cannot: the section drawn in
/// light and dark, on a Mac and a phone.
@Suite("What is kept, seen and let go of at once")
@MainActor
struct KeptInventoryTests {
    private static let one = Source(host: "one.example", kind: .mastodon)
    private static let two = Source(host: "two.example", kind: .mastodon)
    private static let origin = Date(timeIntervalSince1970: 1_800_000_000)
    nonisolated private static let languages = [DummyLanguage.english, .taiwanese]

    private static func post(_ id: Int, _ source: Source = one, body: String = "hello", kept: Bool = false) -> Note {
        Note(
            id: "https://\(source.host)/\(id)", source: source, author: "Ada", handle: "@ada", body: body,
            postedAt: origin.addingTimeInterval(Double(id) * 86_400), categories: [.public], statusID: "\(id)",
            kept: kept
        )
    }

    /// A session over two sources: three posts kept from the first, one from the second, and
    /// one of each not kept.
    private func shell() async -> ShellSession {
        let store = ItemStore(sources: [Self.one, Self.two], notes: [
            Self.post(1, body: "aaaa", kept: true), Self.post(2, body: "bb", kept: true), Self.post(3, body: "c", kept: true),
            Self.post(4), Self.post(5, Self.two, body: "dddddd", kept: true), Self.post(6, Self.two),
        ])
        let session = ShellSession(http: FixtureHTTP(), store: store)
        await session.reloadFromStore()
        return session
    }

    private func lines(_ session: ShellSession) -> [KeptSection.Line] {
        KeptSection.lines(session.holdings, sources: session.sources.map(\.host))
    }

    // MARK: - Seen

    @Test("With posts kept from two sources, each is listed with its count and what its words weigh; after one is removed its kept posts are still counted, under its name and said to be removed")
    func bySource() async {
        let session = await shell()
        #expect(lines(session) == [
            .init(host: Self.one.host, kept: .init(posts: 3, bytes: 7), removed: false),
            .init(host: Self.two.host, kept: .init(posts: 1, bytes: 6), removed: false),
        ])
        #expect(session.holdings.kept == .init(posts: 4, bytes: 13))
        #expect(KeptSection.figure(session.holdings.kept(host: Self.one.host), language: .english) == "3 kept · 7 bytes of words")

        await session.remove(host: Self.one.host)
        #expect(session.sources.map(\.host) == [Self.two.host], "the premise: the source is gone")
        let after = lines(session)
        #expect(after == [
            .init(host: Self.two.host, kept: .init(posts: 1, bytes: 6), removed: false),
            .init(host: Self.one.host, kept: .init(posts: 3, bytes: 7), removed: true),
        ], "a removed source's kept posts are not counted under its name")
        #expect(KeptSection.name(after[1], language: .english) == "one.example · source removed")
        #expect(KeptSection.name(after[0], language: .english) == "two.example")
    }

    @Test("Nothing kept is one line saying so, and no source is listed")
    func nothingKept() async {
        let session = ShellSession(http: FixtureHTTP(), store: ItemStore(sources: [Self.one], notes: [Self.post(1)]))
        await session.reloadFromStore()
        #expect(lines(session).isEmpty && session.holdings.kept == .none)
    }

    @Test("Every word of the section is said in every language, and a figure never reads as a key", arguments: languages)
    func theWords(_ language: DummyLanguage) {
        for key in [
            "usage.kept", "usage.kept.line", "usage.kept.help", "usage.kept.none", "usage.kept.stop",
            "usage.kept.stop.help", "usage.kept.went.none", "usage.kept.ask.detail",
        ] {
            #expect(L10n.t(key, language: language) != key, "\(key) has no words in \(language)")
        }
        let figure = KeptSection.figure(.init(posts: 2, bytes: 2_048), language: language)
        #expect(figure.contains("2") && !figure.contains("usage.") && !figure.contains("%"))
        #expect(!KeptSection.wentLine(.init(ordinary: 3, elsewhere: 2), language: language).contains("%"))
        #expect(KeptSection.wentLine(.init(), language: language) == L10n.t("usage.kept.went.none", language: language))
    }

    // MARK: - Let go of at once

    @Test("Stop keeping for one source asks first and names the count; a yes un-keeps exactly those and lets nothing go, and the next letting go takes them")
    func stopKeepingOneSource() async {
        let session = await shell()
        let ask = KeptAsk(host: Self.one.host, posts: session.holdings.kept(host: Self.one.host).posts)
        let question = ShellQuestion.stopKeeping(ask, language: .english)
        #expect(question.title == "Stop keeping 3 posts?")
        #expect(question.line == "From one.example. Nothing goes now.")
        #expect(question.choices.map(\.role) == [.destructive] && question.warns)
        #expect(session.notes.filter(\.kept).count == 4, "asking changed nothing")

        #expect(await session.stopKeeping(host: Self.one.host) == StoppedKeeping(ordinary: 3, elsewhere: 0))
        #expect(session.notes.count == 6, "stopping keeping let a post go")
        #expect(lines(session).map(\.host) == [Self.two.host])
        #expect(session.notes.filter(\.kept).map(\.source.host) == [Self.two.host])

        // Ordinary posts now: the reader's next letting go takes them, and leaves the one kept.
        let went = await session.letGo(span: Self.origin..<Self.origin.addingTimeInterval(100 * 86_400), host: nil)
        #expect(went == 5)
        #expect(session.notes.map(\.source.host) == [Self.two.host])
    }

    @Test("Stop keeping all reaches every source, one that has been removed included, and says how many")
    func stopKeepingAll() async {
        let session = await shell()
        await session.remove(host: Self.one.host)
        #expect(ShellQuestion.stopKeeping(KeptAsk(host: nil, posts: 4), language: .english).line == "From every source. Nothing goes now.")
        #expect(await session.stopKeeping(host: nil) == StoppedKeeping(ordinary: 4, elsewhere: 0))
        #expect(lines(session).isEmpty)
        #expect(await session.stopKeeping(host: nil) == StoppedKeeping(), "and a second press finds none")
    }

    @Test("The removed source's own press un-keeps its posts and nobody else's")
    func stopKeepingARemovedSource() async {
        let session = await shell()
        await session.remove(host: Self.one.host)
        #expect(await session.stopKeeping(host: Self.one.host).ordinary == 3)
        #expect(lines(session) == [.init(host: Self.two.host, kept: .init(posts: 1, bytes: 6), removed: false)])
    }

    @Test("The question is a title with the count and one line, in every language", arguments: languages)
    func theQuestion(_ language: DummyLanguage) {
        for ask in [KeptAsk(host: "a.example", posts: 1), KeptAsk(host: nil, posts: 12)] {
            let question = ShellQuestion.stopKeeping(ask, language: language)
            #expect(question.title.contains("\(ask.posts)") && !question.title.contains("%"))
            #expect(ShellQuestion.width(question.line) <= ShellQuestion.lineLength && !question.line.contains("%"))
            #expect(question.help != nil && question.help != question.line)
        }
    }

    // MARK: - A post two sources carry

    /// One post as `source` carries it: the same name on both, as a boost or a federated copy is.
    private static func shared(_ name: String, _ source: Source, kept: Bool) -> Note {
        Note(
            id: "https://origin.example/\(name)", source: source, author: "Ada", handle: "@ada@origin.example",
            body: name, postedAt: origin, categories: [.public], statusID: "\(source.host)-\(name)", kept: kept
        )
    }

    /// Kept from the first source: a post the second keeps too, and one that is the first's alone.
    private func sharing() async -> ShellSession {
        let store = ItemStore(sources: [Self.one, Self.two], notes: [
            Self.shared("both", Self.one, kept: true), Self.shared("both", Self.two, kept: true),
            Self.shared("mine", Self.one, kept: true),
        ])
        let session = ShellSession(http: FixtureHTTP(), store: store)
        await session.reloadFromStore()
        return session
    }

    @Test("Stopping keeping one source's posts counts only the ones that will be ordinary, says how many stay kept through another source, and leaves that source's copies alone")
    func keptThroughAnotherSource() async throws {
        let session = await sharing()
        let line = try #require(lines(session).first { $0.host == Self.one.host })
        #expect(line.kept.posts == 2 && line.elsewhere == 1)
        let ask = KeptSection.ask(line)
        #expect(ask == KeptAsk(host: Self.one.host, posts: 1, elsewhere: 1))
        let question = ShellQuestion.stopKeeping(ask, language: .english)
        #expect(question.title == "Stop keeping 1 post?", "a post that stays kept was counted as let be ordinary")
        #expect(says(question, "1 stays kept through another source."), "\(question.line) / \(question.help ?? "")")

        let went = await session.stopKeeping(host: Self.one.host)
        #expect(went == StoppedKeeping(ordinary: 1, elsewhere: 1))
        #expect(KeptSection.wentLine(went, language: .english) == "1 post is no longer kept. 1 stays kept through another source.")
        let kept = session.notes.filter(\.kept)
        #expect(kept.map(\.source.host) == [Self.two.host], "the other source's copy was un-kept, or this one's was not")
        // The row two sources carry is still drawn kept; the one that was this source's alone is not.
        let rows = session.timelineItems(latest: nil)
        #expect(rows.first { $0.noteID.hasSuffix("both") }?.kept == true)
        #expect(rows.first { $0.noteID.hasSuffix("mine") }?.kept == false)
    }

    @Test("A source whose every kept post is kept through another source too has nothing to make ordinary: the press says so, and every source's press is what reaches them")
    func nothingToMakeOrdinary() async throws {
        let session = await sharing()
        let line = try #require(lines(session).first { $0.host == Self.two.host })
        #expect(KeptSection.ask(line) == KeptAsk(host: Self.two.host, posts: 0, elsewhere: 1))
        #expect(KeptSection.wentLine(.init(ordinary: 0, elsewhere: 1), language: .english) == "1 stays kept through another source.")

        #expect(await session.stopKeeping(host: nil) == StoppedKeeping(ordinary: 3, elsewhere: 0))
        #expect(session.timelineItems(latest: nil).allSatisfy { !$0.kept })
    }

    // MARK: - What a question that lets posts go says of them

    /// Whether `question` says `sentence`, on its line or behind its (?).
    private func says(_ question: ShellConfirmation, _ sentence: String) -> Bool {
        question.line.contains(sentence) || (question.help ?? "").contains(sentence)
    }

    @Test("Removing a source with kept posts says how many will stay, read off what the session holds; with none kept, or where its posts all stay, the question is as it was")
    func removingASource() async {
        let session = await shell()
        let asked = session.removeQuestion(host: Self.one.host, postsStay: false)
        #expect(asked.line == "Its posts and what is held for it go; the 3 you keep stay.")
        #expect(asked.help == "Its posts and what this device holds for it go.", "and the (?) says the rest, once")
        #expect(session.removeQuestion(host: Self.two.host, postsStay: false).line
            == "Its posts and what is held for it go; the one you keep stays.")
        let boards = ShellQuestion.remove(host: "a.example", boards: 8, kept: 3, language: .english)
        #expect(boards.line == "Its posts and the 8 boards you picked go; the 3 you keep stay.")
        #expect(boards.help?.contains("The boards do not come back.") == true)

        let plain = ShellQuestion.remove(host: "a.example", boards: 0, language: .english)
        #expect(ShellQuestion.remove(host: "a.example", boards: 0, kept: 0, language: .english) == plain)
        #expect(session.removeQuestion(host: Self.one.host, postsStay: true)
            == ShellQuestion.remove(host: Self.one.host, boards: 0, postsStay: true))
    }

    @Test("Every question that lets posts go says the count of kept ones that stay, inside a line or behind the (?), in every language", arguments: languages)
    func whatStays(_ language: DummyLanguage) throws {
        let ask = SpanAsk(from: Self.origin, to: Self.origin, host: "a.example").counting(4, kept: 2)
        let questions: [(ShellConfirmation, ShellConfirmation, Int)] = [
            (ShellQuestion.letGo(posts: 3, places: 0, kept: 2, language: language),
             ShellQuestion.letGo(posts: 3, places: 0, language: language), 2),
            (ShellQuestion.letGo(posts: 3, places: 2, kept: 12, language: language),
             ShellQuestion.letGo(posts: 3, places: 2, language: language), 12),
            (ShellQuestion.letGo(ask, language: language),
             ShellQuestion.letGo(ask.counting(4), language: language), 2),
        ]
        for (counted, plain, kept) in questions {
            let sentence = try #require(ShellQuestion.keptStay(kept, language: language))
            #expect(sentence.contains("\(kept)") && !sentence.contains("%"))
            #expect(says(counted, sentence), "\(counted.line) / \(counted.help ?? "")")
            #expect(!says(plain, sentence), "said with nothing kept")
            #expect(ShellQuestion.width(counted.line) <= ShellQuestion.lineLength, "\(counted.line) is more than a line")
            #expect(counted.title == plain.title && counted.choices == plain.choices)
            try saidOnce(counted, language)
        }
        // Removing a source says it on the line itself, whatever else the line must name.
        for (boards, kept) in [(0, 1), (0, 12), (8, 1), (40, 120)] {
            let counted = ShellQuestion.remove(host: "a.example", boards: boards, kept: kept, language: language)
            let plain = ShellQuestion.remove(host: "a.example", boards: boards, language: language)
            #expect(counted.line != plain.line && !counted.line.contains("%"))
            #expect(kept == 1 || counted.line.contains("\(kept)"), "\(counted.line) does not say how many")
            #expect(boards == 0 || counted.line.contains("\(boards)"))
            #expect(ShellQuestion.width(counted.line) <= ShellQuestion.lineLength, "\(counted.line) is more than a line")
            #expect(counted.title == plain.title && counted.choices == plain.choices && counted.help != counted.line)
            try saidOnce(counted, language)
        }
        // Where only places go no post goes, so there is nothing to say stays.
        #expect(ShellQuestion.letGo(posts: 0, places: 2, kept: 5, language: language)
            == ShellQuestion.letGo(posts: 0, places: 2, language: language))
    }

    /// The question says once that kept posts stay: the counted sentence, and not the uncounted
    /// one the same question says where nothing is counted.
    private func saidOnce(_ question: ShellConfirmation, _ language: DummyLanguage) throws {
        let all = question.line + " " + (question.help ?? "")
        for uncounted in language == .english ? ["A post you keep stays", "a post you keep stays"] : ["你留下的貼文會保留"] {
            #expect(!all.contains(uncounted), "said twice: \(all)")
        }
        let stays = language == .english ? "keep stay" : "則會保留"
        #expect(all.components(separatedBy: stays).count == 2, "kept posts staying is said \(all.components(separatedBy: stays).count - 1) times: \(all)")
    }

    @Test("A line is measured as it is drawn: a wide character takes two columns, so a Chinese line half as long is as wide")
    func width() {
        #expect(ShellQuestion.width("abc, def.") == 9)
        #expect(ShellQuestion.width("你留下的") == 8)
        #expect(ShellQuestion.width("留下 3 則。") == 11)
        // Thirty-three wide characters and two more with their stops are seventy columns: a line.
        let fits = String(repeating: "字", count: 33)
        #expect(ShellQuestion.saying("一。", line: fits, help: nil, language: .taiwanese).line == fits + "一。")
        // One more is seventy-two — thirty-six characters, which a count of characters would pass.
        let over = String(repeating: "字", count: 34)
        let behind = ShellQuestion.saying("一。", line: over, help: nil, language: .taiwanese)
        #expect(behind.line == over && behind.help == "一。")
    }

    @Test("The sentence goes on the line where the line can take it, and behind the (?) where it cannot")
    func whereItIsSaid() {
        let short = ShellQuestion.saying("Two.", line: "One.", help: "More.", language: .english)
        #expect(short.line == "One. Two." && short.help == "More.")
        let long = String(repeating: "x", count: 68) + "."
        let behind = ShellQuestion.saying("Two.", line: long, help: "More.", language: .english)
        #expect(behind.line == long && behind.help == "More. Two.")
        #expect(ShellQuestion.saying("Two.", line: long, help: nil, language: .english).help == "Two.")
        #expect(ShellQuestion.saying(nil, line: "One.", help: nil, language: .english) == ("One.", nil))
        #expect(ShellQuestion.saying("二。", line: "一。", help: nil, language: .taiwanese).line == "一。二。")
    }

    @Test("What a span and what is marked gone would leave for being kept is counted at the press")
    func countedAtThePress() async {
        let session = await shell()
        let span = Self.origin..<Self.origin.addingTimeInterval(10 * 86_400)
        #expect(await session.spanHeld(span, host: nil) == 2)
        #expect(await session.spanKept(span, host: nil) == 4)
        #expect(await session.spanKept(span, host: Self.two.host) == 1)
        #expect(await session.goneKept() == 0)
        for note in session.notes where note.source.host == Self.one.host { await session.store.markGone(note.key) }
        #expect(await session.goneKept() == 3)
        #expect(await session.goneHeld().posts == 1)
    }

    // MARK: - What a question that brings posts in says of them

    private static func summary(kept: Int?, contents: PackageSummary.Contents = .whole) -> PackageSummary {
        PackageSummary(
            contents: contents, sources: [.init(host: "a.example", kind: .mastodon)], posts: 12, timelines: 2,
            takenAt: origin, withPictures: false, bytes: 3_000, hasSecrets: true, device: "a laptop",
            appVersion: "0.7.0", entryCount: 5, kept: kept
        )
    }

    @Test("Reading back says how many of the posts are kept before the yes — some, none, or that the package does not say — in every language and inside a line", arguments: languages)
    func readingBack(_ language: DummyLanguage) {
        let some = ShellQuestion.readBack(Self.summary(kept: 5), held: true, language: language)
        #expect(says(some, ShellQuestion.keptBrought(5, language: language)))
        #expect(ShellQuestion.keptBrought(5, language: language).contains("5"))
        let none = ShellQuestion.readBack(Self.summary(kept: 0), held: false, language: language)
        #expect(says(none, L10n.t("question.kept.brought.none", language: language)))
        let unsaid = ShellQuestion.readBack(Self.summary(kept: nil), held: false, language: language)
        #expect(says(unsaid, L10n.t("question.kept.brought.unsaid", language: language)))
        for question in [some, none, unsaid] {
            #expect(ShellQuestion.width(question.line) <= ShellQuestion.lineLength && !question.line.contains("%"))
        }
        // Sign-ins alone bring no posts, and nothing is said of any.
        let signIns = ShellQuestion.readBack(Self.summary(kept: nil, contents: .signInsOnly), held: false, language: language)
        #expect(!says(signIns, L10n.t("question.kept.brought.unsaid", language: language)))
    }

    @Test("Holding what another device moves, and moving it, say how many of the posts are kept", arguments: languages)
    func nearby(_ language: DummyLanguage) {
        for receiving in [true, false] {
            let offer = NearbyOffer(id: "o", summary: Self.summary(kept: 3), fileBytes: 3_100)
            let ask = ShellNearby.Ask(offer: offer, peer: "a tablet", held: true, receiving: receiving)
            let question = ShellQuestion.nearbyAsk(ask, language: language)
            #expect(says(question, ShellQuestion.keptBrought(3, language: language)), "\(question.line)")
            #expect(ShellQuestion.width(question.line) <= ShellQuestion.lineLength)
        }
        let older = NearbyOffer(id: "o", summary: Self.summary(kept: nil), fileBytes: 3_100)
        let unsaid = ShellQuestion.nearbyAsk(.init(offer: older, peer: "a tablet", held: false, receiving: true), language: language)
        #expect(says(unsaid, L10n.t("question.kept.brought.unsaid", language: language)))
        let signIns = NearbyOffer(id: "o", summary: Self.summary(kept: nil, contents: .signInsOnly), fileBytes: 10)
        let only = ShellQuestion.nearbyAsk(.init(offer: signIns, peer: "a tablet", held: false, receiving: true), language: language)
        #expect(!says(only, L10n.t("question.kept.brought.unsaid", language: language)))
    }

    // MARK: - The read back's own flow

    @Test("The question the read back asks is made from what the package's header says, and of one that says nothing, that it does not say")
    func theFlowsQuestion() {
        let file = URL(fileURLWithPath: "/tmp/x")
        let said = CarryFlow.question(.previewing(.init(url: file, summary: Self.summary(kept: 4), held: false)))
        #expect(says(said, ShellQuestion.keptBrought(4)))
        let unsaid = CarryFlow.question(.previewing(.init(url: file, summary: Self.summary(kept: nil), held: false)))
        #expect(says(unsaid, L10n.t("question.kept.brought.unsaid")))
    }
}
