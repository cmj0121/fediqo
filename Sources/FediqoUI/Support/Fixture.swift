#if DEBUG
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import FediqoCore

/// A timeline worth photographing: servers, posts and a conversation that are invented, and
/// are not pretending not to be.
///
/// Screenshots of an empty list sell nothing, and screenshots of somebody's real timeline are
/// somebody's real timeline. So this stands in for the network — not by faking the answers
/// somewhere deep, but by being a `SourceClient` like any other, so everything above it does
/// its actual work: the merge that turns one post carried by two servers into one row, the
/// store that keeps what arrived, the conversation asked of the server whose word is final.
/// What the camera sees is the real app, reading an invented world.
///
/// **`#if DEBUG`, whole file.** The build that goes to the store cannot compile this, let
/// alone turn it on, which is the guarantee `FEDIQO_FIXTURE` is worth having.
///
/// Every host here ends in `.example`, which RFC 2606 reserves and no resolver will ever
/// answer. That is belt and braces: nothing asks the network anyway, and if something one
/// day did, it would fail rather than reach a stranger's machine.
enum Fixture {
    static let hosts = ["alder.example", "birch.example", "cedar.example"]

    static var servers: [Server] {
        hosts.enumerated().map { position, host in
            Server(host: host, socialProtocol: .mastodon, title: title(of: host),
                   addedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(position)))
        }
    }

    static func title(of host: String) -> String {
        host.split(separator: ".").first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? host
    }

    /// Ages rather than dates. The rows are the same rows every run — same words, same order,
    /// same "12 minutes ago" — while never being a timeline that was plausible in 2026 and
    /// absurd two years later. Determinism is in the content; the clock only follows it.
    private static func at(_ minutesAgo: Double, _ now: Date) -> Date {
        now.addingTimeInterval(-minutesAgo * 60)
    }

    /// What each server hands over. One post appears in two of these lists under the same
    /// `uri` — that is the merge, and it happens for real on the way up rather than being
    /// written here as an already-merged row.
    static func timeline(of host: String, now: Date = Date()) -> [Post] {
        switch host {
        case hosts[0]: return alder(now)
        case hosts[1]: return birch(now)
        default: return cedar(now)
        }
    }

    static func trending(of host: String, now: Date = Date()) -> [Post] {
        Array(timeline(of: host, now: now).prefix(2))
    }

    private static func alder(_ now: Date) -> [Post] {
        [
            post("carried-by-two", host: hosts[0], minutesAgo: 12, now: now,
                 name: "Wren Ashby", handle: "wren",
                 text: "Two servers carried this one. The timeline says so underneath rather "
                     + "than showing it to you twice.",
                 counts: Counts(replies: 4, reblogs: 11, favourites: 27)),
            post("the-deck", host: hosts[0], minutesAgo: 41, now: now,
                 name: "Ines Okafor", handle: "ines",
                 text: "Three things came attached. They are a deck, not a row of thumbnails — "
                     + "click the top one and the stack turns over.",
                 attachments: (0..<3).map { image("deck-\($0)", seed: $0) },
                 counts: Counts(replies: 1, reblogs: 3, favourites: 19)),
            post("the-thread", host: hosts[0], minutesAgo: 96, now: now,
                 name: "Wren Ashby", handle: "wren",
                 text: "Asking what a timeline is for, and getting three answers. Press Return "
                     + "on this one to read them.",
                 counts: Counts(replies: 3, reblogs: 2, favourites: 14),
                 inReplyToURI: address("the-answer", on: hosts[0], by: "ines")),
        ]
    }

    private static func birch(_ now: Date) -> [Post] {
        [
            post("carried-by-two", host: hosts[1], origin: hosts[0], minutesAgo: 12, now: now,
                 name: "Wren Ashby", handle: "wren",
                 text: "Two servers carried this one. The timeline says so underneath rather "
                     + "than showing it to you twice.",
                 counts: Counts(replies: 4, reblogs: 11, favourites: 27)),
            // Written for the author's followers rather than for the world -- the one post
            // here that the row draws a padlock beside.
            post("the-warning", host: hosts[1], minutesAgo: 63, now: now,
                 name: "Dag Solheim", handle: "dag",
                 text: "The photographs from the dig, which are a lot of bones.",
                 attachments: [image("warned", seed: 7)],
                 sensitive: true, spoiler: "Archaeology, human remains", audience: .followers,
                 counts: Counts(replies: 6, reblogs: 4, favourites: 31)),
            post("the-answer", host: hosts[1], minutesAgo: 8, now: now,
                 name: "Ines Okafor", handle: "ines",
                 text: "Answering something this timeline never carried past us. The row says "
                     + "it is an answer and stops there rather than inventing whose.",
                 // Readable by anybody and on nobody's public timeline.
                 audience: .unlisted,
                 counts: Counts(replies: 1, reblogs: 0, favourites: 5),
                 inReplyToURI: "https://elm.example/api/v1/statuses/nobody-handed-us-this"),
            // Both an answer and a boost, which is the case #76 was about: two things happened
            // to this post before it reached the reader, and they are one line rather than two
            // stacked bands. A post that is only one of the two cannot show that.
            // Near the top on purpose. A case that is always below the fold is a case the
            // fixture is not presenting: this world exists to be photographed, and a screenshot
            // that cannot reach a row proves nothing about it.
            post("the-boost", host: hosts[1], minutesAgo: 15, now: now,
                 name: "Mira Halvorsen", handle: "mira",
                 text: "A quiet argument for reading things in the order they were written.",
                 counts: Counts(replies: 0, reblogs: 8, favourites: 22),
                 boostedBy: "Dag Solheim",
                 // Not `carried-by-two`: two servers carry that one, the merge keeps whichever
                 // address arrived first, and a reply pointing at the other one names nobody.
                 // That is a real edge and not this fixture's to demonstrate.
                 inReplyToURI: address("the-emoji", on: hosts[2], by: "tove")),
        ]
    }

    private static func cedar(_ now: Date) -> [Post] {
        [
            post("the-tags", host: hosts[2], minutesAgo: 27, now: now,
                 name: "Yusuf Adeyemi", handle: "yusuf",
                 text: "Reading rooms, mostly. The one at the top of the hill has the light "
                     + "and none of the chairs. https://cedar.example/rooms",
                 attachments: [image("room", seed: 3)],
                 counts: Counts(replies: 2, reblogs: 5, favourites: 41),
                 tags: ["libraries", "slowweb"]),
            // Written partly in pictures, in the words and in the name above them: a
            // shortcode is what the server sends, and a picture is what a reader should see.
            post("the-emoji", host: hosts[2], minutesAgo: 5, now: now,
                 name: "Tove :spark: Rasmussen", handle: "tove",
                 text: "Custom emoji are :spark: a server's own, and a client that cannot draw "
                     + "them leaves you reading the shortcode :cog: instead.",
                 counts: Counts(replies: 2, reblogs: 6, favourites: 23),
                 emojis: [emoji("spark", seed: 1), emoji("cog", seed: 4)]),
            // A post that is mostly a link, with the card its own server made of it. Nothing
            // here fetched anything from `slowweb.example`: the picture is drawn from a file
            // beside the rest of the fixture, exactly as a real card is drawn from the
            // *server's* copy rather than from the site — see #77.
            post("the-link", host: hosts[2], minutesAgo: 33, now: now,
                 name: "Ines Okafor", handle: "ines",
                 text: "Somebody finally wrote the piece about reading at the pace things were "
                     + "written. https://slowweb.example/at-the-pace-things-were-written",
                 counts: Counts(replies: 6, reblogs: 12, favourites: 58),
                 card: Card(
                     url: URL(string: "https://slowweb.example/at-the-pace-things-were-written")!,
                     title: "At the pace things were written",
                     summary: "A timeline that does not rank you is a timeline you can finish.",
                     provider: "The Slow Web",
                     imageURL: FixtureImages.url("card", seed: 9, width: 640, height: 436),
                     imageAlt: "A reading room with the light coming in from one side.")),
            // An answer to a post on the same page, so the row can name whom it answers, and
            // an answer to something nobody handed us, where it can only say that much.
            post("the-plain-one", host: hosts[2], minutesAgo: 18, now: now,
                 name: "Bea Lindqvist", handle: "bea",
                 text: "No picture, no warning, no numbers anybody has told us. A post can be "
                     + "just its words, and the row does not pad it out with an empty box.",
                 // And nobody said who it was for either, so the row says nothing about that.
                 audience: nil,
                 counts: Counts(),
                 inReplyToURI: address("the-tags", on: hosts[2], by: "yusuf")),
        ]
    }

    /// The conversation under `the-thread`, as its own server would hand it over.
    static func conversation(around post: Post, now: Date = Date()) -> Conversation {
        guard post.mergeKey == address("the-thread", on: hosts[0], by: "wren")
        else { return Conversation(post: post) }
        // A way up as well as a way down, and a chain rather than a fan on both sides — a
        // conversation with no shape to it cannot show that a page has learned to draw one
        // (#75). `the-question` is answered by `the-answer`, which is answered by the post
        // this page is about.
        let ancestors = [
            Self.post("the-question", host: hosts[0], minutesAgo: 140, now: now,
                      name: "Bea Lindqvist", handle: "bea",
                      text: "What is a timeline actually for? Nobody agrees and everybody is sure."),
            Self.post("the-answer", host: hosts[0], minutesAgo: 118, now: now,
                      name: "Ines Okafor", handle: "ines",
                      text: "For reading what you chose to read, in the order it was written.",
                      inReplyToURI: address("the-question", on: hosts[0], by: "bea")),
        ]

        let replies = [
            ("reply-one", "Ines Okafor", "ines", 88.0,
             "One order, and nothing between what arrived and what I see except a rule I wrote.",
             "the-thread", "wren"),
            ("reply-two", "Bea Lindqvist", "bea", 71.0,
             "Mine is narrower than that. I want the servers I never joined, and no home page.",
             "the-thread", "wren"),
            // An answer to an answer, so the way down has a step in it too.
            ("reply-three", "Wren Ashby", "wren", 55.0,
             "Both of those are the same feature, which is the part I keep failing to explain.",
             "reply-two", "bea"),
        ].map { uri, name, handle, minutes, text, parent, parentHandle in
            Self.post(uri, host: hosts[0], minutesAgo: minutes, now: now, name: name,
                      handle: handle, text: text,
                      inReplyToURI: address(parent, on: hosts[0], by: parentHandle))
        }
        return Conversation(ancestors: ancestors, post: post, descendants: replies)
    }

    // swiftlint:disable:next function_parameter_count
    /// `origin` is the server the post was written on, where that is not `host` — which is
    /// the whole of what makes one post carried by two servers one row. `mergeKey` is
    /// `originURI ?? uri`, so the relayed copy keeps its own address and answers to the
    /// original's, and the merge above this file does the rest.
    private static func post(
        _ uri: String, host: String, origin: String? = nil, minutesAgo: Double, now: Date,
        name: String, handle: String, text: String,
        attachments: [Attachment] = [], sensitive: Bool? = nil, spoiler: String? = nil,
        audience: Audience? = .everyone,
        counts: Counts = Counts(), tags: [String] = [], emojis: [CustomEmoji] = [],
        card: Card? = nil, boostedBy: String? = nil, inReplyToURI: String? = nil
    ) -> Post {
        Post(
            uri: address(uri, on: host, by: handle),
            originURI: origin.map { address(uri, on: $0, by: handle) },
            socialProtocol: .mastodon,
            sourceURL: "https://\(host)",
            createdAt: at(minutesAgo, now),
            authorId: "https://\(host)/users/\(handle)",
            authorName: name,
            authorHandle: "@\(handle)@\(host)",
            authorAvatarURL: image("avatar-\(handle)", seed: abs(handle.hashValue % 6), side: 96).url,
            text: text,
            attachments: attachments,
            sensitive: sensitive,
            spoiler: spoiler,
            audience: audience,
            counts: counts,
            application: Application(name: "Fediqo"),
            webURL: URL(string: "https://\(host)/@\(handle)/\(uri)"),
            inReplyToURI: inReplyToURI,
            tags: tags,
            emojis: emojis,
            card: card,
            boostedBy: boostedBy,
            boostedById: boostedBy.map { "https://\(host)/users/\($0.lowercased())" },
            sources: [host]
        )
    }

    /// Where one post lives, spelled the way a Mastodon server spells it.
    private static func address(_ uri: String, on host: String, by handle: String) -> String {
        "https://\(host)/users/\(handle)/statuses/\(uri)"
    }

    /// A custom emoji that moves, drawn here for the same reason the photographs are: an
    /// animated GIF in the repository is a binary no test can check, and the point of the
    /// fixture is that everything above it does its actual work — the fetch, the frame-by-frame
    /// decode, and the line rebuilt on a clock.
    private static func emoji(_ shortcode: String, seed: Int) -> CustomEmoji {
        guard let moving = FixtureImages.emoji(shortcode, seed: seed, frames: 6),
              let still = FixtureImages.emoji("\(shortcode)-still", seed: seed, frames: 1) else {
            // Unreachable in practice; a shortcode with nowhere to point is drawn as its own
            // text, which is exactly what should happen.
            return CustomEmoji(shortcode: shortcode, url: URL(string: "file:///dev/null")!)
        }
        return CustomEmoji(shortcode: shortcode, url: moving, staticURL: still)
    }

    /// A picture that is drawn rather than downloaded, and drawn the same way every run.
    ///
    /// `AsyncImage` is what the row uses, and it reads a `file:` URL as happily as any other,
    /// so the fixture's pictures are real files in the temporary directory and the drawing
    /// code above them is untouched. Nothing is committed: an invented photograph would be a
    /// binary in the repository that no test can check and nobody can regenerate.
    private static func image(_ name: String, seed: Int, side: Int = 640) -> Attachment {
        let url = FixtureImages.url(name, seed: seed, width: side, height: side * 68 / 100)
        return Attachment(kind: .image, url: url, previewURL: url,
                          alt: "An invented picture, drawn by the app so that nothing is fetched.")
    }
}

