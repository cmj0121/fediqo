import FediqoCore
import SwiftUI

/// Every question the app asks before something that cannot be undone, and the two notices that
/// share its sheet (#238) — **what each says, in one place and in words a test can read.**
///
/// Each is a `ShellConfirmation`: a title naming the act, one line saying what will happen, and
/// what the question used to say at length behind its (?). The long text is the key it always
/// was; the line is new. The screens that ask only hand these the facts they already hold.
///
/// `language` is threaded for the tests, as `ItemActs.withdrawQuestion` threads it; nothing
/// means the shell's own.
@MainActor
enum ShellQuestion {
    /// The id every one-yes question answers with.
    static let yes = "yes"

    /// Taking back what the reader wrote (#109). `copy` is the copy that goes (#136): its words
    /// and its host are what is named.
    static func withdraw(_ copy: DummyItem, language: DummyLanguage? = nil) -> ShellConfirmation {
        let words = ItemActs.withdrawQuestion(copy, language: language)
        return ShellConfirmation(
            symbol: "arrow.uturn.backward", title: words.title,
            line: String(format: L10n.t("withdraw.line", language: language), copy.source.host),
            help: words.detail,
            choices: [.init(yes, L10n.t("withdraw.confirm", language: language), role: .destructive)],
            cancel: L10n.t("compose.cancel", language: language)
        )
    }

    /// Removing a source. The boards it takes do not come back, so where there are any the line
    /// itself names them; the (?) says the rest.
    static func remove(host: String, boards: Int, language: DummyLanguage? = nil) -> ShellConfirmation {
        ShellConfirmation(
            symbol: "trash", title: String(format: L10n.t("account.remove.title", language: language), host),
            line: boards > 0
                ? String(format: L10n.t("account.remove.line.boards", language: language), boards)
                : L10n.t("account.remove.detail", language: language),
            help: boards > 0
                ? String(format: L10n.t("account.remove.detail.boards", language: language), boards) : nil,
            choices: [.init(yes, L10n.t("account.remove.confirm", language: language), role: .destructive)],
            cancel: L10n.t("board.choose.cancel", language: language)
        )
    }

    /// Clearing what a source left here. `detailKey` is `SourceRow.clearDetailKey`'s answer for
    /// this host; the line follows it, so a saved password's going is said on the line itself.
    ///
    /// **Keyed and not destructive**, for decision 29's reason: the weight of the yes matches the
    /// weight of the act, and most of what Clear drops comes back — so ⌘Return answers it, and it
    /// is drawn as a plain press. **Except where a saved password goes**: that does not come back,
    /// so that Clear is a loss, drawn and chorded (⌘D) as one.
    static func clear(host: String, detailKey: String, language: DummyLanguage? = nil) -> ShellConfirmation {
        ShellConfirmation(
            symbol: "eraser", title: String(format: L10n.t("account.clear.title", language: language), host),
            line: L10n.t(clearLineKey(detailKey), language: language),
            help: L10n.t(detailKey, language: language),
            choices: [.init(
                yes, L10n.t("account.clear.confirm", language: language),
                role: detailKey == SourceRow.clearDetailKey(hasPassword: true, reachedSignIn: false)
                    ? .destructive : .keyed
            )],
            cancel: L10n.t("board.choose.cancel", language: language)
        )
    }

    /// The line beside each of Clear's three long texts.
    static func clearLineKey(_ detailKey: String) -> String {
        detailKey.replacingOccurrences(of: "account.clear.detail", with: "account.clear.line")
    }

    /// Reading, or reading and writing, on a source being signed in to. Neither is a loss, and
    /// neither is lit: the narrower comes first and is the one a key answers (⌘Return), so the
    /// answer given without looking is the one that grants the least.
    static func signIn(host: String, language: DummyLanguage? = nil) -> ShellConfirmation {
        ShellConfirmation(
            symbol: "key", title: String(format: L10n.t("account.signin.ask.title", language: language), host),
            line: L10n.t("account.signin.ask.line", language: language),
            help: L10n.t("account.signin.ask.detail", language: language),
            choices: [
                .init(signInRead, L10n.t("account.signin.ask.read", language: language), role: .keyed),
                .init(signInWrite, L10n.t("account.signin.ask.write", language: language), role: .plain),
            ],
            cancel: L10n.t("board.choose.cancel", language: language)
        )
    }

