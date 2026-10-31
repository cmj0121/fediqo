import FediqoCore
import SwiftUI

/// The quiet act under a preview: an invitation field on a closed host, and the press.
struct SignUpOffer: View {
    let said: SignUpOfferSaid
    @Binding var invitation: String
    var onPress: () -> Void = {}
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            if said.asksInvitation {
                TextField(said.prompt(), text: $invitation)
                    .shellFont(.meta)
                    .shellField(.alone)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .accessibilityLabel(said.prompt())
            }
            if said.offersAct {
                ShellLinkButton(said.act(), action: onPress)
                    .disabled(said.busy)
                    .shellHelp(verbatim: said.help(), about: said.act())
            }
            ForEach(said.lines(), id: \.self) { line in
                Text(line)
                    .shellFont(.mark)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The offer as a preview draws it: the typing is its own, and goes with the host it is keyed by.
struct SignUpOfferHost: View {
    let preview: SourcePreview
    let session: ShellSession
    @State private var invitation = ""

    var body: some View {
        if let said = session.signUp.offer(for: preview, invitation: invitation, in: session) {
            SignUpOffer(
                said: said, invitation: $invitation,
                onPress: { session.signUp.ask(preview, invitation: invitation, in: session) }
            )
            .padding(.bottom, ShellSpace.pad)
        }
    }
}

/// An attempt that ended short of signed in, said where the person is adding sources.
struct SignUpToldLine: View {
    let told: ShellSignUp.Told
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(told.words())
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.ink(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A held attempt, on the page and whatever else stands over it: what it waits for, and its acts.
struct SignUpHeldLine: View {
    let said: ShellSignUp.Mail
    var onCheck: () -> Void = {}
    var onLeave: () -> Void = {}
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            Text(said.heldLine())
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            if let note = said.noteWords() {
                Text(note)
                    .shellFont(.mark)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: ShellSpace.step) {
                ShellLinkButton(L10n.t("account.signup.mail.check"), action: onCheck)
                    .disabled(said.reading)
                ShellLinkButton(L10n.t("account.signup.mail.leave"), action: onLeave)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The step after the form where the host wants its mail opened: the sentences, and three acts.
struct SignUpMailSheet: View {
    let said: ShellSignUp.Mail
    var onCheck: () -> Void = {}
    var onResend: () -> Void = {}
    var onLeave: () -> Void = {}
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(said.title())
                .shellFont(.pane)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .padding(ShellSpace.room)
            ShellRule()
            VStack(alignment: .leading, spacing: ShellSpace.step) {
                ForEach(said.lines(), id: \.self) { line in
                    Text(line)
                        .shellFont(.body)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note = said.noteWords() {
                    Text(note)
                        .shellFont(.meta, weight: .medium)
                        .foregroundStyle(ShellChrome.ink(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(ShellSpace.room)
            ShellRule()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: ShellSpace.step) { acts }
                VStack(alignment: .leading, spacing: ShellSpace.snug) { acts }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(ShellSpace.room)
        }
    }

    @ViewBuilder
    private var acts: some View {
        Button(L10n.t("account.signup.mail.leave"), action: onLeave)
            .keyboardShortcut(.cancelAction)
        Button(L10n.t("account.signup.mail.resend"), action: onResend)
            .disabled(said.resending)
        Button(L10n.t("account.signup.mail.check"), action: onCheck)
            .keyboardShortcut(.defaultAction)
            .disabled(said.reading)
    }
}

/// The mail step over everything, for as long as the attempt stands. **Closed by any way at all it
/// is the person leaving**: the binding for what the system closes, and the disappearing for a
/// window that goes with the sheet on it.
struct SignUpPresenter: ViewModifier {
    let session: ShellSession

    func body(content: Content) -> some View {
        content.sheet(item: shown) { _ in SignUpMailHost(session: session) }
    }

    private var shown: Binding<ShellSignUp.Mail?> {
        Binding(get: { session.signUp.mail }, set: { if $0 == nil { session.signUp.leave(in: session) } })
    }
}

private struct SignUpMailHost: View {
    let session: ShellSession
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        if let mail = session.signUp.mail {
            SignUpMailSheet(
                said: mail,
                onCheck: { Task { await session.signUp.check(in: session) } },
                onResend: { Task { await session.signUp.resend(in: session) } },
                onLeave: { session.signUp.leave(in: session) }
            )
            #if os(macOS)
            .frame(width: 460)
            #else
            .presentationDetents([.medium, .large])
            #endif
            // The person back from their mail: how it stands is read with no press.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await session.signUp.check(in: session) } }
            }
            .onDisappear { session.signUp.leave(in: session) }
        }
    }
}

/// Reading, or reading and writing, asked before the form opens, as a sign-in asks it — a modifier
/// for `SignInChoiceQuestion`'s reason.
struct SignUpQuestion: ViewModifier {
    let session: ShellSession
    let answered: @MainActor (ShellSignUp.Ask, Bool) -> Void

    func body(content: Content) -> some View {
        content.shellConfirm(asked, question: { ShellQuestion.signUp(host: $0.preview.host) }) { ask, id in
            answered(ask, id == ShellQuestion.signInWrite)
        }
    }

    private var asked: Binding<ShellSignUp.Ask?> {
        Binding(get: { session.signUp.asked }, set: { if $0 == nil { session.signUp.putDownAsk() } })
    }
}
