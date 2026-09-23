import Foundation

/// Discuz! blog pages **as a real install served them** (#209) — the local Discuz! X5.0.2 that
/// `servers/compose.yml` brings up, installed by `servers/discuz/seed.sh`, with its blogs switched
/// on and four seeded as `admin` (uid 1): one public, one only its author may read, one behind a
/// password, and one three hours old. Fetched signed out with `curl` on 2026-09-23.
///
/// **Trimmed, not edited.** Each is the page's main region, from the breadcrumb to the comment
/// form, with the head, the site chrome and the scripts cut away; the click buttons' per-visitor
/// `hash=` is zeroed, and the space's short link names `discuz.localhost` where the capture wrote
/// the loopback address. Every tag, class and line break in between is the server's.
enum DiscuzBlogCaptures {
    /// `home.php?mod=space&uid=1&do=blog&id=1`: the breadcrumb, the author's space header
    /// (`#uhd`, a lazy-loaded avatar), the heading, the date line — after the read count — the
    /// words, the click buttons, and the author's other blogs.
    static let blog = #"""
    <div id="pt" class="bm cl">
    <div class="z">
    <a href="./" class="nvhm" title="首页">Discuz!</a> <em>&rsaquo;</em>
    <a href="home.php?mod=space&amp;uid=1">admin</a> <em>&rsaquo;</em>
    <a href="home.php?mod=space&amp;uid=1&amp;do=blog&amp;view=me">日志</a>
    </div>
    </div>
    <style id="diy_style" type="text/css"></style>
    <div class="wp">
    <!--[diy=diy1]--><div id="diy1" class="area"></div><!--[/diy]-->
    </div><div id="uhd">
    <div class="mn">
    <ul>
    <li class="pm2">
    <a href="home.php?mod=spacecp&amp;ac=pm&amp;op=showmsg&amp;handlekey=showmsg_1&amp;touid=1&amp;pmid=0&amp;daterange=2" id="a_sendpm_1" onclick="showWindow('showMsgBox', this.href, 'get', 0)" title="发送消息">发送消息</a>
    </li>
    </ul>
    </div>
    <div class="h cl">
    <div class="icn avt"><a href="home.php?mod=space&amp;uid=1"><img data-src="./data/avatar/noavatar.svg" class="_avt user_avatar"></a></div>
    <h2 class="mt">
    admin</h2>
    <p>
    <a href="https://discuz.localhost/?1" class="xg1">https://discuz.localhost/?1</a>
    </p>
    </div>

    <ul class="tb cl" style="padding-left: 75px;">
    <li><a href="home.php?mod=space&amp;uid=1&amp;do=thread&amp;view=me&amp;from=space">主题</a></li>
    <li class="a"><a href="home.php?mod=space&amp;uid=1&amp;do=blog&amp;view=me&amp;from=space">日志</a></li>
    <li><a href="home.php?mod=space&amp;uid=1&amp;do=profile&amp;from=space">个人资料</a></li>
    </ul>
    </div>
    <div id="ct" class="ct1 wp cl">
    <div class="mn">
    <!--[diy=diycontenttop]--><div id="diycontenttop" class="area"></div><!--[/diy]-->
    <div class="bm bw0">
    <div class="bm_c">

    <div class="vw mbm">
    <div class="h pbm">
    <h1 class="ph" >
    A blog & more</h1>
    <p class="xg2">
    <span class="xg1">已有 12 次阅读</span><span class="xg1">2026-9-11 05:30</span>


    </p>
    </div>

