import Foundation

// What one Mastodon host has, as far as this run knows (#315, #320, #321).
//
// **Two sources, and no third.** A thing is absent where the host's own account of itself says
// so — the one document it publishes, read by the one reader this package has of it
// (`MastodonClient.said()`) — and where that document says nothing of the thing, by a not-found
// its own address answered, remembered for the run (`MastodonHostsKnown`). **Never by a version**: no
// version string is read here, nor the number a host gives for how much of the API it speaks.
// A fork, a host behind a proxy and a host its administrator narrowed all answer for
// themselves, and a floor would be wrong about each of them.
//
// **Per host, and for the run.** What a kind of source has is `SourceOffers`, said once for
// every host of that kind; what *this* host has is here, kept in memory, written nowhere, and
// gone with the run — a host is upgraded, narrowed and widened while the app is closed.
//
// **Mostly, a Mastodon does not say** — asked of a real one (`MastodonHostCaptures`). Its
// document says how many hashtags an account may feature and nothing of suggestions, the
// directory, featured people, what is rising, announcements, or the three longer accounts of
// itself — switched off or on, the document is the same bytes. A directory, the servers it
// knows and how busy it has been, switched off, answer a not-found of their own address, and
// that is how they are known absent. What is rising, **switched off, answers exactly as an
// empty one does** (`200 []`). So `unsaid` is the common answer; an empty answer is said as
// the source giving nothing, never as the host having no such thing; and only the document or
// the host's own "no such address" makes a thing absent.
//
// **One thing shares its address with another**: the posts an account pinned are asked for
// where its posts are, by one word more, so no not-found is theirs alone. What stands for it is
// the host answering the word with the ordinary posts (`MastodonPerson.pinned`), and whoever
// keeps this remembers that as it remembers a not-found.
//
// **Nothing here is an address.** Every fact is a figure or a yes, bounded where it is read; a
// host's word about itself can make the app offer less, and can never make it reach anywhere
// (#282). The first fact that is an address — where a host says its live line is served, often
// another hostname — belongs to the unit that reads the line, and is admitted there under
// whatever its story decides, not kept here as a place to go.
//
// **Where the later stories' facts go.** How large a picture or a film may be, how a poll may
// be shaped, whether a post may quote or be translated, how many may wait to be sent: each is
// in the same document, under `configuration`. They are read by adding a field to `MastodonHostSays`
// and a line to its reading — one document, one reader, one lenient decode — when the unit
// that wants one is built, each bounded as `featuredTagLimit` is.

/// A thing a Mastodon host may have or not, that a unit of #309 asks about before it offers it.
///
/// **A Mastodon's, and named so.** Another kind of source has other things and says them
/// another way; what the kinds share is not drawn here.
public enum MastodonHostThing: String, Sendable, Hashable, CaseIterable {
    /// The people it suggests to whoever is signed in (#315).
    case suggestions
    /// Its directory of people (#315).
    case directory
    /// The people an account features on its profile (#315).
    case featuredPeople
    /// The hashtags an account features on its profile (#318).
    case featuredTags
    /// The hashtags rising on it (#320).
    case risingTags
    /// The links rising on it (#320).
    case risingLinks
    /// What it announces to the people signed in to it (#321).
    case announcements
    /// Its longer account of itself (#321).
    case longerAccount
    /// The servers it knows (#321).
    case knownServers
    /// How busy it has been, week by week (#321).
    case activity
    /// The posts an account pinned (#310). Never said by the document, and with no address of
    /// its own to answer not-found: a host has none where it answered the word with an
    /// account's ordinary posts (`MastodonPerson.pinned` handing back nothing).
    case pinnedPosts
}

/// What is known of one thing at one host.
///
/// **Two limits, as a real Mastodon is.** `present` is reached today only for featured
/// hashtags: nothing else is said by the document, and an address that answers is not
/// remembered as a yes. And the hashtags and the links rising are never anything but `unsaid`
/// there: switched off they answer as an empty list does, so no answer of theirs is a no.
public enum MastodonHostHas: Sendable, Hashable {
    /// The host says it has it.
    case present
    /// The host says it has none of it, or answered that it has no such address this run.
    case absent
    /// The host has said nothing either way: the thing is offered, and asking is how it is
    /// found out.
    case unsaid
}

/// What a host's own account of itself says it has: the facts read out of the one document it
/// publishes, each bounded, none of them an address.
public struct MastodonHostSays: Sendable, Hashable {
    /// How many hashtags an account may feature, where the host says. Nothing where it does
    /// not, or says less than none.
    public let featuredTagLimit: Int?

    /// The most a figure a host gives for itself is believed to be. A stranger's number: one
    /// past this is theirs to send and not ours to size anything by.
    static let most = 1_000

    /// A host that has said nothing.
    public static let nothing = MastodonHostSays(featuredTagLimit: nil)

    public init(featuredTagLimit: Int?) {
        self.featuredTagLimit = featuredTagLimit.flatMap { $0 >= 0 ? min($0, Self.most) : nil }
    }

    /// Read out of the host's document. **Never fails**: a key that is missing or of another
    /// shape costs the fact it carried, a document that is no document says nothing at all —
    /// and neither costs the reader what else the same answer was read for.
    init(document: Data) {
        let read = try? MastodonJSON.decoder.decode(Wire.self, from: document)
        self.init(featuredTagLimit: read?.configuration?.value?.accounts?.value?.maxFeaturedTags?.value)
    }

