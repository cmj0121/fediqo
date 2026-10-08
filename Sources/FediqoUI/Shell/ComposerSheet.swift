import FediqoCore
import SwiftUI

/// Compose over the current page. The same shape a reply will use: a sheet, not a destination.
struct ComposerSheet: View {
    @Environment(ShellSession.self) private var session
    @Environment(\.colorScheme) private var colorScheme

    /// What the sheet draws: empty is only when there is nothing to write to **and** nothing
    /// unsent and no refusal in hand. A source that stops being writable while the sheet is up
    /// must not swallow the draft into that notice.
    enum Surface: Equatable {
        case empty
        case composing
    }

    /// The source a press that could not send is said against: the one the composer was
    /// writing to.
    @MainActor
    static func failedAt(_ session: ShellSession) -> String? { session.composeHost }

    static func surface(offered: [Source], draft: String, failed: String?) -> Surface {
        if !offered.isEmpty { return .composing }
        if failed != nil { return .composing }
        if !trimmed(draft).isEmpty { return .composing }
        return .empty
    }

    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func remaining(_ text: String, limit: Int) -> Int {
        limit - trimmed(text).count
    }

    static func canSend(text: String, limit: Int, hasSource: Bool) -> Bool {
        let body = trimmed(text)
        return hasSource && !body.isEmpty && body.count <= limit
    }

    static func limitLine(remaining: Int, limit: Int) -> String {
        String(format: L10n.t("compose.limit"), remaining, limit)
    }

    static func visibilityKey(_ audience: Audience) -> String {
        switch audience {
        case .everyone: "compose.visibility.public"
        case .unlisted: "compose.visibility.unlisted"
        case .followers: "compose.visibility.private"
        case .mentioned: "compose.visibility.direct"
        }
    }

    var body: some View {
        @Bindable var session = session
        let offered = session.writableSources
        let host = session.composeHost
        let limit = host.map(session.postLimit(of:)) ?? MastodonWrite.defaultLimit
        WritingSheet(
            titleKey: "compose.title",
            sendKey: "compose.post",
            bodyKey: "compose.body",
            draft: $session.composeDraft,
            limit: limit,
            canSend: session.canPost,
            height: 400,
            hidesScrollIndicators: true,
            speaksLimitLine: true,
            writes: { failed in
                Self.surface(offered: offered, draft: session.composeDraft, failed: failed) == .composing
            },
            send: { session.send() },
            failedAt: { Self.failedAt(session) }
        ) { failed in
            if Self.surface(offered: offered, draft: session.composeDraft, failed: failed) == .empty {
                ShellNotice(
                    symbol: "square.and.pencil",
                    title: L10n.t("compose.none.title"),
                    detail: L10n.t("compose.none.detail")
                )
            } else if offered.isEmpty, failed == nil {
                Text(L10n.t("compose.none.detail"))
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            } else if !offered.isEmpty {
                ComposeChoices(session: session, offered: offered)
                .pickerStyle(.menu)
            }
        }
        .onAppear { session.prepareCompose() }
        .task(id: session.composeHost) { await session.refreshPostLimit() }
    }
}

/// Where a post goes and who may read it: the two choices above the composer's editor.
///
/// **Side by side where both are whole, and one over the other where they are not** (#302). On
/// a narrow phone the two together are wider than the sheet, and a menu squeezed there breaks
/// its host in the middle of a word. A Mac's sheet is a fixed 600 points, and an iPad's has
/// room: both draw them as they did.
private struct ComposeChoices: View {
    @Bindable var session: ShellSession
    let offered: [Source]

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        #if os(iOS)
        if sizeClass == .compact {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: ShellSpace.step) { choices }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: ShellSpace.tight) { choices }
            }
        } else {
            row
        }
        #else
        row
        #endif
    }

    private var row: some View {
        HStack(alignment: .firstTextBaseline, spacing: ShellSpace.step) { choices }
    }

    @ViewBuilder
    private var choices: some View {
        Picker(L10n.t("compose.source"), selection: $session.composeHost) {
            ForEach(offered, id: \.host) { source in
                Text(source.host).tag(Optional(source.host))
            }
        }
        .shellFont(.meta)
        .accessibilityLabel(L10n.t("compose.source"))
        Picker(L10n.t("compose.visibility"), selection: $session.composeAudience) {
            ForEach(Audience.allCases, id: \.self) { audience in
                Text(L10n.t(ComposerSheet.visibilityKey(audience))).tag(audience)
            }
        }
        .shellFont(.meta)
        .accessibilityLabel(L10n.t("compose.visibility"))
    }
}

