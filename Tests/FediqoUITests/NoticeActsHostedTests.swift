#if os(macOS)
import AppKit
import FediqoCore
import SwiftUI
import Testing
@testable import FediqoUI

/// #323 — what the notices page offers to do, as it is drawn: the press that asks a source for
/// notices and the question it raises, each menu behind three dots with what it offers and
/// why it does not, what a source holds back, and 320 points across.
///
/// **What this reaches.** The page the root draws, hosted in an `NSHostingView` over a session
/// whose sources answer from a fixture, each part reporting where it was laid out and what it
/// says; and each menu as the value the page builds it from, pressed as the menu presses it.
///
/// **What it does not reach.** No window is made, so no menu is opened and no sheet is put:
/// the question is read as the words the sheet would draw. Light and dark, a finger's long
/// press and VoiceOver itself are for a person on a running app.
@Suite("The notices page's acts, hosted", .serialized)
@MainActor
struct NoticeActsHostedTests {
    private typealias F = NoticeActFixture
    private static let a = F.a
    private static let b = F.b
    private static let long = "a-rather-long-instance-name.example"
    private static let policy = "/api/v2/notifications/policy"
    private static let requests = "/api/v1/notifications/requests"

    @MainActor
    private final class Root {
        let mark = ShellReadingMark()
        let prefs = DummyPrefs(defaults: UserDefaults(suiteName: "fediqo.test.noticeacts.\(UUID().uuidString)")!)
    }

    private struct Host: View {
        let session: ShellSession
        let root: Root
        @State private var selected: String?

        var body: some View {
            NoticesPane(
                session: session, selectedID: $selected, mark: root.mark,
                canReload: !ShellNoticeList.asked(in: session).isEmpty, onReload: {}, onOpen: { _ in },
                onOpenPerson: { _, _ in }
            )
            .environment(root.prefs)
        }
    }

    private static func settle(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        view.layoutSubtreeIfNeeded()
    }

    /// The page hosted `width` across, with what it drew. Hosted afresh for each look: a probe
    /// keeps what a part last reported, so a part since gone is told only by a new one.
    private func hosted(
        _ session: ShellSession, width: CGFloat = 600, layout: ShellLayout = .wide, type: DynamicTypeSize = .large,
        opening: Bool = false
    ) -> (NSView, NoticesProbe) {
        let probe = NoticesProbe()
        let view = NSHostingView(
            rootView: Host(session: session, root: Root())
                .environment(\.shellNoticesProbe, probe)
                .environment(\.shellLayout, layout)
                .environment(\.shellPlaceIsActive, opening)
                .dynamicTypeSize(type)
        )
        view.frame = NSRect(x: 0, y: 0, width: width, height: 900)
        for _ in 0..<3 { Self.settle(view) }
        return (view, probe)
    }

    private func rows(_ probe: NoticesProbe) -> [String] {
        probe.frames.compactMap { part, frame -> (String, CGFloat)? in
            if case .row(let id) = part { (id, frame.minY) } else { nil }
        }.sorted { $0.1 < $1.1 }.map(\.0)
    }

    private static func ideal(_ view: some View, _ type: DynamicTypeSize = .large) -> CGSize {
        NSHostingView(rootView: view.fixedSize().dynamicTypeSize(type)).fittingSize
    }

    /// How tall words stand when they are wrapped to `width` and nothing is cut.
    private static func wrapped(_ text: some View, width: CGFloat, _ type: DynamicTypeSize) -> CGFloat {
        NSHostingView(
            rootView: text.fixedSize(horizontal: false, vertical: true).frame(width: width).dynamicTypeSize(type)
        ).fittingSize.height
    }

    private static func box(_ type: DynamicTypeSize = .large) -> CGSize {
        ideal(Image(systemName: ShellMore.symbol).modifier(ShellGlyphBox()), type)
    }

    /// How far a frame may differ from the size asked for and still be whole: a box scaled
    /// with the text has a side that is no whole point, and a hosted view with no screen lays
    /// out to whole points. A part that is cut is short by many times this.
    private static let pixel: CGFloat = 1

    /// `a` acts and `b` only reads, each read to its end.
    private func two(
        _ extra: [String: NoticeActServer.Outcome] = [:], a scopes: String = F.acts
    ) async throws -> (ShellSession, NoticeActServer) {
        var routes: [String: NoticeActServer.Outcome] = [
            F.get(Self.a): F.page(F.one(4, by: "Ada", minutes: 2), F.one(3, "follow", by: "Bo", minutes: 9)),
            F.get(Self.b): F.page(F.one(8, "mention", by: "Cy", minutes: 5)),
        ]
        routes.merge(extra) { _, new in new }
        let (session, server, _) = try await F.shell(routes, signedIn: [Self.a: scopes, Self.b: F.reads])
        await session.noticeList.acts.readPage(in: session)
        await session.noticeList.readOn(in: session)
        await session.noticeList.readOn(in: session)
        #expect(session.noticeList.lines.count == 3)
        return (session, server)
    }

    private func line(_ newest: String, of host: String, in session: ShellSession) throws -> Notice {
        try #require(session.noticeList.lines.first { $0.source.host == host && $0.newestID == newest })
    }

    // MARK: - The ask

