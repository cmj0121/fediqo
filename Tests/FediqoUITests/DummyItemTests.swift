import Foundation
import FediqoCore
import Testing

@testable import FediqoUI

/// Which shape of row each protocol gets — the one place `ProtocolKind` turns into something the
/// timeline can draw.
@Suite("Row shape")
@MainActor
struct DummyItemTests {
    init() {
        L10n.language = .english
    }

    private static func note(_ kind: ProtocolKind, url: URL? = nil) -> Note {
        Note(
            id: "\(kind.rawValue):host:1",
            source: Source(host: "example.test", kind: kind),
            author: "somebody",
            handle: "@somebody@example.test",
            body: "",
            title: "A named discussion",
            board: "A section",
            postedAt: .distantPast,
            categories: [.public],
            url: url,
            counts: Counts(replies: 3)
        )
    }

    private static func row(_ kind: ProtocolKind, url: String?) -> DummyItem {
        DummyItem(note(kind, url: url.flatMap { URL(string: $0) }))
    }

    @Test("Every protocol is drawn as exactly one shape, and none of them as a board")
    func everyProtocolGetsAShape() {
        // **Every protocol written out, rather than "these two are forums and the rest are
        // microblogs".** The shorter spelling agreed with the code by construction: a protocol
        // added to `ProtocolKind` and left out of the set was *expected* to be a microblog, which
        // is the exact wrong answer the incident behind `shape(of:)` produced — a whole Discuz!
        // forum drawn as microblog posts with every title missing. The no-`default:` rule makes
        // the compiler stop at the switch; this makes the suite stop as well, because a new
        // protocol has no entry here, `expected[kind]` is nothing, and nothing matches no shape.
        // Saying it twice is the price of the second question being asked at all.
        let expected: [ProtocolKind: DummySourceKind] = [
            .mastodon: .microblog,
            .pleroma: .microblog,
            .akkoma: .microblog,
            .misskey: .microblog,
            .pixelfed: .microblog,
            .lemmy: .microblog,
            .friendica: .microblog,
            .gotosocial: .microblog,
            .unknown: .microblog,
            .discourse: .forum,
            .discuz: .forum,
            .peertube: .video,
        ]
        let unshaped = Set(ProtocolKind.allCases).subtracting(expected.keys)
        #expect(unshaped.isEmpty, "no shape stated for \(unshaped.map(\.rawValue).sorted())")

        for kind in ProtocolKind.allCases {
            let item = DummyItem(Self.note(kind))
            #expect(item.source.kind == expected[kind], "\(kind.rawValue)")
            // `.board` is a query inside a source, never a shape a protocol has. `shape(of:)`
            // returning it would draw a whole host as one section of itself, and no switch would
            // complain, because `.board` is a case the row already knows how to draw.
            #expect(item.source.kind != .board, "\(kind.rawValue)")
        }
    }

    @Test("A film is not drawn as somebody's words")
    func aPeerTubeNoteIsAVideo() {
        // Pinned while it is still unreachable — `.peertube` is refused at every join door, so
        // nothing here can arrive from a real server yet. It is pinned because the alternative
        // answers, `.note` and `.thread`, are both plausible and both silently wrong, and M2's
        // PeerTube unit should be changing a stated expectation rather than discovering one.
        let item = DummyItem(Self.note(.peertube))
        #expect(item.source.kind == .video)
        #expect(item.kind == .video)
    }

    @Test("A Discuz! thread carries its title and its board into the row")
    func aDiscuzThreadIsAThread() {
        // The whole point of the shape: a forum row draws a name and a section, and a microblog
        // row draws neither because a microblog has neither.
        let item = DummyItem(Self.note(.discuz))
        #expect(item.source.kind == .forum)
        #expect(item.kind == .thread)
        #expect(item.title == "A named discussion")
        #expect(item.board == "A section")
        #expect(item.counts.replies == 3)

        // The same note from a microblog is the same words drawn as a note.
        let post = DummyItem(Self.note(.mastodon))
        #expect(post.source.kind == .microblog)
        #expect(post.kind == .note)
    }

    // MARK: - The way out, on every row

    /// **The row's way out is decided here and drawn from here.** Every control this milestone
    /// got wrong was decided inside a `View` body, where the suite could not reach it and stayed
    /// green while the screen did the wrong thing. `outwardURL` is that decision, pulled out to
    /// where these tests can press it: whether the row offers a way out at all, and which address
    /// it opens.
    @Test("A row offers the address its note carried, for every protocol that fills one")
    func aRowOffersWhereItLives() {
        // The three shapes `Note.url` actually arrives in today, one per protocol: a Mastodon
        // status's own `url` lifted from that instance's JSON, a Discourse topic's `/t/<slug>/<id>`
        // composed in Core, and a Discuz! `viewthread` address built in Core out of a parsed host
        // and an integer. By the time they are here the difference has stopped mattering, which is
        // the point of a `Note` carrying the address rather than a row rebuilding one.
        let carried: [ProtocolKind: String] = [
            .mastodon: "https://example.test/@somebody/109",
            .discourse: "https://example.test/t/a-named-discussion/42",
            .discuz: "https://example.test/forum.php?mod=viewthread&tid=42",
        ]
        for (kind, address) in carried {
            let item = Self.row(kind, url: address)
            #expect(item.outwardURL == URL(string: address), "\(kind.rawValue)")
        }
    }

