import FediqoCore
import SwiftUI

/// The lists a source keeps, on its page (#337). Drawn for every source. Where they cannot be
/// changed the same icon is dim and the place says why. Removing one is only in `…`, and asks
/// first.
struct ServerListsSection: View {
    let said: ServerListsSaid
    let lists: ShellServerLists
    let session: ShellSession
    var onAgain: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.step) {
            ShellSectionHead(
                L10n.t("lists.section.title"),
                line: String(format: L10n.t("lists.section.line"), said.source),
                help: L10n.t("lists.section.help")
            )
            switch said.stand {
            case .asking:
                Text(String(format: L10n.t("lists.asking"), said.source))
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
            case .failed(let sentence):
                failed(sentence)
            case .unavailable(let reason, let sentence):
                dim(sentence, reason: reason)
            case .ready, .locked:
                if let lock = said.lock { dim(lock, reason: .askAgain, asks: true) }
                maker
                if said.rows.isEmpty {
                    Text(L10n.t("lists.none"))
                        .shellFont(.meta)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                } else {
                    ForEach(said.rows) { row in list(row) }
                }
            }
            if let sentence = said.sentence, said.writes || said.lock != nil {
                Text(sentence)
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, ShellSpace.snug)
    }

    private var maker: some View {
        HStack(alignment: .center, spacing: ShellSpace.snug) {
            TextField(L10n.t("lists.make.field"), text: Binding(
                get: { said.making },
                set: { lists.setMaking($0, at: said.source) }
            ))
            .shellField(.alone)
            .accessibilityLabel(L10n.t("lists.make.field"))
            press(L10n.t("lists.make"), spoken: L10n.t("lists.make"), live: said.writes) {
                Task { await lists.make(at: said.source, in: session) }
            }
        }
    }

    private func list(_ row: ServerListsSaid.Row) -> some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            HStack(alignment: .center, spacing: ShellSpace.snug) {
                TextField(L10n.t("lists.rename.field"), text: Binding(
                    get: { row.draft },
                    set: { lists.setDraft($0, of: row.id, at: said.source) }
                ))
                .shellField(.alone)
                .accessibilityLabel(L10n.t("lists.rename.field"))
                press(L10n.t("lists.rename"), spoken: L10n.t("lists.rename"), live: said.writes) {
                    Task { await lists.rename(row.id, at: said.source, in: session) }
                }
            }
            HStack(alignment: .center, spacing: ShellSpace.snug) {
                replies(row)
                press(L10n.t("lists.home"), spoken: L10n.t("lists.home"), live: said.writes, on: row.alsoOnHome) {
                    Task { await lists.home(row.id, alsoOnHome: !row.alsoOnHome, at: said.source, in: session) }
                }
                press(L10n.t("lists.people"), spoken: L10n.t("lists.people"), live: true) {
                    lists.openMembers(row.id, at: said.source, in: session)
                }
                ShellMoreButton(label: ShellMore.label()) { more(row) }
                    .accessibilityLabel(L10n.t("lists.delete"))
            }
        }
    }

    @ViewBuilder
    private func replies(_ row: ServerListsSaid.Row) -> some View {
        if said.writes {
            Menu {
                ForEach(ListReplies.allCases, id: \.self) { replies in
                    Button(Self.name(replies)) {
                        Task { await lists.replies(row.id, replies, at: said.source, in: session) }
                    }
                }
            } label: {
                Text(Self.name(row.replies)).shellFont(.meta)
            }
            .accessibilityLabel(L10n.t("lists.answers") + " " + Self.name(row.replies))
        } else {
            press(Self.name(row.replies), spoken: L10n.t("lists.answers"), live: false) {}
        }
    }

    func more(_ row: ServerListsSaid.Row) -> ShellMore {
        if let lock = said.lock {
            let mark = ShellMark("list.bullet", L10n.t("lists.delete"), look: .dim(.askAgain))
            return ShellMore(items: [ShellMoreItem.plain(mark, ask: { _ = lists.ask(said.source, in: session) }, act: {}).because(lock)])
        }
        let title = row.title
        return ShellMore(items: [
            .danger("trash", L10n.t("lists.delete"), asks: lists.deleteQuestion(for: row.id, title: title, at: said.source, in: session)) {
                Task { await lists.remove(row.id, at: said.source, in: session) }
            },
        ])
    }

    private func failed(_ sentence: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
            Text(sentence)
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            Button(L10n.t("person.retry"), action: onAgain)
                .accessibilityLabel(L10n.t("person.retry"))
        }
    }

    private func dim(_ sentence: String, reason: DimReason, asks: Bool = false) -> some View {
        let mark = Label(sentence, systemImage: "list.bullet")
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.markDim(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
        return Group {
            if asks {
                Button(action: { _ = lists.ask(said.source, in: session) }) { mark }
                    .buttonStyle(.plain)
                    .accessibilityLabel(sentence)
                    .help(L10n.t("mark.dim.\(reason)"))
            } else {
                mark.accessibilityElement(children: .combine).accessibilityLabel(sentence).help(L10n.t("mark.dim.\(reason)"))
            }
        }
    }

    private func press(
        _ title: String, spoken: String, live: Bool, on: Bool = false, act: @escaping () -> Void
    ) -> some View {
        Button(action: {
            if live { act() } else if said.lock != nil { _ = lists.ask(said.source, in: session) }
        }) {
            Text(title)
                .shellFont(.meta, weight: on ? .semibold : .regular)
                .foregroundStyle(live ? ShellChrome.ink(colorScheme) : ShellChrome.markDim(colorScheme))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private static func name(_ replies: ListReplies) -> String {
        switch replies {
        case .followed: L10n.t("lists.answers.followed")
        case .list: L10n.t("lists.answers.list")
        case .none: L10n.t("lists.answers.none")
        }
    }
}

/// That block on a joined source's page, and the asking that is the page opening.
struct ServerListsBlock: View {
    let host: String
    let lists: ShellServerLists
    let session: ShellSession

    var body: some View {
        if let said = lists.said(at: host, in: session) {
            ServerListsSection(said: said, lists: lists, session: session, onAgain: {
                Task { await lists.again(host, in: session) }
            })
            .task(id: ShellServerLists.opening(host, in: session)) { await lists.opened(host, in: session) }
        }
    }
}

/// Which of the reader's lists a person is on.
struct PersonListsSheet: View {
    let lists: ShellServerLists
    let session: ShellSession
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let said = lists.personSaid() {
            ScrollView {
                VStack(alignment: .leading, spacing: ShellSpace.step) {
                    Text(said.name).shellFont(.body).foregroundStyle(ShellChrome.ink(colorScheme))
                    if said.asking {
                        Text(String(format: L10n.t("lists.asking"), said.source))
                            .shellFont(.meta).foregroundStyle(ShellChrome.inkDim(colorScheme))
                    }
                    if let locked = said.locked {
                        Text(locked).shellFont(.meta).foregroundStyle(ShellChrome.markDim(colorScheme))
                    }
                    ForEach(said.rows) { row in
                        Button(action: { Task { await lists.toggle(row.id, in: session) } }) {
                            Label(row.title, systemImage: row.on ? "checkmark.circle.fill" : "circle")
                                .shellFont(.meta)
                                .foregroundStyle(said.locked == nil ? ShellChrome.ink(colorScheme) : ShellChrome.markDim(colorScheme))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(row.title)
                        .accessibilityAddTraits(row.on ? .isSelected : [])
                    }
                    if let sentence = said.sentence {
                        Text(sentence).shellFont(.meta).foregroundStyle(ShellChrome.ink(colorScheme))
                    }
                    Button(L10n.t("servers.close")) { lists.closePerson() }
                        .accessibilityLabel(L10n.t("servers.close"))
                }
                .padding(ShellSpace.step)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Who is on one list, and the way to put somebody on it or take them off by their id.
struct MembersSheet: View {
    let lists: ShellServerLists
    let session: ShellSession
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let said = lists.membersSaid() {
            ScrollView {
                VStack(alignment: .leading, spacing: ShellSpace.step) {
                    Text(said.title).shellFont(.body).foregroundStyle(ShellChrome.ink(colorScheme))
                    if said.asking {
                        Text(String(format: L10n.t("lists.asking"), said.source))
                            .shellFont(.meta).foregroundStyle(ShellChrome.inkDim(colorScheme))
                    }
                    if let locked = said.locked {
                        Text(locked).shellFont(.meta).foregroundStyle(ShellChrome.markDim(colorScheme))
                    }
                    if said.people.isEmpty, !said.asking {
                        Text(L10n.t("lists.members.none"))
                            .shellFont(.meta).foregroundStyle(ShellChrome.inkDim(colorScheme))
                    }
                    ForEach(said.people) { person in
                        HStack {
                            Text(person.name).shellFont(.meta).foregroundStyle(ShellChrome.ink(colorScheme))
                            Spacer(minLength: 0)
                            Button(L10n.t("lists.member.remove")) {
                                Task { await lists.dropMember(person.id, in: session) }
                            }
                            .accessibilityLabel(L10n.t("lists.member.remove") + " " + person.name)
                            .foregroundStyle(said.locked == nil ? ShellChrome.ink(colorScheme) : ShellChrome.markDim(colorScheme))
                        }
                    }
                    HStack {
                        TextField(L10n.t("lists.member.field"), text: Binding(
                            get: { said.adding },
                            set: { lists.setAdding($0) }
                        ))
                        .shellField(.alone)
                        .accessibilityLabel(L10n.t("lists.member.field"))
                        Button(L10n.t("lists.member.add")) { Task { await lists.addMember(at: session) } }
                            .accessibilityLabel(L10n.t("lists.member.add"))
                    }
                    if let sentence = said.sentence {
                        Text(sentence).shellFont(.meta).foregroundStyle(ShellChrome.ink(colorScheme))
                    }
                    Button(L10n.t("servers.close")) { lists.closeMembers() }
                        .accessibilityLabel(L10n.t("servers.close"))
                }
                .padding(ShellSpace.step)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// The two sheets, in a modifier of their own so the root's chain of presenters stays short.
struct ServerListsPresenter: ViewModifier {
    let lists: ShellServerLists
    let session: ShellSession

    func body(content: Content) -> some View {
        content
            .sheet(item: person) { _ in PersonListsSheet(lists: lists, session: session) }
            .sheet(item: members) { _ in MembersSheet(lists: lists, session: session) }
    }

    private var person: Binding<ShellServerLists.PersonOpen?> {
        Binding(get: { lists.person }, set: { if $0 == nil { lists.closePerson() } })
    }

    private var members: Binding<ShellServerLists.MembersOpen?> {
        Binding(get: { lists.members }, set: { if $0 == nil { lists.closeMembers() } })
    }
}
