import FediqoCore
import SwiftUI

// What a source announces (#321), as that source's own page draws it: the first block of a
// joined source's page, only where the reader is signed in there. Each announcement is when it
// was announced or what time it is about, its words, and its reactions; New before the ones not
// seen on this device; Dismiss in its `…`, asked first; the dismissed folded under one line at
// the block's end.
//
// **Drawn from what it is handed**: the asking and the presses are `ShellAnnouncements`'s, and
// nothing here names a kind of source.

extension AnnouncementsSaid {
    // MARK: - Words

    static func title(language: DummyLanguage? = nil) -> String {
        L10n.t("announce.title", language: language)
    }

    static func line(_ source: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("announce.line", language: language), source)
    }

    static func help(_ source: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("announce.help", language: language), source)
    }

    static func askingLine(_ source: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("announce.asking", language: language), source)
    }

    static func failed(_ source: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("announce.failed", language: language), source)
    }

    static func forbidden(_ source: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("announce.forbidden", language: language), source)
    }

    static func dismissedLine(_ count: Int, language: DummyLanguage? = nil) -> String {
        L10n.count("announce.dismissed", count, language: language)
    }

    /// What a press that did not arrive says, under its announcement and aloud.
    static func missed(_ missed: Missed, _ source: String, language: DummyLanguage? = nil) -> String {
        switch missed {
        case .dismiss: String(format: L10n.t("announce.dismiss.failed", language: language), source)
        case .react(let name): String(format: L10n.t("announce.react.failed", language: language), name, source)
        case .unreact(let name): String(format: L10n.t("announce.unreact.failed", language: language), name, source)
        }
    }

    /// When it was announced, or the time it is about — dates alone where it is whole days —
    /// and when it was changed, where that is later. Empty where the source said none of it.
    static func when(
        _ announcement: Announcement, language: DummyLanguage? = nil, zone: TimeZone = .current
    ) -> String {
        let locale = L10n.locale(language)
        func moment(_ date: Date, whole: Bool) -> String {
            var style = whole
                ? Date.FormatStyle(date: .abbreviated, time: .omitted)
                : Date.FormatStyle(date: .abbreviated, time: .shortened)
            style.locale = locale
            style.timeZone = zone
            return date.formatted(style)
        }
        var parts: [String] = []
        switch (announcement.startsAt, announcement.endsAt) {
        case (let starts?, let ends?):
            parts.append(String(
                format: L10n.t("announce.span", language: language),
                moment(starts, whole: announcement.allDay), moment(ends, whole: announcement.allDay)
            ))
        case (let one?, nil), (nil, let one?):
            parts.append(moment(one, whole: announcement.allDay))
        case (nil, nil):
            if let published = announcement.publishedAt { parts.append(moment(published, whole: false)) }
        }
        if let updated = announcement.updatedAt, let published = announcement.publishedAt, updated > published {
            parts.append(String(format: L10n.t("announce.edited", language: language), moment(updated, whole: false)))
        }
        return parts.joined(separator: " · ")
    }

    /// What a listener is told of one announcement: New where it is, when, and its words.
    static func spoken(_ shown: Shown, language: DummyLanguage? = nil) -> String {
        let new = shown.new ? [L10n.t("announce.new", language: language)] : []
        let when = when(shown.announcement, language: language)
        return (new + [when, shown.announcement.words]).filter { !$0.isEmpty }
            .joined(separator: L10n.t("people.row.between", language: language))
    }

    /// What a reaction is called to a listener: its name and count, and that the reader is
    /// among them where they are.
    static func reactionSpoken(_ reaction: Reaction, language: DummyLanguage? = nil) -> String {
        let said = String(
            format: L10n.t("announce.reaction.spoken", language: language), reaction.name,
            L10n.grouped(reaction.count, language: language)
        )
        guard reaction.mine else { return said }
        return said + L10n.t("people.row.between", language: language) + L10n.t("announce.reaction.spoken.mine", language: language)
    }

    static func reactionHint(_ reaction: Reaction, language: DummyLanguage? = nil) -> String {
        reaction.mine
            ? L10n.t("announce.reaction.take.hint", language: language)
            : String(format: L10n.t("announce.reaction.add.hint", language: language), reaction.name)
    }

    static func reads(_ source: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("announce.react.reads", language: language), source)
    }

    /// The one emoji typed into Add a reaction's field, or nothing where it is not exactly one:
    /// one grapheme drawn as an emoji — its first scalar is one by default, or it asks to be one
    /// (U+FE0F) or joins several (U+200D). A digit, `#`, `*`, or a sign drawn as text by default
    /// (©, ®, ™, ‼) is not.
    static func oneEmoji(_ typed: String) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 1, let first = trimmed.unicodeScalars.first, first.properties.isEmoji, !first.isASCII
        else { return nil }
        let drawnAsEmoji = first.properties.isEmojiPresentation
            || trimmed.unicodeScalars.contains { $0.value == 0xFE0F || $0.value == 0x200D }
        return drawnAsEmoji ? trimmed : nil
    }

    /// Dismiss's question.
    static func dismissQuestion(_ source: String, language: DummyLanguage? = nil) -> ShellConfirmation {
        ShellConfirmation(
            symbol: AnnouncementsSection.symbol,
            title: String(format: L10n.t("announce.dismiss.ask.title", language: language), source),
            line: String(format: L10n.t("announce.dismiss.ask.line", language: language), source),
            help: nil,
            choices: [.init("dismiss", L10n.t("announce.dismiss", language: language), role: .keyed)]
        )
    }

    /// The `…` of one announcement: its head the `when` sentence — and, where the sign-in does
    /// not hold the account part, why Dismiss is dim — and Dismiss, asked first.
    @MainActor
    static func more(
        _ shown: Shown, source: String, lock: PartWords.Place?, onDismiss: @escaping () -> Void,
        onAsk: @escaping () -> Void, language: DummyLanguage? = nil
    ) -> ShellMore {
        let head = [when(shown.announcement, language: language)].filter { !$0.isEmpty }
        let name = L10n.t("announce.dismiss", language: language)
        guard let lock else {
            return ShellMore(head: head, items: [
                .danger(
                    AnnouncementsSection.dismissSymbol, name, asks: dismissQuestion(source, language: language),
                    act: onDismiss
                ),
            ])
        }
        let mark = ShellMark(AnnouncementsSection.dismissSymbol, name, look: .dim(lock.asks ? .askAgain : .notNow))
        let reason = String(format: L10n.t(lock.key, language: language), source)
        return ShellMore(head: head + [reason], items: [ShellMoreItem.plain(mark, ask: lock.asks ? onAsk : nil, act: {}).underHead])
    }
}

