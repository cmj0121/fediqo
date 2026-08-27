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

# What the release lane cannot work without.
REQUIRED=(
    FEDIQO_TEAM_ID
    FEDIQO_BUNDLE_ID
    ASC_KEY_ID
    ASC_ISSUER_ID
    ASC_KEY_P8_BASE64
    MATCH_GIT_URL
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

        export "$name=$value"
    done < "$ENV_FILE"
}

# The names still missing, one per line. Says nothing about the ones that are there.
missing() {
    local name

    for name in "${REQUIRED[@]}"; do
        [ -n "$(value_of "$name")" ] || echo "$name"
    done
}

check() {
    local name gap

    if [ -f "$ENV_FILE" ]; then
        echo "$ENV_FILE: read"
    else
        echo "$ENV_FILE: not here -- whatever the environment already holds is all there is"
    fi

    for name in "${REQUIRED[@]}"; do
        if [ -n "$(value_of "$name")" ]; then
            printf '  %-32s set\n' "$name"
        else
            printf '  %-32s MISSING\n' "$name"
        fi
    done

    for name in "${OPTIONAL[@]}"; do
        if [ -n "$(value_of "$name")" ]; then
            printf '  %-32s set\n' "$name"
        else
            printf '  %-32s unset, and allowed to be\n' "$name"
        fi
    done

    gap="$(missing)"
    [ -z "$gap" ] || {
        echo >&2
        echo >&2 "env.sh: the release lane still needs $(echo "$gap" | wc -l | tr -d ' ') of these -- see .env.example"
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
