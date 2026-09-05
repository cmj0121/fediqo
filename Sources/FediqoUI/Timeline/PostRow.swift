import SwiftUI
import FediqoCore

/// One row, in bands. Each is the whole width and each answers one question:
///
/// ```text
/// what happened to this post before it got here   (only when something did)
/// who wrote it, where it reached us, and when
/// what it says              │ what came attached
/// what can be done about it
/// what it was written with                        (right, and often empty)
/// ```
///
/// The band that says whose post this is stands a little further off than the rest of them —
/// `Space.step` between every pair of bands, and one `Space.tight` more under the metadata.
/// Everything above that line is *about* the post; everything below it is the post.
///
/// **The two columns are only the middle band**, and only where there is room for them: the
/// words on the left, the attachments on the right, in a column that stays there whether or
/// not anything is in it. That empty column is the point — it is what keeps every row's text
/// starting and ending in the same place down a long list. Below `fediqoWideRows` there is
/// nothing to spend on it and the attachments go back under the words.
///
extension Post {
    /// Whether the author covered anything here: a line in front of the words, media behind a
    /// blur, or both. What the key asks before it does anything, and the row asks before it
    /// draws a control for it.
    var hidesSomething: Bool { sensitive == true || !(spoiler ?? "").isEmpty }
}

/// What a row says about this post being an answer to another.
///
/// Three cases and not an optional string, because "we know it answers somebody we cannot
/// name" is a different thing from "it answers nothing" — and a row that quietly said nothing
/// for the first of those would be hiding half a conversation. Which of the three it is
/// belongs to the page: the timeline knows whether a parent is on the screen with it, and the
/// conversation page knows that a direct answer to the post needs no line at all, because the
/// post is what the page already is.
enum Answering: Equatable {
    /// Nothing is said: it answers nothing, or the page is the conversation it answers into.
    case nothing
    /// It answers something nobody has handed us. We can say that much and no more.
    case somebody
    case handle(String)
}

/// Every row is the same height, set by the attachment card: a short post is padded up to it
/// and a long one stops at it with an ellipsis. What the ellipsis is hiding is what opening
/// the post is for.
struct PostRow: View {
    let post: Post
    /// Whether this is the row the reader is on. The row is told rather than asking: which
    /// post the ring is on belongs to the feed, and a row knows nothing but itself.
    var selected = false
    /// Bumped when `m` is pressed while this row is the one the reader is on — the deck turns
    /// itself over, and which one is on top stays the deck's own business.
    var turns = 0
    /// Bumped when `p` is pressed on this row: what is on top of the deck plays, or stops.
    var plays = 0
    /// Bumped when `s` is pressed on this row: what the author covered is lifted, or put back.
    /// The key and the button beside the warning are one control reached two ways, so they
    /// end in the same line and cannot come to disagree about which way the row is going.
    var covers = 0
    /// Whether what this post covered arrives uncovered. The reader's standing answer; a row
    /// can still be opened by hand without changing it.
    var revealed = false
    /// What this row says about the post being an answer. Decided by the page that draws it.
    var answering: Answering = .nothing
    /// Whether this is a row in a list rather than the post itself, opened.
    ///
    /// In a list it is held to the same height as every other row and its words stop with an
    /// ellipsis — which is the row saying there is more, and `Return` is how to get it. The
    /// opened post is where the whole of it lives, so nothing is clamped there.
    var condensed = true
    /// The widest a picture under the words may be drawn. The column the timeline reserves,
    /// unless the page that draws this row is one post rather than a list of them (#120).
    var widest: CGFloat = Size.card
    /// What a click on the row means: this one. Put the ring here.
    ///
    /// Every page passes it, because a click means that on every page — and it is a
    /// `simultaneousGesture` rather than the row's own tap, so it fires wherever in the row the
    /// click landed. Most of a row is selectable words and buttons that want their own presses,
    /// and a reader who clicked one of those has still said which post they mean.
    var focus: (() -> Void)?
    /// Whether the row carries the things that can be done to the post.
    ///
    /// False where the row is being quoted rather than read — the composer draws the post being
    /// answered, and a star and a boost inside a draft are controls that belong to a row
    /// somewhere else. Not hittable is not enough: they would still be six marks and three
    /// numbers asking to be read, above the field somebody is trying to write in.
    ///
    /// **Before `open` for the reason `openAuthor` is**, which the comment below is about.
    var acting = true
    /// What a press on the author's picture and name asks for — their page. Nothing where
    /// there is none to open, which is that page's own rows: they are already theirs.
    ///
    /// **Before `open` and not after it**, which the comment below is about: a call site writes
    /// `open` as a trailing closure, and a parameter declared after it takes that closure
    /// instead. Adding this at the end compiled, and quietly turned every `PostRow { … }` in
    /// the app into a row that opened a person when it was pressed.
    var openAuthor: (() -> Void)?
    /// What a click on the row asks for **beyond** that. `nil` in a preview and in the
    /// conversation page, where opening what you are already looking at means nothing.
    ///
    /// Declared last on purpose: a call site writes it as a trailing closure, and a parameter
    /// added after it would quietly take the closure instead.
    var open: (() -> Void)?
    /// What a press on one of the post's tags asks for — a timeline of it (#107).
    ///
    /// **Declared after `open` and that is safe**, unlike the two above it: this one takes an
    /// argument, so a trailing closure written at a call site cannot be mistaken for it.
    var openTag: ((String) -> Void)?

