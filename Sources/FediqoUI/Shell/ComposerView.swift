import SwiftUI
import UniformTypeIdentifiers
import FediqoCore

/// What the New Post button opens. It is deliberately not a screen: composing is something
/// you do from wherever you already are, so it arrives over the timeline and leaves the
/// moment you look at anything else.
///
/// Posting lands with #8. This is the room it will land in — and the editor is already in
/// it, because it is the app's one text field inside the shell and so the one thing that can
/// say whether text is being typed. Every single-key shortcut depends on that answer, so the
/// field is here before the sending is.
struct ComposerView: View {
    @Environment(AppState.self) private var app
    @State private var draft = ""
    @State private var warning = ""
    @State private var showingWarning = false
    @State private var audience: Audience = .everyone
    /// Whether there is an account that could send this answer. `nil` until it has been asked —
    /// which is not the same as `false`, and drawing the refusal for it would accuse a reader of
    /// having no account before anybody had looked.
    @State private var canAnswer: Bool?
    /// The pictures on this draft, in the order they were put on (#89). Held here rather than on
    /// the app: a draft is this panel's, and one that is never sent is gone with it.
    @State private var pictures: [Draft.Picture] = []
    @State private var choosing = false
    /// The keyboard, and where it is. SwiftUI will not say whether a text field somewhere
    /// has it, so this says it for the one field that could.
    @FocusState private var typing: Bool

    var body: some View {
        content
        // Whatever the panel was given, which is `share` of the room left after the safe area
        // and the keyboard — see `ComposerPanel`, which is the one place that measures.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fediqoCard(radius: Radius.panel, shadow: true)
        // A composer you have to reach for the mouse to type in is a composer that failed on
        // a keyboard. `c` opens it and the cursor is already here; `Escape` is how you leave,
        // and it is the one key that still works while this has the keyboard.
        .task { await takeTheKeyboard() }
        // That server's rule, asked of it rather than written here, and asked when the panel
        // opens because it is theirs to change between one post and the next.
        .task { await app.askTheLimit() }
        // And whether there is anybody to answer as, asked at the same moment and for the same
        // reason: both are things a reader should be told before writing rather than after.
        .task {
            guard let parent = app.answering else { return }
            let account = await app.acting(on: parent)
            canAnswer = account != nil
            // Who the reply opens with (#97). Once, and only into a draft nobody has written
            // in: the acting account is asked over the network, and a reader who started
            // typing while it was out must not have their first words pushed along by a
            // handle arriving late.
            if draft.isEmpty {
                draft = app.preferences.carryMentions.opening(answering: parent,
                                                              as: account?.authorId)
            }
        }
        // Who the handle being typed could be (#98). `.task(id:)` rather than a task of its
        // own: changing the id cancels the wait and the question with it, so a reader typing
        // quickly asks once at the end rather than once per letter — and closing the panel
        // cancels it too.
        .task(id: typedHandle) {
            guard let typed = typedHandle else { return app.mentions.clear() }
            try? await Task.sleep(for: Self.settle)
            guard !Task.isCancelled else { return }
            // Asked of the server this draft will be posted from, and of no other: an account
            // is offered so it can be written into a post that server will send, and one it
            // has never heard of is one it cannot address.
            let account = if let parent = app.answering {
                await app.acting(on: parent)
            } else {
                await app.publishing()
            }
            await app.mentions.look(for: typed, as: account)
        }
        // What the reader took, written into the draft here and nowhere else. The offer is the
        // model's and the draft is this view's, so there is one place that edits what somebody
        // wrote (#98).
        .onChange(of: app.mentions.chosen) { _, taken in
            guard let taken, let query = MentionQuery.trailing(in: draft) else { return }
            draft = query.accepting(taken.handle, in: draft)
            app.mentions.chosen = nil
            app.mentions.clear()
        }
        .onDisappear { app.mentions.clear() }
        // The audience a reply may not be wider than. Set once when the panel opens rather than
        // clamped at the send, so what the picker shows is what will go — `Draft` narrows it
        // again anyway, and a composer whose picker disagreed with the post it sent would be
        // telling the reader one thing and the server another.
        .task {
            if let parent = app.answering {
                audience = Audience.narrower(of: audience, parent.audience)
            }
        }
    }

