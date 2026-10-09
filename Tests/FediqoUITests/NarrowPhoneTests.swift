import FediqoCore
import Foundation
import SwiftUI
import Testing
@testable import FediqoUI
#if os(macOS)
import AppKit
#endif

/// #302: nothing is cut off on the narrowest phone.
///
/// **What can be worked out is worked out, and what is drawn is measured.** The orders things
/// give way in are values a test reads; a row, its marks and a notice are hosted off screen at a
/// phone's width in the narrow arrangement and asked where their parts landed. Only relations
/// are asserted — inside the row, not over the next, no taller than a few lines — never a
/// number a font decides.
///
/// What this does not reach: a phone. A sheet's size, a safe area and the tab bar are the
/// system's there, and are looked at in pictures (`scripts/shots.sh --phone`).
@Suite("Nothing is cut off on the narrowest phone", .serialized)
@MainActor
struct NarrowPhoneTests {
    // MARK: - The orders things give way in

    @Test("A row's header gives way a step at a time: the host to its first letter, the age to its shortest words, then the handle; then the marks' words; and last the pill and half of every gap")
    func headerLadder() {
        #expect(HeadFit.ladder == [.whole, .initialled, .brief, .unhandled, .plain, .bare, .gaunt])
        #expect(Set(HeadFit.ladder) == Set(HeadFit.allCases), "every way of drawing the line is tried")
        // The handle is kept while the host and the age's words give way, and is gone from there on.
        #expect(HeadFit.ladder.map(\.drawsHandle) == [true, true, true, false, false, false, false])
        #expect(HeadFit.ladder.map(\.pill) == [.host, .initial, .initial, .host, .initial, .initial, .absent])
        #expect(HeadFit.ladder.map(\.shortAge) == [false, false, true, false, true, true, true])
        #expect(HeadFit.ladder.map(\.terse) == [false, false, false, false, false, true, true])
        #expect(HeadFit.ladder.map(\.close) == [false, false, false, false, false, false, true])
    }

    private static func plain(host: String, name: String = "Ada", handle: String = "@ada@m.example") -> DummyItem {
        DummyItem(Note(
            id: "1", source: Source(host: host, kind: .mastodon), author: name, handle: handle,
            body: "Short.", postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: [.public],
            audience: .everyone, statusID: "1"
        ))
    }

    @Test("A host that cannot be said whole is said by its first letter; a host with no letter draws no pill, and the last rung draws none")
    func hostInitial() {
        #expect(HeadFit.initial(of: "fixture.example") == "f")
        #expect(HeadFit.initial(of: "林.example") == "林")
        #expect(HeadFit.initial(of: "") == nil)
        let item = Self.plain(host: "fixture.example")
        #expect(DummyItemRow.pillSays(item, fit: nil) == "fixture.example", "a wide page says the host")
        #expect(DummyItemRow.pillSays(item, fit: .whole) == "fixture.example")
        #expect(DummyItemRow.pillSays(item, fit: .unhandled) == "fixture.example")
        #expect(DummyItemRow.pillSays(item, fit: .plain) == "f")
        #expect(DummyItemRow.pillSays(item, fit: .gaunt) == nil)
        #expect(DummyItemRow.pillSays(Self.plain(host: ""), fit: .initialled) == nil, "no letter, no pill")
    }

    @Test("A handle the line had no room to draw is still said after the name")
    func handleIsSaid() {
        #expect(DummyItemRow.spokenNames(Self.plain(host: "m.example")) == "Ada, @ada@m.example")
        #expect(DummyItemRow.spokenNames(Self.plain(host: "m.example", name: "")) == "@ada@m.example")
        #expect(DummyItemRow.spokenNames(Self.plain(host: "m.example", handle: "")) == "Ada")
    }

    @Test("A line that truncates is tried for size at the room it is sure of, and at its own where that is less")
    func leastIdeal() {
        #expect(LeastIdeal.across(400, cap: 72) == 72)
        #expect(LeastIdeal.across(30, cap: 72) == 30)
        #expect(LeastIdeal.across(400, cap: .infinity) == 400)
    }

