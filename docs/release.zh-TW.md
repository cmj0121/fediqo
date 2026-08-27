# 發布

[English](release.md) | [繁體中文](release.zh-TW.md)

> `make publish` 打包兩個 app、簽章，然後交給 TestFlight。任何時候都不會送審。

建置與測試這份 checkout 不需要以下任何一樣東西。只有 `make publish` 會讀它們，而這正是重點：一個 pull
request 手上沒有任何憑據，也必須繼續不需要。

## 這一道指令做了什麼

```text
  make publish
       │
       ▼
  scripts/env.sh ──── 有 .env 就載入，然後 exec 收到的指令。
       │              往後的一切只讀環境變數，不讀別的，
       │              所以 laptop 與 runner 跑的是同一份程式碼。
       ▼
  fastlane publish
       │
       ├── 問 App Store Connect 現在握著哪些 build number，一個平台問一次
       ├── 取 max(commit 數, 它握著的最大值 + 1) —— 一個號碼，兩個平台共用
       │
       ├── iOS     match ──▶ archive ──▶ .ipa ──▶ TestFlight
       └── macOS   match ──▶ archive ──▶ .pkg ──▶ TestFlight
                                         └─ 由 installer 身分簽章；
                                            Mac App Store 只收這種形狀
```

## 第一次之前

```sh
bundle install                  # 鎖定版本的 fastlane，裝進 vendor/
cp .env.example .env
$EDITOR .env
scripts/env.sh --check          # 只說名字 —— 它從不印出值
```

`--check` 最後會告訴你它會走哪一條路進去，或者根本沒有完整的路。半組不算一組：三個名字填了兩個不是一
條路，它會當場說，而不是等到上傳才發現。

| 名稱                  | 是什麼                                                   |
| --------------------- | -------------------------------------------------------- |
| `FEDIQO_TEAM_ID`      | 那些簽章身分所屬的 Apple Developer Program team          |
| `FEDIQO_BUNDLE_ID`    | 一個識別碼、兩個平台、App Store Connect 上一筆記錄       |
| `MATCH_GIT_URL`       | 憑證與 profile 加密存放的地方                            |
| `MATCH_PASSWORD`      | 那個 repository 的通關密語，keychain 裡沒有的時候才要填  |
| `ASC_KEY_ID`          | App Store Connect key：不需要有人在旁邊的那條路          |
| `ASC_ISSUER_ID`       | ……它的 issuer，一個 team 一組                            |
| `ASC_KEY_P8_BASE64`   | ……以及 `.p8` 本身，base64                                |
| `FEDIQO_APPLE_ID`     | 另一條路，會停下來向人要第二因素                         |
| `FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD` | ……它的 app-specific 密碼，名字是 fastlane 取的 |

沒有要填的就讓它註解著。一個名字後面空著，跟這個名字不存在，是兩件事：fastlane 自己也會讀 `.env`，而
在 Ruby 裡空字串為真 —— 所以空的 `MATCH_PASSWORD=` 會被當成通關密語，keychain 從頭到尾沒被問過。

## 兩條進去的路

哪一條完整就走哪一條，兩條都完整時優先用 key。

**App Store Connect key** 不需要有人看著。權限必須是 **App Manager** —— Developer 既產不了 provisioning
profile，也上傳不了 build。`.p8` 只能下載一次，這裡用 base64 而不是路徑保存，因為路徑是只有 laptop 才
有的東西。

**Apple ID** 今天就能用，而且會停下來要第二因素。Apple 的 session 大約一個月，而且只能由人重新取得，所
以這條路永遠不可能是 runner 走的那條。

## 一個 build 怎麼稱呼自己

Marketing 版本來自 `scripts/version.sh`：`HEAD` 上的 tag 去掉 `v`，或者最近的一個 tag 並說一聲它是將
就的，或者在從未發布過時是 `0.0.0`。

Build number 是歷史，再往上跨過 App Store Connect 已經握著的號碼 —— 同一個 commit 發兩次會數到同樣多的
commit，而商店不收看過的號碼。兩個平台用同一個號碼，因為一次發布嘗試就是一次，無論它抵達幾個商店。

