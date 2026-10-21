#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// V0, drawn: in a list the app a post names sits at the very foot of its band, at the far end of
/// the line — where the marks end with no picture in the slot, and level with the picture's foot
/// beside one — however few its words; the row keeps its one height, and the opened post is as
/// it was. Wide and narrow, light and dark, the usual text and the largest.
@MainActor
@Suite("The app a post names, at the band's foot")
struct ViaFootHostedTests {
    private static let longPost = String(repeating: "A post that goes on and on about the weather and more. ", count: 30)

    private static func item(body: String = "Short.", via: String? = "Fediqo", pictured: Bool = false, boosted: Bool = false) -> DummyItem {
        let picture = FediqoCore.Attachment(kind: .image, previewURL: URL(string: "https://first.example/a.jpg"))
        return DummyItem(Note(
            id: "n1", source: Source(host: "first.example", kind: .mastodon), author: "Ada",
            handle: "@ada@author.example", body: body, postedAt: Date(timeIntervalSince1970: 1_700_000_000),
            categories: [.public], boostedBy: boosted ? "Bob" : nil, attachments: pictured ? [picture] : [],
            statusID: "1", via: via
        ))
    }

    private static func laid(
        _ item: DummyItem, layout: ShellLayout, scheme: ColorScheme, size: DynamicTypeSize, inFull: Bool = false
    ) -> (frames: [RowBand: CGRect], height: CGFloat) {
        let probe = RowBandProbe()
        let row = DummyItemRow(item: item, catalogues: EmojiCatalogueStore(), posts: ForumPosts(), inFull: inFull, probe: probe)
            .environment(\.shellLayout, layout)
            .environment(\.colorScheme, scheme)
            .dynamicTypeSize(size)
        let host = NSHostingView(rootView: row.frame(width: layout == .wide ? 720 : 390))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        return (probe.frames, host.fittingSize.height)
    }

    private static let rooms: [(ShellLayout, ColorScheme, DynamicTypeSize)] = [ShellLayout.wide, .narrow].flatMap { layout in
        [ColorScheme.light, .dark].flatMap { scheme in [DynamicTypeSize.large, .accessibility5].map { (layout, scheme, $0) } }
    }

    @Test("Short words and no picture: the app's line ends where the band and the marks do")
    func noPicture() throws {
        for (layout, scheme, size) in Self.rooms {
            for boosted in [false, true] {
                let laid = Self.laid(Self.item(boosted: boosted), layout: layout, scheme: scheme, size: size).frames
                let via = try #require(laid[.via], "\(layout) \(size): no app line")
                let band = try #require(laid[.content])
                let marks = try #require(laid[.marks])
                #expect(abs(via.maxY - band.maxY) < 0.5, "\(layout) \(size) boosted \(boosted): \(via.maxY) against the band's \(band.maxY)")
                #expect(abs(via.maxX - marks.maxX) < 0.5, "\(layout) \(size): \(via.maxX) against the marks' \(marks.maxX)")
                #expect(via.maxY <= marks.minY + 0.5, "above the marks")
            }
        }
    }

    @Test("Short words beside a picture: the app's line ends at the words' column, its foot level with the picture's")
    func besideAPicture() throws {
        for (layout, scheme, size) in Self.rooms {
            for boosted in [false, true] {
                let laid = Self.laid(Self.item(pictured: true, boosted: boosted), layout: layout, scheme: scheme, size: size).frames
                let via = try #require(laid[.via], "\(layout) \(size): no app line")
                let picture = try #require(laid[.picture])
                #expect(abs(via.maxY - picture.maxY) < 0.5, "\(layout) \(size) boosted \(boosted): \(via.maxY) against the picture's \(picture.maxY)")
                #expect(via.maxX <= picture.minX + 0.5, "\(layout) \(size): left of the slot")
            }
        }
    }

    @Test("Long words keep the row its one height, and never run under the app's line; the opened post keeps it above the marks")
    func longWords() throws {
        for (layout, scheme, size) in Self.rooms {
            for pictured in [false, true] {
                let named = Self.laid(Self.item(body: Self.longPost, pictured: pictured), layout: layout, scheme: scheme, size: size)
                let plain = Self.laid(Self.item(body: Self.longPost, via: nil, pictured: pictured), layout: layout, scheme: scheme, size: size)
                let short = Self.laid(Self.item(pictured: pictured), layout: layout, scheme: scheme, size: size)
                #expect(abs(named.height - plain.height) < 0.5, "\(layout) \(size): \(named.height) against \(plain.height)")
                #expect(abs(named.height - short.height) < 0.5, "\(layout) \(size): one height, short or long")
                let via = try #require(named.frames[.via])
                let words = try #require(named.frames[.words])
                #expect(words.maxY <= via.minY + 0.5, "\(layout) \(size) pictured \(pictured): the words reach \(words.maxY), the app's line starts at \(via.minY)")
            }
            let opened = Self.laid(Self.item(), layout: layout, scheme: scheme, size: size, inFull: true).frames
            #expect(opened[.via] == nil, "the pane draws its own line above the marks")
        }
    }
}
#endif