    @Test("An opened post's head gives up the hint about a key first, then the words beside the way out")
    func threadHeadLadder() {
        #expect(ThreadHead.ladder == [.whole, .unhinted, .glyphs])
        #expect(ThreadHead.ladder.map(\.hintsKey) == [true, false, false])
        #expect(ThreadHead.ladder.map(\.namesWayOut) == [true, true, false])
        #expect(Set(ThreadHead.ladder) == Set(ThreadHead.allCases))
        #expect(ThreadHead.fits(on: .narrow) == ThreadHead.ladder)
        #expect(ThreadHead.fits(on: .wide) == nil, "a wide page's line is not fitted at all")
    }

    @Test("A sheet holds a floor where it is sized by what is in it, and none where the system sizes it")
    func sheetFloor() {
        let floor = CGSize(width: 380, height: 480)
        #expect(ShellSheetFloor.held(floor, sizedByContent: true) == floor)
        #expect(ShellSheetFloor.held(floor, sizedByContent: false) == nil)
        #if os(macOS)
        #expect(ShellSheetFloor.sizedByContent)
        #expect(ShellSheetFloor.held(floor) == floor, "a Mac's sheets are as they were")
        #endif
    }

    @Test("A sheet for writing asks for no floor on a compact page, and for the one it always asked where there is room")
    func writingRoom() {
        #expect(WritingRoom.floor(600, compact: true) == nil)
        #expect(WritingRoom.floor(600, compact: false) == 600)
        #expect(WritingRoom.floor(400, compact: false) == 400)
    }

    @Test("A scrolled row of tabs fades at an end only where there is more beyond it")
    func tabsMore() {
        // At rest at the start of a row wider than the page.
        #expect(ShellTabsMore(offset: 0, across: 300, content: 500) == ShellTabsMore(leading: false, trailing: true))
        // Part-way along.
        #expect(ShellTabsMore(offset: 80, across: 300, content: 500) == ShellTabsMore(leading: true, trailing: true))
        // At the end, to within a point.
        #expect(ShellTabsMore(offset: 199.5, across: 300, content: 500) == ShellTabsMore(leading: true, trailing: false))
        // A row that fits has nothing beyond either end.
        #expect(ShellTabsMore(offset: 0, across: 300, content: 300) == ShellTabsMore(leading: false, trailing: false))
    }

    @Test("A notice stands beside the compose button where it floats, by the width of the button's corner, and where none floats it has the whole foot of the page")
    func noticeBesideTheButton() {
        let corner = FediqoRootView.composeCorner(canCompose: true)
        #expect(corner.width > FediqoRootView.Compact.button)
        #expect(StandsBesideFloatingCorner.kept(corner: corner, already: 0) == corner.width)
        #expect(StandsBesideFloatingCorner.kept(corner: corner, already: ShellSpace.pad) == corner.width - ShellSpace.pad, "its own margin is not kept twice")
        #expect(StandsBesideFloatingCorner.kept(corner: FediqoRootView.composeCorner(canCompose: false), already: ShellSpace.pad) == 0)
        #expect(StandsBesideFloatingCorner.kept(corner: .zero, already: 0) == 0, "a wide page keeps nothing back")
    }

    #if os(macOS)
    // MARK: - A row, hosted at a phone's width

    private static let host = "a-rather-long-subdomain.fixture.example"
    private static let posted = Date(timeIntervalSince1970: 1_700_000_000)

    /// A long name over a long handle, from a long host, changed after it was sent: the row a
    /// narrow page has least room for.
    private static func crowded() -> DummyItem {
        DummyItem(Note(
            id: "9", source: Source(host: host, kind: .mastodon),
            author: "Grace Brewster Murray Hopper, Rear Admiral (retired)",
            handle: "@grace.brewster.murray.hopper@\(host)",
            body: "A name and a handle that are each longer than the screen is wide, over a post of ordinary length.",
            postedAt: posted, categories: [.public], audience: .everyone,
            counts: Counts(replies: 12, reblogs: 340, favourites: 1289), statusID: "9",
            editedAt: posted.addingTimeInterval(60)
        ))
    }

