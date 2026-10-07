import FediqoCore
import Foundation
import SwiftUI
import Testing
@testable import FediqoUI

/// Quiet rows, U8: an act that takes something away is offered only as an item of a `…`, on the
/// row or section it acts on, and asks the question it always asked before anything is done.
///
/// What a test can reach: what each `…` holds as a value, that choosing its item only hands over
/// the question, that only the yes acts, that a menu of one names its item, and — read off the
/// source — that no alarm button is left standing on its own. What it cannot: the menu opened
/// under a pointer or a finger.
@Suite("What takes something away is behind …, and asks first")
@MainActor
struct DangerBehindDotsTests {
    /// Chooses the one item of `more`, and gives back what it put.
    private func chosen(_ more: ShellMore) -> [ShellMoreAsk] {
        var put: [ShellMoreAsk] = []
        more.items.first?.press { put.append($0) }
        return put
    }

    /// The one destructive item of `more` asks `question`, does nothing until its yes, and the
    /// menu's name says what it holds.
    private func asksFirst(
        _ more: ShellMore, symbol: String, named name: String, question: ShellConfirmation, language: DummyLanguage,
        done: () -> Int
    ) {
        #expect(more.items.map(\.symbol) == [symbol])
        #expect(more.dangers.count == 1 && more.ordinary.isEmpty)
        #expect(more.items.first?.name == name)
        #expect(more.label(language: language) == String(format: L10n.t("mark.more.one", language: language), name))
        let put = chosen(more)
        #expect(put.count == 1)
        #expect(put.first?.question == question)
        #expect(done() == 0, "\(name) acted before it was answered")
        put.first?.answered("not the yes")
        #expect(done() == 0)
        put.first?.answered(question.chorded?.id ?? "")
        #expect(done() == 1)
    }

    // MARK: - Kept

