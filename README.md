# Fediqo

<img src="assets/logo.svg" alt="The Fediqo mark: an octopus in front of a machined chassis"
     width="128" align="right">

[English](README.md) | [繁體中文](README.zh-TW.md)

> Your timeline. Your rules.

Fediqo is your timeline. You add sources, write rules, and read one stream in time order.
There is no Fediqo server.

## The concept

| Noun     | What it is                                             | What it is not        |
| -------- | ------------------------------------------------------ | --------------------- |
| source   | a server or account you read; protocol stays behind    | a protocol page       |
| rule     | what this timeline lets through; a hide names its rule | a mute list           |
| timeline | one query of this device's store, in time order        | a network's home page |
| item     | a `note` or a `thread`                                 | a row of one protocol |

## How it works

```text
  sources (any open protocol)
           │
           ▼
     your device, and nothing else
           │
           ▼
  one shape → merge → your rules → one timeline
```

Everything in that path happens on your device. There is no Fediqo server for any of it to
pass through, and you do not have to take our word for it.

Fediqo reaches the sources you added, and nothing else: no telemetry, no crash report, no
update check, no third party. What a source sends back may point elsewhere — a picture, an
avatar, an emoji kept on another server — and that is fetched only because the source pointed
to it. A forum page shown in the app loads nothing from another site but by an entry below.
Those few named entries are all that reach past a source, each only while you are doing what
it is for:

| Entry                          | When                                                    |
| ------------------------------ | ------------------------------------------------------- |
| Directory of servers           | only while you are adding a source and browsing for one |
| A forum's browser check        | on a forum's pages                                      |
| The check a sign-in shows      | only while a forum's sign-in is in front of you         |
| A page followed from a sign-in | only while a forum's sign-in is in front of you         |

Preferences' Allowed tab lists them, says why each is there, and lets you switch any of them
off, or add a host of your own for one source — a forum whose pictures live elsewhere, say.
Switching one off refuses what it let through from that moment. The list keeps only what you
decided, never what was reached.

Every request this run makes can be watched: Preferences, In flight, then Everything this run
has asked. Each line names the source it was for, when it left, and what it was for — never
an address, a query, or anything that could sign in as you. What a source pointed to is listed
under that source, and what an entry let through names the entry. The list can be narrowed to
one source. It is this run only: quitting leaves nothing of where you went. Posts and their
pictures are the store, and they stay.

To check it from outside the app, watch Fediqo while it runs — with the iPhone's App Privacy
Report, or any network monitor on the Mac. Every host it reaches is a source you added,
something a source pointed to, or an entry in Allowed.

Several sources go in and one timeline comes out, so the same post from two of them is one
row rather than two. Nothing is scored or re-ordered on the way: the only thing between what
arrived and what you see is a rule you wrote.

## What it is not

- not a race to speak every network
- not a reader of RSS, YouTube and blogs
- not a client for X, Instagram or Facebook — only protocols anyone can implement and host

## How it is built

| Practice    | What it means                                                       |
| ----------- | ------------------------------------------------------------------- |
| native      | Swift on Apple platforms -- no web view, no cross-platform runtime  |
| open source | AGPL-3.0, buildable from this checkout, so the claim can be checked |

`make test` tests it. `make -C Apps run` opens the macOS app. Neither needs anything this
checkout does not already carry. [`docs/release.md`](docs/release.md) covers the one command
that does need more — the one that signs both apps and sends them to TestFlight.

A pull request is opened only after the full suite has been run on this machine, whatever
the pull request is for. That is the protocol servers, then the suite with them unlocked:

```text
make servers
FEDIQO_SERVERS=1 make test
make servers-down
```

`make servers` needs Docker. `make test` alone still passes on a machine that has not
brought the servers up, and that is the part a pull request checks. The servers, the
cases they unlock, and a release build run when work lands on `main`.

## Using it

An empty launch opens Account. Add a Mastodon host or a Discuz forum from the catalog or by
typing its hostname. It names the protocol; only those two join this session. What a source
sends lands in this device's store, and every timeline is a query of that store. Notices and
compose stay off until they have something.

### Writing a post

From a timeline, `c` or the compose control opens writing over the page. You pick a source
you may write on, and how far the post goes from what that source offers. A send that fails
keeps the text. What landed is in the timeline it belongs to, without reloading everything.