    static let signInRead = "read"
    static let signInWrite = "write"

    /// Dropping every picture copy on this device.
    static func dropCopies(language: DummyLanguage? = nil) -> ShellConfirmation {
        ShellConfirmation(
            symbol: "trash", title: L10n.t("prefs.drop.copies.title", language: language),
            line: L10n.t("prefs.drop.copies.line", language: language),
            help: L10n.t("prefs.drop.copies.detail", language: language),
            choices: [.init(yes, L10n.t("prefs.drop.confirm", language: language), role: .destructive)],
            cancel: L10n.t("board.choose.cancel", language: language)
        )
    }

    /// Keeping fewer months than now.
    static func shorten(months: Int, language: DummyLanguage? = nil) -> ShellConfirmation {
        ShellConfirmation(
            symbol: "hourglass", title: L10n.count("prefs.keep.shorten.title", months, language: language),
            line: L10n.t("prefs.keep.shorten.line", language: language),
            help: L10n.t("prefs.keep.shorten.detail", language: language),
            choices: [.init(yes, L10n.t("prefs.drop.confirm", language: language), role: .destructive)],
            cancel: L10n.t("board.choose.cancel", language: language)
        )
    }

    /// Letting go now of `posts` posts deleted at their source and `places` settled places (#179,
    /// #204): each counted apart in the title, and the line saying only what goes of each.
    static func letGo(posts: Int, places: Int, language: DummyLanguage? = nil) -> ShellConfirmation {
        let line = places == 0 ? "prefs.gone.ask.line"
            : posts == 0 ? "prefs.gone.ask.line.placesonly" : "prefs.gone.ask.line.places"
        return ShellConfirmation(
            symbol: "trash", title: GoneSection.askLine(posts, places: places, language: language),
            line: L10n.t(line, language: language),
            help: GoneSection.askDetail(posts: posts, places: places, language: language),
            choices: [.init(yes, L10n.t("prefs.gone.confirm", language: language), role: .destructive)],
            cancel: L10n.t("board.choose.cancel", language: language)
        )
    }

    /// Removing a timeline. Its line already says it all, so there is no (?).
    static func removeTimeline(named name: String, language: DummyLanguage? = nil) -> ShellConfirmation {
        ShellConfirmation(
            symbol: "trash", title: String(format: L10n.t("timeline.remove.title", language: language), name),
            line: L10n.t("timeline.remove.detail", language: language), help: nil,
            choices: [.init(yes, L10n.t("timeline.remove.confirm", language: language), role: .destructive)],
            cancel: L10n.t("board.choose.cancel", language: language)
        )
    }

    /// A store written by a newer build: nothing to choose, one press to say it was read.
    static func storeNewer(language: DummyLanguage? = nil) -> ShellConfirmation {
        ShellConfirmation(
            symbol: "exclamationmark.triangle", title: L10n.t("store.newer.title", language: language),
            line: L10n.t("store.newer.line", language: language),
            help: L10n.t("store.newer.detail", language: language),
            choices: [], cancel: L10n.t("store.newer.ok", language: language)
        )
    }

    // MARK: - Taking away and reading back (#247, #252)

    static let withPictures = "with"
    static let withoutPictures = "without"

    /// Whether the picture copies ride, with what each would come to on the line. Neither is a
    /// loss; without is the one a key answers, being the smaller.
    static func takeAway(_ weight: PackageWeight, language: DummyLanguage? = nil) -> ShellConfirmation {
        ShellConfirmation(
            symbol: "square.and.arrow.up", title: L10n.t("carry.take.ask.title", language: language),
            line: String(
                format: L10n.t("carry.take.ask.line", language: language),
                UsagePane.size(weight.withPictures, language: language),
                UsagePane.size(weight.withoutPictures, language: language)
            ),
            help: L10n.t("carry.take.ask.help", language: language),
            choices: [
                .init(withoutPictures, L10n.t("carry.take.without", language: language), role: .keyed),
                .init(withPictures, L10n.t("carry.take.with", language: language), role: .plain),
            ],
            cancel: L10n.t("board.choose.cancel", language: language)
        )
    }

