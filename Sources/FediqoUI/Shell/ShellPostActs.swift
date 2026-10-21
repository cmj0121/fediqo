import FediqoCore
import Foundation
import Observation

// The rest of a post's acts (#334): pinning one's own post to one's page, quieting a
// conversation, putting a post into the reader's language, and the people who boosted and
// favourited it — each an item of the post's `…` and of a hold on its row, and each by a key.
//
// **Only where that kind of source has them.** A pin and a quieted conversation are what a source
// says of its reader (`SourceOffers.saysReaderMarks`), and so is the language it translates a
// post for them into; the two lists are people a source keeps (`SourceOffers.people`). A forum
// gains nothing.
//
// **Greyed with its lock's words where the sign-in lacks the part** — the account part for a pin,
// the blocks part for a quiet conversation (asked of a real one, `MastodonPostActsCaptures`) —
// and a press on it then only asks, as Report's does.
//
// **What the source says, and nothing this device decides.** A pin or a quiet is drawn as the
// source last said it; one on its way is drawn as pressed until the source answers, and one it
// refused is put back and said — in its own words, or as the host's limit. A translation is held
// for this run only, beside the post and never in its place, and goes when the post is let go.

/// The acts of #334 on the posts of this run: which are on their way, and each translation asked.
///
/// Held by `ShellPersonPages`, on its count of asks, as the report is: the session's own stored
/// state is not this unit's to add to.
@MainActor
@Observable
final class ShellPostActs {
    /// One of the two acts that change how the post stands for the reader.
    enum Act: Hashable, Sendable {
        case pin, quiet
    }

    /// A translation of one post, by the row id of the copy it was asked through.
    enum Translation: Equatable {
        case asking
        case shown(PostTranslation)
        /// Not translated: the sentence that says why. The post stands as it was.
        case failed(String)
    }

    /// Each act on its way, by the copy's row id, with the way it was pressed.
    private(set) var out: [String: [Act: Bool]] = [:]
    private(set) var translations: [String: Translation] = [:]
    @ObservationIgnored let hosts: ShellHostsKnown

    init(hosts: ShellHostsKnown) {
        self.hosts = hosts
    }

    func pressed(_ act: Act, on row: String) -> Bool? { out[row]?[act] }

    fileprivate func begin(_ act: Act, on row: String, to on: Bool) -> Bool {
        guard out[row]?[act] == nil else { return false }
        out[row, default: [:]][act] = on
        return true
    }

    fileprivate func end(_ act: Act, on row: String) {
        out[row]?[act] = nil
        if out[row]?.isEmpty == true { out[row] = nil }
    }

    fileprivate func set(_ translation: Translation?, on row: String) {
        translations[row] = translation
    }

    /// The language a post is translated into (D4): the interface's, which follows the system's
    /// first language unless the reader chose one.
    static var language: String {
        L10n.language.lprojName ?? Locale.preferredLanguages.first ?? "en"
    }
}

extension ItemActing {
    /// What a row offers of #334, built by `ShellSession.postOffer`. Nothing where its source
    /// has none of them.
    struct PostMore {
        /// One item: where the sign-in lacks the part, its lock — the item is drawn dim with it,
        /// and a press only asks — and the press.
        struct Item {
            var lock: Lock?
            let press: () -> Void
        }

        /// A pin or a quiet: how the source last said it stands (or as pressed, while on its way).
        struct Turn {
            let on: Bool
            let out: Bool
            var lock: Lock?
            let press: () -> Void
        }

        var translate: Item?
        /// Where nobody is signed in to the post's source, which a Mastodon translates for no one
        /// unsigned: the host, and Translate is drawn dim with the sign-in's words.
        var translateSignedOut: String?
        /// Whether the post's translation is shown now: the item then puts the original back alone.
        var translated = false
        var boostedBy: Item?
        var favouritedBy: Item?
        var pin: Turn?
        var quiet: Turn?
        /// The translation drawn beside the post's words, where one was asked.
        var translation: ShellPostActs.Translation?
    }
}

extension ShellSession {
    /// The post a row's #334 acts are about: on a reblog's row, the post it carries.
    private func postOf(_ item: DummyItem) -> DummyItem {
        item.isReblog ? item.reblogged.first ?? item : item
    }

