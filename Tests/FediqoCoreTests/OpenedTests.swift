import Foundation
import Testing
@testable import FediqoCore

/// #293: what belongs with an opened item is read off references among what is held — what it
/// refers to above it, what refers to it below — and off nothing else.
@Suite("What belongs with an opened item")
struct OpenedTests {
    private static let host = "one.example"
    private static let origin = Date(timeIntervalSince1970: 1_700_000_000)

    private static func name(_ id: String, on host: String = host) -> String {
        "https://\(host)/users/ada/statuses/\(id)"
    }

    /// A post its source numbers `id`, posted `at` seconds in, answering and quoting as said.
    private static func post(
        _ id: String, at seconds: TimeInterval = 0, answering parent: String? = nil, quoting quoted: String? = nil,
        on host: String = host, refs: [Reference]? = nil
    ) -> Note {
        Note(
            id: name(id, on: host), source: Source(host: host, kind: .mastodon), author: "Ada",
            handle: "@ada@\(host)", body: "post \(id)", postedAt: origin.addingTimeInterval(seconds), categories: [],
            reply: parent.map { Reply(inReplyToId: $0) }, statusID: id,
            quote: quoted.map { Quote(state: .accepted, statusID: $0) }, refs: refs
        )
    }

    private static func reblog(of id: String, by who: String, at seconds: TimeInterval, named: Bool = true) -> Note {
        Note(
            id: "https://\(host)/users/\(who)/statuses/r\(id)/activity", source: Source(host: host, kind: .mastodon),
            author: who, handle: "@\(who)@\(host)", body: "", postedAt: origin.addingTimeInterval(seconds),
            categories: [.home], statusID: "r\(who)",
            refs: [Reference(kind: .reblogs, id: named ? name(id) : nil, statusID: id)]
        )
    }

    private static func ids(_ notes: [Note]) -> [String] { notes.compactMap(\.statusID) }

    @Test("Above is what it answers and what that answers, as far up as held items go, the start first; where a post in the chain is not held the chain ends there")
    func theChainAbove() {
        let root = Self.post("9", answering: "8")
        let held = [root, Self.post("8", answering: "7"), Self.post("7", answering: "6"), Self.post("5", answering: "4")]
        let opened = Opened.around(root, among: held)
        #expect(Self.ids(opened.above) == ["7", "8"], "6 is not held, so nothing above 7 is drawn — 5 is held and no part of it")
        #expect(opened.below.isEmpty && opened.quoting.isEmpty && opened.reblogs.isEmpty)
        #expect(Opened.around(Self.post("9"), among: held).isAlone, "a post that says it answers nothing has nothing above it")
    }

    @Test("A reference names its target by the source's own id or by the item's ID, and either finds it; another source's post of the same id is never it")
    func byEitherName() {
        let parent = Self.post("8")
        let named = Self.post("9", refs: [Reference(kind: .answers, id: parent.id)])
        #expect(Self.ids(Opened.around(named, among: [named, parent]).above) == ["8"])
        let numbered = Self.post("9", answering: "8")
        #expect(Self.ids(Opened.around(numbered, among: [numbered, parent]).above) == ["8"])

        let elsewhere = Self.post("8", on: "two.example")
        #expect(Opened.around(numbered, among: [numbered, elsewhere]).isAlone)
        // And a name that spells another host is looked up here, among this source's, and not there.
        let pointing = Self.post("9", refs: [Reference(kind: .answers, id: elsewhere.id)])
        #expect(Opened.around(pointing, among: [pointing, elsewhere]).isAlone)
        let answer = Self.post("10", answering: "9", on: "two.example")
        #expect(Opened.around(numbered, among: [numbered, answer]).below.isEmpty, "nor does another source's post answer this one")
    }

    @Test("Below is every held item that answers it or answers one that does: each directly under what it answers, the older first, and two of one second in the order their source numbered them")
    func theAnswersBelow() {
        let root = Self.post("9")
        let held = [
            Self.post("13", at: 30, answering: "9"), Self.post("12", at: 40, answering: "10"),
            Self.post("100", at: 20, answering: "10"), Self.post("99", at: 20, answering: "10"),
            Self.post("10", at: 10, answering: "9"), root,
            Self.post("20", at: 5, answering: "19"),
        ]
        let opened = Opened.around(root, among: held)
        #expect(Self.ids(opened.below) == ["10", "99", "100", "12", "13"])
        #expect(!Self.ids(opened.rows).contains("20"), "an answer to a post not held is in no place here")
    }

