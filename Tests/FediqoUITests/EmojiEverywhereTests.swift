import Foundation
import FediqoCore
import SwiftUI
import Testing
@testable import FediqoUI

#if os(macOS)
import AppKit
#endif

/// Somebody else's text, drawn as the pictures it was written in — and our own text, left alone.
///
/// What is pinned here is the seam rather than the scanner: which lines of a row go through an
/// alphabet, which order that alphabet asks its two sources in, which lines stay a plain `Text`,
/// what a covered row says out loud, and that none of it moved the row.
@Suite("Emoji everywhere")
@MainActor
struct EmojiEverywhereTests {
    private static let reading = "first.example"
    private static let posted = Date(timeIntervalSince1970: 1_700_000_000)

    private static func emoji(_ shortcode: String, on host: String) -> CustomEmoji {
        CustomEmoji(shortcode: shortcode, url: URL(string: "https://\(host)/\(shortcode).png")!)
    }

    private static func item(
        author: String = "Ada",
        handle: String? = "@ada@author.example",
        body: String = "words",
        spoiler: String? = nil,
        sensitive: Bool? = nil,
        emojis: [CustomEmoji] = []
    ) -> DummyItem {
        DummyItem(Note(
            id: "n1",
            source: Source(host: reading, kind: .mastodon),
            author: author,
            handle: handle ?? "",
            body: body,
            postedAt: posted,
            origins: [.publicTimeline],
            sensitive: sensitive,
            spoiler: spoiler,
            emojis: emojis
        ))
    }

    private static func store(_ catalogue: [CustomEmoji], host: String) async -> EmojiCatalogueStore {
        let store = EmojiCatalogueStore()
        await store.refresh(host: host) { catalogue }
        await store.settle(host: host)
        return store
    }

    private static func row(_ item: DummyItem) -> DummyItemRow {
        DummyItemRow(item: item, catalogues: EmojiCatalogueStore(),
                     marks: .constant(DummyMarks()), onToast: { _ in })
    }

    // MARK: - The order, at the layer that draws

    // The order itself is `EmojiAlphabet`'s and is tested there. What is easy to get right once
    // and lose in a refactor is that the row goes through it at all: a row that reached for the
    // catalogue directly, or folded the two lists itself, would draw the reading server's
    // `:blobcat:` over the author's and nothing would fail.
    @Test("The post's own picture wins over the reading server's registration of the same name")
    func thePostsOwnPictureWins() async {
        let own = Self.emoji("blobcat", on: "author.example")
        let theirs = Self.emoji("blobcat", on: Self.reading)
        let store = await Self.store([theirs, Self.emoji("wave", on: Self.reading)],
                                     host: Self.reading)
        let item = Self.item(author: "Ada :blobcat:", body: "hello :blobcat: and :wave:",
                             emojis: [own])

        let alphabet = await store.alphabet(own: item.emojis, host: item.source.host)
        let written = DummyItemRow.Written(alphabet, of: item)

        #expect(written.name == [own])
        #expect(written.body == [own, Self.emoji("wave", on: Self.reading)])
        #expect(written.body.first?.url == own.url)
        #expect(written.body.first?.url != theirs.url)
    }

    // The source the post was read through, never the author's own instance. The two differ for
    // every federated post, and it is the reader's per-server Clear button that depends on it.
    @Test("A row asks the server it read the post through, not the one that wrote it")
    func theRowAsksTheReadingServer() async {
        let theirs = Self.emoji("wave", on: Self.reading)
        let store = await Self.store([theirs], host: Self.reading)
        let item = Self.item(body: "hello :wave:")

        #expect(item.source.host == Self.reading)
        #expect(item.handle?.hasSuffix("author.example") == true)

        let read = DummyItemRow.Written(
            await store.alphabet(own: item.emojis, host: item.source.host), of: item
        )
        let wrote = DummyItemRow.Written(
            await store.alphabet(own: item.emojis, host: "author.example"), of: item
        )
        #expect(read.body == [theirs])
        #expect(wrote.body.isEmpty)
    }

