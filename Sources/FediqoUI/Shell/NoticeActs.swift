import FediqoCore
import SwiftUI

/// What the notices page offers to do, and how it says each (#323): the menus behind its three
/// dots — a line's, the head's and a held-back request's — and the sentences about what a
/// source holds back and what an act came to. Functions of the session, so every menu and every
/// sentence can be asked for without drawing a row.
///
/// **An act is offered only where the sign-in may act.** Dismissing, letting through and
/// letting go change the source, so a sign-in that only reads is shown the item dim, with the
/// reason at the menu's head — the place a finger reads it.
@MainActor
enum NoticeActs {
    static let dismissSymbol = "bell.slash"
    static let throughSymbol = "tray.and.arrow.down"

    /// Somebody as a request's row names them (`NoticeWords.name`).
    static func name(_ person: NoticePerson) -> String {
        NoticeWords.name(person)
    }

    /// Why the sign-in on `host` may not act on its notices, or nothing where it may: it was
    /// made to read only, or it acts and the source did not let it act on notices.
    static func why(host: String, in session: ShellSession, language: DummyLanguage? = nil) -> String? {
        guard !session.mastodon.dismisses(host: host) else { return nil }
        let acts = session.mastodon.grants[host.lowercased()] == .writing
        return String(format: L10n.t(acts ? "notices.acts.why.notAllowed" : "notices.acts.why.reads", language: language), host)
    }

    private static func look(_ why: String?, busy: Bool) -> MarkLook {
        why != nil ? .dim(.never) : busy ? .dim(.notNow) : .live
    }

    private static func menu(_ items: [ShellMoreItem], why: String?) -> ShellMore {
        why.map { ShellMore(head: [$0], items: items.map(\.underHead)) } ?? ShellMore(items: items)
    }

    // MARK: - The menus

    /// A line's `…`: Dismiss, asked first. Dim while its dismissal is on the wire.
    static func more(_ notice: Notice, in session: ShellSession, language: DummyLanguage? = nil) -> ShellMore {
        let acts = session.noticeList.acts
        let why = why(host: notice.source.host, in: session, language: language)
        let dismiss = ShellMoreItem.danger(
            dismissSymbol, L10n.t("notices.dismiss", language: language),
            look: look(why, busy: acts.acting.contains(notice.id)),
            asks: ShellQuestion.dismiss(notice, language: language),
            act: { Task { await acts.dismiss(notice, in: session) } }
        )
        return menu([dismiss], why: why)
    }

    /// The head's `…`: dismissing all, **one item a source** — one press, one source, one
    /// request and one answer, so the question names exactly what goes and nothing is ever
    /// half done. A source whose sign-in may not dismiss is listed dim and named at the head
    /// with why: it is left alone. Nothing where no sign-in may read notices.
    ///
    /// `among` is `NoticesPane.hosts(in:)` where the caller has it worked out already.
    static func more(
        in session: ShellSession, among known: [(host: String, notices: NoticeStanding)]? = nil,
        language: DummyLanguage? = nil
    ) -> ShellMore? {
        let acts = session.noticeList.acts
        let hosts = (known ?? NoticesPane.hosts(in: session)).filter { $0.notices == .allowed }.map(\.host)
        guard !hosts.isEmpty else { return nil }
        var head: [String] = []
        let items = hosts.map { host -> ShellMoreItem in
            let why = why(host: host, in: session, language: language)
            let item = ShellMoreItem.danger(
                dismissSymbol, String(format: L10n.t("notices.dismissAll", language: language), host),
                look: look(why, busy: acts.acting.contains(ShellNoticeActs.all(host))),
                asks: ShellQuestion.dismissAll(host: host, language: language),
                act: { Task { await acts.dismissAll(host: host, in: session) } }
            )
            guard let why else { return item }
            head.append(why)
            return item.underHead
        }
        return ShellMore(head: head, items: items)
    }

    /// A held-back request's `…`: Let through and Let go, **each asked first**. Letting through
    /// takes nothing away, but the source then stops holding back what that person sends, and
    /// Fediqo cannot take that back (`ShellQuestion.letThrough`).
    static func more(_ request: NoticeRequest, in session: ShellSession, language: DummyLanguage? = nil) -> ShellMore {
        let acts = session.noticeList.acts
        let why = why(host: request.source.host, in: session, language: language)
        let look = look(why, busy: acts.acting.contains(request.id))
        let through = ShellMoreItem.danger(
            throughSymbol, L10n.t("notices.held.through", language: language), look: look,
            asks: ShellQuestion.letThrough(request, language: language),
            act: { Task { await acts.letThrough(request, in: session) } }
        )
        let go = ShellMoreItem.danger(
            dismissSymbol, L10n.t("notices.held.go", language: language), look: look,
            asks: ShellQuestion.letGo(request, language: language),
            act: { Task { await acts.letGo(request, in: session) } }
        )
        return menu([through, go], why: why)
    }

    /// `d` on the line the lamp is on: the question the line's own `…` puts, by pressing that
    /// menu's item — so the key and the menu cannot differ. Whether a question was put.
    @discardableResult
    static func askToDismiss(_ notice: Notice, in session: ShellSession) -> Bool {
        guard let dismiss = more(notice, in: session).items.first, dismiss.answers else { return false }
        dismiss.press { session.noticeList.acts.asked = $0 }
        return true
    }

    /// What a listener is offered of a menu, the row it belongs to being one element: each
    /// item by its name, and one that does nothing here with the menu's reason after it.
    static func spoken(_ item: ShellMoreItem, of more: ShellMore, language: DummyLanguage? = nil) -> String {
        guard !item.answers, let why = more.head.first else { return item.title(language: language) }
        return ShellMark.said(item.name, why, language: language)
    }

    // MARK: - The sentences

