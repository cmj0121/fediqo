import FediqoCore
import SwiftUI

// What the person set at a source for the posts they write there (#321), as that source's own
// page draws it: a block "You there", only where the reader is signed in to the source — who a
// new post is for, its language, and whether its media is covered, each a fact with its name.
//
// **Said as what the source uses, not as what the person chose.** Its answer cannot tell a thing
// set from a thing defaulted: where nothing was chosen it still gives a reach, a covering and a
// language — the language following the one this device asks in. So no sentence here says
// "you set".
//
// **Read only, except one choice.** What the person set there is changed there, and nothing
// here starts a post. The one control is whether this source is told where Home was left
// (#316), and it stays off until that is chosen.
//
// **Each value is the source's word about the person's own settings.** The ones this app has
// words for are said in them — a reach as a row's is, a language by its name in the shell's
// language; one it does not know is shown as the source wrote it, already made fit for a line.
// A setting the source did not say is not listed, and where it said none of the three the
// block says so.
//
// **A sign-in that was not given this says so in one sentence and offers no press.** A failure
// says so in full ink with the press that asks again.

extension YouThereSaid {
    /// One of the three things read, in the order they are drawn.
    enum Fact: String, Hashable, CaseIterable {
        case reach, language, media
    }

    // MARK: - Words

    static func title(language: DummyLanguage? = nil) -> String {
        L10n.t("source.you.title", language: language)
    }

    static func line(_ source: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("source.you.line", language: language), source)
    }

    static func help(_ source: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("source.you.help", language: language), source)
    }

    static func askingLine(_ source: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("source.you.asking", language: language), source)
    }

    static func notGiven(_ source: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("source.you.notGiven", language: language), source)
    }

    static func failed(_ source: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("source.you.failed", language: language), source)
    }

    /// What stands where the facts would, where the source answered and said none of them.
    static func nothing(_ source: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("source.you.none", language: language), source)
    }

    /// What a fact is called.
    static func label(_ fact: Fact, language: DummyLanguage? = nil) -> String {
        L10n.t("source.you.\(fact.rawValue)", language: language)
    }

    /// Who a new post is for: the word a row says a post's reach in, or — for a reach this
    /// build does not know — the source's own word, which was made fit for a line as it entered.
    static func reach(_ reach: PostingDefaults.Reach, language: DummyLanguage? = nil) -> String {
        switch reach {
        case .known(let audience): L10n.t("item.visibility.\(audience.rawValue)", language: language)
        case .other(let word): word
        }
    }

    /// A language by its name in the shell's language, or — for a tag no name is known for —
    /// the tag as the source wrote it.
    static func languageName(_ tag: String, language: DummyLanguage? = nil) -> String {
        // Only what a tag is made of is looked up; anything else is the source's word, as is.
        guard tag.utf8.allSatisfy({ ($0 | 0x20 >= 97 && $0 | 0x20 <= 122) || (48...57).contains($0) || $0 == 45 }),
              let name = L10n.locale(language).localizedString(forIdentifier: tag), !name.isEmpty
        else { return tag }
        return name
    }

    static func media(covered: Bool, language: DummyLanguage? = nil) -> String {
        L10n.t(covered ? "source.you.media.covered" : "source.you.media.open", language: language)
    }

    /// The facts the source said, each with what it says, in the order they are drawn. A fact
    /// it did not say is not here.
    static func facts(of set: PostingDefaults, language: DummyLanguage? = nil) -> [(fact: Fact, value: String)] {
        var facts: [(fact: Fact, value: String)] = []
        if let reach = set.reach { facts.append((.reach, Self.reach(reach, language: language))) }
        if let tag = set.language { facts.append((.language, languageName(tag, language: language))) }
        if let covered = set.coversMedia { facts.append((.media, media(covered: covered, language: language))) }
        return facts
    }
}

