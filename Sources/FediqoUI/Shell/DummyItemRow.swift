import SwiftUI

/// One dummy item: decorator, header, two-column words and thumb, local actions.
struct DummyItemRow: View {
    let item: DummyItem
    @Binding var marks: DummyMarks
    var onToast: (String) -> Void
    @Environment(\.colorScheme) private var colorScheme

    private enum Box {
        static let avatar: CGFloat = 36
        static let thumb: CGFloat = 96
        static let vis: CGFloat = 16
        static let source: CGFloat = 108
        static let time: CGFloat = 88
        static let glyph: CGFloat = 20
        static let count: CGFloat = 22
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            decorator
            header
            mainBox
            actions
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var decorator: some View {
        if item.answering != .nothing || item.boostedBy != nil {
            HStack(spacing: 6) {
                if item.answering != .nothing { answered }
                if item.answering != .nothing, item.boostedBy != nil {
                    Text(verbatim: "·")
                }
                if let who = item.boostedBy { boosted(by: who) }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
    }

    private var answered: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrowshape.turn.up.left")
            switch item.answering {
            case .handle(let handle):
                Text(String(format: L10n.t("item.replyingTo"), handle))
            default:
                Text(L10n.t("item.isReply"))
            }
        }
    }

    private func boosted(by who: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.2.squarepath")
            Text(String(format: L10n.t("item.boostedBy"), who))
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            avatar
            Text(item.author)
                .font(.body.weight(.semibold))
                .lineLimit(1)
            if let handle = item.handle {
                Text(handle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            trailingMeta
        }
    }

    private var avatar: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(ShellChrome.well(colorScheme))
            if item.hasAvatar {
                Image(systemName: "person.fill")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: Box.avatar, height: Box.avatar)
    }

    private var trailingMeta: some View {
        HStack(spacing: 6) {
            sourcePills
            visibility
            postedAgo
        }
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
    }

    private var postedAgo: some View {
        Text(item.postedAt, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
            .font(.caption)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: Box.time, alignment: .trailing)
            .help(exactPostedAt)
            .accessibilityLabel(exactPostedAt)
    }

    private var exactPostedAt: String {
        item.postedAt.formatted(.dateTime.year().month().day().hour().minute().second())
    }

    private var visibility: some View {
        Group {
            if let audience = item.audience {
                Image(systemName: audience.symbolName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(ShellChrome.vis(audience, colorScheme))
                    .help(L10n.t("item.visibility.\(audience.rawValue)"))
                    .accessibilityLabel(L10n.t("item.visibility.\(audience.rawValue)"))
            }
        }
        .frame(width: Box.vis, height: Box.vis)
    }

    private var sourcePills: some View {
        let hosts = item.shownHosts
        return HStack(spacing: 4) {
            if let first = hosts.first {
                pill(first)
            }
            if hosts.count > 1 {
                pill("+\(hosts.count - 1)")
                    .accessibilityLabel(L10n.t("item.sources"))
                    .help(hosts.joined(separator: "\n"))
            }
        }
        .frame(width: Box.source, alignment: .trailing)
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(ShellChrome.well(colorScheme))
            )
    }

    private var mainBox: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                words
                thumb
            }
            VStack(alignment: .leading, spacing: 8) {
                words
                if item.hasThumb { thumb }
            }
        }
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 4) {
            if item.source.kind == .board, let board = item.board {
                Text(board)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let title = item.title {
                Text(title)
                    .font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(item.body)
                .font(.body)
                .foregroundStyle(item.title == nil ? Color.primary : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var thumb: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(ShellChrome.well(colorScheme))
            if item.hasThumb {
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: Box.thumb, height: Box.thumb)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                counted("arrowshape.turn.up.left", count: item.counts.replies,
                        label: "item.act.reply", on: false, tint: .secondary) {
                    onToast(L10n.t("item.toast.reply"))
                }
                counted("arrow.2.squarepath", count: item.counts.reblogs,
                        label: "item.act.reblog", on: false, tint: ShellChrome.reblog(colorScheme)) {
                    onToast(L10n.t("item.toast.reblog"))
                }
                counted(marks.favourited ? "star.fill" : "star",
                        count: item.counts.favourites,
                        label: "item.act.favourite", on: marks.favourited,
                        tint: ShellChrome.favourite(colorScheme)) {
                    marks.favourited.toggle()
                    onToast(L10n.t(marks.favourited ? "item.toast.favourite.on" : "item.toast.favourite.off"))
                }
            }
            HStack(spacing: 4) {
                mark(marks.bookmarked ? "bookmark.fill" : "bookmark",
                     label: "item.act.bookmark", on: marks.bookmarked,
                     tint: ShellChrome.bookmark(colorScheme)) {
                    marks.bookmarked.toggle()
                    onToast(L10n.t(marks.bookmarked ? "item.toast.bookmark.on" : "item.toast.bookmark.off"))
                }
                mark(marks.kept ? "archivebox.fill" : "archivebox",
                     label: "item.act.kept", on: marks.kept, tint: ShellChrome.phosphor(colorScheme)) {
                    marks.kept.toggle()
                    onToast(L10n.t(marks.kept ? "item.toast.kept.on" : "item.toast.kept.off"))
                }
            }
            mark("ellipsis", label: "item.act.more", on: false, tint: .secondary) {
                onToast(L10n.t("item.toast.more"))
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private func counted(_ symbol: String, count: Int?, label: String, on: Bool, tint: Color,
                         action: @escaping () -> Void) -> some View {
        DummyMarkButton(symbol: symbol, count: count, counting: true, labelKey: label,
                        on: on, tint: tint, glyph: Box.glyph, countWidth: Box.count, action: action)
    }

    private func mark(_ symbol: String, label: String, on: Bool, tint: Color,
                      action: @escaping () -> Void) -> some View {
        DummyMarkButton(symbol: symbol, count: nil, counting: false, labelKey: label,
                        on: on, tint: tint, glyph: Box.glyph, countWidth: Box.count, action: action)
    }
}

private struct DummyMarkButton: View {
    let symbol: String
    let count: Int?
    let counting: Bool
    let labelKey: String
    let on: Bool
    let tint: Color
    let glyph: CGFloat
    let countWidth: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: glyph, weight: .medium))
                    .frame(width: glyph, height: glyph)
                if counting {
                    Text(count.map(String.init) ?? "")
                        .font(.caption2)
                        .monospacedDigit()
                        .frame(minWidth: countWidth, alignment: .leading)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(on ? tint : Color.secondary)
        .help(L10n.t(labelKey))
        .accessibilityLabel(L10n.t(labelKey))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
