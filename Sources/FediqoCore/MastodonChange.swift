import Foundation

// One's own post changed after it was published (#332): what it was written from, the change
// sent, and what it said before — each as Mastodon 4.6.6 answered it (`MastodonChangeCaptures`).

/// What an own post was written from, as its source holds it: what a change starts from.
///
/// **Two answers, read together.** The source's own copy of the words (`/source`) is the text
/// as typed — mentions as `@name`, line breaks as breaks — and its cover line; nothing else.
/// The language, whether it is covered, the files with their descriptions and the poll are the
/// post's own (`GET /statuses/:id`), which `/source` does not say. The rendered words a row
/// holds are never a stand-in: HTML read back loses what the person typed.
public struct PostSource: Equatable, Sendable {
    /// A file already on the post: kept by its id, its description changeable.
    public struct Media: Equatable, Sendable {
        public let id: String
        public let kind: Attachment.Kind
        public let description: String
        public let previewURL: URL?

        public init(id: String, kind: Attachment.Kind, description: String, previewURL: URL? = nil) {
            self.id = id
            self.kind = kind
            self.description = description
            self.previewURL = previewURL
        }
    }

    public let statusID: String
    public let text: String
    /// The cover line; empty where there is none, as the source spells it.
    public let spoiler: String
    public let sensitive: Bool
    public let language: String?
    public let media: [Media]
    /// The poll as it stands now, votes and all: what a change of it would lose (`restarted`).
    public let poll: Poll?

    public init(
        statusID: String, text: String, spoiler: String = "", sensitive: Bool = false,
        language: String? = nil, media: [Media] = [], poll: Poll? = nil
    ) {
        self.statusID = statusID
        self.text = text
        self.spoiler = spoiler
        self.sensitive = sensitive
        self.language = language
        self.media = media
        self.poll = poll
    }

    /// The post's poll as a draft of it, to send unchanged or change.
    ///
    /// **Its run is what is left of it at `now`**, rounded up to the second: the source starts a
    /// poll's run again from the moment of every change it takes, whatever else changed, so a
    /// draft that kept the run it was made with would move the end later. A poll already ended
    /// has nothing left (`runs` 0), which the source refuses ("Deadline is too soon"): a change
    /// keeps an ended poll only by opening it again for a run chosen anew, votes kept, or takes
    /// it off. Figures hidden until the end stay hidden.
    public func pollDraft(now: Date = Date()) -> NewPoll? {
        guard let poll else { return nil }
        let left = poll.ended(at: now) ? 0 : (poll.endsAt.map { Int(max(0, $0.timeIntervalSince(now)).rounded(.up)) } ?? 0)
        return NewPoll(
            choices: poll.choices.map(\.title), multiple: poll.multiple, runs: left,
            hidesTotals: poll.countsHidden && !poll.ended(at: now)
        )
    }
}

/// A change to an own post, as it is sent (`PUT /api/v1/statuses/:id`).
///
/// **Only what a change can move.** Who may read it, what it answers and what it quotes are not
/// here: the source takes none of them on a change, and one sent is passed over in silence.
public struct PostChange: Equatable, Sendable {
    /// A file the changed post carries, by the id its source gave it, with its description.
    public struct Media: Equatable, Sendable {
        public let id: String
        public let description: String

        public init(id: String, description: String) {
            self.id = id
            self.description = description
        }
    }

    public var text: String
    public var spoiler: String
    public var sensitive: Bool
    public var language: String?
    /// Every file the post carries after, in order: those kept and those newly uploaded. One
    /// left out is taken off.
    public var media: [Media]
    /// The poll after; nothing takes it off.
    public var poll: NewPoll?

    public init(
        text: String, spoiler: String = "", sensitive: Bool = false, language: String? = nil,
        media: [Media] = [], poll: NewPoll? = nil
    ) {
        self.text = text
        self.spoiler = spoiler
        self.sensitive = sensitive
        self.language = language
        self.media = media
        self.poll = poll
    }

    /// `source` unchanged, at `now`: what the change sheet opens on.
    public init(source: PostSource, now: Date = Date()) {
        self.init(
            text: source.text, spoiler: source.spoiler, sensitive: source.sensitive,
            language: source.language,
            media: source.media.map { Media(id: $0.id, description: $0.description) },
            poll: source.pollDraft(now: now)
        )
    }

