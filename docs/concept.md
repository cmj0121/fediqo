# The concept

[English](concept.md) | [繁體中文](concept.zh-TW.md)

> Your timeline. Your rules. There is no Fediqo server.

Fediqo manages what you read as timelines. It loads items from sources, lays them out by the
time they were published, and lets you build a new timeline by putting a filter on what is
already there.

This page is the concept: what the words mean and what must stay true. It is where Fediqo is
going. What a checkout does today is in the [README](../README.md), under Using it.

## The four nouns

| Noun     | What it is                                                           |
| -------- | -------------------------------------------------------------------- |
| item     | the smallest thing with a publish time                               |
| source   | anything that hands over items when asked, and can be asked again    |
| filter   | the rules a timeline lets items through by                           |
| timeline | inputs and a filter, laid flat in the order the items were published |

## Where it runs

Everything happens on your device. There is no Fediqo server for any of it to pass through.
Fediqo reaches the sources you added and nothing else, and every request it makes can be
watched.

## Item

An item is something only if it has all four of these.

| It has       | Meaning                                                             |
| ------------ | ------------------------------------------------------------------- |
| publish time | the source's own word about this item, to the day at least          |
| an ID        | one for this item on this source; the same when it is read again    |
| a source     | where it came from                                                  |
| content      | something to show                                                   |

The publish time is the only time an item is ordered by, and it does not move. The moment an
item was fetched is not its publish time. Neither is a stamp the whole page shares, nor the
time it was last changed.

An item has two layers, and each has one owner.

| Layer               | Holds                                                 | Changed by |
| ------------------- | ----------------------------------------------------- | ---------- |
| what the source said | its content, its fields, and a revision for each change | the source |
| what you did        | keep, the deleted mark, and what you sent about it    | you        |

### The ID

Each item on each source has one ID. It is stable: the content can change under it and the ID
does not. It is never used again for something else. Everything about an item hangs on it —
its revisions, keep, the deleted mark, and what it refers to.

The same item read through another timeline keeps its ID.

### Fields

| Level    | What                                   | Rule                                              |
| -------- | -------------------------------------- | ------------------------------------------------- |
| required | the four above                         | every item has them                               |
| general  | author, category, keyword, and others  | one name everywhere; a source fills what it can   |
| dynamic  | fields that belong to one source       | the source names them and says their type         |

A dynamic field says what type it is: text, a number, a date, yes or no, or one of a fixed set
of options, which it lists. That is how a filter knows what it may ask of it.

A category is the source's own division of what it serves. An item carries each one it arrived
through; you do not make them.

## Source

A source can be as unlike another as it wants. It is a source when it passes three tests.

| Test                                  | What it turns away                               |
| ------------------------------------- | ------------------------------------------------ |
| every item has its own publish time   | a book's chapters, a manual, an undated list     |
| every item has a stable ID            | a page whose items cannot be told apart          |
| it can be read on — newer, at least   | a single page that never says what is new        |

An account on a network, a forum, a feed, and a web page split over numbered pages are the
same thing here: a stretch of items, and a way to ask for the next stretch.

Reading is what every source gives. Taking an act is something a source may offer or not.

## Filter

A filter judges an item by its fields, at any of the three levels. Rules combine.

- An item that lacks a field a rule asks about does not match that rule.
- Nothing is left out of a timeline except by a rule that timeline shows you, and what is left
  out can name the rule that did it.
- A rule that names something gone stays, and says so.

## Timeline

| It is      | Meaning                                                                    |
| ---------- | -------------------------------------------------------------------------- |
| built      | from inputs and a filter; an input is a source or another timeline         |
| ordered    | by publish time, and by nothing else; nothing is scored or re-ordered      |
| flat       | every item stands on its own; none is folded under another                 |
| live       | it follows what this device holds, and changes when its inputs change      |

A new timeline is an existing one with a filter put on it. A search is a filter you did not
save.

A timeline shows what this device holds. The device asks a source when you ask it to, or on a
wait.

## Revision

Three things have revisions.

| What                    | Moves on when                           |
| ----------------------- | --------------------------------------- |
| an item's content       | the source changed it                   |
| a timeline's definition | you changed its inputs or its filter    |
| a timeline's result     | any of its inputs moved on              |

A source changing an item gives that ID a new revision. The item stays where it was in every
timeline.

## Managing

| Act       | Kept      | Note                                             |
| --------- | --------- | ------------------------------------------------ |
| post      | at source | a new item                                       |
| reply     | at source | a new item, referring to what it answers         |
| reblog    | at source | a new item, referring to what it reblogs         |
| favourite | at source |                                                  |
| bookmark  | at source |                                                  |
| withdraw  | at source | takes back what you sent                         |
| keep      | here      | works on any item; a kept item is never let go   |

The list is open. An act kept at the source is there only where the source offers it, so on a
source that can only be read, keep is the one act there is.

## Letting go

| State   | Meaning                                              |
| ------- | ---------------------------------------------------- |
| held    | in its timelines                                     |
| deleted | marked, and still on this device                     |
| purged  | gone; you purge all that is marked, or what is older than a span |

An item its source takes back is marked deleted without you asking. It stays until you purge it.

A purge leaves nothing behind, not even the ID. An item its source still serves comes back the
next time it is read. To stop seeing something, hide it with a rule.

Keep always wins: no purge and no limit takes a kept item.

## What an item refers to

An item can refer to other items, by their IDs. It can refer to several, and each reference
says what kind it is: this answers that, this quotes that, this reblogs that.

- A reblog is an item of its own. It has its own ID and its own time, the time of the reblog; it
  is marked as a reblog and refers to the item it reblogs. The item it reblogs stands at its own
  publish time.
- A favourite is a mark on an item. It is not an item.
- What an item refers to is held too. If it is not there, it is loaded.
- An item loaded that way is an ordinary item: it stands in timelines at its own publish time,
  like any other.

A reference is read when an item is opened, to show what belongs with it. A timeline does not
fold one item under another because of it.

## What this device holds

What is held is yours. It leaves as one file in your own hands or moves to another of your
devices when both agree, and it passes through nowhere of ours. Limits you set let the oldest
go, and say which limit did.

## Later

The same thing from two sources is one item. That is true today where two sources name it
alike, and stays so. The general case is the next story: a link between two IDs, with neither
ID changed.

## What it is not

- Not a ranker. Nothing is scored or re-ordered.
- Not a reader of what has no time.
- Not a way past anything a source does to keep a program from reading it.
- There is no Fediqo server. It does not exist.
