import FediqoCore
import SwiftUI

/// On a joined source's page: the years it looked back on for the person (#340), a row each,
/// opening the year whole. Draws what `ShellYears.offer` hands it and decides nothing: nothing at
/// all where the source keeps no year, dim with the reading part's sentence or the sign-in's where
/// the sign-in held cannot read it, whose press asks.
struct YearBlock: View {
    let host: String
    let session: ShellSession
    @Environment(\.colorScheme) private var colorScheme
    @State private var opened: YearLookedBack?

    var body: some View {
        Group {
            switch session.years.offer(host: host, in: session) {
            case .locked(let sentence)?, .signIn(let sentence)?:
                Button(sentence) { session.years.press(host: host, in: session) }
                    .buttonStyle(.plain)
                    .shellFont(.reading)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(sentence)
                    .padding(.horizontal, ShellSpace.pad)
                    .padding(.bottom, ShellSpace.step)
            case .years(.read(let years)?)?:
                ForEach(years) { year in
                    let title = ShellYears.title(year)
                    Button { opened = year } label: {
                        HStack(alignment: .firstTextBaseline, spacing: ShellSpace.tight) {
                            Image(systemName: "calendar").accessibilityHidden(true)
                            Text(title).fixedSize(horizontal: false, vertical: true)
                            Image(systemName: "chevron.right").shellFont(.mark).accessibilityHidden(true)
                        }
                        .shellFont(.reading)
                        .foregroundStyle(ShellChrome.ink(colorScheme))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(title)
                    .padding(.horizontal, ShellSpace.pad)
                    .padding(.bottom, ShellSpace.step)
                }
            case .years(.failed(let why)?)?:
                Text(why)
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .padding(.horizontal, ShellSpace.pad)
                    .padding(.bottom, ShellSpace.step)
            case .years(.reading?)?, .years(nil)?, nil:
                EmptyView()
            }
        }
        .task(id: host) { await session.years.read(host: host, in: session) }
        .sheet(item: $opened) { year in YearSheet(year: year) }
    }
}

/// One year looked back on, whole: the kind of poster, each month, the hashtags, the posts it
/// names, and where the source shows it.
struct YearSheet: View {
    let year: YearLookedBack
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            List {
                if let archetype = ShellYears.archetype(year) {
                    Section { Text(archetype).shellFont(.reading) }
                }
                if !year.months.isEmpty {
                    Section(L10n.t("year.months")) {
                        ForEach(year.months, id: \.month) { Text(ShellYears.month($0)).shellFont(.reading) }
                    }
                }
                if !year.tags.isEmpty {
                    Section(L10n.t("year.tags")) {
                        ForEach(year.tags, id: \.name) { Text(ShellYears.tag($0)).shellFont(.reading) }
                    }
                }
                let posts = ShellYears.posts(year)
                if !posts.isEmpty {
                    Section(L10n.t("year.posts")) {
                        ForEach(posts, id: \.title) { post in
                            VStack(alignment: .leading, spacing: ShellSpace.hair) {
                                Text(post.title).shellFont(.meta).foregroundStyle(ShellChrome.inkDim(colorScheme))
                                Text(post.words).shellFont(.reading)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .navigationTitle(ShellYears.title(year))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L10n.t("year.done")) { dismiss() } }
            }
        }
    }
}
