import FediqoCore
import SwiftUI

/// On a joined source's page: whether its new notices are told while Fediqo runs, which kinds,
/// and whether as the system's own notices too (#324). Draws what `ShellNoticesTold.offer` hands
/// it and decides nothing: dim with the part's or the sign-in's sentence where the sign-in held
/// cannot read notices, whose press asks; dim with a sentence where the source tells none.
struct NoticesToldControl: View {
    let host: String
    let session: ShellSession
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let offer = session.noticesTold.offer(host: host, in: session) {
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                switch offer {
                case .choice(let choice, let refused):
                    chosen(choice, systemRefused: refused)
                case .locked(let sentence), .signIn(let sentence):
                    Button(sentence) { session.noticesTold.press(host: host, in: session) }
                        .buttonStyle(.plain)
                        .shellFont(.reading)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(sentence)
                case .cannot(let sentence):
                    Text(sentence)
                        .shellFont(.meta)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ShellSpace.pad)
            .padding(.bottom, ShellSpace.step)
        }
    }

    @ViewBuilder
    private func chosen(_ choice: ShellNoticesTold.Choice, systemRefused: Bool) -> some View {
        let told = session.noticesTold
        let title = String(format: L10n.t("source.told"), host)
        Toggle(title, isOn: Binding(get: { choice.on }, set: { told.choose($0, host: host) }))
            .shellFont(.reading)
            .shellHelp(verbatim: String(format: L10n.t("source.told.help"), host), about: title)
        if choice.on {
            let system = L10n.t("source.told.system")
            Toggle(system, isOn: Binding(
                get: { choice.system },
                set: { on in Task { await told.chooseSystem(on, host: host) } }
            ))
            .shellFont(.reading)
            .disabled(systemRefused && !choice.system)
            .shellHelp(verbatim: L10n.t("source.told.system.help"), about: system)
            if systemRefused {
                Text(L10n.t("source.told.system.refused"))
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L10n.t("source.told.kinds"))
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .padding(.top, ShellSpace.tight)
            ForEach(Self.kinds, id: \.self) { kind in
                Toggle(NoticeWords.kindName(kind), isOn: Binding(
                    get: { !choice.off.contains(kind) },
                    set: { told.tell(kind, $0, host: host) }
                ))
                .shellFont(.reading)
            }
        }
    }

    /// The kinds the choice lists: every kind a source may send, then everything else as one.
    static let kinds: [String] = NoticeWords.named.map(\.narrowedAs) + [Notice.Kind.unknownKinds]
}
