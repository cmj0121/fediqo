# Fediqo

<img src="assets/logo.svg" alt="Fediqo 的標誌：機械外殼前的一隻章魚"
     width="128" align="right">

[English](README.md) | [繁體中文](README.zh-TW.md)

> 你的時間軸，你寫的規則。

Fediqo 是你的時間軸。你加入來源，寫下規則，讀一條依時間排的流。
沒有 Fediqo 伺服器。

## 概念

| 名詞 | 是什麼 | 不是什麼 |
| --- | --- | --- |
| source | 你在讀的伺服器或帳號——協定在它後面 | 不是協定頁 |
| rule | 這條 timeline 讓什麼進來；藏的能指名 | 不是靜音清單 |
| timeline | 對這台裝置上 store 的一條 query | 不是某個網路的首頁 |
| item | 一則 `note` 或一則 `thread` | 不是單一協定的一列 |

## 怎麼運作

```text
  sources (any open protocol)
           │
           ▼
     your device, and nothing else
           │
           ▼
  one shape → merge → your rules → one timeline
```

這條路上的每一件事都發生在你的裝置上。沒有一個 Fediqo 伺服器讓它們經過，這就是隱私宣稱的全部——不多，也不少。

進去的是好幾個來源，出來的是一條時間軸，所以從兩處讀到的同一則只佔一列，不是兩列。
路上不會有人替它評分或重排：抵達的東西和你看到的東西之間，只有你自己寫的規則。

## 它不是什麼

- 不是把每個網路都接上的競賽
- 不是 RSS、YouTube 與部落格的閱讀器
- 不是 X、Instagram 或 Facebook 的客戶端——只接任何人都能實作、都能自架的協定

## 怎麼做出來的

| 做法       | 意思                                                      |
| ---------- | --------------------------------------------------------- |
| 原生       | Apple 平台上的 Swift----沒有 web view，沒有跨平台 runtime |
| 開放原始碼 | AGPL-3.0，可以從這份 checkout 自己建置，宣稱因此可查證    |

`make test` 跑測試。`make -C Apps run` 打開 macOS app。兩者都不需要這份 checkout 以外的東西。
[`docs/release.md`](docs/release.md) 寫的是那一個需要更多的指令——幫兩個 app 簽名並送到 TestFlight 的那一個。

空的啟動會打開帳號頁。加入一個尚未登入的 Mastodon 主機當來源——從目錄挑，或自己輸入主機名稱。
它會說出協定的名字；這個工作階段只有 Mastodon 能加入。公開與趨勢貼文進到記憶體裡的 store。
「全部」與「趨勢」是對那個 store 的 query。時間軸、通知與發文在還沒有東西可做之前會停用。
重新啟動，資料就沒了。沒有 OAuth。

這份 checkout 還沒有 release tag：mascot，以及一個只留在這次工作階段、存在記憶體裡的 Mastodon 來源。

## 標誌

機械外殼前的一隻章魚。一隻生物同時把手伸進好幾個地方，這就是整個構想；牠身後的金屬留著開槽，
那是章魚出現以前，時間軸被畫成的樣子。

圖稿放在 [`assets/`](assets/)——`logo.svg` 用在 64 px 以上，`logo-small.svg` 用在以下，那張把每一道
金屬邊界對齊像素格線、並且把觸手加粗，才能在 16 px 存活下來，`mascot.svg` 則用在章魚本身就是主體、
而不是當 icon 的場合。每張為什麼畫成這樣，寫在 [`assets/README.md`](assets/README.md)。

## DDD (Dream-Driven Development)

這個專案採用 DDD（dream-driven development，夢想驅動開發）方法論，意思是這個專案建立在我夢想的東西上。

所有功能都來自我的需求，以及我的夢想。

## 授權

Fediqo 採用 GNU Affero General Public License v3.0 授權——完整條文見 [`LICENSE`](LICENSE)。

Copyright (C) 2026 cmj <cmj@cmj.tw>

本專案刻意維持單一著作權人，如果 iOS 散布需要，日後才能加上 App Store 例外條款。