    /// What an act at `host` that changed nothing came to, in one sentence.
    static func words(_ said: ShellNoticeActs.Said, host: String, language: DummyLanguage? = nil) -> String {
        let key: String
        switch (said.act, said.why) {
        case (_, .locked): key = "notices.source.locked"
        case (.ask, _): key = "notices.ask.failed"
        case (let act, .refused): key = "notices.act.\(act).refused"
        case (let act, .unreachable): key = "notices.act.\(act).failed"
        case (let act, .declined): key = "notices.act.\(act).declined"
        case (let act, .unconfirmed): key = "notices.act.\(act).unconfirmed"
        }
        return String(format: L10n.t(key, language: language), host)
    }

    /// "a.example is holding back 3 notices." — how many, and from which source.
    static func words(_ held: NoticesHeld, host: String, language: DummyLanguage? = nil) -> String {
        ShellQuestion.counted("notices.held", max(held.notices, held.requests), host, language: language)
    }

    /// What is said of a request let through, until a read brings its notices.
    static func onItsWay(_ request: NoticeRequest, language: DummyLanguage? = nil) -> String {
        String(
            format: L10n.t("notices.held.onWay", language: language),
            NoticeWords.named(request.person, language: language), request.source.host
        )
    }

    static func count(_ request: NoticeRequest, language: DummyLanguage? = nil) -> String {
        L10n.count("notices.held.count", request.count, language: language)
    }

    /// The words of the last post among what is held, as one quiet run, where the source sent
    /// one — or what it was covered with, and never its words (`NoticeWords.excerpt(of:)`).
    static func excerpt(_ request: NoticeRequest, language: DummyLanguage? = nil) -> String? {
        NoticeWords.excerpt(of: request.lastPost, language: language)
    }

    /// A request as a listener hears it: who, how many, and the last one's words.
    static func spoken(_ request: NoticeRequest, language: DummyLanguage? = nil) -> String {
        let who = String(
            format: L10n.t("notices.held.spoken", language: language), name(request.person), count(request, language: language)
        )
        return excerpt(request, language: language).map {
            String(format: L10n.t("notices.spoken.post", language: language), who, $0)
        } ?? who
    }

    /// The press on a source's held-back line, and what it is called to a listener.
    static func toggle(open: Bool, host: String, language: DummyLanguage? = nil) -> (word: String, spoken: String) {
        let key = open ? "notices.held.hide" : "notices.held.show"
        return (L10n.t(key, language: language), String(format: L10n.t(key + ".spoken", language: language), host))
    }
}

/// One source's word that it is holding notices back: a quiet line above the list, and the
/// press that opens what it holds.
///
/// A source line's own shape (`WordsThenPress`): on one line with its press where both fit
/// whole, the press under the words where they do not, and neither cut.
struct NoticeHeldLine: View {
    let host: String
    let held: NoticesHeld
    let open: Bool
    let onToggle: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.shellNoticesProbe) private var probe

    var body: some View {
        let words = NoticeActs.words(held, host: host)
        WordsThenPress(words: said(words), press: press)
            .modifier(NoticesProbed(.held(host), says: words, probe: probe))
    }

    private func said(_ words: String) -> some View {
        Label(words, systemImage: "tray")
            .labelStyle(.titleAndIcon)
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
            .modifier(NoticesProbed(.heldWords(host), probe: probe))
    }

    private var press: some View {
        let toggle = NoticeActs.toggle(open: open, host: host)
        return ShellLinkButton(toggle.word, action: onToggle)
            .accessibilityLabel(toggle.spoken)
            .help(toggle.spoken)
            .fixedSize()
            .modifier(NoticesProbed(.heldPress(host), says: toggle.spoken, probe: probe))
    }
}

/// One person's notices a source is holding back: who, how many, the last one's words, and
/// what can be done behind three dots.
///
///     who                                                     […]
///     3 notices held
///     the last one's words, two lines at most
///
/// One element to a listener, with the menu's items as its actions.
struct NoticeRequestRow: View {
    let request: NoticeRequest
    let more: () -> ShellMore
    let asks: Binding<ShellMoreAsk?>
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.shellNoticesProbe) private var probe

    var body: some View {
        let spoken = NoticeActs.spoken(request)
        HStack(alignment: .top, spacing: ShellSpace.snug) {
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                Text(NoticeActs.name(request.person))
                    .shellFont(.name)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                Text(NoticeActs.count(request))
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                if let excerpt = NoticeActs.excerpt(request) {
                    Text(excerpt)
                        .shellFont(.body)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                        .lineLimit(NoticeRow.excerptLines)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(NoticesProbed(.requestWords(request.id), probe: probe))
            ShellMoreButton(label: ShellMore.label(), asks: asks, more: more)
                .fixedSize()
                .modifier(NoticesProbed(.requestMore(request.id), probe: probe))
        }
        .padding(.horizontal, ShellSpace.pad)
        .padding(.vertical, ShellSpace.snug)
        .contentShape(Rectangle())
        .modifier(NoticeRowMenu(menu: NoticeRow.Menu(more: more, asks: asks)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityActions { NoticeMenuActions(more: more, asks: asks) }
        .modifier(NoticesProbed(.request(request.id), says: spoken, probe: probe))
    }
}

/// A `…` menu's items as the named actions of the element that owns it: what a listener, who
/// cannot land on a control inside one element, is offered in its place.
struct NoticeMenuActions: View {
    let more: () -> ShellMore
    let asks: Binding<ShellMoreAsk?>

    var body: some View {
        let menu = more()
        ForEach(Array(menu.items.enumerated()), id: \.offset) { _, item in
            Button(NoticeActs.spoken(item, of: menu)) { item.press { asks.wrappedValue = $0 } }
        }
    }
}