    /// Absent, not disabled — decision 4's rule on this repo's controls.
    ///
    /// A row whose note named nowhere must offer nothing at all. The failure this pins is not a
    /// crash: it is a menu item, or a VoiceOver action, announcing a way out of the app and then
    /// doing nothing when it is taken.
    @Test("A row whose note named nowhere offers no way out")
    func aRowWithNoAddressOffersNothing() {
        #expect(Self.row(.mastodon, url: nil).outwardURL == nil)
        #expect(Self.row(.discuz, url: nil).outwardURL == nil)
    }

    /// **The guard, driven rather than asserted about.**
    ///
    /// `openURL` does as it is told. `URL(string:)` builds every one of these happily out of a
    /// stranger's JSON, and a row that handed one to the system browser would be running a
    /// stranger's script or opening this device's files on their say-so. `Host.allowsFetch` is
    /// the package's one rule for where this device will go, and `outwardURL` is a second reading
    /// of that one function — not a second rule — so a row refuses exactly what a fetch refuses.
    ///
    /// **Asked of the built address too, not only the lifted one.** Discuz! composes its
    /// `viewthread` address rather than taking one from the page, and says at that site why it
    /// still does not trust it: what is checked here is what will be handed to the browser, which
    /// has nothing to do with who wrote it.
    @Test("An address this device will not go to is not offered, however it was built")
    func ahostileAddressIsNotOffered() {
        let hostile = [
            "javascript:alert(1)",
            "data:text/html;base64,PHNjcmlwdD4=",
            "file:///etc/passwd",
            // Downgraded, and a host with no scheme this package fetches under. Both parse.
            "http://example.test/forum.php?mod=viewthread&tid=42",
            "https:///forum.php?mod=viewthread&tid=42",
        ]
        for address in hostile {
            #expect(URL(string: address) != nil, "\(address) is exactly the kind URL(string:) does build")
            for kind in [ProtocolKind.mastodon, .discourse, .discuz] {
                #expect(Self.row(kind, url: address).outwardURL == nil,
                        "\(address) would have opened from a \(kind.rawValue) row")
            }
        }
    }

    /// The name on the control says what it does and where it goes, in every language shipped.
    ///
    /// "Open in browser" tells the reader what will happen and not where they will end up, and
    /// where they end up is the fact worth checking before following an outward link. The host is
    /// the one part of this the app knows for certain — `Source.host` is parsed, never lifted
    /// from anybody's markup.
    ///
    /// **One string for both surfaces.** `thread.open` is the pane's and the row reuses it: the
    /// sentence is equally true of both, and a second key saying the same thing in three bundles
    /// is one more pair to keep in step.
    @Test("The way out names the host, in every language the app ships")
    func theWayOutNamesTheHost() {
        // The suite runs under `.english`, so this is what the control is actually called.
        let name = Self.row(.discuz, url: "https://example.test/forum.php?mod=viewthread&tid=42")
            .outwardName
        #expect(name == String(format: L10n.t("thread.open"), "example.test"))
        #expect(name.contains("example.test"), "the control did not name the host")
        #expect(!name.contains("%@"), "the format was left unfilled")

        // The other bundles are *asked* for rather than assigned, because the suites run in
        // parallel and `L10n.language` is one global they share — the flake `shapeWord`'s
        // `language` parameter was added to retire, and the reason `wayOutName` takes one too.
        for language in [DummyLanguage.english, .taiwanese] {
            let spoken = DummyItem.wayOutName(host: "example.test", language: language)
            #expect(spoken.contains("example.test"), "\(language) does not name the host")
            #expect(!spoken.contains("%@"), "\(language) left the format unfilled")
            #expect(spoken != L10n.t("thread.open", language: language),
                    "\(language) did not fill the slot at all")
        }
    }

    /// One status two instances carry is two rows (#10), and SwiftUI tells rows apart by `id` — so
    /// the two must not share one, or the list draws a single row twice and loses the other. The
    /// note's own spelling stays on `noteID`, which is what a thread and a board query read back.
    @Test("One note through two hosts is two row ids and one note id")
    func twoHostsGiveTwoRowIDs() {
        let uri = "https://origin.example/users/ada/statuses/1"
        func row(_ host: String) -> DummyItem {
            DummyItem(Note(
                id: uri,
                source: Source(host: host, kind: .mastodon),
                author: "ada",
                handle: "@ada@origin.example",
                body: "",
                postedAt: .distantPast,
                categories: [.public]
            ))
        }
        let first = row("first.example")
        let second = row("second.example")
        #expect(first.id != second.id)
        #expect(first.noteID == uri)
        #expect(second.noteID == uri)
        #expect(first.id == NoteKey(host: "first.example", id: uri).rowID)
    }

    /// **One sentence for both surfaces that draw a way out.**
    ///
    /// A timeline row builds its name from a `DummyItem`; a Discuz! reply has no `DummyItem` to
    /// build one from — it is a `DiscuzPost` — so it asks `wayOutName` for the same host. If the
    /// two ever diverge, a reader meets two differently-worded controls that do the same thing
    /// and has to work out whether they are the same act. They are the same act.
    @Test("A row and a reply on one host are offered the same words")
    func bothSurfacesSayTheSameThing() {
        let row = Self.row(.discuz, url: "https://example.test/forum.php?mod=viewthread&tid=42")
        #expect(row.outwardName == DummyItem.wayOutName(host: "example.test"))
    }
}
