import FediqoCore
import SwiftUI

/// What a rule being added names, before it has an effect and a scope.
enum RuleTarget: Hashable {
    case source(String)
    case author(String)
    case keyword(String)
    /// A category as one source holds it. Public, trends and home mean the same on every
    /// Mastodon source; a board or a list is that source's own.
    case category(FediqoCore.Category, on: String)
}

/// The rule the editor may build, and only that: every scope offered is one the factories take,
/// and every target is one this device holds.
enum RuleBuilder {
    /// The scopes a target can be given. None for a source rule, which is its own scope.
    static func scopes(for target: RuleTarget, sources: [Source]) -> [RuleScope] {
        let every = sources.map { RuleScope.source(host: $0.host) }
        switch target {
        case .source:
            return []
        case .keyword:
            return [.every] + every
        case .author(let handle):
            // A forum author is that forum's; the factory would make it so whatever was asked.
            let instance = Fold.handle(handle).split(separator: "@").last.map(String.init) ?? ""
            if sources.contains(where: { $0.host == instance && $0.kind.isForum }) {
                return [.source(host: instance)]
            }
            return [.every] + every
        case .category(let category, let host):
            switch category {
            case .board, .list:
                return [.source(host: host)]
            case .public, .trends, .home:
                return [.every] + sources.filter(\.kind.hasTimelines).map { .source(host: $0.host) }
            }
        }
    }

    static func rule(
        _ target: RuleTarget, scope: RuleScope, effect: RuleEffect, sources: [Source]
    ) -> Rule? {
        switch target {
        case .source(let host): Rule.source(host, effect: effect)
        case .author(let handle): Rule.author(handle, in: scope, effect: effect, sources: sources)
        case .keyword(let text): Rule.keyword(text, in: scope, effect: effect)
        case .category(let category, _):
            Rule.category(category, in: scope, effect: effect, sources: sources)
        }
    }

    /// The categories each source can be picked by: public and trends on a Mastodon, Home where
    /// it is signed in, every list chosen on it, a forum's subscribed boards, and any other its
    /// held posts arrived through.
    static func categories(
        in sources: [Source], notes: [Note], signedIn: (String) -> Bool
    ) -> [(host: String, categories: [FediqoCore.Category])] {
        sources.compactMap { source in
            var picked: [FediqoCore.Category] = source.kind.hasTimelines ? [.public, .trends] : []
            if source.kind.hasTimelines, signedIn(source.host) { picked.append(.home) }
            picked += source.lists.map { .list(id: $0.id) }
            picked += source.boards.map { .board(id: String($0.fid)) }
            let held = Set(notes.filter { $0.source.host == source.host }.flatMap(\.categories))
            picked += held.subtracting(picked).sorted {
                RuleText.categoryName($0, host: source.host, sources: sources)
                    < RuleText.categoryName($1, host: source.host, sources: sources)
            }
            return picked.isEmpty ? nil : (source.host, picked)
        }
    }

    /// Handles of the authors this device holds posts by, most posts first.
    static func authors(in notes: [Note]) -> [String] {
        var counts: [String: Int] = [:]
        for note in notes {
            let handle = Fold.handle(note.handle)
            guard handle.contains("@") else { continue }
            counts[handle, default: 0] += 1
        }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
    }
}

/// A rule said in words: the row's parts, and the one sentence VoiceOver reads for it.
enum RuleText {
    static func effect(_ effect: RuleEffect, language: DummyLanguage? = nil) -> String {
        L10n.t(effect == .include ? "rule.show" : "rule.hide", language: language)
    }

    /// What the rule names, as the row prints it.
    static func target(_ rule: Rule, sources: [Source], language: DummyLanguage? = nil) -> String {
        switch rule.kind {
        case .source(let host): host
        case .author(let handle, _): "@" + handle
        case .keyword(let text, _): text
        case .category(let category, let scope):
            categoryName(category, host: host(of: scope), sources: sources, language: language)
        }
    }

    static func categoryName(
        _ category: FediqoCore.Category, host: String?, sources: [Source], language: DummyLanguage? = nil
    ) -> String {
        switch category {
        case .public: L10n.t("rule.category.public", language: language)
        case .trends: L10n.t("timeline.tab.trends", language: language)
        case .home: L10n.t("rule.category.home", language: language)
        case .list(let id):
            sources.first { $0.host == host }?.lists.first { $0.id == id }?.name
                ?? String(format: L10n.t("rule.category.list", language: language), id)
        case .board(let id):
            sources.first { $0.host == host }?.boards.first { String($0.fid) == id }?.name
                ?? String(format: L10n.t("rule.category.board", language: language), id)
        }
    }