/// The block a source's page draws of what the person set there.
///
/// It draws what it is handed and asks nothing: the asking is `ShellYouThere`'s.
struct YouThereSection: View {
    let said: YouThereSaid
    /// A failure's "Try again".
    var onAgain: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ShellRule()
        VStack(alignment: .leading, spacing: ShellSpace.step) {
            ShellSectionHead(
                YouThereSaid.title(), line: YouThereSaid.line(said.source), help: YouThereSaid.help(said.source)
            )
            switch said.reading {
            case .asking:
                // Said only while there is an ask to wait for: one that was stopped says nothing.
                if said.asking { ShellStatusLine(YouThereSaid.askingLine(said.source)) }
            case .said(let set):
                facts(YouThereSaid.facts(of: set))
            case .notGiven:
                sentence(YouThereSaid.notGiven(said.source), ink: ShellChrome.inkDim(colorScheme))
            case .failed:
                failure
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ShellSpace.pad)
    }

    @ViewBuilder
    private func facts(_ facts: [(fact: YouThereSaid.Fact, value: String)]) -> some View {
        if facts.isEmpty {
            sentence(YouThereSaid.nothing(said.source), ink: ShellChrome.inkFaint(colorScheme))
        } else {
            ForEach(facts, id: \.fact) { entry in
                ShellDetailFact(label: YouThereSaid.label(entry.fact), value: entry.value)
            }
        }
    }

    /// What could not be asked, in full ink, and the press that asks again: side by side where
    /// they fit, the press under the words where they do not.
    private var failure: some View {
        let words = Text(YouThereSaid.failed(said.source))
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.ink(colorScheme))
        let retry = ShellLinkButton(L10n.t("person.retry"), action: onAgain)
            .disabled(said.asking)
            .fixedSize()
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
                words.fixedSize()
                Spacer(minLength: 0)
                retry
            }
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                words.fixedSize(horizontal: false, vertical: true)
                retry
            }
        }
    }

    private func sentence(_ text: String, ink: Color) -> some View {
        Text(text)
            .shellFont(.meta)
            .foregroundStyle(ink)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// That block on a joined source's page: what `ShellYouThere` hands for the host, drawn — and
/// **the asking that is the page opening**, once a run for a host. Nothing is drawn, and nobody
/// asked, for a source the reader is not signed in to or the pages hand nothing for.
struct YouThereBlock: View {
    let host: String
    let you: ShellYouThere
    let session: ShellSession

    var body: some View {
        if let said = you.said(at: host, in: session) {
            VStack(alignment: .leading, spacing: 0) {
                YouThereSection(said: said, onAgain: { Task { await you.again(host, in: session) } })
                HomeStoppedControl(host: host, session: session)
            }
            .task(id: you.opening(host, in: session)) { await you.opened(host, in: session) }
        }
    }
}

/// Whether this Mastodon is told where Home was left (#316). Dim, with the acting part's own
/// sentence, until that part is held: the press asks, and the choice is not written down before.
struct HomeStoppedControl: View {
    let host: String
    let session: ShellSession
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let offer = session.homePlace.offer(host: host, in: session) {
            switch offer.shape {
            case .locked(let sentence):
                Button(sentence) { session.homePlace.pressLocked(host: host, in: session) }
                    .buttonStyle(.plain)
                    .shellFont(.reading)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(sentence)
                    .padding(.horizontal, ShellSpace.pad)
                    .padding(.bottom, ShellSpace.step)
            case .toggle:
                let title = String(format: L10n.t("source.you.stopped"), host)
                Toggle(title, isOn: Binding(
                    get: { session.stopped.hosts.contains(host.lowercased()) },
                    set: { on in Task { await session.homePlace.setOn(on, host: host, in: session) } }
                ))
                .shellFont(.reading)
                .shellHelp(verbatim: String(format: L10n.t("source.you.stopped.help"), host), about: title)
                .padding(.horizontal, ShellSpace.pad)
                .padding(.bottom, ShellSpace.step)
            }
        }
    }
}
