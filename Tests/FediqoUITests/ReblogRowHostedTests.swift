import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #290, the reblog's row as it is laid out: who reblogged and when on its first line, the post
/// under it with the post's own author, face and publish time, in each state the row has, on a
/// wide page and across a phone.
///
/// Hosted, so what is asserted is where the row's parts were really placed. What a hosted view
/// cannot say — how it looks in light and dark, on a Mac and a phone — is a running app's.
@MainActor
@Suite("A reblog's row, laid out", .serialized)
struct ReblogRowHostedTests {
    private static let host = "a-rather-long-instance-name.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let published = Date(timeIntervalSince1970: 1_700_000_000)
    private static let reblogged = published.addingTimeInterval(7 * 86400)

    private static func post(
        gone: Bool = false, changed: Bool = false, covered: Bool = false, reply: Bool = false, quoting: Bool = false
    ) -> Note {
        let quoted = QuotedPost(
            id: "https://\(host)/users/cyd/statuses/5", statusID: "5", author: "Cyd", handle: "@cyd@\(host)",
            body: "the quoted post", postedAt: published.addingTimeInterval(-3600)
        )
        return
        Note(
            id: "https://\(host)/users/ada/statuses/9", source: source, author: "Ada Lovelace the First",
            handle: "@ada@\(host)", body: "hello, a post about cats", postedAt: published, categories: [],
            reply: reply ? Reply(handle: "@cyd@\(host)", inReplyToId: "1") : nil, audience: .everyone,
            sensitive: covered ? true : nil, spoiler: covered ? "a cover" : "", counts: Counts(favourites: 3),
            statusID: "9", goneSince: gone ? published : nil,
            quote: quoting ? Quote(state: .accepted, post: quoted) : nil,
            editedAt: changed ? published.addingTimeInterval(60) : nil
        )
    }

    private static func reblog(
        by name: String = "Bob", kept: Bool = false, gone: Bool = false, due: Bool = false
    ) -> Note {
        Note(
            id: "https://\(host)/users/bob/statuses/900/activity", source: source, author: name,
            handle: "@bob@\(host)", body: "", postedAt: reblogged, categories: [.home], statusID: "900",
            goneSince: gone ? reblogged : nil, kept: kept,
            refs: [Reference(kind: .reblogs, id: "https://\(host)/users/ada/statuses/9", statusID: "9")], refsDue: due
        )
    }

    private struct Laid {
        let probe: RowBandProbe
        let size: CGSize
        @MainActor var meta: [RowMetaPart: CGRect] { probe.meta }
    }

    private static func laid(
        _ item: DummyItem, layout: ShellLayout, width: CGFloat, here: Set<String> = [host],
        type: DynamicTypeSize = .large, acting: ItemActing = ItemActing()
    ) -> Laid {
        let probe = RowBandProbe()
        let row = DummyItemRow(
            item: item, catalogues: EmojiCatalogueStore(), posts: ForumPosts(), acting: acting, probe: probe,
            onOpenPerson: { _ in }, onToast: { _ in }
        )
        .environment(\.shellLayout, layout)
        .environment(\.shellSourcesHere, here)
        .environment(\.dynamicTypeSize, type)
        let hosted = NSHostingView(rootView: row.frame(width: width))
        hosted.frame = NSRect(origin: .zero, size: hosted.fittingSize)
        hosted.layoutSubtreeIfNeeded()
        return Laid(probe: probe, size: hosted.fittingSize)
    }

    private static let pages: [(ShellLayout, CGFloat)] = [(.wide, 720), (.narrow, 390), (.narrow, 320)]

