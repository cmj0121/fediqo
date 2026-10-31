import FediqoCore
import Observation

/// Making an account at a Mastodon from the add-source flow (#435): the host's own form, and what
/// comes after it until the account works.
///
/// **The source is added, and anything is written, only at signed in.** Up to there what stands is
/// a registration and a token held here in memory: the registration is made afresh for this attempt
/// and not filed, and the token is never put in the Keychain, nor noted as one to end. **So stopping
/// at any point leaves this device as it was.** What it leaves elsewhere is said: a registration
/// nothing shows at the host, and from the form's sending on, the person's account there.
///
/// **One attempt at a time**: a press while another is on its page or at its mail does nothing, and
/// a look at the state that comes back after the person left lands nowhere (`attempt`).
///
/// **Asking for the mail again takes `write:accounts`**, asked of a real one (nightly 2026-10-30, a
/// token of exactly each answer's words): 403 `insufficient_scope` on the words of reading and of
/// reading and acting alone, 200 on either with that word. So the form asks it beside either answer
/// and the question says so; it stays with the sign-in as the profile part, which stands without acting.
@MainActor
@Observable
final class ShellSignUp {
    /// The read-or-act question, put before the form opens.
    struct Ask: Equatable {
        let preview: SourcePreview
        let terms: MastodonSignUp
        let invite: String?
    }

    /// The step that asks the person to open the mail the host sent, as a value.
    struct Mail: Identifiable, Equatable {
        enum Note: Equatable { case stillWaiting, unreachable, resent, resendFailed }

        let host: String
        var reading = false
        var resending = false
        var note: Note?

        var id: String { host }

        func title(language: DummyLanguage? = nil) -> String {
            L10n.t("account.signup.mail.title", language: language)
        }

        /// What it says, in the order it matters. The account stays whatever is done here, an early
        /// sign-in on the server's page has no way back, and a quit cannot end what was begun.
        func lines(language: DummyLanguage? = nil) -> [String] {
            ["account.signup.mail.line", "account.signup.mail.early", "account.signup.mail.stays", "account.signup.mail.quit"]
                .map { String(format: L10n.t($0, language: language), host) }
        }

        /// The one line the page draws of it.
        func heldLine(language: DummyLanguage? = nil) -> String {
            String(format: L10n.t("account.signup.held", language: language), host)
        }

        func noteWords(language: DummyLanguage? = nil) -> String? {
            let key: String? = switch note {
            case .stillWaiting: "account.signup.mail.note.waiting"
            case .unreachable: "account.signup.mail.note.unreachable"
            case .resent: "account.signup.mail.note.resent"
            case .resendFailed: "account.signup.mail.note.resendFailed"
            case nil: nil
            }
            return key.map { String(format: L10n.t($0, language: language), host) }
        }
    }

    /// What stands under the field once an attempt ended short of signed in.
    struct Told: Equatable {
        enum Kind: String { case confirm, approval, invitation, failed, gone, notAdded }

        let kind: Kind
        let host: String

        func words(language: DummyLanguage? = nil) -> String {
            String(format: L10n.t("account.signup.told.\(kind.rawValue)", language: language), host)
        }
    }

    private(set) var asked: Ask?
    /// The host whose form is up, or whose answer is being read.
    private(set) var onPage: String?
    private(set) var mail: Mail?
    private(set) var told: Told?

    /// The attempt past its form, and the only place its token is.
    private var held: Held?
    /// Moved by every attempt that ends: what an answer on its way finds no longer its own.
    @ObservationIgnored private var attempt = 0

    private struct Held {
        let traded: MastodonSessions.SignUpTraded
        let preview: SourcePreview
        /// The host's count of sign-outs at the form: another means the source was let go of since.
        let signOuts: Int
    }

    /// Whether an attempt stands, on its page or past it.
    var busy: Bool { onPage != nil || held != nil }

    /// **The step as the page draws it whenever an attempt is held**, whether or not its sheet
    /// could be shown: another sheet may stand where it would, and a held attempt is never without
    /// its words and its way out.
    var heldStep: Mail? {
        mail ?? held.map { Mail(host: $0.traded.token.host, reading: true) }
    }