    /// #252's question: how many posts, from which sources, taken away when — and, where this
    /// device holds a store, that a yes replaces it, which is a loss and is drawn as one.
    static func readBack(_ summary: PackageSummary, held: Bool, language: DummyLanguage? = nil) -> ShellConfirmation {
        let sources = summary.sources.map(\.host).joined(separator: ", ")
        let day = summary.takenAt.formatted(
            Date.FormatStyle(date: .abbreviated, time: .omitted).locale(L10n.locale(language))
        )
        var help = String(
            format: L10n.t("carry.read.ask.help", language: language), sources, day, summary.device, summary.appVersion
        )
        if held { help = String(format: L10n.t("carry.read.ask.help.held", language: language), help) }
        return ShellConfirmation(
            symbol: "square.and.arrow.down",
            title: L10n.count("carry.read.ask.title", summary.posts, language: language),
            line: String(format: L10n.t("carry.read.ask.line", language: language), sources, day),
            help: help,
            choices: [held
                ? .init(yes, L10n.t("carry.read.replace", language: language), role: .destructive)
                : .init(yes, L10n.t("carry.read.go", language: language), role: .primary)],
            cancel: L10n.t("board.choose.cancel", language: language)
        )
    }

    /// Why a take-away or a read back stopped, each its own sentence, and nothing to choose.
    static func carryRefused(_ trouble: ShellCarry.Trouble, language: DummyLanguage? = nil) -> ShellConfirmation {
        let (key, line): (String, String)
        switch trouble {
        case .package(let refusal):
            key = "carry.refused.\(refusal)"
            line = L10n.t(key + ".line", language: language)
        case .noRoom(let needed, let free):
            key = "carry.refused.noRoom"
            line = String(
                format: L10n.t(key + ".line", language: language),
                UsagePane.size(needed, language: language), UsagePane.size(free, language: language)
            )
        case .emptyPassword:
            key = "carry.refused.empty"
            line = L10n.t(key + ".line", language: language)
        case .shortPassword:
            key = "carry.refused.short"
            line = String(format: L10n.t(key + ".line", language: language), PackageFormat.minPasswordCount)
        case .other(let said):
            key = "carry.refused.other"
            line = String(format: L10n.t(key + ".line", language: language), said)
        }
        return ShellConfirmation(
            symbol: "exclamationmark.triangle", title: L10n.t(key + ".title", language: language),
            line: line, help: nil, choices: [], cancel: L10n.t("store.newer.ok", language: language)
        )
    }

    /// It is done: taken away, or read back with the count.
    static func carryDone(_ done: ShellCarry.Done, language: DummyLanguage? = nil) -> ShellConfirmation {
        switch done {
        case .taken:
            ShellConfirmation(
                symbol: "checkmark.circle", title: L10n.t("carry.done.taken.title", language: language),
                line: L10n.t("carry.done.taken.line", language: language), help: nil, choices: [],
                cancel: L10n.t("store.newer.ok", language: language)
            )
        case .readBack(let summary):
            ShellConfirmation(
                symbol: "checkmark.circle", title: L10n.t("carry.done.read.title", language: language),
                line: L10n.count("carry.done.read.line", summary.posts, language: language), help: nil, choices: [],
                cancel: L10n.t("store.newer.ok", language: language)
            )
        }
    }

    /// Sources that ended a sign-in on their own side.
    static func signedOut(hosts: [String], language: DummyLanguage? = nil) -> ShellConfirmation {
        let named = hosts.joined(separator: ", ")
        return ShellConfirmation(
            symbol: "person.crop.circle.badge.xmark",
            title: L10n.t("account.mastodon.ended.title", language: language),
            line: String(format: L10n.t("account.mastodon.ended.line", language: language), named),
            help: String(format: L10n.t("account.mastodon.ended.detail", language: language), named),
            choices: [], cancel: L10n.t("store.newer.ok", language: language)
        )
    }
}
