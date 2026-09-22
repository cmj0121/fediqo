import SwiftUI

/// The line `/` opens along the foot of the timeline, the way a pager's search line does.
///
/// The `/` is the lamp: phosphor while the field has the keys, dim once Return has handed them
/// back to the list. The pattern is set in the keycap face, so a `?` and a `*` are easy to count.
struct SearchBar: View {
    @Bindable var search: ShellSearch
    /// The name of the timeline being searched (#145), in the field and in what VoiceOver reads,
    /// so a reader who switched timeline with the search open can see which one it now asks.
    var timeline: String
    /// How many posts are found, or nothing while no pattern is being searched.
    var found: Int?
    /// Return: the keys go back to the list, on its first result.
    var onSubmit: () -> Void
    /// The field emptied: the timeline is back, with the selection it had.
    var onCleared: () -> Void
    /// Escape: the search closes and the timeline comes back as it was.
    var onClose: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.shellFloatingCorner) private var floatingCorner

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(ShellChrome.hairline(colorScheme))
                .frame(height: ShellSpace.hair)
            HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
                Text(verbatim: "/")
                    .shellFont(.keycap, weight: .semibold)
                    .foregroundStyle(focused ? ShellChrome.phosphor(colorScheme) : ShellChrome.inkDim(colorScheme))
                    .accessibilityHidden(true)
                // Which timeline is searched, still there once the placeholder has gone under
                // what was typed. Read by VoiceOver as part of the field's own label instead.
                Text(timeline)
                    .shellFont(.meta, weight: .semibold)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .lineLimit(1)
                    // At its own width, as the tab it names is drawn.
                    .fixedSize()
                    .accessibilityHidden(true)
                field
                if let found {
                    Text(String(format: L10n.t("search.found"), found))
                        .shellFont(.meta)
                        .monospacedDigit()
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, ShellSpace.pad)
            // The end of the field and the count stop short of whatever floats over the page's
            // corner — the narrow arrangement's compose button (#112). Nothing, elsewhere.
            .padding(.trailing, floatingCorner.width)
            .padding(.vertical, ShellSpace.snug)
        }
        .background(ShellChrome.page(colorScheme))
        .onAppear { focused = true }
        .onChange(of: search.focusTick) { _, _ in focused = true }
        .onChange(of: focused) { _, on in search.fieldFocused = on }
        .onDisappear { search.fieldFocused = false }
        .onChange(of: search.text) { old, new in
            if new.isEmpty, !old.isEmpty { onCleared() }
        }
        .task(id: search.text) {
            let typed = search.text
            try? await Task.sleep(for: ShellSearch.pause)
            guard !Task.isCancelled else { return }
            search.settle(typed)
        }
    }

    private var field: some View {
        TextField(String(format: L10n.t("search.placeholder"), timeline), text: $search.text)
            .shellFont(.keycap)
            .textFieldStyle(.plain)
            .foregroundStyle(ShellChrome.ink(colorScheme))
            .focused($focused)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .onKeyPress(.escape) {
                onClose()
                return .handled
            }
            #else
            .onExitCommand { onClose() }
            #endif
            .onSubmit {
                focused = false
                onSubmit()
            }
            .accessibilityLabel(String(format: L10n.t("search.label"), timeline))
    }
}