    @Test("What a read of the thread said belongs to it and no reference places stands after the placed answers, under the highest held post it answers up to, with its own answers under it; nothing is loose that a reference places, and nothing without the read's word")
    func whatTheReadSaid() {
        let root = Self.post("9")
        let held = [
            root, Self.post("10", at: 10, answering: "9"), Self.post("14", at: 40, answering: "13"),
            Self.post("13", at: 30, answering: "12"), Self.post("15", at: 20, answering: "5"), Self.post("20", at: 5, answering: "19"),
        ]
        func keys(_ ids: [String]) -> Set<NoteKey> { Set(ids.map { NoteKey(host: Self.host, id: Self.name($0)) }) }
        let opened = Opened.around(root, among: held, said: keys(["10", "13", "14", "15"]))
        #expect(Self.ids(opened.below) == ["10", "15", "13", "14"])
        #expect(opened.loose == keys(["15", "13"]))
        #expect(Opened.around(root, among: held).loose.isEmpty)
        #expect(Self.ids(Opened.around(root, among: held).below) == ["10"], "with no read's word, only what refers")
        // Said, and answering a held post that is not under the root: that post is the one at the first step.
        let under = Opened.around(root, among: held, said: keys(["14"]))
        #expect(Self.ids(under.below) == ["10", "13", "14"])
        #expect(under.loose == keys(["13"]))
    }

    @Test("Where the chain above stops at a post not held and a read said more stand above, those stand beyond it in the source's order; where the chain reaches the start, or the item answers nothing, or nothing was said, nothing is beyond")
    func whatTheReadSaidStandsAbove() {
        func keys(_ ids: [String]) -> [NoteKey] { ids.map { NoteKey(host: Self.host, id: Self.name($0)) } }
        // 1 ← 2 ← (5, not held) ← 8 ← 9: opened at 9.
        let root = Self.post("9", answering: "8")
        let held = [root, Self.post("8", answering: "5"), Self.post("2", at: -10, answering: "1"), Self.post("1", at: -20), Self.post("3", answering: "1")]
        let opened = Opened.around(root, among: held, saidAbove: keys(["1", "2", "8"]))
        #expect(Self.ids(opened.above) == ["8"])
        #expect(Self.ids(opened.beyond) == ["1", "2"], "the source's order, and no post twice")
        #expect(Self.ids(opened.rows) == ["1", "2", "8"])
        #expect(Opened.around(root, among: held).beyond.isEmpty, "with no read's word, only what references reach")
        #expect(Opened.around(root, among: held, saidAbove: keys(["2", "1", "404"])).beyond.map(\.statusID) == ["2", "1"], "as said, and only what is held")
        // The chain reaches the start: whatever was said, there is nothing beyond it.
        let whole = [Self.post("9", answering: "8"), Self.post("8"), Self.post("1")]
        #expect(Opened.around(whole[0], among: whole, saidAbove: keys(["1", "8"])).beyond.isEmpty)
        #expect(Opened.around(Self.post("9"), among: held, saidAbove: keys(["1"])).beyond.isEmpty, "it answers nothing")
        // Another source's post of that name is not it.
        let elsewhere = Self.post("1", on: "two.example")
        #expect(Opened.around(root, among: [root, elsewhere], saidAbove: [elsewhere.key, NoteKey(host: Self.host, id: Self.name("1"))]).beyond.isEmpty)
    }

    @Test("A loop in what posts say they answer ends: each post is drawn once")
    func aLoopEnds() {
        let root = Self.post("9", answering: "11")
        let held = [root, Self.post("10", answering: "9"), Self.post("11", answering: "10")]
        let opened = Opened.around(root, among: held)
        #expect(Self.ids(opened.above) == ["10", "11"] && opened.below.isEmpty)
    }

    @Test("A held post that quotes it is with it, after its answers; one that answers in its thread and quotes it is there once, as an answer")
    func quotesOfIt() {
        let root = Self.post("9")
        let held = [
            root, Self.post("30", at: 30, quoting: "9"), Self.post("20", at: 20, quoting: "9"),
            Self.post("10", at: 10, answering: "9", quoting: "9"), Self.post("40", at: 40, quoting: "8"),
        ]
        let opened = Opened.around(root, among: held)
        #expect(Self.ids(opened.below) == ["10"])
        #expect(Self.ids(opened.quoting) == ["20", "30"])
        #expect(Self.ids(opened.rows) == ["10", "20", "30"])
    }

    @Test("The held reblogs of it are with it, the latest first, and are in no thread; a reblog of another post is not; around a reblog there is nothing")
    func reblogsOfIt() {
        let root = Self.post("9")
        let early = Self.reblog(of: "9", by: "bob", at: 50), late = Self.reblog(of: "9", by: "cyd", at: 90, named: false)
        let other = Self.reblog(of: "8", by: "dee", at: 70)
        let opened = Opened.around(root, among: [root, early, other, late, Self.post("10", answering: "9")])
        #expect(opened.reblogs.map(\.author) == ["cyd", "bob"])
        #expect(Self.ids(opened.rows) == ["10"], "a reblog is no row of the thread")
        #expect(Opened.around(early, among: [root, early, Self.post("10", answering: "rbob")]).isAlone)
    }
}