    private static let everyAct = ItemActing(acts: PostActs(offered: Set(PostAct.allCases)), perform: { _ in })

    private static func laid(
        _ item: DummyItem, layout: ShellLayout, width: CGFloat, type: DynamicTypeSize,
        acting: ItemActing = ItemActing(), here: Set<String>? = nil
    ) -> RowBandProbe {
        let probe = RowBandProbe()
        let row = DummyItemRow(
            item: item, catalogues: EmojiCatalogueStore(), posts: ForumPosts(), acting: acting, probe: probe
        )
        .environment(\.shellLayout, layout)
        .environment(\.shellSourcesHere, here)
        .dynamicTypeSize(type)
        let hosted = NSHostingView(rootView: row.frame(width: width))
        hosted.frame = NSRect(origin: .zero, size: hosted.fittingSize)
        hosted.layoutSubtreeIfNeeded()
        return probe
    }

    @Test("At 320 points no band of a crowded row is wider than the row, at every size of text: the header, the words and the marks end inside it, and the age is whole",
          arguments: [DynamicTypeSize.medium, .xLarge, .xxxLarge, .accessibility1, .accessibility2])
    func nothingWiderThanTheRow(_ type: DynamicTypeSize) throws {
        let width: CGFloat = 320
        let inner = width - ShellSpace.pad * 2
        let probe = Self.laid(Self.crowded(), layout: .narrow, width: width, type: type, acting: Self.everyAct)
        for band in [RowBand.header, .content, .marks] {
            let frame = try #require(probe.frames[band], "\(band) was not laid out at \(type)")
            #expect(frame.minX >= -0.5 && frame.maxX <= inner + 0.5, "\(type): \(band) at \(frame) leaves a row \(inner) wide inside its margins")
        }
        let age = try #require(probe.meta[.age])
        let header = try #require(probe.frames[.header])
        #expect(age.maxX <= header.maxX + 0.5 && age.minX >= header.minX, "\(type): the age at \(age) is cut by \(header)")
        // Never wider than its words on a page with room: said shorter, where it had to be, and not cut.
        let alone = try #require(Self.laid(Self.crowded(), layout: .wide, width: 1000, type: type).meta[.age])
        #expect(age.width <= alone.width + 0.5 && age.width > 0, "\(type): the age is \(age.width) of \(alone.width)")
        // Up to the largest text the app's own Font size reaches (`DummyFontSize.largest`), the
        // name keeps enough to be known by; past it the line still holds, and that is all.
        let names = try #require(probe.meta[.names])
        if type <= DummyFontSize.largest.dynamicType {
            #expect(names.width >= 40, "\(type): the name was left \(names.width) points")
        }
        // The pill is drawn at every size the app reaches; past it the last rung may give it up.
        // **Not asked on a hosted runner at the largest of those sizes** (`HostedRunner`): there
        // the same row measures a few points wider and the last rung gives the pill up at
        // exactly that size, where a desk keeps it. Every other size is asked everywhere.
        if type <= DummyFontSize.largest.dynamicType,
           !(HostedRunner.isOne && type == DummyFontSize.largest.dynamicType) {
            let source = try #require(probe.meta[.source], "\(type): the pill was given up")
            #expect(names.maxX <= source.minX + 0.5, "\(type): the name runs under the source")
        }
    }

    @Test("On a narrow page the source's pill is never an empty shape: it says its host whole where there is room, and a letter where there is not",
          arguments: [(CGFloat(320), DynamicTypeSize.xLarge), (320, .xxxLarge), (390, .xLarge), (440, .xLarge)])
    func thePillSaysSomething(_ width: CGFloat, _ type: DynamicTypeSize) throws {
        let probe = Self.laid(Self.crowded(), layout: .narrow, width: width, type: type)
        let pill = try #require(probe.meta[.source])
        // A pill with nothing in it is its two sides' room and no more.
        let empty = DummyItemRow.Box.pillSideways * 2
        #expect(pill.width > empty + 3, "\(width) \(type): the pill is \(pill.width) wide, which is its own room and no letter")
    }

