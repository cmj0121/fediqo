import FediqoCore
import Foundation
import SwiftUI
import Testing
@testable import FediqoUI
#if os(macOS)
import AppKit
#endif

/// A source is one line, the same at every width and for every source: its mark, its host, its
/// sign-in key and `…` (the person's order of 2026-10-07, which withdrew the two arrangements,
/// the ladder of what a narrow line gave up, and decisions 33 and 4).
///
/// Which marks, in which look and for which reason, and what `…` holds and in what order, are
/// values and are asked directly. The row is then hosted at a phone's width and at a wide page's,
/// for each kind of source and each size of text, and measured: one line tall, the same as its
/// neighbour, and no wider than it was given.
@Suite("A source is one line at every width", .serialized)
@MainActor
struct SourceLineTests {
    init() {
        L10n.language = .english
    }

    private static let forum = Source(
        host: "forum.example", kind: .discuz, boards: [BoardSubscription(fid: 1, name: "General")]
    )
    private static let micro = Source(host: "micro.example", kind: .mastodon)

    /// A row that owes `owed`, as the two facts it is derived from: a write turned away, or a
    /// sign-in made before something was asked for.
    private static func row(_ source: Source, signedIn: Bool = false, owed: SourceRow.Owed? = nil) -> SourceRow {
        SourceRow(
            source: source, profile: .unasked(host: source.host, kind: source.kind), signedIn: signedIn,
            writing: owed == .refused ? .refused : nil, unasked: owed == .asking
        )
    }

    private static func clearAsks(_ host: String) -> ShellConfirmation {
        ShellQuestion.clear(host: host, detailKey: "account.clear.detail", language: .english)
    }

    private static func removeAsks(_ host: String) -> ShellConfirmation {
        ShellQuestion.remove(host: host, boards: 0, language: .english)
    }

    private static func view(
        _ row: SourceRow, actsLive: Bool = true, waiting: String? = nil,
        refusal: (host: String, key: String)? = nil, notice: String? = nil,
        presses: SourceRow.Presses = SourceRow.Presses()
    ) -> SourceRowView {
        SourceRowView(
            row: row, actsLive: actsLive, waiting: waiting, refusal: refusal, notice: notice,
            clearAsks: { clearAsks(row.source.host) }, removeAsks: { removeAsks(row.source.host) },
            presses: presses
        )
    }

    // MARK: - Which marks

    @Test("Every source offers the same five acts: the sign-in as a key on the row, and boards, lists, clear and remove in its menu, in that order",
          arguments: ProtocolKind.allCases)
    func everySourceDrawsTheSameMarks(_ kind: ProtocolKind) {
        #expect(SourceRow.onRow == [.signIn])
        #expect(SourceRow.inMore == [.boards, .lists, .clear, .remove])
        #expect(SourceRow.onRow + SourceRow.inMore == SourceRow.Control.allCases, "an act is offered nowhere, or twice")
        #expect(SourceRow.Control.allCases.map(SourceRow.symbol) == ["key", "checklist", "list.bullet", "eraser", "trash"])

        for signedIn in [false, true] {
            for actsLive in [false, true] {
                let drawn = Self.view(Self.row(Source(host: "a.example", kind: kind), signedIn: signedIn), actsLive: actsLive)
                #expect(drawn.key.symbol == "key", "\(kind): the sign-in is one glyph on every source")
                #expect(drawn.more.items.map(\.symbol) == ["checklist", "list.bullet", "eraser", "trash"], "\(kind)")
            }
        }
    }

    // MARK: - Which look, and which reason

