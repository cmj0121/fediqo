import Foundation
import Testing
@testable import FediqoCore

@Suite("A timeline's rules")
struct RuleTests {
    private static let one = Source(host: "one.example", kind: .mastodon)
    private static let two = Source(host: "two.example", kind: .mastodon)
    private static let forum = Source(
        host: "forum.example", kind: .discuz, boards: [BoardSubscription(fid: 33, name: "Swift")]
    )
    private static let sources = [one, two, forum]

    private static func note(
        _ id: String,
        _ source: Source,
        by handle: String = "@ada@one.example",
        _ body: String = "hello",
        _ categories: Set<FediqoCore.Category> = [.public],
        boostedBy booster: String? = nil,
        title: String? = nil,
        spoiler: String? = nil
    ) -> Note {
        Note(id: id, source: source, author: "Someone", handle: handle, body: body, title: title,
             postedAt: Date(timeIntervalSince1970: 0), categories: categories,
             boosterHandle: booster, spoiler: spoiler)
    }

    /// One of every shape the rules below have to tell apart.
    private static let held: [Note] = [
        note("a1", one, by: "@ada@one.example", "Learning Swift today", [.public]),
        note("a2", two, by: "@ada@one.example", "Ada again, on two", [.public, .trends]),
        note("b1", one, by: "@bob@two.example", "a #swift tag", [.trends]),
        note("b2", two, by: "@bob@two.example", "nothing to see", [.public]),
        note("c1", one, by: "@cyd@one.example", "boosted by bob", [.public], boostedBy: "@bob@two.example"),
        note("f1", forum, by: "@ada@forum.example", "Swift on the forum", [.board(id: "33")]),
        note("f2", forum, by: "@eve@forum.example", "front page", []),
    ]

    private func shown(_ rules: [Rule?], sources: [Source] = sources, notes: [Note] = held) -> [String] {
        let timeline = CompiledTimeline(TimelineDefinition(name: "t", rules: rules.map { $0! }), sources: sources)
        return timeline.shown(notes, TextIndex(notes)).map(\.id)
    }

    private func verdicts(_ rules: [Rule]) -> [String: Verdict] {
        let timeline = CompiledTimeline(TimelineDefinition(name: "t", rules: rules), sources: Self.sources)
        let index = TextIndex(Self.held)
        return Dictionary(uniqueKeysWithValues: Self.held.map { ($0.id, timeline.verdict($0, index)) })
    }

    // MARK: - Each kind, for one source and for every source

    @Test("A source rule lets through that source and nothing else")
    func sourceRule() {
        #expect(shown([.source("one.example")]) == ["a1", "b1", "c1"])
        #expect(shown([.source("FORUM.example")]) == ["f1", "f2"])
    }

    @Test("An author rule for every source and for one")
    func authorRule() {
        #expect(shown([.author("ada@one.example", in: .every, sources: Self.sources)]) == ["a1", "a2"])
        #expect(shown([.author("ada@one.example", in: .source(host: "two.example"), sources: Self.sources)]) == ["a2"])
    }

    @Test("A keyword rule for every source and for one")
    func keywordRule() {
        #expect(shown([.keyword("swift", in: .every)]) == ["a1", "b1", "f1"])
        #expect(shown([.keyword("swift", in: .source(host: "one.example"))]) == ["a1", "b1"])
    }