/// What the composer and an answer share (#108): the limit line, the editor, and the one refusal
/// known at the press — **one sheet for the two**, where the answer used to re-implement the
/// composer's and had begun to drift from it.
///
/// **Nothing here waits.** The press hands the text to the outbox and the sheet closes
/// (`ShellSession.send`); no send is on the wire while a sheet is up, so Cancel and a swipe
/// always close it, and what comes of the send is said on the page (`SaidStrip`).
///
/// **The two drifts are parameters rather than fixed**, so each sheet keeps exactly what it drew:
/// the composer's editor draws no scroll indicators and its limit line is spoken as its own
/// label; the answer's does neither. What sits above the limit line is each sheet's own, and so
/// is whether the editor is drawn at all — the composer with nothing to write to and nothing in
/// hand draws only its notice.
struct WritingSheet<Above: View>: View {
    let titleKey: String
    let sendKey: String
    /// The editor's name to VoiceOver.
    let bodyKey: String
    let draft: Binding<String>
    let limit: Int
    let canSend: Bool
    let height: CGFloat
    let hidesScrollIndicators: Bool
    let speaksLimitLine: Bool
    /// Whether the editor is drawn, given the source a refused press is said against, if any.
    let writes: (String?) -> Bool
    /// The press: true where the outbox took the text, and the sheet closes; false where it
    /// could not be sent at all — no source to send through — and the draft is untouched.
    let send: @MainActor () -> Bool
    /// The source a refused press is said against, asked when it is refused.
    let failedAt: @MainActor () -> String?
    let above: (_ failed: String?) -> Above

    init(
        titleKey: String, sendKey: String, bodyKey: String, draft: Binding<String>, limit: Int,
        canSend: Bool, height: CGFloat, hidesScrollIndicators: Bool, speaksLimitLine: Bool,
        writes: @escaping (String?) -> Bool = { _ in true },
        send: @escaping @MainActor () -> Bool,
        failedAt: @escaping @MainActor () -> String?,
        @ViewBuilder above: @escaping (_ failed: String?) -> Above
    ) {
        self.titleKey = titleKey
        self.sendKey = sendKey
        self.bodyKey = bodyKey
        self.draft = draft
        self.limit = limit
        self.canSend = canSend
        self.height = height
        self.hidesScrollIndicators = hidesScrollIndicators
        self.speaksLimitLine = speaksLimitLine
        self.writes = writes
        self.send = send
        self.failedAt = failedAt
        self.above = above
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var compact: Bool { sizeClass == .compact }
    #endif
    @State private var failed: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: ShellSpace.step) {
                above(failed)
                if writes(failed) {
                    let remaining = ComposerSheet.remaining(draft.wrappedValue, limit: limit)
                    let line = ComposerSheet.limitLine(remaining: remaining, limit: limit)
                    Text(line)
                        .shellFont(.reading)
                        .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                        .modifier(SpokenAs(line: speaksLimitLine ? line : nil))
                    TextEditor(text: draft)
                        .shellFont(.body)
                        .scrollContentBackground(.hidden)
                        .modifier(HiddenIndicators(hidden: hidesScrollIndicators))
                        .foregroundStyle(ShellChrome.ink(colorScheme))
                        .accessibilityLabel(L10n.t(bodyKey))
                    if let failed {
                        ShellFailure(source: failed) {
                            run()
                        }
                        .frame(minHeight: 72)
                    }
                }
            }
            .padding(ShellSpace.step)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(ShellChrome.page(colorScheme))
            .navigationTitle(L10n.t(titleKey))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("compose.cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t(sendKey)) {
                        run()
                    }
                    .disabled(!canSend)
                    .accessibilityLabel(L10n.t(sendKey))
                }
            }
        }
        // **No floor where the page is compact** (#302): a phone's sheet is the screen's width
        // and this fills it. The floor there was wider than every phone, so Cancel, the send
        // and the pickers stood outside the sheet. An iPad with room keeps the floor it had.
        #if os(macOS)
        .frame(width: 600, height: height)
        #else
        .frame(minWidth: WritingRoom.floor(600, compact: compact), minHeight: WritingRoom.floor(height, compact: compact))
        #endif
    }

    /// The press: the outbox takes the text and the sheet closes, with nothing waited for.
    private func run() {
        if send() {
            dismiss()
        } else {
            failed = failedAt()
        }
    }
}

/// The limit line spoken as its own words, where a sheet asks for that.
private struct SpokenAs: ViewModifier {
    let line: String?

    func body(content: Content) -> some View {
        if let line {
            content.accessibilityLabel(Text(line))
        } else {
            content
        }
    }
}

/// The editor's scroll indicators hidden, where a sheet asks for that.
private struct HiddenIndicators: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        if hidden {
            content.scrollIndicators(.never)
        } else {
            content
        }
    }
}

/// The least a sheet for writing asks to be on an iPhone or an iPad (#302): what it always asked
/// where the page has room, and nothing where it is compact — there the sheet is the screen's
/// width, and a floor wider than the screen lays the sheet's contents out past both its edges.
enum WritingRoom {
    static func floor(_ asked: CGFloat, compact: Bool) -> CGFloat? {
        compact ? nil : asked
    }
}