/// Where the fixture's pictures are drawn and kept for the run.
enum FixtureImages {
    private static let directory: URL = {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("fediqo-fixture")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// A custom emoji, drawn as a disc that turns through the palette. `frames` of 1 is the
    /// still — the copy a reader who has asked for less movement is given — and anything more
    /// is a GIF with a fortieth of a second on each frame, which is what a real one looks like.
    static func emoji(_ name: String, seed: Int, frames: Int) -> URL? {
        let file = directory.appendingPathComponent("emoji-\(name).gif")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.gif.identifier as CFString,
                                                               frames, nil) else { return nil }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        for frame in 0..<frames {
            guard let image = disc(seed: seed + frame, turn: Double(frame) / Double(frames)) else { continue }
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: 0.1],
            ] as CFDictionary)
        }
        return CGImageDestinationFinalize(destination) ? file : nil
    }

    /// One frame of one: a disc on nothing, at a size and a colour that say which frame it is.
    private static func disc(seed: Int, turn: Double) -> CGImage? {
        let side = 64
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let hues: [(CGFloat, CGFloat, CGFloat)] = [
            (0.96, 0.72, 0.24), (0.36, 0.74, 0.62), (0.86, 0.42, 0.42),
            (0.45, 0.58, 0.92), (0.72, 0.52, 0.88), (0.52, 0.78, 0.36),
        ]
        let (red, green, blue) = hues[abs(seed) % hues.count]
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        // The disc breathes between two thirds and the whole of the square, so the movement is
        // unmistakable at the size a line of text draws it.
        let inset = CGFloat(side) * 0.16 * CGFloat(abs(sin(turn * .pi)))
        context.fillEllipse(in: CGRect(x: inset, y: inset,
                                       width: CGFloat(side) - inset * 2, height: CGFloat(side) - inset * 2))
        return context.makeImage()
    }

    /// Two flat bands and a disc, from a palette picked by `seed`. It is not art and is not
    /// trying to be; it is a picture-shaped thing of a fixed size, so a row with something
    /// attached looks like a row with something attached.
    static func url(_ name: String, seed: Int, width: Int, height: Int) -> URL? {
        let file = directory.appendingPathComponent("\(name).png")
        if FileManager.default.fileExists(atPath: file.path) { return file }

        let palette: [(CGFloat, CGFloat, CGFloat)] = [
            (0.24, 0.31, 0.44), (0.39, 0.29, 0.35), (0.22, 0.38, 0.36),
            (0.45, 0.36, 0.24), (0.28, 0.26, 0.42), (0.35, 0.40, 0.28),
            (0.19, 0.34, 0.42), (0.42, 0.25, 0.28),
        ]
        let (red, green, blue) = palette[abs(seed) % palette.count]
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: red * 1.45, green: green * 1.45, blue: blue * 1.45, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 3))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.16)
        let side = CGFloat(min(width, height)) * 0.42
        context.fillEllipse(in: CGRect(x: CGFloat(width) * 0.58, y: CGFloat(height) * 0.30,
                                       width: side, height: side))

        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return file
    }
}

