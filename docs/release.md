# Releasing

[English](release.md) | [繁體中文](release.zh-TW.md)

> `make publish` archives both apps, signs them, hands them to TestFlight, and tells the store what this checkout
> says. Nothing is ever submitted for review.

Building and testing this checkout needs none of what follows. Only `make publish` reads any of it, which is the
point: a pull request has no credentials and must go on not needing any.

## What the one command does

```text
  make publish
       │
       ▼
  scripts/env.sh ──── loads .env if there is one, then execs what it was given.
       │              Everything past here reads the environment and nothing else,
       │              so a laptop and a runner run the same code.
       ▼
  fastlane publish
       │
       ├── scripts/metadata.py -- the store text, before anything is built: the language
       │   folders, the lengths, the links, and that this version has release notes
       ├── setup_ci -- a temporary keychain, on a runner; nothing at all on a laptop
       │
       ├── ask App Store Connect which build numbers it already holds, one platform at a time
       ├── take max(commit count, the highest it holds + 1) -- one number, both platforms
       │
       ├── iOS     match ──▶ archive ──▶ .ipa ──▶ TestFlight ──▶ store text
       └── macOS   match ──▶ archive ──▶ .pkg ──▶ TestFlight ──▶ store text
                                         └─ signed by the installer identity;
                                            the Mac App Store takes nothing else
```

## Before the first time

```sh
bundle install                  # fastlane, pinned, into vendor/
cp .env.example .env
$EDITOR .env
scripts/env.sh --check          # names only -- it never prints a value
```

`--check` ends by saying which way in it would use, or that there is no whole way in. Half a group is no group:
two of three names filled is not a way in, and it will say so rather than find out at the upload.

| name                  | what it is                                                          |
| --------------------- | ------------------------------------------------------------------- |
| `FEDIQO_TEAM_ID`      | the Apple Developer Program team the identities belong to           |
| `FEDIQO_BUNDLE_ID`    | one identifier, both platforms, one record in App Store Connect     |
| `MATCH_GIT_URL`       | where the certificates and profiles live, encrypted                 |
| `MATCH_PASSWORD`      | that repository's passphrase, if the keychain does not already hold it |
| `ASC_KEY_ID`          | the App Store Connect key: the way in that needs nobody             |
| `ASC_ISSUER_ID`       | ... its issuer, one per team                                        |
| `ASC_KEY_P8_BASE64`   | ... and the `.p8` itself, base64                                    |
| `FEDIQO_APPLE_ID`     | the other way in, which asks a person for a second factor           |
| `FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD` | ... its app-specific password, named by fastlane |

Leave what you do not fill in commented out. A name with nothing after it is not the same as a name left out:
fastlane reads `.env` too, and in Ruby an empty string is true, so an empty `MATCH_PASSWORD=` is taken for the
passphrase and the keychain is never asked.

## The two ways in

The lane takes whichever is whole, and prefers the key where both are.

The **App Store Connect key** works with nobody watching. Its role has to be **App Manager** -- a Developer can
neither create a provisioning profile nor upload a build. The `.p8` is offered for download exactly once, and is
carried here as base64 rather than as a path, because a path is a thing only a laptop has.

The **Apple ID** works today and stops to ask for a second factor. Apple's session lasts about a month and can be
renewed no other way, so this is the way that can never be what a runner uses.

## What a build calls itself

The marketing version comes from `scripts/version.sh`: the tag on `HEAD` with its `v` removed, or the nearest tag
with a line saying it had to settle, or `0.0.0` where there has never been a release.

The build number is the history, stepped past whatever App Store Connect already holds -- the same commit released
twice counts the same commits twice, and the store will not take a number it has seen. Both platforms take the same
number, because a release attempt is one attempt however many stores it reaches.

**No tag is required to run this.** A tag is what makes a release happen -- it is what the workflow will fire on --
but it is not what makes the command work. A laptop publishes whenever somebody types it.

## What the store is told

The description, the keywords, the name, the subtitle and the two links are files in this checkout. They are
what gets uploaded, in the same run that uploaded the build, and nothing about them is ever typed into a browser.

```text
  fastlane/metadata/
      ios/    en-US/  description.txt keywords.txt name.txt subtitle.txt support_url.txt privacy_url.txt
              zh-Hant/ …
      macos/  en-US/  …
              zh-Hant/ …
      notes/  0.1.0/  en-US.txt zh-Hant.txt
```

**The language folders are `en-US` and `zh-Hant`.** Not `zh-TW`, which is the code every document in this
repository uses and is not a code App Store Connect knows. deliver does not complain about a folder it does not
recognise; it uploads the ones it does and says nothing about the rest, which is a release that went out in one
language while somebody was sure it went out in two. `scripts/metadata.py` is what refuses.

```sh
scripts/metadata.py                     # the tree, the lengths, the links
scripts/metadata.py --version 0.1.0     # ... and that this version has release notes
scripts/metadata.py --resolve           # ... and that the links answer
```

It also runs as a pre-commit hook, and `make publish` runs all three before it builds anything -- a description
of 4001 characters is rejected by App Store Connect after forty minutes of archiving, and by that script in a
second.

**A platform's own text is its own; the app's text is shared.** The description, the keywords and the support
link belong to a version of one platform. The name, the subtitle and the privacy link belong to the app, and App
Store Connect keeps one of each per language whichever platform uploaded it last -- so both trees carry them and
`metadata.py` refuses to let the two copies drift.

**Release notes are named after the version, not left in the language folders.** A `release_notes.txt` beside
the description is one file overwritten every release, and the release that forgets to overwrite it ships the
last one's words without a sound. `notes/0.1.0/en-US.txt` cannot be forgotten: a tag with no folder of its own
has nothing to read, and `make publish` stops before it builds. Write them before the tag.