    /// The form as the source takes it. A cover line is sent empty to take one off, sensitive
    /// always, a language only where there is one; each file by its id and again with its
    /// description, which is how a description already on the post is changed.
    var form: [(String, String)] {
        var form = [("status", text), ("spoiler_text", spoiler), ("sensitive", sensitive ? "true" : "false")]
        if let language = SourceField.languageTag(language) { form.append(("language", language)) }
        for file in media { form.append(("media_ids[]", file.id)) }
        for file in media {
            form.append(("media_attributes[][id]", file.id))
            form.append(("media_attributes[][description]", file.description))
        }
        if let poll {
            for choice in poll.said { form.append(("poll[options][]", choice)) }
            form.append(("poll[expires_in]", String(poll.runs)))
            form.append(("poll[multiple]", poll.multiple ? "true" : "false"))
            form.append(("poll[hide_totals]", poll.hidesTotals ? "true" : "false"))
        }
        return form
    }
}

extension Poll {
    /// Whether `change` — the poll a change sends, nothing where it takes the poll off — starts
    /// this poll again, so that every vote in it is lost.
    ///
    /// **As Mastodon 4.6.6 answered** (`MastodonChangeCaptures`): its choices differ in their
    /// words, their number or their order, or one-choice became several or back; or the poll is
    /// taken off. A run changed, or figures hidden or shown, keeps the votes. (So does the
    /// change's form only because it always says one or several outright: left out, the
    /// source takes that for a change of it too.)
    public func restarted(by change: NewPoll?) -> Bool {
        guard let change else { return true }
        return change.said != choices.map(\.title) || change.multiple != multiple
    }
}

extension MastodonWrite {
    /// What `note` — the reader's own post — was written from (`PostSource`): its source's copy
    /// of the words and the post as it stands, asked together.
    ///
    /// **Nothing here is written to the store**: a sheet opened and cancelled has changed
    /// nothing. A 404 is the post gone, or not one this sign-in may see.
    public func source(of note: Note) async throws -> PostSource {
        guard await store.sources().contains(where: { $0.host == host }) else {
            throw MastodonWriteError.noSource
        }
        guard let id = note.sendableID, ListSubscription.isPathSegment(id) else {
            throw MastodonWriteError.unfindable
        }
        async let words = door.get(path: "/api/v1/statuses/\(id)/source")
        async let post = door.get(path: "/api/v1/statuses/\(id)")
        let (wordsData, postData) = try await (words, post)
        guard let said = try? MastodonJSON.decoder.decode(SourceDTO.self, from: wordsData), said.id == id,
              let status = try? MastodonJSON.decoder.decode(StatusDTO.self, from: postData), status.id == id
        else {
            throw MastodonWriteError.unreadable
        }
        return PostSource(
            statusID: id, text: said.text ?? "", spoiler: said.spoilerText ?? status.spoilerText ?? "",
            sensitive: status.sensitive ?? false, language: status.language?.value,
            media: (status.mediaAttachments ?? []).compactMap(\.asSourceMedia),
            poll: status.poll?.value?.poll
        )
    }

    /// Sends `change` to `note`, the reader's own post, and returns the post as the store now
    /// holds it.
    ///
    /// **The answer lands as an act's answer does** (`refresh`), over the row held: the same row,
    /// with what it said until now kept as an earlier wording, where the words changed — the
    /// source's own moment of the change (`edited_at`) is what makes it the later copy. A read
    /// already on its way when the change landed says an earlier moment, or none, and changes no
    /// word of it (`Note.isEarlier`). Nothing is asked of the timeline.
    ///
    /// **Refused here, before anything is sent**, as a new post is: a poll beside media, and a
    /// poll past what the source said it takes. **A refusal there changes nothing held**: a 422
    /// throws `MastodonUnprocessable` with the source's words, a sign-in without the writing
    /// part `MastodonScopeError.outside`, a 404 (the post gone, or not the reader's) what the
    /// door throws for it.
    ///
    /// **No `Idempotency-Key`**: the same change sent twice lands once — a second that changes
    /// nothing makes no new wording at the source.
    @discardableResult
    public func change(_ note: Note, to change: PostChange, pollLimits: MastodonPollLimits? = nil) async throws -> Note {
        if let poll = change.poll {
            if !change.media.isEmpty { throw MastodonWriteError.refusedHere(.pollWithMedia) }
            if let pollLimits, let refusal = poll.refusal(within: pollLimits) {
                throw MastodonWriteError.refusedHere(refusal)
            }
        }
        guard await store.sources().contains(where: { $0.host == host }) else {
            throw MastodonWriteError.noSource
        }
        guard let id = note.sendableID, ListSubscription.isPathSegment(id) else {
            throw MastodonWriteError.unfindable
        }
        let sent = ReadMoment.now()
        let data = try await door.put(path: "/api/v1/statuses/\(id)", form: change.form)
        guard let answered = try? MastodonJSON.decoder.decode(StatusDTO.self, from: data)
            .asNote(source: note.source, categories: note.categories, sent: sent),
            answered.statusID == id
        else {
            throw MastodonWriteError.unreadable
        }
        try Task.checkCancellation()
        await store.refresh([answered], ifSourceHere: host)
        return await store.note(answered.key) ?? answered.refreshed(over: note)
    }

