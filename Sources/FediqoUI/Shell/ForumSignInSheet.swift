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

    private var engine: ForumWebEngine { sessions.engine(host: request.host) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ForumWebViewBox(engine: engine)
                .frame(minHeight: 320)
                .accessibilityLabel(Text(String(format: L10n.t("forum.signin.web.label"), request.host)))
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 560)
        .task { await open() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            Text(String(format: L10n.t("forum.signin.title"), request.host))
                .font(ShellType.pane)
                .foregroundStyle(ShellChrome.ink(colorScheme))
            Text(L10n.t(request.stop.explanationKey))
                .font(ShellType.meta)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
            // The forum's own words, on their own line. Not this app talking, and never
            // rephrased into this app's voice — a stranger's server saying "wrong password" is
            // information, and putting it in our own sentence would make us the ones claiming it.
            if let said = request.stop.forumSaid {
                Text(said)
                    .font(ShellType.mark)
                    .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                    .textSelection(.disabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ShellSpace.pad)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            Toggle(L10n.t("forum.signin.save"), isOn: $saving)
                .font(ShellType.body)
            Text(L10n.t(saving ? "forum.signin.save.on" : "forum.signin.save.off"))
                .font(ShellType.mark)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
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
        guard let url = engine.loginURL else { return }
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
    private func confirm() async {
        checking = true
        defer { checking = false }
        let reached = await engine.isSignedIn()
        signedIn = reached
        if reached, saving {
            await sessions.saveTyped(host: request.host)
        }
        finish(reached)
    }

    private func finish(_ reached: Bool) {
        finished(reached)
        dismiss()
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