    @Test("Stop keeping is the one item of a kept row's …, named with its source", arguments: [DummyLanguage.english, .taiwanese])
    func stopKeeping(_ language: DummyLanguage) {
        for host in ["one.example", nil] as [String?] {
            var stopped = 0
            var said: [StoppedKeeping] = []
            let ask = KeptAsk(host: host, posts: 3, elsewhere: 1)
            let more = KeptSection.more(ask, said: { said.append($0) }, stop: { stopped += 1 }, language: language)
            let name = String(
                format: L10n.t("usage.kept.stop.from", language: language), SpanSection.whereLabel(host, language: language)
            )
            #expect(!name.contains("%"))
            if let host { #expect(name.contains(host)) }
            asksFirst(
                more, symbol: "bookmark.slash", named: name,
                question: ShellQuestion.stopKeeping(ask, language: language), language: language
            ) { stopped }
            #expect(said.isEmpty)
        }
    }

    @Test("Where nothing would be made ordinary, the item says so at once: nothing is asked or done")
    func stopKeepingWithNothingToStop() {
        var stopped = 0
        var said: [StoppedKeeping] = []
        let more = KeptSection.more(
            KeptAsk(host: "one.example", posts: 0, elsewhere: 2), said: { said.append($0) }, stop: { stopped += 1 }
        )
        #expect(more.items.map(\.symbol) == ["bookmark.slash"])
        #expect(more.dangers.isEmpty, "an item that takes nothing away is drawn as a loss")
        #expect(chosen(more).isEmpty, "it asked")
        #expect(said == [StoppedKeeping(ordinary: 0, elsewhere: 2)])
        #expect(stopped == 0)
    }

    @Test("A kept row draws its source's mark and its host as a name")
    func keptRowHasItsMark() throws {
        let section = try ShellSource.shell("KeptSection")
        #expect(section.contains("UsageSourceMark(source: known[line.host] ?? Source(host: line.host, kind: .unknown))"))
        #expect(section.contains("Text(name)\n                    .shellFont(.name)"), "the host is not in the name face")
        #expect(section.contains(".truncationMode(.middle)"))

        let session = ShellSession(http: FixtureHTTP())
        session.sources = [Source(host: "forum.example", kind: .discuz)]
        let known = KeptSection.sources(in: session)
        #expect(known["forum.example"]?.kind == .discuz)
        #expect(known["gone.example"] == nil, "a host nothing remembers is drawn as the host alone")
    }

    // MARK: - Span, Copies

    /// The one item of `more` is destructive and counted: nothing is done by choosing it but
    /// the count, and what comes back is the question to put.
    private func counted(_ more: ShellMore, symbol: String, named name: String, language: DummyLanguage) async -> ShellMoreAsk? {
        #expect(more.items.map(\.symbol) == [symbol])
        #expect(more.dangers.count == 1 && more.items.first?.isCounted == true)
        #expect(more.items.first?.name == name)
        #expect(more.label(language: language) == String(format: L10n.t("mark.more.one", language: language), name))
        // A counted item never acts, or asks, without its count.
        #expect(chosen(more).isEmpty)
        return await more.items.first?.counted()
    }

    @Test("Let these go asks about the count at the press, not the figure the row drew",
          arguments: [DummyLanguage.english, .taiwanese])
    func spanLetGo(_ language: DummyLanguage) async {
        var went = 0
        var none = 0
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let ask = SpanAsk(from: day, to: day, host: "one.example")
        // The row drew 2; by the press the store holds 5, one of them kept.
        let more = SpanSection.more(
            ask, figure: 2, count: { _ in (posts: 5, kept: 1) }, none: { none += 1 }, go: { went += 1 },
            language: language
        )
        #expect(more.head.isEmpty)
        let put = await counted(more, symbol: "trash", named: L10n.t("usage.span.now", language: language), language: language)
        #expect(put?.question == ShellQuestion.letGo(ask.counting(5, kept: 1), language: language))
        #expect(put?.question != ShellQuestion.letGo(ask.counting(2), language: language))
        #expect(went == 0 && none == 0)
        put?.answered("not the yes")
        #expect(went == 0)
        put?.answered(ShellQuestion.yes)
        #expect(went == 1)
    }

    @Test("A span that held posts when drawn and holds none at the press says so, and asks nothing")
    func spanEmptiedSinceDrawn() async {
        var went = 0
        var none = 0
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let more = SpanSection.more(
            SpanAsk(from: day, to: day, host: nil), figure: 3, count: { _ in (posts: 0, kept: 0) },
            none: { none += 1 }, go: { went += 1 }
        )
        #expect(await more.items[0].counted() == nil)
        #expect(none == 1 && went == 0)
    }

    @Test("With nothing on its days the span's item is dim, and the head says there is nothing — not \"not right now\"",
          arguments: [DummyLanguage.english, .taiwanese])
    func spanWithNothing(_ language: DummyLanguage) async {
        var counts = 0
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        for figure in [Int?.none, 0] {
            let more = SpanSection.more(
                SpanAsk(from: day, to: day, host: nil), figure: figure,
                count: { _ in counts += 1; return (posts: 9, kept: 0) }, none: {}, go: {}, language: language
            )
            #expect(more.head == [L10n.t("usage.span.none", language: language)])
            let item = more.items[0]
            #expect(item.look == .dim(.notNow) && !item.answers && more.dangers.count == 1)
            #expect(item.title(language: language) == L10n.t("usage.span.now", language: language))
            #expect(chosen(more).isEmpty)
            #expect(await item.counted() == nil)
        }
        #expect(counts == 0, "a dim item counted")
    }

    @Test("A span's figure read for days no longer picked does not land")
    func anOvertakenReadDoesNotLand() async {
        #expect(await SpanSection.landed { 7 } == 7)

        let gate = Gate()
        let started = Gate()
        let read = Task { @MainActor in
            await SpanSection.landed {
                await started.open()
                await gate.wait()
                return 7
            }
        }
        await started.wait()
        // The pickers moved while the store was counting: the task is cancelled, and its answer —
        // which still arrives — is about another span.
        read.cancel()
        await gate.open()
        #expect(await read.value == nil)
    }

    @Test("Drop picture copies is the one item of the copies line's …", arguments: [DummyLanguage.english, .taiwanese])
    func dropCopies(_ language: DummyLanguage) {
        var dropped = 0
        asksFirst(
            UsagePane.copiesMore(language: language) { dropped += 1 }, symbol: "trash",
            named: L10n.t("prefs.drop.copies", language: language),
            question: ShellQuestion.dropCopies(language: language), language: language
        ) { dropped }
    }

    // MARK: - The timeline editor

    @Test("Remove timeline is the one item of the timeline tab's …, asking what ⌘⌫ asks", arguments: [DummyLanguage.english, .taiwanese])
    func removeTimeline(_ language: DummyLanguage) {
        var removed = 0
        var built = 0
        let question = ShellQuestion.removeTimeline(named: "Art", language: language)
        let more = TimelineEditor.removeMore(
            asks: { built += 1; return question }, language: language, remove: { removed += 1 }
        )
        #expect(built == 0, "the question was built before the item was chosen")
        asksFirst(
            more, symbol: "trash", named: L10n.t("timeline.remove", language: language), question: question,
            language: language
        ) { removed }
    }

    @Test("Remove rule is in …, an ordinary item that asks nothing: a rule only leaves the draft")
    func removeRule() {
        var removed = 0
        let more = TimelineEditor.ruleMore(language: .english) { removed += 1 }
        #expect(more.items.map(\.symbol) == ["trash"])
        #expect(more.dangers.isEmpty, "red without a question")
        #expect(more.items.first?.question == nil)
        #expect(more.label(language: .english) == "More: Remove rule")
        #expect(chosen(more).isEmpty)
        #expect(removed == 1)
    }

    // MARK: - A host the person added

    @Test("Remove is the one item of an added host's …, under the bin, and now asks first", arguments: [DummyLanguage.english, .taiwanese])
    func removeOwnHost(_ language: DummyLanguage) {
        var removed = 0
        let entry = Allowance.own(host: "img.example", for: "forum.example")
        let question = ShellQuestion.removeOwnHost("img.example", language: language)
        #expect(question.title.contains("img.example") && question.warns && question.cancel != nil)
        asksFirst(
            OwnHostDetail.more(entry, language: language) { removed += 1 }, symbol: "trash",
            named: String(format: L10n.t("allow.own.remove", language: language), "img.example"),
            question: question, language: language
        ) { removed }
    }

    // MARK: - Nothing left standing

    /// **A tripwire and not proof**: it reads the spellings it lists. The three glyphs that say
    /// "this takes something away" are written only where a press asks first — as the glyph of a
    /// `danger` item, or of the question itself — and at the sites named here, each stated.
    @Test("No destructive button stands on its own in the shell, and the glyphs of taking away are written only where a press asks first")
    func nothingStandsOnItsOwn() throws {
        // The tables a `danger` item's mark reads its glyph from, and the one ordinary item
        // that wears the trash: taking a rule out of a draft, which nothing is lost by until
        // the draft is saved (`RuleFormFoot`).
        let stated: [String: [String]] = [
            "ItemActs.swift": [#"case .withdraw: return "trash""#],
            "SourceRow.swift": [#"case .clear: "eraser""#, #"case .remove: "trash""#],
            "TimelineEditor.swift": [#".plain("trash", L10n.t("rule.action.remove""#],
        ]
        let files = try #require(FileManager.default.enumerator(at: ShellSource.root, includingPropertiesForKeys: nil))
        var read = 0
        var found = 0
        for case let file as URL in files where file.pathExtension == "swift" {
            let name = file.lastPathComponent
            let text = try String(contentsOf: file, encoding: .utf8)
            read += 1
            // The two places a destructive role is given: an item of `…`, and a question's yes.
            if !["ShellMark.swift", "ShellConfirm.swift"].contains(name) {
                #expect(!text.contains("Button(role: .destructive"), "\(name) draws a destructive button")
            }
            guard name != "ShellQuestions.swift" else { continue }
            for glyph in [#""trash""#, #""eraser""#, #""key.slash""#] {
                var from = text.startIndex
                while let at = text.range(of: glyph, range: from ..< text.endIndex) {
                    from = at.upperBound
                    found += 1
                    let before = text[..<at.lowerBound]
                    let asksFirst = before.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(".danger(")
                    let line = text[text.lineRange(for: at)]
                    let isStated = stated[name, default: []].contains { line.contains($0) }
                    #expect(asksFirst || isStated, "\(name) writes \(glyph) outside a danger item: \(line)")
                }
            }
        }
        #expect(read > 50 && found >= 10, "the sweep read \(read) files and found \(found) glyphs")
    }
}
