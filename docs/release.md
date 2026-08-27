# Releasing

[English](release.md) | [繁體中文](release.zh-TW.md)

> `make publish` archives both apps, signs them, and hands them to TestFlight. Nothing is ever submitted for review.

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
       ├── ask App Store Connect which build numbers it already holds, one platform at a time
       ├── take max(commit count, the highest it holds + 1) -- one number, both platforms
       │
       ├── iOS     match ──▶ archive ──▶ .ipa ──▶ TestFlight
       └── macOS   match ──▶ archive ──▶ .pkg ──▶ TestFlight
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

The screenshots ([#30](https://github.com/cmj0121/fediqo/issues/30)), the store text
([#31](https://github.com/cmj0121/fediqo/issues/31)) and the workflow that fires on a tag are still outside this
command. Until they arrive, a release reaches TestFlight and stops there, which is where anything that has not been
looked at ought to stop.

The macOS app runs under App Sandbox, so its database is in `~/Library/Containers/dev.mini-poc.fediqo/` rather than
in `~/Library/Application Support/`. A build made before the sandbox cannot see what a build made after it writes,
and nothing migrates the one to the other.
