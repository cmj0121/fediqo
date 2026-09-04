import SwiftUI
import Observation
import FediqoCore

/// What a post can tell you about itself (#126).
///
/// A row says *23* beside a star and *6* beside a boost, and on an opened post the numbers were
/// still only numbers. Three questions a reader has and could not ask: **when exactly**, **who
/// favourited it**, and **who boosted it**.
///
/// One page rather than a line here and a list there: they are three answers to *tell me more
/// about this post*, and a page that holds all three is one place to go.
@MainActor
@Observable
final class PostAboutModel {
    let post: Post
    var tab: People.AboutAPost = .favourited
    private(set) var found: [People.AboutAPost: [Profile]] = [:]
    private(set) var loading = false
    private(set) var failure: SourceFailure?
    /// The server whose word on this post is final, which is the one that keeps the lists.
    private(set) var host: String = ""

    private let loader: TimelineLoader

    init(post: Post, loader: TimelineLoader) {
        self.post = post
        self.loader = loader
    }

    /// How many the count on the post says there are, for the list to be held to.
    ///
    /// **Nil is not zero.** A server that did not send a count has not said nobody favourited
    /// it, and reading it as zero would turn "we do not know" into "nobody did" — which is the
    /// one thing the `hidden` answer below exists to avoid.
    func counted(_ which: People.AboutAPost) -> Int? {
        switch which {
        case .favourited: post.counts.favourites
        case .boosted: post.counts.reblogs
        }
    }

    /// Whether the list is empty because nobody did it, or because the server would not say.
    ///
    /// #90's rule, applied to a post: an empty answer and a hidden one arrive identically, and
    /// what tells them apart is the count beside them. A post that says *23 favourites* and then
    /// hands over none of them has been told not to.
    func reason(_ which: People.AboutAPost) -> People.Reason {
        guard let list = found[which] else { return .unknown }
        if !list.isEmpty { return .some }
        // A count nobody sent leaves this unknown rather than picking: drawing "nobody" over a
        // hidden list invents a fact about a post, and drawing "hidden" over a genuinely empty
        // one invents a different one (S5).
        guard let counted = counted(which) else { return .unknown }
        return counted > 0 ? .withheld : .none
    }

    /// Asked when a tab is chosen and not before: the numbers on a row are free and the names
    /// behind them are a request.
    func read(_ which: People.AboutAPost) async {
        guard found[which] == nil, !loading else { return }
        loading = true
        defer { loading = false }
        let answer = await loader.people(which, of: post)
        host = answer.host
        failure = answer.failure
        // Only where somebody was actually asked. A list nobody asked for is not an empty list,
        // and recording it as one would have the page say the server withheld it.
        guard answer.asked else { return }
        found[which] = answer.people
    }
}

/// The page (#126).
///
/// The same arrangement the Inbox has, which is the same arrangement Statistics has: a title, the
/// line describing the tab being shown, the tabs, and a way out. A reader who has learned one has
/// learned this.
struct PostAboutPage: View {
    let model: PostAboutModel
    let done: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    /// The app's language, because the exact time is built as a string rather than drawn by
    /// `Text(date, format:)` — the mistake #110 and #124 both had to fix.
    @Environment(\.locale) private var locale

    var body: some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
            header
            Hairline()
            written
            Hairline()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.gap) {
                    list
                }
                .padding(Space.pad)
            }
        }
        .background(Palette.surface(colorScheme))
        .task(id: model.tab) { await model.read(model.tab) }
    }

    private var header: some View {
        @Bindable var model = model
        return PageHeader(titleKey: "post.about",
                          subtitleKey: "post.about.\(model.tab.rawValue)",
                          loading: model.loading) {
            SegmentedChoice(People.AboutAPost.allCases, keyPrefix: "post.about.tab",
                            selection: $model.tab)
        } controls: {
            Button(action: done) {
                Label(t("post.back"), systemImage: "chevron.left")
                    .fediqoFont(TypeScale.small, weight: .medium)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.accent)
            .keyboardShortcut(.escape, modifiers: [])
        }
    }

    /// **When exactly.** `5 minutes ago` is the right thing on a row being scanned and the wrong
    /// thing on a post being read: *which of these two came first* and *was this before or after
    /// the thing it answers* are questions a relative time cannot answer.
    private var written: some View {
        HStack(spacing: Space.step) {
            Image(systemName: "clock").fediqoSymbol(Glyph.inline).foregroundStyle(.secondary)
            Text(model.post.createdAt.formatted(
                .dateTime.year().month().day().hour().minute().second().locale(locale)))
                .fediqoFont(TypeScale.small)
                .textSelection(.enabled)
            Spacer(minLength: Space.tight)
            Text(model.post.authorHandle)
                .fediqoFont(TypeScale.minor)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, Space.pad)
        .padding(.vertical, Space.mid)
    }

    @ViewBuilder
    private var list: some View {
        let people = model.found[model.tab] ?? []
        if people.isEmpty {
            // Which kind of empty, said in words. An empty answer and a withheld one arrive
            // identically and are different facts (#90, S5).
            Text(t(emptyKey))
                .fediqoFont(TypeScale.small)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ForEach(people, id: \.authorId) { person in
                PersonLine(person: person, host: model.host)
            }
        }
    }

    /// Which kind of empty this is — and **a request that did not arrive is none of them.**
    ///
    /// A server that would not answer, or a network that was not there, is not a server choosing
    /// not to publish its list. Reading one as the other tells the reader something about
    /// somebody's server that nobody has any evidence for, which is exactly what #90's four
    /// reasons exist to stop.
    private var emptyKey: String {
        if model.failure != nil { return "post.about.refused" }
        switch model.reason(model.tab) {
        case .some, .none: return "post.about.nobody"
        case .withheld: return "post.about.withheld"
        case .unknown: return "post.about.unknown"
        }
    }
}
