import FediqoCore
import SwiftUI

/// Where a blog behind its author's password stands while the reader is typing it (#213).
enum ForumLock: Equatable, Sendable {
    /// The form is up and nothing has been tried.
    case asking
    /// A password is on its way to the forum and the blog is being read again.
    case trying
    /// The last one tried did not open it; the form is up again.
    case wrong
}

/// What a refusal may offer — **only what could help**, never a way to try again that is
/// guaranteed to change nothing (#213).
enum ForumRefusalAction: Hashable, Sendable {
    /// Read it again.
    case again
    /// The forum's own page, in the app's reader.
    case page
    /// Sign in to the forum, and read it again once signed in.
    case signIn
    /// The author's password, typed here.
    case password
}

/// Why a forum's blog or thread is not shown, said where its words would be — **one view for
/// both**, so a thread refused for a sign-in, standing, points, a price or being gone reads the
/// same way a blog does (#213).
///
/// **Each reason its own mark, its own sentence, and only its own help.** A reason is drawn as a
/// glyph and a sentence in the quiet register every forum condition uses (`ForumPostBand.said`),
/// what the forum asked for where it asked for something, and then the actions `actions(for:)`
/// allows and nothing else: sign in, the password, the page, or trying again — and for a post that
/// is gone, or a forum with its blogs switched off, nothing at all.
///
/// **The password is typed here and held here only while it is being typed.** The field's text is
/// handed to `onUnlock` and cleared in the same press, and cleared again when the view goes; it is
/// never put in a label, a hint, a sentence or a log.
struct ForumRefusalView: View {
    let absence: ForumPosts.Absence
    /// The forum's host, for the sentences that name it.
    let host: String
    /// This app's sentence for the reason — the caller's, which knows whether this is a blog or a
    /// thread for the reasons that are not the forum's own (`unreadable`, `unreachable`).
    let sentence: String
    /// The forum's own page, where the row names one this app will open.
    var page: URL?
    /// Where a password blog stands. Read only for `.refusal(.password)`.
    var lock: ForumLock = .asking
    var onAgain: () -> Void = {}
    var onSignIn: () -> Void = {}
    var onUnlock: (String) -> Void = { _ in }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.shellReader) private var reader
    @State private var password = ""

    var body: some View {
        let actions = Self.actions(for: absence)
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            said
            if actions.contains(.password) {
                passwordForm
            }
            let buttons = actions.subtracting([.password])
            if !buttons.isEmpty {
                HStack(spacing: ShellSpace.step) {
                    if buttons.contains(.signIn) {
                        button(String(format: L10n.t("refusal.signIn.action"), host), "person.crop.circle", onSignIn)
                    }
                    if buttons.contains(.again) {
                        button(L10n.t("refusal.again"), "arrow.clockwise", onAgain)
                    }
                    if buttons.contains(.page), let page {
                        button(L10n.t("blog.page"), "doc.richtext") { _ = reader?.open(page, from: host) }
                            .accessibilityHint(Text(L10n.t("refusal.page.hint")))
                    }
                }
            }
        }
        .padding(.top, ShellSpace.snug)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onDisappear { password = "" }
    }

    /// The mark, the sentence, and what the forum asked — **one element to VoiceOver**, read as
    /// the sentence and then the forum's own words.
    private var said: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            ForumPostBand.said(Self.glyph(for: absence), sentence, lines: nil, colorScheme: colorScheme)
            if let asked = Self.asked(in: absence) {
                Text(String(format: L10n.t("refusal.asked"), asked))
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .multilineTextAlignment(.leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Self.spoken(absence, sentence: sentence)))
    }

    /// The author's password, typed here: a secure field, a way to send it, and what became of
    /// the last one — trying, or not the right one.
    @ViewBuilder
    private var passwordForm: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            HStack(spacing: ShellSpace.snug) {
                SecureField(L10n.t("refusal.password.field"), text: $password)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .notOfferedToKeychain()
                    .frame(maxWidth: 280)
                    .disabled(lock == .trying)
                    .onSubmit(unlock)
                    .accessibilityLabel(Text(L10n.t("refusal.password.field")))
                button(L10n.t("refusal.password.open"), "lock.open", unlock)
                    .disabled(password.isEmpty || lock == .trying)
            }
            switch lock {
            case .asking:
                EmptyView()
            case .trying:
                ForumWaiting(line: L10n.t("refusal.password.trying"))
            case .wrong:
                ForumPostBand.said(
                    "exclamationmark.circle", L10n.t("refusal.password.wrong"), lines: nil, colorScheme: colorScheme
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(L10n.t("refusal.password.wrong")))
            }
            // One line; where the password goes and for how long is behind its (?) (#235).
            let note = String(format: L10n.t("refusal.password.line"), host)
            Text(note)
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                .shellHelp(verbatim: String(format: L10n.t("refusal.password.note"), host), about: note)
        }
    }

    private func unlock() {
        guard !password.isEmpty, lock != .trying else { return }
        let typed = password
        password = ""
        onUnlock(typed)
    }

    private func button(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .shellFont(.meta, weight: .medium)
        }
        .buttonStyle(.plain)
        .foregroundStyle(ShellChrome.selectInk(colorScheme))
    }

    // MARK: - The rules, without a screen

    /// What each reason offers. **No `default:`** — a reason added has to say what could help it.
    ///
    /// Trying again is offered only where the next read could come back different by itself: a
    /// network that was dark, a page this app could not read. Signing in is the whole of what a
    /// sign-in refusal offers, and the read after it is the sign-in's. A post that is gone and a
    /// forum with its blogs switched off offer nothing; standing, points and a price offer the
    /// page, where the forum can be asked in its own terms — never paid from here.
    static func actions(for absence: ForumPosts.Absence) -> Set<ForumRefusalAction> {
        switch absence {
        case .unreachable, .unreadable: [.again, .page]
        case .refused, .crowded: [.page]
        case .refusal(let refusal):
            switch refusal {
            case .signIn: [.signIn]
            case .password: [.password]
            case .privateToAuthor, .standing, .points, .price: [.page]
            case .gone, .blogsOff: []
            }
        }
    }

    /// Each reason's own mark. `gone` is the mark a post deleted at its source wears (#179).
    static func glyph(for absence: ForumPosts.Absence) -> String {
        switch absence {
        case .refused, .crowded: "exclamationmark.triangle"
        case .unreadable: "doc.questionmark"
        case .unreachable: "wifi.exclamationmark"
        case .refusal(let refusal):
            switch refusal {
            case .signIn: "person.crop.circle.badge.questionmark"
            case .password: "key"
            case .privateToAuthor: "eye.slash"
            case .gone: "xmark.bin"
            case .blogsOff: "nosign"
            case .standing: "lock.shield"
            case .points: "star.circle"
            case .price: "tag"
            }
        }
    }

    /// Each refusal's own sentence, the same for a blog and a thread.
    static func sentence(for refusal: DiscuzRefusal, language: DummyLanguage? = nil) -> String {
        switch refusal {
        case .signIn: L10n.t("refusal.signIn", language: language)
        case .password: L10n.t("refusal.password", language: language)
        case .privateToAuthor: L10n.t("refusal.private", language: language)
        case .gone: L10n.t("refusal.gone", language: language)
        case .blogsOff: L10n.t("refusal.blogsOff", language: language)
        case .standing: L10n.t("refusal.standing", language: language)
        case .points: L10n.t("refusal.points", language: language)
        case .price: L10n.t("refusal.price", language: language)
        }
    }

    /// What the forum itself asked for, where it asked for something.
    static func asked(in absence: ForumPosts.Absence) -> String? {
        guard case .refusal(let refusal) = absence else { return nil }
        switch refusal {
        case .standing(let asked), .points(let asked), .price(let asked):
            return asked.isEmpty ? nil : asked
        case .signIn, .password, .privateToAuthor, .gone, .blogsOff:
            return nil
        }
    }

    /// What VoiceOver reads for the reason: the sentence, then what the forum asked.
    static func spoken(_ absence: ForumPosts.Absence, sentence: String) -> String {
        guard let asked = asked(in: absence) else { return sentence }
        return sentence + " " + String(format: L10n.t("refusal.asked"), asked)
    }
}

private extension View {
    /// A password used once and never kept is not one the system should offer to save or fill:
    /// on iPhone, marked as a one-time code so no keychain save is asked (#213).
    @ViewBuilder
    func notOfferedToKeychain() -> some View {
        #if os(iOS)
        textContentType(.oneTimeCode)
        #else
        self
        #endif
    }
}
