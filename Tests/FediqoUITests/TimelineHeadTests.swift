import FediqoCore
import Foundation
import SwiftUI
import Testing
@testable import FediqoUI
#if os(macOS)
import AppKit
#endif

/// #304: a narrow screen names the one timeline it shows.
///
/// The dots, what the list offers and what is said are functions and are asked directly. The
/// head is then hosted at a phone's width in the narrow arrangement and measured — one name and
/// one line under it, inside the page — and the wide row of names is measured against the row
/// it was. A sheet being raised and a finger's reach on an iPad are not reached from here.
@Suite("A narrow screen names the one timeline it shows", .serialized)
@MainActor
struct TimelineHeadTests {
    init() {
        L10n.language = .english
    }

    // MARK: - The dots

    @Test("At rest exactly one dot is lit and it is the page in front; whatever the row, it is the row of whole places said another way")
    func oneDotIsLitAtRest() throws {
        #expect(TimelineDots.drawn(position: 2, of: 5).map(\.lit) == [0, 0, 1, 0, 0])
        #expect(TimelineDots.drawn(position: 0, of: 1).isEmpty && TimelineDots.drawn(position: 0, of: 0).isEmpty, "one alone has no dots")
        for total in 2 ... 20 {
            for index in 0 ..< total {
                let drawn = TimelineDots.drawn(position: CGFloat(index), of: total)
                let whole = try #require(TimelineDots.dots(position: index, of: total))
                #expect(drawn.count == whole.count, "\(index) of \(total)")
                #expect(drawn.map(\.lit) == (0 ..< whole.count).map { $0 == whole.lit ? 1 : 0 }, "\(index) of \(total): \(drawn.map(\.lit))")
                #expect(drawn.map(\.small) == (0 ..< whole.count).map { whole.fades($0) ? 1 : 0 }, "\(index) of \(total): \(drawn.map(\.small))")
            }
        }
    }

    @Test("While a finger has the page between two, those two dots are lit between them by as much as one is at rest, by the share the finger has gone — and no third dot is lit at all")
    func twoDotsShareTheLight() {
        let near: (CGFloat, CGFloat) -> Bool = { abs($0 - $1) < 0.0001 }
        let toNext = TimelineDots.drawn(position: 2.4, of: 5).map(\.lit)
        #expect(near(toNext[2], 0.6) && near(toNext[3], 0.4) && toNext[0] == 0 && toNext[1] == 0 && toNext[4] == 0, "\(toNext)")
        let toPrevious = TimelineDots.drawn(position: 1.75, of: 5).map(\.lit)
        #expect(near(toPrevious[1], 0.25) && near(toPrevious[2], 0.75) && toPrevious[0] == 0, "\(toPrevious)")
        for total in [2, 5, 7, 8, 20] {
            for step in 0 ... (total - 1) * 20 {
                let lit = TimelineDots.drawn(position: CGFloat(step) / 20, of: total).map(\.lit)
                #expect(near(lit.reduce(0, +), 1), "at \(CGFloat(step) / 20) of \(total) the row is lit \(lit)")
                #expect(lit.filter { $0 > 0 }.count <= 2, "at \(CGFloat(step) / 20) of \(total) the row is lit \(lit)")
            }
        }
        // Past either end is the end: a finger pulling at the first or the last lights nothing new.
        #expect(TimelineDots.drawn(position: -0.4, of: 5).map(\.lit) == [1, 0, 0, 0, 0])
        #expect(TimelineDots.drawn(position: 4.4, of: 5).map(\.lit) == [0, 0, 0, 0, 1])
        // A finger leans the row no further than the one beside, however far it has gone.
        #expect(TimelineDots.leaning(0.4) == 0.4 && TimelineDots.leaning(-0.4) == -0.4)
        #expect(TimelineDots.leaning(3) == 1 && TimelineDots.leaning(-3) == -1)
    }

    @Test("Which way the page went is known as its head is drawn, for this change and not the one before: on, on, and then back")
    func whichWayItWent() {
        let travel = PageTravel()
        #expect(travel.note(0) == 1, "on where nothing says")
        #expect(travel.note(1) == 1)
        #expect(travel.note(2) == 1)
        #expect(travel.note(1) == -1, "back, at the very drawing in which it went back")
        #expect(travel.note(1) == -1, "the same place again says what was said")
        #expect(travel.note(nil) == -1)
        #expect(travel.note(3) == 1)
        #expect(TimelineDots.moves > 0 && TimelineDots.shift > 0)
    }

