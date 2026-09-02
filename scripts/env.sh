#!/usr/bin/env bash
#
# What the release lane is allowed to know, and where it learned it.
#
#   scripts/env.sh --check                    # which names are set, never what they hold
#   scripts/env.sh -- bundle exec fastlane …  # run that, with .env loaded first
#
# A laptop keeps these in .env at the root; a runner already has them in its environment
# under the same names. Everything past this point reads the environment and nothing else,
# so no lane has to know which machine it is standing on -- which is the whole of what #28
# asks for.
#
# .env is parsed, never sourced. Sourcing would run whatever the file happens to say, and
# would let a line left there last month quietly beat a value exported for one run. Here the
# environment always wins and the file only fills what it finds missing.
#
# Nothing in here prints a value. A secret that reaches a terminal has reached a scrollback,
# and a scrollback is not a place a signing key should be.

set -euo pipefail

cd "$(dirname "$0")/.."

ENV_FILE=".env"

# What the release lane cannot work without, whichever way it proves who is asking.
#
# The four review names are here rather than in a file because this repository is public and
# they are a person's: their name, their telephone number, their address. They are required
# for the same reason the team is -- App Store Connect will not hold a version without a
# review detail, and the release that discovers this discovers it after the archive, after
# TestFlight, and calls it `No data`.
REQUIRED=(
    FEDIQO_TEAM_ID
    FEDIQO_BUNDLE_ID
    MATCH_GIT_URL
    FEDIQO_REVIEW_FIRST_NAME
    FEDIQO_REVIEW_LAST_NAME
    FEDIQO_REVIEW_PHONE
    FEDIQO_REVIEW_EMAIL
)

# And then one of two ways to sign in to Apple, whole or not at all.
#
# The key is the one that works with nobody watching, which is the only kind that survives a
# runner. The Apple ID is the one that works today and asks a person for a second factor;
# it is here so that a missing .p8 postpones the runner rather than the release.
KEY_AUTH=(
    ASC_KEY_ID
    ASC_ISSUER_ID
    ASC_KEY_P8_BASE64
)

APPLE_ID_AUTH=(
    FEDIQO_APPLE_ID
    FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD
)

# MATCH_PASSWORD is missing on a laptop that told match its passphrase once already -- match
# reads it back out of the keychain. A runner has no keychain to read it from, so there it
# has to be set; that belongs to the pass that writes the workflow, not to this one.
OPTIONAL=(
    MATCH_PASSWORD
    MATCH_GIT_BASIC_AUTHORIZATION
)

# Indirection, spelled the one way that means the same thing on every bash this might meet.
value_of() {
    eval "printf '%s' \"\${$1-}\""
}

trim() {
    local text="$1"
    text="${text#"${text%%[![:space:]]*}"}"
    text="${text%"${text##*[![:space:]]}"}"
    printf '%s' "$text"
}

load() {
    [ -f "$ENV_FILE" ] || return 0

    local line name value

    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        line="$(trim "$line")"

        case "$line" in
            '' | '#'*) continue ;;
        esac

        name="${line%%=*}"
        [ "$name" != "$line" ] || {
            echo >&2 "env.sh: $ENV_FILE: a line without '=' sets nothing -- skipped"
            continue
        }

        value="$(trim "${line#*=}")"
        name="$(trim "${name#export }")"

        [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
            echo >&2 "env.sh: $ENV_FILE: '$name' is not a name -- skipped"
            continue
        }

        # An exported value beats the file, so `ASC_KEY_ID=… make publish` works for one run
        # without anyone editing .env and forgetting to put it back.
        [ -z "$(value_of "$name")" ] || continue

        case "$value" in
            '"'*'"' | "'"*"'") value="${value:1:${#value} - 2}" ;;
        esac

        # A name with nothing after the '=' is a name nobody filled in, and exporting it empty
        # is worse than leaving it alone: `MATCH_PASSWORD=` in the file reads to match as a
        # passphrase that happens to be the empty string, and it stops looking in the keychain
        # where the real one is. Empty is unset here, as it is everywhere else in this file.
        [ -n "$value" ] || continue

        export "$name=$value"
    done < "$ENV_FILE"
}

# Whether every name in a group is set. Half a group is no group.
complete() {
    local name

    for name in "$@"; do
        [ -n "$(value_of "$name")" ] || return 1
    done
}

# Which way the lane will sign in, or nothing where neither way is whole. The key wins where
# both are there: it is the one that does not stop to ask anybody anything.
auth_path() {
    if complete "${KEY_AUTH[@]}"; then
        echo key
    elif complete "${APPLE_ID_AUTH[@]}"; then
        echo apple-id
    fi
}

# What is still missing, one line each. Says nothing about what is already there.
missing() {
    local name

    for name in "${REQUIRED[@]}"; do
        [ -n "$(value_of "$name")" ] || echo "$name"
    done

    [ -n "$(auth_path)" ] || {
        echo "all of ${KEY_AUTH[*]}"
        echo "or all of ${APPLE_ID_AUTH[*]}"
    }
}

check() {
    local name gap

    if [ -f "$ENV_FILE" ]; then
        echo "$ENV_FILE: read"
    else
        echo "$ENV_FILE: not here -- whatever the environment already holds is all there is"
    fi

    for name in "${REQUIRED[@]}" "${KEY_AUTH[@]}" "${APPLE_ID_AUTH[@]}"; do
        if [ -n "$(value_of "$name")" ]; then
            printf '  %-46s set\n' "$name"
        else
            printf '  %-46s unset\n' "$name"
        fi
    done

    for name in "${OPTIONAL[@]}"; do
        if [ -n "$(value_of "$name")" ]; then
            printf '  %-46s set\n' "$name"
        else
            printf '  %-46s unset, and allowed to be\n' "$name"
        fi
    done

    case "$(auth_path)" in
        key)      echo "signs in with the App Store Connect key -- nobody has to be watching" ;;
        apple-id) echo "signs in as the Apple ID -- expect to be asked for a second factor" ;;
        *)        echo "no whole way to sign in" ;;
    esac

    gap="$(missing)"
    [ -z "$gap" ] || {
        echo >&2
        echo >&2 "env.sh: the release lane is still missing this -- see .env.example"
        echo "$gap" | sed 's/^/  /' >&2
        return 1
    }
}

run() {
    local gap

    gap="$(missing)"
    [ -z "$gap" ] || {
        echo >&2 "env.sh: refusing to run -- these are not set:"
        echo "$gap" | sed 's/^/  /' >&2
        echo >&2 "See .env.example. 'scripts/env.sh --check' says the same thing without running anything."
        return 1
    }

    exec "$@"
}

load

case "${1:-}" in
    --check)
        check
        ;;
    --)
        shift
        [ $# -gt 0 ] || { echo >&2 "env.sh: '--' with nothing after it"; exit 2; }
        run "$@"
        ;;
    *)
        echo >&2 "usage: ${0##*/} [--check | -- COMMAND [ARG…]]"
        exit 2
        ;;
esac
