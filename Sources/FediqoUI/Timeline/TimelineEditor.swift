import SwiftUI
import FediqoCore

/// Making a timeline, and changing one afterwards. The same sheet for both, because they are
/// the same three questions — what it reads, what it is called, and what it is for.
///
/// The template is only asked about once. It seeds the new timeline and has nothing to say to
/// it afterwards, so editing shows what the timeline *is* rather than which template it came
/// from: changing the template of a list somebody has named and described would be building a
/// different thing under the same name.
struct TimelineEditor: View {
    /// What the sheet was opened on: a timeline that does not exist yet, or one that does.
    enum Subject: Identifiable, Hashable {
        case new
        case existing(Timeline)

        var id: String {
            switch self {
            case .new: "new"
            case .existing(let timeline): timeline.id
            }
        }

        var timeline: Timeline? {
            switch self {
            case .new: nil
            case .existing(let timeline): timeline
            }
        }
    }

    let subject: Subject
    let done: () -> Void

    /// Wide enough for a rule read as a sentence and the controls that change it, and no wider:
    /// the sheet stands over the timeline it edits, and covering the whole of it would hide what
    /// is being said.
    ///
    /// **It grew, and #115 said it would.** A list of rules and a preview do not fit in the 380
    /// points that held three questions. Whether it should still be a sheet at all is the
    /// question that comes next, and it is a question to ask of a height that is a fact rather
    /// than a guess — which it now is.
    private static let sheetWidth: CGFloat = 460
    /// How much of the preview is shown. Enough to recognise what the rules are letting through,
    /// and not so much that the sheet becomes the timeline it is standing over.
    private static let previewed = 3

    @Environment(AppState.self) private var app
    @State private var template = TimelineTemplate.shipped[0]
    @State private var name = ""
    @State private var summary = ""
    /// What a template that is about something in particular is about: a hashtag, an author,
    /// an account being named. Empty for the three that are about everything.
    @State private var about = ""
    /// The hashtags this timeline subscribes to — asked for, not sieved (#104). On every
    /// template rather than only the one about a tag: a timeline is a base and the tags beside
    /// it, so a reader's home timeline may carry them too.
    /// The rules as they stand, which is what the reader is editing (#115).
    ///
    /// Held here and written on Save rather than into the timeline as they are typed: a reader
    /// who changes their mind and presses Cancel has not changed anything.
    @State private var rules: [TimelineFilter] = []
    /// What the rules as they stand let through, out of what this device already holds.
    @State private var preview: [Post] = []
    @State private var previewCount = 0
    @State private var tags: [String] = []
    /// The one being typed, before it is added. Separate from the list because a half-typed tag
    /// is not a subscription and must not be saved as one.
    @State private var typing = ""
    /// Whether the reader has typed a name of their own. Until they do, the name and the line
    /// under it follow the template they are picking — which is what makes choosing a template
    /// feel like choosing a timeline rather than filling in a form.
    @State private var named = false

    private var editing: Timeline? { subject.timeline }

    /// Which rule a template's one question writes.
    private static func kind(of parameter: TimelineTemplate.Parameter) -> TimelineFilter.Kind {
        switch parameter {
        case .none, .tag: .tag
        case .author: .author
        case .mention: .mention
        }
    }

