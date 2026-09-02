#!/usr/bin/env bash
#
# The pictures the two stores ask for, taken by a command rather than by a person.
#
#   scripts/shots.sh --macos      # both languages, 1280x800
#   scripts/shots.sh --ios        # both languages, both devices the store requires
#
# What a person does is look at them and judge them. Nobody takes them, nobody crops them, and
# nobody drags a window to the right size -- which is the whole of #30.
#
# They land where `deliver` looks: fastlane/screenshots/<platform>/<locale>/, named so that the
# order they upload in is the order they are read in, and so a person can tell which is which
# without opening them.
#
# ## The app is launched into each picture, never driven into it
#
# A hosted runner will not grant an app the accessibility permission UI testing needs -- measured,
# see #30 -- so there is no pressing anything. Every picture here is a state a launch variable can
# reach. A picture the list needs and the variables cannot reach is a variable to add, never a
# click to script.
#
# ## The Mac is photographed by the Mac app
#
# `screencapture` needs Screen Recording, which a hosted runner has and this project's laptop does
# not, and a command that works in one place is not one command. So the app draws itself -- see
# `Shooter` -- which needs no permission anywhere and pins the size at 1280x800 whatever the
# display happens to be.

set -euo pipefail

cd "$(dirname "$0")/.."

# The codes App Store Connect uses, which are not the codes this repository's documents use.
# `scripts/metadata.py` refuses anything else in the text tree; the pictures follow it.
LOCALES=(en-US zh-Hant)

# What each locale is called inside the app, which is a third spelling again: the app's own
# `AppLanguage`, as its raw values.
language_of() {
    case "$1" in
        en-US)   echo "en" ;;
        zh-Hant) echo "zh-TW" ;;
        *)       echo >&2 "shots: no app language for $1"; return 1 ;;
    esac
}

# The screens, in the order the store shows them. The name is the file name, so the numbers are
# what orders the upload -- deliver sorts by it and nothing else. The third field is whatever
# else that screen needs said to it, or nothing.
#
# **Statistics is not among them, on purpose.** That screen reads the store, and a run launched
# straight into it has never loaded a timeline, so the store is empty and the picture is a column
# of zeros. Nothing is wrong with the screen; it is that this list cannot press anything, and a
# screen that has to be arrived at cannot be arrived at. It goes back in the day either the
# fixture seeds the store or something can drive the app -- and a runner cannot drive it, see #30.
#
# What is here is what a person should look at and judge. Changing the list is changing these
# lines; nothing else knows what a screenshot is of.
SHOTS=(
    "01-timeline:timeline:"
    "02-trending:trend:"
    "03-composer:timeline:FEDIQO_COMPOSE=1"
    "04-settings:settings:"
)

MACOS_APP=".build/xcode/Build/Products/Debug/Fediqo.app"
IOS_APP=".build/xcode/Build/Products/Debug-iphonesimulator/Fediqo.app"
BUNDLE_ID="dev.mini-poc.fediqo"

# The two the store requires. Everything smaller Apple scales from these, so there is nothing to
# be gained by photographing a phone this list does not name.
IOS_DEVICES=(
    "iPhone 17 Pro Max"
    "iPad Pro 13-inch (M4)"
)

say() { printf '%s\n' "$*"; }

# ── macOS ────────────────────────────────────────────────────────────────────────────────────