    @Test("The key is quiet signed out and filled and warm signed in; dim for good where the protocol has no sign-in, and dim for now while the row's acts are not live",
          arguments: ProtocolKind.allCases)
    func theKey(_ kind: ProtocolKind) {
        let source = Source(host: "a.example", kind: kind)
        func look(signedIn: Bool = false, actsLive: Bool = true) -> MarkLook {
            SourceRow.look(.signIn, source: source, signedIn: signedIn, actsLive: actsLive)
        }
        guard SourceRow.canSignIn(kind) else {
            // Never comes before not now: a busy page does not promise a control that is not coming.
            #expect(look() == .dim(.never) && look(actsLive: false) == .dim(.never), "\(kind)")
            let key = Self.view(Self.row(source)).key
            #expect(key.drawn == "key" && !key.on)
            #expect(key.spoken.hasSuffix(L10n.t("mark.dim.never")), "the reason is not said")
            return
        }
        #expect(look() == .live && look(signedIn: true) == .live, "\(kind)")
        #expect(look(actsLive: false) == .dim(.notNow) && look(signedIn: true, actsLive: false) == .dim(.notNow))

        let out = Self.view(Self.row(source)).key
        let signedIn = Self.view(Self.row(source, signedIn: true)).key
        #expect(!out.on && out.drawn == "key")
        #expect(signedIn.on && signedIn.drawn == "key.fill")
        #expect(ShellMark.ink(out.look, on: out.on, .light) == ShellChrome.inkDim(.light))
        #expect(ShellMark.ink(signedIn.look, on: signedIn.on, .light) == ShellChrome.filament(.light))
        // Busy, it keeps the glyph it had: filled is its state and not its look.
        let held = Self.view(Self.row(source, signedIn: true), actsLive: false).key
        #expect(held.drawn == "key.fill" && held.look == .dim(.notNow))
        #expect(ShellMark.ink(held.look, on: held.on, .light) == ShellChrome.markDim(.light))
        // And it is named by its act, either way round.
        #expect(out.name == String(format: L10n.t("account.refuse.signin.label"), "a.example"))
        #expect(signedIn.name == String(format: L10n.t("account.source.signout.label"), "a.example"))
    }

    @Test("Boards are dim for good where the protocol has no picker or the source has no boards; lists are dim for now signed out where the protocol has lists, and for good elsewhere; clear and remove are on every source",
          arguments: ProtocolKind.allCases)
    func theMenusLooks(_ kind: ProtocolKind) {
        let bare = Source(host: "a.example", kind: kind)
        let boarded = Source(host: "a.example", kind: kind, boards: [BoardSubscription(fid: 1, name: "x")])
        func look(_ control: SourceRow.Control, _ source: Source, signedIn: Bool = false, actsLive: Bool = true) -> MarkLook {
            SourceRow.look(control, source: source, signedIn: signedIn, actsLive: actsLive)
        }

        #expect(look(.boards, bare) == .dim(.never), "\(kind): nothing to pick between")
        #expect(look(.boards, boarded) == (SourceRow.canChangeBoards(kind) ? .live : .dim(.never)), "\(kind)")
        #expect(look(.boards, boarded, actsLive: false) == (SourceRow.canChangeBoards(kind) ? .dim(.notNow) : .dim(.never)))

        if SourceRow.canChooseLists(kind) {
            #expect(look(.lists, bare) == .dim(.notNow), "\(kind): signing in is what brings the lists")
            #expect(look(.lists, bare, signedIn: true) == .live)
            #expect(look(.lists, bare, signedIn: true, actsLive: false) == .dim(.notNow))
        } else {
            for signedIn in [false, true] {
                #expect(look(.lists, bare, signedIn: signedIn) == .dim(.never), "\(kind)")
                #expect(look(.lists, bare, signedIn: signedIn, actsLive: false) == .dim(.never), "\(kind)")
            }
        }

        for control in [SourceRow.Control.clear, .remove] {
            #expect(look(control, bare) == .live, "\(kind) \(control)")
            #expect(look(control, bare, actsLive: false) == .dim(.notNow), "\(kind) \(control)")
        }
    }

    // MARK: - What `…` holds

