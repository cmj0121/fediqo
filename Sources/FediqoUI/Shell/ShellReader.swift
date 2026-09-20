import FediqoCore
import Observation
import SwiftUI
import WebKit

/// A page the reader opened out of a post's words, and which is drawn over the shell.
struct ShellReading: Identifiable, Hashable, Sendable {
    /// The address the reader pressed. **It does not move when the page does**: it is what the
    /// web view is built for and what identifies this reading, and a value that changed on every
    /// hop would tear the web view down and load it again at each one. Where the page went is
    /// `showing`.
    let url: URL
    /// Where the main frame is **now** — this address until the page goes somewhere else, and
    /// wherever it went after that.
    private(set) var showing: URL
    /// The host the reader is told they are on, which is `showing`'s and not `url`'s.
    ///
    /// **The sheet makes the reader exactly one promise and this is it.** There is no address
    /// bar, no back button and no history, so the name beside the padlock is the whole of what a
    /// reader has to go on — and onward navigation is allowed by design: a redirect, a link in
    /// the page, a `target="_blank"` reloaded into the same view. Fixed at open time this named
    /// the first host while a second one was on the screen, at a moment the author picks.
    private(set) var host: String
    /// Whether the page's last attempt to move was one this app would not follow. Set where the
    /// gate says no, and cleared by the next move that lands — see `arrived(at:)`.
    var refused: Bool = false

    var id: String { url.absoluteString }

    init(url: URL, host: String) {
        self.url = url
        showing = url
        self.host = host
    }

    /// The main frame landed somewhere. **An address with no host moves nothing**, because the
    /// failure this closes is the chrome naming a host the reader is not on, and keeping the old
    /// name is that failure rather than a safe fallback. The gate above has already refused
    /// everything that is not `https` with a host, so this is the invariant read once more where
    /// the consequence of it being false is a lie on the screen.
    mutating func arrived(at url: URL) {
        guard let host = url.host(), !host.isEmpty else { return }
        showing = url
        self.host = host
        refused = false
    }
}

/// What the reader has opened out of a post's words.
///
/// **A held object rather than a closure in the environment.** Every line of every post reads
/// this, and a closure has no identity — handing one down would make the environment differ on
/// every pass of the root and invalidate every line on the screen with it. A class reference is
/// the same value until it is a different object.
///
/// **It is a state, not a place.** `ShellPlace` is where the reader *is*; this is drawn over
/// wherever they are, so nothing about the timeline — which post is selected, where the list is
/// scrolled to, an open thread, an open search — is torn down to show it or rebuilt to leave it.
/// That is how "close it and you are back at the post you left" is kept: there is nothing to put
/// back, because nothing was taken away. Navigating to it instead would have meant restoring the
/// selection by hand, which is the shape `ShellSearch.selectionBefore` had to grow.
@MainActor
@Observable
final class ShellReader {
    private(set) var reading: ShellReading?

    /// Opens an address inside the app, and answers whether it did.
    ///
    /// **Decision 9 read again, at the door of a web view.** A `PostLink` is already a checked
    /// address — it has no other way of being built — but this is the boundary where a `URL`
    /// becomes a page rendered on this device, and the way in is a plain `URL` that a caller
    /// with no `PostLink` could reach. Refusing here as well is the second reading of one rule
    /// that `DummyThreadPane.outward` argues for at the other door, not a second spelling of it:
    /// both call `Host.allowsFetch`.
    ///
    /// The answer is used rather than ignored: a caller that is told no falls back to nothing at
    /// all, never to handing the address somewhere else.
    ///
    /// **What decision 9 does not carry, said out loud.** `Host.allowsFetch` is `https` plus a
    /// host and nothing else, so `https://127.0.0.1/`, `https://192.168.1.1/` and
    /// `https://[::1]:8443/` pass it — see `PostLink.followable`, where the whole of that
    /// omission is written down. For a `URLSession` fetch that is a request this app chose to
    /// make; here it is somebody else's JavaScript, pointed at the reader's own device or the
    /// network it is on, one press away in a stranger's post. It is not a regression and the
    /// press is the reader's, but nothing in this file should be read as saying otherwise.
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard Host.allowsFetch(url), let host = url.host(), !host.isEmpty else { return false }
        reading = ShellReading(url: url, host: host)
        return true
    }

    /// The page moved, and the chrome follows it. See `ShellReading.host`.
    func arrived(at url: URL) {
        reading?.arrived(at: url)
    }

    /// The page tried to go somewhere this app will not follow, and was stopped.
    ///
    /// **Said rather than swallowed.** A cancelled main-frame navigation leaves the reader
    /// looking at a link they pressed that did nothing at all — a control on the screen that is
    /// not a control in the app, which is the defect `PostLink.followable` refuses `http` in
    /// order to avoid. This app does not get to commit it one surface over.
    func refuse() {
        reading?.refused = true
    }

    func close() {
        reading = nil
    }
}