    /// "posts containing “swift”" — the kind and its target.
    static func phrase(_ rule: Rule, sources: [Source], language: DummyLanguage? = nil) -> String {
        let key = switch rule.kind {
        case .source: "rule.source"
        case .author: "rule.author"
        case .keyword: "rule.keyword"
        case .category: "rule.category"
        }
        return String(format: L10n.t(key, language: language), target(rule, sources: sources, language: language))
    }

    /// "on every source" / "only on host", or nothing for a source rule.
    static func scope(_ rule: Rule, language: DummyLanguage? = nil) -> String? {
        if case .source = rule.kind { return nil }
        guard let host = host(of: rule.kind) else { return L10n.t("rule.scope.every", language: language) }
        return String(format: L10n.t("rule.scope.one", language: language), host)
    }

    /// The row as one sentence: effect, kind and target, scope, and whether it is missing.
    static func spoken(
        _ rule: Rule, status: RuleStatus, sources: [Source], language: DummyLanguage? = nil
    ) -> String {
        let effect = effect(rule.effect, language: language)
        let phrase = phrase(rule, sources: sources, language: language)
        var sentence = if let scope = scope(rule, language: language) {
            String(format: L10n.t("rule.spoken", language: language), effect, phrase, scope)
        } else {
            String(format: L10n.t("rule.spoken.plain", language: language), effect, phrase)
        }
        if status != .present {
            sentence += " " + L10n.t("rule.missing.spoken", language: language)
        }
        return sentence
    }

    private static func host(of kind: RuleKind) -> String? {
        switch kind {
        case .source(let host): host
        case .author(_, let scope), .keyword(_, let scope), .category(_, let scope): host(of: scope)
        }
    }

    static func host(of scope: RuleScope) -> String? {
        switch scope {
        case .every: nil
        case .source(let host): host
        }
    }
}

/// One rule in the editor: the effect word, the target (in a dashed socket where it is missing),
/// the scope, and its two actions. One accessibility element.
struct RuleRowView: View {
    let rule: Rule
    let status: RuleStatus
    let sources: [Source]
    /// Where `j` and `k` rest: `x` and ⌫ act on this row.
    var focused = false
    var onToggle: () -> Void
    var onRemove: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var missing: Bool { status != .present }

    var body: some View {
        HStack(spacing: ShellSpace.snug) {
            Image(systemName: rule.effect == .include ? "plus.circle" : "minus.circle")
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .accessibilityHidden(true)
            Button(action: onToggle) {
                Text(RuleText.effect(rule.effect))
                    .font(ShellType.meta.weight(.semibold))
                    .foregroundStyle(ShellChrome.selectInk(colorScheme))
                    .padding(.horizontal, ShellSpace.snug)
                    .padding(.vertical, ShellSpace.hair)
                    .background(Capsule(style: .continuous).fill(ShellChrome.selectFill(colorScheme)))
            }
            .buttonStyle(.plain)
            target
            if missing {
                Text(L10n.t("rule.missing"))
                    .font(ShellType.mark)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .help(L10n.t("rule.missing.help"))
            }
            Spacer(minLength: ShellSpace.snug)
            if let scope = RuleText.scope(rule) {
                Text(scope)
                    .font(ShellType.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .lineLimit(1)
            }
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(ShellType.meta)
                    .foregroundStyle(ShellChrome.inkFaint(colorScheme))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, ShellSpace.tight)
        .padding(.horizontal, ShellSpace.snug)
        // The rail's lamp: a float fill and a phosphor edge on the row the keys act on.
        .background(focused ? ShellChrome.floatFill(colorScheme) : .clear)
        .overlay(alignment: .leading) {
            if focused {
                Rectangle().fill(ShellChrome.phosphor(colorScheme)).frame(width: 2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(RuleText.spoken(rule, status: status, sources: sources))
        .accessibilityAction(named: Text(L10n.t(rule.effect == .include ? "rule.action.hide" : "rule.action.show")), onToggle)
        .accessibilityAction(named: Text(L10n.t("rule.action.remove")), onRemove)
    }

    @ViewBuilder
    private var target: some View {
        let text = Text(RuleText.target(rule, sources: sources))
            .font(ShellType.body)
            .lineLimit(1)
        if missing {
            // An empty socket: the part is not seated on the plate, and the rule still works.
            text
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                .padding(.horizontal, ShellSpace.snug)
                .padding(.vertical, ShellSpace.hair)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            ShellChrome.hairline(colorScheme),
                            style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                        )
                )
        } else {
            text.foregroundStyle(ShellChrome.ink(colorScheme))
        }
    }
}
