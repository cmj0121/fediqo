import FediqoCore
import SwiftUI

/// One row's share of #54's acts (#106), with every press it carries: what the timeline, a
/// conversation, somebody's page and the notices page (#375) all hand a post's row.
///
/// **One builder for every list a post's row stands on**, so a post drawn on the notices page is
/// the same row it is on the timeline: the session holds what the sign-in bought and what the
/// source has turned away since, and each list working it out for itself would be one more
/// derivation free to disagree about one post.
@MainActor
struct RowActing {
    let session: ShellSession
    var people: ShellPersonPages?
    var linkPreviews = true
    /// Opening the conversation of the row with this id.
    let openThread: (String) -> Void
    /// Opening who boosted or favourited it, from the row with this id.
    var openPeople: (PeopleList, String) -> Void = { _, _ in }

    /// The acts of `item`, drawn inside the conversation around `root` where there is one —
    /// where the answer mark opens the answer rather than the conversation (#108).
    func callAsFunction(_ item: DummyItem, inside root: DummyItem? = nil) -> ItemActing {
        var acting = session.acting(on: item)
        acting.perform = { act in
            switch act {
            case .boost, .favourite, .bookmark:
                Task { await session.toggle(act, on: item) }
            case .answer:
                if let root {
                    session.openAnswer(to: item, in: root)
                } else {
                    openThread(item.id)
                }
            // No mark performs these: taking back is an item of the row's `…` (`withdraw`,
            // below), and a vote is pressed from the post's poll with its choices (`vote`).
            case .withdraw, .vote:
                break
            }
        }
        // A post's poll (#331): voted in where the post offers it, read again wherever it is.
        if acting.acts.offers(.vote), acting.poll != nil {
            acting.vote = { choices in Task { await session.vote(item, choices: choices) } }
        }
        if acting.poll != nil { acting.readPoll = { Task { await session.readPollAgain(item) } } }
        if let lock = acting.voteLock { acting.askToVote = { _ = session.askFor([.acting], host: lock.host) } }
        // What `y` does (#284), and it says so itself: one act, one outcome, whichever asked.
        acting.keep = { Task { await session.toggleKept(item) } }
        acting.ask = { _ in session.askToBookmark(item) }
        acting.locks = session.locks(on: item, acts: acting.acts)
        // Reporting it (#339): the sheet goes up at the press, or the sign-in is asked for more.
        if let people, let offer = session.reportOffer(on: item) {
            acting.report = ItemActing.Report(lock: offer.lock) {
                Task { await people.reports.start(offer.who, post: offer.post, people: people, in: session) }
            }
        }
        // The preview of the page it links to (#335), where the person lets previews be drawn:
        // its picture only where the gate lets it through as one its own source pointed to.
        acting.preview = LinkPreview.of(item, shown: linkPreviews) { reached, source in
            session.work.admits(reached: reached, source: source)
        }
        // Pinning, quieting, translating, and who boosted and favourited it (#334). Translate on a
        // list row opens the post, where its translation is drawn beside its words.
        if let people {
            acting.post = session.postOffer(
                on: item, people: people, openPeople: { list in openPeople(list, item.id) },
                afterTranslate: root == nil ? { openThread(item.id) } : nil
            )
        }
        // Quoting it (#330): the mark live where its source lets the reader, dim with why where not;
        // and on the reader's own post, who may quote it and its quotes.
        acting.quote = session.quoteOffer(on: item)
        acting.ownQuotes = session.ownQuotesOffer(on: item)
        // Changing it (#332): the sheet opens on the reader's own copy, or the sign-in is asked.
        if let offer = session.changeOffer(on: item) {
            acting.change = ItemActing.Change(lock: offer.lock) {
                if let lock = offer.lock {
                    _ = session.askFor([.acting], host: lock.host)
                } else {
                    session.changes.start(item, in: session)
                }
            }
        }
        // Taking back is an item of the row's `…` (#109), built only where the post offers it:
        // the question the key `d` asks, about the copy that goes, and a yes that refuses what
        // that asking refuses.
        if acting.acts.offers(.withdraw) {
            acting.withdraw = ItemActing.Withdraw(
                asks: { ShellQuestion.withdraw(session.actingCopy(of: item, for: .withdraw) ?? item) },
                yes: { session.withdrawAsked(item) }
            )
        }
        return acting
    }
}