    // Each line is resolved on its own, because each line is decoded at its own ink height. One
    // list for the whole row would decode the words' pictures a second time at the name's size.
    @Test("Every line of a row is resolved, and each one carries only its own pictures")
    func everyLineCarriesOnlyItsOwn() async {
        let store = await Self.store(
            ["inname", "inhandle", "inbody", "incover"].map { Self.emoji($0, on: Self.reading) },
            host: Self.reading
        )
        let item = Self.item(author: "Ada :inname:", handle: "@ada :inhandle:",
                             body: "words :inbody:", spoiler: "careful :incover:")
        let written = DummyItemRow.Written(
            await store.alphabet(own: item.emojis, host: item.source.host), of: item
        )

        #expect(written.name.map(\.shortcode) == ["inname"])
        #expect(written.handle.map(\.shortcode) == ["inhandle"])
        #expect(written.body.map(\.shortcode) == ["inbody"])
        #expect(written.cover.map(\.shortcode) == ["incover"])
    }

    @Test("A post written in letters alone asks for nothing, on a server with a catalogue or not")
    func lettersAloneAskForNothing() async {
        let store = await Self.store([Self.emoji("wave", on: Self.reading)], host: Self.reading)
        let item = Self.item(author: "Ada", body: "no colons here at all")
        let written = DummyItemRow.Written(
            await store.alphabet(own: item.emojis, host: item.source.host), of: item
        )
        #expect(written == DummyItemRow.Written(EmojiAlphabet(), of: item))
        #expect(written.name.isEmpty && written.handle.isEmpty)
        #expect(written.body.isEmpty && written.cover.isEmpty)
        // The stamp is the post's, not empty: an answer that carries no pictures is still this
        // post's answer, and `written` leans on that to tell a stale one from its own.
        #expect(written.id == item.id)
    }

    // A row is torn down when it scrolls out of a `LazyVStack` and comes back with fresh state,
    // so anything that waits for a task to dispatch draws the shortcode every time the reader
    // scrolls past. The post's own pictures need no actor, so a row has them before it has run
    // anything — which is also what gives `EmojiText.pictures(for:)` a list to find its already
    // cached frames under on the very first pass.
    @Test("A row carries the post's own pictures before it has asked anybody anything")
    func theOwnPicturesNeedNoTask() {
        let own = Self.emoji("blobcat", on: "author.example")
        let item = Self.item(author: "Ada :blobcat:", body: "hello :blobcat:", emojis: [own])
        let fresh = Self.row(item)

        #expect(fresh.written.name == [own])
        #expect(fresh.written.body == [own])
        #expect(fresh.written.id == item.id)
    }

    // MARK: - The timeline asks, where nothing else would

    // `refresh` had exactly one call site in the whole product — the join — so a catalogue the
    // reader dropped never came back for the life of the process. The twenty-four hour life
    // cannot save it, because staleness is a question about a catalogue that is there. These
    // pin the second call site, which lives inside a `View`'s `.task` and is therefore lifted
    // out of it so that something can run it: a call site reachable only from a `body` is a
    // call site with no test, and "the timeline asks at all" is the fact that was missing.
    @Test("A timeline load asks for a catalogue nobody is holding")
    func aTimelineLoadAsksForAMissingCatalogue() async {
        let http = FixtureHTTP(["/api/v1/custom_emojis": .body(Fixtures.json("custom-emojis"))])
        let store = EmojiCatalogueStore()
        #expect(await store.catalogue(host: Self.reading) == nil)

        await TimelinePane.catalogue(Self.reading, in: store, over: http)

        #expect(await store.catalogue(host: Self.reading)?.count == 3)
        #expect(await http.paths == ["/api/v1/custom_emojis"])
    }