/// The fixture's answer to every question the timeline asks a server. No `URLSession` is built
/// here and none is reachable from here, which is what "nothing reaches a real server" means.
struct FixtureSource: SourceClient {
    func instance(host: String) async throws -> InstanceInfo {
        InstanceInfo(host: host, title: Fixture.title(of: host), summary: "An invented server.")
    }

    /// One page and no more. A fixture that handed over history for ever would be a fixture
    /// nobody could photograph the end of the timeline on.
    /// One page and no more, and one stretch and no more: a fixture asked for what is between
    /// two posts it has already handed over has nothing further to say, which is the honest
    /// answer for an invented world where nothing arrives late.
    func timeline(host: String, limit: Int, before: Post?, after: Post?,
                  token: String?) async throws -> [Post] {
        before == nil && after == nil ? Fixture.timeline(of: host) : []
    }

    /// Nobody is signed in to an invented server, so nobody has a home on one.
    func home(host: String, limit: Int, before: Post?, after: Post?,
              token: String) async throws -> [Post] { [] }

    func trending(host: String, limit: Int, token: String?) async throws -> [Post] {
        Fixture.trending(of: host)
    }

    func context(of post: Post, host: String, token: String?) async throws -> Conversation {
        Fixture.conversation(around: post)
    }

    /// Nothing invented is ever taken down: a fixture that reconciled its own rows away would
    /// photograph differently depending on how long the app had been open.
    func stillHas(_ post: Post, host: String, token: String?) async throws -> Bool { true }

