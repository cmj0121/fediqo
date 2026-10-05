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
    /// A value of a field one kind of source declares (#287): the field's name, and the value.
    case field(String, FieldValue)
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
            case .public, .home:
                return [.every] + sources.filter(\.kind.hasTimelines).map { .source(host: $0.host) }
            // A Discuz!'s ranking lists are its Trends; public and home are still never a forum's.
            case .trends:
                return [.every] + sources.filter(\.kind.hasTrends).map { .source(host: $0.host) }
            }
        // Every source, or one whose kind declares the field: no other could match it.
        case .field(let name, _):
            return [.every] + sources.filter { $0.kind.field(named: name) != nil }.map { .source(host: $0.host) }
        }
    }

    /// The fields the reader's sources declare, each once, in the order their kinds list them
    /// (#287). What the editor offers a rule on — and nothing where no source here declares one.
    static func fields(in sources: [Source]) -> [SourceField] {
        var seen: Set<String> = []
        return sources.flatMap(\.kind.fields).filter { seen.insert($0.name).inserted }
    }

    /// How many values of an open field are offered: the ones most held posts say.
    static let valuesOffered = 60

    /// The values of `field` a rule may ask for (#287) — **only ones the reader's sources can
    /// give**: a yes and a no; a fixed set of options as its kind names them; and, where a field
    /// is open — a language — what held posts from sources that declare it say, most posts first.
    static func values(of field: SourceField, sources: [Source], notes: [Note]) -> [FieldValue] {
        switch field.type {
        case .flag:
            return [.flag(true), .flag(false)]
        case .options(let fixed, let open):
            guard open else { return fixed.map(FieldValue.option) }
            var counts: [String: Int] = [:]
            let hosts = Set(sources.filter { $0.kind.field(named: field.name) != nil }.map(\.host))
            for note in notes where hosts.contains(note.source.host) {
                if case .option(let said)? = note.value(of: field.name) { counts[said, default: 0] += 1 }
            }
            let held = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
            return (fixed + held.filter { !fixed.contains($0) }).prefix(valuesOffered).map(FieldValue.option)
        // Nothing asks one of these yet, so nothing is offered for one.
        case .text, .number, .date:
            return []
        }
    }

    static func rule(
        _ target: RuleTarget, scope: RuleScope, effect: RuleEffect, sources: [Source], id: Rule.ID = UUID()
    ) -> Rule? {
        switch target {
        case .source(let host): Rule.source(host, effect: effect, id: id)
        case .author(let handle): Rule.author(handle, in: scope, effect: effect, sources: sources, id: id)
        case .keyword(let text): Rule.keyword(text, in: scope, effect: effect, id: id)
        case .category(let category, _):
            Rule.category(category, in: scope, effect: effect, sources: sources, id: id)
        case .field(let name, let value): Rule.field(name, is: value, in: scope, effect: effect, id: id)
        }
    }

    /// The categories each source can be picked by: public and trends on a Mastodon, trends on a
    /// Discuz! (its ranking lists), Home where it is signed in, every list chosen on it, a forum's subscribed boards, and any other its
    /// held posts arrived through.
    static func categories(
        in sources: [Source], notes: [Note], signedIn: (String) -> Bool
    ) -> [(host: String, categories: [FediqoCore.Category])] {
        sources.compactMap { source in
            var picked: [FediqoCore.Category] = source.kind.hasTimelines ? [.public] : []
            if source.kind.hasTrends { picked.append(.trends) }
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
        case .field(let name, let value, _):
            String(
                format: L10n.t("rule.field.title", language: language),
                fieldName(name, language: language), valueName(value, of: name, language: language)
            )
        }
    }

    /// What a field is called, in the shell's language — or by its own name, for one this build
    /// has no word for.
    static func fieldName(_ name: String, language: DummyLanguage? = nil) -> String {
        let key = "rule.field.\(name)"
        let said = L10n.t(key, language: language)
        return said == key ? name : said
    }

    /// What a field's value is called (#287): how far a post was sent by the composer's own
    /// words for it, a language by its name in the shell's language where the system has one and
    /// by its code where it has none, a yes or a no.
    static func valueName(_ value: FieldValue, of name: String, language: DummyLanguage? = nil) -> String {
        switch value {
        case .flag(let yes):
            return L10n.t(yes ? "rule.field.yes" : "rule.field.no", language: language)
        case .option(let option):
            if name == SourceField.audience.name, let audience = Audience(rawValue: option) {
                return L10n.t(ComposerSheet.visibilityKey(audience), language: language)
            }
            if name == SourceField.language.name {
                return L10n.locale(language).localizedString(forIdentifier: option) ?? option
            }
            return option
        case .text(let text): return text
        case .number(let number): return number.formatted(.number.locale(L10n.locale(language)))
        case .date(let date): return date.formatted(.dateTime.year().month().day().locale(L10n.locale(language)))
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
        if case .field(let name, let value, _) = rule.kind {
            return fieldPhrase(name, value, language: language)
        }
        let key = switch rule.kind {
        case .source: "rule.source"
        case .author: "rule.author"
        case .keyword: "rule.keyword"
        case .category, .field: "rule.category"
        }
        return String(format: L10n.t(key, language: language), target(rule, sources: sources, language: language))
    }

    /// A rule on a field as the middle of a sentence (#287): "posts in Japanese", "posts sent to
    /// Followers", "posts their author covered" — each field's own phrase where it has one, and
    /// "posts whose <field> is <value>" for a field this build has no phrase for.
    static func fieldPhrase(_ name: String, _ value: FieldValue, language: DummyLanguage? = nil) -> String {
        let said = valueName(value, of: name, language: language)
        var key = "rule.field.\(name).phrase"
        if case .flag(let yes) = value { key += yes ? ".yes" : ".no" }
        let phrase = L10n.t(key, language: language)
        guard phrase == key else { return String(format: phrase, said) }
        return String(format: L10n.t("rule.field.phrase", language: language), fieldName(name, language: language), said)
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
        case .author(_, let scope), .keyword(_, let scope), .category(_, let scope), .field(_, _, let scope):
            host(of: scope)
        }
    }

    static func host(of scope: RuleScope) -> String? {
        switch scope {
        case .every: nil
        case .source(let host): host
        }
    }
}