    @Test("A category rule for every source and for one")
    func categoryRule() {
        #expect(shown([.category(.trends, in: .every, sources: Self.sources)]) == ["a2", "b1"])
        #expect(shown([.category(.trends, in: .source(host: "one.example"), sources: Self.sources)]) == ["b1"])
        #expect(shown([.category(.public, in: .every, sources: Self.sources)]) == ["a1", "a2", "b2", "c1"])
        #expect(shown([.category(.board(id: "33"), in: .source(host: "forum.example"), sources: Self.sources)])
            == ["f1"])
    }

    // MARK: - How rules combine

    @Test("Rules of one kind: any one lets a post through")
    func sameKindIsAny() {
        #expect(shown([.source("two.example"), .source("forum.example")]) == ["a2", "b2", "f1", "f2"])
        #expect(shown([.keyword("again", in: .every), .keyword("#swift", in: .every)]) == ["a2", "b1"])
    }

    @Test("Rules of different kinds: all must let it through")
    func differentKindsIsAll() {
        #expect(shown([.source("one.example"), .keyword("swift", in: .every)]) == ["a1", "b1"])
        #expect(shown([
            .source("one.example"),
            .keyword("swift", in: .every),
            .category(.trends, in: .every, sources: Self.sources),
        ]) == ["b1"])
    }

    @Test("An exclude hides what it matches whatever lets it through")
    func excludeAlwaysHides() {
        let rules: [Rule?] = [
            .source("one.example"),
            .author("ada@one.example", in: .every, effect: .exclude, sources: Self.sources),
        ]
        #expect(shown(rules) == ["b1", "c1"])
        // Even where the include names exactly what the exclude does.
        #expect(shown([.keyword("swift", in: .every), .keyword("SWIFT", in: .every, effect: .exclude)]) == [])
    }

    @Test("An exclude-only timeline is All less what it hides, and no rules is All")
    func excludeOnlyIsAllLess() {
        let everything = Self.held.map(\.id)
        #expect(shown([]) == everything)
        let exclude = Rule.keyword("swift", in: .every, effect: .exclude)!
        let hidden = Set(shown([.keyword("swift", in: .every)]))
        #expect(shown([exclude]) == everything.filter { !hidden.contains($0) })
        #expect(shown([exclude, .source("two.example", effect: .exclude)]) == ["c1", "f2"])
    }

    // MARK: - Every post left out is left out by a rule the timeline shows

    @Test("Every hidden post names one of the timeline's own rules, and the right one")
    func everyOmissionIsAttributed() throws {
        let excludeBob = Rule.author("bob@two.example", in: .every, effect: .exclude, sources: Self.sources)!
        let excludeFront = Rule.source("forum.example", effect: .exclude)!
        let sourceOne = Rule.source("one.example")!
        let sourceTwo = Rule.source("two.example")!
        let swift = Rule.keyword("swift", in: .every)!
        let trends = Rule.category(.trends, in: .every, sources: Self.sources)!
        let timelines: [[Rule]] = [
            [excludeBob],
            [sourceOne, sourceTwo, swift],
            [trends, swift, excludeBob, excludeFront],
            [swift, sourceOne, trends],
            TimelineDefinition.trends.rules,
        ]
        for rules in timelines {
            let ids = Set(rules.map(\.id))
            for (id, verdict) in verdicts(rules) {
                if case .hidden(let by) = verdict {
                    #expect(ids.contains(by), "\(id) was hidden by a rule the timeline does not show")
                }
            }
        }

        // An exclude that matches is named, the first of them in the reader's order.
        let both = verdicts([swift, excludeFront, excludeBob])
        #expect(both["f1"] == .hidden(by: excludeFront.id))
        #expect(both["b1"] == .hidden(by: excludeBob.id))
        // A kind no rule of which matched names its first rule, and the first failing kind is the
        // one put down: source before keyword before category, whatever order they were written.
        let missed = verdicts([trends, swift, sourceTwo, sourceOne])
        #expect(missed["f1"] == .hidden(by: sourceTwo.id))
        #expect(missed["a2"] == .hidden(by: swift.id))
        #expect(missed["a1"] == .hidden(by: trends.id))
        #expect(missed["b1"] == .shown)
    }

    // MARK: - Author

    @Test("An author is the full user@instance, folded, with or without its @")
    func authorIsFullHandle() {
        #expect(Rule.author("@Ada@One.Example", in: .every, sources: [])?.kind
            == .author(handle: "ada@one.example", in: .every))
        #expect(Rule.author("ada", in: .every, sources: []) == nil)
        #expect(Rule.author("", in: .every, sources: []) == nil)
        #expect(Rule.author("@", in: .every, sources: []) == nil)
        #expect(Rule.author("ada@", in: .every, sources: []) == nil)
        #expect(Rule.author("a@b@c", in: .every, sources: []) == nil)
        // The same person reached through two sources is one author.
        #expect(shown([.author("@ADA@one.example", in: .every, sources: Self.sources)]) == ["a1", "a2"])
    }

    @Test("A boost matches both who boosted it and who wrote it")
    func boostMatchesBoth() {
        #expect(shown([.author("bob@two.example", in: .every, sources: Self.sources)]) == ["b1", "b2", "c1"])
        #expect(shown([.author("cyd@one.example", in: .every, sources: Self.sources)]) == ["c1"])
    }

    @Test("A forum author is that forum's, so the rule is for that source")
    func forumAuthorIsItsSource() {
        let rule = Rule.author("ada@forum.example", in: .every, sources: Self.sources)
        #expect(rule?.kind == .author(handle: "ada@forum.example", in: .source(host: "forum.example")))
        // A forum this device does not hold is not known to be one, so the scope stands.
        #expect(Rule.author("ada@forum.example", in: .every, sources: [])?.kind
            == .author(handle: "ada@forum.example", in: .every))
        #expect(shown([rule]) == ["f1"])
    }

    @Test("A post that names nobody is matched by no author")
    func emptyHandleNeverMatches() {
        let nobody = Self.note("n", Self.one, by: "", "anonymous")
        #expect(shown([.author("ada@one.example", in: .every, sources: [])], notes: [nobody]) == [])
    }

    // MARK: - Keyword

    @Test("A keyword ignores case and full width against half width")
    func keywordFolds() {
        let notes = [
            Self.note("latin", Self.one, "I like SWIFT"),
            Self.note("wide", Self.one, "ＳＷＩＦＴ is wide"),
            Self.note("kana", Self.one, "ｽｲﾌﾄ in half width"),
            Self.note("other", Self.one, "Kotlin"),
        ]
        #expect(shown([.keyword("swift", in: .every)], notes: notes) == ["latin", "wide"])
        #expect(shown([.keyword("Ｓwift", in: .every)], notes: notes) == ["latin", "wide"])
        #expect(shown([.keyword("スイフト", in: .every)], notes: notes) == ["kana"])
        #expect(shown([.keyword("ｽｲﾌﾄ", in: .every)], notes: notes) == ["kana"])
    }

    @Test("An accent typed as one character or two is one spelling, and no accent is another word")
    func keywordComposes() {
        let notes = [
            Self.note("decomposed", Self.one, "a CAFE\u{301} downtown"),
            Self.note("plain", Self.one, "a cafe downtown"),
        ]
        #expect(shown([.keyword("Café", in: .every)], notes: notes) == ["decomposed"])
        #expect(shown([.keyword("cafe", in: .every)], notes: notes) == ["plain"])
    }

    @Test("A keyword matches anywhere, with no word breaking")
    func keywordMatchesMidWord() {
        let notes = [
            Self.note("mid", Self.one, "unswiftly"),
            Self.note("cjk", Self.one, "今天學習程式設計"),
            Self.note("none", Self.one, "swi ft"),
        ]
        #expect(shown([.keyword("swift", in: .every)], notes: notes) == ["mid"])
        #expect(shown([.keyword("程式", in: .every)], notes: notes) == ["cjk"])
    }

    @Test("A dotted capital I folds to the plain i a keyword is typed with")
    func turkishDottedI() {
        let notes = [Self.note("tr", Self.one, "İSTANBUL'da"), Self.note("other", Self.one, "Ankara")]
        #expect(shown([.keyword("istanbul", in: .every)], notes: notes) == ["tr"])
        #expect(shown([.keyword("İstanbul", in: .every)], notes: notes) == ["tr"])
    }

    /// The match reads bytes, and only a native string has them in one piece. macOS 15 folds to
    /// an `NSString`; a newer OS does not, so this is the line that fails where it matters.
    @Test("A folded key is native UTF-8, so a match reads its bytes on every OS")
    func foldedKeysAreNative() {
        for text in ["flags 🇦🇺🇸🇪 together", "ＳＷＩＦＴ", "İSTANBUL\u{00A0}da", ""] {
            #expect(Fold.key(text).isContiguousUTF8, "\(text) folded to a string with no bytes to read")
        }
        let bridged = NSString(string: "flags 🇦🇺🇸🇪 together") as String
        #expect(!Fold.contains(bridged, "🇺🇸"), "a string that did not come through key still splits a flag")
        #expect(Fold.contains(bridged, "🇦🇺"))
    }

    @Test("A match never splits a character: flags, marks and skin tones")
    func matchesWholeCharacters() {
        let notes = [
            Self.note("flags", Self.one, "flags 🇦🇺🇸🇪 together"),
            Self.note("us", Self.one, "the 🇺🇸 flag"),
            Self.note("marked", Self.one, "ye\u{331}s"),
            Self.note("plain", Self.one, "yes"),
            Self.note("toned", Self.one, "nice 👍🏽"),
            Self.note("thumb", Self.one, "nice 👍"),
        ]
        #expect(shown([.keyword("🇺🇸", in: .every)], notes: notes) == ["us"])
        #expect(shown([.keyword("🇦🇺", in: .every)], notes: notes) == ["flags"])
        #expect(shown([.keyword("yes", in: .every)], notes: notes) == ["plain"])
        #expect(shown([.keyword("ye\u{331}s", in: .every)], notes: notes) == ["marked"])
        // A skin tone makes a different character, so each thumb matches only itself.
        #expect(shown([.keyword("👍", in: .every)], notes: notes) == ["thumb"])
        #expect(shown([.keyword("👍🏽", in: .every)], notes: notes) == ["toned"])
    }

    @Test("A no-break space is a space, as the text arrives from HTML")
    func noBreakSpace() {
        let notes = [
            Self.note("nbsp", Self.one, HTMLText.plain("<p>hello&nbsp;world</p>")),
            Self.note("narrow", Self.one, "hello\u{202F}world"),
            Self.note("ideographic", Self.one, "hello\u{3000}world"),
            Self.note("joined", Self.one, "helloworld"),
        ]
        #expect(shown([.keyword("hello world", in: .every)], notes: notes) == ["nbsp", "narrow", "ideographic"])
    }

    @Test("A keyword matches with no word breaking, so #swift is inside #swiftui")
    func noWordBreaking() {
        let notes = [Self.note("ui", Self.one, "#SwiftUI tips"), Self.note("other", Self.one, "#kotlin")]
        #expect(shown([.keyword("#swift", in: .every)], notes: notes) == ["ui"])
    }

    @Test("#swift matches only the hashtag; swift matches the hashtag too")
    func hashtags() {
        let notes = [
            Self.note("tag", Self.one, "loving #Swift"),
            Self.note("word", Self.one, "loving swift"),
        ]
        #expect(shown([.keyword("#swift", in: .every)], notes: notes) == ["tag"])
        #expect(shown([.keyword("swift", in: .every)], notes: notes) == ["tag", "word"])
    }

    @Test("A keyword reads the post's body, not its title or its covering line")
    func keywordReadsBody() {
        let notes = [
            Self.note("title", Self.forum, "body", title: "Swift"),
            Self.note("spoiler", Self.one, "body", spoiler: "swift"),
            Self.note("body", Self.one, "swift"),
        ]
        #expect(shown([.keyword("swift", in: .every)], notes: notes) == ["body"])
    }

    @Test("An empty keyword is refused")
    func emptyKeyword() {
        #expect(Rule.keyword("", in: .every) == nil)
        #expect(Rule.keyword("  \n", in: .every) == nil)
        #expect(Rule.keyword(" swift ", in: .every)?.kind == .keyword(" swift ", in: .every))
        #expect(Rule.keyword("swift", in: .source(host: "")) == nil)
    }

    // MARK: - Category and source factories

    @Test("A board or list is never for every source; public and home never for a forum; trends for a Discuz! only")
    func categoryRejections() {
        let s = Self.sources
        #expect(Rule.category(.board(id: "33"), in: .every, sources: s) == nil)
        #expect(Rule.category(.list(id: "7"), in: .every, sources: s) == nil)
        // A Discuz!'s ranking lists are its Trends; a Discourse ranks nothing this app reads.
        #expect(Rule.category(.trends, in: .source(host: "forum.example"), sources: s)?.kind
            == .category(.trends, in: .source(host: "forum.example")))
        let talk = s + [Source(host: "talk.example", kind: .discourse)]
        #expect(Rule.category(.trends, in: .source(host: "talk.example"), sources: talk) == nil)
        #expect(Rule.category(.public, in: .source(host: "talk.example"), sources: talk) == nil)
        #expect(Rule.category(.public, in: .source(host: "forum.example"), sources: s) == nil)
        #expect(Rule.category(.home, in: .source(host: "forum.example"), sources: s) == nil)
        #expect(Rule.category(.home, in: .every, sources: s) != nil)
        #expect(Rule.category(.list(id: "7"), in: .source(host: "one.example"), sources: s) != nil)
        #expect(Rule.category(.trends, in: .source(host: "One.Example"), sources: s)?.kind
            == .category(.trends, in: .source(host: "one.example")))
        #expect(Rule.source("") == nil)
    }

    // MARK: - A rule naming something gone

    @Test("A rule naming a gone source or board stays, says so, and still matches what is held")
    func missingTargets() {
        let unsubscribed = Source(host: "forum.example", kind: .discuz)
        let remaining = [Self.one, unsubscribed]
        let sourceRule = Rule.source("two.example")!
        let scoped = Rule.keyword("again", in: .source(host: "two.example"))!
        let board = Rule.category(.board(id: "33"), in: .source(host: "forum.example"), sources: Self.sources)!
        let keyword = Rule.keyword("swift", in: .every)!
        let definition = TimelineDefinition(name: "t", rules: [sourceRule, scoped, board, keyword])
        let timeline = CompiledTimeline(definition, sources: remaining)

        #expect(timeline.definition.rules.count == 4)
        #expect(timeline.status(of: sourceRule) == .missingSource(host: "two.example"))
        #expect(timeline.status(of: scoped) == .missingSource(host: "two.example"))
        #expect(timeline.status(of: board) == .missingCategory)
        #expect(timeline.status(of: keyword) == .present)
        #expect(CompiledTimeline(definition, sources: Self.sources).status(of: board) == .present)

        for rules in [[sourceRule], [scoped], [board]] {
            let definition = TimelineDefinition(name: "t", rules: rules)
            let before = CompiledTimeline(definition, sources: Self.sources).shown(Self.held, TextIndex(Self.held))
            let after = CompiledTimeline(definition, sources: remaining).shown(Self.held, TextIndex(Self.held))
            #expect(after == before)
            #expect(!after.isEmpty)
        }
    }

    // MARK: - All and Trends

    @Test("All and Trends are fixed definitions: everything, and what arrived as trending")
    func builtIns() {
        let index = TextIndex([])
        #expect(CompiledTimeline(.all, sources: Self.sources).shown(Self.held, index) == Self.held)
        #expect(CompiledTimeline(.trends, sources: Self.sources).shown(Self.held, index).map(\.id) == ["a2", "b1"])
        #expect(TimelineDefinition.trends.id == TimelineDefinition.trends.id)
        #expect(TimelineDefinition.all.id != TimelineDefinition.trends.id)
    }

    // MARK: - Which sources to ask

    private func asks(_ rules: [Rule?], sources: [Source] = sources) -> [FetchAsk] {
        CompiledTimeline(TimelineDefinition(name: "t", rules: rules.map { $0! }), sources: sources).sourcesToAsk()
    }

    private func ask(_ host: String, _ categories: Set<FediqoCore.Category>? = nil) -> FetchAsk {
        FetchAsk(host: host, categories: categories)
    }

    @Test("All asks every source its usual reads; Trends asks each Mastodon and each Discuz! for trends")
    func asksForBuiltIns() {
        #expect(CompiledTimeline(.all, sources: Self.sources).sourcesToAsk()
            == [ask("one.example"), ask("two.example"), ask("forum.example")])
        #expect(CompiledTimeline(.trends, sources: Self.sources).sourcesToAsk()
            == [ask("one.example", [.trends]), ask("two.example", [.trends]), ask("forum.example", [.trends])])
        // A Discourse has no Trends, so the Trends tab never asks one.
        let talk = Self.sources + [Source(host: "talk.example", kind: .discourse)]
        #expect(!CompiledTimeline(.trends, sources: talk).sourcesToAsk().contains { $0.host == "talk.example" })
    }

    /// A forum's Trends reach it without public or home: a rule for every source's public
    /// timeline still passes a forum by, and one for every source's trends asks it for those alone.
    @Test("Trends reaches a Discuz!; public and home still do not")
    func trendsReachAForum() {
        #expect(!asks([.category(.public, in: .every, sources: Self.sources)]).contains { $0.host == "forum.example" })
        #expect(!asks([.category(.home, in: .every, sources: Self.sources)]).contains { $0.host == "forum.example" })
        #expect(asks([.category(.trends, in: .every, sources: Self.sources)]).last == ask("forum.example", [.trends]))
        #expect(asks([.category(.trends, in: .source(host: "forum.example"), sources: Self.sources)])
            == [ask("forum.example", [.trends])])
        let board = Rule.category(.board(id: "33"), in: .source(host: "forum.example"), sources: Self.sources)
        #expect(asks([board, .category(.trends, in: .source(host: "forum.example"), sources: Self.sources)])
            == [ask("forum.example", [.board(id: "33"), .trends])])
    }

    @Test("Include kinds narrow the sources asked, and categories say what to ask for")
    func asksNarrow() {
        #expect(asks([.author("ada@one.example", in: .every, sources: Self.sources)])
            == [ask("one.example"), ask("two.example"), ask("forum.example")])
        #expect(asks([.keyword("x", in: .source(host: "two.example"))]) == [ask("two.example")])
        #expect(asks([
            .source("one.example"), .source("forum.example"),
            .category(.public, in: .every, sources: Self.sources),
        ]) == [ask("one.example", [.public])])
        #expect(asks([
            .category(.board(id: "33"), in: .source(host: "forum.example"), sources: Self.sources),
            .category(.trends, in: .source(host: "two.example"), sources: Self.sources),
        ]) == [ask("two.example", [.trends]), ask("forum.example", [.board(id: "33")])])
    }

    @Test("An excluded source is not asked; an excluded category is not asked for")
    func asksLessExcludes() {
        #expect(asks([.source("two.example", effect: .exclude)]) == [ask("one.example"), ask("forum.example")])
        #expect(asks([
            .category(.public, in: .every, sources: Self.sources),
            .category(.trends, in: .every, sources: Self.sources),
            .category(.trends, in: .source(host: "one.example"), effect: .exclude, sources: Self.sources),
        ]) == [
            ask("one.example", [.public]), ask("two.example", [.public, .trends]),
            ask("forum.example", [.trends]),
        ])
        #expect(asks([
            .category(.trends, in: .every, sources: Self.sources),
            .category(.trends, in: .every, effect: .exclude, sources: Self.sources),
        ]) == [])
    }

    @Test("A rule naming something gone asks nothing")
    func asksSkipMissing() {
        let remaining = [Self.one, Source(host: "forum.example", kind: .discuz)]
        #expect(asks([.source("two.example")], sources: remaining) == [])
        #expect(asks([.source("two.example"), .source("one.example")], sources: remaining) == [ask("one.example")])
        #expect(asks([
            .category(.board(id: "33"), in: .source(host: "forum.example"), sources: Self.sources),
        ], sources: remaining) == [])
    }

    @Test("A list rule is present only while the list is chosen, and a missing list is not asked for")
    func listRules() {
        let chosen = Source(host: "one.example", kind: .mastodon, lists: [ListSubscription(id: "7", name: "Friends")])
        let unchosen = Source(host: "one.example", kind: .mastodon)
        let rule = Rule.category(.list(id: "7"), in: .source(host: "one.example"), sources: [chosen])!
        let other = Rule.category(.list(id: "8"), in: .source(host: "one.example"), sources: [chosen])!
        let definition = TimelineDefinition(name: "t", rules: [rule])

        #expect(CompiledTimeline(definition, sources: [chosen]).status(of: rule) == .present)
        #expect(CompiledTimeline(definition, sources: [chosen]).status(of: other) == .missingCategory)
        #expect(CompiledTimeline(definition, sources: [unchosen]).status(of: rule) == .missingCategory)
        #expect(asks([rule], sources: [chosen]) == [ask("one.example", [.list(id: "7")])])
        #expect(asks([rule], sources: [unchosen]) == [])
        #expect(asks([rule, other], sources: [chosen]) == [ask("one.example", [.list(id: "7")])])

        let held = [Self.note("l1", Self.one, "on a list", [.list(id: "7")])]
        #expect(CompiledTimeline(definition, sources: [unchosen]).shown(held, TextIndex(held)) == held,
                "a list no longer chosen stopped matching what it brought")
    }

    // MARK: - The index

    @Test("A rebuilt index folds only the notes that changed")
    func indexReuse() {
        let first = TextIndex(Self.held)
        #expect(first.folded == Self.held.count)
        var changed = Self.held
        changed[0] = Self.note("a1", Self.one, "edited")
        let second = TextIndex(changed + [Self.note("new", Self.two)], reusing: first)
        #expect(second.folded == 2)
        #expect(second.entry(for: changed[0]).text == "edited")
    }

    @Test("10,000 notes against 20 rules stay inside the budget")
    func performance() {
        let hosts = (0..<10).map { Source(host: "h\($0).example", kind: .mastodon) }
        let words = ["swift", "kotlin", "rust", "#fediverse", "ｶﾀｶﾅ", "Café", "coffee", "tea", "news", "art"]
        let notes = (0..<10_000).map { i in
            Self.note(
                "\(i)", hosts[i % 7], by: "@user\(i % 4)@h\(i % 4).example",
                String(repeating: "Some ordinary words about the day and \(words[i % words.count]) ", count: 4),
                i % 3 == 0 ? [.trends] : [.public],
                boostedBy: i % 11 == 0 ? "@booster@h1.example" : nil
            )
        }
        // Half the keywords never match, so most notes are read against all ten.
        var rules: [Rule] = words.enumerated().map { i, word in Rule.keyword(i < 5 ? word + "x" : word, in: .every)! }
        rules += (0..<4).map { Rule.author("user\($0)@h\($0).example", in: .every, sources: hosts)! }
        rules += (0..<3).map { Rule.source("h\($0).example")! }
        rules += [
            Rule.category(.public, in: .every, sources: hosts)!,
            Rule.keyword("nothing", in: .every, effect: .exclude)!,
            Rule.author("booster@h1.example", in: .every, effect: .exclude, sources: hosts)!,
        ]
        #expect(rules.count == 20)

        let plain = Pace.plainRead(notes)
        var index = TextIndex([])
        var shown: [Note] = []
        let indexing = Pace.fastest { index = TextIndex(notes) }
        let evaluating = Pace.fastest {
            shown = CompiledTimeline(TimelineDefinition(name: "t", rules: rules), sources: hosts).shown(notes, index)
        }
        #expect(!shown.isEmpty)
        // Against the plain read of the same notes (`Pace`), measured the same way just before.
        // Debug measured about 2.8 plain reads to index and 0.72 to evaluate, at most 3.7 and 1.0
        // across thirty runs — at normal and background priority and counting coverage, where a
        // plain read took 70 to 220 ms. The lines leave twice that and more, and an index or a
        // timeline made five times dearer is past them. They are drawn for the debug build
        // `swift test` makes: release measured 1.0 and 0.27, as a plain read is library code
        // either way and gains nothing from it.
        #expect(indexing < plain * 10, "indexing took \(indexing), \(indexing / plain) plain reads of \(plain)")
        #expect(evaluating < plain * 5 / 2, "evaluating took \(evaluating), \(evaluating / plain) plain reads of \(plain)")
    }
}
