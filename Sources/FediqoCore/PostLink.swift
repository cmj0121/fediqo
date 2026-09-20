import Foundation

/// One address written in a post's words, and the letters it was written with.
///
/// **The letters and the address are one string.** `text` is what the author typed and `url` is
/// that same string parsed — nothing is ever read out of an `href`, a title attribute or any
/// other part of a stranger's markup. So the oldest trick there is, a link that reads
/// `example.com` and goes somewhere else, is not a thing this type can express: the reader is
/// looking at the address.
///
/// **It cannot be built out of an address this device will not go to.** The only initialiser is
/// failable and goes through `followable`, so a `PostLink` in hand is a checked address and every
/// consumer of one is holding a checked address rather than remembering to check it. That is the
/// same shape `DummyItem.outwardURL` took for the way out of the app, and for the reason
/// `ShellSession.remove`'s own comment gives: a rule enforced at each consumer's door is a rule
/// consumer N+1 misses.
public struct PostLink: Sendable, Hashable {
    /// Exactly what the author typed, drawn exactly as they typed it.
    public let text: String
    /// Where a press goes. Parsed from `text` and from nothing else.
    public let url: URL
    /// The host a reader is told they are being taken to. ASCII by construction — see
    /// `allowed` — so it is the name the wire uses and not a picture of one.
    public let host: String

    public init?(_ text: String) {
        guard let url = Self.followable(text), let host = url.host(), !host.isEmpty else {
            return nil
        }
        self.text = text
        self.url = url
        self.host = host
    }
}

public extension PostLink {
    /// The one rule this app follows an address under, read at the one boundary a post's words
    /// reach: **`https`, a host to reach, and nobody's credentials.**
    ///
    /// `Host.allowsFetch` is decision 9 — it is what `URLSession` fetches under, what an
    /// attachment is admitted under, and what the way out of the app hands the system browser.
    /// Handing one to a web view inside this app is exactly as much of a wire boundary as any of
    /// those, so it is the same function and not a second spelling of the same idea.
    ///
    /// **What it refuses, and why each refusal is deliberate.** A post's text is written by a
    /// stranger, so every one of these is a thing a stranger would otherwise be deciding.
    ///
    /// - `http` — not followed and not even drawn as a link. This app has one wire rule and it is
    ///   `https`; an author does not get to ask a reader's device for a plaintext hop. Drawing it
    ///   as a link and then refusing the press would be a control that exists on the screen and
    ///   not in the app, which is the defect this repo keeps writing down.
    /// - `javascript:` — script in a surface the reader believes is a page they chose.
    /// - `data:` — the author's own HTML, rendered inside this app, with this app's chrome round
    ///   it saying a host that is not there.
    /// - `file:` — this device's own disk, read by somebody else's post.
    /// - any other scheme (`mailto:`, `tel:`, `itms-apps:`, an app's own) — a request to hand the
    ///   reader to another program. A post's author does not get to make it.
    ///
    /// None of those four can even reach this function, because `spans(in:)` opens a candidate
    /// only at a literal `https://`. They are refused here as well because this is the function
    /// that states the rule, and a rule stated only where it happens to be unreachable is a rule
    /// that stops being true the day the scanner grows.
    ///
    /// **Credentials are refused rather than stripped.** `https://apple.com@evil.example/` has a
    /// host of `evil.example` and reads, to a person, as Apple's. Nothing honest can be done with
    /// it — stripping the userinfo would open a different address from the one on the screen, and
    /// keeping it would hand a password to a web view — so it is not a link at all.
    static func followable(_ raw: String) -> URL? {
        guard !raw.isEmpty, let url = URL(string: raw), Host.allowsFetch(url) else { return nil }
        guard url.user() == nil, url.password() == nil else { return nil }
        return url
    }

    /// The links in a post's words, in the order they were written, and never more than
    /// `maxLinks` of them.
    static func found(in text: String) -> [PostLink] {
        spans(in: text).map(\.link)
    }

    /// How many links one post's words may draw.
    ///
    /// **A bound on what a hostile instance can make a row do**, in the same family as the row's
    /// own line limits and `maxShortcodeLength`: a post is five hundred characters of somebody
    /// else's choosing, and five hundred one-character-apart addresses would be five hundred
    /// attributed runs in a line that is re-laid-out on every pass of the row. Far more than any
    /// post a person writes, and small enough that the worst case is a shape rather than a stall.
    /// Past it the addresses stay as the letters they were typed as, which is what a reader would
    /// have seen anyway.
    static var maxLinks: Int { 32 }

    /// What opens a candidate. The only one: this scanner does not guess that `example.com` or
    /// `www.example.com` was meant to be an address, because guessing is how a name somebody
    /// chose for themselves becomes a control the reader can press.
    internal static var opener: String { "https://" }