**跑這道指令不需要 tag。** tag 是讓一次發布「發生」的東西 —— 是 workflow 將來要監看的訊號 —— 但不是讓
這道指令能動的東西。laptop 上任何人打下它就會發布。

## 讓 build 抵達一個人

上傳不會邀請任何人。build 只會透過一個「裡面有人」的 TestFlight 群組抵達一個人。

Internal tester 不是用 email 邀請的，而是從團隊既有的 App Store Connect 使用者裡挑，而且那個帳號要在
**Users and Access** 裡對這個 app 有存取權。這個專案用的群組是 `dev`，它會自己收下每一個新 build，所以
上傳時不必指名它。

```sh
scripts/env.sh -- bundle exec fastlane pilot add "$FEDIQO_APPLE_ID" -g dev -u "$FEDIQO_APPLE_ID" -a "$FEDIQO_BUNDLE_ID"
```

Mac 版透過 macOS 上的 TestFlight app 安裝。它跟手機是 App Store Connect 上同一筆記錄，只是另一個平台。

## 出錯的時候

這裡壞掉的東西，大多不是在它被回報的地方壞的。

**`Invalid password passed via 'MATCH_PASSWORD'`** —— `.env` 裡有一行空的 `MATCH_PASSWORD=`。空字串在
Ruby 裡為真，所以 match 拿它當通關密語，keychain 從沒被問過。

**iOS 的 lane 跑著跑著出現一個 macOS archive** —— scheme 不是 shared 的。fastlane 找不到收到的那個名
字，而它不會停下來，它會改用專案裡第一個 scheme。

**`requires a provisioning profile`** —— Release 是手動簽章，而 archive 沒被告知要用哪張 profile。只在
export options 裡指名太晚了，那時根本還沒有東西可以 export。

**`doesn't include signing certificate "Apple Distribution: …"`** —— 機器上裝了不只一張同名的憑證。
xcodebuild 按名字挑，而且不說它挑了哪張；這條 lane 改成按指紋挑，指紋是向那張終究要接受它的 profile 問
來的。

**`GRDB_GRDB` 或某個 `Fediqo_*` bundle 說 `has conflicting provisioning settings`** —— 簽章設定是交給整
個 build 而不是寫進單一 target，於是它也套到了 Swift Package Manager 產生的 resource bundle 上。

**`Certificate '…' is not available on the Developer Portal`** —— 憑證 repository 裡存的那張已經過期或被
撤銷。把它從那裡移除，讓 match 產一張新的。

**`No orientations were specified`（90474）** —— `TARGETED_DEVICE_FAMILY` 含 iPad，而一個不能只佔螢幕三
分之一的 app 不能待在 iPad 上。四個 `UISupportedInterfaceOrientations` 都要宣告。

**`Could not find pkg file at path …`** —— gym 會自己補副檔名，所以一個本來就帶副檔名的 `output_name` 會
變成兩個。

## 憑證 repository 是共用的

`MATCH_GIT_URL` 指向的 repository 由這個 team 上好幾個 app 共用。match 靠 bundle identifier 把它們分
開，所以共用不花什麼代價 —— 但憑證本身是共用的，而這件事有兩面。換掉一張過期的，全隊的 app 都被修好。
`match nuke` 則是全隊一起壞。

它的預設分支是 `main`。`fastlane/Matchfile` 把這件事寫明，因為 match 沒被告知時會去找 `master`。

## 還不在這裡的東西

截圖（[#30](https://github.com/cmj0121/fediqo/issues/30)）、商店文案
（[#31](https://github.com/cmj0121/fediqo/issues/31)），以及 tag 觸發的 workflow，都還在這道指令之外。
在它們到位以前，一次發布抵達 TestFlight 就停下 —— 而那正是任何還沒被人看過的東西該停的地方。

macOS app 跑在 App Sandbox 裡，所以它的資料庫在 `~/Library/Containers/dev.mini-poc.fediqo/`，不在
`~/Library/Application Support/`。sandbox 之前建的版本看不見之後的版本寫下的東西，而且沒有任何東西會把
前者搬給後者。
