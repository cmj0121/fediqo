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