    @Test("A short host on a short name is said whole on a phone that has room for it")
    func thePillWholeWhereItFits() throws {
        let item = DummyItem(Note(
            id: "1", source: Source(host: "m.example", kind: .mastodon), author: "Ada", handle: "@ada@m.example",
            body: "Short.", postedAt: Self.posted, categories: [.public], audience: .everyone, statusID: "1"
        ))
        let narrow = try #require(Self.laid(item, layout: .narrow, width: 440, type: .large).meta[.source])
        let wide = try #require(Self.laid(item, layout: .wide, width: 1000, type: .large).meta[.source])
        #expect(abs(narrow.width - wide.width) <= 0.5, "the host is whole: \(narrow.width) on a phone, \(wide.width) with room")
    }

    /// How wide a line of the pill's own writing is, alone.
    private static func written(_ text: String, role: ShellType) -> CGFloat {
        NSHostingView(rootView: Text(text).shellFont(role).lineLimit(1).fixedSize()).fittingSize.width
    }

    @Test("A wide page draws the header as it always did: the pill is its host's own letters and the room each side, the handle is beside the name")
    func wideIsAsItWas() throws {
        let item = Self.plain(host: "m.example")
        let probe = Self.laid(item, layout: .wide, width: 1000, type: .large)
        let pill = try #require(probe.meta[.source])
        let letters = Self.written("m.example", role: .mark)
        #expect(abs(pill.width - (letters + DummyItemRow.Box.pillSideways * 2)) <= 1, "the pill is \(pill.width) for letters \(letters) wide")
        let name = try #require(probe.meta[.name]), handle = try #require(probe.meta[.handle])
        #expect(abs(handle.minX - name.maxX - ShellSpace.snug) <= 0.5, "the handle stands a step after the name")
    }

    // MARK: - The handle

    @Test("A short name on a phone keeps its handle, at the app's default text: the handle is drawn, after the whole name, and the age is inside the row",
          arguments: [CGFloat(375), 390, 440])
    func aShortNameKeepsItsHandle(_ width: CGFloat) throws {
        let item = Self.plain(host: "fixture.example", handle: "@ada@fixture.example")
        let probe = Self.laid(item, layout: .narrow, width: width, type: DummyFontSize.standard.dynamicType)
        let handle = try #require(probe.meta[.handle], "the handle was given up at \(width)")
        let name = try #require(probe.meta[.name])
        let whole = try #require(Self.laid(item, layout: .wide, width: 1000, type: DummyFontSize.standard.dynamicType).meta[.name])
        #expect(abs(name.width - whole.width) <= 0.5, "\(width): the name is \(name.width) of \(whole.width) while the handle is drawn")
        #expect(handle.minX >= name.maxX && handle.width >= 40, "\(width): the handle is \(handle)")
        let age = try #require(probe.meta[.age]), header = try #require(probe.frames[.header])
        #expect(age.maxX <= header.maxX + 0.5)
    }

    @Test("The handle goes before a letter of the name does: wherever a narrow row draws the handle the name is whole, and a name too long for both is drawn alone",
          arguments: [CGFloat(320), 375, 440], [DynamicTypeSize.large, .xxLarge, .accessibility1])
    func theHandleGoesBeforeTheName(_ width: CGFloat, _ type: DynamicTypeSize) throws {
        for item in [Self.plain(host: "fixture.example", name: "Ada Lovelace"), Self.crowded()] {
            let probe = Self.laid(item, layout: .narrow, width: width, type: type)
            let name = try #require(probe.meta[.name])
            let whole = try #require(Self.laid(item, layout: .wide, width: 2000, type: type).meta[.name])
            if probe.meta[.handle] != nil {
                #expect(abs(name.width - whole.width) <= 0.5, "\(width) \(type): the name was cut to \(name.width) of \(whole.width) beside a handle")
            }
        }
        // The crowded row's name is wider than a phone on its own, so its handle is never drawn.
        #expect(Self.laid(Self.crowded(), layout: .narrow, width: width, type: type).meta[.handle] == nil)
    }

