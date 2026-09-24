import FediqoCore
import SwiftUI
import WebKit

/// The forum's own sign-in page, inside this app.
///
/// **Two jobs and no third.** This web view signs the reader in and it fetches a page for a host
/// that will not answer anything else — nothing in this app navigates in it, nothing links into
/// it, and there is no back button, because a native client that reads through an embedded
/// browser is one step away from being a browser with native chrome, which is not what this app
/// is. The chrome here is a title, a sentence, one switch and two buttons.
///
/// **The switch is where the honest sentence changes, and it says so in those words.** Before it
/// is turned on, this app does not see the password: the reader types into markup the forum sent,
/// running in the forum's own origin, and nothing reads the field. Turned on, it does see it,
/// because signing in by itself means holding it. Both sentences are on screen, and which one is
/// true right now is which one is emphasised — D23.
struct ForumSignInSheet: View {
    let request: ForumSignInRequest
    let sessions: ForumSessions
    /// Called when the reader is done, with whether a sign-in was actually reached.
    let finished: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var saving = false
    @State private var checking = false
    @State private var signedIn = false
    /// Why what the reader asked to keep was not kept, once that has happened. While it is set the
    /// sheet stays up and says so, and Done closes it — the sign-in itself was reached.
    @State private var unkept: ForumKeepFailure?

