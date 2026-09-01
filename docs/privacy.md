# Privacy

[English](privacy.md) | [繁體中文](privacy.zh-TW.md)

> Fediqo collects nothing. There is no Fediqo server for anything to be collected on.

This is the policy the App Store links to. It describes the app in this repository, which is the only Fediqo
there is -- everything it claims can be checked by building the source it is written about.

## What we collect

Nothing.

There is no account with us, no analytics, no crash reporting, no advertising identifier, no third-party SDK
of any kind. The app has one external dependency, [GRDB](https://github.com/groue/GRDB.swift), and it is an
SQLite library that never leaves the device.

## What leaves your device, and where it goes

Only to the servers you chose, and only because you asked:

| When                    | What goes                                             | Where it goes                          |
| ----------------------- | ----------------------------------------------------- | -------------------------------------- |
| you sign in             | the app registration and the OAuth exchange           | the server you named, through your browser |
| you read a timeline     | a request for posts, carrying your access token       | the servers you added                  |
| a post carries media    | a request for the image or the video                  | wherever that server hosts its media   |
| you post, reply or boost | what you wrote, once to each network you chose       | the servers you chose                  |

Nothing is relayed. There is no Fediqo server in the middle of any of those lines, which is the whole of the
privacy claim -- no more, and no less. Once a request reaches a server you added, that server's own policy
governs what it does with it, and we are not a party to it.

## What stays on your device

Your access tokens are in the system Keychain. Everything else -- the posts you read, what you kept, the
servers you added, your settings -- is in one SQLite database in the app's own container, alongside the app.
Trends and digests are worked out from that database, on your device.

Deleting the app deletes the database with it. Tokens can be revoked on the server that issued them.

## Children

Fediqo is not directed at children and asks for no age, no name and no identity of any kind.

## Changes

This file is versioned with the app. What a release was told to say is what this file said at its tag.

## Contact

Questions about this policy: <cmj@cmj.tw>, or an issue at
[github.com/cmj0121/fediqo/issues](https://github.com/cmj0121/fediqo/issues).