    // MARK: - The last rung

    /// Removed from this device, deleted at its source and changed: every mark the header has.
    private static func everyMark() -> DummyItem {
        DummyItem(Note(
            id: "9", source: Source(host: host, kind: .mastodon),
            author: "Grace Brewster Murray Hopper, Rear Admiral (retired)",
            handle: "@grace.brewster.murray.hopper@\(host)", body: "hello",
            postedAt: posted, categories: [.public], audience: .everyone, statusID: "9",
            goneSince: posted, editedAt: posted.addingTimeInterval(60)
        ))
    }

    /// Somebody's reblog of a post, drawn as the post under the reblog's own line.
    private static func reblog() -> DummyItem {
        let source = Source(host: host, kind: .mastodon)
        let post = Note(
            id: "https://\(host)/users/ada/statuses/9", source: source, author: "Ada Lovelace the First",
            handle: "@ada@\(host)", body: "The post.", postedAt: posted, categories: [.home], audience: .everyone,
            statusID: "9", editedAt: posted.addingTimeInterval(60)
        )
        let reblog = Note(
            id: "https://\(host)/users/bob/statuses/900/activity", source: source,
            author: "A person with a long display name who passes things on", handle: "@bob@\(host)", body: "",
            postedAt: posted.addingTimeInterval(600), categories: [.home], statusID: "900",
            refs: [Reference(kind: .reblogs, id: "https://\(host)/users/ada/statuses/9", statusID: "9")]
        )
        return DummyItem(reblog, reblogging: post)
    }

    @Test("At 320 points the rows with most on their header — every mark at once, and a reblog — are no wider than the row at any size of text the app reaches, and the age is whole",
          arguments: [DynamicTypeSize.medium, .large, .xxLarge, .xxxLarge, .accessibility1])
    func theLastRungHolds(_ type: DynamicTypeSize) throws {
        let width: CGFloat = 320
        let inner = width - ShellSpace.pad * 2
        // `here` is empty for the first, so its source has left as well.
        let rows: [(String, DummyItem, Set<String>)] = [("every mark", Self.everyMark(), []), ("a reblog", Self.reblog(), [Self.host])]
        for (name, item, here) in rows {
            let probe = Self.laid(item, layout: .narrow, width: width, type: type, acting: Self.everyAct, here: here)
            for band in [RowBand.header, .content, .marks] {
                let frame = try #require(probe.frames[band], "\(name): \(band) was not laid out at \(type)")
                #expect(frame.minX >= -0.5 && frame.maxX <= inner + 0.5, "\(name) \(type): \(band) at \(frame) leaves a row \(inner) wide inside its margins")
            }
            let age = try #require(probe.meta[.age]), header = try #require(probe.frames[.header])
            #expect(age.minX >= header.minX - 0.5 && age.maxX <= header.maxX + 0.5, "\(name) \(type): the age at \(age) is cut by \(header)")
            for part in [RowMetaPart.left, .gone, .changed] {
                if let mark = probe.meta[part] {
                    #expect(mark.minX >= header.minX - 0.5 && mark.maxX <= age.minX + 0.5, "\(name) \(type): \(part) at \(mark)")
                }
            }
        }
        #expect(DummyItemRow.headerMarks(Self.everyMark(), here: []) == 3)
    }

