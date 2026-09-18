import Foundation

/// The sign-in form a forum is offering, read off the live page.
///
/// **Read, never assumed.** Discuz! puts a per-request `formhash` in a hidden field and a
/// per-page `loginhash` in the form's action, and refuses a post carrying neither — so a client
/// that hard-codes an action URL works once, on the machine it was written on, and then never
/// again. Measured on `install-e.example` (Discuz! X3.4): the action is
/// `member.php?mod=logging&action=login&loginsubmit=yes&loginhash=<five characters>` and the
/// hidden field is `formhash` = `<eight hex digits>`, both of which change on every load. The
/// shapes are the measurement; the values that were here were one forum's, on one morning, and
/// are not this repository's to keep.
///
/// This type does not build a request out of any of it. The post is made by the web view, by
/// submitting the form the reader's own engine loaded — see `ForumLoginScript`. What is read
/// here is what has to be **decided** before that: whether this page can be filled in at all.
public struct ForumLoginForm: Sendable, Equatable {
    /// The element id, e.g. `loginform_KQ8ZM`. Empty where the form has none.
    public let formID: String
    /// The action exactly as the page wrote it, entity-decoded.
    public let action: String
    /// The per-page token out of the action, where there was one.
    public let loginHash: String?
    /// The per-request token out of the hidden field, where there was one.
    public let formHash: String?
    /// The page is already asking for a verification code, so no saved credential can answer it.
    public let asksCaptcha: Bool

    public init(
        formID: String,
        action: String,
        loginHash: String? = nil,
        formHash: String? = nil,
        asksCaptcha: Bool = false
    ) {
        self.formID = formID
        self.action = action
        self.loginHash = loginHash
        self.formHash = formHash
        self.asksCaptcha = asksCaptcha
    }

    /// Whether a saved username and password could be typed into this page and posted.
    ///
    /// **A security question is deliberately not consulted here, and that is not an omission.**
    /// Discuz! renders the question menu on *every* login page, whether or not the member set
    /// one: its first option is `value="0"`, "ignore this if you have not set one" — measured on
    /// a live forum. So the menu's presence says nothing about this reader, and a client that
    /// read it as "this forum asks a security question" would refuse to autofill every Discuz!
    /// in the world. Whether a question is actually required is a fact about the **account**,
    /// and the only place it is ever stated is the answer to an attempt. See
    /// `ForumLoginVerdict.needsQuestion`.
    public var canFillItself: Bool {
        !asksCaptcha && formHash != nil && !action.isEmpty
    }

    /// The login form on this page, or nothing where there is none to fill.
    ///
    /// Picks the form by what it *does* — an action that posts a login — rather than by its id,
    /// because the id carries the per-page hash and a page carries several forms (search, lost
    /// password, login) that a looser match would confuse.
    public static func read(_ html: String) -> ForumLoginForm? {
        for tag in tags(html, name: "form") {
            let action = decode(attribute("action", in: tag) ?? "")
            guard action.contains("action=login"), action.contains("loginsubmit") else { continue }
            let id = attribute("id", in: tag) ?? ""
            return ForumLoginForm(
                formID: id,
                action: action,
                loginHash: value(of: "loginhash", in: action),
                formHash: hiddenFormHash(html),
                asksCaptcha: asksCaptcha(html)
            )
        }
        return nil
    }

    /// Discuz! writes `formhash` into a hidden input on every form on the page and they all
    /// carry the same value for one request, so the first is the right one.
    static func hiddenFormHash(_ html: String) -> String? {
        for tag in tags(html, name: "input")
        where attribute("name", in: tag)?.lowercased() == "formhash" {
            if let value = attribute("value", in: tag), !value.isEmpty { return value }
        }
        return nil
    }

    /// Markers for a verification code already on the page. `seccodeverify` is the field
    /// Discuz! posts it in and `seccode` names the image's own endpoint; either means the form
    /// in front of us is asking for something no stored secret contains.
    static func asksCaptcha(_ html: String) -> Bool {
        html.contains("seccodeverify")
            || html.contains("mod=seccode")
            || html.contains("name=\"seccodeverify\"")
    }

    static func value(of key: String, in query: String) -> String? {
        guard let range = query.range(of: "\(key)=") else { return nil }
        let rest = query[range.upperBound...]
        let stop = rest.firstIndex { $0 == "&" || $0 == "\"" || $0 == "'" }
        let found = String(rest[..<(stop ?? rest.endIndex)])
        return found.isEmpty ? nil : found
    }