    @Test("A catalogue the reader cleared comes back on the next timeline load")
    func aClearedCatalogueComesBack() async {
        let http = FixtureHTTP(["/api/v1/custom_emojis": .body(Fixtures.json("custom-emojis"))])
        let store = EmojiCatalogueStore()
        await TimelinePane.catalogue(Self.reading, in: store, over: http)
        #expect(await store.alphabet(own: [], host: Self.reading).lookup("blobcat") != nil)

        await store.forget(host: Self.reading)
        #expect(await store.catalogue(host: Self.reading) == nil)

        await TimelinePane.catalogue(Self.reading, in: store, over: http)

        #expect(await store.alphabet(own: [], host: Self.reading).lookup("blobcat") != nil)
        #expect(await http.paths.count == 2)
    }

    // The other side of the same line, and the one that binds: an unguarded ask here would be a
    // request to every joined server on every pass through the timeline. The guard that makes
    // that true is the store's own — `refresh` re-reads what is held and what is in flight from
    // inside the actor — so this passes whether or not `needsFetch` is asked first, which is
    // precisely why the comment at the call site says the `needsFetch` line is an allocation
    // saved rather than a race closed.
    @Test("A catalogue already in hand is not asked for again, however often a timeline loads")
    func aHeldCatalogueIsNotAskedForAgain() async {
        let http = FixtureHTTP(["/api/v1/custom_emojis": .body(Fixtures.json("custom-emojis"))])
        let store = EmojiCatalogueStore()
        for _ in 0..<4 { await TimelinePane.catalogue(Self.reading, in: store, over: http) }
        #expect(await http.paths == ["/api/v1/custom_emojis"])
    }

    // A server that does not serve the endpoint is a server whose posts still read. Nothing is
    // written down for a fetch that failed, so the host stays askable rather than being marked
    // dead for the run — but the pane must not be the thing that turns a 404 into a stuck wait.
    @Test("A server with no catalogue endpoint leaves the timeline waiting for nothing")
    func aMissingEndpointIsSurvivable() async {
        let http = FixtureHTTP(["/api/v1/custom_emojis": .text("nope", status: 404)])
        let store = EmojiCatalogueStore()

        await TimelinePane.catalogue(Self.reading, in: store, over: http)

        // It asked, and survived the answer — both halves, so this cannot pass by not asking.
        #expect(await http.paths == ["/api/v1/custom_emojis"])
        #expect(await store.catalogue(host: Self.reading) == nil)
        // Nothing is written down for a fetch that failed, so one bad minute is not permanent.
        #expect(await store.needsFetch(host: Self.reading))
        // The post's own pictures are untouched by any of it.
        let own = Self.emoji("blobcat", on: "author.example")
        #expect(await store.alphabet(own: [own], host: Self.reading).lookup("blobcat") == own)
    }

    // MARK: - Our own copy is ours

    // A shortcode in a string this app wrote would be this app's bug, and drawing it as a picture
    // would hide the bug rather than show it. The cover line is the one place the two kinds of
    // text share a slot, so it is the one place the distinction has to be made by hand.
    @Test("The cover line is the author's only when the author wrote one")
    func ourOwnCoverSentenceStaysOurs() {
        let authors = Self.item(spoiler: "Blood")
        #expect(authors.covered)
        #expect(Self.row(authors).coverIsTheAuthors)

        for ours in [Self.item(sensitive: true), Self.item(spoiler: "", sensitive: true)] {
            #expect(ours.covered)
            #expect(!Self.row(ours).coverIsTheAuthors)
        }
    }

    // The alphabet is asked about `spoiler`, never about the line the row ends up drawing. Where
    // the author wrote nothing, there is no stranger's text on that band to resolve.
    @Test("Where the cover line is ours, nothing on that band goes through an alphabet")
    func ourOwnSentenceIsNeverResolved() async {
        let store = await Self.store([Self.emoji("wave", on: Self.reading)], host: Self.reading)
        let ours = Self.item(sensitive: true)
        let written = DummyItemRow.Written(
            await store.alphabet(own: ours.emojis, host: ours.source.host), of: ours
        )
        #expect(written.cover.isEmpty)
        #expect(!Self.row(ours).coverIsTheAuthors)
    }