### Timelines you write

All and Trends are built in. Beside them you write your own. The header is `+`, then the
tabs, then the rule for the one in front. Tab goes All, Trends, then yours, in the order you
gave them. `e` opens the editor for the selected timeline; on All or Trends it says they
cannot be edited. Double-click or long-press a tab to edit it. To add one, press `+`. In the
editor you name, reorder, and remove a timeline, and the editor shows its own keys. Edits
apply on Done; Esc leaves the timeline as it was. Your timelines stay on this device across a
relaunch. Removing one takes its rules with it; its posts stay under All.

A timeline is its rules. A rule names one kind of thing:

| Kind     | Lets through                                                   |
| -------- | -------------------------------------------------------------- |
| source   | posts from that source                                         |
| author   | posts by that person (`user@instance`), or boosted by them     |
| keyword  | posts whose text contains it, hashtags included                |
| category | posts that arrived through it                                  |

- Rules of the same kind are any: one of them is enough.
- Rules of different kinds are all: each kind must let the post through.
- A Hide rule hides what it matches, whatever else lets it through. A timeline with only Hide
  rules is All, less what they hide.
- An author, keyword, or category rule can be for every source or for one. A list or a board
  belongs to one source, so a rule naming one is only for that source.
- A keyword ignores case, and full-width against half-width, and matches anywhere in the text
  with no word breaking. `#swift` finds only the hashtag, and also finds `#swiftui`; `swift`
  finds the word and the hashtag.

Nothing is hidden except by a rule the timeline shows you in its editor. Every post a timeline
leaves out is left out by one of its rules, and there is no mute list apart from them. If a
rule names a source or a category that is gone, the rule stays and is marked missing. It still
applies to the posts this device holds.

A timeline shows only what this device holds. An author rule shows that person's posts that
arrived here, not everything they ever wrote.

### Categories

A post carries the categories its source put it in. They are how the source itself divides
what it serves, and you do not make, rename, or delete them in Fediqo.

- Mastodon: public, trends, Home, and each of your lists.
- A forum: each board.

A category means a post arrived through it, so a post can carry several — Home and a list at
once, say. What arrived before you signed in has no Home. A list is made on the Mastodon
server; a list or board renamed there is still the same category, under its new name. You
choose which of your lists this device reads on the source's row on Account, the way you
choose a forum's boards. Home is always read once you are signed in.

### Signing in to Mastodon

A Mastodon source can be signed in to from its row on Account, so its Home and your lists can
be read. Before the server's page opens, Fediqo asks which sign-in you want, and says which
part is which: reading alone, or reading and writing. Reading brings in your Home and your
lists. Writing lets you post, reply, boost and favourite from Fediqo, and take any of them
back — and nothing else: Fediqo never asks to follow anybody, change your profile, or touch
your filters. Choosing reading alone asks for exactly what Fediqo asked for before it could
write at all, so refusing the writing part changes nothing about reading. Signing in again is
how you change your answer.

If you signed in before Fediqo could write, that sign-in still only reads, and Fediqo writes
nothing with it. Account says so, names the source, and puts the choice there beside it: one
press asks the same question, without signing you out first. Cancel on the server's page and
the sign-in you already had is still the one in use. What you already agreed to is never
widened behind your back.

Every row on Account says what may be done on that source — read, read and write, or read only
where the protocol has no writing in Fediqo at all, which is every forum. What it says is the
server's own answer: a server that grants less than Fediqo asked for is taken at its word, and
the row says what may be done rather than what was asked. A source that turns a write away says
so on its row and keeps saying it until you sign in to it again.

The secret is kept in this device's Keychain. It is not in the
store, it is not copied to iCloud, and it does not follow your Apple account to another
device. It survives a relaunch.

Sign out on the row, Clear, and Remove each delete the secret from this device. What Home and
your lists brought in stays until you drop it. The sign-in page keeps no session of its own
and shares none with Safari, so each sign-in asks for your password on the server's page, and
signing out leaves nothing on this device that could sign in as you there. A server that ends
the sign-in shows the source as signed out and says so; it does not pretend to still work.

A forum sign-in keeps its cookies on this device until you sign out, Clear, or Remove, and each
of those takes them, with any password you saved for it.

