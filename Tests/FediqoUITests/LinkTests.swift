import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// A link in a post's words, as far as this package can hold it without a screen (#34).
///
/// What a test can reach: the cut the line is built from, the `Text` that is built out of it, and
/// the object a press hands the address to. What it cannot: the press itself, the menu the
/// secondary press opens, and the web view — all three are `View` bodies, and this package cannot
/// execute one. They are named in the report rather than claimed here.
///
/// **`@MainActor` belongs on the suite and nowhere else — this cost an afternoon.** `ShellReader`
/// and `EmojiCache` are main-actor types, so their isolation has to come from somewhere. Moving
/// the annotation onto the individual `@Test` functions *compiles clean*, and then the whole
/// `FediqoUITests` bundle dies with signal 5 — SIGTRAP — the moment this suite starts: no failing
/// assertion, no test name, nothing but `exited with unexpected signal code 5` after the last
/// suite that ran. Leaving it off entirely is the friendly failure of the two; that one is a
/// compile error naming every line. If this file ever starts trapping with nothing to show for
/// it, look at this annotation before looking at anything else.
@MainActor
@Suite("Following a link in a post")
struct LinkTests {
    private static func link(_ text: String) -> PostLink { PostLink(text)! }

    private static let blobcat = CustomEmoji(
        shortcode: "blobcat", url: URL(string: "https://first.example/blobcat.png")!
    )

    // MARK: - What the line is built out of

    @Test("The links of a line are the link runs of its cut, in order")
    func theLinksOfALine() {
        let cut = EmojiRun.prose(in: "a https://one.test/x b https://two.test/y", emojis: [])
        #expect(EmojiText.links(in: cut).map(\.host) == ["one.test", "two.test"])
        #expect(EmojiText.links(in: [.text("nothing here")]).isEmpty)
    }

    /// The address is drawn as the letters the author typed, carrying the address they typed.
    /// **Equal by construction**: the `Text` this builds is compared against one built the same
    /// way, so what the test holds is that the attributes are on it at all — the address, the
    /// hue and the underline — and that a line missing any of them is not this line.
    @Test("An address is drawn as a link: the address, the shell's hue, and an underline")
    func anAddressIsDrawnAsALink() {
        let link = Self.link("https://example.test/a")
        let ink = ShellChrome.selectInk(.dark)
        let drawn = EmojiText.drawn(link, in: ink)

        var expected = AttributedString("https://example.test/a")
        expected.link = link.url
        expected.foregroundColor = ink
        expected.underlineStyle = .single
        #expect(drawn == Text(expected))

        // Hue alone is a difference some readers cannot see, so the underline is part of what a
        // link is here rather than decoration on top of it.
        var noUnderline = AttributedString("https://example.test/a")
        noUnderline.link = link.url
        noUnderline.foregroundColor = ink
        #expect(drawn != Text(noUnderline))

        // And the address is on it. A line drawn without it is a line nothing can be pressed in.
        var noAddress = AttributedString("https://example.test/a")
        noAddress.foregroundColor = ink
        noAddress.underlineStyle = .single
        #expect(drawn != Text(noAddress))
    }