**The privacy answers are the one thing not uploaded from here.** `deliver` has no way to answer App Store
Connect's privacy questionnaire -- it carries the privacy *link* and nothing else. Fediqo collects nothing, so
the answer is **Data Not Collected**, ticked once by hand under App Privacy, and it stays true for as long as
[`docs/privacy.md`](privacy.md) does. What the code does is checkable: one dependency, no analytics, no
third-party SDK of any kind.

The screenshots are not here yet ([#30](https://github.com/cmj0121/fediqo/issues/30)). When they arrive at
`fastlane/screenshots/<platform>/`, the lane picks them up and uploads them in the same run without being told.

## The tag that runs it

Pushing a tag is the whole of it.

```sh
git tag v0.1.0
git push origin v0.1.0
```

[`.github/workflows/release.yml`](../.github/workflows/release.yml) fires on `v*`, and every step in it is
either a `brew install` or `make publish`. Nothing about releasing is written down in that file: what the build
is called, which certificate signs it, what the store is told and that nothing is submitted for review are all
decisions the Fastfile makes, and a laptop makes them the same way.

A release that failed at the upload is run again from the same tag -- **Actions → Release → Run workflow**, and
pick the tag in the dropdown. Nobody has to invent a `v0.1.1` because the pipeline could not be asked twice.

The runner is handed by its secret store exactly what `.env` hands a laptop:

| secret                          | how it differs from the laptop's                             |
| ------------------------------- | ------------------------------------------------------------ |
| `FEDIQO_TEAM_ID`                | the same                                                     |
| `FEDIQO_BUNDLE_ID`              | the same                                                     |
| `MATCH_GIT_URL`                 | the HTTPS form -- a runner has no ssh key to clone with      |
| `MATCH_GIT_BASIC_AUTHORIZATION` | required here, unused on a laptop                            |
| `MATCH_PASSWORD`                | required here: there is no keychain to have remembered it    |
| `ASC_KEY_ID`                    | required here -- the Apple ID way needs a person watching    |
| `ASC_ISSUER_ID`                 | ... its issuer                                               |
| `ASC_KEY_P8_BASE64`             | ... and the `.p8`, base64, which is why it is not a path     |

`setup_ci` in the publish lane makes the temporary keychain match needs. Off CI it does nothing, which is why
it can be the same line on both machines.

## Getting a build to a person

Uploading invites nobody. A build reaches a person only through a TestFlight group with people in it.

Internal testers are not invited by e-mail address; they are picked from the team's existing App Store Connect
users, and the account has to have access to this app under **Users and Access**. The group this project uses is
`dev`, and it takes every new build on its own, so nothing has to name it at upload time.

```sh
scripts/env.sh -- bundle exec fastlane pilot add "$FEDIQO_APPLE_ID" -g dev -u "$FEDIQO_APPLE_ID" -a "$FEDIQO_BUNDLE_ID"
```

The Mac build installs through the TestFlight app on macOS. It is the same App Store Connect record as the phone,
under its other platform.

## When it goes wrong

Most of what breaks here breaks somewhere other than where it is reported.

**`Invalid password passed via 'MATCH_PASSWORD'`** -- an empty `MATCH_PASSWORD=` in `.env`. Empty is true in
Ruby, so match took it for the passphrase and never asked the keychain.

**A macOS archive appears while an iOS lane is running** -- a scheme that is not shared. fastlane cannot find the
name it was given, and rather than stopping it takes the first scheme in the project.

**`requires a provisioning profile`** -- Release signs manually and the archive was not told which profile. Naming
it only in the export options is too late; there is nothing to export.

**`doesn't include signing certificate "Apple Distribution: ..."`** -- more than one certificate of that name is
installed. xcodebuild picks by name and says nothing about which; this lane picks by fingerprint, taken out of the
profile that will have to accept it.

**`has conflicting provisioning settings`** on `GRDB_GRDB` or a `Fediqo_*` bundle -- signing was handed to the
build instead of written into the target, so it reached the resource bundles Swift Package Manager generates.

**`Certificate '...' is not available on the Developer Portal`** -- what the certificate repository holds has
expired or been revoked. Remove it there and let match make a new one.

**`No orientations were specified` (90474)** -- `TARGETED_DEVICE_FAMILY` includes the iPad, and an app that cannot
be a third of a screen cannot be on one. All four `UISupportedInterfaceOrientations` have to be declared.

**`Could not find pkg file at path ...`** -- gym appends the extension itself, so an `output_name` that already
carries one comes back doubled.

## The certificate repository is shared

`MATCH_GIT_URL` points at a repository several apps on this team use. match keeps them apart by bundle identifier,
so sharing costs nothing -- but the certificates themselves are shared, and that cuts both ways. Replacing one that
expired fixes every app on the team. `match nuke` breaks every one of them.

Its default branch is `main`. `fastlane/Matchfile` says so out loud, because match looks for `master` unless told.

## What is not here yet

The screenshots ([#30](https://github.com/cmj0121/fediqo/issues/30)). Until a command takes them, the two stores
are shown whatever was last uploaded by hand, and the lane uploads no pictures at all rather than uploading none
-- which App Store Connect would read as an answer.

A release reaches TestFlight and stops there. That is where anything nobody has looked at ought to stop.

The macOS app runs under App Sandbox, so its database is in `~/Library/Containers/dev.mini-poc.fediqo/` rather than
in `~/Library/Application Support/`. A build made before the sandbox cannot see what a build made after it writes,
and nothing migrates the one to the other.