/// What the block's presses do, handed in by whoever holds the asking.
struct AnnouncementActs {
    var onAgain: () -> Void = {}
    var onFold: () -> Void = {}
    /// The yes to Dismiss's question, for the announcement of this id.
    var onDismiss: (String) -> Void = { _ in }
    /// The press on a dim Dismiss that asks the sign-in for the account part.
    var onAskAccount: () -> Void = {}
    /// A pill pressed: the reader's reaction of this name put on, or taken back.
    var onReact: (_ id: String, _ name: String) -> Void = { _, _ in }
    /// Add a reaction's Add: only ever put on.
    var onAdd: (_ id: String, _ name: String) -> Void = { _, _ in }
}

/// The block a source's page draws of what it announces. It draws what it is handed and asks
/// nothing.
struct AnnouncementsSection: View {
    let said: AnnouncementsSaid
    var acts = AnnouncementActs()

    nonisolated static let symbol = "megaphone"
    nonisolated static let dismissSymbol = "checkmark.circle"
    nonisolated static let newSymbol = "circle.fill"

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ShellRule()
        VStack(alignment: .leading, spacing: ShellSpace.step) {
            ShellSectionHead(
                AnnouncementsSaid.title(), line: AnnouncementsSaid.line(said.source),
                help: AnnouncementsSaid.help(said.source)
            )
            switch said.reading {
            case .asking:
                if said.asking { ShellStatusLine(AnnouncementsSaid.askingLine(said.source)) }
            case .forbidden:
                sentence(AnnouncementsSaid.forbidden(said.source), ink: ShellChrome.inkDim(colorScheme))
            case .failed:
                failure
            case .said:
                EmptyView()
            }
            ForEach(said.shown) { shown in
                if shown.id != said.shown.first?.id { ShellRule() }
                AnnouncementView(shown: shown, said: said, acts: acts, dismissed: false)
            }
            if !said.dismissed.isEmpty {
                if !said.shown.isEmpty { ShellRule() }
                foldLine
                if !said.folded {
                    ForEach(said.dismissed) { shown in
                        AnnouncementView(shown: shown, said: said, acts: acts, dismissed: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ShellSpace.pad)
    }

    private var foldLine: some View {
        Button(action: acts.onFold) {
            HStack(spacing: ShellSpace.tight) {
                Image(systemName: said.folded ? "chevron.right" : "chevron.down")
                Text(AnnouncementsSaid.dismissedLine(said.dismissed.count))
            }
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AnnouncementsSaid.dismissedLine(said.dismissed.count))
        .accessibilityValue(L10n.t(said.folded ? "announce.folded" : "announce.unfolded"))
    }

    private var failure: some View {
        let words = Text(AnnouncementsSaid.failed(said.source))
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.ink(colorScheme))
        let retry = ShellLinkButton(L10n.t("person.retry"), action: acts.onAgain)
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

/// One announcement: New and when, its words, its `…`, its reactions, and what a press that did
/// not arrive says.
private struct AnnouncementView: View {
    let shown: AnnouncementsSaid.Shown
    let said: AnnouncementsSaid
    let acts: AnnouncementActs
    /// Folded under the dismissed line: drawn quieter, with no `…`.
    let dismissed: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            HStack(alignment: .top, spacing: ShellSpace.snug) {
                VStack(alignment: .leading, spacing: ShellSpace.tight) {
                    head
                    EmojiText.words(
                        shown.announcement.words, emojis: shown.announcement.emojis, host: said.source, covered: false
                    )
                    .opacity(dismissed ? 0.75 : 1)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(AnnouncementsSaid.spoken(shown))
                .frame(maxWidth: .infinity, alignment: .leading)
                if !dismissed { more }
            }
            AnnouncementReactions(shown: shown, said: said, acts: acts)
            if let missed = shown.missed {
                Text(AnnouncementsSaid.missed(missed, said.source))
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var head: some View {
        let when = AnnouncementsSaid.when(shown.announcement)
        if shown.new || !when.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: ShellSpace.tight) {
                if shown.new {
                    Image(systemName: AnnouncementsSection.newSymbol)
                        .imageScale(.small)
                        .foregroundStyle(ShellChrome.ink(colorScheme))
                    Text(L10n.t("announce.new"))
                        .foregroundStyle(ShellChrome.ink(colorScheme))
                        .fontWeight(.semibold)
                }
                Text(when)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
            }
            .shellFont(.meta)
        }
    }

    private var more: some View {
        let shown = shown, said = said, acts = acts
        return ShellMoreButton(
            label: String(format: L10n.t("announce.more.spoken"), said.source)
        ) {
            AnnouncementsSaid.more(
                shown, source: said.source, lock: said.dismissLock, onDismiss: { acts.onDismiss(shown.id) },
                onAsk: acts.onAskAccount
            )
        }
        .fixedSize()
    }
}

/// An announcement's reactions, a pill each in the source's order, and Add a reaction — or, for
/// a sign-in that only reads, the same pills as words. They wrap whole.
private struct AnnouncementReactions: View {
    let shown: AnnouncementsSaid.Shown
    let said: AnnouncementsSaid
    let acts: AnnouncementActs

    @State private var adding = false

    var body: some View {
        if !shown.reactions.isEmpty || said.reacts {
            PillsWrap(spacing: ShellSpace.tight) {
                ForEach(shown.reactions) { reaction in
                    if said.reacts {
                        Button { acts.onReact(shown.id, reaction.name) } label: {
                            ReactionPill(reaction: reaction, source: said.source)
                        }
                        .buttonStyle(.plain)
                        .disabled(shown.pressing)
                        .help(AnnouncementsSaid.reactionSpoken(reaction))
                        .accessibilityLabel(AnnouncementsSaid.reactionSpoken(reaction))
                        .accessibilityHint(AnnouncementsSaid.reactionHint(reaction))
                        .accessibilityAddTraits(reaction.mine ? .isSelected : [])
                    } else {
                        ReactionPill(reaction: reaction, source: said.source)
                            .help(AnnouncementsSaid.reads(said.source))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(AnnouncementsSaid.reactionSpoken(reaction))
                            .accessibilityHint(AnnouncementsSaid.reads(said.source))
                    }
                }
                if said.reacts {
                    AddReactionButton(adding: $adding, pressing: shown.pressing) { name in
                        acts.onAdd(shown.id, name)
                    }
                }
            }
        }
    }
}

/// One reaction, on the well: its emoji — a custom one drawn from its picture, its name the
/// words where there is none — and the source's count. The reader's own on the lamp's wash,
/// the count heavier.
private struct ReactionPill: View {
    let reaction: AnnouncementsSaid.Reaction
    let source: String

    @Environment(\.colorScheme) private var colorScheme
    @ShellMetric(relativeTo: .caption2) private var sideways: CGFloat = DummyItemRow.Box.pillSideways
    @ShellMetric(relativeTo: .caption2) private var upright: CGFloat = DummyItemRow.Box.pillUpright

    var body: some View {
        HStack(spacing: ShellSpace.tight) {
            if let picture = reaction.picture {
                EmojiText(":\(picture.shortcode):", emojis: [picture], host: source, role: .meta)
            } else {
                Text(reaction.name).shellFont(.meta)
            }
            Text(L10n.compact(reaction.count))
                .shellFont(.mark)
                .fontWeight(reaction.mine ? .semibold : .regular)
                .foregroundStyle(reaction.mine ? ShellChrome.selectInk(colorScheme) : ShellChrome.inkDim(colorScheme))
        }
        .lineLimit(1)
        .padding(.horizontal, sideways)
        .padding(.vertical, upright)
        .background(Capsule(style: .continuous).fill(
            reaction.mine ? ShellChrome.selectFill(colorScheme) : ShellChrome.well(colorScheme)
        ))
        .contentShape(Capsule(style: .continuous))
    }
}

/// Add a reaction: the press, and the field it opens — a popover on a Mac, a medium sheet on a
/// phone. A view of its own, so the presenter's closure stands in this short body and in no long chain.
private struct AddReactionButton: View {
    @Binding var adding: Bool
    let pressing: Bool
    let add: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button { adding = true } label: {
            HStack(spacing: 1) {
                Image(systemName: "face.smiling")
                Image(systemName: "plus").imageScale(.small)
            }
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
            .modifier(ShellGlyphBox())
        }
        .buttonStyle(.plain)
        .disabled(pressing)
        .help(L10n.t("announce.react"))
        .accessibilityLabel(L10n.t("announce.react"))
        .popover(isPresented: $adding) { AnnounceReactField(adding: $adding, add: add) }
    }
}

/// One field the system's emoji picker fills, and Add — live only for exactly one emoji.
struct AnnounceReactField: View {
    @Binding var adding: Bool
    let add: (String) -> Void

    @State private var typed = ""
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let one = AnnouncementsSaid.oneEmoji(typed)
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            Text(L10n.t("announce.react"))
                .shellFont(.name)
                .foregroundStyle(ShellChrome.ink(colorScheme))
            HStack(spacing: ShellSpace.snug) {
                TextField(L10n.t("announce.react.field"), text: $typed)
                    .shellField(.alone)
                    .focused($focused)
                    .onSubmit { if let one { submit(one) } }
                Button(L10n.t("announce.react.add")) { if let one { submit(one) } }
                    .disabled(one == nil)
                    .keyboardShortcut(.defaultAction)
            }
            if !typed.isEmpty, one == nil {
                Text(L10n.t("announce.react.notOne"))
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
            }
        }
        .padding(ShellSpace.pad)
        .frame(minWidth: 260)
        .onAppear { focused = true }
        #if os(iOS)
        .presentationDetents([.medium])
        #endif
    }

    private func submit(_ name: String) {
        adding = false
        add(name)
    }
}

/// Pills laid out in rows, each whole: the next one goes on a new row where it does not fit.
struct PillsWrap: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let placed = Self.rows(subviews.map { $0.sizeThatFits(.unspecified) }, width: proposal.width, spacing: spacing)
        return placed.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let placed = Self.rows(sizes, width: bounds.width, spacing: spacing)
        for (subview, (origin, size)) in zip(subviews, zip(placed.origins, sizes)) {
            subview.place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height)
            )
        }
    }

    /// Where each pill goes at `width`, and the room they take: a pill wider than the width
    /// stands alone on its row, cut to it.
    static func rows(_ sizes: [CGSize], width: CGFloat?, spacing: CGFloat) -> (size: CGSize, origins: [CGPoint]) {
        let bound = width.flatMap { $0.isFinite ? $0 : nil } ?? .infinity
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, tallest: CGFloat = 0, widest: CGFloat = 0
        for size in sizes {
            let wide = min(size.width, bound)
            if x > 0, x + wide > bound {
                x = 0
                y += tallest + spacing
                tallest = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += wide + spacing
            tallest = max(tallest, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: sizes.isEmpty ? 0 : widest, height: sizes.isEmpty ? 0 : y + tallest), origins)
    }
}

