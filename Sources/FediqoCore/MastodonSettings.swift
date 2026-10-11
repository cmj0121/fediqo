import Foundation

// What the person set at a Mastodon for the posts they write there (#321): who a new post is
// for, its language, and whether its media is covered.
//
// **Asked of a real one first** (`MastodonSettingsCaptures`). It is given only to somebody
// signed in — with no sign-in, and with a token that is none, the server answers that the
// token is not valid — and to this app's reading sign-in as to one that may do everything.
// A sign-in without the word for reading the person's own account is refused it, which is a
// refusal of that sign-in and not the end of it. The answer is one flat list of settings named
// by the server; three of them are read here, and the rest — how the person reads, who may
// quote them — are other units' to read. **Where the person set no language the server still
// answers one**, and not the same one to every asker: the language read here is the source's
// word, and is not known to be a thing the person chose.
//
// **The server's word about the person's own settings, and still a stranger's**: each value is
// known or it is kept as the server wrote it, bounded and made fit for a line of ours. Nothing
// here is an address, and nothing here is believed about anybody else.
//
// **Read, and never written**: changing what the person set there is not this app's to do.

/// What somebody set at a source for the posts they write there, as the source says it.
public struct PostingDefaults: Sendable, Hashable {
    /// Who a new post is for: one of the reaches this app knows, or the source's own word for
    /// one it does not.
    public enum Reach: Sendable, Hashable {
        case known(Audience)
        /// A word this build does not know, as the source wrote it, fit for a line.
        case other(String)
    }

    /// Who a new post is for, where the source said.
    public let reach: Reach?
    /// The language a new post is written in, as the tag the source gave — `en`, `zh-TW` —
    /// fit for a line. Nothing where it gave none.
    public let language: String?
    /// Whether a new post's media is covered, where the source said.
    public let coversMedia: Bool?

    /// How long a word of the source's is kept: a reach is a word, a language a short tag.
    public static let wordLength = 35

    public init(reach: Reach? = nil, language: String? = nil, coversMedia: Bool? = nil) {
        self.reach = reach
        self.language = language.flatMap(Self.word)
        self.coversMedia = coversMedia
    }

    /// A word of the source's made fit for a line of ours, or nothing where nothing is left.
    static func word(_ raw: String) -> String? {
        let clean = LineText.oneLine(raw, limit: wordLength).trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? nil : clean
    }

    /// A reach as a Mastodon names it: one this app knows, or its own word, cleaned.
    static func reach(_ raw: String) -> Reach? {
        if let known = Audience(mastodon: raw) { return .known(known) }
        return word(raw).map(Reach.other)
    }
}

/// What a read of the person's settings could not make anything of.
public enum MastodonSettingsError: Error, Equatable, Sendable {
    /// The source answered, and not with a list of settings.
    case unreadable
}

/// A Mastodon asked what the person set there: `/api/v1/preferences`, **as them and no other
/// way** — through the one signed-in door, to the host the sign-in is of.
///
/// **Nothing here writes anywhere on this device**: a read lands in what it returns, and one
/// that is refused or fails throws what the door threw — `MastodonAuthError.http(403)` where
/// the sign-in was not given this, `.signedOut` where the door confirmed the sign-in is over.
public struct MastodonSettings: Sendable {
    private let door: MastodonAuthorized

    public init(door: MastodonAuthorized) {
        self.door = door
    }

    static let path = "/api/v1/preferences"
    static let reachKey = "posting:default:visibility"
    static let languageKey = "posting:default:language"
    static let coversKey = "posting:default:sensitive"

    /// What the person set for the posts they write. **Setting by setting**: one that is
    /// missing, or of another shape, is that one not said — and never the others.
    public func postingDefaults() async throws -> PostingDefaults {
        try Self.postingDefaults(from: try await door.get(path: Self.path))
    }

    /// The answer read. Throws `unreadable` where it is no list of settings at all.
    static func postingDefaults(from body: Data) throws -> PostingDefaults {
        // The server's names are kept as it wrote them: this decoder renames nothing.
        guard let said = try? JSONDecoder().decode([String: Loose].self, from: body) else {
            throw MastodonSettingsError.unreadable
        }
        return PostingDefaults(
            reach: said[reachKey]?.text.flatMap(PostingDefaults.reach), language: said[languageKey]?.text,
            coversMedia: said[coversKey]?.flag
        )
    }

    /// One setting's value, whatever its shape: words, a yes or a no, or something else that
    /// is neither — which says nothing.
    private enum Loose: Decodable {
        case text(String)
        case flag(Bool)
        case other

        init(from decoder: any Decoder) throws {
            let container = try? decoder.singleValueContainer()
            if let flag = try? container?.decode(Bool.self) {
                self = .flag(flag)
            } else if let text = try? container?.decode(String.self) {
                // Bounded before it is cleaned: a word, not a page.
                self = .text(String(String.UnicodeScalarView(text.unicodeScalars.prefix(PostingDefaults.wordLength * 16))))
            } else {
                self = .other
            }
        }

        var text: String? {
            if case .text(let text) = self { return text }
            return nil
        }

        var flag: Bool? {
            if case .flag(let flag) = self { return flag }
            return nil
        }
    }
}
