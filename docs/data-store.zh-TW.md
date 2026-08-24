# 儲存層

[English](data-store.md) | [繁體中文](data-store.zh-TW.md)

> Fediqo 讀到與寫下的一切都落在同一顆本地資料庫，而且不離開它。

SQLite 透過 GRDB，而 GRDB 是唯一的外部依賴。這份文件說明存什麼、一則貼文怎麼進來，以及「同一則貼文」是什
麼意思。表本身寫在 [`schema.sql`](schema.sql)，那份就是 migration 001 必須對得上的基準。

範圍是貼文優先：公開時間軸，以及依 tag、伺服器、作者或關鍵字篩過的時間軸。其餘的都等，理由寫在
[〈還在等的〉](#還在等的)。

## 規則

> **網路交過來的東西寫一次就不再改寫。你決定的事情，是疊在它上面、可以撤銷的另一層。**

選一台伺服器、追蹤一個 tag、靜音一個 tag：每一樣都是刷新永遠不寫的欄位，撤回決定就是把它設回 `NULL`。
原始資料還在。

Migration 遵守同一條規則：只增不減。只有 `CREATE`、`ADD COLUMN`、`CREATE INDEX`，沒有別的 —— 會毀掉東西
的 migration 也是一種改寫。`posts_fts` 是唯一的例外，因為它是衍生出來的。

## 形狀

儲存層在讀取路徑上，不在旁邊。

```text
       網路刷新                              畫面
             │                                  ▲
             ▼                                  │
   ┌──────────────────┐   寫入    ┌─────────────┴─────────────┐
   │  source clients  │──────────▶│          SQLite           │
   └────────┬─────────┘           │  畫面上的每一列           │
            │ 只回傳 failures     │  都來自這裡               │
            │ 不回傳貼文          └───────────────────────────┘
            ▼
      橫幅：哪一台伺服器，以及為什麼

   伺服器掛掉  ──▶  既有的列一列不少，只是沒有新的
   空畫面      ──▶  只有儲存層真的空才會出現，也就是全新安裝
```

一次刷新回傳的是失敗，不是貼文。伺服器拒絕，是滿滿一列時間軸上方多一條訊息，不是一片空白。

## 什麼放在哪裡

| 狀態                          | 放哪裡         | 為什麼                                       |
| ----------------------------- | -------------- | -------------------------------------------- |
| 主題、字級、語言、側邊欄      | `UserDefaults` | 第一個 frame 在儲存層開起來之前就需要它們    |
| 貼文、帳號、伺服器，與其關聯  | SQLite         | 社交資料                                     |
| 時間軸篩選                    | `UserDefaults` | 值存這裡，但當成 bind parameter 在 SQL 生效  |

讀完一頁再用 Swift 篩，每一頁的長度都會不一樣，所以不論值存在哪裡，篩選都屬於查詢。

同步讀偏好也讓 app 撐得過開不起來的資料庫：**那是一個畫面，不是 crash**，而那個畫面得用對的語言寫。

## 四層

```text
network   伺服器交過來的。刷新寫入；只有權威方改得動內容。
          protocols、servers、accounts、posts、tags、post_tags、server_trends

local     你決定的，可以撤回。只有你動得了。
          servers.selected_at、servers.position、tags.followed_at、tags.muted_at

record    在這裡數出來的，而且被數的列清掉之後它還留著。
          tag_buckets

derived   可以丟掉的索引。
          posts_fts
```

每一個外鍵一支箭，指向它參照的那張表：

```text
   ┌───────────┐
   │ protocols │
   └─────▲─────┘
         │ proto
         ├───────────────────────┬───────────────────┐
   ┌─────┴─────┐ server_url ┌────┴─────┐             │
   │  servers  │◄───────────┤ accounts │             │ proto
   └──▲──▲─────┘            └────▲─────┘             │
      │  │ authority_url         │ author_id         │
      │  │ source_url            │ boosted_by        │
      │  │                  ┌────┴────┐              │
      │  └──────────────────┤  posts  ├──────────────┘
      │                     └─▲──▲──▲─┘
      │ source_url   merge_key │  │  │ merge_key
   ┌──┴───────────────┐        │  │  │        ┌───────────┐  tag  ┌──────┐
   │  server_trends   ├────────┘  │  └────────┤ post_tags ├──────►│ tags │
   └──────────────────┘           │           └───────────┘       └──▲───┘
                                  │ id                               │ tag
                            ┌─────┴─────┐                    ┌───────┴─────┐
                            │ posts_fts │  (not a FK)        │ tag_buckets │
                            └───────────┘                    └─────────────┘

   不是外鍵   posts.in_reply_to_uri ──► posts.uri，讀取時比對
              posts_fts.rowid = posts.id，由 trigger 保持同步
              tag_buckets 數的是 post_tags × posts，清掉之後數字仍留著
```

本地的決定永遠不是刷新會寫的欄位。它確實掛在 network 表上 —— `servers` 帶著 `selected_at` 與 `position`，
`tags` 帶著 `followed_at` 與 `muted_at` —— 而讓這件事守得住的規則寫在 SQL 裡，不是寫在自律裡：

```sql
INSERT INTO servers (url, host, proto, title, created_at)
VALUES (?, ?, ?, ?, ?)
ON CONFLICT(url) DO UPDATE SET
    proto = excluded.proto,
    title = excluded.title;
    -- selected_at 與 position 不出現在這裡。這就是規則本身。
```

`servers` 是「我們遇過的每一個 host」的目錄，不是「你選的那幾台」的清單；選擇是 `selected_at`，移除一台
伺服器只是把它設回 `NULL`。**那一列永遠不刪**，所以你移掉一台，它什麼都不會帶走，它交給過你的每一則貼文
照樣顯示。

## 時間

時間戳一律是 `INTEGER`、epoch 毫秒，全系統沒有例外。Nostr 給的是秒，進來時乘一千 —— 也就是說它的毫秒位
永遠是 `000`、撞在同一毫秒的機率遠高於另外兩個協定，所以 `ORDER BY` 裡的 tie-break 是必需品，不是保險。

每一張表都帶同一組：

| 欄位         | 意思                                     | 可為 NULL？    |
| ------------ | ---------------------------------------- | -------------- |
| `created_at` | 這一列是什麼時候出現在**這裡**，不是事情發生的時間 | 永不         |
| `updated_at` | 它的值最後一次改變是什麼時候             | NULL 表示從未 |

`updated_at` 只在真的有東西改變時才動。刷新交來一模一樣的資料，它不動 —— 這就是它和 `posts.last_seen_at`
的分別：一則被交過來一百次、一次都沒被編輯過的貼文，有一百次目擊、一個 `created_at`、以及 `NULL` 的
`updated_at`。

一張表對時間還需要知道的其他事，就用它自己的名字：`posted_at`、`last_seen_at`、`selected_at`、
`deleted_at`。特別是 `posts.posted_at` 是**作者**寫下它的時間，`posts.created_at` 是**我們**第一次存下它
的時間；算年齡的 policy 從後者算起，因為今天才抵達的貼文並沒有從發文那天就待在這裡。

## 伺服器是端點，不是主機名

同一個主機名可能講不只一種協定 —— 一個網域可以在 `https` 上提供 ActivityPub、在 `wss` 上開一個 Nostr
relay —— 而 Nostr relay 本來就是一個 URL，有 scheme、有時有 port、有時有 path。光一個主機名表達不了這些，
所以 `servers` 以正規化後的端點 URL 為鍵：

```text
https://mastodon.social        AP / Mastodon；port 與 path 是隱含的
https://bsky.social            一台 atproto PDS
wss://relay.damus.io           一台 Nostr relay
wss://relay.example.com/v1     帶 path 的 Nostr relay
wss://localhost:7777           帶 port 的 Nostr relay
```

正規化的意思是：scheme 與 host 轉小寫、拿掉預設 port、拿掉尾斜線、拿掉 query 與 fragment，其餘保留。
**兩列共用同一個主機名就是兩台伺服器**，這是對的，不是重複。`servers.host` 另外保留裸主機名並建索引，供
分組與顯示使用。

## 會長大的集合用表，不用 CHECK

`proto` 是指向 `protocols` 的外鍵。

理由是只增不減的 migration。SQLite 改不動 `CHECK`，把合法值寫死在 `CHECK` 裡，加第四個協定就得重建整張
表 —— 而重建正是規則禁止的事。改成外鍵之後，新增一個就是一次 `INSERT`。約束兩種寫法都是真的：資料庫直接
拒絕不認識的值，而不是相信 Swift 有記得檢查。

分界線是「這個集合會不會長大」。不可能生出第三個值的欄位維持純 `TEXT`；兩列永不增加的查表沒有任何好處。

同一套「現在不做、永遠不能做」的邏輯，讓每張表都加上 `STRICT`。SQLite 預設把宣告的型別當建議 ——
`created_at INTEGER` 塞進字串 `"yesterday"` 它照收不誤 —— 而 `STRICT` 之後加不了，因為加它就是重建。
加上之後，錯的型別在寫入當下就報錯，而不是靜默存進去，無論寫入走的是哪一條路。

## 兩個 URI

一則貼文有它的 id，也有你剛好從哪裡拿到它的位址。在 ActivityPub 裡兩者差得很遠：

```text
origin_uri   https://mastodon.social/users/alice/statuses/109…   各處相同
uri          https://a.example/api/v1/statuses/44215             a.example 的本地流水號
```

`origin_uri` 是身分，帶動所有東西 —— 鍵、權威判定、`authority_url`。`uri` 是來歷，同時也是那種完全不給正本
id 的少數來源的後備身分。

`origin_uri` 是**這則貼文自己的正本 id，不是它抄自哪一則**。橋接副本的 `origin_uri` 就是 bridge 發的那
個，因為橋接副本是另一個 actor 發的另一則貼文。它和原文的關係是一個宣稱，而儲存層今天不記任何宣稱 ——
見[〈還在等的〉](#還在等的)。

### 回覆指向第三個 URI

三個協定都會把「這則在回覆誰」交過來 —— Mastodon 的 `in_reply_to_id`、atproto 的 `reply.parent`、Nostr 的
`e` tag —— 所以 `posts.in_reply_to_uri` 把它留下。沒有它，時間軸沒辦法把回覆縮排，也沒辦法隱藏「回覆給你
不追蹤的人」，而那是其他 client 的預設行為。

它存的是一個位址，**不是外鍵**。回覆比它回覆的那則先抵達是常態，外鍵會直接拒收；串接是讀取時在
`posts.uri` 上的一次 join，還沒抵達的父文就是不在。兩邊都有索引 —— `posts_by_reply` 與 `posts_by_uri`。

它從第一次寫入就存著，而不是之後再加欄位，因為之後加的欄位永遠不會回填：網路交過來的東西寫一次就不再改
寫，所以已經存進去的每一則貼文會永遠留著空值。這是 append-only 給自己設下的陷阱，而出路是在凍結之前就
決定。

## Hashtag

一則貼文帶很多個 tag，一個 tag 被很多則貼文帶著，所以是兩張表：`tags` 與 `post_tags`。

它們是協定交過來的 —— Mastodon 的 `tags[]`、atproto 的 facets、Nostr 的 `t` —— 只有在來源完全沒給清單時
才從 `text` 裡剖出來。tag 比對時不分大小寫、顯示時保留大小寫，所以是兩個欄位而不是一個：

| 欄位           | 存什麼                        | 例子                 |
| -------------- | ----------------------------- | -------------------- |
| `tags.tag`     | NFC、轉小寫、去掉開頭的 `#`   | `blacklivesmatter`   |
| `tags.display` | 一個具代表性的大小寫寫法      | `BlackLivesMatter`   |

**依 tag 搜尋永遠不碰 `posts_fts`。** `WHERE tag = ?` 是 `post_tags_by_tag` 上的一次索引命中，是精確比對而
不是斷詞，而且它今天就能用在中文 tag 上 —— 不論這份文件最後那個 tokenizer 問題怎麼定案。時間軸因此可以依
tag 篩選而不必讀 `extras`，那條規則原封不動。

### 搜尋有它自己的鍵

`posts` 上有一個 `id INTEGER PRIMARY KEY`，其他地方都用不到它。它存在，是因為 `posts_fts` 是外部內容索引，
必須用 rowid 指名它的每一列。若只有 `merge_key`（一個 `TEXT` 鍵）當鍵，那個 rowid 就是隱含的 ——
而 **SQLite 可以在 `VACUUM` 時把隱含 rowid 重新編號**。索引裡的每一列就會指到另一則貼文，而且不會有任何
錯誤：搜尋只是靜靜地回傳錯的貼文。`INTEGER PRIMARY KEY` 是 rowid 的別名，`VACUUM` 不會動它。

`merge_key` 沒有因此失去什麼。它是 `UNIQUE NOT NULL`，所有外鍵仍然指向它，排序打破平手的也仍然是它。
`id` 只是給一個索引用的管線，永遠不離開儲存層。

`tags` 上沒有計數欄位。計數器會飄，`count(*)` 走索引不會。

追蹤與靜音某個 tag 是 `tags` 上的 `followed_at` 與 `muted_at`，沿用 `servers.selected_at` 的先例：掛在
network 表上的本地欄位，刷新只寫 `display`，永遠不碰它們。

權威方的編輯會把整組 tag 換掉，和換掉內文是同一件事。非權威方而不一致時，什麼都不改 —— 和其他每一個欄位
同一條規則。

## Trend 是兩件事

伺服器可以說某則貼文正在流行，儲存層也可以自己數。這是兩個不同的事實，在不同的層，刻意分開放：

| 表              | 層      | 一列說的是什麼                                                         |
| --------------- | ------- | ---------------------------------------------------------------------- |
| `server_trends` | network | 伺服器 `source_url` 把貼文 `merge_key` 列在第 `rank` 名，從 `first_seen_at` 到 `last_seen_at` |
| `tag_buckets`   | record  | 從 `bucket_at` 起的那一小時，`tag` 被 `posts` 則貼文帶著，來自 `authors` 個不同作者 |

`server_trends` 是伺服器交過來的，所以遵守 network 的規則：以 `(source_url, merge_key)` 為鍵，
`first_seen_at` 寫一次，`last_seen_at` 每次看到就更新，並且從 `posts` `ON DELETE CASCADE` —— 貼文已經不在，
它的 trend 也就什麼都不代表。Trending 畫面是 `posts ⋈ server_trends`，走 `server_trends_recent` ——
`WHERE last_seen_at` 夠新、`ORDER BY rank` —— 讀的是儲存層不是網路，所以離線也能用，過期的列只是從畫面上
消失。

`tag_buckets` 是第三層 **record**，它存在的理由就是：它比它數的東西活得久。一個 bucket 是 `posted_at` 的一小時。
每次刷新之後，這次刷新的貼文所落在的每一小時都會從 `post_tags` × `posts` 重算一遍，而 bucket 只會往上 ——
`posts` 與 `authors` 衝突時取 `max`，沒有 `DELETE`。清除會刪掉貼文；bucket 留著數字，一則遲到的貼文落進已經
清掉的那一小時，也拉不低它。一個 trend 是一個時間窗和前一個時間窗相減，走 `tag_buckets_by_tag`；而 `authors` 之所以在，是因
為一個人發兩百則不算 trend。

## 什麼算是同一則貼文

兩層，取第一個成立的：

```text
1.  boost:<轉發者 author_id>|<origin_uri>
2.  <origin_uri>，若為 NULL 則 <uri>
```

只看身分。不從 `web_url`、不從內容、不從時間猜 —— 不做內容雜湊、不做相似度、不做「同作者同一分鐘」。之
後若有想併更多的 policy，那是讀取時 join 的一張新表，永遠不是改 `merge_key`：鍵和其他網路交過來的東西一
樣，寫一次。

**兩個不同的 `origin_uri` 就是兩則不同的貼文**，各自成列。`proto` 永遠不進鍵 —— 同一則貼文透過兩種協定
讀到，帶的是同一個 `origin_uri`，必須合併。每個 URI 都存成帶 scheme 的形式，`https://…`、`at://…`、
`nostr:…`，讓鍵自己說得出它是什麼。

永遠不併的：轉發與原文、A 的轉發與 B 的轉發、引用與被引用的那則。前兩者是第 1 層刻意分開的。

### 抵達

```text
   一則貼文從 host H 交來
             │
             ▼
   有 origin_uri 嗎？
   ┌─────────┴──────────┐
  有                    沒有
   │                     │
   ▼                     ▼
 快路徑                依序落到兩層
 merge_key = origin_uri   boost → uri
 主鍵直接命中           │
 或直接插入             │
   └──────────┬──────────┘
              ▼
   H 是這則的權威方嗎？（posts.authority_url = H，或簽章驗過）
```

### 誰的版本算數

兩台伺服器帶同一則貼文，內容可能不一致。取先到的那一份，結果就取決於網路快慢，而且回得快的伺服器可以宣
稱別人的 id。

**內容以那個 `origin_uri` 的權威方為準，其餘來源什麼都改不動。** `posts.authority_url` 存的就是它是誰，
所以那個判定是一次欄位比對，不是每次寫入重新解析一遍：

| 協定          | `posts.authority_url` | 真正的權威是誰            |
| ------------- | --------------------- | ------------------------- |
| Mastodon / AP | URI 裡的 origin       | 就是那台                  |
| AT Protocol   | DID 目前指的 PDS      | 簽章，PDS 只是載體        |
| Nostr         | `NULL`                | 事件簽章，完全在本地驗    |

`NULL` 在這裡有精確的意思：**這則貼文的真偽不靠任何一台伺服器。** 非權威方而內容不一致時，直接略過；把它
說了什麼記下來，是還在等的表之一。

## 刪除

遠端回報已刪除的貼文是做記號，不是移除：`posts.deleted_at` 設一次、永不改寫，和其他每一個網路欄位一樣。
時間軸用 `WHERE deleted_at IS NULL` 略過它，而 partial index `posts_deleted` 找得到做了記號的列，不必掃
其餘的。

清掉做了記號的列是**儲存層唯一會執行的 `DELETE`**，而且只依 policy 跑 —— 例行掃除，或資料庫長過某個大
小 —— 永遠不在刷新裡發生。`post_tags` 與 `server_trends` 透過 `ON DELETE CASCADE` 一起走；trigger 把那一列
從 `posts_fts` 拿掉。`tag_buckets` 不動：數字是貼文還在的時候數的，清除不會把它收回，而 bucket 從不往下 —— 就算一則遲到的貼文
重算了已經清掉的那一小時也一樣。

清掉之後，若有伺服器再把那則交過來，它會是一列新的。這是可以接受的：儲存層從沒承諾記得它選擇忘掉的東
西，而一塊永遠留著的墓碑只是換個形狀的 rotation 問題。

## 各不相同的協定

| 事項                   | Mastodon / AP      | AT Protocol           | Nostr                |
| ---------------------- | ------------------ | --------------------- | -------------------- |
| 免登入讀公開時間軸     | 有                 | 大致有                | 有，透過 relay       |
| trending               | 有一個 endpoint    | feed generator        | 沒有                 |
| 作者刪除               | 確定               | 確定                  | 只是請求，可能收不到 |
| 編輯                   | 原地更新           | 沒有                  | replaceable event    |
| 自己才有的欄位         | CW、language、poll | labels、langs、facets | tags、relay、簽章    |

最後一列以 JSON 放進 `extras`，配一條強制得了也測得出來的規則：

> **timeline 永遠不讀 `extras`。** 只有寫進它的那個 client，以及貼文詳情的 renderer 讀它。

兩個 JSON 欄位都在寫入當下檢查：`extras` 必須是物件，`media_urls` 必須是陣列，兩者都可以是 `NULL`。
`STRICT` 只保證這個欄位裝的是文字 —— 它會毫無怨言地存下 `'[broken'`，之後 `json_extract()` 就在讀取時、
在畫時間軸的那條路徑上炸開。`CHECK` 沒辦法事後加到既有的表上，所以這兩欄一直以來寫在註解裡的形狀，現在
寫進 schema，而不是交給下一個寫入的人去記得。

它上面那幾列是**能力**，不是欄位，該以一個值掛在 source client 上讓畫面詢問。畫面問來源做得到什麼，永遠
不問它叫什麼名字。協定告訴不了我們的事 —— 例如一則永遠傳不到的刪除 —— 答案是說出來，不是假裝。

## 還在等的

只增不減的規則對欄位和表是兩種待遇，而 schema 的形狀就是這個不對稱決定的：

> **之後才加到 `posts` 的欄位永遠不會回填。之後才加的表不花任何代價。**

今天沒放進 `posts` 的網路欄位，在已經存著的每一則貼文上會永遠是 `NULL`，因為網路交過來的東西只寫一次。
所以 `posts` 現在就留著每一個網路欄位 —— `in_reply_to_uri`、`boosted_by`、`web_url`、`media_urls`、
`extras`、`deleted_at` —— 不管畫面讀不讀。

表則相反，不論何時加進來都從空的開始，以外鍵掛在主幹上。等待不會損失任何東西，所以這些都等到畫面需要
時再加：

| 等的是                       | 等什麼                                               |
| ---------------------------- | ---------------------------------------------------- |
| 通知，以及通知的種類         | 你自己的帳號；公開時間軸不需要                       |
| 自有帳號                     | 同上 —— 憑證無論如何都留在 Keychain                  |
| identity 與帳號 alias        | 會搬伺服器的人；是一個宣稱，永遠不是改寫             |
| 同一稿的多則貼文             | 發布出去、之後才被認出是同一稿的貼文                 |
| 合併提示、reason 與決定      | id 判不出來的那些對，以及你對它們說了什麼            |
| 貼文分歧                     | 非權威來源說了什麼、而且被略過了                     |

每一張都是一次新的 `CREATE`，讀取時以 `merge_key` 或 `author_id` 做 join。沒有一張會動到已經在那裡的列。

## 寫入

```text
   一則貼文抵達 ── 來自 host H，協定 P
             │
             ▼
   client 產出 origin_uri（或什麼都沒有）、它回應的 uri，以及穩定的 author_id
             │
             ▼
   UPSERT servers ── H，以及 origin_uri 指名的那個端點，若是新的；
             │       作者與轉發者的 host 也是，title 未知
             │       只寫 proto 與 title，而 title 一旦知道就不會被清空；
             │       selected_at 是你的
             ▼
   UPSERT accounts ── 名字會變，id 不會
             │
             ▼
   UPSERT tags ── 協定給的清單；只有它完全沒給時才從內文剖
             │
             ▼
   merge_key ── boost，否則 origin_uri，否則 uri
             │
             ▼
     BEGIN ──▶ SELECT posts WHERE merge_key = ?
             │
   ┌─────────┴──────────┐
 沒有這一列          已經有了
   │                    │
   ▼                    ▼
 INSERT posts     更新 last_seen_at
   │                    │
   │                    ▼
   │             H 是權威方嗎？（authority_url = H，或簽章驗過）
   │               ┌────┴────────────┐
   │             是                  否
   │               │                 │
   │               ▼                 ▼
   │          更新內容欄位，    什麼都不改
   │          或遠端說刪了
   │          就設 deleted_at
   │               │                 │
   └──────────┬────┴─────────────────┘
              ▼
     若是權威方的編輯，整組換掉這則的 post_tags
              │
              ▼
     UPSERT server_trends ── 若 H 把它列為 trending：rank 與 last_seen_at
              │               會動，first_seen_at 不會
              ▼
     trigger 讓 posts_fts 跟上  ──▶  COMMIT
              │
              ▼
     重算這次刷新的貼文所落在的每一小時的 tag_buckets ── 只做一次，在每一則
                                                     都進去之後；數字只會往上
```

一次刷新一個 transaction，不是一則一個。沿路沒有任何一步掃表：`merge_key` 是 `UNIQUE`，`servers.url`、
`accounts.author_id` 與 `tags.tag` 是主鍵，查回覆走 `posts_by_uri`。順序由外鍵決定 —— `protocols` →
`servers` → `accounts` → `posts` → `tags` → `post_tags` → `server_trends` —— 而 `tag_buckets` 排最後，因為
它數的就是這次刷新剛寫進去的東西。bucket 的鍵是貼文發出的那一小時，不是它抵達的那一小時；而且它是單調的：
`posts` 與 `authors` 取舊數字與新數字的 `max`，沒有任何東西會刪掉一列。

## 讀取

```text
   posts   主幹 —— 收到什麼就是什麼，永不改寫
     │
     ├── WHERE deleted_at IS NULL
     │
     ├── JOIN accounts ──▶  誰寫的；依作者篩選走 posts_by_author_time
     │
     ├── JOIN post_tags ──▶  只有指定 tag 時才接上。是 post_tags_by_tag 上的索引命中，不是搜尋
     │
     ├── JOIN posts_fts ──▶  只有要搜自由文字時才接上
     │
     ├── WHERE ── 篩選只增與只減，從不移動任何一列
     │            依伺服器篩選走 posts_by_source
     │
     ├── ORDER BY posted_at DESC, merge_key
     │        唯一的排序。用 merge_key 打破平手，因為它 UNIQUE 而且
     │        永不為 NULL，所以順序是全序，分頁的邊界每次刷新都落在同
     │        一個地方
     │
     └── LIMIT ── 分頁在這裡發生，且在篩選之後
           │
           ▼
        畫面
```

四種篩選、四個索引：tag 走 `post_tags_by_tag`，伺服器走 `posts_by_source`，作者走
`posts_by_author_time`，關鍵字走 `posts_fts`。主幹在中間，而今天接在它身上的，沒有一樣不是網路交過來的。

Trending 是另外兩種讀取，兩者都不碰網路：

```text
   伺服器說的   posts ⋈ server_trends  WHERE last_seen_at > ?  ORDER BY rank
                走 server_trends_recent；不再被看到的列就從畫面上消失

   這裡數的     tag_buckets  WHERE tag = ? AND bucket_at >= ?
                走 tag_buckets_by_tag；這個時間窗的 posts 與 authors 和上一個相減
```

## 還沒定的

`schema.sql` 裡有一處標著 `<undecided>`，還沒定案：

| 未定                  | 問題                                                            |
| --------------------- | --------------------------------------------------------------- |
| `posts_fts` tokenizer | `unicode61` 把連續的漢字當成單一 token，`台北` 搜不到 `今天在台北喝咖啡` |
