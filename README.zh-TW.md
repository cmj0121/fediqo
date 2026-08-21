# Fediqo

<img src="assets/logo.svg" alt="Fediqo 的標誌：機械外殼前的一隻章魚"
     width="128" align="right">

[English](README.md) | [繁體中文](README.zh-TW.md)

> 一條時間軸，所有網路。

Fediqo 是開放社群網路的統一客戶端，把散在各處的社群網路收在同一個地方。
在一個原生的介面裡追蹤多條時間軸、處理對話，並且跨平台發文。

## 概念

| 原則         | 意思                                                           |
| ------------ | -------------------------------------------------------------- |
| 只有客戶端   | 沒有我們的伺服器----你的裝置直接連你的網路，不經過別人         |
| 開放協定     | 任何人都能實作、都能自架的協定----終究全部都要支援             |
| 合併，不重複 | 同一則貼文來自多個地方，仍然只佔一列                           |
| 時間軸優先   | 一條流、一個順序----依 hashtag、作者，或你不必加入的伺服器     |
| 只發一次     | 一個編輯器、多個網路，自己的時間軸只出現一則                   |
| 管理屬於你的 | 你的貼文，以及伺服器允許時，你的伺服器                         |
| 留在這裡     | 你留下的、以及你寫的，都留在這裡----不告訴伺服器，也不會輪替掉 |
| 在這裡算出來 | 趨勢與摘要來自你留下的東西，在你的裝置上算出來                 |

## 怎麼運作

```text
     servers you read                                servers you post to
   several, any protocol,                            the ones you chose,
   some you never joined                           each told exactly once
             |                                                ^
             v                                                |
  +----------+------------------------------------------------+-----+
  |  your device, and nothing else                            |     |
  |         |                                                 |     |
  |         v                                                 |     |
  |  one shape --> merge --> your rules --> one timeline      |     |
  |                  ^                                        |     |
  |                  |  the same post from two servers is     |     |
  |                  |  one row; nothing is ranked, only      |     |
  |                  |  ordered, and only by rules you wrote  |     |
  |                                                           |     |
  |  what you keep --> stays here, unrotated --> trends       |     |
  |                      and digests, worked out here         |     |
  |                                                           |     |
  |  what you write --> Composer --> once per server ---------+     |
  |                                                                 |
  +-----------------------------------------------------------------+
```

框裡的每一件事都發生在你的裝置上。沒有一個 Fediqo 伺服器讓它們經過，這就是隱私宣稱的全部——不多，也不少。

進去的是好幾台伺服器，出來的是一條時間軸，所以從兩台讀到的同一則貼文只佔一列，不是兩列。
路上不會有人替它評分或重排：抵達的東西和你看到的東西之間，只有你自己寫的規則。
你留下的不再被輪替掉，趨勢與摘要就從它算出來，在它本來就待著的地方算。
你寫的東西從同一道門出去——你選的每個網路各一次，而且時間軸會這樣說，不會假裝那只是一則。

## 怎麼做出來的

| 做法       | 意思                                                      |
| ---------- | --------------------------------------------------------- |
| 原生       | Apple 平台上的 Swift----沒有 web view，沒有跨平台 runtime |
| 開放原始碼 | AGPL-3.0，可以從這份 checkout 自己建置，宣稱因此可查證    |

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