    // MARK: - People

    /// What an invented person says about themselves. One line, in the fixture's own voice, so
    /// that the page has words on it without a screenshot pretending to have read anybody's real
    /// self-description.
    private static func note(for handle: String) -> String {
        "Reading rooms, mostly. The one at the top of the hill has the light and none of the chairs."
    }

    /// Somebody, invented out of what this server's own timeline says about them.
    ///
    /// Built from a post rather than from a second list, so the name, the handle and the emoji
    /// on the page are the ones on the rows behind it — a fixture whose person disagreed with
    /// their own posts would photograph as a bug.
    ///
    /// The counts are here because their absence is what a screenshot would otherwise show, and
    /// "this server did not say" is a state worth being able to photograph but not the one every
    /// picture should be of.
    func profile(handle: String, host: String, token: String?) async throws -> Profile? {
        guard let post = Fixture.timeline(of: host).first(where: { $0.authorHandle == handle })
        else { return nil }
        return Profile(id: handle, authorId: post.authorId, name: post.authorName,
                       handle: post.authorHandle, avatarURL: post.authorAvatarURL,
                       note: Self.note(for: post.authorHandle), emojis: post.emojis,
                       posts: 412, followers: 89, following: 130,
                       joined: Date(timeIntervalSince1970: 1_710_000_000))
    }

