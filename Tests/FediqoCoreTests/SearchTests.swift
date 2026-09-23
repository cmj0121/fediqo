import Foundation
import Testing
@testable import FediqoCore

@Suite("Searching what this device holds")
struct SearchTests {
    private static let one = Source(host: "one.example", kind: .mastodon)
    private static let forum = Source(
        host: "forum.example", kind: .discuz, boards: [BoardSubscription(fid: 33, name: "Football Talk")]
    )

    private static func note(
        _ id: String,
        _ body: String = "hello",
        _ categories: Set<FediqoCore.Category> = [],
        in source: Source = one,
        author: String = "Someone",
        by handle: String = "@someone@one.example",
        boostedBy: String? = nil,
        boosterHandle: String? = nil,
        at time: TimeInterval = 0
    ) -> Note {
        Note(id: id, source: source, author: author, handle: handle, body: body,
             postedAt: Date(timeIntervalSince1970: time), categories: categories,
             boostedBy: boostedBy, boosterHandle: boosterHandle)
    }

    private static func matches(_ pattern: String, _ field: String) -> Bool {
        WildcardPattern(pattern)!.matches(Fold.key(field))
    }

    private static func found(_ pattern: String, _ notes: [Note], sources: [Source] = [one, forum]) -> [String] {
        NoteSearch(pattern, sources: sources)!.found(notes, SearchIndex(notes)).map(\.id)
    }

    // MARK: Fields

    @Test("With no wildcard, a post is found by its text, author, booster, hashtag, source or category")
    func everyField() {
        let notes = [
            Self.note("text", "I watched football today"),
            Self.note("author.name", author: "Football Fan"),
            Self.note("author.handle", by: "@footballer@one.example"),
            Self.note("booster.name", boostedBy: "Football Club"),
            Self.note("booster.handle", boosterHandle: "@football@one.example"),
            Self.note("hashtag", "#Football"),
            Self.note("source", in: Source(host: "football.example", kind: .mastodon)),
            Self.note("board", "", [.board(id: "33")], in: Self.forum, by: "someone@forum.example"),
            Self.note("none", "nothing about it", [.public]),
        ]
        #expect(Self.found("football", notes) == notes.dropLast().map(\.id))
    }