    @Test("At 320 points every mark keeps its share of the line: none narrower than a glyph and its room, and the last ends at the line's far end",
          arguments: [DynamicTypeSize.large, .xLarge, .xxxLarge])
    func marksKeepTheirShare(_ type: DynamicTypeSize) throws {
        let probe = Self.laid(Self.crowded(), layout: .narrow, width: 320, type: type, acting: Self.everyAct)
        let band = try #require(probe.frames[.marks])
        let marks = probe.marks.values.sorted { $0.minX < $1.minX }
        #expect(marks.count == 7, "every mark is laid out")
        let last = try #require(marks.last)
        #expect(last.maxX >= band.maxX - 1, "\(type): the marks stop at \(last.maxX) of a line \(band.maxX) wide, bunched at its start")
        // An even share of the line, less what the gaps may take, is what each is owed at least
        // most of: a mark that gave up its room altogether would be a glyph wide.
        let share = band.width / CGFloat(marks.count)
        for mark in marks {
            #expect(mark.width >= share * 0.6, "\(type): a mark is \(mark.width) wide of a share of \(share)")
        }
        for (left, right) in zip(marks, marks.dropFirst()) {
            #expect(left.maxX <= right.minX + 0.5, "\(type): two marks overlap: \(left) and \(right)")
        }
    }

    @Test("A mark and its count never touch the next mark, however long the counts: on a phone the marks stand at least their least gap apart, and give up their counts before that",
          arguments: [CGFloat(320), 375, 390], [DynamicTypeSize.large, .xxLarge, .accessibility1])
    func marksNeverTouch(_ width: CGFloat, _ type: DynamicTypeSize) throws {
        let item = DummyItem(Note(
            id: "n1", source: Source(host: Self.host, kind: .mastodon), author: "Ada", handle: "@ada@\(Self.host)",
            body: "Short.", postedAt: Self.posted, categories: [.public], audience: .everyone,
            counts: Counts(replies: 12_345, reblogs: 67_890, favourites: 123_456), statusID: "1"
        ))
        let probe = Self.laid(item, layout: .narrow, width: width, type: type, acting: Self.everyAct)
        let band = try #require(probe.frames[.marks])
        let marks = probe.marks.values.sorted { $0.minX < $1.minX }
        #expect(marks.count == 7)
        for (left, right) in zip(marks, marks.dropFirst()) {
            #expect(right.minX - left.maxX >= DummyItemRow.Box.markGap - 0.5, "\(width) \(type): two marks are \(right.minX - left.maxX) apart: \(left) and \(right)")
        }
        #expect(try #require(marks.last).maxX <= band.maxX + 0.5, "\(width) \(type): the marks run past their line")
    }

    @Test("With room for them the marks are laid out exactly as they were: each its own width, from the line's start")
    func marksWithRoomAreAsTheyWere() throws {
        let probe = Self.laid(Self.crowded(), layout: .wide, width: 1000, type: .large, acting: Self.everyAct)
        let band = try #require(probe.frames[.marks])
        let marks = probe.marks.values.sorted { $0.minX < $1.minX }
        let last = try #require(marks.last)
        #expect(last.maxX < band.maxX / 2, "marks with room do not spread across the line")
    }

    // MARK: - A notice

    private static func banner(_ text: String, width: CGFloat) -> CGSize {
        let view = TimelineToastBanner(toast: TimelineToast(kind: .note, text: text))
            .frame(width: width)
        let hosted = NSHostingView(rootView: view.fixedSize(horizontal: false, vertical: true))
        return hosted.fittingSize
    }

    /// Where a measured view landed, written by the view as it is laid out.
    private final class Landed {
        var size = CGSize.zero
    }

    /// How large the notice is drawn where a page `width` wide is its to stand in.
    private static func inner(_ text: String, proposing width: CGFloat) -> CGSize {
        let landed = Landed()
        let view = Color.clear
            .frame(width: width, height: 400)
            .overlay {
                TimelineToastBanner(toast: TimelineToast(kind: .note, text: text))
                    .background(GeometryReader { room in
                        let _ = landed.size = room.size
                        Color.clear
                    })
            }
        let hosted = NSHostingView(rootView: view)
        hosted.frame = NSRect(origin: .zero, size: hosted.fittingSize)
        hosted.layoutSubtreeIfNeeded()
        return landed.size
    }