    @Test("Each source not asked has one press beside its name, on the page with no list and above the list; the press raises a question naming notices and opens nothing")
    func theAskIsOnePress() async throws {
        // Nobody may read notices yet: the page says so and each source has its press.
        let (unasked, quiet, _) = try await F.shell([:], signedIn: [Self.a: F.plain, Self.b: F.plainActing])
        let (_, first) = hosted(unasked, opening: true)
        #expect((first.frames[.notAllowed]?.height ?? 0) > 0)
        for host in [Self.a, Self.b] {
            let press = try #require(first.frames[.linePress("unasked:\(host)")], "\(host) has no press")
            let button = Self.ideal(ShellLinkButton(L10n.t("notices.ask.press")) {})
            #expect(press.width >= button.width - 0.5 && press.height >= button.height - 0.5)
            #expect(first.says[.linePress("unasked:\(host)")] == "Ask \(host) for your notices", "a listener hears a bare Ask")
        }
        #expect(NoticeAskSlot.spoken(Self.a, language: .english) == "Ask a.example for your notices")
        // The same glyph a source's row draws where its sign-in must be asked again: one errand.
        #expect(NoticeAskSlot.symbol == SourceRow.permissionSymbol)

        #expect(unasked.askForNotices(host: Self.b))
        let question = ShellQuestion.notices(host: Self.b, grant: unasked.mastodon.grants[Self.b], language: .english)
        #expect(question.title == "Ask b.example for your notices?")
        #expect(question.line == "Its page asks for what you allowed, and to read and dismiss notices.")
        #expect(question.symbol == "bell" && !question.warns)
        #expect(await quiet.asked.isEmpty, "the question itself asked the source something")
        unasked.cancelNoticeAsk()

        // Beside a list: the unasked source is named above it with the same press.
        let (session, _, _) = try await F.shell(
            [F.get(Self.a): F.page(F.one(4, minutes: 2))], signedIn: [Self.a: F.reads, Self.b: F.plain]
        )
        await session.noticeList.read(in: session)
        let (_, page) = hosted(session)
        let named = try #require(page.frames[.line("unasked:b.example")])
        let press = try #require(page.frames[.linePress("unasked:b.example")])
        let row = try #require(page.frames[.row(rows(page)[0])])
        #expect(press.height > 0 && press.minY >= named.minY - 0.5 && press.maxY <= named.maxY + 0.5)
        #expect(named.maxY <= row.minY + 0.5)

        // Once allowed, the press is gone and the source's lines are read.
        await session.allowNotices(host: Self.b, through: NoticeActPage())
        let (_, after) = hosted(session)
        #expect(after.frames[.linePress("unasked:b.example")] == nil && after.frames[.line("unasked:b.example")] == nil)
        #expect(session.mastodon.notices(host: Self.b) == .allowed)
    }

    @Test("A sign-in that acts and was made before bookmarks is told the page asks for bookmarks too, in #285's words, in each language")
    func theAskNamesBookmarksWhereTheyAreNew() async throws {
        // Acting, and never asked for bookmarks: what #285 asks again for.
        let earlier = "read:statuses read:lists read:accounts read:search write:statuses write:favourites"
        let (session, _, _) = try await F.shell([:], signedIn: [Self.a: earlier, Self.b: F.plainActing])
        #expect(session.mastodon.bookmarks(host: Self.a) == .unasked && session.mastodon.bookmarks(host: Self.b) == .allowed)
        #expect(MastodonOAuth.scopes(writing: true, notices: true).contains(MastodonOAuth.bookmarking), "the page asks for bookmarks")

        let asked = ShellQuestion.notices(host: Self.a, grant: .writing, bookmarks: true, language: .english)
        #expect(asked.line == "Its page asks for what you allowed, and for bookmarks and notices.")
        let help = try #require(asked.help)
        #expect(help.hasPrefix("You signed in to a.example before Fediqo could bookmark."))
        #expect(help.contains("reading, posting, replying, boosting and favouriting — and for bookmarks as well"))
        #expect(help.contains("to read your notifications there, and to dismiss them"))
        #expect(help.contains("the sign-in you have goes on as it is"))
        // #285's own question says the same of bookmarks.
        let bookmarks = try #require(ShellQuestion.bookmarks(host: Self.a, language: .english).help)
        #expect(bookmarks.contains("reading, posting, replying, boosting and favouriting — and for bookmarks as well"))

        // One that holds bookmarks is not told they are new.
        let held = ShellQuestion.notices(host: Self.b, grant: .writing, bookmarks: false, language: .english)
        #expect(held.line == "Its page asks for what you allowed, and to read and dismiss notices.")
        #expect(held != asked)
        // A sign-in that reads is asked for no bookmarks, whatever is handed in.
        #expect(ShellQuestion.notices(host: Self.a, grant: .reading, bookmarks: true, language: .english).line
            == "Its page asks again for what you allowed, and to read notices.")

