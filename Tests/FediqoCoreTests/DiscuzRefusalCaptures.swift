import Foundation

/// Discuz! refusals **as a real install served them** (#213) — the local X5.0.2 that
/// `servers/compose.yml` brings up, installed by `servers/discuz/seed.sh`, with blogs and friends
/// switched on, a second member (新手上路, not the author's friend) registered, and blogs and
/// threads seeded by `admin` for each refusal. Fetched with `curl` on 2026-09-24, signed out and
/// as that member.
///
/// **Trimmed, not edited.** Each is the region that says why, cut out of its page; a `formhash`
/// is zeroed and the loopback address the capture wrote is `discuz.localhost`. Every tag, class
/// and line break kept is the server's. The signed-out blog notice, the missing blog and blogs
/// switched off are `DiscuzBlogCaptures`'.
enum DiscuzRefusalCaptures {
    /// `home.php?mod=space&uid=1&do=blog&id=3` as a signed-in member who is nobody's friend: the
    /// privacy page (`home/space_privacy`), served **the same** for a blog only its author may
    /// read, one for friends only (`id=2`) and one for chosen readers (`id=5`) — byte for byte but
    /// the page's own address. The author's activity and credit lists are cut.
    static let privacy = #"""
    <div id="pt" class="bm cl">
    <div class="z">
    <a href="./" class="nvhm" title="首页">Discuz!</a> <em>&rsaquo;</em>
    <a href="home.php"></a> <em>&rsaquo;</em>
    隐私提醒
    </div>
    </div>
    <div id="ct" class="wp cl">
    <div class="nfl">
    <div class="f_c mtw mbw">
    <table cellpadding="0" cellspacing="0" width="100%" style="table-layout: fixed;">
    <tr>
    <td valign="top" width="140" class="hm">
    <div class="avt avtm"><a href="home.php?mod=space&amp;uid=1"><img data-src="./data/avatar/noavatar.svg" class="_avt user_avatar"></a></div>
    <p class="mtm xw1 xi2 xs2"><a href="home.php?mod=space&amp;uid=1">admin</a></p>
    </td>
    <td width="14"></td>
    <td valign="top" class="xs1">
    <h2 class="xs2">
    抱歉！由于 admin 的隐私设置，您不能访问当前内容
    </h2>
    <p class="mtm mbm">
    <a href="home.php?mod=space&amp;uid=1&amp;do=friend">查看好友列表</a>
    <span class="pipe">|</span><a href="home.php?mod=spacecp&amp;ac=friend&amp;op=add&amp;uid=1&amp;handlekey=addfriendhk_1" id="a_friend" onclick="showWindow(this.id, this.href, 'get', 0);">加为好友</a>
    <span class="pipe">|</span><a href="home.php?mod=spacecp&amp;ac=poke&amp;op=send&amp;uid=1&amp;handlekey=propokehk_1" id="a_poke" onclick="showWindow(this.id, this.href, 'get', 0);">打个招呼</a>
    <span class="pipe">|</span><a href="home.php?mod=spacecp&amp;ac=pm&amp;op=showmsg&amp;handlekey=showmsg_1&amp;touid=1&amp;pmid=0&amp;daterange=4" id="a_pm" onclick="showWindow(this.id, this.href, 'get', 0);">发送消息</a>
    <!--span class="pipe">|</span><a href="home.php?mod=spacecp&amp;ac=common&amp;op=report&amp;idtype=uid&amp;id=1&amp;handlekey=reportbloghk_1" id="a_report" onclick="showWindow(this.id, this.href, 'get', 0);">举报</a-->
    </p>