    @Environment(\.openURL) private var openURL
    @Environment(\.fediqoWideRows) private var wide
    /// The reader's text size, because how many lines fit in a card depends on it.
    @Environment(\.fediqoTextScale) private var scale
    @Environment(\.colorScheme) private var colorScheme

    /// What this reader decided about this post, or nothing where they have not decided.
    ///
    /// `nil` follows the standing preference; a press of the button is an answer of its own and
    /// wins over it **in both directions** — a reader who turned everything on can still put
    /// one post back behind its warning. It lasts as long as the app is open and is never
    /// written down: which posts somebody chose to read is a reading record, and this app
    /// keeps none.
    @State private var reveal: Bool?

    /// How much of a post a row shows before it stops.
    ///
    /// **A measure of its own now, and it had to become one.** It used to be the deck's height
    /// divided by a line, which was exactly right while the row *was* the deck's height: the
    /// words filled the frame and stopped at the bottom of it. The row is as tall as its content
    /// now, so that division has nothing to divide — and following the deck anyway would have
    /// doubled how much of every post is shown the moment #79 doubled the card, which is a
    /// decision about reading that nobody made.
    ///
    /// So the arithmetic is kept and the height it divides is this view's own: `words` is what
    /// `AttachmentDeck.height` was on the day the row stopped being that tall, so **every reader
    /// sees exactly what they saw before** — 9 lines at 0.85×, 7 at 1.0×, 4 at the 1.6× this app
    /// ships at. #79 moves the picture, and how much of a post a reader is given is not #79's to
    /// move.
    ///
    /// The clamp itself is what S6 keeps: a row that grew to hold a long post would be the one
    /// row on the screen that is a different shape from the rest, and the ellipsis is the row
    /// saying there is more. It follows the text scale rather than being a fixed count for the
    /// reason it always did — a count that fits at 13 points overflows at 21. 1.35 is the line
    /// height a `Text` gives itself around its point size; three is the floor, because a row
    /// showing one line of a paragraph is not showing a post at all.
    private var lines: Int {
        max(3, Int(Self.words / (TypeScale.body * scale * 1.35)))
    }

    /// The height the words were clamped to while the row was the attachment card's height.
    ///
    /// 136 is `AttachmentDeck.side * 0.68` at the side the deck was before #79 doubled it. Named
    /// here rather than read from the deck so that a bigger picture stays a bigger picture
    /// instead of quietly becoming a longer excerpt as well.
    /// Also what `AttachmentDeck.tall` is, so that the picture beside the words is as tall as the
    /// words are allowed to be and a row with a picture is nearly a row without one.
    static let words: CGFloat = 136

    private var spoiler: String { post.spoiler ?? "" }
    /// One answer for both halves, the way the preference is one switch for both: the words
    /// behind their line and the media behind its blur are the same act to a reader.
    private var shown: Bool { reveal ?? revealed }
    private var wordsAreCovered: Bool { !spoiler.isEmpty && !shown }
    private var mediaIsCovered: Bool { post.sensitive == true && !shown }

    /// What `covers` stood at when the ring arrived here, or nothing while it is elsewhere.
    ///
    /// Without it the count alone would lie. Every row but the selected one is handed a zero,
    /// so a ring moving onto a post takes its `covers` from 0 to however many times the key
    /// has been pressed anywhere — which reads as a press and would lift the cover off a post
    /// the reader has only just arrived at. That is the one thing a cover must never do, so
    /// the row remembers where the count was when it became the reader's and acts only on
    /// what happens after.
    @State private var coversOnArrival: Int?
    /// Whether the list of the servers that carried this post is up.
    @State private var showingSources = false

