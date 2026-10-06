import Foundation

// Fields that belong to one kind of source (#287): what a Mastodon says of a post beyond its
// author, its words and its categories. The concept's third level — a field the source names,
// for a filter to use — and each says what type it is, so a rule on one carries a name and a
// typed value and a field added later needs no new kind of rule.
//
// **Declared by the kind of source and read off the note.** A kind lists its fields
// (`ProtocolKind.fields`); a note answers for one by name (`Note.value(of:)`), and answers
// nothing where its source's kind declares no such field or the source said nothing — which is
// not a value, so no rule on that field shows the post or hides it.

/// What kind of thing a field holds.
///
/// **All five are here, and three are asked today.** A rule compares an option, a yes-or-no and
/// a text; a number and a date are named so a stored rule's shape does not change when a field
/// of one arrives, and nothing builds or compares one yet (`FieldValue.isAsked`).
///
/// **A text is compared whole, as its field folds it.** The one text field there is holds a
/// handle (`SourceField.holdsHandle`), folded as an author rule folds one; nothing here matches
/// part of a text, and a field that wanted that would have to say how.
public enum FieldType: Hashable, Sendable {
    case text
    case number
    case date
    /// Yes or no.
    case flag
    /// One of a set of options. `fixed` are the ones the kind of source names; `open` says the
    /// source may say others — a language — and then what is offered is what held posts say.
    case options(fixed: [String], open: Bool)
}

/// One field a kind of source declares: a name that does not change, and its type.
/// What a field is a fact about (#290), which is what a rule on it is asked of.
///
/// **Said by the field's own declaration**, so the one place rules are judged reads it off the
/// field and names no field: a field added later says which it is where it is declared.
public enum FieldSubject: Hashable, Sendable {
    /// What a post says or is — whom it was for, its language, its cover. A reblog has none of
    /// these of its own, so on a reblog a rule on such a field is asked of the post it reblogs:
    /// what hides a post hides its reblog.
    case post
    /// The item itself, whatever it shows — whether it is a reblog. Asked of the row the rule is
    /// judging and never of what that row reblogs.
    case item
}

public struct SourceField: Hashable, Sendable, Identifiable {
    /// Stable, and what a stored rule names. Never shown as it is.
    public let name: String
    public let type: FieldType

    public var id: String { name }

    /// What it is a fact about, and so what a rule on it is asked of. A post's, unless said.
    public let about: FieldSubject

    public init(name: String, type: FieldType, about: FieldSubject = .post) {
        self.name = name
        self.type = type
        self.about = about
    }

    /// How far a post was sent: `Audience`'s four, by their own names.
    public static let audience = SourceField(
        name: "audience", type: .options(fixed: Audience.allCases.map(\.rawValue), open: false)
    )
    /// The language a post says it is in, as its source spells it, folded to lower case. An open
    /// set: a source may say any language there is.
    public static let language = SourceField(name: "language", type: .options(fixed: [], open: true))
    /// Whether its author covered it — marked sensitive, or given a line of warning.
    public static let covered = SourceField(name: "covered", type: .flag)
    /// Whether the item is a reblog (#290): somebody passing a post on, as an item of its own.
    /// **About the item, not about a post** — the one field here that is — so a rule hiding
    /// reblogs hides the reblog's row and leaves the row of the post it reblogs where the rules
    /// let it through, and a rule showing only reblogs shows no post for being reblogged.
    public static let reblog = SourceField(name: "reblog", type: .flag, about: .item)

    /// Whose post a reblog reblogs (#290): the handle of the author of the post reblogged, as
    /// `user@instance`, folded as an author rule's is. **About the item** — only a reblog says
    /// it. A post says nothing for it, whoever wrote it and however it arrived, so a rule on
    /// this neither shows a post nor hides one: hiding reblogs of a person leaves that person's
    /// own posts, and showing them shows no post. **And a reblog whose post is not held says
    /// nothing**: who wrote it is the post's own item's to say, and there is none here.
    public static let reblogOf = SourceField(name: "reblogOf", type: .text, about: .item)

    /// Whether this field's text is a handle: compared as `user@instance`, folded, and taken in
    /// the editor the way an author rule's handle is.
    public var holdsHandle: Bool { self == .reblogOf }