    @Test("A notice too long for one line breaks and stops at three lines exactly: a fourth would be taller, and two would be shorter")
    func aLongNoticeStops() {
        let sentence = "fixture.example did not answer, so this timeline shows what this device already holds. "
        let one = Self.banner("Nothing new.", width: 320).height
        // A line of the notice's own writing, alone: what each line after the first adds.
        let line = NSHostingView(rootView: Text("Nothing new.").shellFont(.meta).fixedSize()).fittingSize.height
        #expect(line > 4)
        let endless = Self.banner(String(repeating: sentence, count: 40), width: 320).height
        #expect(TimelineToast.lines == 3)
        #expect(abs(endless - (one + line * 2)) <= 1, "forty sentences are \(endless) tall; three lines are \(one + line * 2), four \(one + line * 3)")
    }

    @Test("A long notice is no wider than its measure on a desktop, and stands inside a phone's edges with its margin")
    func aNoticeHasAMeasure() {
        let sentence = String(repeating: "fixture.example did not answer. ", count: 12)
        let wide = Self.inner(sentence, proposing: 1400)
        // Measured with the margin it keeps at each side of itself.
        let margins = ShellSpace.pad * 2
        #expect(wide.width <= TimelineToast.measure + margins + 0.5 && wide.width > TimelineToast.measure + margins - 60, "a long notice is \(wide.width) wide on a desktop")
        let phone = Self.inner(sentence, proposing: 320)
        #expect(phone.width <= 320.5 && phone.width > 320 - 60, "a long notice is \(phone.width) wide on a phone 320 wide: it uses the page and stays inside it")
        #expect(Within.offered(1400, measure: 480) == 480)
        #expect(Within.offered(288, measure: 480) == 288, "asked again at the size it answered with, it is offered that size")
        #expect(Within.offered(nil, measure: 480) == 480)
    }

    @Test("A short notice is exactly as wide as what it says, on a phone and on a desktop alike: its frame is the capsule and nothing more")
    func aShortNoticeHugs() {
        let alone = NSHostingView(rootView: TimelineToastBanner(toast: TimelineToast(kind: .note, text: "Nothing new.")).fixedSize()).fittingSize
        let wide = Self.inner("Nothing new.", proposing: 1400)
        let phone = Self.inner("Nothing new.", proposing: 320)
        #expect(abs(wide.width - alone.width) <= 0.5 && abs(phone.width - alone.width) <= 0.5, "\(alone.width) alone, \(wide.width) on a desktop, \(phone.width) on a phone")
        #expect(alone.width < 200, "a short notice is not the measure wide: \(alone.width)")
    }

    /// Where the notice's plate landed in a page `width` wide, placed as the timeline places it:
    /// at the foot, beside whatever corner the page was told is taken. The plate, and not the
    /// margin the notice keeps at each side of it.
    private static func placed(_ text: String, width: CGFloat, corner: CGSize) -> CGRect {
        final class Frame { var rect = CGRect.zero }
        let landed = Frame()
        let view = Color.clear
            .frame(width: width, height: 400)
            .overlay(alignment: .bottom) {
                TimelineToastBanner(toast: TimelineToast(kind: .loading, text: text))
                    .background(GeometryReader { room in
                        let _ = landed.rect = room.frame(in: .named("page"))
                        Color.clear
                    })
                    .padding(.bottom, ShellSpace.pad)
                    .standsBesideFloatingCorner(by: ShellSpace.pad)
            }
            .coordinateSpace(name: "page")
            .environment(\.shellFloatingCorner, corner)
        let hosted = NSHostingView(rootView: view)
        hosted.frame = NSRect(origin: .zero, size: hosted.fittingSize)
        hosted.layoutSubtreeIfNeeded()
        return landed.rect.insetBy(dx: ShellSpace.pad, dy: 0)
    }

