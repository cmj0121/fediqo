import FediqoCore
import SwiftUI

/// The cover, the language, whether the media is covered, and the files — above the editor,
/// so an answer, which shares the sheet, does not grow them. `pollFooter` is what a sheet says
/// under the poll of its own: the change sheet's line that votes are lost (X0 §1).
struct ComposeExtras<PollFooter: View>: View {
    @Binding var draft: PostDraft
    let controls: DraftControls
    @ViewBuilder let pollFooter: () -> PollFooter

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let limits = controls.media
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            TextField(L10n.t("compose.cover"), text: $draft.cover, axis: .vertical)
                .lineLimit(1...3)
                .shellFont(.body)
                .accessibilityLabel(L10n.t("compose.cover"))
            let coverLeft = ComposerSheet.remaining(draft.cover, limit: controls.limit)
            let coverLine = ComposerSheet.limitLine(remaining: coverLeft, limit: controls.limit)
            Text(coverLine)
                .shellFont(.reading)
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                .accessibilityLabel(coverLine)
            TextField(L10n.t("compose.language"), text: Binding(
                get: { draft.language },
                set: { controls.chooseLanguage($0) }
            ))
            .shellFont(.body)
            .accessibilityLabel(L10n.t("compose.language"))
            Toggle(L10n.t("compose.sensitive"), isOn: Binding(
                get: { draft.coversMedia == true },
                set: { controls.chooseCoversMedia($0) }
            ))
            .shellFont(.meta)
            .accessibilityLabel(L10n.t("compose.sensitive"))
            let countLine = String(format: L10n.t("compose.media.count"), draft.media.count, limits.count)
            Text(countLine)
                .shellFont(.reading)
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                .accessibilityLabel(countLine)
            ForEach(draft.media) { piece in
                mediaRow(piece, descriptionLimit: limits.descriptionLimit)
            }
            Button(L10n.t("compose.media.add")) { controls.addMedia() }
                .accessibilityLabel(L10n.t("compose.media.add"))
                .disabled(controls.quoteBlocks != nil)
            ComposePoll(draft: $draft, controls: controls)
                .disabled(controls.quoteBlocks != nil)
            if let blocks = controls.quoteBlocks {
                Text(blocks)
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            pollFooter()
            if let note = controls.mediaNote {
                Text(note)
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(note)
            }
            if let later = controls.later {
                LaterControl(at: $draft.at, slot: later, host: controls.host)
            }
        }
    }

    private func mediaRow(_ piece: UnsentMedia, descriptionLimit: Int) -> some View {
        // A file already on the post a change is written over (#332): named as being there.
        let name = PostDraft.kept(piece) ? String(format: L10n.t("change.media.kept"), piece.name) : piece.name
        return VStack(alignment: .leading, spacing: ShellSpace.hair) {
            HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
                Text(name)
                    .shellFont(.meta)
                    .lineLimit(1)
                    .accessibilityLabel(name)
                Spacer(minLength: ShellSpace.snug)
                Button(L10n.t("compose.media.remove")) { draft.media.removeAll { $0.id == piece.id } }
                    .accessibilityLabel(L10n.t("compose.media.remove"))
            }
            TextField(L10n.t("compose.media.description"), text: Binding(
                get: { draft.media.first { $0.id == piece.id }?.description ?? "" },
                set: { next in
                    guard let index = draft.media.firstIndex(where: { $0.id == piece.id }) else { return }
                    draft.media[index].description = next
                }
            ), axis: .vertical)
            .lineLimit(1...4)
            .shellFont(.body)
            .accessibilityLabel(L10n.t("compose.media.description"))
            if piece.description.count > descriptionLimit {
                let over = String(format: L10n.t("compose.media.description.over"), descriptionLimit)
                Text(over)
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .accessibilityLabel(over)
            }
        }
    }
}

/// The poll a post is written with (#331): its choices, whether more than one may be chosen,
/// how long it runs and whether its figures wait for the end — **held to what the source said
/// it takes**, which the composer reads beside the post's own length. A press to add one beside
/// a file says why there is none, as adding a file beside a poll does.
private struct ComposePoll: View {
    @Binding var draft: PostDraft
    let controls: DraftControls

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let limits = controls.polls
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            if let poll = draft.poll {
                editing(poll, least: limits.leastChoices, most: limits.choices, runs: controls.runs)
            } else {
                Button(L10n.t("compose.poll.add")) { controls.addPoll() }
                    .accessibilityLabel(L10n.t("compose.poll.add"))
            }
            if let line = controls.pollSays {
                Text(line)
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(line)
            }
        }
    }

    @ViewBuilder
    private func editing(_ poll: NewPoll, least: Int, most: Int, runs: [Int]) -> some View {
        let count = String(format: L10n.t("compose.poll.count"), poll.choices.count, most)
        HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
            Text(count)
                .shellFont(.reading)
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                .accessibilityLabel(count)
            Spacer(minLength: ShellSpace.snug)
            Button(L10n.t("compose.poll.remove")) { draft.poll = nil }
                .accessibilityLabel(L10n.t("compose.poll.remove"))
        }
        ForEach(Array(poll.choices.indices), id: \.self) { index in
            choice(index, of: poll, least: least)
        }
        if poll.choices.count < most {
            Button(L10n.t("compose.poll.addChoice")) { draft.addChoice(within: controls.polls) }
                .accessibilityLabel(L10n.t("compose.poll.addChoice"))
        }
        Toggle(L10n.t("compose.poll.multiple"), isOn: field(\.multiple))
            .shellFont(.meta)
            .accessibilityLabel(L10n.t("compose.poll.multiple"))
        Toggle(L10n.t("compose.poll.hide"), isOn: field(\.hidesTotals))
            .shellFont(.meta)
            .accessibilityLabel(L10n.t("compose.poll.hide"))
        Picker(L10n.t("compose.poll.runs"), selection: field(\.runs)) {
            ForEach(runs, id: \.self) { run in
                Text(ComposeWords.runsLine(run)).tag(run)
            }
        }
        .pickerStyle(.menu)
        .shellFont(.meta)
        .accessibilityLabel(L10n.t("compose.poll.runs"))
    }

    private func choice(_ index: Int, of poll: NewPoll, least: Int) -> some View {
        let name = String(format: L10n.t("compose.poll.choice"), index + 1)
        return HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
            TextField(name, text: Binding(
                get: { draft.poll?.choices[safe: index] ?? "" },
                set: { next in
                    guard draft.poll?.choices.indices.contains(index) == true else { return }
                    draft.poll?.choices[index] = next
                }
            ))
            .shellFont(.body)
            .accessibilityLabel(name)
            if poll.choices.count > least {
                Button(L10n.t("compose.poll.removeChoice")) { draft.removeChoice(at: index) }
                    .accessibilityLabel(String(format: L10n.t("compose.poll.removeChoice.named"), index + 1))
            }
        }
    }

    /// One field of the poll, as a binding the controls write through the draft.
    private func field<Value>(_ path: WritableKeyPath<NewPoll, Value>) -> Binding<Value> {
        Binding(
            get: { (draft.poll ?? .fresh)[keyPath: path] },
            set: { next in draft.poll?[keyPath: path] = next }
        )
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