    private var chosen: TimelineTemplate {
        TimelineTemplate.named(template) ?? TimelineTemplate.all[0]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.pad) {
            Text(t(editing == nil ? "timeline.new" : "timeline.edit"))
                .fediqoFont(TypeScale.lead, weight: .semibold)

            if editing == nil { templates }
            fields
            Spacer(minLength: 0)
            buttons
        }
        .padding(Space.withinGroup)
        .frame(width: Self.sheetWidth, alignment: .topLeading)
        .fediqoCard(radius: Radius.panel, shadow: true)
        .onAppear(perform: load)
    }

    // MARK: - The questions

    private var templates: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            Text(t("timeline.template")).fediqoFont(TypeScale.minor).foregroundStyle(.secondary)
            Picker("", selection: $template) {
                ForEach(TimelineTemplate.all) { option in
                    Text(t("template.\(option.id).name")).tag(option.id)
                }
            }
            .labelsHidden()
            .onChange(of: template) { _, id in
                // Only while the name is still the template's. A reader who has typed their
                // own keeps it, whichever template they try next.
                guard !named else { return }
                name = t("template.\(id).name")
                summary = t("template.\(id).summary")
            }
            Text(t("template.\(chosen.id).summary"))
                .fediqoFont(TypeScale.minor)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var fields: some View {
        // What the timeline is about, whether it is being made or changed. A hashtag timeline
        // whose hashtag could be set once and never corrected would be a timeline the reader
        // has to delete and make again over a typo.
        if chosen.parameter != .none, chosen.parameter != .tag {
            field(t("template.\(chosen.id).prompt"), text: $about, lines: 1)
        }
        hashtags
        field(t("timeline.name"), text: $name, lines: 1)
            .onChange(of: name) { _, _ in named = true }
        // The long one. A name is two words and the line under it is what the page shows to
        // say what those two words mean — `PageHeader` has kept the room for it all along.
        field(t("timeline.description"), text: $summary, lines: 3)
        rulesList
        previewList

        if chosen.source.needsAccount, app.servers.isEmpty {
            Text(t("timeline.needsAccount"))
                .fediqoFont(TypeScale.minor)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The rules, as sentences a person would say, each with the two things that can be done
    /// to it: turned round, or taken off (#115).
    ///
    /// **A list and not a field.** The model has carried several rules of five kinds, each
    /// including or excluding, since it was written — the sheet was the only thing keeping any
    /// of it from the reader. It wrote exactly one, of whichever kind the template implied, and
    /// never set `negate` at all, so *this hashtag but not from that server* could not be said.
    @ViewBuilder
    private var rulesList: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            HStack {
                Text(t("timeline.rules")).fediqoFont(TypeScale.minor).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(TimelineFilter.Kind.allCases, id: \.self) { kind in
                        Button(t("timeline.kind.\(kind.rawValue)")) { add(kind) }
                    }
                } label: {
                    Label(t("timeline.rules.add"), systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                        .fediqoFont(TypeScale.minor)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            if rules.isEmpty {
                // Removing the last rule leaves a timeline rather than a broken one: no rules
                // means everything the reading carries, which is what the three shipped ones are.
                Text(t("timeline.rules.none"))
                    .fediqoFont(TypeScale.minor)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(rules.enumerated()), id: \.offset) { at, rule in
                ruleRow(at: at, rule: rule)
            }
        }
    }

    private func ruleRow(at index: Int, rule: TimelineFilter) -> some View {
        HStack(spacing: Space.step) {
            // Which way round it is, said in words rather than by a checkbox called `negate`.
            Picker("", selection: Binding(
                get: { rules[index].negate },
                set: { rules[index] = TimelineFilter(kind: rule.kind, value: rule.value, negate: $0) }
            )) {
                Text(t("timeline.rules.keep")).tag(false)
                Text(t("timeline.rules.drop")).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if rule.kind == .media {
                // The whole rule; there is nothing to name. A field here would be a box asking
                // for something that does not exist.
                Text(t(rule.sentence.key))
                    .fediqoFont(TypeScale.minor)
                    .foregroundStyle(.secondary)
            } else {
                TextField(t("timeline.kind.\(rule.kind.rawValue)"), text: Binding(
                    get: { rules[index].value },
                    set: { rules[index] = TimelineFilter(kind: rule.kind, value: $0, negate: rule.negate) }
                ))
                .textFieldStyle(.plain)
                .fediqoFont(TypeScale.small)
                .padding(Space.step)
                .fediqoCard(radius: Radius.inner, raised: false)
            }

            Button { rules.remove(at: index) } label: {
                Image(systemName: "xmark").fediqoSymbol(Glyph.inline)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(t("timeline.rules.remove"))
            .accessibilityLabel(Text(t("timeline.rules.remove")))
        }
    }

    /// What the rules as they stand let through, out of what this device already holds (#115).
    ///
    /// **It asks nobody.** So it costs nobody's server anything, works with the network off, and
    /// is instant — and it says out loud that it is showing what is already here rather than
    /// what exists, because anything else would be a promise it cannot keep. It is #105's read
    /// path, pointed at a timeline that does not exist yet.
    @ViewBuilder
    private var previewList: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            Text(t("timeline.preview")).fediqoFont(TypeScale.minor).foregroundStyle(.secondary)
            if preview.isEmpty {
                Text(t("timeline.preview.none"))
                    .fediqoFont(TypeScale.minor)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(preview.prefix(Self.previewed), id: \.mergeKey) { post in
                    VStack(alignment: .leading, spacing: Space.tight) {
                        Text(post.authorHandle)
                            .fediqoFont(TypeScale.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                        // The post as the reader would see it, shortcodes drawn as the pictures
                        // they are: a preview written in `:spark:` is not a preview of what the
                        // timeline will look like.
                        EmojiText(prose: post.text, emojis: post.emojis, size: TypeScale.minor)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(Space.step)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fediqoCard(radius: Radius.inner, raised: false)
                }
                Text(t("timeline.preview.note", "\(previewCount)"))
                    .fediqoFont(TypeScale.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Remade whenever the question changes and never oftener: the rules, the tags and the
        // template are the whole of what the preview is an answer to.
        .task(id: previewKey) { await lookAtWhatIsHere() }
    }

    /// What the preview is an answer to, as one value, so a reader typing a hashtag asks the
    /// store once when they stop rather than once per letter.
    private var previewKey: String {
        "\(chosen.id)|\(tags.joined(separator: ","))|" +
        rules.map { "\($0.kind.rawValue)\($0.negate ? "!" : "")\($0.value)" }.joined(separator: "|")
    }

    private func lookAtWhatIsHere() async {
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        var made = chosen.timeline(named: "", summary: "", about: about)
        made.tags = tags
        made.filters = rules
        let found = await app.storedUnder(made.query)
        guard !Task.isCancelled else { return }
        preview = found
        previewCount = found.count
    }

    private func add(_ kind: TimelineFilter.Kind) {
        rules.append(TimelineFilter(kind: kind, value: "", negate: false))
    }

    /// The tags, and a place to add one.
    ///
    /// A list rather than a field, because a subscription is a thing you add to and take from —
    /// a hashtag timeline whose one tag could be set and never corrected was a timeline the
    /// reader had to delete and make again over a typo, and one that could only ever hold a
    /// single tag was most of what #104 is about missing.
    private var hashtags: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            Text(t("timeline.tags")).fediqoFont(TypeScale.minor).foregroundStyle(.secondary)
            if !tags.isEmpty {
                FlowRow(spacing: Space.tight, lineSpacing: Space.tight) {
                    ForEach(tags, id: \.self) { tag in
                        Button { remove(tag) } label: {
                            HStack(spacing: Space.tight) {
                                Text(verbatim: "#\(tag)").fediqoFont(TypeScale.minor)
                                Image(systemName: "xmark").fediqoSymbol(Glyph.inline)
                            }
                            .padding(.horizontal, Space.snug)
                            .padding(.vertical, Space.tight)
                            .fediqoCard(radius: Radius.inner, raised: false)
                        }
                        .buttonStyle(.plain)
                        // What pressing it does, said in words: the shape is a tag and the
                        // cross is small, and neither says "remove" to somebody not looking.
                        .help(t("timeline.tags.remove", tag))
                        .accessibilityLabel(Text(t("timeline.tags.remove", tag)))
                    }
                }
            }
            HStack(spacing: Space.step) {
                TextField(t("timeline.tags.hint"), text: $typing)
                    .textFieldStyle(.plain)
                    .fediqoFont(TypeScale.small)
                    .padding(Space.step)
                    .fediqoCard(radius: Radius.inner, raised: false)
                    // Return adds it, because that is what Return does to a field you are
                    // typing a list into. The button is the same thing for a pointer.
                    .onSubmit(add)
                Button(t("timeline.tags.add"), action: add)
                    .buttonStyle(.plain)
                    .fediqoFont(TypeScale.small)
                    .disabled(Post.normalisedTags([typing]).isEmpty)
            }
        }
    }

    /// What was typed, kept the one way the store keeps a tag — so `#Swift`, `swift` and
    /// `＃swift` are one subscription however it was typed, and adding one already there does
    /// nothing rather than asking the same server twice.
    private func add() {
        guard let tag = Post.normalisedTags([typing]).first, !tags.contains(tag) else {
            typing = ""
            return
        }
        tags.append(tag)
        typing = ""
    }

    private func remove(_ tag: String) {
        tags.removeAll { $0 == tag }
    }

    private func field(_ label: String, text: Binding<String>, lines: Int) -> some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            Text(label).fediqoFont(TypeScale.minor).foregroundStyle(.secondary)
            TextField("", text: text, axis: lines > 1 ? .vertical : .horizontal)
                .textFieldStyle(.plain)
                .lineLimit(lines, reservesSpace: lines > 1)
                .fediqoFont(TypeScale.small)
                .padding(Space.step)
                .fediqoCard(radius: Radius.inner, raised: false)
        }
    }

    private var buttons: some View {
        HStack(spacing: Space.step) {
            Spacer()
            Button(t("timeline.cancel"), action: done)
                .buttonStyle(.plain)
                .fediqoFont(TypeScale.small)
            Button(t("timeline.save"), action: save)
                .buttonStyle(.borderedProminent)
                .fediqoFont(TypeScale.small)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: - In and out

    private func load() {
        guard let editing else {
            name = t("template.\(template).name")
            summary = t("template.\(template).summary")
            return
        }
        // The template is not asked about again when editing, but it is still what says
        // whether this timeline is about something in particular — so it is read back rather
        // than left at the picker's default.

        // What it is called on the screen, which for one of the shipped rows is its template's
        // word for it — the field must show what the reader sees, not the empty string that
        // means "you have not written one".
        name = editing.displayName
        summary = editing.displaySummary
        template = editing.template
        about = editing.filters.first?.value ?? ""
        tags = editing.tags
        rules = editing.filters
        named = true
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if var editing {
            // Saving the app's own words back is not writing a name. Left as they are, the tab
            // goes on following the language; anything else is the reader's and is kept as
            // typed. This is also what a reader "undoing" a rename would expect: type the
            // original words back and it is the app's again.
            editing.name = Timeline.isTemplateWording(trimmed, "name", of: editing.template) ? "" : trimmed
            editing.summary = Timeline.isTemplateWording(summary, "summary", of: editing.template) ? "" : summary
            // The rule the template is about, rewritten from what they typed. Every other rule
            // the timeline carries is left where it is: this sheet is about what it is called
            // and what it is about, and a rule it never showed is not its to remove.
            if chosen.parameter != .none, chosen.parameter != .tag {
                let kind = Self.kind(of: chosen.parameter)
                editing.filters = editing.filters.filter { $0.kind != kind }
                let typed = about.trimmingCharacters(in: .whitespaces)
                if !typed.isEmpty { editing.filters.insert(TimelineFilter(kind: kind, value: typed), at: 0) }
            }
            // Including one still in the field. A reader who typed a tag and pressed Save meant
            // to subscribe to it, and losing it to an unpressed button is the sheet being right
            // about the mechanism and wrong about the person.
            editing.tags = tags + Post.normalisedTags([typing]).filter { !tags.contains($0) }
            // Every rule the reader can now see is a rule this sheet is responsible for, so the
            // whole list is written rather than one kind of it. A rule with nothing named is
            // dropped: an empty box is a rule somebody started and did not finish, and saving
            // it would be a timeline that quietly shows nothing.
            editing.filters = rules.filter { $0.kind == .media || !$0.value.isEmpty }
            app.update(editing)
        } else {
            // A timeline made from a template the reader did not rename follows the language
            // too — the three that ship are made this way on a first run, and one made by hand
            // from the same template should behave the same.
            let own = Timeline.isTemplateWording(trimmed, "name", of: chosen.id) ? "" : trimmed
            let line = Timeline.isTemplateWording(summary, "summary", of: chosen.id) ? "" : summary
            var made = chosen.timeline(named: own, summary: line,
                                       about: about.trimmingCharacters(in: .whitespaces))
            made.tags = tags + Post.normalisedTags([typing]).filter { !tags.contains($0) }
            made.filters = rules.filter { $0.kind == .media || !$0.value.isEmpty }
            app.add(made)
        }
        done()
    }
}