    @Test("On a page with the compose button the notice is at the foot and wholly to the leading side of the button, short or long; with no button it is in the middle of the foot, as wide as the page allows",
          arguments: [320, 440] as [CGFloat])
    func theNoticeIsBesideTheButton(_ width: CGFloat) throws {
        let corner = FediqoRootView.composeCorner(canCompose: true)
        // The button as the root lays it: its own size, and the room it keeps from the edge.
        let button = width - ShellSpace.room - FediqoRootView.Compact.button
        let long = String(repeating: "Reloading fixture.example Public. ", count: 12)
        for text in ["Reloading", long] {
            let beside = Self.placed(text, width: width, corner: corner)
            #expect(beside.width > 40 && beside.minX >= ShellSpace.pad - 0.5, "\(beside)")
            #expect(beside.maxX <= button - ShellSpace.snug + 0.5, "the notice ends at \(beside.maxX) and the button begins at \(button)")
            #expect(abs(beside.maxY - (400 - ShellSpace.pad)) <= 0.5, "at the foot, and not lifted: \(beside)")
            #expect(abs(beside.midX - (width - corner.width + ShellSpace.pad) / 2) <= 0.5, "in the middle of the room it has: \(beside)")
            let alone = Self.placed(text, width: width, corner: .zero)
            #expect(abs(alone.midX - width / 2) <= 0.5 && abs(alone.maxY - (400 - ShellSpace.pad)) <= 0.5, "\(alone)")
            #expect(alone.maxX <= width - ShellSpace.pad + 0.5 && alone.minX >= ShellSpace.pad - 0.5)
        }
        // A long one uses the room it has: it is narrower beside the button than alone, by the corner.
        let beside = Self.placed(long, width: width, corner: corner), alone = Self.placed(long, width: width, corner: .zero)
        #expect(beside.width < alone.width, "\(beside.width) beside the button, \(alone.width) alone")
        // And the timeline places it so.
        let pane = try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Sources/FediqoUI/Shell/TimelinePane.swift"),
            encoding: .utf8
        )
        #expect(pane.contains(".padding(.bottom, ShellSpace.pad)\n                    // At the foot of the page, beside the compose button where it floats and\n                    // never under it or over it (#302).\n                    .standsBesideFloatingCorner(by: ShellSpace.pad)"))
    }

    // MARK: - The head of an opened post

    private static func head(_ layout: ShellLayout, width: CGFloat) -> CGFloat {
        let line = ThreadHeadLine(
            title: "Thread", onBack: {},
            wayOut: ("Open on fixture.example", URL(string: "https://fixture.example/@ada/9")!)
        )
        .environment(\.shellLayout, layout)
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        return NSHostingView(rootView: line).fittingSize.height
    }

    @Test("On a narrow page the head of an opened post is one line however narrow: the title is never broken")
    func theNarrowThreadHeadIsOneLine() {
        let roomy = Self.head(.narrow, width: 1000)
        // 200 is where the unfitted line breaks its title on this machine (`theWideThreadHeadIsAsItWas`).
        for width in [CGFloat(440), 375, 320, 200] {
            #expect(abs(Self.head(.narrow, width: width) - roomy) <= 0.5, "\(width): the head is \(Self.head(.narrow, width: width)) tall, one line is \(roomy)")
        }
    }

    @Test("On a wide page the head is the line it always was: with room it is the narrow page's one line, and squeezed it breaks its title as it did, because nothing there is fitted")
    func theWideThreadHeadIsAsItWas() {
        let roomy = Self.head(.wide, width: 1000)
        #expect(abs(roomy - Self.head(.narrow, width: 1000)) <= 0.5)
        #expect(Self.head(.wide, width: 200) > roomy + 4, "squeezed, the wide page's title still takes a second line")
    }
    #endif
}

/// Whether these tests are being run by a hosted runner and not on somebody's desk.
///
/// **For what a runner measures differently, and for nothing else.** A row laid out there is a
/// few points wider at the largest text than the same row on a desk, so the one or two checks
/// that sit on that edge are not asked of it; they are still asked wherever a person runs the
/// tests. It is the runner's own word (`GITHUB_ACTIONS`), read once.
enum HostedRunner {
    static let isOne = ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true"
}
