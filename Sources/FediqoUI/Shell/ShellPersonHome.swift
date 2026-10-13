import FediqoCore
import Foundation
import Observation

// The server somebody lives on, asked what it says of them (#310): the one press on their page
// that makes this device itself reach a host nobody added.
//
// **Asked at the press, once, and by nothing else.** Opening a page, asking it again, reading
// on, the wait and a picture coming into view ask that server nothing: only `ask` does, and it
// makes one request — of who they are, and no more. No posts, no lists, no reading on, no
// second try: every further ask is a further press.
//
// **The press is what lets the request leave.** That server is nobody's source, so the gate
// lets a request to it through only by an entry of `Allowance` that applies at a press
// (`SourceWork.press`), and that press is spent by the one request and ended on every way out.
// The run's record lists the ask under the server asked, naming the entry.
//
// **With no sign-in, always** (`SourceReach.personHome`): whoever is signed in to the source
// the page is of, nothing of theirs goes to another server.
//
// **Only to a name a press may reach** (`Allowance.homeServer`), and only where the page says
// they live elsewhere or its source has not heard of them. For anybody else — and on a page
// handed nothing, which is every forum's — no press is drawn.
//
// **Held while the page it was asked on is in front, and nowhere else.** One answer at a
// time, in memory: let go at the way back, when that page leaves, and when another is asked.
// Nothing of it is written, no post comes from it, and no picture it names is fetched.
//
// **An answer lands only where it is still the one awaited**, as every page's does: the ask is
// numbered, and what it brings is written only where that number still stands and the source
// the page is of is still here. Late — after the way back, another press, the page left or
// its source removed — it lands nowhere.

@MainActor
@Observable
final class ShellPersonHome {
    /// Where the one ask stands.
    enum Standing: Equatable {
        case asking
        case said(Person, at: Date)
        /// The server answered, and not with them.
        case noAccount
        /// The server is a Mastodon, and knows nobody of that name.
        case nobody
        /// The server was not read.
        case unread
    }

    private struct Asked {
        /// The page it was asked on.
        let page: String
        /// The source that page is of.
        let source: String
        let address: PersonAddress
        var standing: Standing = .asking
        let awaits: Int
    }

    private var asked: Asked?
    /// The ask on the wire.
    @ObservationIgnored private var asking: Task<Void, Never>?
    @ObservationIgnored private let errands: PageErrands
    /// How long the ask may take. A test shortens it.
    @ObservationIgnored var deadline: Duration = .seconds(30)
    /// Another way to that server, where a test reaches it by one — a wire that goes on
    /// answering an ask that was called off, as a transfer already ended does. Nothing in the app.
    @ObservationIgnored var reaching: ((String) -> MastodonPersonHome)?

    init(errands: PageErrands) {
        self.errands = errands
    }

    // MARK: - Who a press would ask

    /// Whom a press on the page of `who` would ask for, and so of which server — or nothing,
    /// and then there is no press: the page was handed nothing, its source has not answered or
    /// failed, their handle names that very source, or the server it names is no name a press
    /// may reach.
    ///
    /// **By the handle the source gave** once it has said who they are, and by the one the
    /// page was opened by where it has not heard of them.
    static func target(of who: DummyPerson, said: PersonSaid?) -> PersonAddress? {
        guard let said else { return nil }
        let handle: String?
        switch said.reading {
        case .said(let person): handle = person.handle
        case .unheardOf: handle = who.handle
        case .asking, .failed: handle = nil
        }
        guard let address = handle.flatMap(PersonAddress.init(typed:)), case .handle = address,
              address.host != said.source, Allowance.homeServer(address.host) != nil
        else { return nil }
        return address
    }

    /// The ask as it stands for the page of `who` as that page is now, or nothing.
    private func standing(of who: DummyPerson, said: PersonSaid?) -> (address: PersonAddress, standing: Standing?)? {
        guard let address = Self.target(of: who, said: said), let source = said?.source else { return nil }
        guard let asked, asked.page == who.id, asked.source == source, asked.address == address else { return (address, nil) }
        return (address, asked.standing)
    }

    // MARK: - What the page is handed

    /// What their own server said of them, where the press on this very page brought it and
    /// nobody has gone back since — and nothing where the person switched the entry that let
    /// the ask through off: the source's view is drawn, as the way back would leave it.
    func said(of who: DummyPerson, beside said: PersonSaid?, in session: ShellSession) -> PersonHomeSaid? {
        guard session.work.allows(.personHome), let stands = standing(of: who, said: said),
              case .said(let person, let at) = stands.standing
        else { return nil }
        return PersonHomeSaid(home: stands.address.host, person: person, at: at)
    }

