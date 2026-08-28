# The rules a screen is drawn by

[English](interface.md) | [繁體中文](interface.zh-TW.md)

> The look is not a taste. It is eight rules, and a screen is judged against them rather than against an opinion.

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
them anyway. The exception is where a mistake cannot be taken back: muting, blocking, reporting and deleting
carry their words, because the reader must be told what they are about to do, not reminded what they already
know.

| what it is                      | how it is drawn                                      |
| ------------------------------- | ---------------------------------------------------- |
| an ordinary action              | glyph only, with `help()` and an accessibility label |
| a destructive or one-way action | glyph and its words                                  |
| a place to go                   | glyph, and words where there is room for them        |

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

| colour           | what it means                          |
| ---------------- | -------------------------------------- |
| grey (secondary) | at rest, nothing has been done         |
| a tint           | on — this is a thing you did           |
| red              | this takes something away              |
| orange           | a server is unwell                     |
| the accent       | where the reader is                    |

Nothing is coloured to be pretty. A reader who cannot tell two hues apart still has every state available to
them, because each of these is also a filled or unfilled glyph, a word, or a position.

## S5 — Invent no numbers

A count that no server told us is not drawn. Zero means nobody, and it is never shown for a post that has no
idea — a row stored before the counts existed knows nothing, and drawing `0` there would be the screen making
something up.

The same holds for a switch: what nobody has told us about is drawn unfilled, and does not claim to mean "not
favourited".

## S6 — Every row the same height

`AttachmentDeck.height` sets the height of a row in a list. A short post is padded up to it; a long one stops
at it with an ellipsis, and the ellipsis is the row saying there is more.

How many lines fit is worked out from that height at the reader's own text scale, never fixed at a count. A
count that fits at 13 points overflows at 21, and a list whose rows are different heights cannot be scanned.

## S7 — Native controls only

A control the platform does not draw is a new issue, not a quiet exception. If a screen needs something the
system has no equivalent for, that is a decision to be argued in the open, because it is the premise of the
whole interface that is being spent.

## S8 — Numbers come from tokens

Spacing, radius, type size and glyph size come from `Theme.swift`. A bare number in a view is a bug.

A number written in a view is a number that cannot be changed anywhere else. Two of them written a week apart
disagree, and the disagreement is invisible until the screens are put side by side.

| token       | what it is for                                             |
| ----------- | ---------------------------------------------------------- |
| `Space`     | every gap and every padding                                |
| `Radius`    | every corner                                               |
| `Glyph`     | every symbol size                                          |
| `TypeScale` | every text size, always through `fediqoFont`               |
| `Hit`       | the smallest thing worth pressing                          |

Text is set with `fediqoFont` and never with `.font(.system(size:))`, because that is what carries the reader's
own text size down a tree macOS gives no Dynamic Type to.

## When a rule is in the way

A rule that is wrong is changed here, in the open, and the change is argued in
[#35](https://github.com/cmj0121/fediqo/issues/35). A screen that breaks one quietly is a screen that has
decided on everybody's behalf, which is the thing these eight sentences exist to stop.

## What this is not

This says nothing about what a screen shows or in what order — that is what the timeline, the composer and the
store are for. It governs how what is already decided is drawn, and nothing else.