    <p class="mtw xg1">请加入到我的好友中，您就可以了解我的近况，与我一起交流，随时与我保持联系 </p>
    <p class="mtm cl"><a href="home.php?mod=spacecp&amp;ac=friend&amp;op=add&amp;uid=1" id="add_friend" onclick="showWindow(this.id, this.href, 'get', 0);" class="pn z" style="text-decoration: none;"><strong class="z">加为好友</strong></a></p>
    </td>
    </tr>
    </table>
    </div>
    </div>
    </div>
    """#

    /// `…&id=4`, a blog behind its author's password, as a signed-in member who is not its author:
    /// the password form (`home/misc_inputpwd`), its `formhash` zeroed.
    static let password = #"""
    <div id="pt" class="bm cl">
    <div class="z"><a href="./" class="nvhm" title="首页">Discuz!</a> <em>&rsaquo;</em> <a href="home.php"></a></div>
    </div>

    <div id="ct" class="ct2_a wp cl">
    <div class="mn">
    <div class="bm bw0" style="margin: 70px 0 0 150px;">
    <h1 class="mt">密码验证</h1>
    <form method="post" autocomplete="off"  id="invalueform" name="invalueform" action="home.php?mod=misc&amp;ac=inputpwd" >
    <input type="hidden" name="refer" value="/home.php?mod=space&uid=1&do=blog&id=4" />
    <input type="hidden" name="blogid" value="4" />
    <input type="hidden" name="albumid" value="" />
    <input type="hidden" name="pwdsubmit" value="true" />
    <input type="hidden" name="formhash" value="00000000" />
    <div class="c mbn">
    您需要正确输入密码后才能继续查看： <br />
    <input type="password" name="viewpwd" value="" class="px mtn" />
    </div>
    <p class="o pns">
    <button type="submit" name="submit" value="true" class="pn pnc"><strong>提交</strong></button>
    </p>
    </form>
    """#

    /// What `home.php?mod=misc&ac=inputpwd` answers a wrong password with: a notice, no cookie.
    static let wrongPassword = #"""
    <div id="messagetext" class="alert_info">
    <p>抱歉，您输入的网站登录密码不正确<script type="text/javascript" reload="1">setTimeout("window.location.href ='home.php?mod=space&uid=1&do=blog&id=4';", 2000);</script></p>
    <p class="alert_btnleft"><a href="home.php?mod=space&uid=1&do=blog&id=4">如果您的浏览器没有自动跳转，请点击此链接</a></p>
    </div>
    """#

    /// What it answers the right one with: a notice, and `Set-Cookie: …view_pwd_blog_4=<md5 of
    /// md5 of the password>; path=/; secure` — a session cookie — after which the blog page reads.
    static let rightPassword = #"""
    <div id="messagetext" class="alert_info">
    <p>验证成功，现在进入查看页面<script type="text/javascript" reload="1">setTimeout("window.location.href ='home.php?mod=space&uid=1&do=blog&id=4';", 2000);</script></p>
    <p class="alert_btnleft"><a href="home.php?mod=space&uid=1&do=blog&id=4">如果您的浏览器没有自动跳转，请点击此链接</a></p>
    </div>
    """#

    /// `forum.php?mod=viewthread&tid=2&mobile=2`, a thread with reading permission 200, as a
    /// member of 新手上路 (reading permission 10): the touch template's notice, `div.jump_c`, at
    /// 200. Signed out the same address is a 302 to the sign-in page.
    static let threadStanding = #"""
    <div class="jump_c">
    <div>抱歉，本帖要求阅读权限高于 200 才能浏览</div>
    <div><a href="javascript:history.back();" class="grey">[ 点击这里返回上一页 ]</a></div>
    </div>
    """#

    /// The same thread without `mobile=2`: the desktop template's notice, `div#messagetext`.
    static let threadStandingDesktop = #"""
    <div id="messagetext" class="alert_error">
    <p>抱歉，本帖要求阅读权限高于 200 才能浏览</p>
    <script type="text/javascript">
    if(history.length > (BROWSER.ie ? 0 : 1)) {
    document.write('<p class="alert_btnleft"><a href="javascript:history.back()">[ 点击这里返回上一页 ]</a></p>');
    } else {
    document.write('<p class="alert_btnleft"><a href="./">[ Discuz! 首页 ]</a></p>');
    }
    </script>
    """#

    /// `…tid=4&mobile=2`, a thread in the recycle bin: **404**, and the notice saying so.
    static let threadGone = #"""
    <div class="jump_c">
    <div>抱歉，指定的主题不存在或已被删除或正在被审核</div>
    <div><a href="javascript:history.back();" class="grey">[ 点击这里返回上一页 ]</a></div>
    </div>
    """#

    /// `…tid=1&mobile=2` while its board is readable only by administrators
    /// (`viewperm_none_nopermission`).
    static let boardStanding = #"""
    <div class="jump_c">
    <div>抱歉，您没有权限访问该版块</p></div><div></div>
    <div><a href="javascript:history.back();" class="grey">[ 点击这里返回上一页 ]</a></div>
    </div>
    """#

    /// `…tid=1&mobile=2` while its board asks 金钱 > 100 (`forum_permforum_nopermission`): the
    /// notice breaks out of its own paragraph to list what it asked and what this account has.
    static let boardPoints = #"""
    <div class="jump_c">
    <div>您需要满足以下条件才能访问这个版块</p></div><div><p><b>访问条件： </b><br />&nbsp;&nbsp;&nbsp;金钱 > 100<br /><b>您的信息： </b><br />&nbsp;&nbsp;&nbsp;金钱: 2 </div>
    <div><a href="javascript:history.back();" class="grey">[ 点击这里返回上一页 ]</a></div>
    </div>
    """#

    /// `…tid=3&mobile=2`, a thread its author sells for 5 金钱: the thread, its opening post's
    /// words replaced by a lock holding a way to pay (`forum.php?mod=misc&action=pay&tid=3`).
    /// From `div.viewthread` to the comment region; the per-page `formhash` script is cut.
    static let pricedThread = #"""
    <div class="viewthread">
    <div class="view_tit">
    Priced thread</div>
    <!--[diy=diy2]--><div id="diy2" class="area"></div><!--[/diy]--><div class="plc cl" id="pid3">
    <div class="avatar"><img data-src="./data/avatar/noavatar.svg" class="_avt user_avatar"></div>
    <div class="display pi pione">
    <ul class="authi">
    <li class="mtit">
    <span class="y">
    楼主</span>
    <span class="z">
    <a href="home.php?mod=space&amp;uid=1&amp;mobile=2">admin</a>
    </span>
    </li>
    <li class="mtime">
    <span class="y"><i class="dm-eye"></i><em>1</em><i class="dm-chat-s"></i><em>0</em></span>49&nbsp;秒前</li>
    </ul>
    <div class="message">
    <div class="locked">
    <a href="forum.php?mod=misc&amp;action=pay&amp;tid=3&amp;pid=3&amp;mobile=2" class="y viewpay dialog">购买主题</a>
    <em class="right">
    </em>
    本主题需向作者支付 <strong>5 金钱</strong> 才能浏览</div>
    </div>
    <div id="comment_3">
    </div>
    <div id="post_rate_div_3"></div>
    </div>
    <div class="threadlist cl">
    <div class="threadlist_foot cl">
    <ul>
    </ul>
    </div>
    </div>
    </div>
    <div class="discuz_x cl"></div>
    <div class="txtlist cl">
    <div class="mtit cl">
    <a href="forum.php?mod=viewthread&amp;tid=3&amp;extra=&amp;ordertype=1&amp;mobile=2" class="ytxt">倒序浏览</a>
    <a href="forum.php?mod=viewthread&amp;tid=3&amp;page=1&amp;authorid=1&amp;mobile=2" rel="nofollow" class="ytxt">只看楼主</a>
    全部回复</div>
    </div>
    <div class="view_reply cl"><i class="dm-sofa"></i>暂无回复，快来抢沙发</div>
    </div>
    """#
}
