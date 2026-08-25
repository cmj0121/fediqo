import Foundation
import FediqoCore

/// What a timeline is called on the screen, and the line under it.
///
/// A timeline that ships with the app **keeps no name of its own until the reader writes one**,
/// and that is the whole of how Public and Trending follow the language. The words come from
/// the template each time they are drawn; the moment somebody types their own, the row carries
/// theirs and the language stops having an opinion about it — which is right, because a name a
/// reader chose is not a string this app gets to translate.
///
/// It lives here rather than on `Timeline` in Core for the reason the seeding does: Core has no
/// words. `Timeline.name` is what the reader wrote, and empty means they have not.
extension Timeline {
    @MainActor
    var displayName: String {
        name.isEmpty ? Self.templateWords("name", of: template) ?? "" : name
    }

    /// The reader's own sentence, or the template's where they have written none. Empty only
    /// for a timeline made from a template that has since gone — which nothing does today.
    @MainActor
    var displaySummary: String {
        summary.isEmpty ? Self.templateWords("summary", of: template) ?? "" : summary
    }

    /// Whether what was typed is just the template's own words back again.
    ///
    /// Saving those is not writing a name: the field is prefilled with them, and a reader who
    /// leaves it alone has not chosen anything — so the row keeps none and goes on following
    /// the language. Typing the original words back is how a rename is undone.
    ///
    /// The language on now, and no other. This answers a question about what somebody just
    /// typed into a field in front of them, not about what a row from an older version means.
    @MainActor
    static func isTemplateWording(_ written: String, _ part: String, of template: String) -> Bool {
        guard TimelineTemplate.named(template) != nil else { return false }
        return written == t("template.\(template).\(part)")
    }

    /// The template's own words for a part of a timeline, or nothing where the template is not
    /// one this build knows — a row from a later version, or one whose template was renamed.
    @MainActor
    private static func templateWords(_ part: String, of template: String) -> String? {
        guard TimelineTemplate.named(template) != nil else { return nil }
        return t("template.\(template).\(part)")
    }
}
