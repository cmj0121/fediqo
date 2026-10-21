import Foundation

/// A post's words in another language, as the source that translated them said them (#334):
/// beside the post, never in its place, and never kept — a translation is asked for when it is
/// wanted, and goes with whatever showed it.
public struct PostTranslation: Hashable, Sendable {
    /// The words, as plain text, as a post's are (`HTMLText.plain`).
    public let body: String
    /// The cover line in the same language, or nothing where the post has none.
    public let spoiler: String?
    /// The language the source says the post was written in, as a tag (`SourceField.languageTag`),
    /// or nothing where it said none.
    public let from: String?
    /// Who made the translation, as the source names them — fit for one line — or nothing where
    /// it named nobody.
    public let provider: String?

    public init(body: String, spoiler: String? = nil, from: String? = nil, provider: String? = nil) {
        self.body = body
        self.spoiler = spoiler
        self.from = from
        self.provider = provider
    }
}

/// Why a post was not translated. **Each leaves the original as it was**: nothing is written
/// anywhere, and the post is shown as it always is.
public enum MastodonTranslationError: Error, Equatable, Sendable {
    /// Refused before anything was asked: a language that is no tag, or a post that cannot be
    /// named on its own server.
    case invalid
    /// The source would not translate this post (403): one only some may read, or one it says
    /// is not to be translated.
    case refused
    /// The source's translator did not answer it (503). Asking again later may be answered.
    case unavailable
    /// The source has no translator, or no such post: **a Mastodon words the two alike**
    /// (`{"error":"Not Found"}`, asked of a real one, `MastodonPostActsCaptures`), so this is
    /// never by itself a word about the host — the document is (`MastodonHostThing.translation`).
    case notFound
    /// The source answered, and not with a translation.
    case unreadable
}

/// A Mastodon asked to put a post into the reader's language (#334):
/// `POST /api/v1/statuses/:id/translate`, through the one signed-in door.
///
/// **The language is the caller's** (D4: the system's first language); **whether to offer it at
/// all is `offered`**, said once here so a view never decides it alone.
///
/// **Nothing here writes anywhere on this device.** A translation lands in what this returns; one
/// that is refused or fails throws and changes nothing.
public struct MastodonTranslator: Sendable {
    private let door: MastodonAuthorized

    public init(door: MastodonAuthorized) {
        self.door = door
    }

    /// How much of a translation's words are read before the markup is taken out: a post's
    /// words are bounded by its source, a stranger's translation by this.
    static let bodyLength = 64 * 1024
    /// How long a provider's name may run on its line.
    static let providerLength = 80

    /// Whether `note` is offered a translation into `language` (D4): a post with words, that
    /// anyone may read — public or unlisted, which a Mastodon translates and no other (asked of
    /// a real one) — **not already in that language**, at a host whose own account of itself
    /// does not say it has no translator. A post that names no language is offered: the source
    /// tells what it was written in. Two tags are the same language where their first parts are
    /// (`en-gb` is `en`).
    ///
    /// **A boost is offered by the post it boosts** (`boosted`, the item `reblogKey` names): the
    /// boost has no words of its own, and it is the boosted post that is asked about and
    /// translated — by its own id (`translate`). A boost handed in without it is not offered.
    public static func offered(_ note: Note, into language: String, host: MastodonHostHas, boosted: Note? = nil) -> Bool {
        let post: Note
        if note.isReblog {
            guard let boosted, boosted.key == note.reblogKey, !boosted.isReblog else { return false }
            post = boosted
        } else {
            post = note
        }
        guard host != .absent, let into = primary(language) else { return false }
        guard post.audience == .everyone || post.audience == .unlisted else { return false }
        guard !post.body.isEmpty || !(post.spoiler ?? "").isEmpty else { return false }
        return primary(post.language) != into
    }

    /// The id `note` is translated by: its own, or for a boost the boosted post's at the same source.
    private static func translatedID(_ note: Note) -> String? {
        note.isReblog ? note.refs.first { $0.kind == .reblogs }?.statusID : note.sendableID
    }

    /// The first part of a language tag, or nothing where `tag` is none.
    private static func primary(_ tag: String?) -> String? {
        SourceField.languageTag(tag).flatMap { $0.split(separator: "-").first.map(String.init) }
    }

    /// `note` in `language`, as its source translates it — for a boost, the post it boosts.
    ///
    /// **A not-found is the caller's to remember** (D6), and only where the host's document said
    /// nothing of translating: `MastodonHostsKnown.translationNotFound(at:)`.
    public func translate(_ note: Note, into language: String) async throws -> PostTranslation {
        guard let translated = Self.translatedID(note), let id = MastodonWrite.pathID(of: note, at: door.token.host, id: translated),
              let lang = SourceField.languageTag(language)
        else { throw MastodonTranslationError.invalid }
        let body: Data
        do {
            body = try await door.post(path: "/api/v1/statuses/\(id)/translate", form: [("lang", lang)])
        } catch MastodonAuthError.http(403) {
            throw MastodonTranslationError.refused
        } catch MastodonAuthError.http(503) {
            throw MastodonTranslationError.unavailable
        } catch MastodonAuthError.http(404) {
            throw MastodonTranslationError.notFound
        }
        guard let said = try? MastodonJSON.decoder.decode(TranslationDTO.self, from: body) else {
            throw MastodonTranslationError.unreadable
        }
        return said.translation
    }

    private struct TranslationDTO: Decodable, Sendable {
        typealias Lenient = StatusDTO.Lenient
        let content: String
        let spoilerText: Lenient<String>?
        let detectedSourceLanguage: Lenient<String>?
        let provider: Lenient<String>?

        var translation: PostTranslation {
            // Markup and entities taken out as the words' are, then made one line.
            let spoiler = LineText.cleanLine(
                spoilerText?.value, limit: MastodonTranslator.bodyLength, cut: MastodonTranslator.bodyLength
            )
            let provider = provider?.value.map {
                LineText.oneLine($0, limit: MastodonTranslator.providerLength).trimmingCharacters(in: .whitespaces)
            }
            return PostTranslation(
                body: HTMLText.plain(AccountDTO.cut(content, to: MastodonTranslator.bodyLength)),
                spoiler: spoiler,
                from: SourceField.languageTag(detectedSourceLanguage?.value),
                provider: provider?.isEmpty == false ? provider : nil
            )
        }
    }
}

extension MastodonHostsKnown {
    /// A translation asked of `host` answered a not-found (`MastodonTranslationError.notFound`):
    /// remembered for the run as the host having no translator (D6) — **only where its document
    /// said nothing of translating**. Where it said it translates, the not-found is a post it has
    /// not got (a Mastodon words the two alike), and nothing is remembered.
    public mutating func translationNotFound(at host: String) {
        guard said(at: host)?.translates == nil else { return }
        notFound(.translation, at: host)
    }
}
