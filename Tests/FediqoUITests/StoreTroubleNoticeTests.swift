import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// What the person is told when this device's store did not simply open (#295): the words of
/// each notice, what it offers, and what putting it down or choosing answers.
///
/// What a test can reach: the notice as `ShellConfirmation` — title, line, detail, choices — in
/// every language, and the answer each way of leaving it gives. What it cannot: the sheet drawn
/// over the first frame, in light and dark, on a Mac and a phone.
@Suite("What is said of a store that did not open")
@MainActor
struct StoreTroubleNoticeTests {
    nonisolated private static let languages = [DummyLanguage.english, .taiwanese]
    private static let written = Date(timeIntervalSince1970: 1_800_000_000)
    private static let both = StoreTrouble.twoStores(
        inPlace: StoreGlance(written: written, posts: 2), setAside: StoreGlance(written: written, posts: 12)
    )
    private static let every: [StoreTrouble] = [
        .unreachable(.inUse), .unreachable(.noRoom), .unreachable(.outOfReach), .unreachable(.readBackInterrupted),
        .unreachable(.putAsideOnly), .unreachable(.otherComesBack),
        .damaged(replacedBy: .empty), .damaged(replacedBy: .otherStore), both,
        .twoStores(inPlace: StoreGlance(written: nil, posts: nil), setAside: StoreGlance(written: nil, posts: nil)),
    ]

    @Test("Each notice is a title, one line no wider than a line and a detail, in every language, and no two say the same", arguments: languages)
    func everyNotice(_ language: DummyLanguage) {
        var lines: Set<String> = []
        for trouble in Self.every {
            let notice = ShellQuestion.storeTrouble(trouble, language: language)
            for text in [notice.title, notice.line, notice.help ?? "", notice.cancel ?? ""] {
                #expect(!text.isEmpty && !text.contains("store.") && !text.contains("%"), "\(trouble): \(text)")
            }
            #expect(ShellQuestion.width(notice.line) <= ShellQuestion.lineLength, "\(notice.line) is more than a line")
            #expect(notice.help != notice.line)
            lines.insert(notice.line)
        }
        #expect(lines.count == Self.every.count)
    }

    @Test("A store out of reach says nothing was changed and asks nothing; each reason is its own sentence")
    func outOfReach() {
        for (why, said) in [
            (StoreTrouble.Unreachable.inUse, "Another copy of Fediqo is using it."),
            (.noRoom, "This device has no room left."),
            (.outOfReach, "Its folder could not be read or written."),
            (.readBackInterrupted, "A read back was interrupted."),
        ] {
            let notice = ShellQuestion.storeTrouble(.unreachable(why), language: .english)
            #expect(notice.title == "This device's store could not be opened")
            #expect(notice.line == said + " Nothing was changed.")
            #expect(notice.choices.isEmpty && !notice.warns)
            let detail = notice.help ?? ""
            #expect(detail.contains("What you do in Fediqo this time is not kept"), "\(why) reads as though nothing can be lost")
            #expect(!detail.contains("nothing here can be lost"))
        }
    }