        for language in [DummyLanguage.english, .taiwanese] {
            let said = ShellQuestion.notices(host: Self.a, grant: .writing, bookmarks: true, language: language)
            #expect(said.line != "notices.ask.actsBookmarks.line" && said.help?.contains(Self.a) == true, "\(language)")
            #expect(ShellQuestion.width(said.line) <= ShellQuestion.lineLength, "\(language): the line is too long for the sheet")
        }
        let chinese = ShellQuestion.notices(host: Self.a, grant: .writing, bookmarks: true, language: .taiwanese)
        #expect(chinese.line.contains("書籤") && chinese.line.contains("通知"))
        #expect(chinese.help?.contains("並加上書籤") == true, "not #285's words for it")
    }

    @Test("An ask that fails is said above the list in the page's own words, and the press stands to ask again")
    func aFailedAskIsSaid() async throws {
        let (session, server, _) = try await F.shell(
            [F.get(Self.a): F.page(F.one(4, minutes: 2))], signedIn: [Self.a: F.reads, Self.b: F.plain]
        )
        await session.noticeList.read(in: session)
        await server.set("POST b.example/api/v1/apps", .status(503))
        await session.allowNotices(host: Self.b, through: NoticeActPage())

        let (_, page) = hosted(session)
        #expect(page.says[.said(Self.b)] == "Notices were not allowed on b.example. Its sign-in works as it did.")
        #expect((page.frames[.said(Self.b)]?.height ?? 0) > 0)
        #expect((page.frames[.linePress("unasked:b.example")]?.height ?? 0) > 0)
    }

    // MARK: - A line's menu

    @Test("A line's three dots offer Dismiss where its sign-in acts, asked first with what goes and that it cannot be undone")
    func aLineOffersDismiss() async throws {
        let (session, _) = try await two()
        let notice = try line("4", of: Self.a, in: session)

        let more = NoticeActs.more(notice, in: session, language: .english)
        #expect(more.head.isEmpty)
        #expect(more.items.map(\.name) == ["Dismiss"])
        let dismiss = try #require(more.items.first)
        #expect(dismiss.isDanger && dismiss.answers && dismiss.symbol == NoticeActs.dismissSymbol)
        #expect(NoticeRow.moreLabel(language: .english) == "More: Dismiss")
        #expect(NoticeActs.spoken(dismiss, of: more, language: .english) == "Dismiss")

        let question = ShellQuestion.dismiss(notice, language: .english)
        #expect(question.title == "Dismiss this notice on a.example?")
        #expect(question.line == "It goes there, and in your other apps. This cannot be undone.")
        #expect(question.warns && question.choices.map(\.label) == ["Dismiss"] && question.cancel == "Cancel")
        let gathered = Notice(
            source: notice.source, handle: .gathered(key: "favourite-9-1"), kind: .favourite, people: notice.people,
            count: 5, post: nil, at: notice.at, newestID: "12", oldestID: "1"
        )
        let many = ShellQuestion.dismiss(gathered, language: .english)
        #expect(many.title == "Dismiss these 5 notices on a.example?")
        #expect(many.line == "They go there, and in your other apps. This cannot be undone.")
        for asked in [question, many] { #expect(ShellQuestion.width(asked.line) <= ShellQuestion.lineLength) }

        // The row draws its three dots whole, after the age.
        let probe = NoticeRowProbe()
        let row = NSHostingView(rootView: NoticeRow(
            notice: notice, menu: NoticeRow.Menu(more: { more }, asks: .constant(nil)), probe: probe
        ).frame(width: 600))
        row.frame = NSRect(origin: .zero, size: row.fittingSize)
        row.layoutSubtreeIfNeeded()
        let dots = try #require(probe.frames[.more]), age = try #require(probe.frames[.age])
        #expect(dots.width >= Self.box().width - Self.pixel && dots.height >= Self.box().height - Self.pixel)
        #expect(dots.minX >= age.maxX - 0.5)
        // And none where the row is given nothing to do.
        let bare = NoticeRowProbe()
        let plain = NSHostingView(rootView: NoticeRow(notice: notice, probe: bare).frame(width: 600))
        plain.frame = NSRect(origin: .zero, size: plain.fittingSize)
        plain.layoutSubtreeIfNeeded()
        #expect(bare.frames[.more] == nil)
    }

    @Test("Choosing Dismiss only puts the question; its yes dismisses, and the row leaves the page only after the source answers. The key asks the same question")
    func dismissIsAskedFirst() async throws {
        let gate = Gate()
        let path = F.post(Self.a, "/api/v1/notifications/4/dismiss")
        let (session, server) = try await two([path: .held(gate, "{}")])
        let acts = session.noticeList.acts
        let notice = try line("4", of: Self.a, in: session)
        let (_, before) = hosted(session)
        #expect(rows(before).count == 3)

        let dismiss = try #require(NoticeActs.more(notice, in: session).items.first)
        dismiss.press { acts.asked = $0 }
        let asked = try #require(acts.asked)
        #expect(asked.question == ShellQuestion.dismiss(notice))
        #expect(await server.posts.isEmpty, "choosing the item dismissed without asking")

        // Any answer but the yes changes nothing.
        asked.answered("cancel")
        #expect(await server.posts.isEmpty)

        asked.answered(ShellQuestion.yes)
        acts.asked = nil
        #expect(await spun { await server.count(path) == 1 })
        let (_, waiting) = hosted(session)
        #expect(rows(waiting).contains(notice.id), "the row left before the source answered")
        // On the wire, the item says it is not to be chosen again just now.
        let busy = try #require(NoticeActs.more(notice, in: session, language: .english).items.first)
        #expect(!busy.answers && busy.title(language: .english) == "Dismiss. Not right now")

        await gate.open()
        #expect(await spun { !session.noticeList.lines.contains { $0.id == notice.id } })
        let (_, after) = hosted(session)
        #expect(rows(after).count == 2 && !rows(after).contains(notice.id))

        // `d` on the lamp's line presses the same item.
        let next = try line("3", of: Self.a, in: session)
        #expect(NoticeActs.askToDismiss(next, in: session))
        #expect(acts.asked?.question == ShellQuestion.dismiss(next))
        acts.asked = nil
        #expect(!NoticeActs.askToDismiss(try line("8", of: Self.b, in: session), in: session))
        #expect(acts.asked == nil, "a line whose sign-in only reads was asked about")
    }

    @Test("Where the sign-in may not dismiss, the line's menu still names Dismiss, dim, and says why at its head and to a listener")
    func aLineSaysWhyItCannotBeDismissed() async throws {
        let (session, server) = try await two()
        let reading = try line("8", of: Self.b, in: session)

        let more = NoticeActs.more(reading, in: session, language: .english)
        #expect(more.head == ["The sign-in on b.example only reads, so it cannot act on notices."])
        let dismiss = try #require(more.items.first)
        #expect(more.items.count == 1 && dismiss.name == "Dismiss" && !dismiss.answers)
        #expect(dismiss.title(language: .english) == "Dismiss", "the reason is said once, at the head")
        #expect(NoticeActs.spoken(dismiss, of: more, language: .english)
            == "Dismiss. The sign-in on b.example only reads, so it cannot act on notices.")
        var put = false
        dismiss.press { _ in put = true }
        #expect(!put && session.noticeList.acts.asked == nil)
        #expect(await server.posts.isEmpty)

        // A sign-in that acts, and was not let to act on notices, is told that instead.
        let partly = F.plainActing + " " + MastodonOAuth.noticing
        let (other, _) = try await two(a: partly)
        #expect(other.mastodon.notices(host: Self.a) == .allowed && !other.mastodon.dismisses(host: Self.a))
        #expect(NoticeActs.why(host: Self.a, in: other, language: .english) == "a.example did not let this sign-in act on notices.")
        #expect(NoticeActs.why(host: Self.a, in: session, language: .english) == nil)
    }

    // MARK: - The head's menu

    @Test("The head's three dots dismiss all, one item a source: live where the sign-in acts, dim and named as left alone where it only reads, and absent where nobody may read notices")
    func theHeadDismissesAllBySource() async throws {
        let clear = F.post(Self.a, "/api/v1/notifications/clear")
        let gate = Gate()
        let (session, server) = try await two([clear: .held(gate, "{}")])
        let acts = session.noticeList.acts

        let more = try #require(NoticeActs.more(in: session, language: .english))
        #expect(more.items.map(\.name) == ["Dismiss all on a.example", "Dismiss all on b.example"])
        #expect(more.head == ["The sign-in on b.example only reads, so it cannot act on notices."])
        #expect(more.items.map(\.answers) == [true, false] && more.items.allSatisfy(\.isDanger))

        let question = ShellQuestion.dismissAll(host: Self.a, language: .english)
        #expect(question.title == "Dismiss every notice on a.example?")
        #expect(question.line == "All of them go there, shown here or not. This cannot be undone.")
        #expect(question.help?.contains("the ones not read on to yet, and the kinds you left out") == true)
        #expect(question.help?.hasSuffix("Every other source is left alone.") == true)
        #expect(question.warns && question.choices.map(\.label) == ["Dismiss all"])
        #expect(ShellQuestion.width(question.line) <= ShellQuestion.lineLength)

        let (_, page) = hosted(session)
        let dots = try #require(page.frames[.moreMark], "the head has no three dots")
        #expect(dots.width >= Self.box().width - Self.pixel && dots.height >= Self.box().height - Self.pixel)
        #expect(rows(page).count == 3)

        more.items[0].press { acts.asked = $0 }
        let asked = try #require(acts.asked)
        #expect(asked.question == ShellQuestion.dismissAll(host: Self.a))
        #expect(await server.posts.isEmpty)
        asked.answered(ShellQuestion.yes)
        acts.asked = nil
        #expect(await spun { await server.count(clear) == 1 })
        #expect(session.noticeList.lines.count == 3, "lines left before the source answered")
        await gate.open()
        #expect(await spun { session.noticeList.lines.count == 1 })
        let (_, after) = hosted(session)
        #expect(rows(after) == [try line("8", of: Self.b, in: session).id], "the source left alone lost its lines")

        // The dim item puts nothing and sends nothing.
        more.items[1].press { acts.asked = $0 }
        #expect(acts.asked == nil)
        #expect(await server.posts == [clear])

        // Nobody may read notices: no head, and no menu.
        let (unasked, _, _) = try await F.shell([:], signedIn: [Self.a: F.plain])
        #expect(NoticeActs.more(in: unasked) == nil)
        let (_, none) = hosted(unasked)
        #expect(none.frames[.moreMark] == nil)
    }

    // MARK: - What a source holds back

    @Test("Where no source holds anything back, or has no such thing, nothing is drawn for it")
    func nothingIsDrawnWhereNothingIsHeld() async throws {
        // a has no policy at all (404); b has one and holds nothing.
        let (session, server) = try await two([F.get(Self.b, Self.policy): F.policy(requests: 0, notices: 0)])
        #expect(session.noticeList.acts.holdings == [Self.a: .absent, Self.b: .holds(NoticesHeld(requests: 0, notices: 0))])

        let (_, page) = hosted(session)
        #expect(rows(page).count == 3)
        #expect(!page.frames.keys.contains { part in
            switch part {
            case .held, .heldWords, .heldPress, .heldReading, .heldPartial, .request, .requestWords, .requestMore, .onWay: true
            default: false
            }
        }, "a held-back line was drawn with nothing held")
        #expect(await server.asked.filter { $0.hasSuffix(Self.requests) }.isEmpty)
    }

    /// `a` holds two people's notices back; its line is not yet opened.
    private func holding(
        _ extra: [String: NoticeActServer.Outcome] = [:], a scopes: String = F.acts
    ) async throws -> (ShellSession, NoticeActServer) {
        var routes: [String: NoticeActServer.Outcome] = [
            F.get(Self.a, Self.policy): F.policy(requests: 2, notices: 4),
            F.get(Self.a, Self.requests): .body("[" + F.request(71, by: "Eve", count: 3) + "," + F.request(72, by: "Flo", count: 1) + "]"),
        ]
        routes.merge(extra) { _, new in new }
        return try await two(routes, a: scopes)
    }

    @Test("A held-back request whose last post its author covered draws and says what it was covered with, and its words are nowhere on the page")
    func aCoveredRequestStaysCoveredOnItsRow() async throws {
        func covering(_ request: String, _ cover: String) -> String {
            request.replacingOccurrences(of: #""content":"#, with: cover + #","content":"#)
        }
        let eve = covering(F.request(71, by: "Eve", count: 3, words: "What was put under the cover"), #""sensitive":true,"spoiler_text":"Spoilers""#)
        let flo = covering(F.request(72, by: "Flo", count: 1, words: "What was put under the cover"), #""sensitive":true,"spoiler_text":"""#)
        let (session, _) = try await holding([F.get(Self.a, Self.requests): .body("[" + eve + "," + flo + "]")])
        let acts = session.noticeList.acts
        await acts.open(host: Self.a, in: session)
        let listed = try #require(acts.requests[Self.a])
        #expect(listed.map { $0.lastPost?.body } == ["What was put under the cover", "What was put under the cover"])

        let (_, page) = hosted(session)
        #expect(page.says[.request(listed[0].id)] == "Eve, 3 notices held: Author's warning: Spoilers")
        #expect(page.says[.request(listed[1].id)] == "Flo, 1 notice held: Covered")
        #expect(!page.says.values.contains { $0.contains("under the cover") }, "a covered post's words are said on the page")
        // The row's third line is the cover's, drawn: as tall as it with the name and the count.
        for (request, shown) in zip(listed, ["Author's warning: Spoilers", "Covered"]) {
            #expect(NoticeActs.excerpt(request, language: .english) == shown)
            let who = try #require(page.frames[.requestWords(request.id)])
            let name = Self.wrapped(Text(NoticeActs.name(request.person)).shellFont(.name), width: who.width, .large)
            let count = Self.wrapped(Text(NoticeActs.count(request)).shellFont(.meta), width: who.width, .large)
            let excerpt = Self.wrapped(Text(shown).shellFont(.body).lineLimit(NoticeRow.excerptLines), width: who.width, .large)
            #expect(who.height >= name + count + excerpt + 2 * ShellSpace.tight - 0.5, "the cover's line is not drawn")
        }
    }

    @Test("A source that holds notices back says how many and from where on a quiet line above the list; opened, it lists who, how many and the last one's words")
    func theHeldBackLineAndItsList() async throws {
        let (session, server) = try await holding()
        let acts = session.noticeList.acts

        let (_, closed) = hosted(session)
        #expect(closed.says[.held(Self.a)] == "a.example is holding back 4 notices.")
        let held = try #require(closed.frames[.held(Self.a)]), first = try #require(closed.frames[.row(rows(closed)[0])])
        #expect(held.height > 0 && held.maxY <= first.minY + 0.5, "it is not above the list")
        #expect(closed.says[.heldPress(Self.a)] == "Show what a.example is holding back")
        #expect((closed.frames[.heldPress(Self.a)]?.height ?? 0) > 0)
        #expect(closed.frames[.held(Self.b)] == nil, "a source with no such thing was given a line")
        #expect(!closed.frames.keys.contains { if case .request = $0 { true } else { false } })
        #expect(await server.count(F.get(Self.a, Self.requests)) == 0, "what is held was read before it was opened")

        await acts.open(host: Self.a, in: session)
        let listed = try #require(acts.requests[Self.a])
        let (_, open) = hosted(session)
        #expect(open.says[.heldPress(Self.a)] == "Hide what a.example is holding back")
        #expect(open.says[.request(listed[0].id)] == "Eve, 3 notices held: Held words")
        #expect(open.says[.request(listed[1].id)] == "Flo, 1 notice held: Held words")
        let eve = try #require(open.frames[.request(listed[0].id)]), flo = try #require(open.frames[.request(listed[1].id)])
        #expect(eve.height > 0 && eve.maxY <= flo.minY + 0.5)
        let top = try #require(open.frames[.row(rows(open)[0])])
        #expect(flo.maxY <= top.minY + 0.5, "the requests stand above the notices")
        for request in listed {
            let dots = try #require(open.frames[.requestMore(request.id)])
            #expect(dots.width >= Self.box().width - Self.pixel && dots.height >= Self.box().height - Self.pixel)
        }
        #expect(rows(open).count == 3, "opening what is held took the notices away")

        acts.close(host: Self.a)
        let (_, again) = hosted(session)
        #expect(again.frames[.request(listed[0].id)] == nil && again.says[.heldPress(Self.a)] == "Show what a.example is holding back")
    }

    @Test("A held-back request offers Let through and Let go, each asked first — letting through says the person's later notices come through too and that Fediqo cannot undo it; let through, it is said to be on its way above the list")
    func aRequestIsLetThroughOrGo() async throws {
        let accept = F.post(Self.a, Self.requests + "/71/accept")
        let go = F.post(Self.a, Self.requests + "/72/dismiss")
        let (session, server) = try await holding([accept: .body("{}"), go: .body("{}")])
        let acts = session.noticeList.acts
        await acts.open(host: Self.a, in: session)
        let listed = try #require(acts.requests[Self.a])

        let more = NoticeActs.more(listed[0], in: session, language: .english)
        #expect(more.head.isEmpty && more.items.map(\.name) == ["Let through", "Let go"])
        #expect(more.items.allSatisfy(\.isDanger) && more.items.allSatisfy(\.answers), "an act went out on one press")
        #expect(more.items.map { NoticeActs.spoken($0, of: more, language: .english) } == ["Let through", "Let go"])
        let question = ShellQuestion.letGo(listed[1], language: .english)
        #expect(question.title == "Let go of @flo@a.example (Flo)'s notices held on a.example?")
        #expect(question.line == "They are dismissed there, unshown. This cannot be undone.")
        #expect(question.warns && question.choices.map(\.label) == ["Let go"])

        // Let through only puts its question: the source also stops holding that person back.
        for language in [DummyLanguage.english, .taiwanese] {
            let through = ShellQuestion.letThrough(listed[0], language: language)
            #expect(through.title.contains("Eve") && through.title.contains(Self.a) && through.help?.contains("Eve") == true)
            #expect(ShellQuestion.width(through.line) <= ShellQuestion.lineLength, "\(language)")
            #expect(!through.warns && through.chorded?.id == ShellQuestion.yes)
        }
        let through = ShellQuestion.letThrough(listed[0], language: .english)
        #expect(through.title == "Let @eve@a.example (Eve)'s notices through on a.example?")
        #expect(through.line == "Their later notices come through too. Fediqo cannot undo this.")
        #expect(through.help?.contains("from then on stops holding back what they send you") == true)
        #expect(through.help?.contains("Fediqo has no way to ask it to take that back") == true)
        #expect(through.choices.map(\.label) == ["Let through"] && through.cancel == "Cancel")
        #expect(ShellQuestion.letThrough(listed[0], language: .taiwanese).line.contains("Fediqo 無法復原"))

        more.items[0].press { acts.asked = $0 }
        let first = try #require(acts.asked)
        #expect(first.question == ShellQuestion.letThrough(listed[0]))
        #expect(await server.posts.isEmpty, "choosing Let through sent it without asking")
        first.answered("cancel")
        #expect(await server.posts.isEmpty)
        first.answered(ShellQuestion.yes)
        acts.asked = nil
        #expect(await spun { acts.onItsWay.count == 1 })
        let (_, page) = hosted(session)
        #expect(page.says[.onWay(listed[0].id)] == "@eve@a.example (Eve)'s notices are on their way from a.example. A later read shows them.")
        let way = try #require(page.frames[.onWay(listed[0].id)]), top = try #require(page.frames[.row(rows(page)[0])])
        #expect(way.height > 0 && way.maxY <= top.minY + 0.5)
        #expect(page.frames[.request(listed[0].id)] == nil && page.frames[.request(listed[1].id)] != nil)
        #expect(page.says[.held(Self.a)] == "a.example is holding back 1 notice.")

        // Let go only puts its question; the yes sends it.
        let last = NoticeActs.more(listed[1], in: session)
        last.items[1].press { acts.asked = $0 }
        let asked = try #require(acts.asked)
        #expect(asked.question == ShellQuestion.letGo(listed[1]))
        #expect(await server.posts == [accept])
        asked.answered(ShellQuestion.yes)
        acts.asked = nil
        #expect(await spun { acts.holders.isEmpty })
        #expect(await server.posts == [accept, go])
        let (_, after) = hosted(session)
        #expect(after.frames[.held(Self.a)] == nil && after.frames[.request(listed[1].id)] == nil)
        #expect(after.says[.onWay(listed[0].id)] != nil, "what was let through stopped being said before a read showed it")
    }

    @Test("A sign-in that only reads is shown what is held, and both acts dim with why")
    func aReadingSignInSeesAndMayNotAct() async throws {
        let (session, server) = try await holding(a: F.reads)
        let acts = session.noticeList.acts
        await acts.open(host: Self.a, in: session)
        let eve = try #require(acts.requests[Self.a]?.first)

        let (_, page) = hosted(session)
        #expect((page.frames[.request(eve.id)]?.height ?? 0) > 0)
        let more = NoticeActs.more(eve, in: session, language: .english)
        let why = "The sign-in on a.example only reads, so it cannot act on notices."
        #expect(more.head == [why] && more.items.map(\.answers) == [false, false])
        #expect(more.items.map { NoticeActs.spoken($0, of: more, language: .english) } == ["Let through. \(why)", "Let go. \(why)"])
        for item in more.items { item.press { acts.asked = $0 } }
        #expect(acts.asked == nil)
        #expect(await server.posts.isEmpty)
    }

    @Test("An opened held-back line whose source lists nobody says so, and one that lists fewer people than it counts says there are more")
    func anOpenedLineNeverStandsOverNothing() async throws {
        let (session, server) = try await holding([F.get(Self.a, Self.requests): .body("[]")])
        let acts = session.noticeList.acts
        await acts.open(host: Self.a, in: session)
        #expect(acts.requests[Self.a] == [] && acts.held(host: Self.a) != nil)

        let (_, empty) = hosted(session)
        #expect(empty.says[.heldPartial(Self.a)] == "a.example listed none of the people whose notices it is holding back.")
        #expect((empty.frames[.heldPartial(Self.a)]?.height ?? 0) > 0, "an opened line stood over nothing")
        #expect(L10n.t("notices.held.none", language: .taiwanese) != "notices.held.none")

        // One of the two it counts.
        await server.set(F.get(Self.a, Self.requests), .body("[" + F.request(71, by: "Eve", count: 3) + "]"))
        acts.close(host: Self.a)
        await acts.open(host: Self.a, in: session)
        let (_, partial) = hosted(session)
        #expect(partial.says[.heldPartial(Self.a)] == "a.example is holding back more people's notices than are listed here.")
        #expect(partial.frames[.request(try #require(acts.requests[Self.a]?.first).id)] != nil)

        // Both of the two: nothing more to say.
        await server.set(F.get(Self.a, Self.requests), .body("[" + F.request(71, by: "Eve", count: 3) + "," + F.request(72, by: "Flo", count: 1) + "]"))
        acts.close(host: Self.a)
        await acts.open(host: Self.a, in: session)
        let (_, whole) = hosted(session)
        #expect(whole.frames[.heldPartial(Self.a)] == nil)
    }

    // MARK: - 320 points across

    @Test("At 320 points nothing the acts add to the page is cut: each sentence at the height it asks for, each press and each three dots whole",
          arguments: [DummyFontSize.standard.dynamicType, DynamicTypeSize.accessibility1])
    func theActsAt320(_ type: DynamicTypeSize) async throws {
        let held = "[" + F.request(71, by: "Eve Evelyn Everard of the Very Long Name That Goes On and On", count: 3, words: String(repeating: "held words and more ", count: 12))
            + "," + F.request(72, by: "Flo", count: 1) + "]"
        let (session, _, _) = try await F.shell([
            F.get(Self.long): F.page(F.one(4, by: "Ada", minutes: 2), F.one(3, "follow", by: "Bo", minutes: 9)),
            F.get(Self.long, Self.policy): F.policy(requests: 3, notices: 4),
            F.get(Self.long, Self.requests): .body(held),
            F.post(Self.long, Self.requests + "/72/accept"): .body("{}"),
            F.post(Self.long, "/api/v1/notifications/4/dismiss"): .status(503),
        ], signedIn: [Self.long: F.acts, "c.example": F.plain])
        let acts = session.noticeList.acts
        await acts.readPage(in: session)
        await acts.open(host: Self.long, in: session)
        let listed = try #require(acts.requests[Self.long])
        await acts.letThrough(listed[1], in: session)
        await acts.dismiss(try line("4", of: Self.long, in: session), in: session)

        let (_, probe) = hosted(session, width: 320, layout: .narrow, type: type)
        #expect(rows(probe).count == 2)
        for (part, frame) in probe.frames {
            #expect(frame.minX >= -0.5 && frame.maxX <= 320 + Self.pixel, "\(type): \(part) runs past a page 320 points across")
        }

        // Each sentence the acts say stands at the height it asks for at the width it has.
        let said = try #require(NoticesPane.said(in: session).first?.words)
        let sentences: [(NoticesProbe.Part, String)] = [
            (.said(Self.long), said),
            (.onWay(listed[1].id), NoticeActs.onItsWay(listed[1])),
            (.heldPartial(Self.long), String(format: L10n.t("notices.held.partial"), Self.long)),
        ]
        for (part, words) in sentences {
            let frame = try #require(probe.frames[part], "\(type): \(part) is not drawn")
            #expect(probe.says[part] == words)
            let asks = Self.wrapped(Text(words).shellFont(.meta), width: frame.width, type)
            #expect(frame.height >= asks - 0.5, "\(type): \(part) is cut: \(frame.height) of \(asks)")
        }
        let words = try #require(probe.frames[.heldWords(Self.long)])
        let holding = try #require(acts.held(host: Self.long))
        let asks = Self.wrapped(
            Label(NoticeActs.words(holding, host: Self.long), systemImage: "tray").labelStyle(.titleAndIcon).shellFont(.meta),
            width: words.width, type
        )
        #expect(words.height >= asks - 0.5, "\(type): the held-back words are cut: \(words.height) of \(asks)")

        // The presses, whole: opening what is held, and asking a source for notices.
        let toggle = try #require(probe.frames[.heldPress(Self.long)])
        let hide = Self.ideal(ShellLinkButton(L10n.t("notices.held.hide")) {}, type)
        #expect(toggle.width >= hide.width - 0.5 && toggle.height >= hide.height - 0.5, "\(type): the press on the held-back line is cut")
        let ask = try #require(probe.frames[.linePress("unasked:c.example")])
        let button = Self.ideal(ShellLinkButton(L10n.t("notices.ask.press")) {}, type)
        #expect(ask.width >= button.width - 0.5 && ask.height >= button.height - 0.5, "\(type): the press to ask is cut")

        // Every three dots at its own box, and clear of the words beside it.
        let box = Self.box(type)
        let head = try #require(probe.frames[.moreMark]), title = try #require(probe.frames[.title])
        #expect(head.width >= box.width - Self.pixel && head.height >= box.height - Self.pixel, "\(type): the head's three dots are squeezed")
        #expect(head.minX >= title.maxX - 0.5 || head.minY >= title.maxY - 0.5)
        let request = listed[0]
        let dots = try #require(probe.frames[.requestMore(request.id)]), who = try #require(probe.frames[.requestWords(request.id)])
        #expect(dots.width >= box.width - Self.pixel && dots.height >= box.height - Self.pixel, "\(type): a request's three dots are squeezed")
        #expect(who.maxX <= dots.minX + 0.5, "\(type): a request's words run under its three dots")
        // A long name wraps under the dots' column, and is not cut to one line.
        let name = Self.wrapped(Text(NoticeActs.name(request.person)).shellFont(.name), width: who.width, type)
        let count = Self.wrapped(Text(NoticeActs.count(request)).shellFont(.meta), width: who.width, type)
        let excerpt = Self.wrapped(
            Text(try #require(NoticeActs.excerpt(request))).shellFont(.body).lineLimit(NoticeRow.excerptLines), width: who.width, type
        )
        let whole = name + count + excerpt + 2 * ShellSpace.tight
        #expect(who.height >= whole - 0.5, "\(type): a request's name or count is cut: \(who.height) of \(whole)")
    }

    @Test("At 320 points a row with its three dots cuts nothing: the dots whole under the first line, the words there whole beside them, and the first line as it is without them",
          arguments: [DynamicTypeSize.xSmall, .large, .xxLarge, .xxxLarge, .accessibility1, .accessibility2])
    func aRowWithItsDotsAt320(_ type: DynamicTypeSize) throws {
        let width: CGFloat = 320
        let source = Source(host: Self.long, kind: .mastodon)
        let notice = Notice(
            source: source, handle: .gathered(key: "annual_report-30-1"), kind: .unknown("annual_report"),
            people: [NoticePerson(handle: "@ada@elsewhere.example", name: "Ada Augusta Lovelace of the Analytical Engine")],
            count: 12, post: nil, at: Date().addingTimeInterval(-34 * 86_400), newestID: "9", oldestID: "1"
        )
        func laidOut(_ menu: NoticeRow.Menu?) -> NoticeRowProbe {
            let probe = NoticeRowProbe()
            let row = NoticeRow(notice: notice, menu: menu, probe: probe)
                .environment(\.shellLayout, .narrow)
                .dynamicTypeSize(type)
            let hosted = NSHostingView(rootView: row.frame(width: width))
            hosted.frame = NSRect(origin: .zero, size: hosted.fittingSize)
            hosted.layoutSubtreeIfNeeded()
            return probe
        }
        let probe = laidOut(NoticeRow.Menu(more: { ShellMore(items: []) }, asks: .constant(nil)))
        let bare = laidOut(nil)

        let inside = width - 2 * ShellSpace.pad
        let dots = try #require(probe.frames[.more], "\(type): no three dots")
        let head = try #require(probe.frames[.head]), words = try #require(probe.frames[.whatWords])
        let box = Self.box(type)
        #expect(dots.width >= box.width - Self.pixel && dots.height >= box.height - Self.pixel, "\(type): the three dots are squeezed")
        #expect(dots.maxX <= inside + Self.pixel && dots.minY >= head.maxY - 0.5 && words.minY >= head.maxY - 0.5, "\(type): the three dots are not under the first line")
        // What happened is whole beside them: at the height it asks for at the width it has.
        #expect(words.maxX <= dots.minX + 0.5, "\(type): the words run under the three dots")
        let asks = Self.wrapped(Text(NoticeWords.what(notice)).shellFont(.meta), width: words.width, type)
        #expect(words.height >= asks - 0.5, "\(type): what happened is cut: \(words.height) of \(asks)")
        // And the first line gave nothing up for them: who, the source and the age as without.
        for part in [NoticeRowProbe.Part.head, .glyph, .who, .source, .age] {
            let with = try #require(probe.frames[part], "\(type): \(part) is not drawn"), without = try #require(bare.frames[part])
            #expect(abs(with.width - without.width) <= Self.pixel && abs(with.minX - without.minX) <= Self.pixel, "\(type): \(part) moved for the three dots")
        }
        #expect(bare.frames[.more] == nil)
    }

    @Test("The first ask of all failing is said on the page drawn then: no source may be read, and the page still says notices were not allowed")
    func aFailedFirstAskIsSaidWhereNoSourceIsAllowed() async throws {
        let (session, server, _) = try await F.shell([:], signedIn: [Self.a: F.plain])
        await server.set("POST a.example/api/v1/apps", .status(503))
        await session.allowNotices(host: Self.a, through: NoticeActPage())
        #expect(session.mastodon.notices(host: Self.a) == .unasked)

        for width in [600, 320] as [CGFloat] {
            let (_, probe) = hosted(session, width: width, layout: width < 400 ? .narrow : .wide)
            #expect(probe.says[.notAllowed] != nil && probe.frames[.head] == nil, "the page with no source allowed is the one drawn")
            #expect(probe.says[.said(Self.a)] == "Notices were not allowed on a.example. Its sign-in works as it did.")
            let said = try #require(probe.frames[.said(Self.a)])
            #expect(said.height > 0 && said.maxX <= width + 1)
            let line = try #require(probe.frames[.line("unasked:a.example")])
            #expect(said.minY >= line.maxY - 1, "said under the source it is about")
        }

        // The next ask takes it down as it sets out, as on the list.
        await server.set("POST a.example/api/v1/apps", nil)
        session.askForNotices(host: Self.a)
        await session.allowNotices(host: Self.a, through: NoticeActPage(closes: true))
        let (_, after) = hosted(session)
        #expect(after.says[.said(Self.a)] == nil)
    }
}
#endif
