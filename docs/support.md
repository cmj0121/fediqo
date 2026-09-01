# Support

[English](support.md) | [繁體中文](support.zh-TW.md)

> The fastest way to be helped is an issue with the version in it.

## Where to ask

[github.com/cmj0121/fediqo/issues](https://github.com/cmj0121/fediqo/issues) -- open a new one, or add to
the one already describing what you hit. If it belongs in public no more than it has to, mail <cmj@cmj.tw>
instead.

## What to say

| Tell us               | Because                                                          |
| --------------------- | ---------------------------------------------------------------- |
| the version and build | About Fediqo on the Mac, the build page in TestFlight on the phone |
| macOS or iOS          | the two apps share a timeline and not their bugs                 |
| which server          | protocols are implemented per server, and servers differ         |
| what you expected     | half the reports here turn out to be a disagreement, not a bug   |

Never send an access token, a password or the contents of your Keychain. Nothing we can ask for needs one.

## What we cannot help with

Fediqo talks to servers it does not run. An account that is suspended, a post that will not federate or a
server that is down is that server's business -- ask its administrator. We can help you tell which it is.

## Common answers

**A server stops handing anything over.** Its token expired or was withdrawn. The handle on that row in
Settings turns orange when the server has stopped accepting the account; sign in to it again there.

**A post appears once, and it was on two servers.** That is the point -- the same post from several places is
one row. The row says which servers carried it.

**Statistics says the split between sources is an estimate.** It is. The store is counted exactly; which
server a merged row came from is not a thing a count can settle, and the screen says which of its numbers is
which rather than inventing a precise one.

**A build made before the sandbox cannot see my data.** The macOS app moved into its own container. Nothing
migrates the old location, and what was there is still in `~/Library/Application Support/`.
