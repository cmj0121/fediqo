import SwiftUI
import FediqoCore

/// One person, in a list of them.
///
/// **Extracted rather than copied (#126).** A page about a post has two lists of people on it —
/// who favourited it and who boosted it — and they are the same rows a list of followers is. A
/// second design for a name, a handle and a face would drift from this one the first time either
/// changed.
///
/// The name is drawn with `EmojiText`'s plain init: a name can be written partly in pictures, and
/// a name is not prose (#119).
struct PersonLine: View {
    let person: Profile
    /// The server this list was found on, which is the server the page about them is asked of —
    /// and a server the reader already reads.
    let host: String

    @Environment(AppState.self) private var app

    var body: some View {
        Button { app.openPerson(person, from: host) } label: {
            HStack(spacing: Space.gap) {
                RemoteImage(url: person.avatarURL, width: Size.avatar, height: Size.avatar,
                            standing: .avatar)
                VStack(alignment: .leading, spacing: Space.hair) {
                    EmojiText(person.name.isEmpty ? person.handle : person.name,
                              emojis: person.emojis, size: TypeScale.body, weight: .semibold)
                        .lineLimit(1)
                    Text(person.handle)
                        .fediqoFont(TypeScale.minor)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: Space.snug)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(person.name.isEmpty ? person.handle : person.name))
        .accessibilityHint(Text(t("person.title")))
    }
}
