import Foundation
import Testing

@testable import FediqoCore

/// Reading a forum's own sign-in page, and reading its answer.
///
/// The page fixture is a **live capture** — `install-e.example/member.php?mod=logging&action=login`,
/// Discuz! X3.4 — rather than markup written to match the parser. A fixture an author wrote is a
/// fixture that describes the world the author already believed in, which is the first of the two
/// conventions this branch earned; this one had a `loginhash` of `KQ8ZM` and a `formhash` of
/// `7c41ea90` because a real forum put them there on the day it was fetched.
@Suite("Reading a forum's sign-in form")
struct ForumLoginFormTests {
    private var live: String { String(data: Fixtures.html("discuz-login"), encoding: .utf8)! }

    @Test("The live page's two hashes are read, not assumed")
    func readsBothHashes() throws {
        let form = try #require(ForumLoginForm.read(live))
        #expect(form.formHash == "7c41ea90")
        #expect(form.loginHash == "KQ8ZM")
        #expect(form.formID == "loginform_KQ8ZM")
    }

    @Test("The action is decoded, so it posts somewhere rather than nowhere")
    func actionIsDecoded() throws {
        let form = try #require(ForumLoginForm.read(live))
        // Every Discuz! action arrives HTML-escaped. Left escaped, the whole query is one
        // parameter and the login silently posts to a URL the server has never heard of.
        #expect(!form.action.contains("&amp;"), "the action kept its entities")
        #expect(form.action == "member.php?mod=logging&action=login&loginsubmit=yes&loginhash=KQ8ZM")
    }

    @Test("The login form is picked out from the three forms on the page")
    func picksTheLoginFormNotTheOthers() throws {
        // The live page also carries a search form and a lost-password form. Choosing by id
        // prefix would have found the right one here and the wrong one on a template that names
        // them differently; choosing by what the action does cannot.
        let form = try #require(ForumLoginForm.read(live))
        #expect(!form.action.contains("search.php"))
        #expect(!form.action.contains("lostpasswd"))
    }

    @Test("A live page with no verification code can be filled by a saved password")
    func liveFormCanFillItself() throws {
        let form = try #require(ForumLoginForm.read(live))
        #expect(!form.asksCaptcha)
        #expect(form.canFillItself)
    }

    /// The reason `canFillItself` does not consult the security-question menu.
    @Test("The question menu on every Discuz! page does not block an automatic sign-in")
    func questionMenuIsNotAQuestion() throws {
        // The live fixture *has* the menu — seven options, defaulting to "ignore this if you
        // have not set one". Reading its presence as "this forum asks a security question" would
        // refuse to autofill every Discuz! in existence.
        #expect(live.contains("name=\"questionid\""), "the fixture lost the menu it is about")
        let form = try #require(ForumLoginForm.read(live))
        #expect(form.canFillItself, "the menu every page carries was read as a question")
    }

    @Test("A page already asking for a verification code cannot be filled")
    func captchaBlocksFilling() {
        let html = """
        <form action="member.php?mod=logging&amp;action=login&amp;loginsubmit=yes&amp;loginhash=Lz1">
        <input type="hidden" name="formhash" value="abc12345" />
        <input type="text" name="username" /><input type="password" name="password" />
        <input type="text" name="seccodeverify" id="seccodeverify_z1" />
        </form>
        """
        let form = ForumLoginForm.read(html)
        #expect(form?.asksCaptcha == true)
        #expect(form?.canFillItself == false)
    }

    @Test("A page with no formhash cannot be filled, because the post would be refused")
    func noFormHashCannotFill() {
        let html = """
        <form action="member.php?mod=logging&amp;action=login&amp;loginsubmit=yes">
        <input type="text" name="username" /><input type="password" name="password" />
        </form>
        """
        let form = ForumLoginForm.read(html)
        #expect(form?.formHash == nil)
        #expect(form?.canFillItself == false)
    }

