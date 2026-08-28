import SwiftUI
import FediqoCore

/// What just came of the last thing the reader asked for, said out loud and then gone.
///
/// A star is pressed and filled in the same instant, before anybody's server has been asked —
/// which is right, because a control whose whole job is to answer immediately cannot wait on
/// somebody else's machine. The price of that is this: when the server disagrees, the mark
/// goes back and nothing on the screen has said why. Without these words a press that failed
/// and a press that did nothing look exactly alike, and the commonest failure of the two —
/// nobody signed in anywhere — looks like an app with a broken button.
///
/// The other thing said here is not a failure at all. Acting on a post the acting server has
/// never seen makes it go and fetch it, which is the one moment this app tells somebody else
/// what is being read. A reader who allowed that should watch it happen rather than find out
/// from a changelog.
///
/// It is drawn by the shell rather than by the timeline because an action is not the
/// timeline's: the opened post has the same bar on it, and Kept has rows that act too.
struct ActionNotice: View {
    @Environment(AppState.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    /// A reader who asked for less movement. The words still come and still go — it is the
    /// fade that is the decoration, not the message.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What is on screen, which is the app's news taken down rather than read live: the news
    /// is cleared the moment it has been said, and a message that vanished mid-sentence with
    /// it would be a message nobody read.
    @State private var saying: Saying?

    /// How long each of the two stands — see `Saying.lasts`, which is what reads them.
    static let failureLasts = Duration.milliseconds(4500)
    static let noteLasts = Duration.milliseconds(2500)

    /// One piece of news, and everything about how it is said.
    ///
    /// Two kinds, and they are not the same kind of thing: one is a thing that did not happen,
    /// the other a thing that did. Which is why each of the four answers below is a `switch`
    /// over the two rather than a flag the view reads — how long it stands, what colour it
    /// wears, which glyph it is and what it says are four decisions, and every one of them is
    /// decided by which kind of news this is.
    ///
    /// They live on the news rather than in the view because none of them is a drawing: they
    /// are what the app has decided to tell the reader, and a decision that can only be
    /// checked by rendering a screen is a decision nothing checks.
    enum Saying: Equatable {
        case wrong(SourceFailure)
        case reachedOut(String)

        /// How long it stands.
        ///
        /// A failure is a sentence with a hostname in it and something to do about it, so it is
        /// given time to be read twice. The reach-out is four words about something that has
        /// already happened, and it is not worth covering a corner of the timeline for longer.
        var lasts: Duration {
            switch self {
            case .wrong: ActionNotice.failureLasts
            case .reachedOut: ActionNotice.noteLasts
            }
        }

        /// Orange rather than red. Red is for what takes something away, and nothing here has:
        /// the mark went back and the post is as it was. What this is, is a server that would
        /// not do as it was asked — which is the colour a server that is unwell already wears.
        var tint: Color {
            switch self {
            case .wrong: .orange
            case .reachedOut: .secondary
            }
        }

        var symbol: String {
            switch self {
            case .wrong: "exclamationmark.triangle"
            case .reachedOut: "antenna.radiowaves.left.and.right"
            }
        }

        /// The words, in the reader's own language — which is the whole reason `SourceFailure`
        /// carries a case rather than a sentence.
        @MainActor var words: String {
            switch self {
            case .wrong(let failure): message(for: failure)
            case .reachedOut(let host): t("post.reachedOut", host)
            }
        }
    }

    /// Which of the two is worth the reader's attention, given what the app is holding.
    ///
    /// A failure wins, and it wins for a plain reason: the reach-out is a note about a request
    /// that went out, and where both are standing the request went out and then failed. Saying
    /// only that we told somebody else what you are reading, and not that it was for nothing,
    /// would be the least useful half of the truth.
    ///
    /// Pure, and given both values rather than the app, so what gets said can be settled
    /// without a screen.
    static func saying(failure: SourceFailure?, reachedOut: String?) -> Saying? {
        if let failure { return .wrong(failure) }
        return reachedOut.map { .reachedOut($0) }
    }

    private var fading: Animation? { reduceMotion ? nil : Motion.appearing }

    var body: some View {
        // A container that is always here, whether or not there is anything to say: the
        // watching below has to keep running through the silence, and modifiers hung on
        // nothing are modifiers that never run. It is nothing at all when empty, and it never
        // takes a press — what is underneath it is the timeline, and a message is not a
        // control.
        VStack(spacing: 0) { pill }
            .allowsHitTesting(false)
            // The news, watched rather than drawn straight: what is drawn has to outlive the
            // clearing below, which is what makes a second identical failure a second message
            // instead of a value that never changed and so was never said again.
            .onChange(of: Self.saying(failure: app.actionFailure, reachedOut: app.lastReachedOut)) {
                _, next in
                guard let next else { return }
                withAnimation(fading) { saying = next }
            }
            // Structured, so leaving the app takes the message with it rather than leaving a
            // sleep to wake up in a shell nobody is looking at. The app's own news is cleared
            // here and not at the moment it was said: cleared any earlier and the same failure
            // twice running would be one message, because nothing about the value changed.
            .task(id: saying) {
                guard let saying else { return }
                try? await Task.sleep(for: saying.lasts)
                guard !Task.isCancelled else { return }
                withAnimation(fading) { self.saying = nil }
                app.actionFailure = nil
                app.lastReachedOut = nil
            }
    }

    @ViewBuilder
    private var pill: some View {
        if let saying {
            HStack(spacing: Space.step) {
                Image(systemName: saying.symbol).fediqoSymbol(Glyph.inline, weight: .medium)
                    .foregroundStyle(saying.tint)
                Text(saying.words).fediqoFont(TypeScale.small, weight: .medium)
            }
            .fediqoPill()
            // A pill usually speaks quietly beside something louder. This one is the whole of
            // what is being said, and only for a few seconds.
            .foregroundStyle(.primary)
            .background {
                Capsule()
                    .fill(Palette.raised(colorScheme))
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.55 : 0.22),
                            radius: 10, y: 4)
            }
            .padding(.bottom, Space.band)
            // Not hidden, unlike the marker at the foot of a timeline: that one repeats a
            // sentence the list already says, and this is the only place the news appears at
            // all. A reader who cannot see the pill has to be told the same thing.
            //
            // The words said outright rather than gathered from the children. The glyph is
            // decoration — it says nothing the sentence does not — and a combined element left
            // the label empty, which is a message that exists and says nothing to anybody
            // reading the screen rather than looking at it.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(saying.words))
            // One name for the whole message, so a driver outside the app can wait for it to
            // arrive and read what it says. There is at most one of these anywhere.
            .accessibilityIdentifier("action.notice")
            .transition(.opacity)
        }
    }
}
