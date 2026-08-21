import SwiftUI

/// The first thing you see: the octopus, turning, and nothing else. It hands over on its
/// own once the turn finishes, and to a click before that for anyone who has seen it.
struct LandingView: View {
    @Environment(AppState.self) private var app
    @Environment(\.colorScheme) private var colorScheme

    @State private var spin: Double = 0
    @State private var settled = false

    private let turns: Double = 2
    private let duration: Double = 1.6

    var body: some View {
        ZStack {
            Palette.surface(colorScheme).ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                MascotView(side: 190)
                    .rotation3DEffect(.degrees(spin), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
                    .scaleEffect(settled ? 1.0 : 0.86)
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.6 : 0.2), radius: 30, y: 12)

                VStack(spacing: 10) {
                    Text(verbatim: "Fediqo")
                        .fediqoFont(34, weight: .semibold, design: .rounded)
                    Text(t("landing.tagline"))
                        .fediqoFont(15)
                        .foregroundStyle(.secondary)
                }
                .opacity(settled ? 1 : 0)

                Spacer()

                Button(action: advance) {
                    Text(t(settled ? "landing.enter" : "landing.skip"))
                        .fediqoFont(13, weight: .medium)
                        .frame(minWidth: 96)
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)
                .padding(.bottom, 36)
            }
            .padding(40)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: advance)
        .task { await run() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(t("landing.tagline")))
    }

    private func run() async {
        withAnimation(.easeInOut(duration: duration)) {
            spin = 360 * turns
        }
        withAnimation(.spring(duration: 0.8).delay(duration * 0.55)) {
            settled = true
        }
        guard !app.holdsLanding else { return }
        try? await Task.sleep(for: .seconds(duration + 0.6))
        advance()
    }

    private func advance() {
        guard app.route == .landing else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            app.leaveLanding()
        }
    }
}

/// The mascot. The corner radius is the one the drawing itself uses — 232 of 1024 — so the
/// plate keeps its shape at 28 pt in the rail and at 190 pt on the landing screen.
struct MascotView: View {
    let side: CGFloat

    var body: some View {
        Image("Mascot", bundle: .module)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: side * 232 / 1024, style: .continuous))
    }
}
