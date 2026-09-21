import SwiftUI

/// Covered, said as a machined mark rather than a sentence: the diagonal hatch a guard plate
/// carries. It needs no colour and no words, so a covered post is told apart from an open one
/// before anything on it is read — and no sentence is put in the author's mouth where they
/// wrote none.

/// Lines at 45°, `spacing` apart, filling whatever rectangle it is given. Stroke it and clip it
/// to the shape it decorates.
struct Hatch: Shape {
    var spacing: CGFloat = ShellSpace.tight + ShellSpace.hair

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var offset = -rect.height
        while offset < rect.width {
            path.move(to: CGPoint(x: rect.minX + offset, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + offset + rect.height, y: rect.minY))
            offset += spacing
        }
        return path
    }
}

/// The mark that leads a covered post's notice band. Covered, it is a hatched plate; lifted, the
/// same glyph in an open outline — the lid is off, and the mark still says there was one.
///
/// Hidden from VoiceOver: what it means is said in the band's own label.
struct CoverChip: View {
    let lifted: Bool
    /// Drawn over a picture, where the ground is a stranger's photograph rather than the chassis.
    var onPicture = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(systemName: "eye.slash")
            .shellFont(.mark, weight: .medium)
            .foregroundStyle(onPicture ? ShellChrome.overPicture : ShellChrome.inkDim(colorScheme))
            .padding(.horizontal, ShellSpace.tight)
            .padding(.vertical, ShellSpace.hair * 2)
            .background { plate }
            .help(L10n.t(lifted ? "item.lifted.mark" : "item.covered.mark"))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var plate: some View {
        let capsule = Capsule(style: .continuous)
        if lifted {
            capsule.strokeBorder(
                onPicture ? ShellChrome.hatchOverPicture : ShellChrome.hairline(colorScheme),
                lineWidth: ShellSpace.hair
            )
        } else {
            capsule
                .fill(onPicture ? ShellChrome.scrim : ShellChrome.well(colorScheme))
                .overlay {
                    Hatch()
                        .stroke(onPicture ? ShellChrome.hatchOverPicture : ShellChrome.hatch(colorScheme),
                                lineWidth: ShellSpace.hair)
                        .clipShape(capsule)
                }
        }
    }
}