Removing a source also stops everything Fediqo would ask of it by itself: the wait, a reload
already on its way, its pictures and emoji still queued, and an open thread from it. Nothing
reaches it again until you add it again.

### Reading

| Key | What it does                                                    |
| --- | --------------------------------------------------------------- |
| `r` | reload the selected timeline, or the open post and its thread   |
| `e` | write or change the selected timeline                           |
| `/` | search the posts this device holds                              |
| `?` | show the keys list                                              |

`r` asks exactly the sources the selected timeline draws from. All asks every source; Trends
asks the sources that have trends, for their trends; a timeline you wrote asks the sources
and categories its rules name, and a rule for every source asks every source. With a post
open, `r` reloads that post and its thread, from any source, and not the timeline under it.
Pressing `r` again while a reload runs does not start a second one; Esc stops it. A source that fails says
so, and the others still land. The selected post stays selected.

`/` opens one search field. Its pattern is matched anywhere in every field a post is known by:
who wrote it, who boosted it, its text, its hashtags, its source, and its categories, by
their English or translated names and by list and board names. `*` stands for any run of
characters, including none, and `?` for exactly one. Every other character stands for itself:
there is no regex, operator, field prefix, or quoting. Case, and full-width against
half-width, do not change what is found. Only posts this device holds are searched, and no
source is asked. What is found is in time order. Clearing the field returns to the timeline
as it was.

Preferences can set a latest date. Every timeline — All, Trends, yours, and a search — then
shows nothing posted after 23:59:59 of that day, in this device's time zone, and the timeline
says so. Newer posts stay on this device; turning the date off shows them again without a
fetch. The date survives a relaunch.

With no network, everything this device holds still reads: timelines, threads already read,
and pictures already brought. Rules are written and applied, and a search finds what is held.
What needs a network — asking a source, signing in, posting — says it could not reach the
source, rather than hanging. When the network returns, what was left unasked is asked again,
with no relaunch.

A covered post carries a Covered mark, apart from its words. Where the author wrote a warning,
it reads as their warning, set apart from the body. Where they wrote none, Fediqo puts no
sentence in their place. `s` lifts the cover; the mark then says it was covered, and `s`
covers it again. Covered pictures carry the same mark. After Esc from a thread, the post it
opened from is centred and still selected.

### What this device holds

The Usage page is tabbed by purpose: by source, by time, and picture copies. Tab rotates
them. Sources holds the totals, each source's figures and its Clear. Time holds the week or
month breakdown and how long posts are kept. Copies holds the pictures this device is
keeping, and the drop that takes them. Clear takes a server's cached copies and its sign-in,
and keeps its posts. Preferences keeps what you choose: language, theme, type, and the
latest date.

The store survives a relaunch. The first 0.2.0 launch carries an older store forward in
place, with nothing fetched and nothing for you to do: every source, post, board, sign-in,
and choice is still there. Old public and trends posts carry those categories, and a forum
post that recorded its board carries it. A post from a forum's cross-board listing never
recorded one and carries none; a source rule still reaches it.

A build older than the store it finds does not open it. It says a newer Fediqo wrote it, and
leaves it exactly as it was: it does not read it, write over it, or set it aside.

This checkout has no release tag yet. It is building toward 0.2.0.

## The mark

An octopus in front of a machined chassis. One creature with its arms in several places at
once, which is the whole idea; the metal behind it keeps the slots the timeline was drawn as
before the creature arrived.

The artwork is in [`assets/`](assets/) — `logo.svg` from 64 px up, `logo-small.svg` below
that, where every metal edge is snapped to the pixel grid and the arms are thickened so they
survive at 16 px, and `mascot.svg` for where the creature is the subject rather than the icon.
[`assets/README.md`](assets/README.md) says why each drawing is the way it is.

## DDD (Dream-Driven Development)

This project is based on the DDD (dream-driven development) methodology which means the project
is based on what I dream of.

All the features are based on my needs and my dreams.

## License

Fediqo is licensed under the GNU Affero General Public License v3.0 — see [`LICENSE`](LICENSE)
for the full text.

Copyright (C) 2026 cmj <cmj@cmj.tw>

The project deliberately keeps a single copyright holder, so that an App Store exception clause
can be added later if iOS distribution requires it.