    /// Every `<name …>` opening tag in the document, as raw text. A regular expression rather
    /// than a parser because what is wanted is three attributes off a handful of tags, and this
    /// package has no HTML parser and is not getting one for this.
    static func tags(_ html: String, name: String) -> [String] {
        let pattern = "<\(name)\\b[^>]*>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, range: range).compactMap {
            Range($0.range, in: html).map { String(html[$0]) }
        }
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = "\\b\(escaped)\\s*=\\s*[\"']([^\"']*)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: tag)
        else { return nil }
        return String(tag[range])
    }

    /// The five entities an action URL can actually carry. `&amp;` is the one that matters —
    /// every Discuz! action arrives with it and a URL left holding it posts to nowhere.
    static func decode(_ text: String) -> String {
        var out = text
        for (entity, character) in [
            ("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"),
        ] {
            out = out.replacingOccurrences(of: entity, with: character)
        }
        return out
    }
}

/// What the forum said about an attempt to sign in.
///
/// **Success is a thing the page says, not the absence of a thing it did not say.** A wrong
/// password, a challenge that came back, a session that timed out and a network that dropped all
/// produce a page with no error text this code knows; read as "no error, therefore signed in",
/// every one of them becomes a reader staring at an empty forum with no way to find out why. So
/// the only verdict that lets an automatic sign-in be called finished is a **positive** marker,
/// and everything else — including a page this code cannot read at all — ends with the reader
/// being shown the forum's own page. That is D24 in one type: a sign-in that can only succeed
/// silently is a sign-in that strands the reader on the day it cannot.
public enum ForumLoginVerdict: Sendable, Equatable {
    /// The page came back showing a signed-in member.
    case signedIn
    /// The forum said no, with its own words where it gave any.
    case refused(String?)
    /// A verification code is now required — too many attempts, usually.
    case needsCaptcha
    /// This account has a security question, which no stored password answers.
    case needsQuestion
    /// Nothing here says either way. Show the reader the page.
    case unreadable

    public static func read(_ html: String) -> ForumLoginVerdict {
        // Order matters and it is not alphabetical. A page can carry both an error and a logout
        // link (an error shown in the header of an already-signed-in session), and the question
        // and captcha cases are refusals with something specific to do about them — so the most
        // specific instruction the page gives is the one to act on, and plain signed-in is
        // checked only once the page has asked for nothing.
        if asks(html, ForumMarkers.captcha) { return .needsCaptcha }
        if asks(html, ForumMarkers.question) { return .needsQuestion }
        if ForumMember.isSignedIn(html) { return .signedIn }
        if asks(html, ForumMarkers.refusal) { return .refused(message(html)) }
        return .unreadable
    }

    private static func asks(_ html: String, _ markers: [String]) -> Bool {
        markers.contains { html.localizedCaseInsensitiveContains($0) }
    }

    /// The forum's own sentence, where it put one somewhere this can find it. Truncated,
    /// because it is going on one line of a sheet and a forum is free to send an essay.
    static func message(_ html: String) -> String? {
        for pattern in [
            "errorhandle_login\\(\\s*'([^']*)'",
            "<div[^>]*class=\"alert_error\"[^>]*>\\s*<p>([^<]*)</p>",
        ] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: html)
            else { continue }
            let text = ForumLoginForm.decode(String(html[range]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return String(text.prefix(200)) }
        }
        return nil
    }
}

/// The phrases each verdict is read from.
///
/// **Both scripts, and English too.** Discuz! ships in Simplified and Traditional Chinese and in
/// English, and one install may serve any of them — `install-e.example` answers in Simplified and
/// the reader's own forum is Traditional. A marker list with one script in it is a marker list
/// that reads a Traditional forum as `unreadable` on every attempt, which is not a crash and not
/// a wrong answer: it is a reader shown a web view every single time, forever, with nobody able
/// to say why. Gathered here rather than spread through the switch so that adding a language is
/// one edit in one place.
enum ForumMarkers {
    static let captcha = [
        "seccodeverify",
        "验证码",      // Simplified: verification code
        "驗證碼",      // Traditional
        "verification code",
    ]

    static let question = [
        "安全提问",    // Simplified: security question
        "安全提問",    // Traditional
        "security question",
    ]

    static let refusal = [
        "errorhandle_login",
        "login_error",
        "alert_error",
        "登录失败",    // Simplified: sign-in failed
        "登錄失敗",    // Traditional
        "密码错误",    // Simplified: wrong password
        "密碼錯誤",    // Traditional
        "用户名不存在",
        "用戶名不存在",
        "incorrect username or password",
    ]

    /// What only a signed-in page carries.
    ///
    /// A logout link with a `formhash` on it is the strongest marker Discuz! has: the hash is
    /// per-session and the link is rendered only for a member, so a signed-out page cannot
    /// produce one — checked against a live anonymous login page, which carries no `action=logout`
    /// anywhere at all.
    static let signedIn = [
        "action=logout",
        "succeedhandle_login",
    ]
}

