import FediqoCore
import Foundation

/// What the read-or-act question about a source is drawn from (#347), **read once and handed
/// over with its answer**: the sign-in held there, what signing in again carries of it, and
/// the parts ticked beside either answer. The question's words and the page either answer
/// opens are both read off this, so the page asks no word the question did not name — and
/// its yes opens no page where what is held has since become other than this
/// (`MastodonSessions.signIn(…answering:)`).
struct SignInDrawn: Equatable {
    /// The source, folded.
    let host: String
    /// Which sign-in the question is about: the mark of its filing. Nothing where none is held.
    var stamp: String?
    /// Every word the sign-in held is filed as holding: what an answer may give up.
    let scopes: String?
    /// The words of it either answer carries (`MastodonParts.carried`): what it was asked
    /// for where it stood, by this device.
    let carried: String?
    /// Whether the sign-in asked for carries the notices the one held has.
    let notices: Bool
    /// The parts ticked beside either answer: a first sign-in raised from a part's lock.
    let ticked: Set<MastodonPart>
    /// Which answer ends the sign-in held at the source. Nothing where none is held.
    var ends: MastodonSessions.SignInEnds?

    /// The words the page of one answer asks, or the same on a source without bookmarks, or
    /// without search.
    func page(search: Bool = true, writing: Bool, bookmarks: Bool = true) -> String {
        MastodonOAuth.scopes(
            search: search, writing: writing, bookmarks: bookmarks, notices: notices, carried: carried, ticking: ticked
        )
    }

    /// The words one answer's page asks beyond what that answer always asked: what the
    /// sign-in held carries to it, and what was ticked beside it. The question names each.
    func also(writing: Bool) -> [String] {
        MastodonParts.more(on: page(writing: writing), than: MastodonOAuth.scopes(writing: writing, notices: notices))
    }

    /// The held words neither answer's page asks, given up whichever is chosen — where the
    /// question has to say so (`toSay`).
    var lostEitherWay: [String] {
        Self.toSay(MastodonParts.lost(of: scopes, on: page(writing: true)))
    }

    /// The held words reading alone gives up and reading and acting keeps — where the
    /// question has to say so (`toSay`).
    var lostReading: [String] {
        let kept = page(writing: true).split(separator: " ").map(String.init)
        return Self.toSay(MastodonParts.lost(of: scopes, on: page(writing: false)).filter(kept.contains))
    }

    /// `lost`, where one of them is no word of the question's own: a word the sign-in was
    /// asked for where it stood, or one this build does not know. Nothing where they are
    /// only what the two answers differ by and the notices they carry, which the question's
    /// own words already say.
    private static func toSay(_ lost: [String]) -> [String] {
        let own = Set(MastodonOAuth.chosen.flatMap { $0.words + $0.wordsBesideActing })
        return lost.contains { !own.contains($0) } ? lost : []
    }

    /// Whether `question` was drawn from this — `same` being whether the two are about one
    /// sign-in (`MastodonSessions.isSame`).
    func isWhat(_ question: SignInDrawn, wasDrawnFrom same: Bool) -> Bool {
        var drawn = question
        drawn.stamp = stamp
        return same && drawn == self
    }
}

extension ShellSession {
    /// What the read-or-act question about `host` is drawn from, as the sign-in held there
    /// stands now — with what the question open says of notices (`signInAsked`) and the
    /// parts it was raised to tick. **The card keeps the one it was drawn from and hands it
    /// over with its answer** (`SignInChoiceQuestion`), so a yes is held to what was shown.
    func signInDrawn(host raw: String) -> SignInDrawn {
        let host = raw.lowercased()
        return mastodon.signInDrawn(
            host: host, notices: signInAsked(host: raw).notices, ticking: partAsks.signInTicks(host: host)?.parts ?? []
        )
    }

    /// The press on a part's lock **where no sign-in is held at `host`**: the read-or-act
    /// question, with `parts` ticked beside either answer and named by it (#347). Sends
    /// nothing. Returns whether the question was raised — not where a sign-in is held, which
    /// is asked where it stands (`askFor`).
    ///
    /// It is what makes "sign out and sign in again, choosing what to allow" true of a
    /// source whose sign-in could not be asked in place.
    @discardableResult
    func askSignIn(host raw: String, ticking parts: Set<MastodonPart>) -> Bool {
        guard !mastodon.isSignedIn(host: raw) else { return false }
        putDownSignInChoice()
        partAsks.tickSignIn(parts, host: raw.lowercased())
        signInChoice = raw
        return true
    }

    /// The read-or-act question about `host` raised from its own row: nothing is ticked,
    /// whatever a question before it was raised with.
    func askSignIn(host raw: String) {
        putDownSignInChoice()
        signInChoice = raw
    }

    /// The read-or-act question put again in the place of one whose yes opened no page:
    /// what is held turned out other than `drawn` was read from, and it says so.
    func askSignInAgain(_ drawn: SignInDrawn?, host raw: String) {
        putDownSignInChoice()
        partAsks.tickSignIn(drawn?.ticked ?? [], host: raw.lowercased(), again: true)
        signInChoice = raw
    }
}

extension ShellQuestion {
    /// What the read-or-act question says beyond its own words, of the sign-in it is drawn
    /// from (#347), each a whole sentence and in this order: the held words this build asks
    /// for on no page, which either answer gives up; what each answer's page asks beyond
    /// what that answer always asked; what reading alone leaves undone of a part ticked;
    /// what either answer gives up, and what reading alone does; and which answer ends the
    /// sign-in held at the source. **Every word a page carries is named by one of them or by
    /// the question's own**, and nothing is given up or ended that none of them said.
    ///
    /// **A part ticked says for itself what reading alone leaves of it**
    /// (`part.<name>.readOnly`), where reading alone asks for less than all of it; one with
    /// no such sentence says nothing.
    static func signInSaid(_ drawn: SignInDrawn, language: DummyLanguage? = nil) -> [String] {
        func said(_ key: String, _ words: [String], partly: String = "part.held.partly") -> String? {
            PartWords.listed(words, partly: partly, language: language).map {
                String(format: L10n.t(key, language: language), $0)
            }
        }
        let either = drawn.lostEitherWay
        let unknown = PartWords.shown(MastodonParts.unknown(in: either.joined(separator: " ")), language: language)
        var sentences: [String?] = [
            unknown.isEmpty ? nil : String(format: L10n.t("account.signin.ask.givesUp.other", language: language), unknown),
            said("account.signin.ask.also.read", drawn.also(writing: false)),
            said("account.signin.ask.also.write", drawn.also(writing: true)),
        ]
        let reading = drawn.page(writing: false).split(separator: " ").map(String.init)
        for part in PartWords.named(drawn.ticked) where !part.words.allSatisfy(reading.contains) {
            let key = "part.\(part.rawValue).readOnly"
            let sentence = L10n.t(key, language: language)
            if sentence != key { sentences.append(sentence) }
        }
        sentences += [
            said("account.signin.ask.givesUp.either", either),
            said("account.signin.ask.givesUp.read", drawn.lostReading, partly: "account.signin.ask.givesUp.changing"),
        ]
        if let ends = drawn.ends { sentences.append(signInEnds(ends, host: drawn.host, language: language)) }
        return sentences.compactMap { $0 }
    }
}
