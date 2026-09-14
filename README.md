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
pass through, which is the whole of the privacy claim — no more, and no less.

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

An empty launch opens Account. Add an unsigned Mastodon host from the catalog or by
typing its hostname. It names the protocol; only Mastodon joins this session.
Public and trending notes land in an in-memory store. All and Trends are queries of
that store. Timeline, notices and compose stay off until they have something.
The data is gone on relaunch. There is no OAuth.

This checkout has no release tag yet: the mascot, and a session-only Mastodon source, in memory.

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