    /// The host's terms where `preview` may offer an account at all: only a Mastodon's look carries
    /// any (`MastodonClient.profile`), and nobody signed in there.
    func terms(for preview: SourcePreview, in session: ShellSession) -> MastodonSignUp? {
        guard case .stated(let profile) = preview.profile,
              !session.mastodon.isSignedIn(host: preview.host)
        else { return nil }
        return profile.signUp
    }

    /// The act pressed: the question, where the host may be asked with what was typed.
    func ask(_ preview: SourcePreview, invitation typed: String, in session: ShellSession) {
        guard !busy, let terms = terms(for: preview, in: session) else { return }
        let invite = terms.open ? nil : MastodonSignUp.invitation(typed, at: preview.host)
        guard terms.open || invite != nil else { return }
        told = nil
        asked = Ask(preview: preview, terms: terms, invite: invite)
    }

    /// What the offer under `preview` draws, or nothing where it offers none.
    func offer(for preview: SourcePreview, invitation: String = "", in session: ShellSession) -> SignUpOfferSaid? {
        terms(for: preview, in: session).map {
            SignUpOfferSaid(host: preview.host, terms: $0, invitation: invitation, busy: busy)
        }
    }

    func putDownAsk() {
        asked = nil
    }

    func putDownTold() {
        told = nil
    }

    /// The question answered: the form, the trade, and how the account stands.
    func answer(_ ask: Ask, writing: Bool, through browser: any OAuthBrowser, in session: ShellSession) async {
        asked = nil
        let host = ask.preview.host
        guard !busy, !session.isAdded(host), !session.mastodon.isSignedIn(host: host) else { return }
        let signOuts = session.mastodon.signOutCount(host: host)
        onPage = host
        let paged = await session.mastodon.signUpPage(host: host, writing: writing, invite: ask.invite, through: browser)
        switch paged {
        case .closed:
            onPage = nil
            // A closed host answers a code it will not take with its sign-in page and no way back.
            if !ask.terms.open, ask.invite != nil { told = Told(kind: .invitation, host: host) }
        case .failed:
            onPage = nil
            told = Told(kind: .failed, host: host)
        case .traded(let traded):
            attempt += 1
            held = Held(traded: traded, preview: ask.preview, signOuts: signOuts)
            await read(saying: nil, in: session)
            onPage = nil
        }
    }

    /// How the account stands, asked again: a press, or the person coming back to the app. One at
    /// a time; a second ask while one is out does nothing.
    func check(in session: ShellSession) async {
        guard mail?.reading != true else { return }
        await read(saying: .stillWaiting, in: session)
    }

    /// `saying` is what stands on the step where it stays up: a refused mail's sentence stays,
    /// whatever else is found out, for the person to be told why nothing came.
    private func read(saying: Mail.Note?, in session: ShellSession) async {
        guard let held else { return }
        let mine = attempt
        mail?.reading = true
        let answer: MastodonNewAccount
        do {
            answer = try await session.mastodon.signUpStanding(held.traded)
        } catch MastodonSignInError.http(401) {
            guard mine == attempt else { return }
            end(told: .gone, of: held)
            return
        } catch {
            guard mine == attempt else { return }
            present(saying == .resendFailed ? saying : .unreachable, of: held, in: session)
            return
        }
        guard mine == attempt else { return }
        // Removed or signed out of while it stood: the person has let the host go.
        guard session.mastodon.signOutCount(host: held.traded.token.host) == held.signOuts else {
            letGo(held, told: nil, in: session)
            return
        }
        switch answer {
        case .functional(let who):
            // Nothing can be left from here. It stays the one attempt until the keeping is done.
            end(told: nil, of: held)
            onPage = held.traded.token.host
            await session.signedUp(held.preview, held.traded, as: who)
            onPage = nil
        case .awaitingMail:
            present(saying, of: held, in: session)
        case .awaitingApproval:
            letGo(held, told: .approval, in: session)
        case .unsaid:
            letGo(held, told: .confirm, in: session)
        }
    }

