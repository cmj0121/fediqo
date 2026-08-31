import Foundation
import Testing
@testable import FediqoCore

/// How long a search takes on a year of what a reader kept.
///
/// #2 has asked for it in under a second on a year of timeline since the beginning, and the
/// number could not be got until there was something to measure. This is the something, and it
/// is a test rather than a note because a number nothing re-measures is a number about a laptop
/// somebody threw away.
///
/// **A year is 75,000 posts here, and that is an argument rather than a round number.** This app
/// keeps what it read, and what it reads is several servers' public timelines through the day.
/// Two hundred posts a day is a reader who leaves it open with a few servers on it — heavy, but
/// a person rather than a stress test — and two hundred a day for a year is 73,000. Rounded up,
/// because the number worth holding is the one nobody's real year exceeds.
///
/// Measured on 2026-08-31, in memory, 75,000 posts built in 5.5 seconds:
///
/// ```text
/// kingfisher   1 found      0.0012s     a word in one post
/// 伺服器       40 found      0.062s     a word in about half of them
/// server       40 found      0.057s     the same, in the other language
/// 貼文         40 found      0.028s     a word in a quarter of them
/// ```
///
/// The worst of those is a sixteenth of what was asked for, so nothing was done about it. What
/// the shape of it says is worth keeping: the cost is in how many posts the words match and not
/// in how many are stored — the plan ends `USE TEMP B-TREE FOR ORDER BY`, so a common word is
/// sorted before the page is cut. A word in one post out of 75,000 answers in a millisecond.
@Suite("A search on a year of timeline")
struct SearchBenchmarkTests {
    /// Two hundred a day, for a year, rounded up. See the note on the suite.
    private static let aYear = 75_000

    /// What the criterion allows, and what this holds the search to.
    private static let promised = Duration.seconds(1)

    /// Posts worth searching: two languages, words in most of them, and one word in exactly
    /// one. The two ends are what a search costs — a common word makes the index hand back
    /// most of the store, a rare one almost nothing — and both are timed below.
    private func aYearOfPosts() -> [Post] {
        (0..<Self.aYear).map { index in
            let text = switch index % 4 {
            case 0: "一個伺服器公開給所有人的貼文，新的在最上面 \(index)"
            case 1: "another server carried this one, and the timeline says so \(index)"
            case 2: "伺服器與伺服器之間的差別，說在下面 \(index)"
            default: "a server's own emoji, drawn rather than spelled \(index)"
            }
            return makePost(uri: "https://one.example/api/v1/statuses/\(index)",
                            originURI: "https://one.example/users/a/statuses/\(index)",
                            at: TimeInterval(index),
                            text: index == 7 ? "the one post that mentions a kingfisher" : text)
        }
    }

    @Test("A year of it, searched in under a second")
    func aYearInUnderASecond() async throws {
        let store = try LocalStore.inMemory()
        let server = Server(host: "one.example", socialProtocol: .mastodon)
        let posts = aYearOfPosts()
        for chunk in stride(from: 0, to: posts.count, by: 5_000) {
            try await store.save(Array(posts[chunk..<min(chunk + 5_000, posts.count)]), from: server)
        }
        #expect(try await count(store, "SELECT count(*) FROM posts") == Self.aYear)

        let clock = ContinuousClock()
        for word in ["kingfisher", "伺服器", "server", "貼文"] {
            var found = 0
            let took = try await clock.measure { found = try await store.search(word, limit: 40).count }
            #expect(found > 0, "\(word) found nothing on a store that has it")
            #expect(took < Self.promised, "\(word) took \(took), which is over the second #2 promised")
        }

        // A word in no post is the other thing a reader does, and it must not be the expensive
        // one: nothing found is nothing to sort.
        let missing = try await clock.measure { _ = try await store.search("翡翠鳥 kingfishers").count }
        #expect(missing < Self.promised, "a word in no post took \(missing)")
    }
}