public enum ForumMember {
    /// Whether this page is being shown to somebody who is signed in.
    ///
    /// Used twice and for two different questions, which is why it is not folded into the
    /// verdict: once to read the answer to an attempt, and once on an **ordinary fetched page**,
    /// to notice that a session has quietly expired mid-scroll. The second is the one that makes
    /// it worth a public name — a forum whose session has lapsed does not send an error, it
    /// sends the guest's version of the page, and nothing else in this project would tell the
    /// difference between that and a board the reader is allowed to see.
    public static func isSignedIn(_ html: String) -> Bool {
        ForumMarkers.signedIn.contains { html.contains($0) }
    }

    /// Whether a cookie by this name is a member's session, as opposed to what any visitor is
    /// handed.
    ///
    /// **Not "holds a cookie".** Discuz! sets `<prefix>_saltkey`, `_lastvisit` and `_sid` on a
    /// guest's first page, and a challenged host adds `cf_clearance`, so every forum this app
    /// has merely read holds cookies. Only a sign-in writes `<prefix>_auth` — the prefix is the
    /// site's own and is not known in advance, which is why this reads the suffix.
    public static func isSessionCookie(named name: String) -> Bool {
        name == "auth" || name.hasSuffix("_auth")
    }
}

/// The JavaScript the web view runs on the forum's own login page.
///
/// **The password is never in this text.** Every script here is a body for
/// `callAsyncJavaScript(_:arguments:)`, whose arguments arrive as real parameters bound by
/// WebKit rather than as text spliced into source. That is not tidiness: a password containing
/// a quote or a backslash would either break a spliced script or, worse, close the string and
/// run as code on the forum's own origin, with the reader's session. It also means the secret
/// never exists as a Swift string that some future `print` of "the script we ran" could spill —
/// which is the failure mode this unit is least allowed to have.
public enum ForumLoginScript {
    /// Fills the login form and posts it, returning what it did.
    ///
    /// **`HTMLFormElement.prototype.submit.call`, not `form.submit()`.** A form element exposes
    /// its own named controls as properties, so a form containing anything named `submit`
    /// shadows the method and `form.submit()` throws "not a function". Calling the prototype's
    /// method against the element cannot be shadowed by markup this code does not control.
    ///
    /// Submitting this way also deliberately **skips the form's `onsubmit`**, which on Discuz!
    /// is `ajaxpost(...); return false` — that handler posts with `inajax=1` and gets back an
    /// XML blob meant for Discuz!'s own JavaScript, which the reader would see as raw markup and
    /// this code would have to parse a second format to read. A plain submit posts to the same
    /// action and gets an ordinary page, which is the one thing both the reader and
    /// `ForumLoginVerdict` can already read. `inajax` is stripped from the action as well, for
    /// the install that puts it there rather than appending it in script.
    public static let fill = """
    const form = Array.from(document.querySelectorAll('form')).find(
        (f) => (f.getAttribute('action') || '').includes('action=login')
            && (f.getAttribute('action') || '').includes('loginsubmit')
    );
    if (!form) { return 'no-form'; }
    const user = form.querySelector('input[name="username"]');
    const pass = form.querySelector('input[name="password"]');
    if (!user || !pass) { return 'no-fields'; }
    user.value = username;
    pass.value = password;
    const keep = form.querySelector('input[name="cookietime"]');
    if (keep && keep.type === 'checkbox') { keep.checked = true; }
    const action = form.getAttribute('action') || '';
    form.setAttribute('action', action.replace(/[?&]inajax=1/, ''));
    HTMLFormElement.prototype.submit.call(form);
    return 'submitted';
    """

    /// Reads back what the reader typed into the forum's own form, for the reader who asked for
    /// it to be saved.
    ///
    /// **Run only when they have opted in.** This is the line where D23's honest sentence stops
    /// being true, so it is one script, called from one place, guarded by one flag — and not, for
    /// instance, a field this app reads on every keystroke and happens not to store. Returns the
    /// empty string for either field it cannot find, so the caller saves nothing rather than
    /// saving half a credential.
    public static let readTyped = """
    const form = Array.from(document.querySelectorAll('form')).find(
        (f) => (f.getAttribute('action') || '').includes('action=login')
            && (f.getAttribute('action') || '').includes('loginsubmit')
    );
    if (!form) { return null; }
    const user = form.querySelector('input[name="username"]');
    const pass = form.querySelector('input[name="password"]');
    return { username: (user && user.value) || '', password: (pass && pass.value) || '' };
    """

    /// The whole document, which is what every read in this unit starts from.
    public static let document = "document.documentElement.outerHTML"
}