    // MARK: - What a covered row says

    // Decision 6: the words are drawn, blurred, and taken out of the accessibility tree and the
    // pasteboard. `EmojiText` gives itself a label — what the author typed — so the words now
    // name themselves, and the row's spoken label is the only thing that may speak for them.
    @Test("A covered row's label carries the warning and never the words behind it")
    func aCoveredRowDoesNotAnnounceTheWords() {
        let item = Self.item(body: "the thing nobody asked to read :blobcat:", spoiler: "Blood")
        let covered = DummyItemRow(item: item, catalogues: EmojiCatalogueStore(),
                                   marks: .constant(DummyMarks()), lifted: false, onToast: { _ in })
        let lifted = DummyItemRow(item: item, catalogues: EmojiCatalogueStore(),
                                  marks: .constant(DummyMarks()), lifted: true, onToast: { _ in })

        #expect(covered.spokenCover.contains("Blood"))
        #expect(!covered.spokenCover.contains("nobody asked to read"))
        #expect(!covered.spokenCover.contains(":blobcat:"))
        #expect(covered.spokenCover.contains(L10n.t("item.covered.label")))

        // Lifted is the reader's own doing and the words speak for themselves again — but the
        // label still does not repeat them.
        #expect(!lifted.spokenCover.contains("nobody asked to read"))
        #expect(lifted.spokenCover.contains(L10n.t("item.lifted.label")))
    }

    #if os(macOS)
    // MARK: - The row is still one height