    @Test("A page with no login form at all is nothing, not an empty one")
    func noFormIsNil() {
        #expect(ForumLoginForm.read("<html><body>the forum</body></html>") == nil)
        #expect(ForumLoginForm.read(String(data: Fixtures.html("discourse"), encoding: .utf8)!) == nil)
    }

    @Test("A loginhash stops where the query does")
    func loginHashStopsAtTheDelimiter() {
        #expect(ForumLoginForm.value(of: "loginhash", in: "a=1&loginhash=LX9&b=2") == "LX9")
        #expect(ForumLoginForm.value(of: "loginhash", in: "a=1&loginhash=LX9") == "LX9")
        #expect(ForumLoginForm.value(of: "loginhash", in: "a=1") == nil)
        #expect(ForumLoginForm.value(of: "loginhash", in: "a=1&loginhash=") == nil)
    }
}

/// What the forum said about an attempt, and what is done about each answer.
@Suite("Reading a forum's answer to a sign-in")
struct ForumLoginVerdictTests {
    @Test("A logout link carrying a formhash is what signed-in looks like")
    func logoutLinkIsSuccess() {
        let page = """
        <html><body><a href="member.php?mod=logging&amp;action=logout&amp;formhash=7c41ea90">Log out</a>
        </body></html>
        """
        #expect(ForumLoginVerdict.read(page) == .signedIn)
        #expect(ForumMember.isSignedIn(page))
    }

    @Test("The live anonymous page is not mistaken for a signed-in one")
    func anonymousPageIsNotSignedIn() {
        // The whole of the success test rests on this: the live sign-in page carries no
        // `action=logout` anywhere, so the marker cannot be produced by a signed-out session.
        let live = String(data: Fixtures.html("discuz-login"), encoding: .utf8)!
        #expect(!ForumMember.isSignedIn(live), "a signed-out page read as signed in")
    }

    @Test("Nothing at all is unreadable, and unreadable shows the reader the page")
    func silenceIsNotSuccess() {
        // The single most important line in this suite. An empty answer, a dropped connection's
        // half page and a challenge that came back all land here, and every one of them is a
        // reader who must be shown the forum rather than told they are signed in.
        #expect(ForumLoginVerdict.read("<html><body></body></html>") == .unreadable)
        #expect(ForumLoginVerdict.read("") == .unreadable)
    }

    @Test("A refusal is reported with the forum's own sentence where it sent one")
    func refusalCarriesTheMessage() {
        let page = "<script>errorhandle_login('登录失败，您还可以尝试 4 次', {})</script>"
        #expect(ForumLoginVerdict.read(page) == .refused("登录失败，您还可以尝试 4 次"))
    }

    @Test("A refusal with no readable sentence is still a refusal")
    func refusalWithoutMessage() {
        #expect(ForumLoginVerdict.read("<div class=\"alert_error\"></div>") == .refused(nil))
    }

    @Test("A verification code and a security question are each their own answer")
    func captchaAndQuestionAreDistinct() {
        #expect(ForumLoginVerdict.read("<p>请输入验证码</p>") == .needsCaptcha)
        #expect(ForumLoginVerdict.read("<p>請輸入驗證碼</p>") == .needsCaptcha)
        #expect(ForumLoginVerdict.read("<p>Please enter the verification code</p>") == .needsCaptcha)
        #expect(ForumLoginVerdict.read("<p>请回答安全提问</p>") == .needsQuestion)
        #expect(ForumLoginVerdict.read("<p>請回答安全提問</p>") == .needsQuestion)
        #expect(ForumLoginVerdict.read("<p>Answer your security question</p>") == .needsQuestion)
    }