extension EnvironmentValues {
    /// Where a link in a post's words is opened. **Nothing outside the shell**, and a line that
    /// finds nothing here hands the address to the system browser instead — a preview, a test or
    /// a host that never set this degrades to what pressing a link did before this unit, never
    /// to a link that quietly does nothing.
    @Entry var shellReader: ShellReader?
}

/// Somebody else's page, drawn inside Fediqo.
///
/// **Why this is a second web surface when `ForumWebEngine` already exists.** That engine is one
/// host's browser and holds that host's session: its own doc says a host-scoped jar "must not be
/// spent on a stranger", `page(at:)` refuses an address that does not belong to its host, and the
/// whole point of it is that the cookies a sign-in earned and the cookies a fetch sends are the
/// same jar by construction. A link in a post goes wherever the author wrote, which is exactly
/// the stranger that engine refuses. Reusing it would mean either widening it to any host — and
/// carrying a forum's signed-in cookies there — or fetching one host's page through another
/// host's session. Neither is a thing to do.
///
/// So this one holds **no session at all**: a non-persistent store, made for the sheet and gone
/// with it. A page opened out of a post cannot read what a forum sign-in left on this device, and
/// cannot leave anything of its own behind for the next one.
struct LinkReaderSheet: View {
    /// The reading this sheet was presented with. Read only through `reading` below, and only
    /// during the frame the sheet is dismissed in — after that there is nothing live to read.
    let presented: ShellReading
    /// Where the live reading is. **Observed rather than taken from the presented value**:
    /// `.sheet(item:)` hands its content the item it was presented with, and everything the
    /// chrome says — the host, the notice, which page the browser button leads to — moves while
    /// the sheet is open. A snapshot would be exactly the header that stops being true.
    let reader: ShellReader
    let onClose: () -> Void

    private var reading: ShellReading { reader.reading ?? presented }