    @Test("The hue follows the scheme, so a link reads as one in light and in dark")
    func bothSchemes() {
        let link = Self.link("https://example.test/a")
        #expect(EmojiText.drawn(link, in: ShellChrome.selectInk(.light))
            != EmojiText.drawn(link, in: ShellChrome.selectInk(.dark)))
    }

    @Test("A line with an address in it is the words, then the link, then the words")
    func theLineItself() {
        let link = Self.link("https://example.test/a")
        let ink = ShellChrome.selectInk(.light)
        let cut = EmojiRun.prose(in: "see https://example.test/a now", emojis: [])
        #expect(EmojiText.line(cut, [:], at: 0, baseline: -4, linkInk: ink)
            == Text(verbatim: "") + Text(verbatim: "see ") + EmojiText.drawn(link, in: ink)
            + Text(verbatim: " now"))
    }

    /// The other half of `EmojiText`'s two initialisers: a name that happens to be spelled like
    /// an address is a label somebody chose, and the label cut cannot turn it into a control.
    @Test("A label spelled like an address is drawn as letters and nothing else")
    func aLabelIsNotAControl() {
        let cut = CustomEmoji.runs(in: "https://example.test/a", from: [])
        #expect(EmojiText.links(in: cut).isEmpty)
        #expect(EmojiText.line(cut, [:], at: 0, baseline: -4)
            == Text(verbatim: "") + Text(verbatim: "https://example.test/a"))
    }

    // MARK: - What a cover draws

    /// **The cover's cut is the label cut.** A blurred `Text` is still laid out and still
    /// hit-tested, so prose behind a cover is a covered post whose links are live: the press that
    /// should lift the cover lands on the text layer and opens the author's page, and the
    /// secondary press lists the hosts the warning was put in front of. The fix is the cut, so
    /// this is what the test holds — the line the cover draws is one the scanner never opened.
    @Test("A covered post's words are cut as a label, so the cover draws no control")
    func theCoverDrawsNoControl() {
        let body = "see https://example.test/a"
        let covered = EmojiText.words(body, emojis: [], host: "first.example", covered: true)
        let lifted = EmojiText.words(body, emojis: [], host: "first.example", covered: false)

        #expect(covered.linked == false)
        #expect(lifted.linked)

        // And the two cuts those answers pick: nothing to press under the cover, the address
        // once it is off. Asked of the cache, which is where the line itself asks.
        let cache = EmojiCache(http: FixtureHTTP())
        #expect(EmojiText.links(in: cache.runs(in: body, from: [])).isEmpty)
        #expect(EmojiText.links(in: cache.proseRuns(in: body, from: [])).map(\.host)
            == ["example.test"])
    }

    /// The row's other half of the same rule: a forum band under a cover offers no spoken action
    /// either. A reader using VoiceOver is not an exception to "the cover draws no control".
    @Test("A covered band offers no address to speak, and an uncovered one offers the words'")
    func aCoveredBandSpeaksNoAddress() {
        let words = ForumPostBand.words(of: .words("see https://example.test/a"))
        #expect(EmojiText.links(in: EmojiCache.shared.proseRuns(in: words, from: []))
            .map(\.host) == ["example.test"])
        // What the band hands `spokenLinks` while covered is the empty string, and an empty
        // string has no addresses in it however it is cut.
        #expect(EmojiText.links(in: EmojiCache.shared.proseRuns(in: "", from: [])).isEmpty)
    }

    // MARK: - The memo keeps the two cuts apart

    @Test("The prose cut and the label cut of the same words are two answers, both remembered")
    func theMemoKeepsThemApart() {
        let cache = EmojiCache(http: FixtureHTTP())
        let words = "see https://example.test/a :blobcat:"
        let asProse = cache.proseRuns(in: words, from: [Self.blobcat])
        let asLabel = cache.runs(in: words, from: [Self.blobcat])

        #expect(asProse != asLabel)
        #expect(EmojiText.links(in: asProse).map(\.host) == ["example.test"])
        #expect(EmojiText.links(in: asLabel).isEmpty)
        // Asked again, each still gets its own answer rather than whichever was memoised first.
        #expect(cache.proseRuns(in: words, from: [Self.blobcat]) == asProse)
        #expect(cache.runs(in: words, from: [Self.blobcat]) == asLabel)
    }

    @Test("A post with no picture in it still has its addresses found")
    func proseWithNoPictures() {
        let cache = EmojiCache(http: FixtureHTTP())
        let cut = cache.proseRuns(in: "https://example.test/a", from: [])
        #expect(EmojiText.links(in: cut).map(\.host) == ["example.test"])
        // Which is exactly what the label cut of the same words does not do.
        #expect(EmojiText.links(in: cache.runs(in: "https://example.test/a", from: [])).isEmpty)
    }

    // MARK: - Where a press goes

    @Test("A press opens the address inside the app, and names the host it opened")
    func aPressOpensItHere() throws {
        let reader = ShellReader()
        #expect(reader.reading == nil)
        #expect(reader.open(URL(string: "https://example.test/a")!))
        let reading = try #require(reader.reading)
        #expect(reading.host == "example.test")
        #expect(reading.url.absoluteString == "https://example.test/a")
        #expect(reading.id == "https://example.test/a")
    }

    /// Decision 9 read again at the door of a web view. The way in takes a plain `URL`, so this
    /// is the check a caller with no `PostLink` in hand would otherwise skip.
    @Test("Nothing but https is opened inside the app", arguments: [
        "http://example.test/a",
        "javascript:alert(1)",
        "data:text/html,<script>alert(1)</script>",
        "file:///etc/passwd",
        "fediqo://open/timeline",
        "https:///a",
    ])
    func theReaderRefusesEverythingElse(_ raw: String) {
        let reader = ShellReader()
        let url = URL(string: raw)!
        #expect(reader.open(url) == false)
        // And refused means nothing opened, never "opened something else".
        #expect(reader.reading == nil)
    }

    @Test("Closing it leaves nothing open")
    func closing() {
        let reader = ShellReader()
        reader.open(URL(string: "https://example.test/a")!)
        reader.close()
        #expect(reader.reading == nil)
    }

    @Test("A second address replaces the first, so one page is open at a time")
    func oneAtATime() throws {
        let reader = ShellReader()
        reader.open(URL(string: "https://one.test/a")!)
        reader.open(URL(string: "https://two.test/b")!)
        let reading = try #require(reader.reading)
        #expect(reading.host == "two.test")
        // And the sheet's web view is built for the second address rather than updated over the
        // first: the identity moved, which is what `.id(reading.id)` is read for.
        #expect(reading.id == "https://two.test/b")
    }

    // MARK: - Where the reader is, once the page has moved

    /// **The one fact this sheet promises.** There is no address bar, no back button and no
    /// history, so the name beside the padlock is the whole of what a reader has to go on — and
    /// onward navigation is allowed by design. Fixed at open time it named the first host while a
    /// second one was on the screen, at a moment the author picks.
    @Test("The header follows the main frame: a redirect renames the host")
    func theHeaderFollowsARedirect() throws {
        let reader = ShellReader()
        reader.open(URL(string: "https://one.test/a")!)
        reader.arrived(at: URL(string: "https://two.test/landed")!)

        let reading = try #require(reader.reading)
        #expect(reading.host == "two.test")
        #expect(reading.showing.absoluteString == "https://two.test/landed")
        // The address the sheet was opened on does not move with it. It is what the web view was
        // built for, and a value that changed on every hop would rebuild the web view at each one.
        #expect(reading.url.absoluteString == "https://one.test/a")
        #expect(reading.id == "https://one.test/a")
    }

    /// A `target="_blank"` link is loaded back into the same view, so it arrives here as one more
    /// main-frame landing — the header follows it exactly as it follows a redirect, and a second
    /// hop from there is not the first one's host either.
    @Test("A second hop renames it again, rather than sticking at the first")
    func theHeaderFollowsEveryHop() throws {
        let reader = ShellReader()
        reader.open(URL(string: "https://one.test/a")!)
        reader.arrived(at: URL(string: "https://two.test/b")!)
        reader.arrived(at: URL(string: "https://three.test/c")!)
        #expect(try #require(reader.reading).host == "three.test")
    }

    /// Naming the old host is the defect this closes, so an address that names no host moves
    /// nothing — keeping the last true name is the failure rather than a safe fallback.
    @Test("An address with no host of its own renames nothing")
    func nothingToName() throws {
        let reader = ShellReader()
        reader.open(URL(string: "https://one.test/a")!)
        reader.arrived(at: URL(string: "about:blank")!)
        #expect(try #require(reader.reading).host == "one.test")
    }

    @Test("Nothing has arrived anywhere while nothing is open")
    func arrivingWithNothingOpen() {
        let reader = ShellReader()
        reader.arrived(at: URL(string: "https://two.test/b")!)
        reader.refuse()
        #expect(reader.reading == nil)
    }

    /// A cancelled navigation used to be silent: a link the reader pressed simply did nothing,
    /// which is a control on the screen that is not a control in the app.
    @Test("A refused move is said, and the next move that lands takes the notice away")
    func aRefusalIsSaid() throws {
        let reader = ShellReader()
        reader.open(URL(string: "https://one.test/a")!)
        #expect(try #require(reader.reading).refused == false)

        reader.refuse()
        #expect(try #require(reader.reading).refused)

        reader.arrived(at: URL(string: "https://one.test/b")!)
        #expect(try #require(reader.reading).refused == false)
    }

    // MARK: - A forum's words

    /// The band is one accessibility element, so the addresses it offers are found from the same
    /// text it drew — and only where that text is the author's own words. The four other states
    /// are this app's own sentences, and an address in one of those is not a post's.
    @Test("A forum band offers the addresses of the words, and of nothing else")
    func aForumBandsWords() {
        #expect(ForumPostBand.words(of: .words("see https://example.test/a"))
            == "see https://example.test/a")
        #expect(ForumPostBand.words(of: .coming) == "")
        #expect(ForumPostBand.words(of: .withheld) == "")
        #expect(ForumPostBand.words(of: .silent) == "")
        #expect(ForumPostBand.words(of: .absent(.unreachable)) == "")
        #expect(PostLink.found(in: ForumPostBand.words(of: .coming)).isEmpty)
    }

    // MARK: - What a reader is told

    @Test("Both ways to follow an address are sentences this app actually ships", arguments: [
        "link.open.here", "link.open.browser", "link.hint.pointer", "link.hint.touch",
        "link.reader.label", "link.reader.browser", "link.reader.close", "link.reader.refused",
    ])
    func theSentencesExist(_ key: String) {
        // `L10n.t` answers with the key itself where there is no string for it, which is what
        // makes this a check rather than a tautology. Parity across the three `.lproj` is held
        // by the shipped-strings test; this holds that English has them at all.
        #expect(L10n.t(key, language: .english) != key)
        #expect(L10n.t(key, language: .taiwanese) != key)
    }
}