    @Test("With more timelines than dots, going to the one beside may leave the lit dot where it is: the dots are a window, and it is the window that moved")
    func theWindowMoves() throws {
        let here = try #require(TimelineDots.dots(position: 10, of: 20)), next = try #require(TimelineDots.dots(position: 11, of: 20))
        #expect(here.lit == next.lit, "the lit dot stays in the middle of the window")
        // And so it is all the way between them: the window goes with the page, and the row
        // drawn half-way is the row drawn at either — nothing slides and nothing jumps back.
        #expect(TimelineDots.drawn(position: 10, of: 20) == TimelineDots.drawn(position: 11, of: 20))
        #expect(TimelineDots.drawn(position: 10.5, of: 20) == TimelineDots.drawn(position: 10, of: 20))
        #expect(TimelineDots.drawn(position: 10, of: 20).map(\.lit) == [0, 0, 0, 1, 0, 0, 0])
        // Coming away from the first, the window sets out as the lit dot reaches its middle,
        // and the first dot grows small as there comes to be something before it.
        let leaving = TimelineDots.drawn(position: 3.5, of: 20)
        #expect(leaving.map(\.lit) == [0, 0, 0, 1, 0, 0, 0] && leaving[0].small == 0.5 && leaving[6].small == 1)
        // And near the last the window has stopped: the light goes on from dot to dot.
        let arriving = TimelineDots.drawn(position: 17.5, of: 20)
        #expect(arriving.map(\.lit) == [0, 0, 0, 0, 0.5, 0.5, 0] && arriving[6].small == 0 && arriving[0].small == 1)
        // Toward an end the window stops and the dot goes on.
        let last = try #require(TimelineDots.dots(position: 19, of: 20)), before = try #require(TimelineDots.dots(position: 18, of: 20))
        #expect(last.lit == before.lit + 1 && !last.moreAfter && last.moreBefore)
    }

    @Test("The words on show are the old ones in the drawing in which what they are about has just changed, and the new ones once they are let go")
    func theWordsOnShow() {
        let held = ChangingLine.Held()
        #expect(held.showing("All", about: "all") == "All")
        #expect(held.showing("All of it", about: "all") == "All of it", "the same thing renamed is simply the new words")
        #expect(held.showing("Trends", about: "trends") == "All of it", "changed: still the old words, on their way out")
        held.turn()
        #expect(held.showing("Trends", about: "trends") == "Trends")
    }

    @Test("A page that is one of several is headed by its name and a dot for each; one alone has no such head. Its second line is heard as the line about it, where it has one, and its place")
    func theSharedHead() {
        #expect(PageHead<EmptyView>.drawn(count: 2) && !PageHead<EmptyView>.drawn(count: 1) && !PageHead<EmptyView>.drawn(count: 0))
        #expect(PageHead<EmptyView>.spoken(line: "Rules.", position: 1, of: 5, language: .english) == "Rules. 2 of 5")
        #expect(PageHead<EmptyView>.spoken(line: nil, position: 1, of: 5, key: "tabs.position", language: .english) == "2 of 5")
        #expect(PageHead<EmptyView>.spoken(line: nil, position: 0, of: 5, key: "tabs.position", language: .taiwanese) == "第 1 個，共 5 個")
        #expect(PageHead<EmptyView>.spoken(line: nil, position: 0, of: 1, language: .english) == "")
    }

    @Test("A page's tabs are one head on a narrow page where there is more than one, and a row of them everywhere else; the name lists every tab, the one in front marked")
    func tabsAsAHead() {
        typealias Tabs = ShellTabs<UsagePane.Purpose>
        let all = Array(UsagePane.Purpose.allCases)
        #expect(Tabs.headed(.narrow, count: all.count))
        #expect(!Tabs.headed(.wide, count: all.count), "a wide page keeps the row")
        #expect(!Tabs.headed(.narrow, count: 1), "one tab is no head")
        let listed = Tabs.listed(all, selected: all[1], language: .english)
        #expect(listed.map(\.name) == all.map { L10n.t($0.titleKey, language: .english) })
        #expect(listed.map(\.symbol) == all.map(\.symbol))
        #expect(listed.filter(\.current).map(\.name) == [L10n.t(all[1].titleKey, language: .english)])
        #expect(Set(listed.map(\.id)).count == all.count)
        // Preferences under a finger counts the gestures' page among them.
        #expect(PreferencesPane.Purpose.shown(touch: true).count == PreferencesPane.Purpose.allCases.count + 1)
        for key in ["tabs.list.title", "tabs.list.hint", "tabs.position"] {
            #expect(L10n.t(key, language: .english) != key && L10n.t(key, language: .taiwanese) != L10n.t(key, language: .english), "\(key)")
        }
        #expect(TimelineSwipe.announcement(name: "Time", position: 1, count: 4, key: "tabs.position", language: .english) == "Time, 2 of 4")
        #expect(TimelineSwipe.announcement(name: "時間", position: 1, count: 4, key: "tabs.position", language: .taiwanese) == "時間, 第 2 個，共 4 個")
        // And the page that says the gestures says the name is pressed on a page with tabs too.
        #expect(ShellGesture.name.detail(language: .english).contains("tabs") && ShellGesture.name.detail(language: .taiwanese).contains("分頁"))
    }

