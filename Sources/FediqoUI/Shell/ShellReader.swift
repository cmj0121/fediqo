import FediqoCore
import Observation
import SwiftUI
import WebKit

/// A page the reader opened out of a post's words, and which is drawn over the shell.
struct ShellReading: Identifiable, Hashable, Sendable {
    let url: URL
    /// The host the reader is told they are on. `PostLink` already proved there is one.
    let host: String

    var id: String { url.absoluteString }
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
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard Host.allowsFetch(url), let host = url.host(), !host.isEmpty else { return false }
        reading = ShellReading(url: url, host: host)
        return true
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
    let reading: ShellReading
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    /// The way out of the app. Read here, above nothing that overrides it, so the button below
    /// really does leave — see `EmojiText`'s prose links, which override it for their own subtree.
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            LinkWebView(url: reading.url)
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

    private var footer: some View {
        HStack(spacing: ShellSpace.step) {
            Button {
                openURL(reading.url)
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
/// **`https` or nothing, on every navigation and not only the first.** The address this was
/// opened with was checked twice over, but a page decides where it goes next: a redirect to
/// `http://`, an `<a href="javascript:…">`, a frame loading `data:`, a link to another app's
/// scheme. Each of those arrives here as a navigation, so the rule is applied to each of them
/// rather than to the address that started it. A site that will only go somewhere this app will
/// not follow simply does not load, which is the honest outcome.
private struct LinkWebView {
    let url: URL

    @MainActor
    func makeCoordinator() -> Gate { Gate() }

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
        nonisolated func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            MainActor.assumeIsolated {
                let allowed = navigationAction.request.url.map(Host.allowsFetch) ?? false
                decisionHandler(allowed ? .allow : .cancel)
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