    /// The mail step up, or still up, saying `note`. A sheet standing in its way goes: two cannot
    /// stand at once, and this one holds what cannot be had again.
    private func present(_ note: Mail.Note?, of held: Held, in session: ShellSession) {
        var step = mail ?? Mail(host: held.traded.token.host)
        step.reading = false
        step.note = note
        mail = step
        if session.stage?.surface == .sheet { session.dismissStage() }
    }

    /// Asks for the mail again. A refusal may be the account having been confirmed, so how it
    /// stands is read straight after one.
    func resend(in session: ShellSession) async {
        guard let held, mail?.resending == false else { return }
        let mine = attempt
        mail?.resending = true
        let refused: Bool
        do {
            try await session.mastodon.signUpResend(held.traded)
            refused = false
        } catch {
            refused = true
        }
        guard mine == attempt else { return }
        mail?.resending = false
        mail?.note = refused ? .resendFailed : .resent
        if refused { await read(saying: .resendFailed, in: session) }
    }

    /// Leaving the mail step any way at all: its button, a swipe, Escape, the window closing. The
    /// token goes, nothing was written, and how to come back is said. Nothing where none stands.
    @discardableResult
    func leave(in session: ShellSession) -> Task<Void, Never>? {
        guard let held else { return nil }
        return letGo(held, told: .confirm, in: session)
    }

    /// What was told when the account could not be added after all.
    func tell(_ kind: Told.Kind, host: String) {
        told = Told(kind: kind, host: host)
    }

    @discardableResult
    private func letGo(_ held: Held, told kind: Told.Kind?, in session: ShellSession) -> Task<Void, Never> {
        end(told: kind, of: held)
        let mastodon = session.mastodon
        return Task { await mastodon.letGoSignedUp(held.traded) }
    }

    private func end(told kind: Told.Kind?, of ended: Held) {
        attempt += 1
        held = nil
        mail = nil
        if let kind { told = Told(kind: kind, host: ended.traded.token.host) }
    }
}

/// What the offer beside a preview draws, as a value.
struct SignUpOfferSaid: Equatable {
    let host: String
    let terms: MastodonSignUp
    var invitation = ""
    var busy = false

    /// A closed host is asked only with an invitation, so it is asked for one.
    var asksInvitation: Bool { !terms.open }
    private var invite: String? { MastodonSignUp.invitation(invitation, at: host) }
    /// **The act stands only where pressing it can lead to a form.**
    var offersAct: Bool { terms.open || invite != nil }

    var invitationUnread: Bool {
        asksInvitation && invite == nil && !invitation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func act(language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("account.signup.act", language: language), host)
    }

    func help(language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("account.signup.help", language: language), host)
    }

    func prompt(language: DummyLanguage? = nil) -> String {
        L10n.t("account.signup.invitation", language: language)
    }

    /// What the host's terms are, told and not enforced, and what stops being undone at the form.
    func lines(language: DummyLanguage? = nil) -> [String] {
        var lines: [String] = []
        if invitationUnread { lines.append(String(format: L10n.t("account.signup.invitation.unread", language: language), host)) }
        if terms.approvalRequired { lines.append(String(format: L10n.t("account.signup.approval", language: language), host)) }
        if let age = terms.minAge { lines.append(String(format: L10n.t("account.signup.minAge", language: language), host, age)) }
        return lines
    }
}

extension ShellQuestion {
    /// The two answers a sign-in has, about an account not made yet: neither is assumed for
    /// somebody who has not got as far as the form.
    static func signUp(host: String, language: DummyLanguage? = nil) -> ShellConfirmation {
        ShellConfirmation(
            symbol: "person.badge.plus", title: String(format: L10n.t("account.signup.ask.title", language: language), host),
            line: L10n.t("account.signup.ask.line", language: language),
            help: String(format: L10n.t("account.signup.help", language: language), host),
            choices: [
                .init(signInRead, L10n.t("account.signin.ask.read", language: language), role: .keyed),
                .init(signInWrite, L10n.t("account.signin.ask.write", language: language), role: .plain),
            ],
            cancel: L10n.t("board.choose.cancel", language: language)
        )
    }
}