    @Test("A dot a timeline up to seven, the one in front lit; one timeline has no dots")
    func dotsUpToTheCap() {
        #expect(TimelineDots.dots(position: 0, of: 1) == nil)
        #expect(TimelineDots.dots(position: 0, of: 0) == nil)
        #expect(TimelineDots.dots(position: 1, of: 4) == TimelineDots(count: 4, lit: 1, moreBefore: false, moreAfter: false))
        #expect(TimelineDots.dots(position: 6, of: 7) == TimelineDots(count: 7, lit: 6, moreBefore: false, moreAfter: false))
        #expect(TimelineDots.dots(position: 4, of: 4) == nil, "a place past the end is no place")
        #expect(TimelineDots.most == 7)
    }

    @Test("Past seven the dots are a window round the one in front, never more than seven, with a small dot at an end that has more beyond it")
    func dotsPastTheCap() throws {
        let start = try #require(TimelineDots.dots(position: 0, of: 20))
        #expect(start == TimelineDots(count: 7, lit: 0, moreBefore: false, moreAfter: true))
        #expect(!start.fades(0) && start.fades(6))
        let middle = try #require(TimelineDots.dots(position: 10, of: 20))
        #expect(middle == TimelineDots(count: 7, lit: 3, moreBefore: true, moreAfter: true))
        #expect(middle.fades(0) && middle.fades(6) && !middle.fades(3))
        let end = try #require(TimelineDots.dots(position: 19, of: 20))
        #expect(end == TimelineDots(count: 7, lit: 6, moreBefore: true, moreAfter: false))
        for position in 0 ..< 20 {
            let dots = try #require(TimelineDots.dots(position: position, of: 20))
            #expect(dots.count == 7 && (0 ..< 7).contains(dots.lit))
        }
    }

    // MARK: - What the list offers

    private let microblog = Source(host: "m.example", kind: .mastodon)

