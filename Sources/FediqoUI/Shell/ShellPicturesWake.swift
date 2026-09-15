// Which pictures are worth asking for again, and why only the screen can say which.
//
// An extension rather than a change to `ShellPictures`: that file is merged, its invariants are
// load-bearing, and this needs nothing from inside it — `missing` and `maxInFlight` are both
// readable from here. Kept out of `FediqoRootView` all the same, because what counts as stranded
// is a fact about the cache and belongs next to it rather than inside a view.

import Foundation

/// One picture a screen is drawing, and which of the reader's servers it is drawn under.
///
/// The pair, never the address alone. A wake ends in a `fetch`, and `fetch` needs a source to
/// file what comes back under — the address itself cannot be traced back to one, because it
/// usually points at a CDN. See `ShellPictures`, I10. Only the screen holds both halves, which
/// is why the wake is driven from there.
struct DrawnPicture: Hashable {
    let url: URL
    let host: String
}

extension ShellPictures {
    /// Of the pictures a screen is drawing, the ones an outage wrote off — a handful of them,
    /// and **a different handful each time**.
    ///
    /// **Asked of what is drawn, not of the whole cache, and the difference is not tidiness.** A
    /// `Key` carries no host, by decision 19: the source lives in a set on the entry, so nothing
    /// inside the cache can say which server to ask a stranded address on behalf of. The screen
    /// can, because it has `item.source.host` beside every address it draws.
    ///
    /// The other half of the reason is damage. A key nobody has drawn recently carries no
    /// `interest` stamp, so a fetch for it arrives with a stamp of zero, can evict nothing, and
    /// on a full cache is **declined and marked `.crowded` — which is terminal for the life of
    /// the process**. A wake that reached such a key could permanently strand a picture nobody
    /// was even looking at. `interest[key] != nil` is the guard, and it is the honest spelling of
    /// "still being drawn": a stamp is what `picture(…)` leaves on every body pass, and
    /// `trimInterest` drops it only for a key with no picture that nothing has read in a long
    /// while. The list a screen hands over is the whole list rather than the rendered window, so
    /// without this guard the claim above would be a claim the code does not keep.
    ///
    /// Only `.unreachable`. The other two kinds of nothing are answers: `.refused` is a server
    /// that said no and will say no again, and `.crowded` is terminal by design — asking for
    /// either is a request whose result is already known. The filter has to be this precise
    /// rather than "is there no picture", because a screen's addresses come in a **fixed order**:
    /// a bound applied before the filter would take the same first few every time, and a screen
    /// whose first few absences are refusals would wake nothing, on every activation, forever.
    ///
    /// **A handful rather than all of them, and a handful is enough** — the first answer that
    /// gets through clears the entire outage cohort by itself. `keep` calls `forgetUnreachable`,
    /// which drops every `.unreachable` mark, on screen or off, and bumps the generation every
    /// `RemoteImage` is waiting on. The bound is the cache's own limit on what may be in the air
    /// at once, so a wake can never ask for more than the cache was already willing to hold.
    ///
    /// **`cursor` is what makes that true, and it is the half an ordered list took away.** The
    /// bound is a hedge against a few addresses being individually unlucky, and a hedge is only a
    /// hedge if the unluckiness is redrawn. The global version this replaces was handed a
    /// different handful every time by `Dictionary.keys` and said so; a screen's list is stable,
    /// so four addresses on a CDN that stays dark would be the whole of every activation for
    /// ever, while a fifth address on a CDN that has come back sits behind them — never asked,
    /// and never re-asking on its own either, because with no success there is no generation bump
    /// and a mounted row's `.task` identity does not change. Rotating the start heals it: every
    /// eligible address is reached within `ceil(eligible / maxInFlight)` activations.
    ///
    /// A cursor rather than a shuffle, because a cursor is deterministic and can therefore be
    /// tested, and this file has paid enough for tests that cannot fail.
    ///
    /// Deduplicated by address rather than by pair, because the bound is about requests and one
    /// address is one request however many sources are drawing it — `work` folds the second asker
    /// into the first's task. The source that misses out is not lost: its own row tags the entry
    /// on the read that follows the arrival.
    ///
    /// `.deck` because that is the tier a list draws at, both for the avatar and for the card on
    /// top of the deck. If unit 7's viewer can ever be open across a return from the background,
    /// its address belongs here too and this stops being one tier.
    func stranded(among drawn: [DrawnPicture], scale: CGFloat, from cursor: Int) -> [DrawnPicture] {
        var eligible: [DrawnPicture] = []
        var seen: Set<URL> = []
        for picture in drawn {
            guard seen.insert(picture.url).inserted else { continue }
            let key = Key(url: picture.url, scale: scale, tier: .deck)
            guard interest[key] != nil, missing[key] == .unreachable else { continue }
            eligible.append(picture)
        }
        guard !eligible.isEmpty else { return [] }

        // The two-step remainder rather than one, which is the form `AttachmentDeck.folded`
        // already uses and for the same reason: `%` keeps the sign of its left side, so a
        // negative cursor would index backwards and trap. Nothing hands this a negative today —
        // the caller counts up from zero — and it is one operator against a crash.
        let start = ((cursor % eligible.count) + eligible.count) % eligible.count
        return (0 ..< min(Self.maxInFlight, eligible.count)).map {
            eligible[(start + $0) % eligible.count]
        }
    }
}
