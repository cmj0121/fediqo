import SwiftUI

/// Preferences' fourth tab (#226): everything the app may reach beyond a source, as a list the
/// person reads and edits. Everything said is `Allowance`'s and everything changed is
/// `AllowanceBook`'s, which is where both are decided and tested; this lays them out.
///
/// **The app's own entries** each say what they let through, when, and why, with a switch: off,
/// what it let through is refused like anything else, at once. **The person's own** are a host
/// for one of their sources, marked as theirs, with a way to remove each and a way to add one.
struct AllowanceSection: View {
    let book: AllowanceBook
    /// The sources the person has, as a host is added for one of them.
    let sources: [String]

    @Environment(\.colorScheme) private var colorScheme
    @State private var typed = ""
    @State private var chosen = ""
    @State private var refusal: AllowanceBook.Refusal?

    var body: some View {
        Section {
            ForEach(Allowance.standing) { entry in
                Toggle(isOn: on(entry.id)) { EntryText(entry: entry) }
                    .accessibilityLabel(Text(entry.spoken()))
            }
        } header: {
            Text(L10n.t("allow.builtIn"))
        } footer: {
            Text(L10n.t("allow.builtIn.footer"))
                .shellFont(.meta)
        }
        Section {
            if book.own.isEmpty {
                Text(L10n.t("allow.own.none"))
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
            }
            ForEach(book.own) { entry in
                HStack(alignment: .top, spacing: ShellSpace.step) {
                    EntryText(entry: entry, gone: !served(entry))
                    Spacer(minLength: 0)
                    Button(role: .destructive) {
                        book.remove(entry.id)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(String(format: L10n.t("allow.own.remove"), entry.title()))
                }
                .accessibilityElement(children: .contain)
            }
            adding
        } header: {
            Text(L10n.t("allow.own"))
        } footer: {
            Text(L10n.t("allow.own.footer"))
                .shellFont(.meta)
        }
    }

    /// A host, and the source it is for.
    @ViewBuilder
    private var adding: some View {
        if sources.isEmpty {
            Text(L10n.t("allow.own.noSource"))
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
        } else {
            Picker(L10n.t("allow.own.source"), selection: source) {
                ForEach(sources, id: \.self) { Text($0).tag($0) }
            }
            HStack(spacing: ShellSpace.snug) {
                TextField(L10n.t("allow.own.host"), text: $typed)
                    .textFieldStyle(.plain)
                    .onSubmit(add)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .autocorrectionDisabled()
                    .accessibilityLabel(L10n.t("allow.own.host"))
                Button(L10n.t("allow.own.add"), action: add)
                    .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let refusal {
                Text(Self.sentence(refusal))
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.alarm(colorScheme))
            }
        }
    }

    /// The source a host is added for: the one chosen while it is still a source, the first
    /// otherwise.
    private var source: Binding<String> {
        Binding(
            get: { sources.contains(chosen) ? chosen : sources.first ?? "" },
            set: { chosen = $0 }
        )
    }

    private func on(_ id: Allowance.ID) -> Binding<Bool> {
        Binding(get: { book.isOn(id) }, set: { book.set(id, on: $0) })
    }

    /// Whether the source an entry serves is among the person's now.
    private func served(_ entry: Allowance) -> Bool {
        sources.contains { SourceWork.fold($0) == entry.source }
    }

    private func add() {
        refusal = book.add(typed, for: source.wrappedValue)
        if refusal == nil { typed = "" }
    }

    static func sentence(_ refusal: AllowanceBook.Refusal, language: DummyLanguage? = nil) -> String {
        switch refusal {
        case .notAHost: L10n.t("allow.own.refused.notAHost", language: language)
        case .itsOwnHost: L10n.t("allow.own.refused.itsOwnHost", language: language)
        case .alreadyThere: L10n.t("allow.own.refused.alreadyThere", language: language)
        case .wildcard: L10n.t("allow.own.refused.wildcard", language: language)
        case .address: L10n.t("allow.own.refused.address", language: language)
        case .port: L10n.t("allow.own.refused.port", language: language)
        case .path: L10n.t("allow.own.refused.path", language: language)
        }
    }
}

/// One entry as the list says it: what it is — marked where it is the person's — what it lets
/// through, when, why, and the hosts.
struct EntryText: View {
    let entry: Allowance
    /// Whether the source it serves is no longer one the person has.
    var gone = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            HStack(spacing: ShellSpace.snug) {
                Text(entry.title())
                    .lineLimit(1)
                    .truncationMode(.middle)
                if entry.source != nil {
                    Text(L10n.t("allow.own.mark"))
                        .shellFont(.meta, weight: .semibold)
                        .foregroundStyle(ShellChrome.selectInk(colorScheme))
                        .padding(.horizontal, ShellSpace.snug)
                        .background(Capsule(style: .continuous).fill(ShellChrome.selectFill(colorScheme)))
                }
            }
            Group {
                Text(entry.what())
                Text(entry.whenText())
                Text(entry.why())
                Text(entry.hostsText())
                    .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                if gone {
                    Text(L10n.t("allow.own.gone"))
                        .foregroundStyle(ShellChrome.alarm(colorScheme))
                }
            }
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(entry.spoken() + (gone ? L10n.t("allow.spoken.joiner") + L10n.t("allow.own.gone") : "")))
    }
}
