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
       │   長度、連結、這個版本有沒有 release notes，以及審查者有沒有東西可讀
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
| `FEDIQO_REVIEW_FIRST_NAME` | 審查有問題的時候 Apple 找誰                         |
| `FEDIQO_REVIEW_LAST_NAME`  | ……那個人的姓                                        |
| `FEDIQO_REVIEW_PHONE`      | ……Apple 撥號的形式，國碼在前                        |
| `FEDIQO_REVIEW_EMAIL`      | ……以及改用寫的要寫去哪裡                            |
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
      review_information/ notes.txt
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

**審查者被告知什麼在這裡；他們找誰不在這裡。** `review_information/notes.txt` 是兩個平台、兩種語言共用
的一份。App Store Connect 是每個平台的*版本*各留一份審查資訊——iOS 那份與 Mac 那份在同一趟裡分別被建
起來——而要告訴它們的是同一件事，所以第二份抄本只可能因為漂開而不同。旁邊那組聯絡資料——姓名、
電話、電子郵件——來自環境裡的 `FEDIQO_REVIEW_*`，永遠不來自這份 checkout，因為 checkout 是公開的而那些是
某個人的。`metadata.py` 不管在哪裡看到叫這些名字的檔案都會拒絕。

**這些都不是選配的，而且跟被不被審查無關。** 這裡的東西從來不會被送去審查；它們之所以必要，是因為
`deliver` 每次上傳 metadata 都會去讀審查附件，而 App Store Connect 上沒有審查資訊的版本，回答那次讀取的
字是 `No data`。訊息就只有這樣，它在 archive 之後、TestFlight 之後才出現，而一個 app 的第一次發布正是還
沒有審查資訊的那一次。把聯絡資料交出去，就是讓它存在的辦法。

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
make -C Apps shots-widths     # 440、700 與 1024 點，最小與最大的字級
```

**`shots-widths` 不是給商店的，也不進 git。** 它是商店那份清單裡的每一個畫面，在 S9 被判斷的那四個角落各拍一張，
輸出在 `.build/shots-widths/`
（已被 gitignore）—— `fastlane/screenshots/` 是整個資料夾被上傳的，不是按清單，所以多放一張圖就是商店頁面上
多一張圖。440 是最寬的 iPhone、1024 是 13 吋 iPad；**700 兩者皆非**，而它正是 `Size.wideRows(at:)` 對它的
回答與另外兩者都不同的那個寬度 —— Split View 裡的 iPad、被拖窄的 Mac 視窗，也就是
[#80](https://github.com/cmj0121/fediqo/issues/80) 在講的情況。到得了那裡的是 `FEDIQO_SHOOT_SIZE` 與
`FEDIQO_TEXT_SCALE`，而它們跟其他啟動變數一樣是 `#if DEBUG`，store build 編譯不到。

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

**tag 是一個名字，而發版是在筆電上跑 `make publish`。** 曾經有一條監看 `v*` 的 workflow，它已經被刪掉了。
不是因為它寫錯 —— 它裡面每一步不是 `brew install` 就是 `make publish`，做出來的會是筆電做的同一個 build ——
而是因為從它被寫下來到被刪掉那天，**沒有人給過它任何東西**。它的 secret 一個都沒有設過，所以唯一一次推 tag，
它在還沒開始建置之前就停在 `refusing to run`。

剩下的東西是誠實的，不是次一等的。發版需要 Apple 的憑證、簽章用的證書、以及一個人的電話號碼；那些東西住在
一個人的一台機器上，而把它們複製一份放進代管的 runner，是為了少打一個指令而多開一個外洩的地方。

所以：把發出去的那個 commit 標上 tag，然後在這裡發版。

```sh
git tag -a v0.1.0 -m "..."
git push origin v0.1.0
make publish
```

tag 說的是這個 build 來自哪個 commit。它不啟動任何東西。

## 一台筆電被交給什麼

`scripts/env.sh` 放著這條發版線缺不得的名字，缺了就拒絕執行 —— 在建置之前，而不是上傳到一半。`.env.example`
就是那份清單；`scripts/env.sh --check` 會在不執行任何東西的情況下說出少了什麼。

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

**build 已經上了 TestFlight，`upload_to_app_store` 卻回 `No data`** —— 這個版本沒有審查資訊，而
`deliver` 照樣去讀了它的附件。第一次發布、沒有人填過審查聯絡資料的時候就是這樣；`FEDIQO_REVIEW_*` 與
`review_information/notes.txt` 是讓那份資訊存在的東西，而 `scripts/env.sh --check` 不跑任何東西就會說出
少了哪一個。

**紅色的 `Error fetching app store review detail - No data`，而 lane 繼續跑下去** —— 這不是同一件事，也
不是失敗。那是 `deliver` 在建立審查資訊之前先去找它，每個平台第一次上傳某個版本時都會這樣。會停下來的那
次只說 `No data`，別的什麼都不說；這一次會說是哪一次讀取失敗，然後往下走。

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
