# 發布

[English](release.md) | [繁體中文](release.zh-TW.md)

> `make publish` 打包兩個 app、簽章、交給 TestFlight，並把這份 checkout 所寫的文案告訴商店。任何時候都
> 不會送審。

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
       ├── scripts/metadata.py —— 在建置任何東西之前檢查商店文案：語言資料夾、
       │   長度、連結，以及這個版本有沒有 release notes
       ├── setup_ci —— 在 runner 上做一個暫時的 keychain；在 laptop 上什麼都不做
       │
       ├── 問 App Store Connect 現在握著哪些 build number，一個平台問一次
       ├── 取 max(commit 數, 它握著的最大值 + 1) —— 一個號碼，兩個平台共用
       │
       ├── iOS     match ──▶ archive ──▶ .ipa ──▶ TestFlight ──▶ 商店文案
       └── macOS   match ──▶ archive ──▶ .pkg ──▶ TestFlight ──▶ 商店文案
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

## 商店被告知什麼

描述、關鍵字、名稱、副標題與兩個連結，都是這份 checkout 裡的檔案。它們就是被上傳的東西，在上傳 build 的
同一趟裡上傳，沒有任何一項是有人打進瀏覽器的。

```text
  fastlane/metadata/
      ios/    en-US/  description.txt keywords.txt name.txt subtitle.txt support_url.txt privacy_url.txt
              zh-Hant/ …
      macos/  en-US/  …
              zh-Hant/ …
      notes/  0.1.0/  en-US.txt zh-Hant.txt
```

**語言資料夾叫 `en-US` 與 `zh-Hant`。** 不是 `zh-TW`——那是這個 repository 每份文件用的代碼，而不是 App
Store Connect 認得的代碼。deliver 遇到不認得的資料夾不會抱怨；它上傳認得的那些，對其餘的一聲不吭，於是一
次發布只出了一種語言，而有人以為出了兩種。`scripts/metadata.py` 就是那個會拒絕的東西。

```sh
scripts/metadata.py                     # 樹的形狀、長度、連結
scripts/metadata.py --version 0.1.0     # ⋯⋯以及這個版本有沒有 release notes
scripts/metadata.py --resolve           # ⋯⋯以及那些連結會不會回應
```

它也是一個 pre-commit hook，而 `make publish` 在建置任何東西之前會把三件事都跑一遍——4001 個字的描述會在
封存四十分鐘之後被 App Store Connect 退回，而那支腳本一秒就能說。

**平台自己的文案是自己的；app 的文案是共用的。** 描述、關鍵字與支援連結屬於某個平台的某個版本。名稱、副
標題與隱私連結屬於 app 本身，App Store Connect 每個語言只留一份，由最後上傳的那個平台決定——所以兩棵樹都
帶著它們，而 `metadata.py` 不准這兩份抄本漂開。

**Release notes 以版本命名，不放在語言資料夾裡。** 放在描述旁邊的 `release_notes.txt` 是一個每次發布都被
覆寫的檔案，而忘記覆寫的那一次，會無聲地把上一次的字送出去。`notes/0.1.0/en-US.txt` 忘不掉：沒有自己資料
夾的 tag 沒有東西可讀，`make publish` 會在建置之前停下。在下 tag 之前寫好它們。

**隱私問卷是唯一不從這裡上傳的東西。** `deliver` 沒有辦法回答 App Store Connect 的隱私問卷——它帶的是隱私
*連結*，僅此而已。Fediqo 不蒐集任何東西，所以答案是 **Data Not Collected**，在 App Privacy 底下手動勾一
次，而只要 [`docs/privacy.zh-TW.md`](privacy.zh-TW.md) 還成立，它就一直成立。程式碼做了什麼是可查的：一
個相依套件、沒有分析、沒有任何第三方 SDK。

截圖就在隔壁，這條 lane 不必被告知就會從 `fastlane/screenshots/<platform>/` 把它們在同一趟裡一起上傳。

## 那些圖

```sh
make -C Apps shots-macos      # 兩種語言，1280x800
make -C Apps shots-ios        # 兩種語言，手機與 iPad
make shots                    # 以上兩者
```

它們會落在 `fastlane/screenshots/<platform>/<locale>/`，編號就是上傳的順序、也是它們該被讀的順序，而且
**會被 commit**。人要做的是看它們、判斷它們；沒有人要去拍它們。

**Mac app 自己拍自己。** `screencapture` 需要「螢幕錄製」權限，而那是 laptop 與 runner 的差別，不是其中
一邊的細節：hosted runner 在 image 裡被授權了，寫下這段話的這台 Mac 回的是
`could not create image from display`。視窗把自己畫進一張點陣圖則哪裡都不需要權限，因為根本沒有東西被
「擷取」——是 app 在算繪自己的 view 階層，那是它隨時可以做的事。程式在
`Sources/FediqoUI/Support/Shooter.swift`，`#if DEBUG`，上架的 build 編譯不到它。