    @Test("The menu's head is the waiting sentence, a refusal, the forum's notice, the permission reason and then why the key is dim; under it boards and lists, a divider, and clear and remove")
    func whatTheMenuHolds() {
        let source = Source(host: "talk.example", kind: .discourse)
        let refusal = (host: "talk.example", key: "account.source.boards.unread")
        let drawn = Self.view(
            Self.row(source, owed: .asking), waiting: "Reading talk.example…", refusal: refusal, notice: "It did not sign in."
        )
        #expect(drawn.more.head == [
            "Reading talk.example…",
            String(format: L10n.t("account.source.boards.unread"), "talk.example"),
            "It did not sign in.",
            String(format: L10n.t("account.source.permission"), "talk.example"),
            // The reason names the mark it is about: a line read alone says what is dim.
            "Open talk.example's own sign-in page. \(L10n.t("mark.dim.never"))",
        ])
        #expect(drawn.more.head.last == drawn.key.spoken)
        #expect(drawn.more.ordinary.map(\.symbol) == ["checklist", "list.bullet"])
        #expect(drawn.more.dangers.map(\.symbol) == ["eraser", "trash"])
        #expect(drawn.more.divides)
        // A menu draws no colour of ours, so a dim item's reason is in its own words.
        #expect(drawn.more.ordinary.allSatisfy { $0.title().hasSuffix(L10n.t("mark.dim.never")) && !$0.answers })
        #expect(drawn.more.label() == L10n.t("mark.more"))

        // At rest on a source with everything, the head is empty and every item answers.
        let rest = Self.view(Self.row(Self.forum))
        #expect(rest.more.head.isEmpty)
        #expect(rest.more.items.map(\.name) == [
            "Change which boards you read on forum.example",
            "Choose which of your lists you read on forum.example",
            "Clear what this device holds from forum.example",
            "Remove forum.example and everything it left here",
        ])
        #expect(rest.more.items.map(\.answers) == [true, false, true, true])
        // Signed out of a protocol with lists: not right now, and said in the item.
        let lists = Self.view(Self.row(Self.micro)).more.items[1]
        #expect(lists.title() == "Choose which of your lists you read on micro.example. \(L10n.t("mark.dim.notNow"))")
        #expect(Self.view(Self.row(Self.micro, signedIn: true)).more.items[1].answers)
    }

    @Test("A press in the menu goes to its own act and no other; clear and remove only hand over their question, and only its yes acts")
    func theMenusPresses() {
        var pressed: [String] = []
        var presses = SourceRow.Presses()
        presses.signIn = { pressed.append("signIn") }
        presses.changeBoards = { pressed.append("boards") }
        presses.chooseLists = { pressed.append("lists") }
        presses.clear = { pressed.append("clear") }
        presses.remove = { pressed.append("remove") }
        presses.open = { pressed.append("open") }
        var put: [ShellMoreAsk] = []

        let forum = Self.view(Self.row(Self.forum), presses: presses).more
        for item in forum.items { item.press { put.append($0) } }
        // Lists is dim on a forum, so its press is taken and goes nowhere; the two that take
        // something away have done nothing yet.
        #expect(pressed == ["boards"])
        #expect(put.map(\.question) == [Self.clearAsks("forum.example"), Self.removeAsks("forum.example")])

        // Cancel, or any answer that is not the yes, changes nothing; the yes acts once.
        put[0].answered("cancel")
        put[1].answered("")
        #expect(pressed == ["boards"])
        put[0].answered(ShellQuestion.yes)
        put[1].answered(ShellQuestion.yes)
        #expect(pressed == ["boards", "clear", "remove"])

        pressed = []
        put = []
        for item in Self.view(Self.row(Self.micro, signedIn: true), presses: presses).more.items { item.press { put.append($0) } }
        #expect(pressed == ["lists"] && put.count == 2)

        // While the row's acts are not live, nothing in the menu does anything or asks anything.
        pressed = []
        put = []
        let held = Self.view(Self.row(Self.forum), actsLive: false, presses: presses).more
        for item in held.items { item.press { put.append($0) } }
        #expect(pressed.isEmpty && put.isEmpty)
        #expect(held.items.allSatisfy { !$0.answers })
    }

    // MARK: - Danger is only in the menu

    @Test("Clear and remove are offered only as destructive items of the menu, each with the question it asks, and that question is built when the item is chosen and not when the row is drawn")
    func clearAndRemoveAreOnlyDangerItems() {
        // What takes something away is never the row's own mark.
        #expect(!SourceRow.onRow.contains(.clear) && !SourceRow.onRow.contains(.remove))

        for source in [Self.forum, Self.micro, Source(host: "talk.example", kind: .discourse)] {
            var built = 0
            var acted = 0
            var presses = SourceRow.Presses()
            presses.clear = { acted += 1 }
            presses.remove = { acted += 1 }
            let row = Self.row(source)
            let drawn = SourceRowView(
                row: row, actsLive: true, waiting: nil, refusal: nil,
                clearAsks: { built += 1; return Self.clearAsks(source.host) },
                removeAsks: { built += 1; return Self.removeAsks(source.host) },
                presses: presses
            )
            // Everything the row and its menu draw, and no question has been built for it.
            let more = drawn.more
            #expect(more.dangers.map(\.symbol) == ["eraser", "trash"], "\(source.kind)")
            #expect(more.dangers.allSatisfy(\.isDanger) && more.ordinary.allSatisfy { !$0.isDanger })
            #expect(more.items.map(\.answers).count == 4 && more.divides)
            _ = (drawn.key, drawn.saying, drawn.permission, more.label(), more.items.map { $0.title() })
            #expect(built == 0, "\(source.kind): a question was built for a row nobody pressed")
            #expect(more.ordinary.allSatisfy { $0.question == nil })

            // Chosen, each hands over the question the page gave it, and has done nothing.
            var put: [ShellMoreAsk] = []
            for item in more.dangers { item.press { put.append($0) } }
            #expect(built == 2 && acted == 0, "\(source.kind)")
            #expect(put.map(\.question) == [Self.clearAsks(source.host), Self.removeAsks(source.host)])
            #expect(put.allSatisfy { $0.question.chorded != nil }, "a question with no yes")
        }
    }

    @Test("The questions a row's menu asks are the session's, its yeses are the session's one clear and one remove, and nothing is raised on the root beside them")
    func theRowsQuestionsAreThePagesOwn() async {
        let session = ShellSession(http: FixtureHTTP(), store: ItemStore())
        await session.store.add(Self.forum)
        await session.store.add(Self.micro)
        session.sources = await session.store.sources()
        let pane = AccountPane(session: session)
        let row = session.rows[0]

        #expect(session.clearQuestion(host: row.source.host) == ShellQuestion.clear(
            host: "forum.example",
            detailKey: SourceRow.clearDetailKey(hasPassword: false, reachedSignIn: false)
        ))
        #expect(session.removeQuestion(host: row.source.host, postsStay: true) != session.removeQuestion(host: row.source.host, postsStay: false))

        await pane.clear(row)
        #expect(session.cleared == 1 && session.sources.count == 2, "Clear's yes did not clear, or took the source")
        await pane.remove(row, keepingPosts: false)
        #expect(session.sources.map(\.host) == ["micro.example"], "Remove's yes did not remove")
    }

    // MARK: - The permission glyph

    @Test("The permission glyph is owed in three cases — a write turned away, a sign-in made before writing was asked for, one made before bookmarks were — and in no other; it is the alarm only for the first",
          arguments: SourceWriting.allCases)
    func whenPermissionIsOwed(_ writing: SourceWriting) {
        #expect(SourceRow.permissionSymbol == "exclamationmark.lock")
        for grant in [nil] + MastodonGrant.allCases.map(Optional.some) {
            for bookmarks in BookmarkStanding.allCases {
                let owed = SourceRow.owed(
                    writing: writing, unasked: SourceRow.unasked(grant: grant, bookmarks: bookmarks)
                )
                let expected: SourceRow.Owed = writing == .refused
                    ? .refused : (grant == .unasked || bookmarks == .unasked ? .asking : .nothing)
                #expect(owed == expected, "\(writing) \(String(describing: grant)) \(bookmarks)")
            }
        }
        // Nothing to ask, by choice, or signed out: no glyph.
        #expect(!SourceRow.unasked(grant: nil, bookmarks: .unavailable))
        #expect(SourceRow.owed(writing: writing, unasked: false) == (writing == .refused ? .refused : .nothing))
        // What a row owes is read off its own two facts, so it cannot disagree with its writing.
        let source = Source(host: "a.example", kind: .mastodon)
        for unasked in [false, true] {
            let row = SourceRow(
                source: source, profile: .unasked(host: source.host, kind: source.kind), signedIn: true,
                writing: writing, unasked: unasked
            )
            #expect(row.owed == SourceRow.owed(writing: writing, unasked: unasked))
            #expect((row.owed == .refused) == (row.writing == .refused))
        }
        #expect(SourceRow.permissionInk(.refused, look: .live, .light) == ShellChrome.alarm(.light))
        #expect(SourceRow.permissionInk(.asking, look: .live, .light) == ShellChrome.inkDim(.light))
        // While it cannot be pressed it is a dim mark's ink, whatever it is owed for.
        for owed in [SourceRow.Owed.asking, .refused] {
            #expect(SourceRow.permissionInk(owed, look: .dim(.notNow), .light) == ShellChrome.markDim(.light))
        }
    }

    @Test("The permission glyph says its sentence in every language, at the head of the menu too, and a row that owes nothing draws none")
    func whatPermissionSays() {
        let none = Self.row(Self.micro, signedIn: true)
        #expect(none.owed == .nothing && SourceRow.permissionLine(none) == nil)
        #expect(Self.view(none).more.head.isEmpty)

        for owed in [SourceRow.Owed.asking, .refused] {
            let row = Self.row(Self.micro, signedIn: true, owed: owed)
            for language in DummyLanguage.allCases {
                let line = SourceRow.permissionLine(row, language: language)
                #expect(line == String(format: L10n.t("account.source.permission", language: language), "micro.example"))
                #expect(line?.contains("micro.example") == true && line?.contains("account.source") == false)
                #expect(SourceRow.head(row, said: ["w"], language: language) == ["w", line!])
            }
            #expect(Self.view(row).more.head == [SourceRow.permissionLine(row)!])
        }
        #expect(L10n.t("account.source.permission", language: .taiwanese) != L10n.t("account.source.permission", language: .english))
    }

    @Test("The permission glyph is pressed only while the row's acts are live: held, it is drawn dim, says not right now, and its press goes nowhere")
    func thePermissionGlyphsPress() {
        let row = Self.row(Self.micro, signedIn: true, owed: .refused)
        #expect(SourceRow.permission(Self.row(Self.micro), actsLive: true) == nil, "a glyph where nothing is owed")

        let live = SourceRow.permission(row, actsLive: true)!
        let held = SourceRow.permission(row, actsLive: false)!
        #expect(live.symbol == "exclamationmark.lock" && live.drawn == held.drawn, "live and dim draw two glyphs")
        #expect(live.look == .live && ShellMark.press(live.look) == .acts)
        #expect(held.look == .dim(.notNow) && ShellMark.press(held.look) == .nothing)
        #expect(live.spoken == SourceRow.permissionLine(row))
        #expect(held.spoken == "\(SourceRow.permissionLine(row)!). \(L10n.t("mark.dim.notNow"))")

        var asked = 0
        ShellMark.pressed(held.look, act: { asked += 1 }, ask: nil)
        #expect(asked == 0, "a held glyph put its question")
        ShellMark.pressed(live.look, act: { asked += 1 }, ask: nil)
        #expect(asked == 1)
        // And the row asks those rules with its own inputs.
        #expect(Self.view(row).permission == live && Self.view(row, actsLive: false).permission == held)

        // Each dim mark's reason is in the head: held, the lock is named there with the key.
        let busy = Self.view(row, actsLive: false)
        #expect(Self.view(row).more.head == [live.name])
        #expect(busy.more.head == [held.name] + ShellMore.reasons(of: [held, busy.key]))
        #expect(busy.more.head.last == "\(held.name), \(busy.key.name). \(L10n.t("mark.dim.notNow"))")
    }

    @Test("The page hands the glyph its own asking: a press puts the sign-in question and signs nobody out, and a row that owes nothing puts none")
    func theGlyphIsWiredToThePagesAsking() async {
        let session = ShellSession(http: FixtureHTTP(), store: ItemStore())
        await session.store.add(Self.micro)
        session.sources = await session.store.sources()
        let pane = AccountPane(session: session)

        pane.presses(session.rows[0]).askAgain()
        #expect(session.signInChoice == nil && session.bookmarkAsk == nil, "a row that owes nothing was asked")

        pane.presses(Self.row(Self.micro, signedIn: true, owed: .refused)).askAgain()
        #expect(session.signInChoice == "micro.example", "the glyph's press reached nothing")
        #expect(session.sources.count == 1 && session.cleared == 0)
    }

    // MARK: - No two presses overlap

    @Test("The row's trailing marks stand apart by exactly what their presses spill, at every size of text, so no two press regions overlap and none reaches the hostname's",
          arguments: DynamicTypeSize.allCases)
    func noTwoPressesOverlap(_ type: DynamicTypeSize) {
        #expect(ShellTouchFloor.finger == 44 && ShellGlyphBox.box == 32)
        #expect(ShellTouchFloor.gap(drawn: ShellGlyphBox.box) == 12)
        #expect(ShellTouchFloor.lead(drawn: ShellGlyphBox.box) == 0)

        let box = ShellGlyphBox.box * ShellType.multiple(at: type)
        let spill = ShellTouchFloor.spill(drawn: box)
        let gap = ShellTouchFloor.gap(drawn: box)
        // Two neighbours each reach `spill` into the gap between them.
        #expect(gap - spill * 2 >= 0, "\(type): two presses share \(spill * 2 - gap) points")
        #expect(gap == spill * 2, "\(type): the gap is wider than the presses need")
        // Box and gap together are a finger, or the box alone already is.
        #expect(box + gap >= ShellTouchFloor.finger - 0.001, "\(type)")
        // The first mark's press stops short of the hostname's, which runs to its own edge.
        #expect(ShellSpace.snug + ShellTouchFloor.lead(drawn: box) >= spill, "\(type): the first mark's press reaches the hostname's")
    }

    // MARK: - What the row has to say

    @Test("The menu is always the one glyph: quiet at rest and while the row only waits, the alarm where it warns; its name says there is something to read; a listener hears the row and then what it says",
          arguments: [DummyLanguage.english, .taiwanese])
    func somethingToSay(_ language: DummyLanguage) {
        #expect(!SourceRow.warns(waiting: true, said: ["Signing in…"]) && !SourceRow.warns(waiting: false, said: []))
        #expect(SourceRow.warns(waiting: false, said: ["It refused."]))
        #expect(SourceRow.warns(waiting: true, said: ["Signing in…", "It refused."]))
        #expect(SourceRow.saying(waiting: false, said: []) == .nothing)
        #expect(SourceRow.saying(waiting: true, said: ["Signing in…"]) == .waits)
        #expect(SourceRow.saying(waiting: false, said: ["It refused."]) == .warns)
        #expect(SourceRow.saying(waiting: true, said: ["Signing in…", "It refused."]) == .warns)
        #expect(SourceRow.heard(row: "m.example, Mastodon", said: []) == "m.example, Mastodon")
        #expect(SourceRow.heard(row: "m.example", said: ["It refused.", "Try again."]) == "m.example It refused. Try again.")

        // One glyph whatever it says; colour is the signal, and only a warning is the alarm.
        #expect(ShellMore.symbol == "ellipsis")
        #expect(ShellMoreButton.ink(.nothing, .light) == ShellChrome.inkDim(.light))
        #expect(ShellMoreButton.ink(.waits, .light) == ShellChrome.inkDim(.light))
        #expect(ShellMoreButton.ink(.warns, .light) == ShellChrome.alarm(.light))
        #expect(ShellMoreButton.ink(.warns, .dark) == ShellChrome.alarm(.dark))

        // And in words, for a pointer and a listener: there is something to read.
        let more = Self.view(Self.row(Self.forum)).more
        let plain = more.label(language: language)
        let said = L10n.t("mark.more.said", language: language)
        #expect(said != "mark.more.said")
        #expect(more.label(saying: .nothing, language: language) == plain)
        let joined = String(format: L10n.t("mark.dim.said", language: language), plain, said)
        #expect(more.label(saying: .waits, language: language) == joined)
        #expect(more.label(saying: .warns, language: language) == joined)
        #expect(joined.contains(". ") == (language == .english), "the two are joined as English joins them in every language")

        // And the row asks those rules about its own sentences.
        #expect(Self.view(Self.row(Self.forum)).saying == .nothing)
        #expect(Self.view(Self.row(Self.forum), waiting: "Reading…").saying == .waits)
        #expect(Self.view(Self.row(Self.forum), notice: "It did not sign in.").saying == .warns)
        // A refusal about another host is not this row's to say.
        let elsewhere = Self.view(Self.row(Self.forum), refusal: (host: "b.example", key: "account.source.boards.unread"))
        #expect(elsewhere.said.isEmpty && elsewhere.saying == .nothing)
    }

    @Test("The list's help names the key, the menu and the lock in all three tables, and the two Chinese tables are one")
    func theHelpSaysTheNewMarks() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI/Resources")
        func table(_ lproj: String) throws -> String {
            try String(contentsOf: resources.appendingPathComponent("\(lproj).lproj/Localizable.strings"), encoding: .utf8)
        }
        let tables = try ["en", "zh-TW", "zh-Hant"].map(table)
        let named = [
            ["key", "⋯", "grey", "A red ⋯ has something to say"],
            // "does not offer a sign-in", never "is not signed in": grey is about the protocol.
            ["鑰匙", "⋯", "灰", "不提供登入", "紅色的 ⋯ 是有話要說"],
            ["鑰匙", "⋯", "灰", "不提供登入", "紅色的 ⋯ 是有話要說"],
        ]
        for (strings, words) in zip(tables, named) {
            let marks = try #require(strings.split(separator: "\n").first { $0.hasPrefix("\"account.sources.marks\"") })
            for word in words { #expect(marks.contains(word), "the legend does not name \(word)") }
            #expect(!marks.contains("only the marks") && !marks.contains("只帶"), "the legend still says a row leaves marks out")
            #expect(!marks.contains("沒有登入"), "the legend reads as signed out, not as no sign-in offered")
            #expect(strings.contains("\"mark.more.said\" = "))
            #expect(strings.contains("\"account.sources.writing\"") && strings.contains("\"account.source.permission\""))
        }
        #expect(tables[1] == tables[2], "the two Chinese tables differ")
        for language in [DummyLanguage.english, .taiwanese] {
            let help = AccountPane.sourcesHelp(language: language)
            #expect(help.contains(L10n.t("account.sources.marks", language: language)))
            #expect(help.contains(language == .english ? "lock" : "鎖"), "the help does not say what the lock means")
            #expect(!help.contains(L10n.t("account.source.writing.write", language: language)), "the help still describes a word no row draws")
        }
    }

    #if os(macOS)
    private static let sources: [(String, Source, Bool)] = [
        ("signed in", Source(host: "fixture.example", kind: .mastodon), true),
        ("signed out", Source(host: "signed-out.example", kind: .mastodon), false),
        ("a forum with boards", Source(host: "forum.example", kind: .discuz, boards: [BoardSubscription(fid: 1, name: "General")]), false),
        ("another kind of forum", Source(host: "talk.example", kind: .discourse), false),
        ("a long name", Source(host: "a-rather-long-subdomain.of-a-long-name.example", kind: .mastodon), true),
    ]

    private func row(
        _ source: Source, signedIn: Bool, layout: ShellLayout, width: CGFloat, type: DynamicTypeSize,
        waiting: String? = nil, owed: SourceRow.Owed? = nil
    ) -> CGSize {
        let view = Self.view(Self.row(source, signedIn: signedIn, owed: owed), waiting: waiting)
        .environment(\.shellLayout, layout)
        .dynamicTypeSize(type)
        // Offered the width and free to be wider: a line that could not give way runs past it.
        let landed = Landed()
        let placed = view
            .background(GeometryReader { place in
                let _ = landed.maxX = place.frame(in: .named("row")).maxX
                Color.clear
            })
            .frame(minWidth: 0, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: .leading)
            .coordinateSpace(.named("row"))
        let hosted = NSHostingView(rootView: placed)
        hosted.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        hosted.layoutSubtreeIfNeeded()
        return CGSize(width: landed.maxX, height: hosted.fittingSize.height)
    }

    /// Where the row's far edge landed, written as it is laid out.
    private final class Landed {
        var maxX: CGFloat = 0
    }

    @Test("At 288 points — a 320-point phone's row — every kind of source is one line at every size of text: all one height, a finger tall and no taller than a second line would make it, and no wider than the row",
          arguments: [DynamicTypeSize.medium, .xxLarge, .xxxLarge, .accessibility1])
    func oneLineEach(_ type: DynamicTypeSize) {
        let width: CGFloat = 288
        let line = NSHostingView(rootView: Text("Ag").shellFont(.name).dynamicTypeSize(type).fixedSize()).fittingSize.height
        var heights: [CGFloat] = []
        for (name, source, signedIn) in Self.sources {
            let size = row(source, signedIn: signedIn, layout: .narrow, width: width, type: type)
            #expect(size.width <= width + 0.5, "\(type) \(name): the line is \(size.width) wide in a row \(width) wide")
            #expect(size.height >= SourceRow.touch, "\(type) \(name): a finger tall")
            #expect(size.height < SourceRow.touch + ShellSpace.tight * 2 + line, "\(type) \(name): \(size.height) is more than one line")
            heights.append(size.height)
        }
        #expect(Set(heights.map { ($0 * 2).rounded() / 2 }).count == 1, "\(type): the rows are \(heights) tall")
        // And with something to say, it is still one line: the sentence is behind the mark.
        let waiting = row(Self.sources[2].1, signedIn: false, layout: .narrow, width: width, type: type, waiting: "Signing in to forum.example…")
        #expect(abs(waiting.height - heights[0]) <= 0.5 && waiting.width <= width + 0.5)
        // And with the permission glyph beside the key, the same line again.
        let owing = row(Self.sources[0].1, signedIn: true, layout: .narrow, width: width, type: type, owed: .refused)
        #expect(abs(owing.height - heights[0]) <= 0.5 && owing.width <= width + 0.5, "\(type): the glyph made the row \(owing)")
    }

    /// What the row leaves the hostname, measured off the hosted row: the row's width less
    /// everything in it that is not the hostname's text — which is the row at its ideal width
    /// around a one-letter host, less that letter.
    private func hostRoom(in width: CGFloat, type: DynamicTypeSize, owed: SourceRow.Owed?) -> CGFloat {
        let short = Source(host: "a", kind: .mastodon)
        let ideal = NSHostingView(rootView: Self.view(Self.row(short, signedIn: true, owed: owed))
            .dynamicTypeSize(type).fixedSize()).fittingSize.width
        let letter = NSHostingView(rootView: Text("a").shellFont(.name).dynamicTypeSize(type).fixedSize()).fittingSize.width
        return width - (ideal - letter)
    }

    @Test("The hostname's width on the narrowest row is a number that is watched: at 288 points with the lock, the key and the menu all drawn, 128 points at the default size and 77 at the largest")
    func theHostKeepsItsRoom() {
        // The default size: 288 less the mark (24), two gaps (8) and three marks a finger apart
        // (44 each) — four points under the 132 the two-arrangement row promised a hostname.
        let standard = hostRoom(in: 288, type: .large, owed: .refused)
        #expect(standard >= 128, "the hostname has \(standard) points at the default size")
        // The top of this app's ladder, with the lock: the narrowest case there is.
        #expect(DummyFontSize.largest.dynamicType == .accessibility1)
        let largest = hostRoom(in: 288, type: .accessibility1, owed: .refused)
        // **77 points, and that is under half of what the old floor scaled to** (132 × 28/17 =
        // 217; half is 109): the three marks grow with the type and the hostname pays for it,
        // losing its middle. Pinned so that a fourth mark, or a wider one, is seen here.
        #expect(largest >= 77, "the hostname has \(largest) points at the largest size")
        // Without the lock it has a mark's box and its gap more.
        #expect(hostRoom(in: 288, type: .accessibility1, owed: nil) > largest)
    }

    @Test("A wide page draws the same one line a narrow page does: the same height, and no line held open under the host")
    func wideIsTheSameLine() {
        for (name, source, signedIn) in Self.sources {
            let wide = row(source, signedIn: signedIn, layout: .wide, width: 900, type: .large)
            let narrow = row(source, signedIn: signedIn, layout: .narrow, width: 288, type: .large)
            #expect(abs(wide.height - narrow.height) <= 0.5, "\(name): the wide row is \(wide.height), the narrow \(narrow.height)")
            #expect(wide.width <= 900.5)
        }
    }
    #endif
}