    @Test("Where a damaged store was put aside and nothing could open, the notice does not say nothing was changed", arguments: languages)
    func somethingDidChange(_ language: DummyLanguage) {
        let unchanged = language == .english ? "Nothing was changed" : "沒有任何改變"
        for why in [StoreTrouble.Unreachable.putAsideOnly, .otherComesBack] {
            let notice = ShellQuestion.storeTrouble(.unreachable(why), language: language)
            #expect(!notice.line.contains(unchanged) && !(notice.help ?? "").contains(unchanged), "\(why)")
        }
        for why in [StoreTrouble.Unreachable.inUse, .noRoom, .outOfReach, .readBackInterrupted] {
            #expect(ShellQuestion.storeTrouble(.unreachable(why), language: language).line.contains(unchanged))
        }
        let english = ShellQuestion.storeTrouble(.unreachable(.putAsideOnly), language: .english)
        #expect(english.line == "It was damaged and has been put aside. Open Fediqo again.")
        #expect(ShellQuestion.storeTrouble(.unreachable(.otherComesBack), language: .english).line
            == "The store you chose was damaged. The other one comes back.")
    }

    @Test("A damaged store's notice says, on its line, what took its place and that the damaged one is deleted for good; behind it, that there is no getting it back; and it has a press of its own")
    func damaged() {
        let notice = ShellQuestion.storeTrouble(.damaged(replacedBy: .empty), language: .english)
        #expect(notice.title == "This device's store was damaged")
        #expect(notice.line == "An empty one took its place. The damaged one is deleted for good.")
        #expect(notice.help?.contains("There is no way to get it back") == true)
        #expect(notice.help?.contains("Once you press I understand and the new store has been saved") == true)
        #expect(notice.help?.contains("Put this notice down any other way and the damaged one is kept") == true)
        #expect(notice.choices.map(\.id) == [ShellQuestion.told] && notice.choices.first?.label == "I understand")
        #expect(notice.cancel == Optional("Not now"))
        let zh = ShellQuestion.storeTrouble(.damaged(replacedBy: .empty), language: .taiwanese)
        #expect(zh.line.contains("拿不回來") && zh.help?.contains("沒有辦法把它拿回來") == true)
        #expect(zh.choices.first?.label == "我知道了")
    }

    @Test("Where the other of two stores took the damaged one's place, the notice says that, and never that an empty one did", arguments: languages)
    func damagedAndTheOtherCameBack(_ language: DummyLanguage) {
        let notice = ShellQuestion.storeTrouble(.damaged(replacedBy: .otherStore), language: language)
        let all = notice.line + (notice.help ?? "")
        for untrue in ["An empty one", "opened with nothing", "一份空的", "以空的狀態"] {
            #expect(!all.contains(untrue), "\(untrue): \(all)")
        }
        #expect(notice.choices.map(\.id) == [ShellQuestion.told])
        #expect(ShellQuestion.storeTrouble(.damaged(replacedBy: .otherStore), language: .english).line
            == "The other store took its place. The damaged one is deleted for good.")
    }

    @Test("Two stores are said with what each holds; the one in place can always be kept, and the one set aside is offered where it could be glanced at")
    func twoStores() {
        let notice = ShellQuestion.storeTrouble(Self.both, language: .english)
        #expect(notice.title == "This device holds two stores")
        #expect(notice.line == "A read back was interrupted. Choose which one to keep.")
        #expect(notice.choices.map(\.id) == [ShellQuestion.keepInPlace, ShellQuestion.putBack])
        #expect(notice.choices.allSatisfy { $0.role == .destructive }, "either choice lets a store go")
        #expect(notice.cancel == Optional("Decide later"))
        let help = notice.help ?? ""
        #expect(help.contains("Where the store belongs: 2 posts, last written") && help.contains("12 posts, last written"))
        #expect(help.contains("cannot be got back") && help.contains("when you open Fediqo again"))

        let unread = StoreGlance(written: nil, posts: nil)
        let held = StoreGlance(written: Self.written, posts: 3)
        #expect(ShellQuestion.storeTrouble(.twoStores(inPlace: unread, setAside: held)).choices.map(\.id)
            == [ShellQuestion.keepInPlace, ShellQuestion.putBack])
        #expect(ShellQuestion.storeTrouble(.twoStores(inPlace: held, setAside: unread)).choices.map(\.id) == [ShellQuestion.keepInPlace])
    }

    @Test("Where neither store could be glanced at there is still a way out: the one in place can be kept, and the notice says what else to do", arguments: languages)
    func neitherCanBeRead(_ language: DummyLanguage) {
        let unread = StoreGlance(written: nil, posts: nil)
        let notice = ShellQuestion.storeTrouble(.twoStores(inPlace: unread, setAside: unread), language: language)
        #expect(notice.choices.map(\.id) == [ShellQuestion.keepInPlace], "nothing to press but Decide later, at every launch")
        #expect(notice.line == L10n.t("store.two.line.neither", language: language))
        let help = notice.help ?? ""
        #expect(help.contains(language == .english ? "open Fediqo again to look again" : "再打開 Fediqo 一次看看"))
        #expect(help.contains(language == .english ? "if it proves damaged the other is put back" : "另一份會被放回來"))
        #expect(!help.contains("%"))
    }

    @Test("A glance says how many posts and when it was last written, and of a store that would not say, that it cannot be read", arguments: languages)
    func glance(_ language: DummyLanguage) {
        let said = ShellQuestion.glance(StoreGlance(written: Self.written, posts: 12), language: language)
        #expect(said.contains("12") && said.contains("2027") && !said.contains("%"))
        #expect(ShellQuestion.glance(StoreGlance(written: nil, posts: 0), language: language)
            == L10n.t("prefs.held.posts.none", language: language))
        #expect(ShellQuestion.glance(StoreGlance(written: nil, posts: nil), language: language)
            == L10n.t("store.glance.unread", language: language))
    }

    @Test("Only a press on the notice answers it: being told is its own button, each store its own, and nothing else on a sheet is an answer")
    func theAnswers() {
        #expect(ShellQuestion.storeTroubleChose(ShellQuestion.told) == .told)
        #expect(ShellQuestion.storeTroubleChose(ShellQuestion.keepInPlace) == .keepInPlace)
        #expect(ShellQuestion.storeTroubleChose(ShellQuestion.putBack) == .putBack)
        #expect(ShellQuestion.storeTroubleChose(ShellQuestion.yes) == nil)
        // A notice that tells of a deletion must have the press that is being told.
        for replaced in [StoreTrouble.Replacement.empty, .otherStore] {
            let notice = ShellQuestion.storeTrouble(.damaged(replacedBy: replaced))
            #expect(notice.choices.compactMap { ShellQuestion.storeTroubleChose($0.id) } == [.told])
        }
    }

    @Test("A read back refused because the store did not open, and a take-away with nothing to take, each say so in a line of their own — from a file and from a device nearby", arguments: languages)
    func refusedForWantOfAStore(_ language: DummyLanguage) {
        var lines: Set<String> = []
        for notice in [
            ShellQuestion.carryRefused(.init(PackageFault.storeNotOpened), language: language),
            ShellQuestion.carryRefused(.init(PackageFault.nothingToTake), language: language),
        ] {
            #expect(!notice.title.contains("carry.") && !notice.line.contains("carry.") && !notice.line.contains("FediqoCore"))
            #expect(ShellQuestion.width(notice.line) <= ShellQuestion.lineLength, "\(notice.line)")
            lines.insert(notice.line)
        }
        #expect(lines.count == 2)
        #expect(ShellQuestion.nearbyRefused(.storeNotOpened, language: language)
            == ShellQuestion.carryRefused(.storeNotOpened, language: language))
        #expect(ShellQuestion.nearbyRefused(.nothingToTake, language: language)
            == ShellQuestion.carryRefused(.nothingToTake, language: language))
        #expect(ShellCarry.Trouble(PackageFault.storeNotOpened) == .storeNotOpened)
        #expect(ShellCarry.Trouble(PackageFault.nothingToTake) == .nothingToTake)
    }

    /// The sheet's own machinery, as the notice uses it: what reaches the answer when the
    /// question is put down, and when its button is pressed.
    @Test("Putting the notice down — Escape, a swipe, the sheet taken away — answers nothing; the press does, once")
    func puttingItDownIsNotAnAnswer() {
        var trouble: StoreTrouble? = .damaged(replacedBy: .empty)
        var answers: [StoreTroubleAnswer] = []
        let binding = Binding(get: { trouble }, set: { trouble = $0 })
        func settle(_ answer: ShellConfirmAnswer) {
            guard let asked = trouble else { return }
            ShellConfirmAnswer.settle(answer, asked: asked, item: binding) { _, id in
                if let chosen = ShellQuestion.storeTroubleChose(id) { answers.append(chosen) }
            }
        }
        settle(.cancel)
        #expect(trouble == nil && answers.isEmpty, "put down, and counted as told")

        // The binding cleared by something else entirely — another presenter, the view replaced.
        trouble = .damaged(replacedBy: .empty)
        binding.wrappedValue = nil
        #expect(answers.isEmpty)

        trouble = .damaged(replacedBy: .empty)
        settle(.choice(ShellQuestion.told))
        settle(.choice(ShellQuestion.told))
        #expect(answers == [.told])
    }
}