    /// The kind of `item`'s source, where it is one held.
    private func kind(of item: DummyItem) -> ProtocolKind? {
        sources.first { $0.host == item.source.host }?.kind
    }

    /// The copy the signed-in acts go through: the one a boost would, which is the post's on a
    /// reblog's row — or, where no sign-in writes, the first copy at a source somebody is signed
    /// in to, reading only. Nothing where nobody is signed in to any.
    private func signedCopy(of item: DummyItem) -> DummyItem? {
        if let writing = actingCopy(of: item, for: .boost) { return writing }
        let post = postOf(item)
        return (post.actCopies.isEmpty ? [post] : post.actCopies).first { mastodon.token(host: $0.source.host) != nil }
    }

    /// What `item`'s `…` offers of #334, in the order it is drawn, with the presses — or nothing
    /// where its source has none of it. `openPeople` opens the list of who boosted or favourited it.
    func postOffer(
        on item: DummyItem, people: ShellPersonPages, openPeople: @escaping (PeopleList) -> Void,
        afterTranslate: (() -> Void)? = nil
    ) -> ItemActing.PostMore? {
        let post = postOf(item)
        guard let kind = kind(of: post), post.goneSince == nil else { return nil }
        var more = ItemActing.PostMore()
        if kind.offers.people, post.statusID != nil {
            if let list = Self.peopleList(.boostedBy, of: post) {
                more.boostedBy = .init(lock: nil) { openPeople(list) }
            }
            if let list = Self.peopleList(.favouritedBy, of: post) {
                more.favouritedBy = .init(lock: nil) { openPeople(list) }
            }
        }
        guard kind.offers.saysReaderMarks else {
            return more.boostedBy == nil && more.favouritedBy == nil ? nil : more
        }
        guard let copy = signedCopy(of: item), let held = note(ofRow: copy.id) else {
            // Signed in nowhere: a Mastodon translates for nobody unsigned (asked of a real one,
            // `MastodonPostActsCaptures`), so Translate is drawn dim with the sign-in's words.
            if let unsigned = note(ofRow: post.id),
               MastodonTranslator.offered(unsigned, into: ShellPostActs.language, host: people.postActs.hosts.has(.translation, at: post.source.host)) {
                more.translateSignedOut = post.source.host
            }
            return more
        }
        let host = copy.source.host
        let acts = people.postActs
        // Translating (D4): not offered where the post is in the reader's language already, is
        // not one anyone may read, or the host says it has no translator.
        if MastodonTranslator.offered(held, into: ShellPostActs.language, host: acts.hosts.has(.translation, at: host)) {
            more.translate = .init(lock: nil) { [weak self] in
                guard let self else { return }
                afterTranslate?()
                Task { await self.translate(item, people: people) }
            }
            if case .shown? = acts.translations[copy.id] { more.translated = true }
        }
        more.translation = acts.translations[copy.id]
        // Quieting a conversation, on anybody's post; pinning, on the reader's own that may be pinned.
        more.quiet = turn(.quiet, held.muted, on: copy, acts: acts, part: .blocks, people: people, item: item)
        if isMine(copy), MastodonWrite.pinnable(held) {
            more.pin = turn(.pin, held.pinned, on: copy, acts: acts, part: .account, people: people, item: item)
        }
        return more
    }

    private func turn(
        _ act: ShellPostActs.Act, _ said: Bool?, on copy: DummyItem, acts: ShellPostActs, part: MastodonPart,
        people: ShellPersonPages, item: DummyItem
    ) -> ItemActing.PostMore.Turn {
        let host = copy.source.host
        let lock = mastodon.place(part, host: host).map { ItemActing.Lock(place: $0, host: host) }
        let pressed = acts.pressed(act, on: copy.id)
        return .init(on: pressed ?? (said == true), out: pressed != nil, lock: lock) { [weak self] in
            guard let self else { return }
            if lock != nil {
                _ = self.askFor([part], host: host)
            } else {
                Task { await self.turn(act, on: item, people: people) }
            }
        }
    }

