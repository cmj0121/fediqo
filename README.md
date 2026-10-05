# Fediqo

<img src="assets/logo.svg" alt="The Fediqo mark: an octopus in front of a machined chassis"
     width="128" align="right">

[English](README.md) | [繁體中文](README.zh-TW.md)

> Your timeline. Your rules.

Fediqo is your timeline. You add sources, write rules, and read one stream in time order.
There is no Fediqo server.

## The concept

| Noun     | What it is                                                         | What it is not        |
| -------- | ------------------------------------------------------------------ | --------------------- |
| source   | anything that hands over items with a time, and can be asked again | a protocol page       |
| item     | the smallest thing with a publish time                             | a row of one protocol |
| filter   | the rules a timeline lets items through by; a hide names its rule  | a mute list           |
| timeline | inputs and a filter, laid flat in publish order                    | a network's home page |

A source can be as unlike another as it wants — an account on a network, a forum, a feed, a
web page split over numbered pages. It is a source when every item it hands over has its own
publish time, to the day at least, and an ID that stays the same, and when it can be asked for
what is newer. A timeline's input is a source or another timeline, so a new timeline is an
existing one with a filter put on it.

[`docs/concept.md`](docs/concept.md) is the whole of it: the item and its ID, fields,
revisions, what you can do to an item, and how one is let go.

The concept is where Fediqo is going, and Using it, below, is what this checkout does today.
Today a Mastodon host or a Discuz forum can be joined. A post's own revisions are here; a
timeline's are not. A rule can ask a Mastodon source's own fields; no other kind of source
declares any yet. The deleted mark before a purge, and a timeline built on another timeline,
are not here yet.

## How it works