    /// What `note` said before, as its source keeps it (`GET /statuses/:id/history`): every
    /// wording before the one it says now, **the original first**, each with the moment its
    /// source says it was changed from — the time of the next one.
    ///
    /// **A wording is the words and the cover line**, as `Wording` is: a change of a file's
    /// description, of whether it is covered, or of the poll alone is a change at the source and
    /// no new wording here — it joins the wording before. Bounded as every held wording is
    /// (`Wording.bounded`), the oldest going first. Nothing is written to the store.
    public func history(of note: Note) async throws -> [Wording] {
        guard let id = note.sendableID, ListSubscription.isPathSegment(id) else {
            throw MastodonWriteError.unfindable
        }
        let data = try await door.get(path: "/api/v1/statuses/\(id)/history")
        guard let entries = try? MastodonJSON.decoder.decode([StatusDTO.Lenient<EditDTO>].self, from: data) else {
            throw MastodonWriteError.unreadable
        }
        let quotes = note.quotesReference != nil
        return Self.wordings(entries.compactMap { $0.value?.wording(quotes: quotes) })
    }

    /// `said` — each wording with the moment it began, oldest first — as the wordings before the
    /// last, each until the next one that says something else.
    static func wordings(_ said: [(words: Wording, since: Date)]) -> [Wording] {
        var groups: [(words: Wording, since: Date)] = []
        for entry in said.sorted(by: { $0.since < $1.since }) {
            if let last = groups.last, last.words.body == entry.words.body,
               (last.words.spoiler ?? "") == (entry.words.spoiler ?? "") { continue }
            groups.append(entry)
        }
        guard groups.count > 1 else { return [] }
        return Wording.bounded(zip(groups, groups.dropFirst()).map { was, next in
            Wording(body: was.words.body, spoiler: was.words.spoiler, sensitive: was.words.sensitive, until: next.since)
        })
    }
}

/// `GET /api/v1/statuses/:id/source`: the words as typed and the cover line, nothing else.
private struct SourceDTO: Decodable {
    let id: String
    let text: String?
    let spoilerText: String?
}

/// One entry of a post's history: what it said from `created_at` on.
private struct EditDTO: Decodable, Sendable {
    let content: String?
    let spoilerText: String?
    let sensitive: Bool?
    let createdAt: StatusDTO.LenientMoment?

    /// A wording dated by when it began, or nothing where the entry says no moment it can be
    /// placed by. Its `until` is filled in once the next is known.
    func wording(quotes: Bool) -> (words: Wording, since: Date)? {
        guard let since = createdAt?.value else { return nil }
        let html = content ?? ""
        let body = HTMLText.plain(quotes ? HTMLText.withoutQuoteLine(html) : html)
        return (Wording(body: body, spoiler: spoilerText, sensitive: sensitive, until: since), since)
    }
}

extension StatusDTO.MediaAttachment {
    /// This file as a change keeps it: by its id, with its description. Nothing without an id,
    /// which no change can name.
    var asSourceMedia: PostSource.Media? {
        guard let id, !id.isEmpty else { return nil }
        return PostSource.Media(
            id: id, kind: asAttachment?.kind ?? .unknown, description: description ?? "",
            previewURL: Host.fetchableURL(previewUrl)
        )
    }
}
