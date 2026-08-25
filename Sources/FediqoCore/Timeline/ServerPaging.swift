import Foundation

/// Where each server has got to reading backwards, kept by `Server.endpoint`.
///
/// Every server is asked separately for what came before, because each keeps its own thread
/// of time. So a cursor here is the last post *that server itself* handed over — never the
/// foot of a merged page, which may well belong to somebody else. `Post.sourceURL` names only
/// the first server to hand a post over, so nothing about a merged page says who else had it,
/// and using its foot as a cursor would ask one server for what came before another's post.
///
/// Three facts per server, and they are three different things. Its cursor is where it has
/// got to. Exhausted is that it has said it has nothing older — a fact about that server and
/// not about the timeline, so the others carry on without it. In flight is that a page is
/// already out, so a reader scrolling hard asks it once and not once a frame.
///
/// In memory, for as long as the app runs, and per endpoint rather than per host — the same
/// shape and the same reasons as `ServerBackoff` beside it, and held by the same loader, so
/// where a timeline has got to says nothing about the same server's trending list. Like the
/// backoff, it keeps nothing about a server that has left the chosen list: none of it is true
/// of a server nobody is reading, and it is where the map stops growing with the servers it
/// outlived.
actor ServerPaging {
    private struct Place {
        /// The last post this server handed over, and so what it is asked for the page
        /// before. Nil until it has handed over anything, which asks for its newest page.
        var cursor: Post?
        /// It has said it has nothing older.
        var exhausted = false
        /// A page is out and has not come back.
        var inFlight = false
    }

    private var places: [String: Place] = [:]

    /// The chosen servers are now these, and everything remembered about anybody else goes.
    ///
    /// Exhaustion is a fact about a server we are reading. A server that has been dropped is
    /// not being read, and one added back is a stranger again: asked from its newest page, and
    /// asked at all rather than passed over as spent. Its cursor could not survive either —
    /// what it handed over before may be gone by the time it returns.
    ///
    /// The whole chosen list, not the shorter one this reach may ask: a server inside its wait
    /// has not left anything, and losing where it had got to is no part of what a wait is for.
    func forget(everyoneBut servers: [Server]) {
        let chosen = Set(servers.map(\.endpoint))
        places = places.filter { chosen.contains($0.key) }
    }

    /// Which of `servers` may be asked for a page now, each with its own cursor — and every
    /// one handed back is marked in flight by the asking.
    ///
    /// Claiming and marking are one hop rather than a question and then a decision: two
    /// reaches for the bottom arriving together would otherwise both find a server free and
    /// both ask it. Whoever claims must give it back, through `gave` or `gaveNothing`.
    ///
    /// Whoever is still inside a backoff's wait is not among `servers` at all: that is the
    /// loader's filter and not this one's, so the two reasons a server goes unasked stay two
    /// separate facts kept in two separate places.
    func claim(_ servers: [Server]) -> [(server: Server, cursor: Post?)] {
        servers.compactMap { server in
            var place = places[server.endpoint] ?? Place()
            guard !place.exhausted, !place.inFlight else { return nil }
            place.inFlight = true
            places[server.endpoint] = place
            return (server, place.cursor)
        }
    }

    /// What one server handed over, in the order it gave it — so its last post is where that
    /// server has now got to, and the page before that one is what it is asked for next.
    ///
    /// Only an empty page ends a server. A short one is not evidence: Mastodon takes accounts
    /// a reader has blocked or a filter has hidden out of a range it has already chosen, so a
    /// server with plenty left can answer a page of forty with three rows. It handed over
    /// posts, and a cursor with them, so it is asked again from there.
    ///
    /// Being wrong this way costs one round trip at the true end — the last real page, and
    /// then an empty one. Being wrong the other way ends a server that had more to give, and
    /// nothing ever resets it: that server is silently truncated for the rest of the run, and
    /// where it is the last one still going, the screen tells the reader they have finished
    /// reading when they have not.
    func gave(_ page: [Post], _ endpoint: String) {
        // The page is back whatever it carried, so this is the write that must land even for a
        // server nothing has claimed yet — hence the default. After it there is a place here,
        // and the two below reach it the way `gaveNothing` and `forget` reach theirs.
        places[endpoint, default: Place()].inFlight = false
        if let last = page.last {
            places[endpoint]?.cursor = last
        } else {
            places[endpoint]?.exhausted = true
        }
    }

    /// Nothing arrived from this server: it failed, or the request never left. The page is
    /// over and the server is free to be asked again, but where it had got to is unchanged —
    /// silence is not an end, and the next reach asks it from the same place.
    func gaveNothing(_ endpoint: String) {
        places[endpoint]?.inFlight = false
    }

    /// This server's cursor was not a post of its own — so it is dropped rather than asked
    /// about a second time, and the next page it is asked for is its newest. Per-server
    /// cursors are meant to make that impossible; this is what happens if one ever gets out.
    func forget(_ endpoint: String) {
        places[endpoint]?.cursor = nil
    }

    /// Every one of `servers` has said it has nothing older — the only thing on which a
    /// screen may say the reading is over. One server running out while the others keep
    /// going is an ordinary Tuesday and says nothing about the timeline.
    ///
    /// False with no servers at all: there is nobody to have reached an end.
    func reachedTheEnd(of servers: [Server]) -> Bool {
        !servers.isEmpty && servers.allSatisfy { places[$0.endpoint]?.exhausted == true }
    }
}