    /// The line about asking their own server: the press, where the ask stands, what it came
    /// to, or the way back — or nothing where there is nobody to ask, and where the person
    /// switched the entry that lets the ask through off.
    func line(
        of who: DummyPerson, beside said: PersonSaid?, in session: ShellSession, language: DummyLanguage? = nil
    ) -> PersonHomeLine? {
        guard let stands = standing(of: who, said: said), let source = said?.source, session.work.allows(.personHome) else {
            return nil
        }
        let home = stands.address.host
        let ask = String(format: L10n.t("person.home.ask", language: language), home)
        switch stands.standing {
        case nil:
            return PersonHomeLine(press: .ask, pressWords: ask)
        case .asking:
            return PersonHomeLine(words: String(format: L10n.t("person.home.asking", language: language), home))
        case .said:
            // Their posts are still the source's, where it has said who they are: what it gave
            // for the page, and until then what this device holds of theirs, which was read
            // through that same source. One that has not heard of them gave none to speak of.
            let posts = said?.person.map { _ in String(format: L10n.t("person.home.posts", language: language), source) }
            return PersonHomeLine(
                words: posts, press: .back, pressWords: String(format: L10n.t("person.home.back", language: language), source)
            )
        case .nobody:
            return PersonHomeLine(
                words: String(format: L10n.t("person.home.nobody", language: language), home, source),
                press: .ask, pressWords: ask, failed: true
            )
        case .noAccount:
            return PersonHomeLine(
                words: String(format: L10n.t("person.home.noAccount", language: language), home, source),
                press: .ask, pressWords: ask, failed: true
            )
        case .unread:
            return PersonHomeLine(
                words: String(format: L10n.t("person.home.unread", language: language), home, source),
                press: .ask, pressWords: ask, failed: true
            )
        }
    }

    /// Where the ask for the page of `who` stands, for a test.
    func stands(for who: DummyPerson) -> Standing? {
        asked?.page == who.id ? asked?.standing : nil
    }

    // MARK: - The press, and the way back

    /// The press: the server `who` lives on asked what it says of them — one request, with no
    /// sign-in. **A press while that very ask is out asks nothing**; a press on another page
    /// calls the one out off and lets its answer go. Nothing is asked where the page offers no
    /// press (`line`).
    func ask(_ who: DummyPerson, beside said: PersonSaid?, in session: ShellSession) async {
        guard let address = Self.target(of: who, said: said), let source = said?.source,
              ShellPersonPages.source(of: who, in: session)?.host == source, session.work.allows(.personHome)
        else { return }
        if let asked, asked.page == who.id, asked.source == source, asked.address == address, asked.standing == .asking {
            await asking?.value
            return
        }
        asking?.cancel()
        let errand = errands.next()
        asked = Asked(page: who.id, source: source, address: address, awaits: errand)
        let home = address.host, work = session.work
        // The press the gate lets the one request through by: spent by it, and ended here on
        // every way out, so one that never left lets nothing through later.
        let press = work.press(for: home)
        let through = reaching?(home) ?? session.reach.personHome(home, within: deadline)
        let task = Task {
            defer { work.end(press) }
            await self.answer(address, of: through, for: who, at: source, errand: errand, in: session)
        }
        asking = task
        await task.value
    }

    private func answer(
        _ address: PersonAddress, of through: MastodonPersonHome, for who: DummyPerson, at source: String, errand: Int,
        in session: ShellSession
    ) async {
        defer { if asked?.awaits == errand { asking = nil } }
        let standing: Standing
        do {
            standing = .said(try await through.person(address), at: Date())
        } catch {
            guard asked?.awaits == errand else { return }
            if Cancellation.happened(error) {
                // Called off before it answered: nothing is left asking with nothing on the wire.
                asked = nil
                return
            }
            switch error as? PersonHomeError {
            case .nobody: standing = .nobody
            case .noAccount: standing = .noAccount
            default: standing = .unread
            }
        }
        guard asked?.awaits == errand else { return }
        // The source the page is of was removed while the ask was out, or the entry that let it
        // through switched off: nowhere is left to say it.
        guard ShellPersonPages.source(of: who, in: session)?.host == source, session.work.allows(.personHome) else {
            asked = nil
            return
        }
        asked?.standing = standing
    }

    /// The way back to what the source says, and the page of `who` leaving: what their own
    /// server said goes, an ask still out is called off, and what it brings lands nowhere.
    func letGo(of who: DummyPerson) {
        guard asked?.page == who.id else { return }
        asking?.cancel()
        asking = nil
        asked = nil
    }
}