    private func session(timelines names: [String] = [], lost: Bool = false) throws -> ShellSession {
        let session = ShellSession(http: FixtureHTTP([:]), timelines: WrittenTimelineStore(defaults: HeadDefaults()))
        session.sources = [microblog]
        session.rebuildQueries()
        for name in names {
            var draft = TimelineDraft(new: session.written.count + 1)
            draft.name = name
            draft.rules = [try #require(Rule.author("@ada@m.example", in: .every, sources: []))]
            draft.position = session.written.count
            session.commit(draft)
        }
        if lost {
            var draft = TimelineDraft(new: session.written.count + 1)
            draft.name = "Lost"
            draft.rules = [try #require(Rule.source("gone.example"))]
            draft.position = session.written.count
            session.commit(draft)
        }
        session.timelineID = .all
        return session
    }

    @Test("The list offers every timeline in its order with its rules, marks the one in front and the one that lost its source, and offers a new one")
    func whatTheListOffers() throws {
        let session = try session(timelines: ["Ada"], lost: true)
        let list = session.timelineList
        #expect(list.entries.map(\.query) == session.queries)
        #expect(list.entries.map(\.name) == session.queries.map(session.name(of:)))
        #expect(list.entries.map(\.rule) == session.queries.map(session.rule(of:)))
        #expect(list.entries.filter(\.current).map(\.query) == [.all])
        #expect(list.entries.filter(\.missing).map(\.name) == ["Lost"])
        #expect(list.position == 0)
        #expect(list.offersNew)
        #expect(!list.offersEdit, "All is not the person's to change")
    }

    @Test("Changing the timeline in front is offered for one of the person's own and for no other; with no timelines nothing is offered")
    func whenEditIsOffered() throws {
        let session = try session(timelines: ["Ada"])
        let own = try #require(session.queries.last)
        session.goToTimeline(own)
        #expect(session.timelineList.offersEdit)
        #expect(session.timelineList.position == session.queries.count - 1)
        session.goToTimeline(.trends)
        #expect(!session.timelineList.offersEdit)
        let none = TimelineList.offered([], current: .all, name: { _ in "" }, rule: { _ in "" }, missing: { _ in false })
        #expect(!none.offersNew && !none.offersEdit && none.entries.isEmpty && none.position == nil)
    }

    @Test("One function puts a timeline in front, by itself or by its place; one that is not among them, or a place past either end, is refused and moves nothing")
    func goingToATimeline() throws {
        let session = try session(timelines: ["Ada"])
        #expect(session.goToTimeline(.trends) && session.currentTimeline == .trends)
        #expect(session.goToTimeline(at: 0) && session.currentTimeline == .all)
        #expect(session.goToTimeline(at: session.queries.count - 1))
        #expect(session.currentTimeline == session.queries.last)
        #expect(!session.goToTimeline(at: session.queries.count) && !session.goToTimeline(at: -1))
        #expect(!session.goToTimeline(.written(UUID())))
        #expect(session.currentTimeline == session.queries.last, "a refusal moves nothing")
        // Tab goes by the same function, so it wraps as it did.
        #expect(session.rotateTab(by: 1) && session.currentTimeline == .all)
        #expect(session.rotateTab(by: -1) && session.currentTimeline == session.queries.last)
    }

    // MARK: - What is pressed in the list

    @Test("What was pressed in the list is done when the list has gone, on the timeline it was pressed for; nothing where the head is no longer drawn, or the timeline has gone")
    func afterTheListHasGone() {
        let own = TimelineQuery.written(UUID())
        let queries: [TimelineQuery] = [.all, .trends, own]
        #expect(TimelineList.afterDismissal(.new, among: queries, headShown: true) == .new)
        #expect(TimelineList.afterDismissal(.edit(own), among: queries, headShown: true) == .edit(own))
        #expect(TimelineList.afterDismissal(nil, among: queries, headShown: true) == nil, "a row chosen, or the list waved away")
        #expect(TimelineList.afterDismissal(.new, among: queries, headShown: false) == nil, "the person went elsewhere")
        #expect(TimelineList.afterDismissal(.edit(own), among: queries, headShown: false) == nil)
        #expect(TimelineList.afterDismissal(.edit(own), among: [.all, .trends], headShown: true) == nil, "the timeline has gone")
    }

    @Test("Changing a timeline pressed in the list opens the editor on that timeline, though another is in front by the time the list has gone; and it is done once")
    func theEditIsForTheTimelinePressed() throws {
        let session = try session(timelines: ["Ada", "Bob"])
        let ada = session.queries[2], bob = session.queries[3]
        session.goToTimeline(ada)
        session.timelineHeadShown = true
        session.timelineListPressed = .edit(ada)
        session.goToTimeline(bob)
        session.timelineListDismissed()
        #expect(session.currentTimeline == ada, "the timeline pressed for is in front")
        #expect(session.editing?.name == "Ada", "and it is the one being changed: \(session.editing?.name ?? "nothing")")
        #expect(session.timelineListPressed == nil)
        session.editing = nil
        session.timelineListDismissed()
        #expect(session.editing == nil, "a second dismissal does nothing")
        // With the head gone, nothing is raised.
        session.timelineHeadShown = false
        session.timelineListPressed = .new
        session.timelineListDismissed()
        #expect(session.editing == nil && session.timelineListPressed == nil)
    }

    @Test("A press on the name raises the list, but not while an act pressed in it is still to be done or the editor is up")
    func oneSheetAtATime() {
        #expect(TimelineList.raises(pressed: nil, editing: false))
        #expect(!TimelineList.raises(pressed: .new, editing: false))
        #expect(!TimelineList.raises(pressed: nil, editing: true))
    }

    @Test("The notice for a timeline that cannot be changed says where a new one is made: the + on a wide page, the timeline's name on a narrow one")
    func theFixedNotice() throws {
        #expect(TimelineList.fixedNoticeKey(narrow: false) == "timeline.edit.fixed")
        #expect(TimelineList.fixedNoticeKey(narrow: true) == "timeline.edit.fixed.narrow")
        #expect(!L10n.t("timeline.edit.fixed.narrow", language: .english).contains("+"))
        #expect(!L10n.t("timeline.edit.fixed.narrow", language: .taiwanese).contains("+"))
        let session = try session()
        session.timelineHeadShown = true
        session.editCurrentTimeline()
        #expect(session.toast?.text == L10n.t("timeline.edit.fixed.narrow"))
        session.timelineHeadShown = false
        session.editCurrentTimeline()
        #expect(session.toast?.text == L10n.t("timeline.edit.fixed"))
    }

    @Test("Where the timeline in front stands is read without building the list")
    func thePosition() throws {
        let session = try session(timelines: ["Ada"])
        session.goToTimeline(at: 2)
        #expect(session.timelinePosition.index == 2 && session.timelinePosition.count == 3)
    }

    // MARK: - What is said

    @Test("The line under the name is heard as the rules and then the place, in both languages; one timeline says its rules alone")
    func theSecondLineSpoken() {
        typealias Head = TimelineNarrowHead<EmptyView>
        #expect(Head.spoken(rule: "Rules.", position: 1, of: 5, language: .english) == "Rules. 2 of 5")
        #expect(Head.spoken(rule: "規則。", position: 1, of: 5, language: .taiwanese) == "規則。 第 2 條，共 5 條")
        #expect(Head.spoken(rule: "Rules.", position: 0, of: 1, language: .english) == "Rules.")
        #expect(Head.spoken(rule: "Rules.", position: nil, of: 5, language: .english) == "Rules.")
    }

    @Test("The name says that pressing it lists the timelines, and first that a rule is missing where one is")
    func theNameHint() {
        typealias Head = TimelineNarrowHead<EmptyView>
        #expect(Head.hint(missing: false, language: .english) == "Lists every timeline")
        #expect(Head.hint(missing: true, language: .english) == "A rule here is missing. Lists every timeline")
        #expect(Head.hint(missing: false, language: .taiwanese) == "列出每一條時間軸")
        let both = Head.hint(missing: true, language: .taiwanese)
        #expect(both == "這裡有規則已不在。列出每一條時間軸")
        #expect(!both.contains(". "), "no other language's full stop joins the two")
    }

    @Test("Every new word is written in each language the app ships")
    func theWordsAreInBothLanguages() {
        for key in ["timeline.list.title", "timeline.list.hint", "timeline.list.hint.missing", "timeline.position", "timeline.edit.fixed.narrow"] {
            for language in [DummyLanguage.english, .taiwanese] {
                #expect(L10n.t(key, language: language) != key, "\(key) is not written in \(language)")
            }
            #expect(L10n.t(key, language: .english) != L10n.t(key, language: .taiwanese))
        }
    }

    #if os(macOS)
    // MARK: - The head, hosted

    /// Where the head's last mark landed, written as it is laid out.
    private final class Landed {
        var marks = CGRect.zero
    }

    /// The head laid out in `room` points, starting at the page's edge and free to be as wide as
    /// it needs: how tall it came out, and where its trailing marks ended.
    private func head(_ session: ShellSession, room: CGFloat, type: DynamicTypeSize) -> (height: CGFloat, marksEnd: CGFloat) {
        let landed = Landed()
        let view = TimelineNarrowHead(session: session) {
            ShellIconButton("magnifyingglass", name: "shortcut.search", action: {})
            ShellIconButton("arrow.clockwise", name: "shortcut.reload", action: {})
                .background(GeometryReader { place in
                    let _ = landed.marks = place.frame(in: .named("page"))
                    Color.clear
                })
        }
        .dynamicTypeSize(type)
        // Offered the room and not held to it: a head that could not shorten runs past it.
        .frame(minWidth: room, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: room, alignment: .leading)
        .coordinateSpace(.named("page"))
        let hosted = NSHostingView(rootView: view)
        hosted.frame = NSRect(x: 0, y: 0, width: room, height: 400)
        hosted.layoutSubtreeIfNeeded()
        return (hosted.fittingSize.height, landed.marks.maxX)
    }

    @Test("At 320 the narrow head is one name and one line under it, however long the name and the rules, at every size of text: as tall as a short one, with its marks inside the page",
          arguments: [DynamicTypeSize.medium, .xxLarge, .xxxLarge, .accessibility1])
    func theNarrowHeadHolds(_ type: DynamicTypeSize) throws {
        let short = try session(timelines: ["Ada"])
        short.goToTimeline(at: 2)
        let long = try session(timelines: ["A timeline with a rather long name, to see where a long name goes when there is no room for it at all"], lost: true)
        long.goToTimeline(at: 2)
        let inner: CGFloat = 320 - ShellSpace.pad * 2
        let plain = head(short, room: inner, type: type)
        let crowded = head(long, room: inner, type: type)
        #expect(abs(plain.height - crowded.height) <= 0.5, "\(type): a long name made the head \(crowded.height) tall against \(plain.height)")
        #expect(crowded.marksEnd > 0 && crowded.marksEnd <= inner + 0.5, "\(type): the marks end at \(crowded.marksEnd) of a page \(inner) wide")
        // Two lines and no more: the name, and the rules under it.
        let name = NSHostingView(rootView: Text("Ag").shellFont(.name, weight: .semibold).dynamicTypeSize(type).fixedSize()).fittingSize.height
        let rules = NSHostingView(rootView: Text("Ag").shellFont(.meta).dynamicTypeSize(type).fixedSize()).fittingSize.height
        #expect(crowded.height < (name + rules) * 1.6, "\(type): \(crowded.height) is more than a name and a line of rules, \(name) and \(rules)")
        #expect(crowded.height >= name + rules - 1)
    }

    private func pill(_ type: DynamicTypeSize = .large) -> some View {
        ShellTabPill("Ada", symbol: "tray.full", selected: false) {}.dynamicTypeSize(type)
    }

    /// A view offered `room` and free to be wider or taller: how large it came out.
    private func needed(_ view: some View, room: CGFloat) -> CGSize {
        NSHostingView(rootView: view.frame(minWidth: room, alignment: .leading).fixedSize(horizontal: false, vertical: true)).fittingSize
    }

    @Test("The head is the same size while a finger leans its dot: nothing about the head grows or moves, and the row of dots is as wide leaning as at rest")
    func theHeadIsStillDuringASlide() throws {
        let session = try session(timelines: ["Ada", "Bob"])
        session.goToTimeline(at: 2)
        let slide = PageSlide()
        func size() -> CGSize {
            needed(TimelineNarrowHead(session: session, slide: slide) { EmptyView() }, room: 288)
        }
        let rest = size()
        #expect(rest.width <= 288.5)
        for lean in [CGFloat(0.4), -0.4, 1] {
            slide.lean = lean
            #expect(size() == rest, "leaning \(lean), the head is \(size()) against \(rest)")
        }
        // The row alone, short and windowed, read from the left and from the right: one size
        // whatever it shows, since nothing is laid over it and nothing is laid out smaller.
        for (index, total) in [(2, session.queries.count), (0, 2), (10, 20), (1, 20), (18, 20)] {
            slide.lean = 0
            let row = NSHostingView(rootView: TimelineDotsRow(index: index, total: total)).fittingSize
            #expect(row.width > 0 && row.height > 0)
            for lean in [CGFloat(0), 0.25, 0.5, -0.5, 1, -1, 3] {
                slide.lean = lean
                #expect(NSHostingView(rootView: TimelineDotsRow(index: index, total: total, slide: slide)).fittingSize == row, "\(index) of \(total), leaning \(lean)")
                let mirrored = TimelineDotsRow(index: index, total: total, slide: slide).environment(\.layoutDirection, .rightToLeft)
                #expect(NSHostingView(rootView: mirrored).fittingSize == row, "\(index) of \(total), leaning \(lean), read from the right")
            }
        }
        // And a dot more makes it wider: the size is the row's own, not a frame's.
        #expect(NSHostingView(rootView: TimelineDotsRow(index: 0, total: 3)).fittingSize.width > NSHostingView(rootView: TimelineDotsRow(index: 0, total: 2)).fittingSize.width)
    }

    private struct PaneHost: View {
        let session: ShellSession
        let layout: ShellLayout
        let probe: PaneProbe
        @State private var selected: String?
        @State private var decks = ShellDecks()
        @State private var playback = ShellPlayback()
        @State private var prefs = DummyPrefs(defaults: HeadDefaults())

        var body: some View {
            TimelinePane(
                session: session, selectedID: $selected, standing: nil, onOpenPerson: { _ in },
                decks: $decks, playback: playback, onPlayRow: { _ in }, onViewRow: { _ in },
                onTurnRow: { _ in }, onOpenThread: { _ in }, jumpToTop: 0, onBack: {},
                ways: TimelineWays(canSearch: true, onSearch: {}, canReload: true, onReload: {}),
                search: ShellSearch()
            )
            .environment(prefs)
            .environment(\.shellLayout, layout)
            .environment(\.shellSlides, true)
            .environment(\.shellPaneProbe, probe)
        }
    }

    @Test("In the pane itself, a slide moves what is under the head and leaves the head exactly where it was — before, during and after — on a narrow page and on a wide one",
          arguments: [ShellLayout.narrow, .wide])
    func thePaneSlidesUnderItsHead(_ layout: ShellLayout) async throws {
        let session = try session(timelines: ["Ada"])
        session.notes = [Note(
            id: "1", source: microblog, author: "Ada", handle: "@ada@m.example", body: "Words.",
            postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: [.public]
        )]
        let probe = PaneProbe()
        let hosted = NSHostingView(rootView: PaneHost(session: session, layout: layout, probe: probe))
        hosted.frame = NSRect(x: 0, y: 0, width: layout == .narrow ? 390 : 900, height: 600)
        func settle() async {
            for _ in 0 ..< 3 {
                turn(hosted)
                await Task.yield()
            }
        }
        await settle()
        let head = probe.head, under = probe.under
        #expect(head.height > 0 && under.height > 0, "both were laid out: \(head), \(under)")
        session.slide("timeline").x = -120
        await settle()
        #expect(probe.head == head, "\(layout): the head moved to \(probe.head) from \(head)")
        #expect(abs(probe.under.minX - (under.minX - 120)) <= 0.5, "\(layout): what is under it is at \(probe.under.minX), slid from \(under.minX)")
        session.slide("timeline").x = 0
        await settle()
        #expect(probe.head == head && abs(probe.under.minX - under.minX) <= 0.5)
    }

    private func turn(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(mode: .default, before: .distantPast)
    }

    /// The pages with tabs, by the name their slide is kept under.
    enum TabbedPage: String, CaseIterable, Sendable {
        case usage, preferences, account, editor

        /// Whether the page is a list its tabs were a row of.
        var listed: Bool { self == .usage || self == .preferences }
    }

    private struct TabbedHost: View {
        let page: TabbedPage
        let session: ShellSession
        let layout: ShellLayout
        let probe: PaneProbe
        @State private var prefs = DummyPrefs(defaults: HeadDefaults())

        var body: some View {
            Group {
                switch page {
                case .usage: UsagePane()
                case .preferences: PreferencesPane()
                case .account: AccountPane(session: session)
                case .editor: TimelineEditor(session: session, draft: TimelineDraft(new: 1))
                }
            }
            .environment(prefs)
            .environment(session)
            .environment(\.shellLayout, layout)
            .environment(\.shellSlides, true)
            .environment(\.shellPaneProbe, probe)
        }
    }

    @Test("On a narrow page every page with tabs has a head that a slide leaves exactly where it was, and what is under the head is what moves",
          arguments: TabbedPage.allCases)
    func aTabbedPageSlidesUnderItsHead(_ page: TabbedPage) async throws {
        let session = try session()
        let probe = PaneProbe()
        let hosted = NSHostingView(rootView: TabbedHost(page: page, session: session, layout: .narrow, probe: probe))
        hosted.frame = NSRect(x: 0, y: 0, width: 390, height: 700)
        func settle() async {
            for _ in 0 ..< 3 {
                turn(hosted)
                await Task.yield()
            }
        }
        await settle()
        let head = probe.head, under = probe.under
        #expect(head.height > 0 && under.height > 0, "\(page): both were laid out: \(head), \(under)")
        session.slide(page.rawValue).x = -120
        await settle()
        #expect(probe.head == head, "\(page): the head moved to \(probe.head) from \(head)")
        #expect(abs(probe.under.minX - (under.minX - 120)) <= 0.5, "\(page): what is under it is at \(probe.under.minX), slid from \(under.minX)")
        session.slide(page.rawValue).x = 0
        await settle()
        #expect(probe.head == head && abs(probe.under.minX - under.minX) <= 0.5, "\(page)")
    }

    @Test("On a wide page a list's tabs are a row in the list as they were, and no head stands over it",
          arguments: [TabbedPage.usage, .preferences])
    func aWideListKeepsItsRow(_ page: TabbedPage) async throws {
        let session = try session()
        let probe = PaneProbe()
        let hosted = NSHostingView(rootView: TabbedHost(page: page, session: session, layout: .wide, probe: probe))
        hosted.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        for _ in 0 ..< 3 {
            turn(hosted)
            await Task.yield()
        }
        #expect(probe.under.height > 0, "\(page): the list was laid out")
        #expect(probe.head == .zero, "\(page): a head stands over the list at \(probe.head)")
        // The row is in the list exactly where the head is not over it: one or the other.
        let shell = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FediqoUI/Shell")
        let file = page == .usage ? "UsagePane.swift" : "PreferencesPane.swift"
        let pane = try String(contentsOf: shell.appendingPathComponent(file), encoding: .utf8)
        #expect(pane.contains("if !headed { Section { tabs } }"), "\(file)")
        #expect(pane.contains(".modifier(TabsOverForm(headed: headed, slide: slide) { tabs })"), "\(file)")
    }

    @Test("A sheet on a phone is as narrow as the phone, by the rule its page goes by; anywhere else it keeps the arrangement it was handed")
    func aSheetIsArranged() {
        #expect(ShellSheetArranged.layout(phoneIsCompact: true, handed: .wide) == .narrow)
        #expect(ShellSheetArranged.layout(phoneIsCompact: false, handed: .narrow) == .wide, "a phone on its side")
        #expect(ShellSheetArranged.layout(phoneIsCompact: nil, handed: .wide) == .wide)
        #expect(ShellSheetArranged.layout(phoneIsCompact: nil, handed: .narrow) == .narrow)
    }

    @Test("At 288 points every tabbed page's head is one name and a row of dots, at every size of text: no wider than it is given, and no taller than a name and a line",
          arguments: [DynamicTypeSize.medium, .xxLarge, .xxxLarge, .accessibility1])
    func theTabsHeadHolds(_ type: DynamicTypeSize) {
        let name = NSHostingView(rootView: Text("Ag").shellFont(.name, weight: .semibold).dynamicTypeSize(type).fixedSize()).fittingSize.height
        func head<Tab: ShellTab>(_ tabs: [Tab], _ selected: Tab, layout: ShellLayout) -> CGSize {
            needed(ShellTabs(tabs, selected: selected) { _ in }.environment(\.shellLayout, layout).dynamicTypeSize(type), room: 288)
        }
        var sizes: [(String, CGSize)] = []
        let usage = Array(UsagePane.Purpose.allCases), prefs = PreferencesPane.Purpose.shown(touch: true)
        let account = Array(AccountPane.Purpose.allCases), editor = Array(EditorTab.allCases)
        sizes.append(("usage", head(usage, usage[usage.count - 1], layout: .narrow)))
        sizes.append(("preferences", head(prefs, prefs[prefs.count - 1], layout: .narrow)))
        sizes.append(("account", head(account, account[0], layout: .narrow)))
        sizes.append(("editor", head(editor, editor[0], layout: .narrow)))
        for (page, size) in sizes {
            #expect(size.width <= 288.5, "\(type) \(page): the head is \(size.width) wide")
            #expect(size.height >= name && size.height < name * 2.6, "\(type) \(page): the head is \(size.height) tall, a name is \(name)")
        }
        #expect(Set(sizes.map { ($0.1.height * 2).rounded() / 2 }).count == 1, "\(type): every page's head is one height: \(sizes.map(\.1.height))")
        // And a wide page's row of tabs is the row: a pill tall, not a head.
        let pill = NSHostingView(rootView: ShellTabPill("Ag", symbol: "clock", selected: false) {}.dynamicTypeSize(type)).fittingSize.height
        // The row holds a hair's room above and below its pills.
        let row = head(usage, usage[0], layout: .wide).height
        #expect(row >= pill && row <= pill + 4, "\(type): the wide row is \(row), a pill \(pill)")
        #expect(abs(sizes[0].1.height - row) > 1.5, "\(type): and the narrow head is not that row")
    }

    /// **Measured with the reach given**, which on a Mac it never is: the modifiers are told to
    /// apply, so what they do to the row's height is asked here rather than on a phone.
    @Test("A finger's reach on the names adds nothing to what is drawn: a pill with it is the pill's size, and the row that scrolls them is as high as it was")
    func theReachAddsNoHeight() {
        let alone = NSHostingView(rootView: pill()).fittingSize
        let reached = NSHostingView(rootView: pill().modifier(FingerTall(applies: true))).fittingSize
        #expect(alone == reached, "the pill is \(reached) with a reach where it was \(alone)")
        let row = NSHostingView(rootView: HStack { pill() }).fittingSize
        let roomy = NSHostingView(rootView: HStack { pill().modifier(FingerTall(applies: true)) }
            .modifier(FingerRoom(applies: true)).modifier(FingerRoom(given: false, applies: true))).fittingSize
        #expect(row == roomy, "the row is \(roomy) with room for the reach where it was \(row)")
        // And the room is really given inside: without taking it back the row is taller.
        let given = NSHostingView(rootView: HStack { pill() }.modifier(FingerRoom(applies: true))).fittingSize
        #expect(given.height == row.height + FingerTall.reach * 2)
        #expect(!FingerTall.onThisDevice, "a Mac draws and reaches as it did")
    }

    /// **Three points short at the smallest text, and that is measured and kept**: a longer
    /// reach moved the names on an iPad (`FingerTall.drawn`).
    @Test("A name in the row and its reach are a finger tall together at the app's default text and above; at the smallest they are within three points of it; the reach is upright only")
    func aFingerTall() {
        for size in [DummyFontSize.standard, .larger, .largest] {
            let drawn = NSHostingView(rootView: pill(size.dynamicType)).fittingSize.height
            #expect(drawn + FingerTall.reach * 2 >= ShellTouchFloor.finger, "\(size): a pill \(drawn) tall reaches \(drawn + FingerTall.reach * 2)")
        }
        let least = NSHostingView(rootView: pill(DummyFontSize.smallest.dynamicType)).fittingSize.height
        #expect(least + FingerTall.reach * 2 >= ShellTouchFloor.finger - 3, "the smallest pill, \(least) tall, reaches \(least + FingerTall.reach * 2)")
        let reached = Reached(reach: FingerTall.reach).path(in: CGRect(x: 0, y: 0, width: 50, height: 20)).boundingRect
        #expect(reached == CGRect(x: 0, y: -FingerTall.reach, width: 50, height: 20 + FingerTall.reach * 2))
    }
    #endif
}

/// Preferences that are nobody's: a session made here must not read or write the person's own.
private final class HeadDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]

    init() {
        super.init(suiteName: nil)!
    }

    override func object(forKey key: String) -> Any? { values[key] }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values[key] = nil }
}