    /// What the document says of `thing`. Of all but one it says nothing.
    public func has(_ thing: MastodonHostThing) -> MastodonHostHas {
        switch thing {
        case .featuredTags:
            guard let featuredTagLimit else { return .unsaid }
            return featuredTagLimit > 0 ? .present : .absent
        case .suggestions, .directory, .featuredPeople, .risingTags, .risingLinks, .announcements,
             .longerAccount, .knownServers, .activity, .pinnedPosts:
            return .unsaid
        }
    }

    /// The document, as far down as the facts above. Every level is read leniently: it is a
    /// stranger's server and a fork's, and one branch of another shape is that branch's loss.
    private struct Wire: Decodable {
        typealias Lenient = StatusDTO.Lenient
        let configuration: Lenient<Configuration>?

        struct Configuration: Decodable, Sendable {
            let accounts: Lenient<Accounts>?
        }

        struct Accounts: Decodable, Sendable {
            let maxFeaturedTags: Lenient<Int>?
        }
    }
}

/// A not-found, told apart: the host having no such address, or its having nobody and nothing
/// of the name asked for.
///
/// Asked of a real server, both are 404. An address it does not serve answers a page of its
/// own, a thing its administrator switched off or hides answers `{"error":"Not Found"}` or
/// nothing at all — and somebody or something it has not got answers
/// `{"error":"Record not found"}`. Only the first three are a word about the host.
///
/// **Told by what is known, and anything else is not known.** A sentence in the server's own
/// wording that is not exactly its "Not Found" — a fork's "Can't find user" for one deleted
/// account — is taken for neither: were it taken for the address, one missing record would
/// hide the thing for everybody at that host. The thing stays unsaid, and is asked again.
public enum MastodonHostNotFound {
    /// How much of an answer is looked at: the sentence is short, and a page is not read.
    static let bodyLength = 4_096

    /// Whether an answer says the host has no such address — what `MastodonHostsKnown.notFound` may be
    /// told of. Not an answer that is no not-found, and not one about a record.
    public static func isOfTheAddress(status: Int, body: Data) -> Bool {
        guard status == 404 else { return false }
        // No body, a page, or anything that is not the server's own sentence: the address.
        guard body.count <= bodyLength, let said = try? JSONSerialization.jsonObject(with: body, options: .fragmentsAllowed) else {
            return true
        }
        // Its own sentence: only the one known to be about the address.
        return ((said as? [String: Any])?["error"] as? String)?.lowercased() == "not found"
    }
}

/// What this run knows of each host: what its document said, and which things its own address
/// answered not-found for.
///
/// **A value, kept by whoever asks.** A host not heard from yet has nothing here (`said(at:)`),
/// which is how its one ask a run is known to be still owed; a document that could not be
/// fetched is not heard, so it is asked again when next wanted. Nothing is asked from here, and
/// nothing by itself.
///
/// **One owner.** It is a value, and two holders of two copies would each write back over what
/// the other learnt. So it is held by one object on the main actor — the session's, beside
/// what it keeps of each source — and changed in place there, by a call that does not wait:
/// never copied out, carried across an `await`, and written back.
///
/// **Nothing is for ever.** A run lasts days, and a not-found may have been a proxy's or a
/// server halfway through being replaced; one learnt as nobody may not stand for somebody
/// signed in. So a document read again takes that host's not-founds with it, and
/// `askAfresh` lets a host go whole — at the person's reload, and when who is signed in to it
/// changes.
public struct MastodonHostsKnown: Sendable, Equatable {
    private struct Known: Sendable, Equatable {
        var said: MastodonHostSays?
        var notFound: Set<MastodonHostThing> = []
    }

    private var hosts: [String: Known] = [:]

    public init() {}

    private static func key(_ host: String) -> String { host.lowercased() }

    /// What the document of `host` said, or nothing where it has not been read this run.
    public func said(at host: String) -> MastodonHostSays? {
        hosts[Self.key(host)]?.said
    }

    /// The document of `host` was read, and said this. Read again, it is believed afresh, and
    /// what its addresses answered before is let go: each is asked again when next wanted.
    ///
    /// **Only a Mastodon's document is handed here**: one read from a host whose kind, as that
    /// same answer said it (`MastodonClient.said()`), is Mastodon's. Another program's document
    /// at the same address is not this host's word about these things.
    public mutating func heard(_ says: MastodonHostSays, at host: String) {
        hosts[Self.key(host)] = Known(said: says)
    }

    /// The address of `thing` answered that `host` has no such address
    /// (`MastodonHostNotFound.isOfTheAddress`): it is not offered there again this run.
    public mutating func notFound(_ thing: MastodonHostThing, at host: String) {
        hosts[Self.key(host), default: Known()].notFound.insert(thing)
    }

    /// Everything known of `host` let go, so it is a host not heard from: its document is owed
    /// again, and every thing there is unsaid. For the person's reload of it, for a sign-in to
    /// it that begins, ends or changes — what was kept from nobody may be given to somebody —
    /// and for a host removed.
    public mutating func askAfresh(_ host: String) {
        hosts[Self.key(host)] = nil
    }

    /// What is known of `thing` at `host`. **A not-found is believed over the document**: the
    /// document is what the host says it is, and the address is what it did.
    public func has(_ thing: MastodonHostThing, at host: String) -> MastodonHostHas {
        guard let known = hosts[Self.key(host)] else { return .unsaid }
        if known.notFound.contains(thing) { return .absent }
        return known.said?.has(thing) ?? .unsaid
    }
}