自己畫也順便把尺寸定死了，而 `screencapture` 做不到這件事。App Store Connect 只收 16:10，而
**hosted runner 提供的顯示模式沒有一個是 16:10**——實測過：1024×768、1280×720、1600×900、1920×1080，
沒有一個是那個形狀。由這個 app 自己決定像素數的點陣圖，讓螢幕多大變得無關緊要。這個專案出的是
**1280×800**；2560×1600 與 2880×1800 是 retina 螢幕的尺寸，而沒有任何 hosted runner 有 retina 螢幕。

這個 app 在沙盒裡（#27），所以它寫進自己的容器並印出位置，腳本再把檔案搬出來。那是沙盒在做它的事，而盒子
不會為了一張截圖被打開。

**沒有任何東西被「操作」到位，全部都是「啟動」到位。** hosted runner 不會給 app 做 UI 測試需要的
accessibility 權限——實測過，寫在 [#30](https://github.com/cmj0121/fediqo/issues/30) 上——所以按不了任何
東西。每一張圖都是某個 launch 變數到得了的狀態：`FEDIQO_ROUTE`、`FEDIQO_RAIL`、`FEDIQO_LANGUAGE`、
`FEDIQO_COMPOSE`、`FEDIQO_NOTICES`、`FEDIQO_FIXTURE`。清單需要而它們到不了的狀態，是「再加一個變數」，
永遠不是「寫一段點擊腳本」。

在 runner 上踩到的一個坑：**`open` 不會把呼叫者的環境變數交給 app**。`FEDIQO_FIXTURE=1 open Fediqo.app`
開出來的是一個真的、空的 store，拍到的是首次啟動的畫面。腳本改成直接跑 bundle 裡的執行檔。

要拍哪些畫面，是 `scripts/shots.sh` 最上面的 `SHOTS` 陣列，沒有別的地方知道這件事。統計刻意不在裡面：那個
畫面讀的是 store，而直接啟動到它的那一次從來沒載過時間軸，拍出來會是一排零。

## 觸發它的那個 tag

推一個 tag，就是全部。

```sh
git tag v0.1.0
git push origin v0.1.0
```

[`.github/workflows/release.yml`](../.github/workflows/release.yml) 監看 `v*`，而它裡面的每一步不是
`brew install` 就是 `make publish`。關於發布的事，那個檔案裡一件都沒寫：build 叫什麼、由哪張憑證簽、商店
被告知什麼、以及任何時候都不送審，全都是 Fastfile 做的決定，而 laptop 用同樣的方式做同樣的決定。

在上傳那一步失敗的發布，用同一個 tag 再跑一次——**Actions → Release → Run workflow**，在下拉選單裡挑那個
tag。沒有人需要因為管線不能被問第二次，而發明一個 `v0.1.1`。

runner 從它的 secret store 拿到的，正是 `.env` 交給 laptop 的那些：

| secret                          | 與 laptop 上的差別                               |
| ------------------------------- | ------------------------------------------------ |
| `FEDIQO_TEAM_ID`                | 一樣                                             |
| `FEDIQO_BUNDLE_ID`              | 一樣                                             |
| `MATCH_GIT_URL`                 | HTTPS 形式——runner 沒有 ssh key 可以 clone       |
| `MATCH_GIT_BASIC_AUTHORIZATION` | 這裡必要，laptop 上用不到                        |
| `MATCH_PASSWORD`                | 這裡必要：沒有 keychain 幫忙記住它               |
| `ASC_KEY_ID`                    | 這裡必要——Apple ID 那條路需要有人看著            |
| `ASC_ISSUER_ID`                 | ⋯⋯它的 issuer                                    |
| `ASC_KEY_P8_BASE64`             | ⋯⋯以及 `.p8` 本身，base64，所以它不是一個路徑    |

publish lane 裡的 `setup_ci` 會做出 match 需要的暫時 keychain。不在 CI 上時它什麼都不做，這正是它可以在兩
台機器上都是同一行的原因。

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

截圖（[#30](https://github.com/cmj0121/fediqo/issues/30)）。在有指令能拍它們之前，兩個商店看到的是最後一
次有人手動上傳的東西；而這條 lane 會完全不上傳圖，而不是上傳「零張」—— 後者會被 App Store Connect 讀成一
個答案。

一次發布抵達 TestFlight 就停下。那正是任何還沒被人看過的東西該停的地方。

macOS app 跑在 App Sandbox 裡，所以它的資料庫在 `~/Library/Containers/dev.mini-poc.fediqo/`，不在
`~/Library/Application Support/`。sandbox 之前建的版本看不見之後的版本寫下的東西，而且沒有任何東西會把
前者搬給後者。
