import FediqoCore
import Foundation

/// What a person's page says of the reader's own note on them and of who is known in common
/// (#377), as values a test reads without drawing them.
enum PersonNoteWords {
    static func title(language: DummyLanguage? = nil) -> String {
        L10n.t("person.note.title", language: language)
    }

    /// What stands where no note is written: that there is none, and who reads one.
    static func none(language: DummyLanguage? = nil) -> String {
        L10n.t("person.note.none", language: language)
    }

    /// The press that writes it: to write one, or to change the one there is.
    static func write(_ note: String?, language: DummyLanguage? = nil) -> String {
        L10n.t(note == nil ? "person.note.write" : "person.note.change", language: language)
    }

    static func keep(language: DummyLanguage? = nil) -> String {
        L10n.t("person.note.keep", language: language)
    }

    /// What a listener is read of the note.
    static func spoken(_ note: String?, language: DummyLanguage? = nil) -> String {
        guard let note else { return none(language: language) }
        return String(format: L10n.t("person.note.spoken", language: language), note)
    }

    /// A note written here that did not arrive: said under it.
    static func missed(_ host: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("person.note.missed", language: language), host)
    }

    /// A note the source would not keep — one too long — in the source's own words.
    static func refused(_ sentence: String, at host: String, language: DummyLanguage? = nil) -> String {
        sentence.isEmpty
            ? String(format: L10n.t("person.note.refused.unsaid", language: language), host)
            : String(format: L10n.t("person.note.refused", language: language), host, sentence)
    }

    /// The head's figure of who is in common: the glyph, how many, and what it is.
    static func figure(_ count: Int, language: DummyLanguage? = nil) -> PersonSaid.Figure {
        PersonSaid.Figure(
            tab: .about, figure: L10n.grouped(count, language: language), words: familiar(count, language: language),
            glyph: familiarSymbol
        )
    }

    /// The glyph of who is in common, in the head and over the faces.
    static let familiarSymbol = "person.2"

    /// Where the sign-in lacks the account part: the part's own sentence.
    static func locked(_ lock: PartWords.Place, at host: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t(lock.key, language: language), host)
    }

    /// "Followed by 3 people you follow": what the faces are.
    static func familiar(_ count: Int, language: DummyLanguage? = nil) -> String {
        L10n.count("person.familiar", count, language: language)
    }

    /// What pressing a face is called: their page.
    static func open(_ person: Person, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("item.person.open", language: language), person.lineName.isEmpty ? person.lineHandle : person.lineName)
    }
}
