import FediqoCore
import SwiftUI

/// What an answer is written to, and the conversation it is written from (#108).
///
/// **Both, because they are two different posts as often as not.** The reader answers whichever
/// row the lamp is on inside a thread, and what landed has to be laid into the thread that is
/// open — which is keyed by the post the thread is *about*, not by the one being answered.
struct AnswerTarget: Identifiable, Equatable {
    /// The post being answered.
    let item: DummyItem
    /// The post the open conversation is about.
    let root: DummyItem
    /// Where the reach started: the post's own, or the narrowest where this device was never told
    /// it. `Audience.answering`.
    let start: Audience

    var id: String { item.id }
}

/// An answer, written over the conversation it belongs to (#108).
///
/// **The composer's shape pointed at something** — the same `WritingSheet` — and its rules are
/// the composer's own statics rather than a second copy of them: the ceiling, the send test, the
/// draft a landing clears.
/// What is different is what this surface has that the composer does not — the post being
/// answered stays in view while the words are written, the source is named rather than chosen
/// because the post decides it, and the reach starts no wider than the post.
struct AnswerSheet: View {
    let target: AnswerTarget

    @Environment(ShellSession.self) private var session
    @Environment(\.colorScheme) private var colorScheme

    /// The line naming where the answer goes. A sentence rather than a picker: the source is not
    /// a choice here.
    static func goesTo(host: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("answer.goesTo", language: language), host)
    }

    /// What VoiceOver hears on the post being answered: who, and what they said.
    static func answering(_ item: DummyItem, language: DummyLanguage? = nil) -> String {
        let who = item.author.isEmpty ? (item.handle ?? "") : item.author
        return String(format: L10n.t("answer.to", language: language), who) + " " + item.body
    }

    /// Whether the chosen reach needs saying: only where it goes further than where it started,
    /// which is never wider than the post answered.
    static func widens(_ reach: Audience, from start: Audience) -> Bool {
        reach.isWider(than: start)
    }

    var body: some View {
        let item = target.item
        let host = item.source.host
        let draft = Binding(
            get: { session.answerDraft(target) },
            set: { session.answerDrafts[target.id] = $0 }
        )
        let reach = Binding(
            get: { session.answerReach[target.id] ?? target.start },
            set: { session.answerReach[target.id] = $0 }
        )
        WritingSheet(
            titleKey: "answer.title",
            sendKey: "answer.send",
            bodyKey: "answer.body",
            draft: draft,
            limit: session.postLimit(of: host),
            canSend: session.canSendAnswer(target),
            height: 460,
            hidesScrollIndicators: false,
            speaksLimitLine: false,
            send: {
                try await session.answer(target)
                guard session.answerDraft(target).isEmpty else { return false }
                session.answering = nil
                return true
            },
            failedAt: { host }
        ) { sending, _ in
            answered(item)
            HStack(alignment: .firstTextBaseline, spacing: ShellSpace.step) {
                Text(Self.goesTo(host: host))
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                Picker(L10n.t("answer.reach"), selection: reach) {
                    ForEach(Audience.allCases, id: \.self) { audience in
                        Text(L10n.t(ComposerSheet.visibilityKey(audience))).tag(audience)
                    }
                }
                .pickerStyle(.menu)
                .shellFont(.meta)
                .disabled(sending)
                .accessibilityLabel(L10n.t("answer.reach"))
            }
            if Self.widens(reach.wrappedValue, from: target.start) {
                Text(L10n.t("answer.wider"))
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: host) { await session.refreshPostLimit(of: host) }
    }

    /// The post being answered, **kept in view while the answer is written** — its author and its
    /// words, in a box of its own that scrolls rather than pushing the editor off the sheet.
    private func answered(_ item: DummyItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                Text(String(format: L10n.t("answer.to"), item.author.isEmpty ? (item.handle ?? "") : item.author))
                    .shellFont(.meta, weight: .medium)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                Text(item.body)
                    .shellFont(.body)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 120)
        .padding(ShellSpace.snug)
        .background(ShellChrome.floatFill(colorScheme), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Self.answering(item)))
    }
}