    @Environment(\.colorScheme) private var colorScheme
    /// The way out of the app. Read here, above nothing that overrides it, so the button below
    /// really does leave — see `EmojiText`'s prose links, which override it for their own subtree.
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            header
            if reading.refused { refusal }
            Divider()
            LinkWebView(url: reading.url, reader: reader)
                // **One web view per press.** The identity is the address the sheet was opened
                // on, which does not move as the page does, so a hop inside the sheet keeps the
                // view it is happening in — and a second `open` while the sheet is up builds a
                // new one rather than updating the header over the old page. Without it the
                // update methods below are no-ops and the sheet would say one address and show
                // another.
                .id(reading.id)
                // The same fitting as `ForumSignInSheet`, and for its reason: somebody else's page
                // is written for a browser window, and a floor wide enough for a desktop would be
                // wider than the screen on every phone.
                .frame(minWidth: 320, idealWidth: 800, minHeight: 320, idealHeight: 600)
                .accessibilityLabel(Text(String(format: L10n.t("link.reader.label"), reading.host)))
            Divider()
            footer
        }
        .frame(minWidth: 380, minHeight: 480)
    }

    /// The host, and nothing else. **What a reader checks before following a link is where it
    /// goes**, and this is the one fact about the page that this app knows rather than reads off
    /// it: it was parsed out of the letters the author typed. A title lifted from the document
    /// would be the page naming itself.
    private var header: some View {
        HStack(spacing: ShellSpace.snug) {
            Image(systemName: "lock")
                .font(ShellType.meta)
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
            Text(reading.host)
                .font(ShellType.pane)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: ShellSpace.snug)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ShellSpace.pad)
        .accessibilityElement(children: .combine)
    }

    /// One line, where the page asked to go somewhere this app will not follow.
    ///
    /// **A refusal the reader can see.** The gate cancels an `http://` hop, a `javascript:` link
    /// and another app's scheme without a word, so a link the reader pressed simply did nothing —
    /// and a control that does nothing is a question about this app rather than an answer about
    /// the page. It names no address: what was refused is the author's string, and printing a
    /// stranger's text in this app's own chrome is how chrome stops meaning anything.
    private var refusal: some View {
        HStack(spacing: ShellSpace.snug) {
            Image(systemName: "exclamationmark.triangle")
                .font(ShellType.meta)
            Text(L10n.t("link.reader.refused"))
                .font(ShellType.meta)
                .lineLimit(2)
            Spacer(minLength: ShellSpace.snug)
        }
        .foregroundStyle(ShellChrome.inkDim(colorScheme))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ShellSpace.pad)
        .padding(.bottom, ShellSpace.snug)
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        HStack(spacing: ShellSpace.step) {
            Button {
                // **Where the reader is, not where they came in.** The header names `showing`'s
                // host, so handing the browser the address the sheet was opened on would be the
                // same lie one control further along.
                openURL(reading.showing)
            } label: {
                Label(L10n.t("link.reader.browser"), systemImage: "arrow.up.forward.app")
                    .font(ShellType.meta.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(ShellChrome.selectInk(colorScheme))
            .accessibilityHint(Text(L10n.t("thread.open.leaves")))
            Spacer(minLength: ShellSpace.snug)
            Button(L10n.t("link.reader.close")) { onClose() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(ShellSpace.pad)
    }
}

/// The web view itself, and the one rule it navigates under.
///
/// **`https` or nothing, on every navigation this app is asked about.** The address this was
/// opened with was checked twice over, but a page decides where it goes next: a redirect to
/// `http://`, an `<a href="javascript:…">`, a frame loading `data:`, a link to another app's
/// scheme. Each of those arrives here as a navigation, so the rule is applied to each of them
/// rather than to the address that started it. A site that will only go somewhere this app will
/// not follow simply does not load, which is the honest outcome.
///
/// **What "every navigation" does not mean, stated rather than assumed.** The only policy
/// delegate implemented here is `decidePolicyFor navigationAction`, which is asked about
/// *navigations* — a frame going somewhere. It is not asked about what a page that has loaded
/// then fetches for itself: a `<script src>`, a stylesheet, an image, an `XMLHttpRequest`, a
/// `fetch`. Those never reach this file, and `decidePolicyFor navigationResponse` — which would
/// see what came back rather than where it was going — is not implemented at all. The plaintext
/// case is covered, but by WebKit and not by this: mixed content on an `https` page is blocked
/// by the engine. So the sentence above is a rule about where the reader is taken, and it is not
/// a claim about every byte the page pulls in.
private struct LinkWebView {
    let url: URL
    /// Where the page reports back to: the host it landed on, and a move that was stopped.
    let reader: ShellReader

    @MainActor
    func makeCoordinator() -> Gate { Gate(reader: reader) }

    /// Built once, for one address. `@MainActor` because a `WKWebView` is, and because the two
    /// representables below are — this is the body they share rather than a second one.
    @MainActor
    fileprivate func make(_ coordinator: Gate) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // **No session, and none kept.** See `LinkReaderSheet` — a stranger's page gets neither
        // sight of what a forum sign-in left on this device nor a place to leave anything.
        configuration.websiteDataStore = .nonPersistent()
        // The same courtesy `Fediqo.userAgent` and `ForumWebEngine` extend: an administrator
        // reading a log can see which client this is. Nothing is appended that reads as Safari.
        configuration.applicationNameForUserAgent = Fediqo.name
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = coordinator
        view.uiDelegate = coordinator
        view.load(URLRequest(url: url))
        return view
    }

    final class Gate: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let reader: ShellReader

        init(reader: ShellReader) {
            self.reader = reader
        }

        nonisolated func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            MainActor.assumeIsolated {
                let allowed = navigationAction.request.url.map(Host.allowsFetch) ?? false
                // **Told, where the refusal is the reader's own press.** A subframe going
                // somewhere is the page's business and a notice about it would be this app
                // narrating a stranger's markup; the main frame is the page the reader is
                // looking at, and a `nil` target frame is a new window — the same press with a
                // different attribute on it, and the one `createWebViewWith` below folds back
                // into this view.
                if !allowed, navigationAction.targetFrame?.isMainFrame ?? true { reader.refuse() }
                decisionHandler(allowed ? .allow : .cancel)
            }
        }

        /// Where the main frame landed, which is what the header names.
        ///
        /// **`didCommit` and not the policy call.** What the chrome must say is where the reader
        /// *is*, and a navigation that was allowed is not yet a page that loaded — a server
        /// redirect chain resolves between the two, and `webView.url` here is the address at the
        /// end of it. A header moved at the policy call would name a hop the reader never landed
        /// on. This fires for the main frame only, which is exactly the frame the header is about.
        nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            MainActor.assumeIsolated {
                guard let url = webView.url else { return }
                reader.arrived(at: url)
            }
        }

        /// A `target="_blank"` link, which WebKit would otherwise ask for a second view for and
        /// then quietly drop. It is the same page's own link, so it is loaded here — under the
        /// same rule as everything else.
        nonisolated func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            MainActor.assumeIsolated {
                if let url = navigationAction.request.url, Host.allowsFetch(url) {
                    webView.load(URLRequest(url: url))
                }
                return nil
            }
        }
    }
}

#if os(macOS)
extension LinkWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { make(context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#else
extension LinkWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { make(context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif
