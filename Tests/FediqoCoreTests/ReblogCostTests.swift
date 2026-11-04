import Foundation
import Testing
@testable import FediqoCore

/// What a reblog's rules and search cost (#290), in the shape of the two budget checks that were
/// here before it (`RuleTests.performance`, `SearchTests.performance`): 10,000 notes, 20 rules,
/// the same six patterns — with one note in five a reblog of a post among the others.
///
/// **The rules held to what they cost before reblogs**: evaluating the timeline with one note in
/// five a reblog, the lookup of what each reblog reblogs (`ReblogTargets`) built with it, is told
/// against evaluating the same timeline over the same notes with posts in place of the reblogs —
/// the budget the rules already had, measured in the same round (`Pace.each(against:)`, #478).
/// The search is still held to its own line, the slowest under 4 plain reads.
@Suite("What reblogs cost the rules and the search")
struct ReblogCostTests {
    private static let hosts = (0..<10).map { Source(host: "h\($0).example", kind: .mastodon) }
    private static let words = ["swift", "kotlin", "rust", "#fediverse", "ｶﾀｶﾅ", "Café", "coffee", "tea", "news", "art"]

    /// 8,000 posts and 2,000 reblogs, interleaved one in five, each reblog of a post held from
    /// the same source.
    private static let notes: [Note] = (0..<10_000).map { note($0, reblogs: true) }

    /// `notes` before reblogs: the same 10,000, with a post where each reblog is.
    private static let posts: [Note] = (0..<10_000).map { note($0, reblogs: false) }

    private static func note(_ i: Int, reblogs: Bool) -> Note {
        let source = hosts[i % 7]
        if reblogs, i % 5 == 4 {
            // The post seven before it — seven after, for the first — is on the same source and
            // is not a reblog.
            return Note(
                id: "r\(i)", source: source, author: "Booster", handle: "@booster@h1.example", body: "",
                postedAt: Date(timeIntervalSince1970: Double(i)), categories: [.public],
                refs: [Reference(kind: .reblogs, id: "\(i >= 7 ? i - 7 : i + 7)")]
            )
        }
        return Note(
            id: "\(i)", source: source, author: "User \(i % 4)", handle: "@user\(i % 4)@h\(i % 4).example",
            body: String(repeating: "Some ordinary words about the day and \(words[i % words.count]) ", count: 4),
            postedAt: Date(timeIntervalSince1970: Double(i)), categories: i % 3 == 0 ? [.trends] : [.public],
            language: "en"
        )
    }

    private static var rules: [Rule] {
        // Half the keywords never match, so most notes are read against all ten.
        var rules: [Rule] = words.enumerated().map { i, word in Rule.keyword(i < 5 ? word + "x" : word, in: .every)! }
        rules += (0..<3).map { Rule.author("user\($0)@h\($0).example", in: .every, sources: hosts)! }
        rules += [Rule.author("booster@h1.example", in: .every, sources: hosts)!]
        rules += (0..<3).map { Rule.source("h\($0).example")! }
        rules += [
            Rule.category(.public, in: .every, sources: hosts)!,
            Rule.keyword("nothing", in: .every, effect: .exclude)!,
            Rule.field("language", is: .option("fr"), in: .every, effect: .exclude)!,
        ]
        return rules
    }

    @Test("The premise: one note in five is a reblog, and every one of them reblogs a post that is held")
    func premise() {
        let notes = Self.notes
        let targets = ReblogTargets(notes)
        let reblogs = notes.filter { $0.isReblog }
        #expect(reblogs.count == 2_000)
        #expect(reblogs.allSatisfy { targets.target(of: $0)?.isReblog == false })
        #expect(Self.rules.count == 20)
    }

    @Test("10,000 notes, one in five a reblog, against 20 rules stay inside the budget the rules already had")
    func rules() {
        let notes = Self.notes, posts = Self.posts
        let timeline = CompiledTimeline(TimelineDefinition(name: "t", rules: Self.rules), sources: Self.hosts)
        let index = TextIndex(notes), postsIndex = TextIndex(posts)
        var targets = ReblogTargets([])
        var shown: [Note] = []
        var alone: [Note] = []
        var before: [Note] = []
        // The lookup and the evaluation it feeds are timed as one piece of work, so the line holds
        // one ratio rather than two added together. Debug with coverage measured 1.19 to 1.20 on a
        // quiet machine and 1.15 to 1.21 beside twelve busy loops on ten cores; the lookup built
        // twice measured 1.40 to 1.51, so one made 2.3 times dearer fails. Against a plain read
        // the same code measured 1.8 here and 2.1 to 2.5 on the shared runner.
        let paces = Pace.each(against: { before = timeline.shown(posts, postsIndex) }, unit: "evaluations before reblogs", [
            { targets = ReblogTargets(notes) },
            { shown = timeline.shown(notes, index, targets: targets) },
            {
                targets = ReblogTargets(notes)
                shown = timeline.shown(notes, index, targets: targets)
            },
            { alone = timeline.shown(notes, index) },
        ])
        #expect(shown == alone && shown.contains { $0.isReblog } && shown.contains { !$0.isReblog })
        #expect(!before.isEmpty && !before.contains { $0.isReblog })
        print("Reblog lookup built: \(paces[0])")
        print("Rules evaluated, one in five a reblog, lookup handed in: \(paces[1])")
        print("Reblog lookup built and rules evaluated with it: \(paces[2])")
        print("Rules evaluated, one in five a reblog, building its own lookup: \(paces[3])")
        // Handed in, it measured 0.90 to 0.95: a reblog is read through what it reblogs.
        #expect(paces[1].reads < 1.15, "evaluating took \(paces[1])")
        #expect(paces[2].reads < 1.45, "the lookup and one evaluation together took \(paces[2])")
    }

    @Test("10,000 notes, one in five a reblog, are searched inside the budget the search already had")
    func search() throws {
        let notes = Self.notes
        let index = SearchIndex(notes)
        let targets = ReblogTargets(notes)
        let patterns = ["nothingatall", "coffee", "*fediverse*", "user?@*", "*d?y*zzz", "s*t"]
        var counts = [Int](repeating: 0, count: patterns.count)
        let paces = Pace.each(notes, patterns.enumerated().map { i, pattern in
            let search = NoteSearch(pattern, sources: Self.hosts)!
            return { counts[i] = search.found(notes, index, targets: targets).count }
        })
        #expect(counts[0] == 0 && counts[1] == 1_000 && counts[3] == 10_000, "every reblog is found by the author of what it reblogs")
        let (slowest, searching) = try #require(zip(patterns, paces).max { $0.1.reads < $1.1.reads })
        print("Slowest search, one in five a reblog, `\(slowest)`: \(searching)")
        #expect(searching.reads < 4, "searching `\(slowest)` took \(searching)")
    }
}
