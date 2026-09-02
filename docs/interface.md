# The rules a screen is drawn by

[English](interface.md) | [繁體中文](interface.zh-TW.md)

> The look is not a taste. It is nine rules, and a screen is judged against them rather than against an opinion.

Fediqo draws with the platform's own controls and the platform's own chrome. That is a premise, not a preference:
a control the system draws is one the reader already knows, already reaches by keyboard, and already hears read
out loud. What is left for us is the layer above it — which glyph, how far apart, what a colour is allowed to
mean, and where the numbers come from. This document is that layer, written down.

The rules are numbered so a review can cite one. `S1` and `S8` are the two that a screen most often breaks.

## S1 — Icon first

An action is a glyph. Its words live in `help()` for a pointer and in the accessibility label for everything
else, not on the screen beside it.

A row of posts is read a hundred times a session and its actions are the same six every time. A label beside
each of them is six words the eye must skip on every row, and after the first screen it has stopped reading
them anyway.

Two things keep their words. One is where a mistake cannot be taken back — muting, blocking, reporting and
deleting — because the reader must be told what they are about to do, not reminded what they already know.
The other is where the control is the only thing naming what the reader is looking at: the button over a
covered post says **Show**, because an eye above a blur is a glyph with no convention to lean on, and a
reader who cannot read it cannot find out what was covered.

| what it is                                      | how it is drawn                                      |
| ----------------------------------------------- | ---------------------------------------------------- |
| an ordinary action                              | glyph only, with `help()` and an accessibility label |
| a destructive or one-way action                 | glyph and its words                                  |
| a control that is the only thing naming a state | glyph and its words                                  |
| a place to go                                   | glyph, and words where there is room for them        |

## S2 — One size per role

An interaction glyph is `Glyph.action`. What is hittable is at least `Hit.target` — 44 on iOS, 28 on macOS —
and that size is decided in `IconButton`, not at each call site.

A pointer aims and a finger covers. The two numbers are Apple's, and a screen that picks its own is a screen
that is hard to press on exactly one of the two platforms — which is the kind of bug nobody files.

## S3 — Group by space, not by lines

Related controls sit `Space.withinGroup` apart; groups sit at least twice that apart, and nothing is drawn
between them.

Rules between groups drew three boxes where what was wanted was three breaths. The eye reads a gap on its own,
and every line is one more mark competing with the marks that mean something.

## S4 — Colour is state

| colour           | what it means                  |
| ---------------- | ------------------------------ |
| grey (secondary) | at rest, nothing has been done |
| a tint           | on — this is a thing you did   |
| red              | this takes something away      |
| orange           | a server is unwell             |
| the accent       | where the reader is            |

Nothing is coloured to be pretty. A reader who cannot tell two hues apart still has every state available to
them, because each of these is also a filled or unfilled glyph, a word, or a position.

## S5 — Invent no numbers

A count that no server told us is not drawn. Zero means nobody, and it is never shown for a post that has no
idea — a row stored before the counts existed knows nothing, and drawing `0` there would be the screen making
something up.

The same holds for a switch: what nobody has told us about is drawn unfilled, and does not claim to mean "not
favourited".

## S6 — A row is bounded, and its columns line up

No row grows to hold what is in it. The words stop after a set number of lines with an ellipsis, and the
ellipsis is the row saying there is more; where there is room for two columns, the attachment column is
there whether or not anything is in it.

How many lines that is follows the reader's text scale and is never a fixed count. A count that fits at 13
points overflows at 21, and a row that overflowed would be the one row on the screen that is a different
shape from the rest.

**A short post is not padded up to a tall one.** This rule used to say every row was the same height, and
the app has never done that: the arrangement that stacks attachments under the words lets a row hug its
content and always has, which is every phone. What a reader scans by is a row that starts in the same place
and ends in a predictable one — and that is the clamp and the reserved column, not the padding. Padding
every row up to the tallest spends most of a screen saying nothing, which is what
[#79](https://github.com/cmj0121/fediqo/issues/79) measured: five posts became two.

## S7 — Native controls only

A control the platform does not draw is a new issue, not a quiet exception. If a screen needs something the
system has no equivalent for, that is a decision to be argued in the open, because it is the premise of the
whole interface that is being spent.

## S8 — Numbers come from tokens

Spacing, radius, type size and glyph size come from `Theme.swift`. A bare number in a view is a bug.

A number written in a view is a number that cannot be changed anywhere else. Two of them written a week apart
disagree, and the disagreement is invisible until the screens are put side by side.

| token       | what it is for                               |
| ----------- | -------------------------------------------- |
| `Space`     | every gap and every padding                  |
| `Radius`    | every corner                                 |
| `Glyph`     | every symbol size                            |
| `TypeScale` | every text size, always through `fediqoFont` |
| `Hit`       | the smallest thing worth pressing            |

Text is set with `fediqoFont` and never with `.font(.system(size:))`, because that is what carries the reader's
own text size down a tree macOS gives no Dynamic Type to. A symbol is set with `fediqoSymbol`, which does not
scale: a row's height is worked out from the text in it, and marks that grew with the text would overflow it.

What the rule forbids is an **unnamed** number, not a number. A measure that belongs to one view and to
nothing else — the width of the attachment column, the size of the composer panel, the rail's two widths —
is a named, documented `static let` on that view. It goes in `Size` when a second screen needs it.

## S9 — Fit the room, do not measure it

A view offers its arrangements widest first and takes the first that fits. It does not ask how many points it
has and decide from the answer.

A measured width is a guess about a device; `ViewThatFits` is an answer about this window. A phone, an iPad in
Slide Over, a Mac window being dragged narrower — each takes the widest arrangement it can hold, and a screen
size nobody has shipped yet is handled by construction rather than by a number somebody adds after the bug is
filed. A threshold has a second fault as well: it does not know the reader's text size. 560 points is a
comfortable row at 0.85× and an overflowing one at 1.6×, and on iOS this app's scale multiplies whatever
Dynamic Type the phone was already set to rather than replacing it.

A threshold is allowed where an arrangement cannot express the choice — where every row of a list must reach
the *same* answer, S6 being the reason, and an arrangement answers per row. Then it is a named `static let`
with its derivation written beside it, and **the part of it that is text is multiplied by the reader's
scale**. The part that is a picture is not: a picture is the size it is at every text size.

What this rule forbids is a screen that knows how wide it is. Adding a screen is not adding a boolean, and a
new device is not a new threshold.

## When a rule is in the way

A rule that is wrong is changed here, in the open, and the change is argued in
[#35](https://github.com/cmj0121/fediqo/issues/35). A screen that breaks one quietly is a screen that has
decided on everybody's behalf, which is the thing these nine sentences exist to stop.

## What this is not

This says nothing about what a screen shows or in what order — that is what the timeline, the composer and the
store are for. It governs how what is already decided is drawn, and nothing else.