    func posts(by id: String, host: String, limit: Int, before: Post?,
               token: String?) async throws -> [Post] {
        before == nil ? Fixture.timeline(of: host).filter { $0.authorHandle == id } : []
    }

    /// Nobody is signed in to an invented server, so there is no account to have a relationship
    /// from. `nil` and not a made-up "not following": the page has a state for being unable to
    /// say, and it is the honest one here.
    func relationship(with handle: String, as account: ActingAccount) async throws -> Relationship? {
        nil
    }

    /// Who somebody follows, and who follows them (#90), invented out of the same timeline the
    /// rest of this fixture is — so a person on a list and the same person on a row are one
    /// person, and pressing through from one to the other lands somewhere real.
    ///
    /// **`following` is answered and `followers` is withheld**, on purpose. The two empties a
    /// list can have are the whole of what #90 is careful about, and a fixture that only ever
    /// showed the easy one would leave the honest state of the other unphotographed: the profile
    /// publishes 89 followers and this hands over none of them, which is exactly what a server
    /// told not to publish a list does.
    func people(_ kind: People.Kind, of id: String, host: String, limit: Int,
                before: Profile?, token: String?) async throws -> [Profile] {
        guard kind == .following, before == nil else { return [] }
        var seen: Set<String> = []
        return Fixture.timeline(of: host).compactMap { post in
            guard post.authorHandle != id, seen.insert(post.authorId).inserted else { return nil }
            return Profile(id: post.authorHandle, authorId: post.authorId, name: post.authorName,
                           handle: post.authorHandle, avatarURL: post.authorAvatarURL,
                           emojis: post.emojis)
        }
    }