    var body: some View {
        content
            .onChange(of: selected, initial: true) { _, now in
                coversOnArrival = now ? covers : nil
            }
            .onChange(of: covers) { _, now in
                guard selected, let arrival = coversOnArrival, now > arrival else { return }
                coversOnArrival = now
                withAnimation(Motion.appearing) { reveal = !shown }
            }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Space.step) {
            decorator
            metadata
            if wide {
                HStack(alignment: .top, spacing: Space.gap) {
                    words
                    attachmentColumn
                }
                // As tall as what is in it, and no taller. This used to be padded up to
                // `AttachmentDeck.height` so that every row was one height — which S6 no longer
                // promises, because the other arrangement never did it and because padding a
                // two-line post up to the height of a photograph spends most of a screen saying
                // nothing. What keeps the list scannable is still here: the words are clamped,
                // and the attachment column is reserved whether or not anything is in it, so
                // every row's text starts and ends in the same place.
                .padding(.top, Space.tight)
            } else {
                // Under the words, where no column is reserved for a picture and so nothing
                // guarantees the picture fits. The row says how much it has and the card takes
                // that or its own width, whichever is less.
                //
                // Measured, and S9 still holds. This is not a view asking how wide the device is
                // in order to decide what to draw — what to draw was decided by the arrangement.
                // It is the picture being told the size of the hole it goes into, which is the
                // one thing a picture cannot be right about on its own: 400 points of it in a
                // 350-point row is #78 returning with a bigger card.
                VStack(alignment: .leading, spacing: Space.step) {
                    words
                    if !post.attachments.isEmpty {
                        sized { deck(in: $0, widest: widest) }
                    } else if let card = post.card {
                        sized { LinkCard(card: card, covered: mediaIsCovered,
                                         width: $0, widest: widest) }
                    }
                }
                .padding(.top, Space.tight)
            }
            // The tags, where the whole post is being read rather than scanned (#107).
            //
            // **Only here, and that is the point.** In a list they are already in the words,
            // tinted and pressable, and a row of chips under forty rows would be a row of
            // controls where a sentence was doing the job. On the opened post there is one post
            // and room to say what it carries — and a chip is a real button, so this is also
            // where a tag can be reached with the keyboard rather than only with a pointer.
            if !condensed, !post.tags.isEmpty { tags }
            if acting { InteractionBar(post: post, open: open) }
            footer
        }
        .padding(Space.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fediqoCard()
        // One element standing for the whole row, with everything in it still reachable
        // underneath — which is what `.contain` says and what a row needs: the words are read,
        // the buttons are pressed, and none of that may be swallowed by the row having a name.
        //
        // The name is for a driver outside this process. `mergeKey` and not a position, for the
        // same reason the ring is written in one: row 3 is a different post the moment anything
        // arrives above it, and a test that said "row 3" would quietly change what it was
        // asking about. Declared before the ring below, so that "where the reader is" lands on
        // this element rather than on something inside it.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("post.\(post.mergeKey)")
        .fediqoFocusRing(selected)
        // A tap on the row opens the post — from **behind** the row rather than over it.
        //
        // Not a `Button`, for the reason it never was: the words are selectable, the deck turns
        // itself over and the interaction bar has buttons of its own, and wrapping the lot in
        // one would take every one of those presses away from them. And not a gesture over the
        // top of it either, which is what it used to be: an address in the words is now a link,
        // and a press of a link that a gesture above it has already swallowed is a link that
        // does nothing. Behind, so anything in the row that wants a press gets it first and
        // everything else — the padding, the name, the empty half of a short row — still opens
        // the post.
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { open?() }
        }
        // Beside whatever else the click was for, and not instead of it. The tap above is
        // behind the row so that the words stay selectable and the marks stay pressable; this
        // is over the whole of it and takes nothing away, because it only moves the ring.
        .simultaneousGesture(TapGesture().onEnded { focus?() })
        .contextMenu {
            if open != nil { Button(t("post.open")) { open?() } }
            if let url = post.webURL {
                Button(t("timeline.open")) { openURL(url) }
            }
        }
    }

    /// The band above everything: what happened to this post before it reached the reader.
    ///
    /// **One line, however many things happened.** It used to be two independent `if`s, so a
    /// post that was both an answer and a boost drew two stacked bands — two glyphs, two greys,
    /// and two lines of the row's height spent before a word of the post was read. The height is
    /// no longer the argument: S6 lets a row be as tall as what is in it now. What is left is the
    /// better half of the same argument — a boost of a reply is one sentence about how this post
    /// got here, and two bands say it twice.
    ///
    /// Favourites and the rest arrive with notifications (#9), and when they do this is the
    /// line they are said on rather than a second design for the same idea. Nothing at all is
    /// drawn where there is nothing to say.
    @ViewBuilder
    private var decorator: some View {
        if answering != .nothing || post.boostedBy != nil {
            HStack(spacing: Space.snug) {
                if answering != .nothing { answered }
                if answering != .nothing, post.boostedBy != nil { Text(verbatim: "·") }
                if let boostedBy = post.boostedBy { boosted(by: boostedBy) }
            }
            .fediqoFont(TypeScale.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    /// That it answers something, and whom where anybody here holds the answer.
    private var answered: some View {
        HStack(spacing: Space.tight) {
            Image(systemName: "arrowshape.turn.up.left").fediqoSymbol(TypeScale.caption, weight: .regular)
            // Named where the page or the store can name them, and "an answer" where neither
            // can. It is never a name this app worked out for itself: a reply's first mention
            // is usually the person it answers and usually is not good enough to print under
            // somebody else's name.
            switch answering {
            case .handle(let handle): Text(t("post.replyingTo", handle))
            default: Text(t("post.isReply"))
            }
        }
    }

    private func boosted(by who: String) -> some View {
        HStack(spacing: Space.tight) {
            Image(systemName: "arrow.2.squarepath").fediqoSymbol(TypeScale.caption, weight: .regular)
            // Not a `Label`: whoever boosted this may have a picture in their name, and a label
            // takes a string.
            EmojiText(t("timeline.boostedBy", who), emojis: post.emojis, size: TypeScale.caption)
        }
    }

    /// Who wrote it, where it reached us, and when. The whole width, above both columns: it
    /// is about the post rather than about its words, and an avatar in a gutter beside the
    /// text would make the text column start in a different place from the row above it.
    ///
    /// Two arrangements, widest first, and nothing here asks how wide the row is (S9). The
    /// band has four things to say and not always the room for four; the handle and the word
    /// before the server are what it gives up, together, because they are the two a reader
    /// can do without — the handle is usually the name again in lower case and the opened
    /// post says it in full, and a pill reading `birch.example` says "via" by itself.
    ///
    /// They go together because they went together before, when a size class dropped both at
    /// once on a phone. Which of the two should go first is a question nobody has asked, and
    /// this is not the change that answers it.
    private var metadata: some View {
        ViewThatFits(in: .horizontal) {
            metadataBand(verbose: true)
            metadataBand(verbose: false)
        }
    }

    private func metadataBand(verbose: Bool) -> some View {
        HStack(spacing: Space.step) {
            // The picture and the name are one press and not two: they are the same fact, and
            // splitting them would leave a reader guessing which half is the door. It takes the
            // press the row would have taken — the row's own tap opens the post — while the
            // `simultaneousGesture` that moves the ring still fires, so pressing an author still
            // says which post you mean (#55).
            //
            // Under `Hit.target`, and allowed to be: #44 made an address in a post's words
            // pressable at the size the words are, and this is the same kind of thing. Growing
            // the band to 44 would add fourteen points to every row in every list to make one
            // press easier — which is a cost every reader pays for a thing most of them do
            // rarely. S6 would tolerate the taller row now; the arithmetic still refuses it.
            Button { openAuthor?() } label: {
                HStack(spacing: Space.step) {
                    RemoteImage(url: post.authorAvatarURL, width: Size.avatar, height: Size.avatar,
                                standing: .avatar)
                    EmojiText(post.authorName, emojis: post.emojis, size: TypeScale.body,
                              weight: .semibold)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .disabled(openAuthor == nil)
            .layoutPriority(1)
            .accessibilityLabel(Text(post.authorName))
            .accessibilityHint(Text(t("person.title")))
            if verbose {
                // A handle is a label like the name beside it, and `@a@example.com` is most of
                // an address by construction — so it is drawn as text and never hunted through.
                // Safe twice over since #119: a plain `Text`, and `EmojiText`'s plain init would
                // not link it either if it ever wanted emoji.
                Text(post.authorHandle).fediqoFont(TypeScale.minor).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: Space.snug)
            sources(verbose: verbose)
            // When it was written never gives any of it up: a time squeezed to an ellipsis is
            // a row that has stopped saying when it happened. What it costs to keep is the
            // band's answer, though, and not one number — this comment said "four characters"
            // and named `5m`, `18m` and `2h` while the format beside it was drawing
            // `5 minutes ago`, which is thirteen. At 440 points and 1.6× those thirteen were
            // 120 of the band's 310, taken before the author's name was offered any.
            //
            // So the narrow arrangement gets the short form, which is what the comment always
            // said this was. A row with the room says it in words.
            Text(post.createdAt, format: .relative(presentation: .numeric,
                                                   unitsStyle: verbose ? .wide : .narrow))
                .fediqoFont(TypeScale.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
            // Last on the line, and that is about holding still rather than about reading
            // order. A relative time is whatever width its words are — "5m" and "18m" and "2h"
            // are three different widths, and it changes under the reader as the clock moves —
            // so anything drawn before it sits somewhere different on every row and shifts on
            // its own. A mark repeated down a list has to hold a column, and the only column
            // here that nothing can move is the one against the edge.
            audience
        }
    }

    /// Who the author wrote it for, where the server said so.
    ///
    /// Nothing at all where it did not, which is every post stored before 009 and every
    /// protocol with no such idea. A globe drawn on a post nobody described would be this app
    /// making a claim about somebody else's audience, and the one it would make — "anybody may
    /// read this" — is the worst of the four to get wrong.
    ///
    /// Beside the time rather than beside the name, because it belongs with where and when the
    /// post reached the reader rather than with who wrote it. Small and tertiary: it is a fact
    /// about the post, not a warning about it — the one mark on a row that is a warning is the
    /// author's own, and it is a band across the words.
    @ViewBuilder
    private var audience: some View {
        if let audience = post.audience {
            let name = t("post.visibility.\(audience.rawValue)")
            Image(systemName: Self.mark(for: audience))
                // A rung up from `inline`, which is what a mark beside words takes. This one is
                // not beside words: it is four shapes a reader has to tell apart, at the far
                // end of a row, and the comment below already said twelve points was not a
                // thing anybody should have to learn. `column` is the next size there is.
                .fediqoSymbol(Glyph.column, weight: .medium)
                .foregroundStyle(Self.tint(for: audience))
                // A box to hover over. An `Image` is only as hoverable as its own ink, and a
                // twelve-point glyph is a few strokes with holes in it — a pointer between them
                // is a pointer over nothing, and the hint would come and go as it moved. The
                // shape is what a tooltip is aimed at, so it is given one.
                .frame(width: Size.audienceMark, height: Size.audienceMark)
                .contentShape(Rectangle())
                .help(name)
                .accessibilityLabel(Text(name))
        }
    }

    /// One glyph each. The name is always beside it — as the hover hint, and as the
    /// accessibility label — because four shapes at twelve points is not a thing anybody should
    /// have to learn.
    private static func mark(for audience: Audience) -> String {
        switch audience {
        case .everyone: "globe"
        case .unlisted: "moon"
        case .followers: "lock"
        case .mentioned: "at"
        }
    }

    /// Colour says how far the post travels, and it is a ramp rather than four labels.
    ///
    /// Public is the ordinary case and stays the colour of everything else on the line. It is
    /// what most of a timeline is, and forty coloured globes down a page would be a decoration
    /// that means "normal" — the marks that are worth a colour are the ones that are not.
    ///
    /// From there it warms as the audience narrows: out of the public eye, then the author's
    /// followers, then the people they named. What the colour never does is carry the fact on
    /// its own — the shape says which, the hint says it in words, and this is the third telling.
    private static func tint(for audience: Audience) -> Color {
        switch audience {
        case .everyone: .secondary
        case .unlisted: .teal
        case .followers: .orange
        case .mentioned: .pink
        }
    }

    /// The left column: what they said, and the line in front of it where there is one.
    private var words: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            if !spoiler.isEmpty { warning }
            if !post.text.isEmpty, !wordsAreCovered {
                EmojiText(prose: post.text, emojis: post.emojis)
                    .textSelection(.enabled)
                    .lineLimit(condensed ? lines : nil)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: !condensed)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The line the author put in front of their words, and the way past it.
    ///
    /// A band rather than a line of small print: it is the one thing on a row that says "what
    /// is under here is not what you were expecting", and it has to be read before the words
    /// are, not after. The warning stays up whether or not the words behind it are showing —
    /// taking it away once somebody has read past it would remove the only thing saying what
    /// they are looking at — and the button beside it works both ways, so a reader who has
    /// everything turned on can still put one post back.
    private var warning: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.step) {
            Image(systemName: "exclamationmark.triangle.fill")
                .fediqoSymbol(Glyph.inline)
                .foregroundStyle(.orange)
            EmojiText(prose: spoiler, emojis: post.emojis, size: TypeScale.small, weight: .semibold)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.step)
            toggle
        }
        .padding(.horizontal, Space.gap)
        .padding(.vertical, Space.step)
        .background(
            RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                .fill(Color.orange.opacity(colorScheme == .dark ? 0.16 : 0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35))
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Show, or hide again. One control, both ways, and it says which way it is about to go.
    private var toggle: some View {
        Button {
            withAnimation(Motion.appearing) { reveal = !shown }
        } label: {
            HStack(spacing: Space.tight) {
                Image(systemName: shown ? "eye.slash" : "eye")
                    .fediqoSymbol(Glyph.badge)
                Text(t(shown ? "post.covered.hide" : "post.covered.show"))
                    .fediqoFont(TypeScale.caption, weight: .semibold)
            }
            .padding(.horizontal, Space.step)
            .padding(.vertical, Space.tight)
            .background(Capsule().fill(Color.orange.opacity(colorScheme == .dark ? 0.28 : 0.20)))
            .foregroundStyle(.orange)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(t(shown ? "post.covered.hide" : "post.covered.show"))
    }

    /// The right column. It is there whether or not anything is in it — that is what keeps the
    /// words the same width down the whole list — and when it is empty it is nothing at all:
    /// no frame, no dashes, no "no attachments". A visible empty box on every second post
    /// reads as something broken.
    @ViewBuilder
    private var attachmentColumn: some View {
        if !post.attachments.isEmpty {
            deck(widest: widest)
        } else if let card = post.card {
            // The link's own picture goes where the post's would have, because there is no
            // post's — a card and an attachment never both claim this column. The author's
            // media comes first where there is any: it is theirs, and the card is somebody
            // else's page.
            LinkCard(card: card, covered: mediaIsCovered, widest: widest)
        } else {
            // As wide as this row's column, not as wide as a list's: the empty column is what
            // keeps the words the same width down the page, and on the opened post the column
            // is the bigger one (#121).
            Color.clear.frame(width: widest, height: 0)
        }
    }

    private func deck(in width: CGFloat? = nil, widest: CGFloat = Size.card) -> some View {
        AttachmentDeck(attachments: post.attachments, covered: mediaIsCovered,
                       turns: turns, plays: plays, width: width, widest: widest) {
            withAnimation(Motion.appearing) { reveal = true }
        }
    }

    /// A box the shape of a card, no wider than one, and never wider than the row — with the
    /// card drawn into it once its width is known.
    ///
    /// A `GeometryReader` hands back whatever it is given rather than what is inside it, so one
    /// wrapped round the words as well would pad every short post up to the clamp: the padding
    /// S6 has just stopped promising, put back by the thing that measures. So only the picture
    /// is measured. `Color.clear` at the card's own ratio is what makes the box hug — it takes
    /// the narrower of the row and `side`, and its height follows from that rather than being
    /// stated.
    /// The room a picture under the words is given: the card's own shape, no wider than the
    /// card may be drawn and no taller than the card is at that width.
    ///
    /// **Both bounds, and that is not belt and braces.** With only the width, `aspectRatio` sat
    /// outside the cap and fitted its box to the width the *row* offered before the frame clipped
    /// that to the card's — so the card was drawn at 200 by 136 inside a box as tall as
    /// `row width × ratio`, and the hole under it grew with the row. At 1024 points the hole was
    /// deep enough to push the buttons and the whole conversation off the bottom of the window,
    /// and the timeline had the same hole at 700 with the largest text (#120).
    private func sized(@ViewBuilder card: @escaping (CGFloat) -> some View) -> some View {
        Color.clear
            .frame(maxWidth: widest, maxHeight: widest * AttachmentDeck.ratio)
            .aspectRatio(1 / AttachmentDeck.ratio, contentMode: .fit)
            .overlay { GeometryReader { room in card(room.size.width) } }
    }

    /// What this post is filed under, as the server sent it.
    ///
    /// Drawn from `post_tags` rather than from the words, so a tag the author put in the fields
    /// rather than in the sentence is here too — and a post whose server sent none draws nothing
    /// at all rather than an empty band.
    private var tags: some View {
        FlowRow(spacing: Space.tight, lineSpacing: Space.tight) {
            ForEach(post.tags, id: \.self) { tag in
                Button { openTag?(tag) } label: {
                    Text(verbatim: "#\(tag)")
                        .fediqoFont(TypeScale.minor)
                        .foregroundStyle(Palette.accent)
                        .padding(.horizontal, Space.snug)
                        .padding(.vertical, Space.tight)
                        .fediqoCard(radius: Radius.inner, raised: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(t("post.tags") + " #\(tag)"))
            }
        }
        .padding(.top, Space.tight)
    }

    /// The foot of the row: what the post was written with.
    ///
    /// Under everything, and quietly, because it is the least of what a row says — it is about
    /// neither the person nor the words. It is absent far more often than not: a server tells
    /// you what its own writers used and says nothing about a post that reached it from
    /// somewhere else. Nothing is drawn then. "Unknown app" would be a claim nobody made.
    @ViewBuilder
    private var footer: some View {
        if post.application == nil {
            // Held open, because most posts have nothing to say here and a list where every
            // other row is nine points shorter is a list that never sits still.
            if condensed { Color.clear.frame(height: TypeScale.minor * scale) }
        } else if let application = post.application {
            // At the right, alone. It is the only line in the row that is about none of the
            // three — not the person, not the words, not what can be done — and the far end is
            // where a reader's eye goes last.
            HStack(spacing: Space.tight) {
                Spacer(minLength: 0)
                Text(t("post.writtenWith")).fediqoFont(TypeScale.micro).foregroundStyle(.tertiary)
                if let website = application.website {
                    // **Underlined and not tinted** (#102). It has always opened; what it never
                    // did was look as though it would — drawn in the same tertiary grey as the
                    // words beside it, it was a link nobody could see was one. The accent would
                    // say it louder than the rest of the footer, and this line is still the
                    // least of what a row says: it is about neither the person, nor the words,
                    // nor what can be done.
                    Link(application.name, destination: website)
                        .fediqoFont(TypeScale.micro)
                        .foregroundStyle(.tertiary)
                        .underline()
                        // Where it goes, before it is pressed. The name of a client is not the
                        // name of a host, and a reader is owed the second before they leave.
                        .help(website.host() ?? website.absoluteString)
                        .accessibilityLabel(Text(t("post.writtenWith.opens", application.name,
                                                   website.host() ?? website.absoluteString)))
                } else {
                    // A name with no site stays what it is: this app does not go looking for a
                    // client's website and does not guess one from a name, because a link
                    // nobody sent is a link this app invented (S5).
                    Text(application.name).fediqoFont(TypeScale.micro).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// Which server handed it over — and when several did, one of them and a mark saying how
    /// many more. It sits in the metadata band beside who wrote it and when, because it is
    /// the same kind of fact: where this post reached us from, rather than anything about what
    /// it says.
    ///
    /// A pill per server was the repetition the merge exists to end: three servers carrying one
    /// post drew three pills, and the row was a third as wide again for a fact most readers
    /// never ask. So it is said once, and the rest is one hover or one press away — and a screen
    /// reader, which can neither hover nor see the mark, is told every one of them outright.
    ///
    /// `verbose` is the band's answer rather than this view's own: the word before the pill
    /// and the author's handle are given up together, by whichever arrangement of the band
    /// fitted the room it was given.
    private func sources(verbose: Bool) -> some View {
        HStack(spacing: Space.snug) {
            // The word is worth a column on a screen that has one to spare, and is the first
            // thing to go where there is not, because a pill saying `birch.example` says it
            // anyway.
            if verbose {
                Text(t("timeline.via")).fediqoFont(TypeScale.caption).foregroundStyle(.tertiary)
            }
            if let first = shownSources.first {
                Text(first)
                    .fediqoFont(TypeScale.caption)
                    .lineLimit(1)
                    // Middle, not tail: what a reader recognises about a server is at both
                    // ends, and `birch.exa…` names one no better than `b…` does.
                    .truncationMode(.middle)
                    .fediqoPill()
            }
            if shownSources.count > 1 { carriedByTheRest }
        }
        // The same priority as the name beside it, which in an `HStack` means the name is
        // served first because it comes first. That is the intended order and not an accident
        // of the arithmetic: **this used to outrank the name, and at 440 points and 1.6× it
        // drew the author as a single apostrophe** — found by `make -C Apps shots-widths`,
        // which exists to look at exactly that corner.
        //
        // The argument for the old order was that a host cut short is not a server while a
        // name cut short is still the person. It is a good argument at a width where the name
        // still has some, and it is not one for spending a row's last points on everything
        // except who wrote the post. What settles it is what each of them has behind it: a
        // truncated host has the `+n`, the press, the hover and an accessibility label naming
        // every server outright, and a name that is gone has nothing anywhere.
        //
        // At 440 and 1.6× the pill is still cut to `c…ple`, and that is honest rather than
        // fixed: the band has about 310 points and the timestamp takes 120 of them and yields
        // none, so there is no ordering of the two that leaves both whole. See #80.
        .layoutPriority(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(t("post.sources")): \(shownSources.joined(separator: ", "))"))
    }

    /// The servers that carried this post, in a settled order.
    ///
    /// **Sorted, and that is not a detail.** `Post.sources` is in the order the servers
    /// answered, which is a fact about a refresh rather than about the post: the same row read
    /// twice puts a different server first, and a row that says `alder.example` one second and
    /// `birch.example` the next is a row nobody can read. Which of them is drawn has to be the
    /// same answer every time, and alphabetical is the only ordering here that does not depend
    /// on the network's mood.
    private var shownSources: [String] { post.sources.sorted() }

    /// The mark, and the list behind it. `help` is the hover — the whole list, one per line —
    /// and the press is the same list where there is no pointer to hover with.
    private var carriedByTheRest: some View {
        Button { showingSources = true } label: {
            Text(verbatim: "+\(shownSources.count - 1)")
                .fediqoFont(TypeScale.caption, weight: .medium)
                .fixedSize()
                .fediqoPill()
        }
        .buttonStyle(.plain)
        .help(shownSources.joined(separator: "\n"))
        .popover(isPresented: $showingSources, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Space.tight) {
                Text(t("post.sources")).fediqoFont(TypeScale.caption).foregroundStyle(.secondary)
                ForEach(shownSources, id: \.self) { host in
                    Text(host).fediqoFont(TypeScale.small).textSelection(.enabled)
                }
            }
            .padding(Space.gap)
        }
    }
}

/// An avatar or a thumbnail: the same fetch, placeholder and clip wherever a picture comes
/// off a server rather than out of the bundle.
struct RemoteImage: View {
    @Environment(\.colorScheme) private var colorScheme
    let url: URL?
    let width: CGFloat
    let height: CGFloat
    var radius: CGFloat = Radius.thumbnail

    /// What is missing, where something is.
    ///
    /// A face and a picture want different marks — a person's silhouette over a missing
    /// attachment would be worse than no mark at all. And `covered` is a third thing rather
    /// than a kind of absence: there **is** a picture, the reader is not being shown it, and
    /// the deck draws its own cover to say so. A mark under that cover would be a second
    /// answer to a question already answered, smudged by the blur over it.
    enum Standing { case avatar, picture, covered }
    var standing: Standing = .picture


    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Whether the waiting shape is at the top of its breath. `@State` because it is an
    /// animation and nothing else reads it.
    @State private var breathing = false

    @Environment(\.displayScale) private var displayScale
    private var cache: PictureCache { .shared }

    /// Drawn from the cache rather than from an `AsyncImage`, which is #91: `AsyncImage` keeps
    /// its result for the lifetime of this view, so a row rebuilt for any reason went back to
    /// nothing and started again — and whether a reader ever saw a picture came down to whether
    /// the rebuilding stopped before they looked. It was measured not stopping.
    ///
    /// `.task(id:)` is still cancelled by a rebuild and that no longer matters: what it cancels
    /// is this view's waiting, and the work belongs to the cache.
    var body: some View {
        Group {
            if let picture = cache.picture(url, scale: displayScale) {
                picture.resizable().aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            // Still coming, and there is somewhere for it to come from.
            } else if url != nil, standing != .covered, !cache.isMissing(url, scale: displayScale) {
                waiting
            // Nothing to come, or nothing came. The two are one thing to a reader — there is no
            // picture here — and they get the same mark, which says which kind of nothing it is.
            } else {
                absent
            }
        }
        .animation(reduceMotion ? nil : Motion.appearing, value: cache.picture(url, scale: displayScale) == nil)
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .task(id: url) { await cache.fetch(url, scale: displayScale) }
    }

    /// A shape that breathes while the picture is on its way.
    ///
    /// The flat fill this used to be was the same flat fill a picture that never arrived left
    /// behind, so a row full of avatars still loading looked exactly like a row of broken ones.
    /// Under Reduce Motion it is that flat fill again and the mark below still tells the two
    /// apart, which is what makes the movement decoration rather than the message.
    private var waiting: some View {
        Rectangle()
            .fill(Palette.hairline(colorScheme))
            .opacity(breathing ? 0.45 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(Motion.breathing) { breathing = true }
            }
    }

    /// Nothing came, and it says which kind of nothing. Quiet: it is a fact about the row and
    /// not a fault the reader has to do something about.
    @ViewBuilder
    private var absent: some View {
        let fill = Rectangle().fill(Palette.hairline(colorScheme))
        if standing == .covered {
            fill
        } else {
            fill.overlay {
                Image(systemName: standing == .avatar ? "person.fill" : "photo")
                    .fediqoSymbol(min(width, height) * 0.42, weight: .regular)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
