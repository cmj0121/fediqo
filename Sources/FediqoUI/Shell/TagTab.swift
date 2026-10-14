import FediqoCore
import Foundation

/// The tabs of a hashtag's page (F10), in the order they stand: the posts this device holds
/// under it, and where it is followed.
///
/// **Which of them a page has is decided here, from the lines its sources have** — and those
/// are worked out where the sources are asked (`ShellTagFollow.lines`): one for each source
/// the reader is signed in to that keeps hashtags followed. With no such line — a forum's
/// reader, nobody signed in — the page has its posts alone, and then no strip is drawn, no
/// mark, and no Follow: absent, never grey.
enum TagTab: String, ShellTab, CaseIterable, Sendable {
    case posts, about

    var id: String { rawValue }

    var titleKey: String { "tag.tab.\(rawValue)" }

    var symbol: String {
        switch self {
        case .posts: "text.bubble"
        case .about: "info.circle"
        }
    }

    /// The tabs of a page whose sources have the lines `follows`. **The one place it is decided.**
    static func tabs(follows: [TagFollowLine]) -> [TagTab] {
        follows.isEmpty ? [.posts] : [.posts, .about]
    }

    /// The tab in front among `tabs`: the one last brought in front where the page still has
    /// it, and Posts otherwise — the page is its posts.
    static func front(_ kept: TagTab?, among tabs: [TagTab]) -> TagTab {
        kept.flatMap { tabs.contains($0) ? $0 : nil } ?? .posts
    }

    /// Whether the tab's rows are posts: what a mark's key acts on, and what Return opens as
    /// a conversation. About's are blocks, and no post's key acts on one.
    var listsPosts: Bool { self == .posts }

    /// What Tab or ⇧Tab does on a hashtag's page: taken, turning nothing, where it has its
    /// posts alone.
    typealias Keyed = PageKeyed<TagTab>

    /// What the key does on a page with `tabs` and `front` in front, as every page with tabs
    /// decides it (`PageFrame.keyed`).
    static func keyed(_ tabs: [TagTab], front: TagTab, by step: Int, covered: Bool) -> Keyed {
        PageFrame.keyed(tabs, front: front, by: step, covered: covered)
    }

    /// What becomes of the tab kept in front and of the lamp when the page's tabs change
    /// under it, or nothing where nothing does: a kept tab the page no longer has is
    /// forgotten, and the lamp — which stood on one of its rows — goes out with it.
    static func fallen(_ kept: TagTab?, among tabs: [TagTab], lamp: String?) -> (kept: TagTab?, lamp: String?)? {
        guard let kept, !tabs.contains(kept) else { return nil }
        return (nil, nil)
    }

    /// The lamp a tab is handed back, where it is still on one of the rows that tab walks —
    /// and no lamp where it is not: a post's id is never carried onto About, a block's never
    /// onto the posts, and a post the timeline in front no longer shows is not lit.
    static func lamp(_ kept: String?, among walked: [String]) -> String? {
        PageFrame.lamp(kept, among: walked)
    }
}

/// What the About tab of a hashtag's page is handed: one row for each source that has a line
/// — whether the reader follows the hashtag there, and the press for the other — and which
/// sources the page's posts were asked of.
struct TagAboutSaid: Equatable {
    let follows: [TagFollowLine]
    /// Which of the timeline's sources were asked and why the rest were not, or nothing.
    var reach: String?

    /// What the reach sentence is called as a row the lamp stops on.
    static let reachID = "tag.about.reach"

    /// What a source's row is called as a row the lamp stops on.
    static func lamp(on line: TagFollowLine) -> String { "tag.about.follow:" + line.host }

    /// Every block `j` and `k` walk, top to bottom as the tab draws them.
    var walked: [String] {
        follows.map(Self.lamp) + (reach == nil ? [] : [Self.reachID])
    }

    /// The line whose press Return makes with the lamp on the block `id`, or nothing where the
    /// block is words.
    func press(on id: String) -> TagFollowLine? {
        follows.first { Self.lamp(on: $0) == id && $0.offers != nil }
    }
}

/// What a hashtag's page is handed (F10): which tabs it has and which is in front, what its
/// head says, the page's line, and what About holds.
///
/// **Worked out from what the sources said, by nothing that draws** — the page draws it as it
/// is handed, in either form: with the strip of tabs, or as one list with none.
struct TagPageSaid: Equatable {
    /// A source that said the reader follows the hashtag there: a mark in the head.
    struct Followed: Equatable, Identifiable {
        /// The host, which is the mark's word.
        let host: String
        /// The mark's sentence, told to a pointer and a listener.
        let spoken: String

        var id: String { host }

        static let symbol = "checkmark.circle"
    }

    /// Something a source could not do or could not say, said in the page's line whichever
    /// tab is in front: a press that did not arrive, or a source that could not be asked
    /// whether the hashtag is followed there — with the press that asks it again.
    struct Trouble: Equatable, Identifiable {
        let id: String
        let words: String
        /// The line whose press asks again, where there is such a press.
        var again: TagFollowLine?
        /// What that press is called to a listener and a pointer: what is asked again, and where.
        var spoken: String?
    }