    /// The markers are the promise; the harness is what stops the promise shrinking.
    @Test("Every marker in every script produces the verdict it was listed for")
    func everyMarkerCarriesItsVerdict() {
        for marker in ForumMarkers.captcha {
            #expect(ForumLoginVerdict.read("<p>\(marker)</p>") == .needsCaptcha,
                    "\(marker) did not ask for a code")
        }
        for marker in ForumMarkers.question {
            #expect(ForumLoginVerdict.read("<p>\(marker)</p>") == .needsQuestion,
                    "\(marker) did not ask a question")
        }
        for marker in ForumMarkers.signedIn {
            #expect(ForumLoginVerdict.read("<p>\(marker)</p>") == .signedIn,
                    "\(marker) did not read as signed in")
        }
        for marker in ForumMarkers.refusal {
            // `succeedhandle_login` is not in this list and must not be: a refusal marker that
            // also matched a success marker would make the order of the switch the whole answer.
            if case .refused = ForumLoginVerdict.read("<p>\(marker)</p>") { continue }
            Issue.record("\(marker) did not read as a refusal")
        }
    }

    @Test("Both Chinese scripts reach the same verdict, because one install serves either")
    func bothScriptsAreCovered() {
        // A marker list with one script in it is a reader shown a web view on every attempt,
        // forever, with nothing anywhere to say why. The reader's own forum is Traditional.
        #expect(ForumLoginVerdict.read("<p>密码错误</p>") == ForumLoginVerdict.read("<p>密碼錯誤</p>"))
        #expect(ForumLoginVerdict.read("<p>登录失败</p>") == ForumLoginVerdict.read("<p>登錄失敗</p>"))
    }

    @Test("A code being asked for outranks a logout link that is also on the page")
    func mostSpecificInstructionWins() {
        let both = """
        <html><body><a href="member.php?mod=logging&amp;action=logout&amp;formhash=x">Log out</a>
        <p>请输入验证码</p></body></html>
        """
        #expect(ForumLoginVerdict.read(both) == .needsCaptcha)
    }

    @Test("A forum's own sentence is bounded before it is put on one line")
    func messageIsBounded() {
        let long = String(repeating: "x", count: 900)
        guard case .refused(let said) = ForumLoginVerdict.read("<script>errorhandle_login('\(long)', {})</script>")
        else {
            Issue.record("a long message stopped being a refusal")
            return
        }
        #expect((said?.count ?? 0) <= 200, "a forum could write the whole sheet")
        #expect((said?.count ?? 0) > 0)
    }
}

/// The scripts the web view runs, and the one property that matters about them.
@Suite("The sign-in scripts")
struct ForumLoginScriptTests {
    /// The single most load-bearing property in this unit.
    @Test("No script contains a place for a secret to be spliced into")
    func nothingIsInterpolated() {
        for script in [ForumLoginScript.fill, ForumLoginScript.readTyped, ForumLoginScript.document] {
            #expect(!script.contains("\\("), "a script interpolates, so a password could reach its text")
        }
        // The fill script names its inputs as bound parameters, which is what makes a password
        // containing a quote or a backslash data rather than code on the forum's own origin.
        #expect(ForumLoginScript.fill.contains("user.value = username"))
        #expect(ForumLoginScript.fill.contains("pass.value = password"))
    }

    @Test("The fill script cannot be shadowed out of submitting")
    func submitCannotBeShadowed() {
        // `form.submit()` throws on any form containing a control named `submit`, which is
        // markup this code does not control.
        #expect(ForumLoginScript.fill.contains("HTMLFormElement.prototype.submit.call(form)"))
        #expect(!ForumLoginScript.fill.contains("form.submit()"))
    }

    @Test("The fill script strips the ajax flag, so the answer is a page and not a blob")
    func ajaxIsStripped() {
        #expect(ForumLoginScript.fill.contains("inajax"))
    }

    @Test("Each script says what it did rather than leaving the caller to guess")
    func scriptsReportThemselves() {
        for answer in ["'no-form'", "'no-fields'", "'submitted'"] {
            #expect(ForumLoginScript.fill.contains(answer), "\(answer) is not an answer it can give")
        }
    }
}
