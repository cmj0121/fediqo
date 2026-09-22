import Foundation
import Testing

@testable import FediqoCore

/// Reading a forum's own sign-in page, and reading its answer.
///
/// **This page is written here, and that is a loss worth stating.** It used to be a live capture
/// of a Discuz! X3.4 sign-in page, and the whole point of that was the one thing markup written by
/// an author can never do: its `loginhash` and its `formhash` were in it because a real forum put
/// them there on the day it was fetched, not because the parser wanted them. The capture carried
/// a session's live tokens, so it is gone, and **the claim that this markup was not written to
/// match the parser is no longer true**. The tokens below are invented. What the page still does
/// honestly is hold the *shape* the parser has to survive: three forms rather than one, the login
/// form in the middle of them, all three carrying the same per-request `formhash`, the action
/// entity-escaped the way Discuz! writes it, and the security-question menu that every install
/// renders whether or not the member set one.
@Suite("Reading a forum's sign-in form")
struct ForumLoginFormTests {
    /// A signed-out Discuz! X3.4 sign-in page: a search form, then the login form, then the
    /// lost-password form. No verification code anywhere, and no `action=logout` anywhere.
    private var page: String {
        #"""
        <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
        <meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
        <title>登录 -  示例论坛 -  Powered by Discuz!</title>
        <meta name="generator" content="Discuz! X3.4" />
        <meta name="author" content="Discuz! Team and Comsenz UI Team" />
        <base href="" />
        </head>
        <body id="nv_member" class="pg_logging">
        <div id="scbar" class="cl">
        <form id="scbar_form" method="post" autocomplete="off" action="search.php?searchsubmit=yes" target="_blank">
        <input type="hidden" name="mod" id="scbar_mod" value="forum" />
        <input type="hidden" name="formhash" value="7c41ea90" />
        <input type="hidden" name="srchtype" value="title" />
        <input type="text" name="srchtxt" id="scbar_txt" value="请输入搜索内容" autocomplete="off" />
        <button type="submit" name="searchsubmit" id="scbar_btn" class="pn pnc" value="true"><strong class="xi2">搜索</strong></button>
        </form>
        </div>
        <div class="mn" id="main_message">
        <div id="layer_login_KQ8ZM">
        <h3 class="flb"><em id="returnmessage_KQ8ZM"></em><span></span></h3>
        <form method="post" autocomplete="off" name="login" id="loginform_KQ8ZM" class="cl" onsubmit="pwdclear = 1;ajaxpost('loginform_KQ8ZM', 'returnmessage_KQ8ZM', 'returnmessage_KQ8ZM', 'onerror');return false;" action="member.php?mod=logging&amp;action=login&amp;loginsubmit=yes&amp;loginhash=KQ8ZM">
        <div class="c cl">
        <input type="hidden" name="formhash" value="7c41ea90" />
        <input type="hidden" name="referer" value="https://install-e.example/./" />
        <div class="rfm"><table><tr>
        <th><span class="login_slct"><select name="loginfield" id="loginfield_KQ8ZM">
        <option value="username">用户名</option>
        <option value="uid">UID</option>
        <option value="email">Email</option>
        </select></span></th>
        <td><input type="text" name="username" id="username_KQ8ZM" autocomplete="off" size="30" class="px p_fre" tabindex="1" value="" /></td>
        <td class="tipcol"><a href="member.php?mod=register">立即注册</a></td>
        </tr></table></div>
        <div class="rfm"><table><tr>
        <th><label for="password3_KQ8ZM">密码:</label></th>
        <td><input type="password" id="password3_KQ8ZM" name="password" onfocus="clearpwd()" size="30" class="px p_fre" tabindex="1" /></td>
        </tr></table></div>
        <div class="rfm"><table><tr>
        <th>安全提问:</th>
        <td><select id="loginquestionid_KQ8ZM" name="questionid" onchange="if($('loginquestionid_KQ8ZM').value > 0) {$('loginanswer_row_KQ8ZM').style.display='';} else {$('loginanswer_row_KQ8ZM').style.display='none';}">
        <option value="0">安全提问(未设置请忽略)</option>
        <option value="1">母亲的名字</option>
        <option value="2">爷爷的名字</option>
        <option value="3">父亲出生的城市</option>
        <option value="4">您其中一位老师的名字</option>
        <option value="5">您个人计算机的型号</option>
        <option value="6">您最喜欢的餐馆名称</option>
        <option value="7">驾驶执照最后四位数字</option>
        </select></td>
        </tr></table></div>
        <div class="rfm" id="loginanswer_row_KQ8ZM" style="display:none"><table><tr>
        <th>答案:</th>
        <td><input type="text" name="answer" id="loginanswer_KQ8ZM" autocomplete="off" size="30" class="px p_fre" tabindex="1" /></td>
        </tr></table></div>
        <div class="rfm"><table><tr>
        <th></th>
        <td><label for="cookietime_KQ8ZM"><input type="checkbox" class="pc" name="cookietime" id="cookietime_KQ8ZM" tabindex="1" value="2592000" />自动登录</label></td>
        </tr></table></div>
        <div class="rfm mbw bw0"><table width="100%"><tr>
        <th>&nbsp;</th>
        <td><button class="pn pnc" type="submit" name="loginsubmit" value="true" tabindex="1"><strong>登录</strong></button></td>
        </tr></table></div>
        </div>
        </form>
        </div>
        <div id="layer_lostpw_KQ8ZM" style="display: none;">
        <h3 class="flb"><em id="returnmessage3_KQ8ZM">找回密码</em><span></span></h3>
        <form method="post" autocomplete="off" id="lostpwform_KQ8ZM" class="cl" onsubmit="ajaxpost('lostpwform_KQ8ZM', 'returnmessage3_KQ8ZM', 'returnmessage3_KQ8ZM', 'onerror');return false;" action="member.php?mod=lostpasswd&amp;lostpwsubmit=yes&amp;infloat=yes">
        <div class="c cl">
        <input type="hidden" name="formhash" value="7c41ea90" />
        <input type="hidden" name="handlekey" value="lostpwform" />
        <div class="rfm"><table><tr>
        <th><span class="rq">*</span><label for="lostpw_email">Email:</label></th>
        <td><input type="text" name="email" id="lostpw_email" size="30" value="" tabindex="1" class="px p_fre" /></td>
        </tr></table></div>
        <div class="rfm mbw bw0"><table><tr>
        <th></th>
        <td><button class="pn pnc" type="submit" name="lostpwsubmit" value="true" tabindex="100"><span>提交</span></button></td>
        </tr></table></div>
        </div>
        </form>
        </div>
        </div>
        <div id="ft" class="cl"><div class="wp"><div id="frt">
        <p>Powered by <strong><a href="https://www.discuz.net" target="_blank">Discuz!</a></strong> <em>X3.4</em></p>
        </div></div></div>
        </body>
        </html>
        """#
    }

    @Test("The page's two hashes are read, not assumed")
    func readsBothHashes() throws {
        // The two are in two different places and neither can be constructed from the other: the
        // `loginhash` is a per-page value inside the form's action, the `formhash` a per-request
        // value in a hidden field. A client that hard-coded either posts to a forum that refuses
        // it on every load but the first.
        let form = try #require(ForumLoginForm.read(page))
        #expect(form.formHash == "7c41ea90")
        #expect(form.loginHash == "KQ8ZM")
        #expect(form.formID == "loginform_KQ8ZM")
    }

    @Test("The action is decoded, so it posts somewhere rather than nowhere")
    func actionIsDecoded() throws {
        let form = try #require(ForumLoginForm.read(page))
        // Every Discuz! action arrives HTML-escaped. Left escaped, the whole query is one
        // parameter and the login silently posts to a URL the server has never heard of.
        #expect(page.contains("&amp;action=login"), "the page lost the entities this is about")
        #expect(!form.action.contains("&amp;"), "the action kept its entities")
        #expect(form.action == "member.php?mod=logging&action=login&loginsubmit=yes&loginhash=KQ8ZM")
    }

    @Test("The login form is picked out from the three forms on the page")
    func picksTheLoginFormNotTheOthers() throws {
        // The page also carries a search form — written first, so document order alone would
        // find the wrong one — and a lost-password form after it. Choosing by id prefix would
        // have found the right one here and the wrong one on a template that names them
        // differently; choosing by what the action does cannot.
        #expect(ForumLoginForm.tags(page, name: "form").count == 3, "the page lost a form")
        let form = try #require(ForumLoginForm.read(page))
        #expect(!form.action.contains("search.php"))
        #expect(!form.action.contains("lostpasswd"))
    }

    @Test("A page with no verification code can be filled by a saved password")
    func formCanFillItself() throws {
        let form = try #require(ForumLoginForm.read(page))
        #expect(!form.asksCaptcha)
        #expect(form.canFillItself)
    }

    /// The reason `canFillItself` does not consult the security-question menu.
    @Test("The question menu on every Discuz! page does not block an automatic sign-in")
    func questionMenuIsNotAQuestion() throws {
        // The page *has* the menu — seven options, defaulting to "ignore this if you have not
        // set one". Reading its presence as "this forum asks a security question" would refuse
        // to autofill every Discuz! in existence.
        #expect(page.contains("name=\"questionid\""), "the page lost the menu it is about")
        #expect(page.contains("<option value=\"0\">"), "the menu lost its no-question default")
        let form = try #require(ForumLoginForm.read(page))
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
        // A forum that is not a Discuz! at all, forms and everything: the search box on a
        // Discourse front page must not be read as somewhere to post a password.
        let otherForum = #"""
        <!DOCTYPE html>
        <html lang="en"><head><meta name="generator" content="Discourse 2026.9.0-latest"></head>
        <body class="crawler">
        <form action="/search" method="get"><input type="text" name="q" /></form>
        <div id="main-outlet"><h1>Latest topics</h1></div>
        </body></html>
        """#
        #expect(ForumLoginForm.read(otherForum) == nil)
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

    @Test("An anonymous sign-in page is not mistaken for a signed-in one")
    func anonymousPageIsNotSignedIn() {
        // The whole of the success test rests on this: a signed-out sign-in page carries no
        // `action=logout` anywhere, so the marker cannot be produced by a signed-out session.
        // That used to be checked against a live capture, and so was a statement about a real
        // install's template; the page below is written here, so what is left is the weaker
        // claim that the two markers are specific enough not to appear in the guest furniture a
        // Discuz! sign-in page carries — the guest navigation prompt, the register link, the
        // sign-in button that says the same word a logout link would.
        let anonymous = #"""
        <html><head><title>登录 -  示例论坛 -  Powered by Discuz!</title></head>
        <body id="nv_member" class="pg_logging">
        <div id="qmenu_menu"><div class="ptm pbw hm">请 <a href="javascript:;" onclick="lsSubmit()"><strong>登录</strong></a> 后使用快捷导航<br />没有帐号？<a href="member.php?mod=register">立即注册</a></div></div>
        <form method="post" name="login" id="loginform_KQ8ZM" action="member.php?mod=logging&amp;action=login&amp;loginsubmit=yes&amp;loginhash=KQ8ZM">
        <input type="hidden" name="formhash" value="7c41ea90" />
        <input type="text" name="username" /><input type="password" name="password" />
        <button type="submit" name="loginsubmit" value="true"><strong>登录</strong></button>
        </form>
        </body></html>
        """#
        #expect(!ForumMember.isSignedIn(anonymous), "a signed-out page read as signed in")
    }

    @Test("Only a member's auth cookie is a session; what a guest is handed is not", arguments: [
        ("x7Kq_2132_auth", true), ("auth", true),
        ("x7Kq_2132_saltkey", false), ("x7Kq_2132_lastvisit", false), ("x7Kq_2132_sid", false),
        ("cf_clearance", false), ("author", false), ("oauth", false),
    ])
    func sessionCookie(name: String, isSession: Bool) {
        #expect(ForumMember.isSessionCookie(named: name) == isSession)
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
        // forever, with nothing anywhere to say why. Discuz! ships in both.
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
        for script in [
            ForumLoginScript.fill, ForumLoginScript.readTyped, ForumLoginScript.document,
            ForumLoginScript.remember, ForumLoginScript.watchTyped,
        ] {
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

    /// #153's first cause: the reader's own sign-in never asked the forum to remember it.
    @Test("A login form is asked to remember the sign-in, and a box the reader touched is theirs")
    func theReadersSignInIsRemembered() {
        let remember = ForumLoginScript.remember
        #expect(remember.contains("input[name=\"cookietime\"]"))
        #expect(remember.contains("keep.checked = true"))
        #expect(remember.contains("fediqoTouched"), "a box the reader unticked would be ticked again")
        // It reads no field and hands nothing anywhere.
        #expect(!remember.contains("password"))
        #expect(!remember.contains("postMessage"))
    }

    @Test("What was typed is handed over at the moment it is submitted, and only to the one handler")
    func typedIsHandedOverOnSubmit() {
        let watch = ForumLoginScript.watchTyped
        #expect(watch.contains("addEventListener('submit'"))
        #expect(watch.contains("messageHandlers.fediqoTyped"))
        #expect(watch.contains(ForumLoginScript.typedMessage))
        // Nothing half-typed is handed over: an empty field is not a credential.
        #expect(watch.contains("!user.value || !pass.value"))
    }
}