    let tag: PostTag
    let tabs: [TagTab]
    let front: TagTab
    /// How many posts this device holds under it: a press that opens Posts where the page has
    /// a strip, and a figure that opens nothing where it has none.
    let figure: PageFigure
    /// One mark for each source that said it is followed there; none for one that did not.
    let followed: [Followed]
    /// The head's Follow: the line of the one source that offers it, where exactly one does.
    let follow: TagFollowLine?
    /// Where the ask of the sources stands, or nothing once it has landed whole.
    let line: TagPane.Said?
    /// What the press beside a failed ask is called to a listener and a pointer: whom it
    /// asks again, and for what. Nothing where no ask failed.
    let retrySpoken: String?
    /// What a source failed at about following: full ink, under the head — **while Posts is
    /// in front**. On About each is said by its source's own row, with its press, and is not
    /// said a second time over it.
    let troubles: [Trouble]
    /// Which sources were asked, said in the page's line — only where the page has no About
    /// to say it, and not while the sources are being asked, when the line names them.
    ///
    /// **Under a failure it is still said**, which is more than F10's "one at a time": a
    /// source that fails says so, and which sources were asked and why not the rest is no
    /// less true for it — the two rules both hold, as they did before the page had a frame.
    let reach: String?
    /// The sentence of a page with no posts, once nobody is being asked for any: about this
    /// device, never about the hashtag.
    let none: String?
    /// What About holds, where the page has one.
    let about: TagAboutSaid?

    /// Whether the page draws its strip of tabs.
    var stripped: Bool { PageFrame.stripDrawn(tabs) }

    static func made(
        of tag: PostTag, held: Int, asking: [String] = [], failed: [String] = [], reach: String? = nil,
        follows: [TagFollowLine] = [], front kept: TagTab? = nil, language: DummyLanguage? = nil
    ) -> TagPageSaid {
        let tabs = TagTab.tabs(follows: follows)
        let front = TagTab.front(kept, among: tabs)
        let hasAbout = tabs.contains(.about)
        let offering = follows.filter { $0.offers == .follow }
        let line = TagPane.said(asking: asking, failed: failed, tag: tag, language: language)
        let beingAsked = !asking.isEmpty
        return TagPageSaid(
            tag: tag, tabs: tabs, front: front,
            // What this device holds, counted here: a figure of its own, and so never a guess.
            figure: PageFigure(
                symbol: TagTab.posts.symbol, figure: L10n.grouped(held, language: language),
                spoken: L10n.count("person.held", held, language: language),
                opens: PageFrame.stripDrawn(tabs), lit: front == .posts
            ),
            followed: follows.filter { $0.standing == .said(true) }.map {
                Followed(host: $0.host, spoken: String(format: L10n.t("tag.stands.followed", language: language), $0.host))
            },
            follow: offering.count == 1 ? offering.first : nil,
            line: line,
            retrySpoken: failed.isEmpty || beingAsked ? nil : String(
                format: L10n.t("tag.retry.spoken", language: language), failed.joined(separator: ", "), tag.text
            ),
            troubles: front == .about ? [] : troubles(of: follows, language: language),
            reach: hasAbout || beingAsked ? nil : reach,
            // Never left blank under a line that has finished asking, which would read as waiting.
            none: held == 0 && asking.isEmpty ? TagPane.none(tag, language: language) : nil,
            about: hasAbout ? TagAboutSaid(follows: follows, reach: reach) : nil
        )
    }
}

extension TagPageSaid {
    /// What the sources failed at, in their order: a read that failed, with the press that
    /// asks again, and a press that did not arrive. **A source with no hashtag of the name
    /// says nothing here**: it has none — absent, not a failure.
    static func troubles(of follows: [TagFollowLine], language: DummyLanguage? = nil) -> [Trouble] {
        follows.compactMap { line in
            if line.standing == .unknown {
                return Trouble(
                    id: "unknown:" + line.host, words: line.words(language: language), again: line,
                    spoken: line.pressSpoken(language: language)
                )
            }
            return line.missedWords(language: language).map { Trouble(id: "missed:" + line.host, words: $0) }
        }
    }

    /// The page of `tag` as the session stands: what its ask says only where the ask is this
    /// hashtag's — another's, or one left behind, is not this page's to say.
    @MainActor
    static func made(of tag: PostTag, held: Int, follows: [TagFollowLine], front: TagTab?, in session: ShellSession) -> TagPageSaid {
        let asked = session.reload.tagAsk?.tag == tag
        return made(
            of: tag, held: held, asking: asked ? session.reload.tagAsking : [], failed: asked ? session.reload.tagFailed : [],
            reach: asked ? session.reload.tagAsk?.reach.sentence : nil, follows: follows, front: front
        )
    }
}

/// What the parts of a hashtag's page press: each answered by whoever holds the walk and the
/// pages, so the page draws and asks nothing.
struct TagPageActs {
    var onBack: () -> Void = {}
    /// A tab's pill pressed, the figure that counts its posts, or a swipe: that tab in front.
    var onTab: (TagTab) -> Void = { _ in }
    /// The head's Follow, at the one source that offers it.
    var onHeadFollow: (TagFollowLine) -> Void = { _ in }
    /// A line's press at one source: follow or unfollow, or ask again whether it is followed.
    var onFollow: (TagFollowLine) -> Void = { _ in }
    /// A lock's press: the question that asks that source's sign-in for who the reader follows.
    var onAskFollows: (String) -> Void = { _ in }
    /// Asks the sources again, after a failure.
    var onRetry: () -> Void = {}
}