    /// Asks the field for the keyboard until it has it.
    ///
    /// Not in `onAppear`, and not once after a fixed wait either. The panel arrives on an
    /// animation, and a field asked for the keyboard before it is on screen is not yet in
    /// the responder chain to take it — the ask is simply dropped. A single sleep timed
    /// against that animation is a bet, and losing it leaves a reader with no pointer in a
    /// panel they can neither type in nor get out of. So it asks again until the field says
    /// it has the keyboard, and stops the moment it does — or the moment the panel goes and
    /// `.task` is cancelled with it.
    private func takeTheKeyboard() async {
        for _ in 0..<Self.focusAttempts {
            if Task.isCancelled { return }
            typing = true
            try? await Task.sleep(for: Self.focusRetry)
            if typing { return }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Space.gap) {
            HStack(spacing: Space.step) {
                Image(systemName: app.answering == nil ? "square.and.pencil" : "arrowshape.turn.up.left")
                    .foregroundStyle(Palette.accent)
                Text(t(app.answering == nil ? "compose.title" : "compose.replying"))
                    .fediqoFont(TypeScale.lead, weight: .semibold)
                Spacer()
                room
            }

            answering
            cannotAnswer

            if showingWarning {
                TextField(t("composer.warning"), text: $warning)
                    .textFieldStyle(.plain)
                    .fediqoFont(TypeScale.small)
                    .padding(Space.mid)
                    .fediqoCard(radius: Radius.inner, raised: false)
            }

            TextField(t("compose.placeholder"), text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .focused($typing)
                .fediqoFont(TypeScale.small)
                .padding(Space.mid)
                // Into whatever the panel has left. The composer is most of the window now, and
                // a field that stayed 72 points tall in it would be a small box with a field of
                // empty card under it — which is what a corner panel had no room to be.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .fediqoCard(radius: Radius.inner, raised: false)
                .onChange(of: typing) { _, now in app.setTyping(now) }

            offered
            attached
            destinations
            controls
        }
        .padding(Space.pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - the handle being typed (#98)

    /// Who the handle at the end of the draft could be.
    ///
    /// Under the field rather than over it, because it appears and goes as somebody types: a
    /// list that opened above the field would push the words they are writing down the panel
    /// on every third letter.
    @ViewBuilder
    private var offered: some View {
        if !app.mentions.people.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(app.mentions.people, id: \.authorId) { person in
                    Button { app.mentions.chosen = person } label: {
                        HStack(spacing: Space.step) {
                            RemoteImage(url: person.avatarURL, width: Size.iconColumn,
                                        height: Size.iconColumn, standing: .avatar)
                            EmojiText(person.name, emojis: person.emojis,
                                      size: TypeScale.small, weight: .medium)
                                .lineLimit(1)
                            Text(person.handle)
                                .fediqoFont(TypeScale.minor)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: Space.tight)
                            // Which one `Tab` takes, said on the row it would take rather than
                            // left for a reader to guess from the order.
                            if person.authorId == app.mentions.first?.authorId {
                                Text(verbatim: "⇥")
                                    .fediqoFont(TypeScale.minor, design: .monospaced)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, Space.tight)
                        .padding(.horizontal, Space.mid)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fediqoCard(radius: Radius.inner, raised: false)
        }
    }

    /// What is being typed at the end of the draft, or nothing. Watched rather than computed at
    /// the ask, so the wait below is keyed to the question and not to every keystroke.
    private var typedHandle: String? { MentionQuery.trailing(in: draft)?.text }

    /// How long a reader has to stop typing before anybody is asked.
    ///
    /// Not a throttle on our side but a courtesy to theirs: a question per letter would have
    /// somebody else's server answering eleven times about a handle that was only ever one.
    private static let settle = Duration.milliseconds(250)

    /// How much room is left, or nothing at all where the server never said.
    ///
    /// Nothing rather than a number of ours: how long a post may be is that server's rule, and
    /// a composer counting down to a figure this app invented would be lying quietly until the
    /// moment it mattered. It turns when the room runs out, because that is the one moment the
    /// count is worth reading.
    @ViewBuilder
    private var room: some View {
        if let limit = app.postingLimit {
            // Counted the way the check counts it, so what the reader watches run out and what
            // a server would refuse are one number rather than two that nearly agree.
            let left = limit - written.length
            Text(verbatim: "\(left)")
                .fediqoFont(TypeScale.caption, weight: .medium)
                .monospacedDigit()
                .foregroundStyle(left < 0 ? .red : .secondary)
        }
    }

    /// Where it is going, and what became of each of them last time it was sent.
    ///
    /// Drawn only where there is a choice to make: a reader with one account has already chosen
    /// by having one, and a row of one toggle is a question with one answer.
    ///
    /// The marks beside them are the per-destination answer #8 asks for. A post that reached two
    /// servers of three is two ticks and one cross, said where the reader chose them and where
    /// they can choose again — a notice can only say one thing, and this is three things.
    @ViewBuilder
    private var destinations: some View {
        let choices = app.actingChoices
        if choices.count > 1 {
            FlowRow(spacing: Space.tight) {
                ForEach(choices, id: \.endpoint) { choice in
                    let host = Server.normalise(choice.endpoint)
                    let chosen = app.postingTo.isEmpty
                        ? host == app.lastPosted : app.postingTo.contains(choice.endpoint)
                    Button {
                        if app.postingTo.isEmpty { app.postingTo = Set(choices.map(\.endpoint)) }
                        if app.postingTo.contains(choice.endpoint) {
                            app.postingTo.remove(choice.endpoint)
                        } else {
                            app.postingTo.insert(choice.endpoint)
                        }
                        Task { await app.askTheLimit() }
                    } label: {
                        HStack(spacing: Space.tight) {
                            if let sent = app.lastSent[host] {
                                Image(systemName: sent.went ? "checkmark" : "exclamationmark.triangle.fill")
                                    .fediqoSymbol(Glyph.badge, weight: .semibold)
                                    .foregroundStyle(sent.went ? Color.green : .orange)
                            }
                            Text(host).fediqoFont(TypeScale.caption, weight: .medium)
                        }
                        .fediqoPill()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(chosen ? Palette.accent : Color.secondary)
                }
            }
        }
    }

    /// Who it is for, whether there is a warning, and the press that sends it.
    private var controls: some View {
        HStack(spacing: Space.step) {
            Menu {
                Picker("", selection: $audience) {
                    ForEach(Audience.allCases, id: \.self) { choice in
                        Text(t("post.visibility.\(choice.rawValue)")).tag(choice)
                    }
                }
                .labelsHidden()
            } label: {
                Image(systemName: Self.mark(for: audience)).fediqoSymbol(Glyph.inline, weight: .medium)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(t("post.visibility.\(audience.rawValue)"))

            // A picture, chosen from the files this reader already has. `fileImporter` and not
            // a photo library: it is the one picker both platforms draw, and it asks for the one
            // thing being asked for rather than for a standing permission to look at everything.
            Button { choosing = true } label: {
                Image(systemName: "photo.badge.plus").fediqoSymbol(Glyph.inline, weight: .medium)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.accent)
            .help(t("compose.addPicture"))
            .accessibilityLabel(Text(t("compose.addPicture")))
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.image],
                          allowsMultipleSelection: true) { picked in
                guard case .success(let files) = picked else { return }
                pictures += files.compactMap(Self.read)
            }

            // The warning is a field that is not there until it is asked for: most posts have
            // none, and an empty box above every draft is a question nobody was asking.
            Button {
                showingWarning.toggle()
                if !showingWarning { warning = "" }
            } label: {
                Image(systemName: showingWarning ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
                    .fediqoSymbol(Glyph.inline, weight: .medium)
            }
            .buttonStyle(.plain)
            .foregroundStyle(showingWarning ? .orange : .secondary)
            .help(t("composer.warning"))

            Spacer(minLength: Space.snug)

            Button(t(app.isSending ? "composer.sending" : "composer.send")) {
                let going = written
                Task {
                    // The draft is cleared only where it all went. A post that a server refused
                    // is still written, and losing it is the worst thing this could do.
                    if await app.publish(going) { draft = ""; warning = ""; showingWarning = false }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.accent)
            .fediqoFont(TypeScale.small, weight: .medium)
            .disabled(!canSend)
        }
    }

    /// The post this answers, whole, above what is being written.
    ///
    /// Whole rather than a line naming its author, because a reader who pressed reply from a
    /// timeline may have scrolled past it, and "who am I answering" and "what am I answering"
    /// are two questions. It is the same `PostRow` the list draws, so what is quoted here and
    /// what was pressed there cannot come to look like two different posts.
    ///
    /// There is room for it because the composer is most of the window now. It was a corner
    /// panel of 320 points, and a post in it would have left a line and a half to type in.
    @ViewBuilder
    private var answering: some View {
        if let parent = app.answering {
            PostRow(post: parent, condensed: true, acting: false)
                .fediqoCard(raised: false)
                .allowsHitTesting(false)
                .accessibilityLabel(Text(t("compose.replyingTo", parent.authorHandle)))
        }
    }

    /// Said before a word is typed, and that is the whole of it.
    ///
    /// A reply goes as the account `acting(on:)` chooses, and where the reader has none anywhere
    /// there is no such account. Finding that out on the send is finding it out after writing an
    /// answer, which is the one moment it is most expensive to be told — so the composer asks
    /// when it opens and says so at the top of the empty field.
    @ViewBuilder
    private var cannotAnswer: some View {
        if app.answering != nil, canAnswer == false {
            Label(t("compose.noAccount"), systemImage: "person.slash")
                .fediqoFont(TypeScale.small)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The pictures on the draft, each with the place to describe it.
    ///
    /// **The description is asked for beside the picture and not behind a second press.** This
    /// app says out loud when a server sent a picture with no description; a composer that made
    /// writing one an extra step it is easy not to take would be holding other people to a rule
    /// it makes easy to break here.
    @ViewBuilder
    private var attached: some View {
        if !pictures.isEmpty {
            VStack(spacing: Space.step) {
                ForEach($pictures) { $picture in
                    HStack(alignment: .top, spacing: Space.gap) {
                        RemoteImage(url: nil, width: Size.thumbnail, height: Size.thumbnail,
                                    standing: .picture)
                            .overlay { thumbnail(picture) }
                        VStack(alignment: .leading, spacing: Space.tight) {
                            Text(picture.filename)
                                .fediqoFont(TypeScale.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            TextField(t("compose.describe"), text: $picture.description, axis: .vertical)
                                .textFieldStyle(.plain)
                                .fediqoFont(TypeScale.small)
                                .padding(Space.snug)
                                .fediqoCard(radius: Radius.inner, raised: false)
                        }
                        IconButton(symbol: "xmark", labelKey: "compose.removePicture") {
                            pictures.removeAll { $0.id == picture.id }
                        }
                    }
                }
            }
        }
    }

    /// One chosen file, read in.
    ///
    /// The bytes now rather than the address: a reader may move or delete the file between
    /// choosing it and sending, and a composer holding a path would send nothing and say a
    /// server refused it. What it is is asked of the file itself rather than of its extension.
    ///
    /// A file that cannot be read is simply not added. There is nothing useful to say about it
    /// that the picker did not already know, and a draft is not the place to explain a
    /// filesystem.
    private static func read(_ file: URL) -> Draft.Picture? {
        let opened = file.startAccessingSecurityScopedResource()
        defer { if opened { file.stopAccessingSecurityScopedResource() } }
        guard let bytes = try? Data(contentsOf: file), !bytes.isEmpty else { return nil }
        let mime = (try? file.resourceValues(forKeys: [.contentTypeKey]).contentType)?
            .preferredMIMEType ?? "application/octet-stream"
        return Draft.Picture(bytes: bytes, filename: file.lastPathComponent, mime: mime)
    }

    /// The picture itself, drawn from the bytes in hand. No address and nothing to fetch: it has
    /// not been anywhere yet and will not until this is sent.
    @ViewBuilder
    private func thumbnail(_ picture: Draft.Picture) -> some View {
        if let image = PictureCache.decode(picture.bytes) {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: Radius.thumbnail, style: .continuous))
        }
    }

    /// What is written, as the one value everything here reads: the counter, the check and the
    /// send are three questions about one draft, and building it three times is three chances
    /// for them to differ.
    private var written: Draft {
        Draft(text: draft, audience: audience, warning: showingWarning ? warning : nil,
              answering: app.answering, pictures: pictures)
    }

    /// Nothing to send, no room left, or one already on its way.
    private var canSend: Bool {
        guard !app.isSending else { return false }
        // A picture with no words is a post. What is refused is a draft with nothing in it at
        // all, which is what `carries` means.
        guard written.carries else { return false }
        guard let limit = app.postingLimit else { return true }
        return written.length <= limit
    }

    /// The same four glyphs a row draws for the same four audiences. One idea, drawn the same
    /// way wherever it is: what a reader chooses here is what they will see on the row.
    private static func mark(for audience: Audience) -> String {
        switch audience {
        case .everyone: "globe"
        case .unlisted: "moon"
        case .followers: "lock"
        case .mentioned: "at"
        }
    }

    /// How much of the room the composer takes, on both sides. Read by `ComposerPanel`, which
    /// is what measures the room.
    ///
    /// A share rather than a size. 320 × 250 was most of a phone and a corner of a Mac, and it
    /// was asked to hold the same things in both; four fifths is the same decision wherever it
    /// is made. What is left round the edges is what says this is over something rather than
    /// instead of it.
    static let share: CGFloat = 0.8

    /// Eight asks, 25ms apart: 200ms in all, comfortably past the 0.15s the panel animates
    /// for, in steps short enough that the cursor is there before anybody has begun to type.
    private static let focusAttempts = 8
    private static let focusRetry = Duration.milliseconds(25)
}