macos() {
    say "building the Mac app"
    make -C Apps mac >/dev/null

    local binary="$MACOS_APP/Contents/MacOS/Fediqo"
    [ -x "$binary" ] || { echo >&2 "shots: no Mac app at $binary"; return 1; }

    for locale in "${LOCALES[@]}"; do
        local language out
        language="$(language_of "$locale")"
        out="fastlane/screenshots/macos/$locale"
        rm -rf "$out"; mkdir -p "$out"

        for shot in "${SHOTS[@]}"; do
            local name rail extra
            IFS=: read -r name rail extra <<< "$shot"
            say "  macos/$locale/$name"
            # The binary and not `open`: LaunchServices does not hand an app the environment of
            # whoever asked for it, so `FEDIQO_FIXTURE=1 open …` opens a real, empty store and
            # photographs a first launch. Found the hard way on a runner; see #30.
            #
            # `-ApplePersistenceIgnoreState` because macOS restores a window's frame from the
            # last session, and a screenshot run must not depend on where the last one was left.
            #
            # The app writes into its own container and says where, because #27 put it in a
            # box and the box is not going to be opened for a screenshot. What comes back on
            # stdout is that path; moving it out here is the whole of the difference.
            local wrote
            wrote="$(env FEDIQO_FIXTURE=1 \
                         FEDIQO_ROUTE=shell \
                         FEDIQO_RAIL="$rail" \
                         FEDIQO_LANGUAGE="$language" \
                         FEDIQO_SHOOT="$name.png" \
                         ${extra:-IGNORED=} \
                         "$binary" -ApplePersistenceIgnoreState YES 2>/dev/null \
                     | sed -n 's/^shot: //p')"
            [ -n "$wrote" ] && [ -f "$wrote" ] || {
                echo >&2 "shots: the app took no picture for $locale/$name"
                return 1
            }
            mv "$wrote" "$out/$name.png"
        done
    done
    check macos
}

# ── iOS ──────────────────────────────────────────────────────────────────────────────────────

ios() {
    say "building the iOS app"
    make -C Apps ios >/dev/null
    [ -d "$IOS_APP" ] || { echo >&2 "shots: no iOS app at $IOS_APP"; return 1; }

    for locale in "${LOCALES[@]}"; do
        local language out
        language="$(language_of "$locale")"
        out="fastlane/screenshots/ios/$locale"
        rm -rf "$out"; mkdir -p "$out"

        local index=0
        for device in "${IOS_DEVICES[@]}"; do
            index=$((index + 1))
            local udid
            udid="$(udid_of "$device")" || return 1
            say "  booting $device"
            xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || xcrun simctl boot "$udid" >/dev/null 2>&1 || true
            xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
            xcrun simctl install "$udid" "$IOS_APP" >/dev/null

            for shot in "${SHOTS[@]}"; do
                local name rail extra
                IFS=: read -r name rail extra <<< "$shot"
                say "  ios/$locale/$index-$name"
                xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
                env SIMCTL_CHILD_FEDIQO_FIXTURE=1 \
                    SIMCTL_CHILD_FEDIQO_ROUTE=shell \
                    SIMCTL_CHILD_FEDIQO_RAIL="$rail" \
                    SIMCTL_CHILD_FEDIQO_LANGUAGE="$language" \
                    ${extra:+SIMCTL_CHILD_$extra} \
                    xcrun simctl launch "$udid" "$BUNDLE_ID" >/dev/null
                # The same wait `Shooter` gives the Mac, and for the same reason: layout, and
                # an `AsyncImage` reading a file out of the fixture's own directory.
                sleep 4
                xcrun simctl io "$udid" screenshot "$out/$index-$name.png" >/dev/null 2>&1
                [ -f "$out/$index-$name.png" ] || { echo >&2 "shots: $out/$index-$name.png was not written"; return 1; }
            done
            xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
        done
    done
    check ios
}

udid_of() {
    local found
    found="$(xcrun simctl list devices available | grep -m1 -F "$1 (" | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')"
    [ -n "$found" ] || { echo >&2 "shots: no simulator called '$1' -- what this Xcode has is not what this list names"; return 1; }
    printf '%s' "$found"
}

# ── what came out ────────────────────────────────────────────────────────────────────────────

# Every picture, with its size, so that a wrong one is found here rather than by App Store
# Connect after an archive has been built, signed and uploaded.
check() {
    say ""
    say "fastlane/screenshots/$1:"
    local file
    while IFS= read -r file; do
        printf '  %-44s %s\n' "${file#fastlane/screenshots/$1/}" \
            "$(sips -g pixelWidth -g pixelHeight "$file" | awk '/pixel/ {printf "%s ", $2}')"
    done < <(find "fastlane/screenshots/$1" -name '*.png' | sort)
}

case "${1:-}" in
    --macos) macos ;;
    --ios)   ios ;;
    *)       echo >&2 "usage: ${0##*/} [--macos | --ios]"; exit 2 ;;
esac
