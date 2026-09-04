import SwiftUI
import Observation
import FediqoCore

/// Who has asked to follow this reader and is waiting (#114).
///
/// **The sharpest of #114's lists**, and the reason it is a tab of the Inbox rather than a
/// section of Settings: these rows are not a state the reader is in, they are people waiting on
/// an answer. A locked account could not answer anybody at all.
@MainActor
@Observable
final class RequestsModel {
    /// Who is waiting, per account — a reader signed in to three servers has three sets of
    /// people waiting, and they are not one set.
    private(set) var waiting: [String: [Profile]] = [:]
    private(set) var loading = false
    private(set) var failure: SourceFailure?
    /// Which ones are being answered now, so a row can say so and cannot be pressed twice.
    private(set) var answering: Set<String> = []
    private var hasRead = false

    private let accounts: () async -> [ActingAccount]
    private let client: () -> (any SourceClient)?

    init(accounts: @escaping () async -> [ActingAccount],
         client: @escaping () -> (any SourceClient)?) {
        self.accounts = accounts
        self.client = client
    }

    var hosts: [String] { waiting.keys.sorted() }
    var count: Int { waiting.values.reduce(0) { $0 + $1.count } }

    func readIfNeeded() async {
        guard !hasRead else { return }
        await read()
    }

    func read() async {
        loading = true
        defer { loading = false }
        let asking = await accounts()
        hasRead = !asking.isEmpty
        guard let client = client() else { return }

        var found: [String: [Profile]] = [:]
        var refused: SourceFailure?
        for account in asking {
            do {
                let people = try await client.followRequests(as: account)
                if !people.isEmpty { found[account.host] = people }
            } catch {
                refused = refused ?? SourceFailure.of(error)
            }
        }
        waiting = found
        failure = refused
    }

    /// Say yes or no. **Nothing moves before the server answers** — this changes another
    /// person's situation, and a row that showed the answer before it landed would be
    /// announcing something nobody had done.
    func answer(_ who: Profile, accept: Bool, on host: String) async {
        guard !answering.contains(who.authorId),
              let client = client(),
              let account = await accounts().first(where: { $0.host == host })
        else { return }
        answering.insert(who.authorId)
        defer { answering.remove(who.authorId) }
        do {
            try await client.answerFollowRequest(who, accept: accept, as: account)
            await read()
        } catch {
            failure = SourceFailure.of(error)
        }
    }
}

/// The tab.
struct RequestsList: View {
    @Environment(AppState.self) private var app

    private var model: RequestsModel { app.requests }

    var body: some View {
        body(for: model.hosts)
            .task(id: app.yourAccounts) { await model.readIfNeeded() }
    }

    @ViewBuilder
    private func body(for hosts: [String]) -> some View {
        if hosts.isEmpty {
            VStack(spacing: Space.mid) {
                Image(systemName: "person.badge.clock")
                    .fediqoSymbol(Glyph.big, weight: .light)
                    .foregroundStyle(.tertiary)
                Text(t("requests.none"))
                    .fediqoFont(TypeScale.small)
                    .foregroundStyle(.secondary)
            }
            .padding(Space.room)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.gap) {
                    ForEach(hosts, id: \.self) { host in
                        ForEach(model.waiting[host] ?? [], id: \.authorId) { who in
                            row(who, on: host)
                        }
                    }
                }
                .padding(Space.gap)
            }
        }
    }

    private func row(_ who: Profile, on host: String) -> some View {
        HStack(spacing: Space.gap) {
            PersonLine(person: who, host: host)
            // **Two answers and no third**, said as two words rather than a tick and a cross:
            // this is the only thing in the app that changes somebody else's situation, and it
            // cannot be taken back.
            Button(t("requests.reject")) {
                Task { await model.answer(who, accept: false, on: host) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fediqoFont(TypeScale.minor)
            Button(t("requests.accept")) {
                Task { await model.answer(who, accept: true, on: host) }
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.accent)
            .controlSize(.small)
            .fediqoFont(TypeScale.minor)
        }
        .disabled(model.answering.contains(who.authorId))
        .padding(Space.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fediqoCard()
    }
}