    /// The list of who boosted, or who favourited, `post`, as a step of the walk opens it.
    static func peopleList(_ which: PeopleList.Which, of post: DummyItem) -> PeopleList? {
        guard let id = post.statusID else { return nil }
        let counted = which == .boostedBy ? post.counts.reblogs : post.counts.favourites
        return PeopleList(which, ofPost: id, at: post.source.host, by: post.handle ?? post.author, counted: counted)
    }

    /// A pin or a quiet pressed on `item`: the other way from how the source last said it, sent
    /// through the copy that writes, and drawn as pressed until the source answers. **Asked
    /// nothing where the sign-in lacks the part** — the item only asks for it then.
    func turn(_ act: ShellPostActs.Act, on item: DummyItem, people: ShellPersonPages) async {
        guard let copy = signedCopy(of: item), let held = note(ofRow: copy.id) else { return }
        let host = copy.source.host
        let part: MastodonPart = act == .pin ? .account : .blocks
        guard mastodon.place(part, host: host) == nil, let door = mastodon.authorized(host: host, for: .write) else { return }
        let acts = people.postActs
        let to = !((act == .pin ? held.pinned : held.muted) ?? false)
        guard acts.begin(act, on: copy.id, to: to) else { return }
        defer { acts.end(act, on: copy.id) }
        let write = reach.write(door, landingIn: store)
        do {
            switch act {
            case .pin: _ = try await write.pin(held, on: to, limit: acts.hosts.said(at: host)?.pinLimit)
            case .quiet: _ = try await write.quiet(held, on: to)
            }
            await adopt()
            saveSoon()
        } catch {
            showToast(Self.refused(act, to: to, error, host: host))
        }
    }

    /// What a pin or a quiet that did not land says: the host's limit, the source's own words, or
    /// that it did not arrive.
    static func refused(
        _ act: ShellPostActs.Act, to on: Bool, _ error: any Error, host: String, language: DummyLanguage? = nil
    ) -> String {
        switch error as? MastodonWriteError {
        case .pinLimit(let limit?):
            return String(format: L10n.t("item.act.pin.full.limit", language: language), host, limit)
        case .pinLimit(nil):
            return String(format: L10n.t("item.act.pin.full", language: language), host)
        case .refused(let sentence) where !sentence.isEmpty:
            return String(format: L10n.t("item.act.refused.said", language: language), host, sentence)
        default:
            let key = switch act {
            case .pin: on ? "item.act.pin.failed" : "item.act.unpin.failed"
            case .quiet: on ? "item.act.quiet.failed" : "item.act.unquiet.failed"
            }
            return String(format: L10n.t(key, language: language), host)
        }
    }

    /// `item` translated into the reader's language (D4), shown beside its words — or, where its
    /// translation is shown, put back to the original alone. **A not-found is remembered for the
    /// run as the host having no translator only where its own account of itself said nothing**
    /// (D6), and the item is then not offered there again.
    func translate(_ item: DummyItem, people: ShellPersonPages) async {
        // Reading is all it needs: a sign-in that only reads is translated for.
        guard let copy = signedCopy(of: item), let held = note(ofRow: copy.id),
              let door = mastodon.authorized(host: copy.source.host, for: .conversation)
        else { return }
        let acts = people.postActs
        switch acts.translations[copy.id] {
        case .asking?: return
        case .shown?:
            acts.set(nil, on: copy.id)
            return
        case .failed?, nil: break
        }
        let host = copy.source.host
        await acts.hosts.hear(host, in: self)
        acts.set(.asking, on: copy.id)
        do {
            let said = try await MastodonTranslator(door: door).translate(held, into: ShellPostActs.language)
            acts.set(.shown(said), on: copy.id)
        } catch {
            if (error as? MastodonTranslationError) == .notFound { acts.hosts.translationNotFound(at: host) }
            acts.set(.failed(Self.untranslated(error, host: host)), on: copy.id)
        }
    }

    /// Why a post was not translated, in a sentence: the original stands as it was.
    static func untranslated(_ error: any Error, host: String, language: DummyLanguage? = nil) -> String {
        let key = switch error as? MastodonTranslationError {
        case .refused?: "translation.refused"
        case .unavailable?: "translation.unavailable"
        case .notFound?: "translation.none"
        case .invalid?, .unreadable?, nil: "translation.failed"
        }
        return String(format: L10n.t(key, language: language), host)
    }
}
