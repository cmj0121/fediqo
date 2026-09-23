import Foundation

// MARK: - Why a forum will not show a blog or a thread — #213

/// Why a Discuz! forum would not show this reader a blog or a thread, **told apart**, because
/// each reason has its own one thing that could help: signing in, the author's password, the
/// forum's own page, or nothing at all.
///
/// **What the real pages said** — the local X5.0.2 in `servers/`, fetched with `curl` on
/// 2026-09-24, signed out and as an ordinary member who is nobody's friend:
///
/// | asked for | signed out | signed in |
/// | --- | --- | --- |
/// | a blog for friends, for chosen readers, or only its author | notice, sign in | a privacy page, the same for all three |
/// | a blog behind its author's password | notice, sign in | the password form |
/// | a blog that is not there | notice, gone | notice, gone |
/// | any blog, blogs switched off | notice, switched off | notice, switched off |
/// | a thread that asks more reading standing | redirect to sign in | notice, standing |
/// | a thread in a board for other groups | redirect to sign in | notice, standing |
/// | a thread in a board that asks points | redirect to sign in | notice, conditions |
/// | a thread with a price | the thread, its opening post locked with a way to pay | the same |
/// | a thread deleted | 404 and a notice, gone | 404 and a notice, gone |
///
/// **Friends-only and author-only cannot be told apart, and are one case.** Discuz! serves the
/// same `home/space_privacy` page for both, and for chosen readers too — the page says the
/// author's privacy settings keep this reader out, and not which one — so this says what the
/// page says.
///
/// **A password blog is never offered to a signed-out reader.** Discuz!'s `ckfriend` refuses
/// every guest a blog with any privacy set before it looks at the password, so what a guest is
/// told is to sign in; the form is what a signed-in reader who is not its author is shown.
public enum DiscuzRefusal: Hashable, Sendable {
    /// The forum shows this only to readers who are signed in.
    case signIn
    /// A blog its author keeps behind a password: the form a signed-in reader is shown.
    case password
    /// A blog its author shows only to friends, to chosen readers, or to nobody else.
    case privateToAuthor
    /// Deleted, being moderated, or never there.
    case gone
    /// The forum has its blogs switched off.
    case blogsOff
    /// A thread, or its board, that asks more standing than this account has — a reading
    /// permission, or a group. `asked` is the forum's own sentence.
    case standing(asked: String)
    /// A board that asks conditions this account does not meet — points, as a rule. `asked` is
    /// the forum's own sentence, with what it asked and what this account has.
    case points(asked: String)
    /// A thread its author sells: `asked` is the forum's sentence naming the price.
    case price(asked: String)

    /// Whether signing in, or signing in as somebody else, could change this answer. Not a
    /// thread that is gone, and not a forum with its blogs switched off.
    public var signInMayChange: Bool {
        switch self {
        case .signIn, .password, .privateToAuthor, .standing, .points, .price: true
        case .gone, .blogsOff: false
        }
    }
}