/// One rule in the editor's list (#237), as every list's row (`ShellListRow`): the kind's glyph,
/// what the rule names, and its effect and scope in a line under it; "missing" as the row's figure
/// where what it names is gone, and why it still counts behind a (?) after it. Entering the row opens the rule where it is changed or removed.
struct RuleRowView: View {
    let rule: Rule
    let status: RuleStatus
    let sources: [Source]
    /// Where `j` and `k` rest: `x` and ⌫ act on this row, and Return opens it.
    @Binding var selection: Rule.ID?
    let onOpen: () -> Void
    let onStep: (Int) -> Void

    var body: some View {
        ShellListRow(
            id: rule.id,
            title: RuleText.target(rule, sources: sources),
            brief: RuleText.brief(rule),
            figure: status == .present ? nil : L10n.t("rule.missing"),
            // The kind is only the mark on screen; VoiceOver hears the rule as one sentence.
            spoken: RuleText.spoken(rule, status: status, sources: sources),
            selection: $selection,
            onOpen: onOpen,
            onStep: onStep
        ) {
            Image(systemName: TimelineEditor.kindSymbol(rule.kind.tag))
        } control: {
            // Why a missing rule is kept, behind its (?) rather than on the row.
            if status != .present {
                ShellHelp("rule.missing.help", about: RuleText.target(rule, sources: sources))
            }
        }
    }
}

extension RuleText {
    /// The row's brief line: the effect, and the scope where the rule has one — "Show, on every
    /// source".
    static func brief(_ rule: Rule, language: DummyLanguage? = nil) -> String {
        let effect = effect(rule.effect, language: language)
        guard let scope = scope(rule, language: language) else { return effect }
        return String(format: L10n.t("rule.brief", language: language), effect, scope)
    }
}
