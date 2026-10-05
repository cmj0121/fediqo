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
/// **All five are here, and two are asked today.** A rule compares an option and a yes-or-no;
/// text, a number and a date are named so a stored rule's shape does not change when a field of
/// one arrives, and nothing builds or compares one yet (`FieldValue.isAsked`).
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
public struct SourceField: Hashable, Sendable, Identifiable {
    /// Stable, and what a stored rule names. Never shown as it is.
    public let name: String
    public let type: FieldType

    public var id: String { name }

    public init(name: String, type: FieldType) {
        self.name = name
        self.type = type
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
        case (.flag, .flag), (.text, .text), (.number, .number), (.date, .date):
            return true
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

    /// Whether a rule can be asked of this kind of value today: an option, or a yes-or-no.
    public var isAsked: Bool {
        switch self {
        case .flag, .option: true
        case .text, .number, .date: false
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
    /// **Past five fields the editor's digits run out.** The kinds are picked by 1–4 and each
    /// field offered by the next digit, so a tenth pill has no digit: it is reached as every pill
    /// already is without one — pressed, or walked to with Tab, which the kinds stage leaves to
    /// the system — and `EditorAction.from` says the same where the digits are read. Whoever
    /// declares a sixth field here should look there before they do.
    public var fields: [SourceField] {
        switch self {
        case .mastodon:
            [.audience, .language, .covered]
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
    public func value(of name: String) -> FieldValue? {
        guard let field = source.kind.field(named: name) else { return nil }
        switch field {
        case .audience: return audience.map { .option($0.rawValue) }
        case .language: return language.map { .option($0) }
        case .covered: return covered.map { .flag($0) }
        default: return nil
        }
    }
}
