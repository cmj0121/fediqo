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
                 counts: Counts(replies: 3, reblogs: 2, favourites: 14)),
        ]
    }

    private static func birch(_ now: Date) -> [Post] {
        [
            post("carried-by-two", host: hosts[1], origin: hosts[0], minutesAgo: 12, now: now,
                 name: "Wren Ashby", handle: "wren",
                 text: "Two servers carried this one. The timeline says so underneath rather "
                     + "than showing it to you twice.",
                 counts: Counts(replies: 4, reblogs: 11, favourites: 27)),
            post("the-warning", host: hosts[1], minutesAgo: 63, now: now,
                 name: "Dag Solheim", handle: "dag",
                 text: "The photographs from the dig, which are a lot of bones.",
                 attachments: [image("warned", seed: 7)],
                 sensitive: true, spoiler: "Archaeology, human remains",
                 counts: Counts(replies: 6, reblogs: 4, favourites: 31)),
            post("the-boost", host: hosts[1], minutesAgo: 128, now: now,
                 name: "Mira Halvorsen", handle: "mira",
                 text: "A quiet argument for reading things in the order they were written.",
                 counts: Counts(replies: 0, reblogs: 8, favourites: 22),
                 boostedBy: "Dag Solheim"),
        ]
    }

    private static func cedar(_ now: Date) -> [Post] {
        [
            post("the-tags", host: hosts[2], minutesAgo: 27, now: now,
                 name: "Yusuf Adeyemi", handle: "yusuf",
                 text: "Reading rooms, mostly. The one at the top of the hill has the light "
                     + "and none of the chairs.",
                 attachments: [image("room", seed: 3)],
                 counts: Counts(replies: 2, reblogs: 5, favourites: 41),
                 tags: ["libraries", "slowweb"]),
            post("the-plain-one", host: hosts[2], minutesAgo: 74, now: now,
                 name: "Bea Lindqvist", handle: "bea",
                 text: "No picture, no warning, no numbers anybody has told us. A post can be "
                     + "just its words, and the row does not pad it out with an empty box.",
                 counts: Counts()),
        ]
    }

    /// The conversation under `the-thread`, as its own server would hand it over.
    static func conversation(around post: Post, now: Date = Date()) -> Conversation {
        guard post.mergeKey == address("the-thread", on: hosts[0], by: "wren")
        else { return Conversation(post: post) }
        let replies = [
            ("reply-one", "Ines Okafor", "ines", 88.0,
             "One order, and nothing between what arrived and what I see except a rule I wrote."),
            ("reply-two", "Bea Lindqvist", "bea", 71.0,
             "Mine is narrower than that. I want the servers I never joined, and no home page."),
            ("reply-three", "Wren Ashby", "wren", 55.0,
             "Both of those are the same feature, which is the part I keep failing to explain."),
        ].map { uri, name, handle, minutes, text in
            Self.post(uri, host: hosts[0], minutesAgo: minutes, now: now, name: name,
                      handle: handle, text: text,
                      inReplyToURI: address("the-thread", on: hosts[0], by: "wren"))
        }
        return Conversation(post: post, descendants: replies)
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
        counts: Counts = Counts(), tags: [String] = [], boostedBy: String? = nil,
        inReplyToURI: String? = nil
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
            counts: counts,
            application: Application(name: "Fediqo"),
            webURL: URL(string: "https://\(host)/@\(handle)/\(uri)"),
            inReplyToURI: inReplyToURI,
            tags: tags,
            boostedBy: boostedBy,
            boostedById: boostedBy.map { "https://\(host)/users/\($0.lowercased())" },
            sources: [host]
        )
    }

    /// Where one post lives, spelled the way a Mastodon server spells it.
    private static func address(_ uri: String, on host: String, by handle: String) -> String {
        "https://\(host)/users/\(handle)/statuses/\(uri)"
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
    func timeline(host: String, limit: Int, before: Post?, token: String?) async throws -> [Post] {
        before == nil ? Fixture.timeline(of: host) : []
    }

    /// Nobody is signed in to an invented server, so nobody has a home on one.
    func home(host: String, limit: Int, before: Post?, token: String) async throws -> [Post] { [] }

    func trending(host: String, limit: Int, token: String?) async throws -> [Post] {
        Fixture.trending(of: host)
    }

    func context(of post: Post, host: String, token: String?) async throws -> Conversation {
        Fixture.conversation(around: post)
    }

    /// Nothing invented is ever taken down: a fixture that reconciled its own rows away would
    /// photograph differently depending on how long the app had been open.
    func stillHas(_ post: Post, host: String, token: String?) async throws -> Bool { true }
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