    /// Each part named is laid out, inside a row `width` wide, with room, and none over the next.
    private static func holds(_ parts: [RowMetaPart: CGRect], _ order: [RowMetaPart], width: CGFloat) throws {
        let frames = try order.map { try #require(parts[$0], "\($0) was not laid out at \(width)") }
        for (part, frame) in zip(order, frames) {
            #expect(frame.minX >= -0.5 && frame.maxX <= width + 0.5, "\(part) at \(frame) leaves a row \(width) wide")
            #expect(frame.width > 0, "\(part) was squeezed to nothing at \(width)")
        }
        for (left, right) in zip(frames, frames.dropFirst()) {
            #expect(left.maxX <= right.minX + 0.5, "two parts overlap at \(width): \(left) and \(right)")
        }
    }

    // MARK: - The row that shows its post

    @Test("Who reblogged and when are the row's first line, above the post's own header; the two times end in one column, the reblog's above the post's")
    func twoLinesTwoTimes() throws {
        let item = DummyItem(Self.reblog(), reblogging: Self.post())
        for (layout, width) in Self.pages {
            let laid = Self.laid(item, layout: layout, width: width)
            try Self.holds(laid.meta, [.reblogger, .reblogAge], width: width)
            try Self.holds(laid.meta, [.names, .source, .age], width: width)
            let reblogAge = try #require(laid.meta[.reblogAge]), age = try #require(laid.meta[.age])
            #expect(reblogAge.maxY <= age.minY + 0.5, "the reblog's time is on the line above the post's at \(width)")
            #expect(abs(reblogAge.maxX - age.maxX) <= 1, "the two times do not end in one column at \(width): \(reblogAge) and \(age)")
            let first = try #require(laid.probe.frames[.decorator] ?? laid.meta[.reblogger])
            let header = try #require(laid.probe.frames[.header])
            #expect(first.maxY <= header.minY + 0.5)
            #expect(try #require(laid.probe.frames[.content]).height > 0)
        }
    }

    @Test("The row is the height every row is: a reblog, the post it shows, and an answer are one height on each page")
    func oneHeight() {
        let reblog = DummyItem(Self.reblog(), reblogging: Self.post())
        let own = DummyItem(Self.post())
        let answer = DummyItem(Self.post(reply: true))
        let legacy = DummyItem(Note(
            id: "l", source: Self.source, author: "Ada", handle: "@ada@\(Self.host)", body: "hello, a post about cats",
            postedAt: Self.published, categories: [.home], boostedBy: "Bob", audience: .everyone, spoiler: "", statusID: "9"
        ))
        for (layout, width) in [(ShellLayout.wide, CGFloat(720)), (.narrow, 390)] {
            let heights = [reblog, own, answer, legacy].map { Self.laid($0, layout: layout, width: width).size.height }
            #expect(heights.allSatisfy { abs($0 - heights[0]) <= 0.5 }, "heights differ at \(width): \(heights)")
        }
    }

    @Test("A reblog of an answer that quotes puts four things on the first line — who reblogged, whom the post answers, that it quotes, and when: the post's own facts give way first, who reblogged keeps the room a plain reblog gives it, and the time is whole",
          arguments: [(ShellLayout.wide, CGFloat(720)), (.narrow, 390), (.narrow, 320)])
    func theCrowdedFirstLine(layout: ShellLayout, width: CGFloat) throws {
        let crowded = Self.laid(DummyItem(Self.reblog(), reblogging: Self.post(reply: true, quoting: true)), layout: layout, width: width)
        let plain = Self.laid(DummyItem(Self.reblog(), reblogging: Self.post()), layout: layout, width: width)
        try Self.holds(crowded.meta, [.reblogger, .reblogAge], width: width)
        let who = try #require(crowded.meta[.reblogger]), plainWho = try #require(plain.meta[.reblogger])
        #expect(who.width >= plainWho.width - 0.5, "who reblogged was cut to \(who.width) of \(plainWho.width) at \(width)")
        let when = try #require(crowded.meta[.reblogAge]), plainWhen = try #require(plain.meta[.reblogAge])
        #expect(abs(when.width - plainWhen.width) <= 0.5 && abs(when.maxX - plainWhen.maxX) <= 0.5, "the time moved or was cut at \(width)")
        #expect(abs(who.height - plainWho.height) <= 0.5)
    }

    @Test("A long name of whoever reblogged gives way to the time, never the time to the name, across a phone")
    func aLongRebloggerGivesWay() throws {
        let name = String(repeating: "Bartholomew ", count: 8)
        let item = DummyItem(Self.reblog(by: name), reblogging: Self.post(reply: true))
        for width in [CGFloat(390), 320] {
            let laid = Self.laid(item, layout: .narrow, width: width)
            try Self.holds(laid.meta, [.reblogger, .reblogAge], width: width)
            let short = Self.laid(DummyItem(Self.reblog(), reblogging: Self.post()), layout: .narrow, width: width)
            #expect(try #require(laid.meta[.reblogAge]).width >= #require(short.meta[.reblogAge]).width - 0.5, "the time was cut at \(width)")
        }
    }

    @Test("With the post deleted at its source and changed, and the source removed, the header still holds across a phone under the reblog's line: three marks, the name and both times",
          arguments: [CGFloat(390), 320])
    func everyMarkAtOnce(width: CGFloat) throws {
        let item = DummyItem(Self.reblog(), reblogging: Self.post(gone: true, changed: true))
        #expect(DummyItemRow.headerMarks(item, here: []) == 3, "the post's marks, on the reblog's row")
        let laid = Self.laid(item, layout: .narrow, width: width, here: [])
        try Self.holds(laid.meta, [.names, .source, .left, .gone, .changed, .age], width: width)
        try Self.holds(laid.meta, [.reblogger, .reblogAge], width: width)
        #expect(try #require(laid.meta[.names]).width >= 40, "the name was left a letter")
    }

    @Test("At large text the reblog's line holds across a phone wherever the header under it does, and at the accessibility sizes it reaches no further than that header: the two times stay in one column")
    func largeText() throws {
        let item = DummyItem(Self.reblog(), reblogging: Self.post(changed: true))
        for size in [DynamicTypeSize.xxxLarge, .accessibility1] {
            for width in [CGFloat(320)] {
                let laid = Self.laid(item, layout: .narrow, width: width, type: size)
                try Self.holds(laid.meta, [.reblogger, .reblogAge], width: width)
                try Self.holds(laid.meta, [.names, .source, .changed, .age], width: width)
            }
        }
        // Past those, the header itself is wider than a phone — on every row, a reblog's or not.
        // The reblog's line adds nothing to that: its time ends where the header's does.
        for size in [DynamicTypeSize.accessibility3] {
            let laid = Self.laid(item, layout: .narrow, width: 390, type: size)
            let own = Self.laid(DummyItem(Self.post(changed: true)), layout: .narrow, width: 390, type: size)
            let reblogAge = try #require(laid.meta[.reblogAge]), age = try #require(laid.meta[.age])
            #expect(abs(reblogAge.maxX - age.maxX) <= 1)
            let ownAge = try #require(own.meta[.age])
            #expect(abs(age.minX - ownAge.minX) <= 0.5 && abs(age.width - ownAge.width) <= 0.5, "the header under the reblog's line is as wide as the post's own row draws it")
            #expect(abs(laid.size.height - own.size.height) <= 0.5)
        }
    }

    // MARK: - Each state

    @Test("Each state of the row lays out whole on each page: shown, covered, changed, deleted at its source, the reblog taken back, the source removed, kept")
    func eachStateThatShowsItsPost() throws {
        let states: [(String, DummyItem, Set<String>)] = [
            ("shown", DummyItem(Self.reblog(), reblogging: Self.post()), [Self.host]),
            ("covered", DummyItem(Self.reblog(), reblogging: Self.post(covered: true)), [Self.host]),
            ("changed", DummyItem(Self.reblog(), reblogging: Self.post(changed: true)), [Self.host]),
            ("deleted at its source", DummyItem(Self.reblog(), reblogging: Self.post(gone: true)), [Self.host]),
            ("the reblog taken back", DummyItem(Self.reblog(gone: true), reblogging: Self.post()), [Self.host]),
            ("source removed", DummyItem(Self.reblog(), reblogging: Self.post()), []),
            ("kept", DummyItem(Self.reblog(kept: true), reblogging: Self.post()), [Self.host]),
        ]
        // One narrow page: what differs between these is which marks and bands are drawn, and the
        // widths themselves are held by the plain row and the crowded line, on all three pages.
        for (name, item, here) in states {
            for (layout, width) in [(ShellLayout.narrow, CGFloat(390))] {
                let laid = Self.laid(item, layout: layout, width: width, here: here)
                try Self.holds(laid.meta, [.reblogger, .reblogAge], width: width)
                #expect(laid.meta[.names] != nil && laid.meta[.age] != nil, "\(name) drew no header at \(width)")
                #expect(laid.meta[.reblogNotice] == nil)
                for band in [RowBand.header, .content, .marks] {
                    let frame = try #require(laid.probe.frames[band], "\(name) drew no \(band) at \(width)")
                    #expect(frame.height > 0 && frame.maxX <= width + 0.5, "\(name): \(band) at \(frame), \(width) wide")
                }
            }
        }
    }

    @Test("The post's marks are in its header on the reblog's row, and the reblog's own are not: deleted and changed are the post's; a reblog taken back marks no header")
    func whoseMarks() {
        let both = Self.laid(DummyItem(Self.reblog(), reblogging: Self.post(gone: true, changed: true)), layout: .wide, width: 720)
        #expect(both.meta[.gone] != nil && both.meta[.changed] != nil)
        let undone = Self.laid(DummyItem(Self.reblog(gone: true), reblogging: Self.post()), layout: .wide, width: 720)
        #expect(undone.meta[.gone] == nil && undone.meta[.changed] == nil, "the post is as it was")
        let removed = Self.laid(DummyItem(Self.reblog(), reblogging: Self.post()), layout: .wide, width: 720, here: [])
        #expect(removed.meta[.left] != nil)
    }

    @Test("A reblog with no post to show — on its way, or no longer held — is the reblog alone: no first line, whoever reblogged in the header at the reblog's time, a sentence where the words would be, and the keep mark",
          arguments: [true, false])
    func noPostToShow(onItsWay: Bool) throws {
        let item = DummyItem(Self.reblog(due: onItsWay), reblogging: nil)
        #expect(item.reblogOnItsWay == onItsWay && item.reblogUnheld == !onItsWay)
        for (layout, width) in [(ShellLayout.wide, CGFloat(720)), (.narrow, 320)] {
            let laid = Self.laid(item, layout: layout, width: width)
            #expect(laid.meta[.reblogger] == nil && laid.meta[.reblogAge] == nil)
            try Self.holds(laid.meta, [.names, .source, .age], width: width)
            let notice = try #require(laid.meta[.reblogNotice], "the sentence is not drawn at \(width)")
            #expect(notice.width > 0 && notice.height > 0 && notice.maxX <= width + 0.5)
            let header = try #require(laid.probe.frames[.header])
            #expect(notice.minY >= header.maxY - 0.5, "it stands where the post's words would")
            #expect(laid.probe.marks[L10n.t("item.act.keep.reblog")] != nil, "the reblog can still be kept")
            #expect(laid.probe.marks.keys.allSatisfy { !$0.hasPrefix(L10n.t("item.act.favourite")) })
        }
    }

    @Test("The keep mark on a reblog's row is named as the reblog's, kept or not; the post's own row keeps its plain name")
    func theKeepMarkNamesTheReblog() {
        let reblog = Self.laid(DummyItem(Self.reblog(), reblogging: Self.post()), layout: .wide, width: 720)
        #expect(reblog.probe.marks[L10n.t("item.act.keep.reblog")] != nil && reblog.probe.marks[L10n.t("item.act.keep")] == nil)
        let kept = Self.laid(DummyItem(Self.reblog(kept: true), reblogging: Self.post()), layout: .wide, width: 720)
        #expect(kept.probe.marks[L10n.t("item.act.unkeep.reblog")] != nil)
        let own = Self.laid(DummyItem(Self.post()), layout: .wide, width: 720)
        #expect(own.probe.marks[L10n.t("item.act.keep")] != nil && own.probe.marks[L10n.t("item.act.keep.reblog")] == nil)
    }

    @Test("The post's own row and a row held from before draw no reblog line of this kind: no reblogger to press, and one time")
    func theOtherRowsAreNotThisRow() {
        let own = Self.laid(DummyItem(Self.post()), layout: .wide, width: 720)
        #expect(own.meta[.reblogger] == nil && own.meta[.reblogAge] == nil && own.meta[.age] != nil)
        let legacy = Self.laid(DummyItem(Note(
            id: "l", source: Self.source, author: "Ada", handle: "@ada@\(Self.host)", body: "hello",
            postedAt: Self.published, categories: [.home], boostedBy: "Bob", spoiler: "", statusID: "9"
        )), layout: .wide, width: 720)
        #expect(legacy.meta[.reblogger] == nil && legacy.meta[.reblogAge] == nil)
    }

    // MARK: - What the row says, as functions

    @Test("The row model keeps the two times apart, knows who reblogged, and whose marks are whose")
    func theModel() throws {
        let item = DummyItem(Self.reblog(), reblogging: Self.post(gone: true))
        #expect(item.postedAt == Self.reblogged && item.publishedAt == Self.published)
        #expect(DummyItemRow.headerTime(item) == Self.published, "beside the author: when the post was published")
        #expect(DummyItemRow.reblogTime(item) == Self.reblogged, "beside who reblogged: when it was reblogged")
        #expect(DummyItemRow.reblogTime(DummyItem(Self.post())) == nil && DummyItemRow.reblogTime(DummyItem(Self.reblog(), reblogging: nil)) == nil)
        #expect(DummyItemRow.headerTime(DummyItem(Self.reblog(), reblogging: nil)) == Self.reblogged, "a reblog alone has one time, its own")
        #expect(item.reblogger?.name == "Bob" && item.reblogger?.handle == "@bob@\(Self.host)")
        #expect(DummyPerson(item)?.name == "Ada Lovelace the First", "the face and the name in the header are the author's")
        #expect(item.postGone && !item.reblogUndone && !item.goneEverywhere)
        let undone = DummyItem(Self.reblog(gone: true), reblogging: Self.post())
        #expect(undone.reblogUndone && !undone.postGone)
        let own = DummyItem(Self.post())
        #expect(own.publishedAt == own.postedAt && own.reblogger == nil && !own.reblogOnItsWay)
        let unheld = DummyItem(Self.reblog(), reblogging: nil)
        #expect(unheld.publishedAt == Self.reblogged && unheld.reblogger?.name == "Bob" && !unheld.postGone)
    }

    @Test("Every sentence of the row, in each language", arguments: [DummyLanguage.english, .taiwanese])
    func sentences(language: DummyLanguage) throws {
        let english = language == .english
        let shown = DummyItem(Self.reblog(), reblogging: Self.post())
        #expect(DummyItemRow.reblogLine(shown, language: language) == (english ? "Reblogged by Bob" : "由 Bob 轉發"))
        #expect(DummyItemRow.reblogNotice(shown, language: language) == nil)
        let spoken = try #require(DummyItemRow.spokenReblog(shown, language: language))
        #expect(spoken.hasPrefix(english ? "Reblogged by Bob, " : "由 Bob 轉發，") && spoken.count > (english ? 20 : 10), "who, then exactly when")
        let undone = DummyItem(Self.reblog(gone: true), reblogging: Self.post())
        #expect(DummyItemRow.reblogLine(undone, language: language) == (english ? "Reblogged by Bob, since taken back" : "由 Bob 轉發，之後已收回"))
        let unheld = DummyItem(Self.reblog(), reblogging: nil)
        #expect(DummyItemRow.reblogLine(unheld, language: language) == nil && DummyItemRow.spokenReblog(unheld, language: language) == nil)
        #expect(DummyItemRow.reblogNotice(unheld, language: language) == (english ? "Reblogged a post this device no longer holds." : "轉發了一則這台裝置已不再留著的貼文。"))
        let coming = DummyItem(Self.reblog(due: true), reblogging: nil)
        #expect(DummyItemRow.reblogNotice(coming, language: language) == (english ? "Reblogged a post that is on its way." : "轉發了一則還在路上的貼文。"))
        #expect(DummyItemRow.reblogNotice(DummyItem(Self.post()), language: language) == nil)
        for key in [
            "item.boostedBy", "item.arrivedAsReblogBy", "item.reblog.unheld", "item.reblog.onItsWay", "item.reblog.undone",
            "item.reblog.spoken", "item.act.onPost", "item.act.keep.reblog", "item.act.unkeep.reblog",
        ] {
            #expect(L10n.t(key, language: language) != key, "\(key) is not written in \(language)")
        }
        #expect(L10n.t(DummyItemRow.keepName(shown), language: language) == (english ? "Keep this reblog" : "留下這則轉發"))
        #expect(L10n.t(DummyItemRow.keepName(DummyItem(Self.reblog(kept: true), reblogging: Self.post())), language: language)
            == (english ? "Stop keeping this reblog" : "不再留下這則轉發"))
        #expect(DummyItemRow.keepName(DummyItem(Self.post())) == "item.act.keep")
    }

    @Test("A mark on the reblog's row says whose post it goes to; the same mark on the post's own row does not", arguments: [DummyLanguage.english, .taiwanese])
    func marksNameThePost(language: DummyLanguage) {
        let english = language == .english
        let row = DummyItem(Self.reblog(), reblogging: Self.post())
        let target = row.reblogged[0]
        var acting = ItemActing(acts: PostActs(offered: [.favourite, .boost]))
        acting.through = [.favourite: target, .boost: target]
        let mark = ItemActs.mark(.favourite, on: row, acting: acting, language: language)
        #expect(mark.spoken == (english ? "Favourite — the post by Ada Lovelace the First" : "\(ItemActs.name(.favourite, done: false, language: language))——Ada Lovelace the First 的貼文"))
        #expect(mark.count == 3, "and counts the post's")
        let own = ItemActs.mark(.favourite, on: DummyItem(Self.post()), acting: ItemActing(), language: language)
        #expect(own.spoken == ItemActs.name(.favourite, done: false, language: language))
    }
}
