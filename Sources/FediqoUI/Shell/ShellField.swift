import SwiftUI

/// Where a text field stands, which is the whole of how it is framed.
///
/// **One rule: a field draws its own border unless something drawn around it already is one.**
/// Ten fields chose between `.roundedBorder` and `.plain` each for itself, and the choice read
/// as taste. It was this rule all along, unstated — so it is stated, and a field says where it
/// stands rather than which style it likes.
enum ShellFieldPlace: Equatable, Sendable {
    /// Alone on a sheet or a page, with nothing around it: the field draws its own rounded
    /// border. A sheet's name and password, the rule editor's keyword, a code typed in.
    case alone
    /// Inside something that already frames it — a Form's cell, the search bar under its rule,
    /// the hostname box: the field is plain, and the frame is the surface's.
    case framed

    /// Whether the field draws a border of its own.
    var bordered: Bool { self == .alone }
}

extension View {
    /// The style of a text field standing at `place`. See `ShellFieldPlace`.
    func shellField(_ place: ShellFieldPlace) -> some View {
        modifier(ShellFieldStyle(place: place))
    }
}

private struct ShellFieldStyle: ViewModifier {
    let place: ShellFieldPlace

    @ViewBuilder
    func body(content: Content) -> some View {
        if place.bordered {
            content.textFieldStyle(.roundedBorder)
        } else {
            content.textFieldStyle(.plain)
        }
    }
}

/// The field a hostname is typed into, and the press beside it that takes what was typed.
///
/// Two pages ask for a hostname — Account, to find a source, and Your hosts, to let one in — and
/// each had built its own: one ended in a glyph, the other in the word "Add", and only one said
/// it was a web address to the keyboard in the same breath as the other. **One field: no
/// capitals, no correction, the address keyboard on a phone, Return takes it; and the press is a
/// glyph**, named for VoiceOver and a pointer by whoever supplies it, since what the press does
/// (look it up, add it) is the page's own. A glyph and not a word because the field's prompt
/// already says what is typed, and a word beside it is cut first on a narrow phone.
///
/// **It draws no box.** It is `framed` by what it stands in: a Form's cell on Your hosts, the
/// hairline box Account draws round it on a bare page.
struct ShellHostField<Press: View>: View {
    let prompt: String
    @Binding var text: String
    let focus: FocusState<Bool>.Binding
    let onSubmit: () -> Void
    let press: Press

    init(
        _ prompt: String, text: Binding<String>, focus: FocusState<Bool>.Binding, onSubmit: @escaping () -> Void,
        @ViewBuilder press: () -> Press
    ) {
        self.prompt = prompt
        _text = text
        self.focus = focus
        self.onSubmit = onSubmit
        self.press = press()
    }

    var body: some View {
        HStack(alignment: .center, spacing: ShellSpace.snug) {
            TextField(prompt, text: $text)
                .shellFont(.body)
                .shellField(.framed)
                .focused(focus)
                .onSubmit(onSubmit)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .autocorrectionDisabled()
                .accessibilityLabel(prompt)
            press
        }
    }
}