    /// A row drawn at a fixed width, measured the way the type scale was measured.
    private static func height(_ item: DummyItem, lifted: Bool, size: DynamicTypeSize) -> CGFloat {
        let row = DummyItemRow(item: item, catalogues: EmojiCatalogueStore(),
                               marks: .constant(DummyMarks()), lifted: lifted, onToast: { _ in })
            .dynamicTypeSize(size)
            .frame(width: 720)
        let host = NSHostingView(rootView: row)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    // The row is four fixed bands and every row is the same height — the invariant the whole row
    // design rests on, and the one a stranger's text is the standing threat to. A `spoiler_text`
    // is five hundred characters a hostile instance chooses, so any rule that lets it size a row
    // is a layout attack landing on every row of a timeline at once.
    //
    // This is that measurement taken again after the words, the name, the handle and the cover
    // line all became `EmojiText`: 204.0 points, the figure QA measured before them, at every
    // type size — on macOS, which is the only platform this package runs a test on, and where
    // `@ScaledMetric` and Dynamic Type are both inert, so one height is all that *can* be seen. One number rather than that number is what is asserted — the ink a system font
    // reports is a fact about the machine, and pinning 204 would fail on a different one for a
    // reason that has nothing to do with this row. Across type sizes is deliberately not
    // compared either: `dynamicTypeSize` is inert on macOS today, and a test that asserted the
    // heights matched would be pinning that defect in place.
    @Test("Every row is one height, whatever the server wrote on it")
    func everyRowIsOneHeight() {
        let long = String(repeating: "warning ", count: 63)
        #expect(long.count >= 500)
        let shapes: [(DummyItem, Bool)] = [
            (Self.item(), false),
            (Self.item(spoiler: "Blood"), false),
            (Self.item(spoiler: "Blood"), true),
            (Self.item(spoiler: "Spiders and wasps"), false),
            (Self.item(spoiler: long), false),
            (Self.item(spoiler: long), true),
            (Self.item(author: "Ada :blobcat:", body: "hello :blobcat:", spoiler: ":blobcat:"),
             false),
        ]

        for size in [DynamicTypeSize.large, .accessibility3] {
            let heights = Set(shapes.map { Self.height($0.0, lifted: $0.1, size: size) })
            #expect(heights.count == 1, "one height per type size, got \(heights.sorted())")
        }
    }

    // The other half of the same invariant, and it is not the half that was expected.
    //
    // **A picture standing in a line makes the line taller than the letters do**, even though it
    // is decoded at the font's own ink height. Measured at the default type size: a `.body` line
    // is 16 points of letters and 21 with a picture in it, `.name` 15 and 20, `.meta` 13 and 17.
    // SwiftUI reserves a text attachment's whole height as the line's *ascent* — an image sits
    // with its bottom on the baseline rather than spanning ascender to descender — and then adds
    // `baselineOffset` to the descent instead of sliding the picture up inside the box. So the
    // offset that drops the picture onto the descender, which is what makes it look right, is
    // also what makes the line five points taller. The arithmetic in `EmojiCache.metrics` is
    // right about ink and cannot be right about line height while that is how the offset behaves.
    //
    // **What keeps it off the row is that neither band is sized by its text — on macOS and on
    // regular-width iOS.** The headline is held open by the avatar and the words band by the
    // 96pt slot, so this pins the two inequalities the row's one height rests on. They are what
    // `everyRowIsOneHeight` measures the consequence of; if a later row ever sizes a band to its
    // content, that test goes red and this one says why.
    //
    // **On a phone in portrait it is false, and deliberately so.** `mainBox`'s narrow branch is a
    // bare `VStack` with no `.frame(height:)`, and `words` takes `lineLimit(nil)` there, so the
    // words band *is* sized by its text — a long post already made a tall row on a phone before
    // any of this, and an emoji line now adds its five points there too. What still holds on a
    // phone is the half that was ever a security property: the author's cover line stays capped
    // by `coverLines`, so the five-hundred-character warning a hostile instance chooses cannot
    // size a row on any platform.
    //
    // Measured on macOS at `.large` only, because an SPM test target cannot render on iOS. The
    // untested configuration is regular-width iOS — an iPad, where the wide layout is the one
    // that runs — and there the margin is thinner than macOS suggests, because `@ScaledMetric`
    // and Dynamic Type both move: at `.accessibility5` the slack on `body.picture * 4 ≤ thumb` is
    // around 8%, not the third this assertion passes by here. That configuration is exactly what
    // the UI-test target exists to cover, so this belongs there rather than in a second copy
    // written here and never run.
    @Test("A picture makes its line taller, and the fixed bands are what absorb it")
    func theBandsAbsorbTheTallerLine() throws {
        let name = try Self.line(role: .name)
        let meta = try Self.line(role: .meta)
        let body = try Self.line(role: .body)

        #expect(name.picture > name.plain)
        #expect(body.picture > body.plain)
        #expect(meta.picture > meta.plain)

        // The headline: the author's name and the handle beside the author's picture.
        #expect(name.picture <= DummyItemRow.Box.avatar)
        #expect(meta.picture <= DummyItemRow.Box.avatar)
        // The words: at most four lines beside a slot that is always the same square.
        #expect(body.picture * 4 <= DummyItemRow.Box.thumb)
    }

    /// One line of a role, with a picture standing in it and without.
    private static func line(role: EmojiTextRole) throws -> (plain: CGFloat, picture: CGFloat) {
        let metrics = EmojiCache.metrics(points: EmojiTextRole.points(for: role, at: .large))
        let decoded = try #require(EmojiCache.decode(EmojiFixture.png(width: 64, height: 64),
                                                     ink: Int(metrics.side), stillOnly: false))
        let frames = EmojiCache.Frames(decoded, side: metrics.side)
        let one = emoji("blobcat", on: reading)
        let plain = EmojiText.line([.text("Ada Lovelace")], [:], at: 0, baseline: metrics.baseline)
        let drawn = EmojiText.line([.text("Ada "), .emoji(one), .text(" Lovelace")],
                                   ["blobcat": frames], at: 0, baseline: metrics.baseline)
        return (lineHeight(plain, role: role), lineHeight(drawn, role: role))
    }

    private static func lineHeight(_ text: Text, role: EmojiTextRole) -> CGFloat {
        let host = NSHostingView(rootView: text.font(role.font).frame(width: 720))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }
    #endif
}
