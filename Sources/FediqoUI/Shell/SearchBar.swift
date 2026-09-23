import SwiftUI
#if os(macOS)
import AppKit
#endif

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
    /// Which sources the last Return asked, and which it could not (#176), or nothing before one.
    var reach: String? = nil
    /// Return: the keys go back to the list, on its first result. Called once the pattern has
    /// been settled to what the field says, so the first result is one for the whole pattern.
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
            // Where the results came from, under the field it answers: this device, and the
            // sources named here. Wraps rather than truncates, since the names are the point.
            if let reach {
                Text(reach)
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, ShellSpace.pad)
                    .padding(.trailing, floatingCorner.width)
                    .padding(.bottom, ShellSpace.snug)
            }
        }
        .background(ShellChrome.page(colorScheme))
        .onAppear { focused = true }
        .onChange(of: search.focusTick) { _, _ in focused = true }
        // The field takes the keys when the reader asks for them, and not when AppKit hands them
        // back by itself on the Return that let them go (#168). See `ShellSearch.letGo`.
        .onChange(of: focused) { _, on in
            if !search.fieldFocus(on, during: Self.press) { letGoOfTheKeys() }
        }
        // Return pressed before the index landed found nothing yet to light; its first result
        // is lit once it does, unless `/` has handed the field the keys again since.
        .onChange(of: search.isIndexed) { _, _ in
            if search.takeLitWhenIndexed() { onSubmit() }
        }
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
                // What the field says is searched now, and the keys are the list's before the
                // focus has finished moving (#163).
                search.submit()
                #if os(macOS)
                search.letGo(during: Self.press)
                #endif
                letGoOfTheKeys()
                onSubmit()
            }
            .accessibilityLabel(String(format: L10n.t("search.label"), timeline))
    }

    /// The field gives the keys up: the focus, and on a Mac first responder too.
    ///
    /// **First responder a turn later, not now** (#168). Setting the focus to false is a request
    /// AppKit may not act on at once, and a field editor left first responder takes every letter
    /// the shell does not map. Resigning it from inside Return's own action is undone as soon as
    /// the action returns — AppKit then selects the field's text again — so it is done once the
    /// press is over. The window itself takes it, as it does when nothing is focused; the
    /// shell's keys are read by a monitor ahead of any responder, so they need nothing more.
    private func letGoOfTheKeys() {
        focused = false
        #if os(macOS)
        Task { @MainActor in
            guard !search.fieldFocused else { return }
            NSApp?.keyWindow?.makeFirstResponder(nil)
        }
        #endif
    }

    /// The press being answered now, as far as telling it from the next one goes: its kind and
    /// when it happened. Nothing on iOS, whose field lets go when it is told to.
    private static var press: AnyHashable? {
        #if os(macOS)
        guard let event = NSApp?.currentEvent else { return nil }
        return AnyHashable(Press(kind: event.type.rawValue, at: event.timestamp))
        #else
        return nil
        #endif
    }

    private struct Press: Hashable {
        let kind: UInt
        let at: TimeInterval
    }
}
