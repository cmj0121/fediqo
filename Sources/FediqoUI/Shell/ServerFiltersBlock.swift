import FediqoCore
import SwiftUI

/// On a joined source's page: the person's filters there (#338) — listed as the source keeps
/// them, made, changed, and removed only from a row's `…`, asked first. Draws what
/// `ShellServerFilters.offer` hands it and decides nothing: dim with the part's own sentence, or
/// the sign-in's, where the sign-in held cannot tend them, whose press asks.
struct ServerFiltersBlock: View {
    let host: String
    let session: ShellSession
    @Environment(\.colorScheme) private var colorScheme
    @State private var editing: Editing?
    @State private var removing: ServerFilter?

    /// What the editor sheet is open on: a new filter, or one to change.
    struct Editing: Identifiable {
        let filter: ServerFilter?
        var id: String { filter?.id ?? "new" }
    }

    var body: some View {
        if let offer = session.serverFilters.offer(host: host, in: session) {
            ShellRule()
            VStack(alignment: .leading, spacing: ShellSpace.step) {
                ShellSectionHead(
                    String(format: L10n.t("filters.title"), host), line: L10n.t("filters.line"),
                    help: L10n.t("filters.help")
                )
                switch offer {
                case .locked(let sentence), .signIn(let sentence):
                    Button(sentence) { session.serverFilters.press(host: host, in: session) }
                        .buttonStyle(.plain)
                        .shellFont(.reading)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(sentence)
                case .list(let reading):
                    list(reading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(ShellSpace.pad)
            .task(id: host) { await session.serverFilters.read(host: host, in: session) }
            .sheet(item: $editing) { editing in
                ServerFilterEditor(filter: editing.filter) { draft in
                    Task {
                        if let filter = editing.filter {
                            await session.serverFilters.change(filter, to: draft, host: host, in: session)
                        } else {
                            await session.serverFilters.make(draft, host: host, in: session)
                        }
                    }
                }
            }
            .confirmationDialog(
                String(format: L10n.t("filters.remove.title"), removing?.title ?? ""),
                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                titleVisibility: .visible,
                presenting: removing
            ) { filter in
                Button(L10n.t("filters.remove.yes"), role: .destructive) {
                    Task { await session.serverFilters.remove(filter, host: host, in: session) }
                }
            } message: { _ in
                Text(String(format: L10n.t("filters.remove.line"), host))
            }
        }
    }

    @ViewBuilder
    private func list(_ reading: ShellServerFilters.Reading?) -> some View {
        switch reading {
        case nil, .reading?:
            ShellStatusLine(String(format: L10n.t("filters.reading"), host))
        case .failed(let why)?:
            sentence(why)
        case .read(let filters)?:
            if filters.isEmpty { sentence(String(format: L10n.t("filters.none"), host)) }
            ForEach(filters) { filter in row(filter) }
        }
        if let refused = session.serverFilters.refused[host.lowercased()] { sentence(refused) }
        ShellLinkButton(L10n.t("filters.new")) { editing = Editing(filter: nil) }
            .disabled(session.serverFilters.busy.contains(host.lowercased()))
    }

    private func row(_ filter: ServerFilter) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
            VStack(alignment: .leading, spacing: ShellSpace.hair) {
                Text(filter.title).shellFont(.reading)
                Text(ShellServerFilters.line(filter))
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            Menu {
                Button(L10n.t("filters.change")) { editing = Editing(filter: filter) }
                Button(L10n.t("filters.remove"), role: .destructive) { removing = filter }
            } label: {
                Image(systemName: "ellipsis")
                    .accessibilityLabel(String(format: L10n.t("filters.more"), filter.title))
            }
            .menuStyle(.button)
            .fixedSize()
        }
    }

    private func sentence(_ text: String) -> some View {
        Text(text)
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A filter made or changed: its name, what it does, where, with which words, for how long.
struct ServerFilterEditor: View {
    let filter: ServerFilter?
    let done: (ServerFilterDraft) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var action: ServerFilterAction = .warn
    @State private var places: Set<String> = ["home", "public"]
    @State private var lasts: Int?
    @State private var keywords: [ServerFilter.Keyword] = []
    @State private var adding = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField(L10n.t("filters.edit.name"), text: $title)
                Picker(L10n.t("filters.edit.action"), selection: $action) {
                    ForEach([ServerFilterAction.warn, .hide, .blur], id: \.self) {
                        Text(ShellServerFilters.actionName($0)).tag($0)
                    }
                }
                Section(L10n.t("filters.edit.places")) {
                    ForEach(ServerFilter.places, id: \.self) { place in
                        Toggle(ShellServerFilters.placeName(place), isOn: Binding(
                            get: { places.contains(place) },
                            set: { if $0 { places.insert(place) } else { places.remove(place) } }
                        ))
                    }
                }
                Section(L10n.t("filters.edit.words")) {
                    ForEach(keywords.indices, id: \.self) { at in
                        HStack {
                            Text(keywords[at].keyword)
                            Spacer()
                            Toggle(L10n.t("filters.edit.wholeWord"), isOn: $keywords[at].wholeWord)
                                .fixedSize()
                            Button(L10n.t("filters.edit.takeOut")) { keywords.remove(at: at) }
                                .accessibilityLabel(String(format: L10n.t("filters.edit.takeOut.spoken"), keywords[at].keyword))
                        }
                    }
                    HStack {
                        TextField(L10n.t("filters.edit.word"), text: $adding)
                        Button(L10n.t("filters.edit.add")) {
                            let word = adding.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !word.isEmpty else { return }
                            keywords.append(.init(keyword: word, wholeWord: true))
                            adding = ""
                        }
                    }
                }
                Picker(L10n.t("filters.edit.lasts"), selection: $lasts) {
                    ForEach((filter == nil ? [] : [ServerFilterDraft.unchanged]) + ShellServerFilters.lastings, id: \.self) {
                        Text(ShellServerFilters.lastingName($0)).tag($0)
                    }
                }
            }
            .navigationTitle(L10n.t(filter == nil ? "filters.edit.new" : "filters.edit.change"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.t("filters.edit.cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("filters.edit.done")) {
                        done(ServerFilterDraft(title: title, context: places, action: action, lasts: lasts, keywords: keywords))
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || places.isEmpty)
                }
            }
        }
        .onAppear {
            guard let filter else { return }
            title = filter.title
            action = filter.action
            places = filter.context
            keywords = filter.keywords
            // Left as the source has it, unless the person chooses anew.
            lasts = ServerFilterDraft.unchanged
        }
    }
}
