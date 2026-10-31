import FediqoCore
import SwiftUI

/// The sheet of a person's own collections, or of those somebody may be put in (#433).
///
/// **Drawn from a value** (`CollectionsSaid`), so what it says is what it was handed. What takes
/// something away is in a row's `…`, and asks first. A sentence said is read out as it comes.
struct CollectionsSheetBody: View {
    let said: CollectionsSaid
    var onMake: () -> Void = {}
    var onChange: (String) -> Void = { _ in }
    var onRemove: (String) -> Void = { _ in }
    var onToggle: (String) -> Void = { _ in }
    var onOpen: (String) -> Void = { _ in }
    var onBack: () -> Void = {}
    var onDrop: (String) -> Void = { _ in }
    var onDraft: (CollectionDraft) -> Void = { _ in }
    var onSave: () -> Void = {}
    var onCancel: () -> Void = {}
    var onClose: () -> Void = {}
    var onAgain: () -> Void = {}
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.step) {
            Text(said.person ?? String(format: L10n.t("collections.tend.line"), said.source))
                .shellFont(.body).foregroundStyle(ShellChrome.ink(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            if said.asking {
                line(String(format: L10n.t("collections.asking"), said.source))
            }
            if let failed = said.failed {
                Text(failed).shellFont(.meta).foregroundStyle(ShellChrome.ink(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                Button(L10n.t("collections.again"), action: onAgain)
                    .disabled(said.asking)
                    .accessibilityLabel(L10n.t("collections.again"))
            } else if let form = said.form {
                formView(form)
            } else if let opened = said.opened {
                members(opened)
            } else {
                rows
            }
            if let sentence = said.sentence {
                Text(sentence).shellFont(.meta).foregroundStyle(ShellChrome.ink(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(L10n.t("servers.close"), action: onClose)
                .disabled(said.writing)
                .accessibilityLabel(L10n.t("servers.close"))
        }
        .padding(ShellSpace.step)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func line(_ text: String) -> some View {
        Text(text).shellFont(.meta).foregroundStyle(ShellChrome.inkDim(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var rows: some View {
        if said.rows.isEmpty, !said.asking { line(L10n.t("collections.none")) }
        ForEach(said.rows) { row in
            if said.person != nil { toggle(row) } else { own(row) }
        }
        if said.person == nil {
            Button(L10n.t("collections.make"), action: onMake)
                .disabled(!said.live)
                .accessibilityLabel(L10n.t("collections.make"))
        }
    }

    /// What a row says, heard and read alike.
    private func words(_ row: CollectionsSaid.Row) -> String {
        var said: [String] = [row.name, L10n.count("person.collection.count", row.count)]
        if row.hidden { said.append(L10n.t("collections.hidden")) }
        if row.warns { said.append(L10n.t("collections.warned")) }
        return said.joined(separator: L10n.t("people.row.between"))
    }

    private func toggle(_ row: CollectionsSaid.Row) -> some View {
        let spoken = [words(row), row.waits ? L10n.t("collections.waits") : row.holds ? L10n.t("collections.in") : nil]
            .compactMap { $0 }.joined(separator: L10n.t("people.row.between"))
        return Button { onToggle(row.id) } label: {
            Label(spoken, systemImage: row.waits ? "clock" : row.holds ? "checkmark.circle.fill" : "circle")
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
        .disabled(!said.live)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(row.holds ? .isSelected : [])
    }

    private func own(_ row: CollectionsSaid.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ShellSpace.tight) {
            Button { onOpen(row.id) } label: {
                VStack(alignment: .leading, spacing: ShellSpace.hair) {
                    Text(words(row)).shellFont(.reading).foregroundStyle(ShellChrome.ink(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                    if let about = row.words {
                        Text(about).shellFont(.meta).foregroundStyle(ShellChrome.inkDim(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!said.live)
            .accessibilityLabel([words(row), row.words].compactMap { $0 }.joined(separator: L10n.t("people.row.between")))
            ShellMoreButton(more(row)).fixedSize()
        }
    }

    /// A collection's `…`: changing it, and — under the divider, asked first — removing it.
    func more(_ row: CollectionsSaid.Row) -> ShellMore {
        ShellMore(items: [
            .plain("pencil", L10n.t("collections.change")) { onChange(row.id) },
            .danger("trash", L10n.t("collections.remove"), asks: ShellQuestion.removeCollection(named: row.name, at: said.source)) { onRemove(row.id) },
        ])
    }

    @ViewBuilder
    private func members(_ opened: CollectionsSaid.Opened) -> some View {
        Button(L10n.t("collections.members.back"), action: onBack)
            .disabled(said.asking)
            .accessibilityLabel(L10n.t("collections.members.back"))
        Text(opened.name).shellFont(.reading).foregroundStyle(ShellChrome.ink(colorScheme))
        if opened.members.isEmpty, !said.asking { line(L10n.t("collections.members.none")) }
        ForEach(opened.members) { member in
            HStack(alignment: .firstTextBaseline, spacing: ShellSpace.tight) {
                let spoken = [member.name, member.handle, member.waits ? L10n.t("collections.waits") : nil]
                    .compactMap { $0 }.joined(separator: L10n.t("people.row.between"))
                Text(spoken).shellFont(.meta).foregroundStyle(member.waits ? ShellChrome.inkDim(colorScheme) : ShellChrome.ink(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(spoken)
                ShellMoreButton(more(member, of: opened.name)).fixedSize()
            }
        }
    }

    /// A person's `…` in a collection: taking them out, asked first.
    func more(_ member: CollectionsSaid.Member, of name: String) -> ShellMore {
        ShellMore(items: [
            .danger("person.crop.circle.badge.minus", L10n.t("collections.drop"), asks: ShellQuestion.dropFromCollection(person: member.name, named: name)) {
                onDrop(member.id)
            },
        ])
    }

    private func formView(_ form: CollectionsSaid.Form) -> some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            TextField(L10n.t("collections.field.name"), text: Binding(get: { form.draft.name }, set: { name in
                var draft = form.draft
                draft.name = name
                onDraft(draft)
            }))
            .shellField(.alone)
            .accessibilityLabel(L10n.t("collections.field.name"))
            TextField(L10n.t("collections.field.words"), text: Binding(get: { form.draft.words }, set: { words in
                var draft = form.draft
                draft.words = words
                onDraft(draft)
            }))
            .shellField(.alone)
            .accessibilityLabel(L10n.t("collections.field.words"))
            Toggle(L10n.t("collections.found"), isOn: Binding(get: { form.draft.discoverable }, set: { found in
                var draft = form.draft
                draft.discoverable = found
                onDraft(draft)
            }))
            .shellFont(.meta)
            Toggle(L10n.t("collections.warns"), isOn: Binding(get: { form.draft.sensitive }, set: { warns in
                var draft = form.draft
                draft.sensitive = warns
                onDraft(draft)
            }))
            .shellFont(.meta)
            HStack(spacing: ShellSpace.snug) {
                Button(L10n.t("collections.save"), action: onSave)
                    .disabled(!said.live || form.draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel(L10n.t("collections.save"))
                Button(L10n.t("collections.cancel"), action: onCancel)
                    .disabled(said.writing)
                    .accessibilityLabel(L10n.t("collections.cancel"))
            }
        }
    }
}

/// The sheet up, over its keeper.
struct CollectionsSheet: View {
    let collections: ShellCollections
    let session: ShellSession

    var body: some View {
        if let said = collections.said() {
            ScrollView {
                CollectionsSheetBody(
                    said: said,
                    onMake: { collections.startMaking() },
                    onChange: { collections.startChanging($0) },
                    onRemove: { id in Task { await collections.remove(id, in: session) } },
                    onToggle: { id in Task { await collections.toggle(id, in: session) } },
                    onOpen: { id in Task { await collections.openMembers(id, in: session) } },
                    onBack: { collections.closeMembers() },
                    onDrop: { id in Task { await collections.dropMember(id, in: session) } },
                    onDraft: { collections.setDraft($0) },
                    onSave: { Task { await collections.save(in: session) } },
                    onCancel: { collections.cancelForm() },
                    onClose: { collections.close() },
                    onAgain: { Task { await collections.again(in: session) } }
                )
            }
            .interactiveDismissDisabled(said.writing)
        }
    }
}

/// What puts the sheet up.
struct CollectionsPresenter: ViewModifier {
    let collections: ShellCollections
    let session: ShellSession

    func body(content: Content) -> some View {
        content.sheet(item: open) { _ in CollectionsSheet(collections: collections, session: session) }
    }

    private var open: Binding<CollectionsPresented?> {
        Binding(
            get: { collections.open.map { CollectionsPresented(id: $0.id) } },
            set: { if $0 == nil { collections.close() } }
        )
    }
}

/// Which sheet is up: the same one however much is said in it.
struct CollectionsPresented: Identifiable {
    let id: String
}