    <div id="blog_article" class="d cl"><div class="quote"><blockquote>Somebody else said this.</blockquote></div>First line.<br />
    <img src="data/attachment/album/photo.jpg" /><br />
    <div style="text-align:center"><font size="4">Second line.</font></div></div>
    <div id="click_div"><table cellpadding="0" cellspacing="0" class="atd">
    <tr><td>
    <a href="home.php?mod=spacecp&amp;ac=click&amp;op=add&amp;clickid=1&amp;idtype=blogid&amp;id=1&amp;hash=0000&amp;handlekey=clickhandle" id="click_blogid_1_1" onclick="showWindow(this.id, this.href);doane(event);">
    <img src="static/image/click/luguo.gif" alt="" /><br />路过</a>
    </td>
    <td>
    <a href="home.php?mod=spacecp&amp;ac=click&amp;op=add&amp;clickid=2&amp;idtype=blogid&amp;id=1&amp;hash=0000&amp;handlekey=clickhandle" id="click_blogid_1_2" onclick="showWindow(this.id, this.href);doane(event);">
    <img src="static/image/click/jidan.gif" alt="" /><br />鸡蛋</a>
    </td>
    <td>
    <a href="home.php?mod=spacecp&amp;ac=click&amp;op=add&amp;clickid=3&amp;idtype=blogid&amp;id=1&amp;hash=0000&amp;handlekey=clickhandle" id="click_blogid_1_3" onclick="showWindow(this.id, this.href);doane(event);">
    <img src="static/image/click/xianhua.gif" alt="" /><br />鲜花</a>
    </td>
    <td>
    <a href="home.php?mod=spacecp&amp;ac=click&amp;op=add&amp;clickid=4&amp;idtype=blogid&amp;id=1&amp;hash=0000&amp;handlekey=clickhandle" id="click_blogid_1_4" onclick="showWindow(this.id, this.href);doane(event);">
    <img src="static/image/click/woshou.gif" alt="" /><br />握手</a>
    </td>
    <td>
    <a href="home.php?mod=spacecp&amp;ac=click&amp;op=add&amp;clickid=5&amp;idtype=blogid&amp;id=1&amp;hash=0000&amp;handlekey=clickhandle" id="click_blogid_1_5" onclick="showWindow(this.id, this.href);doane(event);">
    <img src="static/image/click/leiren.gif" alt="" /><br />雷人</a>
    </td>
    </tr>
    </table>
    <script type="text/javascript">
    function errorhandle_clickhandle(message, values) {
    if(values['id']) {
    showCreditPrompt();
    show_click(values['idtype'], values['id'], values['clickid']);
    }
    }
    </script>

    </div>

    <div class="o cl">

    <a href="javascript:;" onclick="showWindow('miscreport1', 'misc.php?mod=report&rtype=blog&uid=1&rid=1', 'get', -1);return false;">举报</a>
    </div>

    </div>

    <div class="ct_vw cl">
    <div class="ct_vw_sd">
    <div class="mbm cl">
    <h2 class="mbm ptn pbn bbs"><span class="xs1 xw0 y"><a href="home.php?mod=space&amp;uid=1&amp;do=blog&amp;view=me">全部</a></span>作者的其他最新日志</h2>
    <ul class="xl xl1 cl"><li>&bull; <a href="home.php?mod=space&amp;uid=1&amp;do=blog&amp;id=3" target="_blank">A recent one</a></li>
    </ul>
    </div>
    </div>

    <div class="ct_vw_mn">
    <div id="div_main_content" class="mbm">
    <h3 class="ptn pbn bbs">
    评论 (<span id="comment_replynum">0</span> 个评论)
    </h3>
    <div id="comment_ul" class="xld xlda"></div>
    """#

    /// The same page for a blog only its author may read, and for one behind a password: a
    /// signed-out reader is told to sign in, in Discuz!'s own notice, at status 200.
    static let signInNotice = #"""
    <div id="ct" class="wp cl w">
    <div class="nfl" id="main_message">
    <div class="f_c altw">
    <div id="messagetext" class="alert_info">
    <p>抱歉，您需要登录后才能查看</p>
    </div>
    <div id="messagelogin"></div>
    <script type="text/javascript">ajaxget('member.php?mod=logging&action=login&infloat=yes&frommessage', 'messagelogin');</script>
    </div>
    </div>
    </div>
    """#

    /// A blog number that does not exist, `id=99`: the same notice, as an error.
    static let missing = #"""
    <div id="ct" class="wp cl w">
    <div class="nfl">
    <div class="f_c altw">
    <div id="messagetext" class="alert_error">
    <p>抱歉，您要查看的信息不存在或已被删除</p>
    <script type="text/javascript">
    if(history.length > (BROWSER.ie ? 0 : 1)) {
    document.write('<p class="alert_btnleft"><a href="javascript:history.back()">[ 点击这里返回上一页 ]</a></p>');
    } else {
    document.write('<p class="alert_btnleft"><a href="./">[ Discuz! 首页 ]</a></p>');
    }
    </script>
    </div>
    </div>
    </div>
    </div>
    """#

    /// Any blog while the forum has blogs switched off, which is how X5.0 installs.
    static let switchedOff = #"""
    <div id="ct" class="wp cl w">
    <div class="nfl">
    <div class="f_c altw">
    <div id="messagetext" class="alert_error">
    <p>抱歉，日志功能尚未开启</p>
    <script type="text/javascript">
    if(history.length > (BROWSER.ie ? 0 : 1)) {
    document.write('<p class="alert_btnleft"><a href="javascript:history.back()">[ 点击这里返回上一页 ]</a></p>');
    } else {
    document.write('<p class="alert_btnleft"><a href="./">[ Discuz! 首页 ]</a></p>');
    }
    </script>
    </div>
    </div>
    </div>
    </div>
    """#
}
