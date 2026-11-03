import FediqoCore
import Foundation

/// What is in front arrives as it happens too (#460): a list or the public timeline the timeline in
/// front reads, and the posts under a hashtag whose page is up — each heard while it is in front, on
/// the source's one line (#459), and let go the moment it is not.
///
/// **Only where the person chose the source's line**, as Home's: signed in, a Mastodon, and not
/// refused this run. **The public timeline only where a rule of the timeline names it**: a source's
/// usual reads take it in on the wait, and hearing every server it knows of as it happens, for a
/// timeline that never asked for it by name, would cost the device more than any read. A list read
/// by the usual reads is heard: it is the reader's own choice, and says little.
///
/// **What was missed while it was not in front is read first**, as Home is (`MastodonAccount.catchUp`):
/// a list or the public timeline read on up to now, and only then does anything it tells land over
/// it. A hashtag's page reads itself as it opens (`ShellReload.tag`), and is no timeline read on.
extension ShellLines {
    /// One stream heard for what is in front, at one source.
    struct FrontWant: Hashable, Comparable {
        let host: String
        let stream: MastodonStream
        /// The hashtag whose page is up, for a hashtag's stream.
        let tag: PostTag?

        static func < (lhs: FrontWant, rhs: FrontWant) -> Bool {
            (lhs.host, lhs.stream.named.joined(separator: " ")) < (rhs.host, rhs.stream.named.joined(separator: " "))
        }
    }

    /// Every stream wanted now for what is in front, sorted: the lists and the public timeline of the
    /// timeline in front (`front`), and the hashtag of the page up — only while Fediqo is `running`.
    func frontWants(running: Bool, in session: ShellSession) -> [FrontWant] {
        guard running, !chosen.isEmpty else { return [] }
        var wants: Set<FrontWant> = []
        if let front, front.inFront, front.timeline != .trends {
            let asks = CompiledTimeline(front.timeline.definition(among: session.written), sources: session.sources).sourcesToAsk()
            for ask in asks {
                let host = ask.host.lowercased()
                guard mayHearFront(host, in: session),
                      let source = session.sources.first(where: { $0.host.lowercased() == host })
                else { continue }
                guard let categories = ask.categories else {
                    for list in source.lists where ListSubscription.isPathSegment(list.id) {
                        wants.insert(FrontWant(host: host, stream: .list(id: list.id), tag: nil))
                    }
                    continue
                }
                for category in categories {
                    switch category {
                    case .list(let id) where ListSubscription.isPathSegment(id):
                        wants.insert(FrontWant(host: host, stream: .list(id: id), tag: nil))
                    case .public:
                        wants.insert(FrontWant(host: host, stream: .federated, tag: nil))
                    default: break
                    }
                }
            }
        }
        if let ask = session.reload.tagAsk {
            for raw in ask.reach.asked {
                let host = raw.lowercased()
                guard mayHearFront(host, in: session) else { continue }
                wants.insert(FrontWant(host: host, stream: .hashtag(ask.tag), tag: ask.tag))
            }
        }
        return wants.subtracting(frontRefused).sorted()
    }

    /// Whether `host` may be heard for what is in front: the person chose its line, it is signed
    /// in, a Mastodon, and its line was not refused this run.
    private func mayHearFront(_ host: String, in session: ShellSession) -> Bool {
        guard chosen.contains(host),
              session.sources.contains(where: { $0.host.lowercased() == host && $0.kind == .mastodon }),
              session.mastodon.isSignedIn(host: host)
        else { return false }
        if case .refused? = standing[host] { return false }
        return true
    }

    /// Holds each of `wants` until cancelled — when what is in front changes, or the window goes to
    /// the background — and lets every one go then.
    func hearFront(_ wants: [FrontWant], in session: ShellSession) async {
        await holdEach(wants) { await self.keepFront($0, in: session) }
    }

    /// One stream for what is in front, heard, and heard again after a drop, until cancelled or
    /// refused. **It has no standing of its own**: the place on the source's page speaks of the
    /// reader's own line, and reading goes on beside this as it does without it.
    private func keepFront(_ want: FrontWant, in session: ShellSession) async {
        var wait = Self.firstWait
        while !Task.isCancelled {
            let opened = now()
            switch await onceFront(want, in: session) {
            case .over: return
            case .refused:
                frontRefused.insert(want)
                return
            case .dropped:
                guard !Task.isCancelled, await waitAfterDrop(&wait, opened: opened) else { return }
            }
        }
    }

    private enum FrontEnd {
        case dropped, refused, over
    }

    /// One hearing of `want`: the stream opened, what was missed read up to now, then each burst of
    /// posts landed as a read of it lands them.
    private func onceFront(_ want: FrontWant, in session: ShellSession) async -> FrontEnd {
        let host = want.host
        guard let token = session.mastodon.token(host: host),
              let source = session.sources.first(where: { $0.host.lowercased() == host })
        else { return .over }
        let category = want.stream.category
        let name = category.flatMap { ShellReload.names(of: source)($0) } ?? want.tag.map { .called($0.text) }
        let events: AsyncThrowingStream<LineEvent, any Error>
        let end: () -> Void
        do {
            guard let heard = try await heard(want.stream, host: host, token: token, name: name, in: session) else { return .over }
            (events, end) = heard
        } catch let refused as MastodonLineRefused where (400..<500).contains(refused.status) {
            return .refused
        } catch {
            return .dropped
        }
        defer { end() }
        if let category {
            let door = session.mastodon.authorized(token: token, for: .timeline, name: name)
            do {
                guard try await MastodonAccount(door: door, store: session.store).catchUp(category) else { return .dropped }
            } catch MastodonAuthError.signedOut {
                session.mastodon.endedByServer(host: host)
                return .over
            } catch {
                return .dropped
            }
            guard !Task.isCancelled else { return .dropped }
            await session.reloadFromStore()
        }
        do {
            for try await burst in Self.bursts(of: events, gathered: gather) {
                let posts = burst.filter { MastodonLine.homeEvents.contains($0.name) }
                guard !posts.isEmpty else { continue }
                let landed = await MastodonLine.land(posts, of: source, as: category, in: session.store)
                if let tag = want.tag {
                    session.reload.heard(landed.compactMap(\.arrivedKey), under: tag)
                } else {
                    for case .arrived(let key, true) in landed { arrivedAbove(key) }
                }
                await session.reloadFromStore()
            }
        } catch {
            return .dropped
        }
        return .dropped
    }
}

extension MastodonLineLanded {
    /// The post that arrived, where one did.
    var arrivedKey: NoteKey? {
        if case .arrived(let key, _) = self { return key }
        return nil
    }
}
