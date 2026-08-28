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
        if chosen.parameter != .none {
            field(t("template.\(chosen.id).prompt"), text: $about, lines: 1)
        }
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
            if chosen.parameter != .none {
                let kind = Self.kind(of: chosen.parameter)
                editing.filters = editing.filters.filter { $0.kind != kind }
                let typed = about.trimmingCharacters(in: .whitespaces)
                if !typed.isEmpty { editing.filters.insert(TimelineFilter(kind: kind, value: typed), at: 0) }
            }
            app.update(editing)
        } else {
            // A timeline made from a template the reader did not rename follows the language
            // too — the three that ship are made this way on a first run, and one made by hand
            // from the same template should behave the same.
            let own = Timeline.isTemplateWording(trimmed, "name", of: chosen.id) ? "" : trimmed
            let line = Timeline.isTemplateWording(summary, "summary", of: chosen.id) ? "" : summary
            app.add(chosen.timeline(named: own, summary: line,
                                    about: about.trimmingCharacters(in: .whitespaces)))
        }
        done()
    }
}