    private var engine: ForumWebEngine { sessions.engine(host: request.host) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ForumWebViewBox(engine: engine)
                // **Ideal, not fixed.** A forum's login page is a real web page written for a
                // browser window, and 520 points wide was making one read like a phone site
                // inside a desktop app. 800×600 is what it opens at where there is room for it.
                //
                // The minimums stay small on purpose: a fixed 800 would be wider than the screen
                // on every phone, which is the one thing this project's layout rule forbids
                // outright. On a compact screen the sheet fills the screen and the ideal is
                // simply never reached — the same page, drawn in what there is.
                .frame(minWidth: 320, idealWidth: 800, minHeight: 320, idealHeight: 600)
                .accessibilityLabel(Text(String(format: L10n.t("forum.signin.web.label"), request.host)))
            Divider()
            footer
        }
        // Lower than the 520×560 that stood here, and that is the point: the ideal above is what
        // decides the opening size now, and a floor that high stopped a reader making the window
        // small when they wanted to see what was behind it.
        .frame(minWidth: 380, minHeight: 480)
        .task { await open() }
        // The check a sign-in shows, and a page followed from it, only while the sheet is up (#220).
        .onDisappear { [engine] in Task { await engine.signingIn(false) } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            Text(String(format: L10n.t("forum.signin.title"), request.host))
                .shellFont(.pane)
                .foregroundStyle(ShellChrome.ink(colorScheme))
            explanation
            // The forum's own words, on their own line. Not this app talking, and never
            // rephrased into this app's voice — a stranger's server saying "wrong password" is
            // information, and putting it in our own sentence would make us the ones claiming it.
            if let said = request.stop.forumSaid {
                Text(said)
                    .shellFont(.mark)
                    .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                    .textSelection(.disabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ShellSpace.pad)
    }

    /// The heading of the forum's page below (#244): what it is, why it is up in one line, and
    /// the rest behind that line's (?) where there is more — on the page's own heading, not
    /// under the sheet's title.
    private var explanation: some View {
        ShellSectionHead(
            L10n.t("forum.signin.page"), line: request.stop.explanation(),
            help: request.stop.moreKey.map { L10n.t($0) }
        )
        .padding(.top, ShellSpace.snug)
    }

    /// What ticking the box does, in one line; the whole promise is behind its (?) (#235).
    static func saveKeys(saving: Bool) -> (line: String, more: String) {
        saving
            ? ("forum.signin.save.line.on", "forum.signin.save.on")
            : ("forum.signin.save.line.off", "forum.signin.save.off")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            Toggle(L10n.t("forum.signin.save"), isOn: $saving)
                .shellFont(.body)
                .modifier(WatchingTyped(host: request.host, sessions: sessions, on: saving))
            let keys = Self.saveKeys(saving: saving)
            Text(L10n.t(keys.line))
                .shellFont(.mark)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .shellHelp(keys.more, about: L10n.t(keys.line))
            if let unkept {
                Text(unkept.sentence())
                    .shellFont(.mark)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: ShellSpace.step) {
                Spacer(minLength: ShellSpace.snug)
                Button(L10n.t("forum.signin.cancel")) { finish(false) }
                Button(L10n.t("forum.signin.done")) { Task { await confirm() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(checking)
            }
        }
        .padding(ShellSpace.pad)
    }

    /// Puts the forum's login page in the view. The engine is the same one the transport fetches
    /// through, so whatever the reader passes here — a browser check, a sign-in — is passed for
    /// the fetches too.
    ///
    /// **And this is the moment the check can actually clear.** Measured: a `WKWebView` that is
    /// not in a window has `document.visibilityState == "hidden"`, and Cloudflare's Turnstile
    /// does not run in a hidden document — an off-screen fetch sat on `challenge.example`'s interstitial
    /// for sixty seconds without so much as a cookie being set. Putting the same engine on screen
    /// is not a fallback for when the automatic path fails; for a challenged host it is the only
    /// way the automatic path is ever reached at all.
    private func open() async {
        guard let url = engine.loginURL, !Task.isCancelled else { return }
        await engine.signingIn(true)
        guard !Task.isCancelled else { return }
        _ = try? await engine.page(at: url)
        signedIn = await engine.isSignedIn()
    }

    /// Confirms by what came back rather than by the reader pressing a button.
    ///
    /// Done does not mean signed in. The reader can press it having typed nothing, having got the
    /// password wrong, or having been shown a check that never cleared — so the page is asked,
    /// and what it says is what is reported upward. Saving happens only on a sign-in that the
    /// page confirms: a password saved from a failed attempt is a password that will fail
    /// silently on every launch afterwards.
    ///
    /// **A keep that failed is said here, and the sheet waits** (#153). It used to be ignored, and
    /// the reader learned only at the next launch — by being signed out — that nothing had been
    /// kept. Now the sentence says what went wrong, and the next Done closes the sheet on a
    /// sign-in that was, after all, reached. The row goes on saying it after the sheet is gone.
    private func confirm() async {
        if unkept != nil {
            finish(true)
            return
        }
        checking = true
        defer { checking = false }
        let reached = await engine.isSignedIn()
        signedIn = reached
        if reached, saving, case .failed(let failure) = await sessions.saveTyped(host: request.host) {
            unkept = failure
            return
        }
        finish(reached)
    }

    private func finish(_ reached: Bool) {
        // Whatever was held for keeping goes with the sheet, kept or not.
        sessions.watchTyped(host: request.host, on: false)
        finished(reached)
        dismiss()
    }
}

/// The sheet's switch, handed to the forum's browser: while it is on, what the reader submits on
/// the forum's page is held for keeping — #153. A modifier of its own so the sheet's chain carries
/// no closure (the CI compiler's rule).
private struct WatchingTyped: ViewModifier {
    let host: String
    let sessions: ForumSessions
    let on: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: on, initial: false) { _, now in
                sessions.watchTyped(host: host, on: now)
            }
            // A sheet swiped away, or the Mac's window closed by its own button, never reaches
            // `finish`; what was held goes with it all the same.
            .onDisappear { sessions.watchTyped(host: host, on: false) }
    }
}

/// The engine's own view, put on screen.
///
/// Hands over the **same** `WKWebView` the transport fetches through rather than making one for
/// the sheet. Two views would mean two documents and, with a non-persistent store, two jars: the
/// reader would sign in successfully and the app would still be a stranger.
struct ForumWebViewBox: View {
    let engine: ForumWebEngine

    var body: some View { Box(engine: engine) }

    #if os(macOS)
    private struct Box: NSViewRepresentable {
        let engine: ForumWebEngine
        func makeNSView(context: Context) -> WKWebView { engine.view }
        func updateNSView(_ view: WKWebView, context: Context) {}
    }
    #else
    private struct Box: UIViewRepresentable {
        let engine: ForumWebEngine
        func makeUIView(context: Context) -> WKWebView { engine.view }
        func updateUIView(_ view: WKWebView, context: Context) {}
    }
    #endif
}