    /// Where each link sits in the words, and what it is.
    ///
    /// Scanned by hand rather than by a data detector: `NSDataDetector` links bare hosts, phone
    /// numbers and addresses, which is four more decisions about a stranger's text than this unit
    /// asked for — and it does not answer to `https` only.
    internal static func spans(in text: String) -> [(range: Range<String.Index>, link: PostLink)] {
        var found: [(range: Range<String.Index>, link: PostLink)] = []
        var cursor = text.startIndex
        while found.count < maxLinks,
              let hit = text.range(of: opener, options: [.caseInsensitive], range: cursor ..< text.endIndex)
        {
            cursor = hit.upperBound
            guard opensAWord(text, at: hit.lowerBound) else { continue }
            let end = addressEnd(text, from: hit.upperBound)
            cursor = end
            let span = hit.lowerBound ..< trimmedEnd(text[hit.lowerBound ..< end])
            guard let link = PostLink(String(text[span])) else { continue }
            found.append((span, link))
        }
        return found
    }

    /// Whether an `https://` at `index` starts an address rather than sitting inside a word.
    ///
    /// **ASCII alphanumerics only, and that is the load-bearing detail.** `Character.isLetter` is
    /// true of 看 and of every other CJK character, so a rule written with it would refuse to
    /// link `請看https://example.test/a` — which is how a great many posts in this app's own
    /// second language are written, with no space before the address. An address is ASCII (see
    /// `allowed`), so a letter that is not ASCII cannot be part of the one before this.
    private static func opensAWord(_ text: String, at index: String.Index) -> Bool {
        guard index > text.startIndex else { return true }
        let before = text[text.index(before: index)]
        return !(before.isASCII && (before.isLetter || before.isNumber))
    }

    /// Where the address stops: the first character an address is not written with.
    ///
    /// **RFC 3986's own set, and nothing outside it.** That is one rule doing four jobs: it ends
    /// the address at a space, it ends it at the CJK sentence it is embedded in
    /// (`https://example.test/a這個` is an address and then two words), it keeps a bidirectional
    /// override such as `U+202E` — which makes an address read backwards on the screen — out of
    /// a link entirely, and it means a host is only ever the ASCII name the wire uses. A person
    /// who writes `https://台灣.tw` is not given a link; the punycode spelling of the same host
    /// is. The cost is real and it is the one worth paying: what is drawn as a link is what the
    /// device will reach, character for character, with no script anybody can read two ways.
    private static func addressEnd(_ text: String, from start: String.Index) -> String.Index {
        var cursor = start
        while cursor < text.endIndex, allowed(text[cursor]) {
            cursor = text.index(after: cursor)
        }
        return cursor
    }

    /// The unreserved, reserved and escape characters an address is spelled with.
    private static func allowed(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1, character.isASCII
        else { return false }
        if character.isLetter || character.isNumber { return true }
        return "-._~:/?#[]@!$&'()*+,;=%".unicodeScalars.contains(scalar)
    }

    /// The sentence's punctuation handed back to the sentence.
    ///
    /// `.`, `,` and their friends are legal in a path and are also how a sentence ends, so an
    /// address at the end of one would otherwise swallow the full stop. A closing bracket is
    /// given back only when nothing in the address opened it — `(` is legal in a path and
    /// Wikipedia writes addresses that end in `)`.
    private static func trimmedEnd(_ address: Substring) -> String.Index {
        var address = address
        while let last = address.last {
            if ".,:;!?'\"".contains(last) {
                address = address.dropLast()
                continue
            }
            if last == ")", address.filter({ $0 == "(" }).count < address.filter({ $0 == ")" }).count {
                address = address.dropLast()
                continue
            }
            break
        }
        return address.endIndex
    }
}

public extension EmojiRun {
    /// A post's own words, cut into letters, pictures and the addresses they were written with.
    ///
    /// **Prose, and only prose.** A name, a handle and a spoiler line are labels a stranger chose
    /// and go through `CustomEmoji.runs` instead: a person may call themselves
    /// `https://example.test`, and a row that quietly turned that into a control the reader can
    /// press would be inventing something about a post. `EmojiText` keeps the same split in its
    /// two initialisers and says so there.
    static func prose(in text: String, emojis: [CustomEmoji]) -> [EmojiRun] {
        // `https://` has a colon in it and so does every shortcode, so a line with no colon has
        // neither — one run, no scan, and that is most lines.
        guard text.utf8.contains(UInt8(ascii: ":")) else {
            return CustomEmoji.runs(in: text, from: emojis)
        }
        let spans = PostLink.spans(in: text)
        guard !spans.isEmpty else { return CustomEmoji.runs(in: text, from: emojis) }

        var runs: [EmojiRun] = []
        var cursor = text.startIndex
        for span in spans {
            if cursor < span.range.lowerBound {
                runs += CustomEmoji.runs(in: String(text[cursor ..< span.range.lowerBound]), from: emojis)
            }
            runs.append(.link(span.link))
            cursor = span.range.upperBound
        }
        if cursor < text.endIndex {
            runs += CustomEmoji.runs(in: String(text[cursor...]), from: emojis)
        }
        return runs
    }
}