/// That block on a joined source's page: what `ShellAnnouncements` hands for the host, drawn —
/// and **the asking that is the page opening**. Nothing is drawn for a source the reader is not
/// signed in to, a host with none, or a source that listed none.
struct AnnouncementsBlock: View {
    let host: String
    let announcements: ShellAnnouncements
    let session: ShellSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // What the opening's task hangs on, whether or not there is anything to draw.
            Color.clear.frame(height: 0).accessibilityHidden(true)
            if let said = announcements.said(at: host, in: session) {
                AnnouncementsSection(said: said, acts: acts)
            }
        }
        .task(id: ShellAnnouncements.opening(host, in: session)) { await announcements.opened(host, in: session) }
        .onDisappear { announcements.left(host) }
    }

    private var acts: AnnouncementActs {
        let host = host, announcements = announcements, session = session
        return AnnouncementActs(
            onAgain: { Task { await announcements.again(host, in: session) } },
            onFold: { announcements.fold(host) },
            onDismiss: { id in Task { await announcements.dismiss(id, at: host, in: session) } },
            onAskAccount: { session.askFor([.account], host: host) },
            onReact: { id, name in Task { await announcements.react(name, on: id, at: host, in: session) } },
            onAdd: { id, name in Task { await announcements.react(name, on: id, at: host, adding: true, in: session) } }
        )
    }
}