    // MARK: - Writing
    //
    // Every one of these agrees at once and sends nothing. An invented server that refused
    // would photograph as a broken app, and one that reached the network would not be a
    // fixture. What is written down still goes to the store, so a star pressed in a fixture
    // run fills in exactly as it would anywhere else.

    func localId(of post: Post, as account: ActingAccount, fetching: Bool) async throws -> Located {
        Located(id: post.mergeKey, reach: .alreadyThere)
    }

    /// An invented server agrees and says nothing about the numbers: a fixture that made one
    /// up would photograph differently every time somebody pressed a key.
    func setMark(_ action: PostAction, on id: String, as account: ActingAccount,
                 done: Bool) async throws -> Marked {
        Marked()
    }
    func setMute(_ kind: Mute.Kind, _ value: String, as account: ActingAccount, muted: Bool) async throws {}
    func report(_ post: Post, id: String, as account: ActingAccount, comment: String) async throws {}
}

/// The chosen servers, for a run that must not read or write the machine's own list.
@MainActor
final class FixtureServerStore: ServerStore {
    private(set) var servers: [Server] = Fixture.servers
    func add(_ server: Server) { servers.append(server) }
    func remove(_ server: Server) { servers.removeAll { $0.id == server.id } }
    func removeAll() { servers.removeAll() }
}
#endif
