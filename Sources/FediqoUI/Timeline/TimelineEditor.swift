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

    /// Wide enough for a rule and its two fields side by side, and no wider: the sheet stands
    /// over the timeline it edits, and covering the whole of it would hide what is being said.
    private static let sheetWidth: CGFloat = 380

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

        if chosen.source.needsAccount, app.servers.isEmpty {
            Text(t("timeline.needsAccount"))
                .fediqoFont(TypeScale.minor)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
            app.add(made)
        }
        done()
    }
}