    /// Every field any kind of source declares, by name: what a rule's value is held to
    /// (`accepts`), whichever of the reader's sources are here.
    public static let declared: [String: SourceField] = Dictionary(
        ProtocolKind.allCases.flatMap(\.fields).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first }
    )

    /// The longest a language tag may be: BCP 47's own bound for a well-formed one.
    public static let longestLanguage = 35

    /// `raw` as a language is kept — folded to lower case — where it looks like a language tag:
    /// ASCII letters, digits and hyphens, not empty, and no longer than a tag can be. Nothing
    /// otherwise. **Somebody else's server wrote it**, and it is stored with the post, offered in
    /// the editor's list and drawn in a rule's name: a megabyte of it, or a line of control
    /// characters, is not a language and is kept nowhere.
    public static func languageTag(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.utf8.count <= longestLanguage,
              raw.utf8.allSatisfy({ byte in
                  (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
                      || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2D
              })
        else { return nil }
        return raw.lowercased()
    }

    /// Whether `value` is one this field can hold: of its type, and — for options that are not
    /// open — one of them. An open field takes any option that is well-formed for it, which for a
    /// language is a language tag. A rule asking a declared field for anything else could never
    /// match, and is never made (`Rule.field`).
    public func accepts(_ value: FieldValue) -> Bool {
        switch (type, value) {
        case (.flag, .flag), (.number, .number), (.date, .date):
            return true
        // A handle is held as `Rule.handle` folds one, and as nothing else.
        case (.text, .text(let text)):
            return holdsHandle && Rule.handle(text) == text
        case (.options(let fixed, let open), .option(let option)):
            if fixed.contains(option) { return true }
            guard open else { return false }
            return self == .language ? Self.languageTag(option) == option : !option.isEmpty
        default:
            return false
        }
    }
}

/// A field's value, typed as its field is.
public enum FieldValue: Hashable, Sendable {
    case text(String)
    case number(Double)
    case date(Date)
    case flag(Bool)
    case option(String)

    /// Whether a rule can be asked of this kind of value today: an option, a yes-or-no, or a
    /// text — and a text only of a field that holds a handle, which `Rule.field` holds it to.
    public var isAsked: Bool {
        switch self {
        case .flag, .option, .text: true
        case .number, .date: false
        }
    }

    /// The value as two copies of it are compared: an option folded to lower case, so `JA` and
    /// `ja` are one language.
    var folded: FieldValue {
        if case .option(let option) = self { return .option(option.lowercased()) }
        return self
    }
}

extension ProtocolKind {
    /// The fields a source of this kind says of a post, beyond the ones every source has. None
    /// for a kind that declares none — which today is every kind but Mastodon.
    ///
    /// **No `default:`**, this package's standing rule: a protocol added later has to say.
    ///
    /// **Five fields, and the editor's digits are spent.** The kinds are picked by 1–4 and each
    /// field offered by the next digit, so a tenth pill has no digit: it is reached as every pill
    /// already is without one — pressed, or walked to with Tab, which the kinds stage leaves to
    /// the system — and `EditorAction.from` says the same where the digits are read. Whoever
    /// declares a sixth field here should look there before they do.
    public var fields: [SourceField] {
        switch self {
        case .mastodon:
            [.audience, .language, .covered, .reblog, .reblogOf]
        case .pleroma, .akkoma, .misskey, .pixelfed, .lemmy, .peertube, .friendica, .gotosocial,
            .discourse, .discuz, .unknown:
            []
        }
    }

    /// The field this kind declares under `name`, or nothing.
    public func field(named name: String) -> SourceField? {
        fields.first { $0.name == name }
    }
}

extension Note {
    /// Whether its author covered it, or nothing where its source never said either way: marked
    /// sensitive, or given a line of warning — the row's own rule (`DummyItem.covered`), with
    /// silence kept apart from a no.
    public var covered: Bool? {
        if sensitive == nil, spoiler == nil { return nil }
        return sensitive == true || !(spoiler ?? "").isEmpty
    }

    /// What this note's source says of it for the field `name`, or nothing — where its kind of
    /// source declares no such field, and where the source said nothing. **Nothing is not a
    /// value**: a rule on the field neither shows such a post nor hides it.
    ///
    /// `reblogged` is the post this item reblogs, where it is a reblog and that post is held —
    /// handed in by whoever holds the notes, as `CompiledTimeline.verdict` is handed it. A field
    /// about what an item reblogs is read off it, and says nothing without it.
    public func value(of name: String, reblogged: Note? = nil) -> FieldValue? {
        guard let field = source.kind.field(named: name) else { return nil }
        switch field {
        case .audience: return audience.map { .option($0.rawValue) }
        case .language: return language.map { .option($0) }
        case .covered: return covered.map { .flag($0) }
        // Always said, by what the item is: a reblog is one, and everything else is not — a post
        // held from before a reblog was an item, which arrived as somebody's reblog, included.
        // It is the post.
        case .reblog: return .flag(isReblog)
        // Only a reblog says it, and only of a post held from the same source: a name that
        // spells another host is not looked at.
        case .reblogOf:
            guard isReblog, let reblogged, !reblogged.isReblog, reblogged.source.host == source.host,
                  let handle = Rule.handle(reblogged.handle)
            else { return nil }
            return .text(handle)
        default: return nil
        }
    }
}