/// Reads a Discuz! page for why it refused, where it did.
///
/// **The notice's words, where there is nothing else to read.** Discuz!'s notice page is one
/// sentence in a container — `div#messagetext` on the desktop template, `div.jump_c` on the touch
/// one — and the sentence is the only thing that says which refusal it is. So the notice is found
/// by its container, and read by the words of Discuz!'s own `lang_message`, in both of the
/// scripts it ships (`SC_UTF8` and `TC_UTF8`); a notice this does not know stays the plain
/// refusal it always was. **The two refusals that are pages rather than notices are anchored on
/// structure**: the password form on its action and its field, the privacy page on its link to
/// the author's friend list.
enum DiscuzRefusalReader {
    /// Whether this page is Discuz!'s notice page, on either template.
    static func isNotice(_ html: String) -> Bool {
        guard let patterns = Patterns.shared else { return false }
        return patterns.desktop.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) != nil
            || patterns.touch.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) != nil
    }

    /// Which refusal a notice page is, or nothing where its words are none this knows.
    static func refusal(inNotice html: String) -> DiscuzRefusal? {
        guard let said = notice(in: html) else { return nil }
        return refusal(said: said, offersSignIn: offersSignIn(html))
    }

    /// Which refusal a notice's own sentence is. The order is the rule: a feature switched off
    /// and a thing that is not there are facts no account changes, so they are asked first; a
    /// sign-in is asked before a permission, because `viewperm_login_nopermission` says both and
    /// signing in is the one that helps.
    static func refusal(said: String, offersSignIn: Bool = false) -> DiscuzRefusal? {
        func any(_ words: [String]) -> Bool { words.contains { said.contains($0) } }
        if any(["尚未开启", "尚未開啓", "尚未開啟"]) { return .blogsOff }
        if any(["不存在", "已被删除", "已被刪除", "没有找到", "沒有找到"]) { return .gone }
        if offersSignIn || any(["登录", "登錄", "登入", "游客", "遊客"]) { return .signIn }
        if any(["满足以下条件", "滿足以下條件"]) { return .points(asked: said) }
        if any(["权限", "權限", "用户组", "用戶組"]) { return .standing(asked: said) }
        return nil
    }

    /// The notice's own sentence, plain: what is in its container, up to the way back Discuz!
    /// writes under it. A notice about conditions breaks out of its own paragraph to list them
    /// (`forum_permforum_nopermission`), so the sentence is read to that way back and not to the
    /// container's close.
    static func notice(in html: String) -> String? {
        guard let patterns = Patterns.shared else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = patterns.desktop.firstMatch(in: html, range: range)
                ?? patterns.touch.firstMatch(in: html, range: range),
              let opened = Range(match.range, in: html)
        else { return nil }
        var rest = html[opened.upperBound...]
        for end in ["<script", "alert_btnleft", "id=\"messagelogin\"", "javascript:history.back"] {
            if let found = rest.range(of: end, options: .caseInsensitive) {
                rest = rest[..<found.lowerBound]
            }
        }
        // A way back cut through its own tag leaves `<a href="` behind, which is no words.
        if let open = rest.range(of: "<", options: .backwards),
           rest[open.lowerBound...].range(of: ">") == nil {
            rest = rest[..<open.lowerBound]
        }
        let said = Self.sentence(HTMLText.plain(String(rest)))
        return said.isEmpty ? nil : said
    }

    /// Whether the notice offers its own sign-in box — `div#messagelogin`, which Discuz! writes
    /// only for a signed-out reader of a notice that signing in would answer.
    static func offersSignIn(_ html: String) -> Bool {
        html.range(of: #"id\s*=\s*["']messagelogin["']"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Why a blog page with no blog on it refused — the two refusals that are pages of their own.
    ///
    /// - **The password form**: a form posting to `home.php?mod=misc&ac=inputpwd` with a
    ///   `viewpwd` field (`home/misc_inputpwd`).
    /// - **The privacy page**: a link to the author's friend list, `mod=space&uid=N&do=friend`,
    ///   with this author's number (`home/space_privacy`). The blog page's own header links the
    ///   reader's friend list, which names no one, and so is not it.
    static func blog(in html: String, uid: Int) -> DiscuzRefusal? {
        guard let patterns = Patterns.shared else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        if patterns.passwordForm.firstMatch(in: html, range: range) != nil,
           patterns.passwordField.firstMatch(in: html, range: range) != nil {
            return .password
        }
        for href in patterns.href.captures(1, in: html) {
            let href = href.replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
            if href.range(of: #"[?&]mod=space(?:&|$)"#, options: .regularExpression) != nil,
               href.range(of: #"[?&]uid=\#(uid)(?![0-9])"#, options: .regularExpression) != nil,
               href.range(of: #"[?&]do=friend(?:&|$)"#, options: .regularExpression) != nil {
                return .privateToAuthor
            }
        }
        return nil
    }

    /// A thread its author sells: the opening post's `<div class="locked">` holding a way to pay
    /// for **this** thread (`forum.php?mod=misc&action=pay&tid=N`). What the forum asked is the
    /// block's own sentence, the way to pay taken out — this app never pays.
    static func price(in html: String, tid: Int) -> DiscuzRefusal? {
        guard let patterns = Patterns.shared, let divs = DiscuzThreadPage.Patterns.shared?.divs
        else { return nil }
        for locked in DiscuzMarkup.extract(patterns.locked, nesting: divs, in: html).removed {
            let pays = patterns.href.captures(1, in: locked).contains { href in
                let href = href.replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
                return href.contains("action=pay")
                    && href.range(of: #"[?&]tid=\#(tid)(?![0-9])"#, options: .regularExpression) != nil
            }
            guard pays else { continue }
            let words = patterns.anchor.stringByReplacingMatches(
                in: locked, range: NSRange(locked.startIndex..., in: locked), withTemplate: ""
            )
            let asked = sentence(HTMLText.plain(words))
            return .price(asked: asked)
        }
        return nil
    }

    /// Plain words on one line, runs of space made one — a notice is laid out for a page, and
    /// what is kept of it is a sentence.
    private static func sentence(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Compiled once for the life of the process — `DiscuzPage.Patterns`' reason.
    struct Patterns: @unchecked Sendable {
        static let shared = Patterns()

        /// `<div id="messagetext">`, the desktop template's notice.
        let desktop: NSRegularExpression
        /// `<div class="jump_c">`, the touch template's.
        let touch: NSRegularExpression
        let passwordForm: NSRegularExpression
        let passwordField: NSRegularExpression
        let href: NSRegularExpression
        let locked: NSRegularExpression
        /// A whole `<a>` element, words and all.
        let anchor: NSRegularExpression

        init?() {
            let options: NSRegularExpression.Options = [.dotMatchesLineSeparators, .caseInsensitive]
            func compile(_ pattern: String) -> NSRegularExpression? {
                try? NSRegularExpression(pattern: pattern, options: options)
            }
            guard
                let desktop = compile("<div[^>]*\(DiscuzMarkup.attribute("id", "messagetext"))[^>]*>"),
                let touch = compile("<div[^>]*\(DiscuzMarkup.classed("jump_c"))[^>]*>"),
                let passwordForm = compile(#"<form\b[^>]*\baction\s*=\s*["'][^"']*ac=inputpwd[^"']*["'][^>]*>"#),
                let passwordField = compile(#"<input\b[^>]*\bname\s*=\s*["']viewpwd["'][^>]*>"#),
                let href = compile(#"\bhref\s*=\s*["']([^"']*)["']"#),
                let locked = compile("<div[^>]*\(DiscuzMarkup.classed("locked"))[^>]*>"),
                let anchor = compile(#"<a\b[^>]*>.*?</a>"#)
            else { return nil }
            self.desktop = desktop
            self.touch = touch
            self.passwordForm = passwordForm
            self.passwordField = passwordField
            self.href = href
            self.locked = locked
            self.anchor = anchor
        }
    }
}

/// What types a blog's password into the forum, from inside the forum's own signed-in browser
/// (#213) — the one script, run once per press, with the password a **bound argument** and never
/// spliced into its text (`ForumLoginScript`'s rule).
///
/// **Measured on the local X5.0.2**: the form `home/misc_inputpwd` draws posts `refer`, `blogid`,
/// `albumid`, `pwdsubmit` and `formhash` beside `viewpwd` to `home.php?mod=misc&ac=inputpwd`, whose
/// `submitcheck` wants the formhash and a referrer on the same host. The right password is
/// answered with a notice and a session cookie `…view_pwd_blog_N`, holding a hash of the password,
/// that opens the blog page; a wrong one with a notice and no cookie. So nothing is read out of the
/// answer: whether it opened is what the blog page says when it is read again.
///
/// **Only to the page's own origin, over `https`, and nowhere else.** The form's action is resolved
/// against the page and refused unless it is the page's origin; the post is a `fetch` from the
/// page, `credentials: same-origin` and `redirect: error`, so it carries this forum's cookies to
/// this forum and follows no redirect at all. It is sent from a content world the page's own
/// scripts cannot reach, and nothing of it is written into the page, so the forum's script sees
/// the password only as the forum's server does. Nothing leaves this script but a word.
public enum DiscuzBlogPasswordScript {
    public static let send = """
    const form = Array.from(document.querySelectorAll('form')).find(
        (f) => (f.getAttribute('action') || '').includes('ac=inputpwd')
    );
    if (!form) { return 'no-form'; }
    if (!form.querySelector('input[name="viewpwd"]')) { return 'no-field'; }
    const action = new URL(form.getAttribute('action') || '', location.href);
    if (location.protocol !== 'https:' || action.origin !== location.origin) { return 'elsewhere'; }
    const body = new URLSearchParams();
    for (const field of form.querySelectorAll('input[type="hidden"]')) {
        body.append(field.name, field.value);
    }
    body.set('viewpwd', password);
    const answer = await fetch(action.href, {
        method: 'POST', body: body, credentials: 'same-origin', redirect: 'error', cache: 'no-store'
    });
    return answer.ok ? 'sent' : 'refused';
    """

    /// The session cookie a right password is answered with, for the blog numbered `id`, with the
    /// forum's own prefix before it. Let go of once the blog is read, so nothing of the password
    /// stays on this device.
    public static func isUnlock(cookie name: String, blog id: Int) -> Bool {
        name.hasSuffix("view_pwd_blog_\(id)")
    }
}
