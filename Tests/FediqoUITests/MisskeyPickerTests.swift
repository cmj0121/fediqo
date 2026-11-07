import FediqoCore
import Foundation
import SwiftUI
import Testing
@testable import FediqoUI

/// #487: Misskey is offered among the kinds of server, and drawn as itself.
///
/// **What is pinned is what a reader meets before and after the press**: the picker names it and
/// leads to the field rather than to an empty list, the mark is not the Mastodon family's, and the
/// row and the page offer nothing Misskey does not have here — no sign-in, no writing, no trends.
@MainActor
@Suite("Misskey in the picker and on the page", .watched)
struct MisskeyPickerTests {
    private static let host = "misskey.example"

    init() {
        L10n.language = .english
    }

    private static let row = SourceRow(
        source: Source(host: host, kind: .misskey),
        profile: .unasked(host: host, kind: .misskey)
    )

    // MARK: - The picker

    @Test("The picker offers Misskey, and choosing it asks nobody and points at the field")
    func choosingMisskeyLeadsToTheField() async {
        #expect(JoinSheet.protocols.contains(.misskey))
        let http = FixtureHTTP(["/servers": .text("[]")])
        let session = ShellSession(http: http, store: ItemStore())

        session.browse()
        session.chooseProtocol(.misskey)

        #expect(session.stage == .browsingServers(.misskey))
        #expect(await http.paths.isEmpty, "a protocol with no directory asked one for its servers")
        // What the step draws in place of a list: the sentence that sends the reader to the field,
        // and not an empty list or a wait for one that is never asked.
        #expect(session.noSuggestions(language: .english)
            == "No suggestions for Misskey yet. Type a hostname in the field instead.")

        // And the one kind with a list is drawn its list, not the sentence.
        session.backToProtocols()
        #expect(session.noSuggestions() == nil, "the protocol list was given the servers' sentence")
        session.chooseProtocol(.mastodon)
        #expect(session.noSuggestions() == nil, "the one kind with a list lost it")
    }

    // MARK: - The mark

    /// What a kind is drawn as, whichever tier answers: its drawing, or the shape glyph.
    private static func picture(_ kind: ProtocolKind, pixels: CGFloat) -> String {
        SourceMark.kindMark(kind, pixels: pixels) ?? "glyph:" + SourceMark.symbol(DummyItem.shape(of: kind))
    }

    /// The picker's row, the source row and the masthead glance all ask `SourceMark.drawing`, so
    /// the pair asked here is what every one of them draws.
    @Test("Misskey's mark is its own: no other kind is drawn with it, at any pixel count")
    func misskeyIsDrawnAsItself() {
        for pixels in [CGFloat(16), 24, 32, 48, 72] {
            let misskey = Self.picture(.misskey, pixels: pixels)
            for kind in ProtocolKind.allCases where kind != .misskey {
                #expect(Self.picture(kind, pixels: pixels) != misskey, "\(kind) at \(pixels)px")
            }
        }
        let drawn = SourcePageTests.drawn(Self.row)
        #expect(drawn.markName == "KindMisskey" || drawn.markName == "KindMisskeySmall")
        #expect(drawn.hasKindMark)
    }

    /// The drawing is one opaque ink on a transparent ground, so what it is seen by is the ink the
    /// row paints it in — a drawing's `inkDim`, the row's own `markInk` — measured on every plate
    /// the row is drawn on, in light and in dark. A graphical object, so `placeFloor`.
    @Test("Misskey's mark can be seen on every plate, in light and in dark")
    func misskeysMarkCanBeSeen() {
        #expect(SourcePageTests.drawn(Self.row).markInk
            == SourceMark.ink(signedIn: false, quiet: ShellChrome.inkDim(.light), scheme: .light))
        for scheme in [ColorScheme.light, .dark] {
            let ink = SourceMark.ink(signedIn: false, quiet: ShellChrome.inkDim(scheme), scheme: scheme)
            for (named, ground) in ShellContrast.plates(scheme, washed: true) {
                let ratio = ShellContrast.ratio(ink, on: ground, scheme)
                #expect(ratio >= ShellChrome.placeFloor, "Misskey's mark is \(ratio):1 on \(named) in \(scheme)")
            }
        }
    }

    /// A glyph says nothing to a listener, so the kind has to be said in words: the picker's row
    /// is labelled with the protocol's name, and the source row says it in its spoken line.
    @Test("A listener hears Misskey named, on the picker and on the row")
    func aListenerHearsTheKind() {
        #expect(ProtocolKind.misskey.displayName == "Misskey")
        let said = SourceRow.spoken(Self.row)
        #expect(said.contains("Misskey"), "\(said)")
        #expect(said.contains(L10n.t("account.source.writing.never")), "\(said)")
    }

    // MARK: - What the row and the page offer

    @Test("A Misskey's row and page offer no sign-in, no writing and no trends")
    func misskeyOffersOnlyReading() {
        #expect(!SourceRow.canSignIn(.misskey))
        #expect(!Self.row.canSignIn)
        #expect(Self.row.writing == .never)
        #expect(Self.row.owed == .nothing, "a permission control was drawn for a sign-in that cannot exist")
        #expect(!ShellSession.hasTrends(.misskey))
        #expect(!SourceRow.canChooseLists(.misskey))
        #expect(!SourceRow.canChangeBoards(.misskey))
        #expect(SourcePreviewView.heldLine(Source(host: Self.host, kind: .misskey))
            == L10n.t("source.held.microblog"))
        #expect(SourcePreviewView.outcomeKey(.misskey) == "join.preview.next.microblog")
    }
}