```text
  sources (anything that gives its items a time)
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

The store is yours to take away and yours to let go. It leaves as one password-locked file in
your own hands, or moves to another of your devices nearby when both agree, and it passes
through nowhere of ours and not through the Apple account. Part of it goes when you say so —
by a span of dates, by a source — or when a limit you set is reached, and what a limit let go
says which limit did. Nothing goes that neither you nor your own limit chose, and a post you
keep goes by none of them. How each works is under What this device holds, below.

Several sources go in and one timeline comes out, so the same post from two of them is one
row rather than two. Nothing is scored or re-ordered on the way: the only thing between what
arrived and what you see is a rule you wrote.

## What it is not

- not a ranker — nothing is scored or re-ordered
- not a reader of what has no time: a book's chapters, a manual's pages
- not a way past anything a source does to keep a program from reading it
- there is no Fediqo server

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
| author   | posts by that person (`user@instance`), and reblogs they made  |
| keyword  | posts whose text contains it, hashtags included                |
| category | posts that arrived through it                                  |
| a field  | posts whose source says that of them — see below               |

- Rules of the same kind are any: one of them is enough.
- Rules of different kinds are all: each kind must let the post through. Each field is a kind
  of its own: two language rules are any, a language rule and a Sent to rule are all.
- A Hide rule hides what it matches, whatever else lets it through. A timeline with only Hide
  rules is All, less what they hide.
- A Hide on a person also hides what others reblog of theirs; showing a person shows what they
  wrote and what they reblogged.
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

### What one kind of source says

Some things only one kind of source says about a post. A Mastodon says four, and a rule can
ask each:

| Field                 | Says                                              | A rule asks for        |
| --------------------- | ------------------------------------------------- | ---------------------- |
| Sent to               | how far the post was sent                         | one of its audiences   |
| Language              | the language the post says it is in               | a language held posts say |
| Covered by its author | whether it was marked sensitive or given a warning | yes, or no            |
| Is a reblog           | whether the row is somebody's reblog of a post    | yes, or no             |

Is a reblog is asked of the row itself; the other three are asked of the post, and on a
reblog's row of the post it reblogs. So a Hide on Is a reblog: yes takes the reblogs out and
leaves each post where it stands on its own, shown once; showing only reblogs shows no post
for having been reblogged. A post held from before reblogs were rows, which says it arrived
as a reblog, is a post: it answers no.

The editor offers a field only while one of your sources declares it, and only the values
those sources can give: every audience, yes and no, and for Language the languages the posts
this device holds actually say, named in your language. A post whose source says no such
thing does not match: a forum's post has no Sent to, so a rule on it neither shows that post
nor hides it, and a post that states no language matches no language rule. Such a rule can be
for every source or for one that declares the field. When the last source that declares a
field is removed, the rule stays and is marked missing, as any rule naming something gone is.
A reload of a timeline made only of these asks the sources that declare the field.

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
lists. Writing lets you post, reply, boost, favourite and bookmark from Fediqo, and take any of
them back — and nothing else: Fediqo never asks to follow anybody, change your profile, or touch
your filters. Choosing reading alone asks for exactly what Fediqo asked for before it could
write at all, so refusing the writing part changes nothing about reading. Signing in again is
how you change your answer.

If you signed in before Fediqo could write, that sign-in still only reads, and Fediqo writes
nothing with it. Account says so, names the source, and puts the choice there beside it: one
press asks the same question, without signing you out first. Cancel on the server's page and
the sign-in you already had is still the one in use. What you already agreed to is never
widened behind your back.

If you signed in to read and write before Fediqo could bookmark, that sign-in posts, replies,
boosts and favourites exactly as it did; only bookmarking waits. The bookmark under a post
there says it has to be asked for, and Account names the source: one press on either asks, on
a page that names bookmarks, without signing you out first. A server that has no bookmarks to
grant leaves you signed in to read and write, and the bookmark is not offered there.

A bookmark is kept at the source. The mark under a post is what its source last said — filled
where it holds your bookmark, and never filled by a press that did not land — so it reads the
same in any other app, and after a relaunch. A press the source turns away says so and leaves
the mark as it was; press again to try again. Keeping a post is another thing, and this
device's own: see Keeping a post, below.

What you just did to a post is not undone by a reload that was already on its way. Boost,
favourite or bookmark a post — or take one back — while a timeline is still loading, and the
mark stays as the source answered your press when that timeline lands. The next reload you ask
for is the source's word again: a mark taken off in another app reads as off.

What a source says you boosted, favourited and bookmarked is yours as its signed-in reader, and
goes when that sign-in does: signing out, a server ending the sign-in, Clear, Remove, or another
account signing in on that source leaves its posts here saying nothing of any of the three,
until a signed-in read says so again.

Every row on Account says what may be done on that source — read, read and write, or read only
where the protocol has no writing in Fediqo at all, which is every forum. What it says is the
server's own answer: a server that grants less than Fediqo asked for is taken at its word, and
the row says what may be done rather than what was asked. A source that turns a write away says
so on its row and keeps saying it until you sign in to it again.

The secret is kept in this device's Keychain. It is not in the
store, it is not copied to iCloud, and it does not follow your Apple account to another
device. It survives a relaunch. The only way it reaches another device is one you start:
Take away carries it inside the locked file, and Move nearby sends it to another of your
devices — with the store, or the sign-ins alone — when both sides agree. Both are below,
under What this device holds.

Sign out on the row, Clear, and Remove each delete the secret from this device. What Home and
your lists brought in stays until you drop it. The sign-in page keeps no session of its own
and shares none with Safari, so each sign-in asks for your password on the server's page, and
signing out leaves nothing on this device that could sign in as you there. A server that ends
the sign-in shows the source as signed out and says so; it does not pretend to still work.

A forum sign-in keeps its cookies on this device until you sign out, Clear, or Remove, and each
of those takes them, with any password you saved for it.

Removing a source also stops everything Fediqo would ask of it by itself: the wait, a reload
already on its way, its pictures and emoji still queued, and an open thread from it. Nothing
reaches it again until you add it again. What becomes of its posts is a choice you made once,
on Preferences, and the question before removing says which it will do.

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

Reading toward the end of a timeline asks its sources for the next stretch, with no key
pressed. On Trends that is the next stretch of what is rising on each Mastodon source: what
arrives carries the trends category and stands at its publish time like every other post —
nothing here ranks it. A source that has no more to give is named at the foot of the timeline
for as long as that is so, and is not asked again until `r` reads from the top; the wait
reading the same sources between times changes none of that. One that fails says so, the
others still land, and it is asked again. A forum's trends are its ranking lists, which have no next. A timeline that does not
ask for trends by name reads on through time only.

`/` opens one search field. Its pattern is matched anywhere in every field a post is known by:
who wrote it, who boosted it, its text, its hashtags, its source, and its categories, by
their English or translated names and by list and board names. `*` stands for any run of
characters, including none, and `?` for exactly one. Every other character stands for itself:
there is no regex, operator, field prefix, or quoting. Case, and full-width against
half-width, do not change what is found. As you type, the posts this device holds are
searched. Return also asks the sources of the timeline in front that can be searched. What is
found is in time order. Clearing the field returns to the timeline.

A reblog is a row of its own. Its first line says who reblogged and, at its far end, when —
the time the row stands at. Under it is the post itself: its author's face and name, and
beside them when the post was published. Pressing who reblogged opens their page; pressing the
face or the name opens the author's. The post it reblogs also stands on its own at the time it
was published, as it does where it arrived with no reblog. Both rows show in a timeline whose
rules let both through, and reading again moves
neither. The reblog's row shows the post as this device holds it — covered where its author covered
it, marked where its source changed or deleted it — or says the post is no longer held, and
then the row is the reblog alone. A reblog its source says was taken back says so on its first
line. What you press on the row is done to the post, and each mark is named for whose post it
goes to: favourite, reblog, bookmark and
answer go to the post, and opening the row opens the post. Keeping the row keeps the reblog — the keep mark is named for it —
and the post it shows stays for as long as the reblog is kept, whatever else is let go — a
post you take back, or one its source says is gone, stays too, marked as gone from its source. A
rule on an author is asked of who reblogged — and a Hide on a person also hides what others
reblog of theirs, while showing a person shows what they wrote and what they reblogged; a rule
on a keyword or a field is asked of the
post reblogged, so what hides a post hides its reblogs — but for Is a reblog, which is asked
of the row, so hiding reblogs leaves the post's own row; a rule on a category is asked of the
reblog, which arrived through the timeline that listed it, while the post it brought arrived
through none. A post held from before reblogs were rows, which arrived as a reblog, stays
where it was and says it arrived as a reblog by that person, until a timeline brings that
reblog again; from then the reblog is the row that timeline shows, and the post is shown by
it only where it also arrives on its own.

What a post refers to is read for it. When a post first arrives and the post it answers is
not on this device — or a post it quotes that did not come with it — Fediqo asks the source
that brought it for that one post, without your asking. The post that arrived is shown at
once, and the line that names what it answers, or the quote, says that post is on its way
until it has come. It is asked for once: read again, the post asks for nothing more, and a
loaded post let go later is not brought back. Only the post referred to directly is read,
never what that post refers to in turn. A post its source says no longer exists is not asked
for again, and the line says it is gone at its source; a post that was read this way and
later let go says it is no longer held; a read that fails is tried twice more, then left for this run and said so on the
row, and asked again at the next launch. Each of these reads is listed with the others under
Requests this run, is made only of your own source — as you, where you are signed in to it,
and never unsigned in your place: when a sign-in ends, what your own timelines there still
had to read this way is dropped with it — and waits its turn: a source is asked for one at a time,
no closer than three seconds apart, and further apart where it says to slow down. One arrival asks a source
for at most ten such posts; the rest are read when their rows come near the screen. A post
read this way is a post like any other, and stays for as long as the post that refers to it.

Everything this device holds stands in its timelines. What a search brought back, what was
read under a hashtag, the answers read when a post was opened, and a post another one quotes
are posts like any other: each stands in All at the time it was posted, and stays there after
the search is cleared or the post is closed. None of them came through a category of its
source, so a timeline whose rules name a category — one made of Home alone, say — does not
show them; a rule on a source, an author, a keyword or a field shows the ones it matches. A
forum topic's replies are parts of their topic: they are read inside it, and are no row of a
timeline.

Preferences can set a latest date. Every timeline — All, Trends, yours, and a search — then
shows nothing posted after 23:59:59 of that day, in this device's time zone, and the timeline
says so. Newer posts stay on this device; turning the date off shows them again without a
fetch. The date survives a relaunch.

With no network, everything this device holds still reads: timelines, threads already read,
and pictures already brought. Rules are written and applied, and a search finds what is held.
What needs a network — asking a source, signing in, posting — says it could not reach the
source, rather than hanging. When the network returns, what was left unasked is asked again,
with no relaunch.

A post its Mastodon source says was changed after it was published carries a Changed mark,
and stays exactly where it was: its age is still when it was published, and no timeline moves
it. It shows what it says now, on an ordinary reload as on `r` with the post open, and a rule
or a search is asked of what it says now. What it said before stays on this device — only the
wordings this device held, never fetched from the source — and is under the post where it is
opened, oldest first, each with when its source said it changed. A post already changed when
it was first read is marked and has nothing earlier to show. A wording is the post's words and
its author's warning; an earlier wording that was covered stays covered until you lift the
post's cover or press Show it on that wording. On a phone, a post carrying two or more of the
Source removed, Deleted at source and Changed marks shows them as their glyphs alone. Earlier
wordings are counted under Usage, ride a take-away and a move nearby with their post, and go
when the post goes, by any way; a post you keep keeps them.

A covered post carries a Covered mark, apart from its words. Where the author wrote a warning,
it reads as their warning, set apart from the body. Where they wrote none, Fediqo puts no
sentence in their place. `s` lifts the cover; the mark then says it was covered, and `s`
covers it again. Covered pictures carry the same mark. After Esc from a thread, the post it
opened from is centred and still selected.

### What this device holds

The Usage page is tabbed by purpose: Sources, Time, Keep, and Copies. Tab rotates them.
Sources holds the totals, each source's figures and its Clear: one figure of posts for each
source, counting everything held from it, a forum topic's replies included. Time holds the week or month
breakdown. Keep holds the two limits, Posts you keep, Let go by dates, and What the limits let go. Copies
holds the pictures this device is keeping, and the drop that takes them. Clear takes a
server's cached copies and its sign-in, and keeps its posts. Preferences keeps what you
choose: language, theme, type, the latest date, what becomes of a removed source's posts,
and the two ways the whole store leaves — Take away and Move nearby.

What a source says about itself — its name, its figures, how long a post may be — stays on
this device with the source. After a relaunch, with or without a network, its page shows what
it last said and when, and asks again behind it. Something new replaces what was kept.

What this device lets go is gone from its store, not only from the screen. When a post goes —
dropped by you, by a limit, with its source, or taken back by its author — its words, and any
earlier wording kept with it, are written over in the store's file by the save that follows,
and a store an earlier version left such words in is rid of them the first time this version
opens it. A store that a read back replaced is not kept either, and nor is one that was put
aside because it was damaged: it is deleted once you have been told of it and what took its
place has been saved. Beyond that, what the system keeps beneath a file is the system's, and a
package you took away earlier still holds what it held.

When the store cannot be opened, Fediqo says why at the first thing you see, and what it does
depends on the reason. If the store is only out of reach — another copy of Fediqo is using it,
the device has no room left, its folder cannot be read or written — nothing on disk is changed
and nothing takes its place: Fediqo opens without it and saves nothing that time, so what you
do in that run is not kept, and the same store opens once the cause has passed. In such a run
nothing is swept by the list of sources either — picture copies and forum sign-ins stay as
they were — and a read back that would replace the store is refused, as is a take-away, which
would have nothing to take. If the store is damaged, it is put aside and an empty one takes
its place; the notice says so, and that the damaged one will be deleted. It is deleted once
you have pressed I understand on that notice and the new store has been saved, and there is no
getting it back after that. Put the notice down any other way, or quit before reading it, and
the damaged one is kept and the notice is shown again. If a read back was interrupted and left
two stores, Fediqo opens neither and asks which to keep, saying how many posts each holds and
when it was last written; the other is deleted only after the one you chose has opened and
been saved, and if the one you chose proves damaged the other is put back.

#### Keeping a post

Any post can be kept: the box under it, on its row and where it is opened, or `y` on the
selected post. The same press un-keeps it. The mark is this device's own, and nothing is sent
to the source. A kept post is never let go — not by either limit, not by dates, not with what
its source deleted, and not when its source is removed, whichever was chosen for that source's
posts: it stays, marked Source removed. A kept post of your own that you take back stays too,
marked Deleted at source. Where a question says how many posts would go, kept ones are not in
the number, and What the limits let go never counts one. Its picture copies are not kept with
it: they go with a removed source and for room like any others, and come back when the post
is read again while its source is here. Where kept posts alone are more than the room, the
store stays over it and Room says so; other posts are then let go as they arrive. Kept survives a relaunch, and goes
with a take-away and a move nearby. Un-kept, it is an ordinary post again from that moment:
the press itself lets nothing go.

Usage's Keep tab counts what you keep under Posts you keep: every source together, then each
by name — a source you removed among them — with what their words weigh, earlier wordings
counted in. Pictures are not in that figure; picture copies are counted by source, on Copies.
Stop keeping, beside each figure, un-keeps all of them or all from that source at once. It asks
first and names the count, and it lets nothing go: they are ordinary posts from then, and the
next limit or letting go may take them. A post two sources carry stays kept through the other
source's copy; one source's Stop keeping counts only the posts it makes ordinary and says how
many stay kept that way, and Every source reaches them all. A question that lets posts go —
removing a source, letting go by dates, letting go of what was deleted at its source — says
how many kept posts stay. Reading back a store, and holding or moving one nearby, says how
many of the posts it brings are kept before you agree, and a package whose store does not
bear that number out is refused before anything here changes. One from a version that did not
write the number down says that it does not say.

#### The two limits

Keep posts holds only the latest months — and with them a post you keep, and an older post
that one still held quotes or reblogs, which stays in All until the post or reblog showing it
goes; Room is what this device gives the index and its
picture copies together. Side by side, and whichever is reached first acts. Past the room,
picture copies go first, oldest first — they come back when read again — and only then the
oldest posts, from every source. A limit never set lets nothing go, and every source stays
joined.

A post a limit let go is no longer here, so nothing on it can name the limit. What the limits
let go, under Keep, keeps that account instead: one line each time a limit acted — which
limit, when, how many posts or picture copies, and from which sources — and never a post.
The lines survive a relaunch. What you let go yourself is not written there. Clearing the
account lets nothing else go.

#### Let go by dates

Under Keep. Pick a first and a last day, both included, in this device's time zone, and one
source or every one. Before anything goes, a question says how many posts, from where, and
that they do not come back; nothing goes without a yes. Afterwards they are in no timeline,
no search, and no count. Nothing outside those days, and nothing from another source, is
touched. Every source stays joined.

#### When a source is removed

Preferences holds one choice: a removed source's posts go with it, or they stay. Remove
honours it without asking again, and its question says which. Posts that stay are marked
Source removed, are still read in All and found by search, and go like any other post — by
dates, or by a limit. Its sign-in, its pictures and the boards you picked go either way, and
nothing reaches it again.

#### Take away

In Preferences. Take away writes the whole of what this device holds — posts, timelines,
rules, what was read, sources, and what signs in to them — to one file locked by a password
you set, and puts it where you choose: never anywhere of ours, never through the Apple
account. It first weighs what is here and asks whether the picture copies ride, showing how
much the file would be with them and without. With them, the file shows everything this
device shows with no network; without, it is far smaller, and pictures come back as each
post is read again. The password is at least eight characters, and a lost one is not
recovered: the file can sign in to every source, so it is nothing without its password, and
nobody — not this app, not anyone else — can open it otherwise. The app says so before the
password is set.

Read back opens such a file, asks its password, and shows what it holds — how many posts,
from which sources, and when it was taken away — before anything changes. On a clean install
or a new device it gives the same store, every source signed in as it was. On a device that
already holds a store it replaces that store: nothing is merged, and the question says so.
It is proven whole first: a file that is not a Fediqo take-away, one cut short or altered,
one written by a newer Fediqo, or the wrong password is refused with its own reason, and the
store is untouched. A read back that fails midway leaves the store as it was.

Nothing leaves this device either way. Both are listed under This device in the run's
requests.

#### Move nearby

In Preferences, below Take away. Another of your devices — a phone, a tablet, a Mac, in any
pairing — can hold this store, with no account between them. Hold from nearby shows a
six-digit code and this device's name, and waits. Move to nearby, on the other device, lists
your devices that are waiting, asks for the code the one you chose shows, then shows a
four-character mark; the holding device shows the same mark beside its code, and you say
whether the two screens agree before anything joins. The code is the key the two devices
join under, new each time, and a wrong one gets one try: it connects nothing, and the holder
shows a new code. Too many wrong codes close the hold.

What moves is what Take away writes — everything with pictures, everything without, or the
sign-ins only — sealed, straight to the other device over Wi-Fi or the direct link between
the two, and through nothing else: not our servers, not the Apple account, not a device that
only shares one. Both devices ask before anything moves, either can refuse, and the receiving
device proves the whole of it before anything there changes; a store already there is
replaced, as Read back says. A move that fails midway leaves it as it was. Each side lists
the move under the other device's name in the run's requests. The first time, the system
asks whether Fediqo may look for devices on the local network; it looks only while a move or
a hold is under way.

The store survives a relaunch. The first 0.2.0 launch carries an older store forward in
place, with nothing fetched and nothing for you to do: every source, post, board, sign-in,
and choice is still there. Old public and trends posts carry those categories, and a forum
post that recorded its board carries it. A post from a forum's cross-board listing never
recorded one and carries none; a source rule still reaches it.

A build older than the store it finds does not open it. It says a newer Fediqo wrote it, and
leaves it exactly as it was: it does not read it, write over it, or set it aside.

This checkout has no release tag yet. It is building toward 0.7.0.

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