    @Test("Public, trends and home are found by those words and by the labels they are drawn with")
    func categoryWords() {
        let notes = [
            Self.note("public", "hello", [.public]),
            Self.note("trends", "hello", [.trends]),
            Self.note("home", "hello", [.home]),
            Self.note("none"),
        ]
        #expect(Self.found("trends", notes) == ["trends"])
        #expect(Self.found("public", notes) == ["public"])
        #expect(Self.found("home", notes) == ["home"])
        #expect(Self.found("e?d", notes) == ["trends"])
        let labels: [FediqoCore.Category: [String]] = [
            .public: ["Public", "公開"], .trends: ["Trends", "趨勢"], .home: ["Home", "首頁"],
        ]
        func labelled(_ pattern: String) -> [String] {
            NoteSearch(pattern, sources: [], labels: labels)!.found(notes, SearchIndex(notes)).map(\.id)
        }
        #expect(labelled("趨勢") == ["trends"])
        #expect(labelled("公開") == ["public"])
        #expect(labelled("首?") == ["home"])
        #expect(labelled("TRENDS") == ["trends"])
        // The English words stay whatever labels are handed in.
        #expect(NoteSearch("home", sources: [], labels: [.home: ["首頁"]])!
            .found(notes, SearchIndex(notes)).map(\.id) == ["home"])
    }

    @Test("A list is found by its name on the source as it is now")
    func listNames() {
        let source = Source(host: "one.example", kind: .mastodon, lists: [ListSubscription(id: "7", name: "Close Friends")])
        let post = Self.note("post", "hello", [.list(id: "7")], in: source)
        #expect(Self.found("friends", [post], sources: [source]) == ["post"])
        #expect(Self.found("close*fr", [post], sources: [source]) == ["post"])
        let renamed = Source(host: "one.example", kind: .mastodon, lists: [ListSubscription(id: "7", name: "Work")])
        #expect(Self.found("friends", [post], sources: [renamed]).isEmpty)
        #expect(Self.found("work", [post], sources: [renamed]) == ["post"])
        // A list that is no longer held has no name to be found by.
        #expect(Self.found("friends", [post], sources: []).isEmpty)
    }

    @Test("A board is found by its name on the source as it is now, not by a board it no longer names")
    func boardNames() {
        let post = Self.note("post", "", [.board(id: "33")], in: Self.forum, by: "a@forum.example")
        #expect(Self.found("talk", [post]) == ["post"])
        let renamed = Source(host: "forum.example", kind: .discuz, boards: [BoardSubscription(fid: 33, name: "Soccer")])
        #expect(Self.found("talk", [post], sources: [renamed]).isEmpty)
        #expect(Self.found("soccer", [post], sources: [renamed]) == ["post"])
        // A board of another forum with the same id is that forum's name, not this one's.
        let other = Source(host: "other.example", kind: .discuz, boards: [BoardSubscription(fid: 33, name: "Chess")])
        #expect(Self.found("chess", [post], sources: [other, Self.forum]).isEmpty)
    }

    @Test("Hashtags are fields of their own, with their #")
    func hashtags() {
        #expect(SearchIndex.Entry.hashtags(in: "a #swift b (#SwiftUI) c#not #_x ##y #") == ["#swift", "#SwiftUI", "#_x", "#y"])
        #expect(SearchIndex.Entry.hashtags(in: "#台灣 #日本語") == ["#台灣", "#日本語"])
        let post = Self.note("tagged", "Learning today #ios #swiftui")
        #expect(Self.found("#swift*", [post]) == ["tagged"])
        #expect(Self.found("#i?s", [post]) == ["tagged"])
        #expect(Self.found("#swift", [post]) == ["tagged"])
        #expect(Self.found("#swift??", [post]) == ["tagged"])
        #expect(Self.found("#swift???", [post]).isEmpty)
    }

    @Test("What is found keeps the order it was given, which is a timeline's")
    func order() {
        let notes = [Self.note("new", "swift", at: 2), Self.note("mid", "nope", at: 1), Self.note("old", "Swift", at: 0)]
        #expect(Self.found("swift", notes) == ["new", "old"])
    }

    @Test("An empty pattern is no search")
    func empty() {
        #expect(WildcardPattern("") == nil)
        #expect(NoteSearch("", sources: []) == nil)
    }

    @Test("A pattern of spaces alone is no search, and a space among other characters is itself")
    func spacesAlone() {
        #expect(WildcardPattern(" ") == nil)
        #expect(WildcardPattern("   ") == nil)
        #expect(WildcardPattern("\u{3000}") == nil, "a full-width space too")
        #expect(NoteSearch("  ", sources: []) == nil)
        let notes = [Self.note("a", "foot ball"), Self.note("b", "football")]
        #expect(Self.found("t b", notes) == ["a"])
    }

    @Test("A handle is found with or without its leading @, the author's and the booster's")
    func handleWithAt() {
        let notes = [
            Self.note("author", by: "@ada@one.example"),
            Self.note("booster", boosterHandle: "@ada@two.example"),
            Self.note("other", by: "@bob@one.example"),
        ]
        #expect(Self.found("@ada", notes) == ["author", "booster"])
        #expect(Self.found("@ada@one", notes) == ["author"])
        #expect(Self.found("ada@one", notes) == ["author"])
        #expect(Self.found("@a?a@*.example", notes) == ["author", "booster"])
    }

    // MARK: Wildcards

    @Test("A star alone finds every post")
    func starAlone() {
        let notes = [Self.note("a", ""), Self.note("b", "x")]
        #expect(Self.found("*", notes) == ["a", "b"])
        #expect(Self.found("**", notes) == ["a", "b"])
        #expect(Self.matches("*", ""))
    }

    @Test("A pattern is found anywhere in a field, wildcard or not; a star is any run, including none")
    func anywhere() {
        #expect(Self.matches("foot*ball", "football"))
        #expect(Self.matches("foot*ball", "I saw a footxball today"))
        #expect(Self.matches("foot*ball", "foot and ball"))
        #expect(!Self.matches("foot*ball", "ball and foot"))
        #expect(Self.matches("swift*", "I like swift"))
        #expect(Self.matches("*swift", "swiftui"))
        #expect(Self.matches("*swift*", "I like swiftui a lot"))
        // A star at either end changes nothing.
        for field in ["swift", "swiftui", "I like swift", "SWIFT!", "sw ift"] {
            let plain = Self.matches("swift", field)
            #expect(Self.matches("*swift", field) == plain && Self.matches("swift*", field) == plain, "\(field)")
        }
        #expect(Self.matches("a*b*c", "abc"))
        #expect(Self.matches("a*b*c", "xa--b--cx"))
        #expect(!Self.matches("a*b*c", "a--c--b"))
        // Backtracking: the first `ab` is followed by the wrong things.
        #expect(Self.matches("ab?c", "abxd abyc"))
        #expect(Self.matches("a?b*c?d", "a-b c a+b--cXd"))
        #expect(!Self.matches("a?b*c?d", "a-b c a+b--cd"))
    }

    @Test("A question mark is exactly one character")
    func question() {
        #expect(Self.matches("fo?t", "foot"))
        #expect(Self.matches("fo?t", "a foot here"))
        #expect(!Self.matches("fo?t", "fot"))
        #expect(!Self.matches("fo?t", "foooot"))
        #expect(Self.matches("??", "ab"))
        #expect(Self.matches("??", "abc"))
        #expect(!Self.matches("??", "a"))
        #expect(Self.matches("?", "a"))
        #expect(!Self.matches("?", ""))
        #expect(Self.matches("?", "台"))
        #expect(Self.matches("台?", "台灣"))
        #expect(!Self.matches("灣?", "台灣"))
    }

    @Test("A lone question mark finds every post with something in a field")
    func questionAlone() {
        // Every note has a handle, so every note is found.
        let notes = [Self.note("a", ""), Self.note("b", "x")]
        #expect(Self.found("?", notes) == ["a", "b"])
    }

    @Test("A question mark is one whole character, however many scalars draw it")
    func graphemes() {
        #expect(Self.matches("?", "👍🏽"))
        #expect(Self.matches("?", "🇹🇼"))
        #expect(Self.matches("?", "👨‍👩‍👧"))
        #expect(Self.matches("?", "e\u{331}"))
        #expect(Self.matches("a?b", "a👍🏽b"))
        #expect(!Self.matches("a??b", "a👍🏽b"))
        // A literal is only ever a whole character: 👍 is not the start of 👍🏽.
        #expect(!Self.matches("👍*", "👍🏽 yes"))
        #expect(Self.matches("👍🏽*", "👍🏽 yes"))
        #expect(!Self.matches("*🇺🇸*", "🇦🇺🇸🇪"))
        #expect(!Self.matches("e*", "e\u{331}"))
    }

    @Test("Every other character is itself: no regex, no operators, no quoting")
    func literals() {
        #expect(Self.matches("a.b", "a.b"))
        #expect(!Self.matches("a.b", "axb"))
        #expect(Self.matches("c++", "I write c++"))
        #expect(!Self.matches("c++", "I write c"))
        #expect(Self.matches("[x]", "see [x] here"))
        #expect(!Self.matches("[x]", "x"))
        #expect(Self.matches("^a$", "^a$"))
        #expect(!Self.matches("^a$", "a"))
        #expect(Self.matches("a|b", "a|b"))
        #expect(!Self.matches("a|b", "a"))
        #expect(Self.matches(#""quoted""#, #"say "quoted""#))
        #expect(!Self.matches(#""quoted""#, "quoted"))
        #expect(!Self.matches("author:ada", "ada"))
        #expect(Self.matches("\\*", "\\anything"))
    }

    @Test("Case and full-width against half-width do not change what is found")
    func folding() {
        #expect(Self.matches("SWIFT", "swift"))
        #expect(Self.matches("ｓｗｉｆｔ", "Swift"))
        #expect(Self.matches("swift", "ＳＷＩＦＴ"))
        #expect(Self.matches("ｶﾀｶﾅ", "カタカナ"))
        #expect(Self.matches("カタ*", "ｶﾀｶﾅ"))
        #expect(Self.matches("istanbul", "İSTANBUL"))
        #expect(Self.matches("a b", "a\u{00A0}b"))
        #expect(Self.matches("café", "cafe\u{301}"))
        #expect(!Self.matches("cafe", "café"))
        let post = Self.note("ada", "ＨＥＬＬＯ", author: "ＡＤＡ", by: "@Ada@One.Example")
        #expect(Self.found("ada@one.example", [post]) == ["ada"])
        #expect(Self.found("hello", [post]) == ["ada"])
    }

    @Test("A full-width star or question mark is a wildcard, once width is folded")
    func fullWidthWildcards() {
        #expect(Self.matches("swift＊", "swiftui"))
        #expect(Self.matches("fo？t", "foot"))
        #expect(WildcardPattern("＊")!.tokens == [.any])
    }

    @Test("CJK text is found without word breaking")
    func cjk() {
        let post = Self.note("zh", "今天去看了足球比賽")
        #expect(Self.found("足球", [post]) == ["zh"])
        #expect(Self.found("今天*比賽", [post]) == ["zh"])
        #expect(Self.found("今天?去*", [post]).isEmpty)
        #expect(Self.found("今?去*", [post]) == ["zh"])
    }

    /// The byte walk against the plainest reading of the rule — a table over whole characters —
    /// on fields and patterns drawn from a small alphabet that includes marks, skin tones, flags
    /// and CJK, so boundaries are hit often. Seeded, so a failure repeats.
    @Test("The match agrees with a character-by-character reading on generated cases")
    func agreesWithReference() {
        let alphabet: [String] = ["a", "b", "a", "ab", "👍", "👍🏽", "🇺🇸", "e\u{331}", "台", "灣", " ", "."]
        var seed: UInt64 = 0x5EED
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        func reference(_ pattern: [Character], _ field: [Character]) -> Bool {
            // Anywhere: a star at each end, then the usual table.
            let p: [Character] = ["*"] + pattern + ["*"]
            var row = [Bool](repeating: false, count: field.count + 1)
            row[0] = true
            for token in p {
                var nextRow = [Bool](repeating: false, count: field.count + 1)
                for i in 0...field.count {
                    switch token {
                    case "*": nextRow[i] = row[i] || (i > 0 && nextRow[i - 1])
                    case "?": nextRow[i] = i > 0 && row[i - 1]
                    default: nextRow[i] = i > 0 && row[i - 1] && field[i - 1] == token
                    }
                }
                row = nextRow
            }
            return row[field.count]
        }
        for _ in 0..<3_000 {
            let field = Fold.key((0..<next(12)).map { _ in alphabet[next(alphabet.count)] }.joined())
            let pattern = Fold.key((0..<(1 + next(5))).map { _ in
                [alphabet[next(alphabet.count)], "*", "?"][next(3)]
            }.joined())
            guard let wildcard = WildcardPattern(pattern) else {
                #expect(pattern.allSatisfy { $0.isWhitespace }, "only spaces are no pattern: \(pattern)")
                continue
            }
            let expected = reference(Array(pattern), Array(field))
            #expect(wildcard.matches(field) == expected, "\(pattern) in \(field)")
        }
    }

    // MARK: Cost

    @Test("10,000 notes are searched quickly enough to type into")
    func performance() throws {
        let hosts = (0..<10).map { Source(host: "h\($0).example", kind: .mastodon) }
        let words = ["swift", "kotlin", "rust", "#fediverse", "ｶﾀｶﾅ", "Café", "coffee", "tea", "news", "art"]
        let notes = (0..<10_000).map { i in
            Self.note(
                "\(i)",
                String(repeating: "Some ordinary words about the day and \(words[i % words.count]) ", count: 4),
                i % 3 == 0 ? [.trends] : [.public],
                in: hosts[i % 7], author: "User \(i % 4)", by: "@user\(i % 4)@h\(i % 4).example",
                boostedBy: i % 11 == 0 ? "Booster" : nil,
                boosterHandle: i % 11 == 0 ? "@booster@h1.example" : nil
            )
        }
        var index = SearchIndex([])
        let indexing = Pace(notes) { index = SearchIndex(notes) }
        // A keyword that never matches reads every field of every note; the wildcard ones walk.
        let patterns = ["nothingatall", "coffee", "*fediverse*", "user?@*", "*d?y*zzz", "s*t"]
        var counts = [Int](repeating: 0, count: patterns.count)
        let paces = Pace.each(notes, patterns.enumerated().map { i, pattern in
            let search = NoteSearch(pattern, sources: hosts)!
            return { counts[i] = search.found(notes, index).count }
        })
        #expect(counts[0] == 0 && counts[1] == 1_000 && counts[2] == 1_000 && counts[3] == 10_000)
        let (slowest, searching) = try #require(zip(patterns, paces).max { $0.1.reads < $1.1.reads })
        // Each against plain reads of the same notes (`Pace`), and printed so a runner's log
        // shows them. Debug measured about 3.0 to index and 1.2 for the slowest search
        // (`*d?y*zzz`, which walks every body); across seventy-one runs at normal and background
        // priority, counting coverage, and beside twice as many busy threads as cores, at most
        // 4.8 and 2.1. The lines are about twice those: an index or a search made five times
        // dearer fails, three times may not. They are drawn for the debug build `swift test`
        // makes; release measured 1.35 and 0.22, as the plain read is library code either way.
        print("Search index: \(indexing)")
        print("Slowest search, `\(slowest)`: \(searching)")
        #expect(indexing.reads < 10, "indexing took \(indexing)")
        #expect(searching.reads < 4, "searching `\(slowest)` took \(searching)")
    }
}
