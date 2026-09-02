ROOT            := ..
MACOS_SCHEME    := Fediqo
IOS_SCHEME      := Fediqo-iOS
XCODEPROJ       := $(ROOT)/Fediqo.xcodeproj
DERIVED         := $(ROOT)/.build/xcode

# Nothing about compiling needs a particular simulator, and a device named here is a name that
# rots: it exists on one machine and not on the next, or it is left holding a runtime nobody
# installed. The generic destination always resolves, so a laptop and a runner ask for the
# same thing. Pass a real one when you mean a real one:
#
#     make -C Apps ios IOS_DESTINATION='platform=iOS Simulator,name=iPhone 17'
IOS_DESTINATION ?= generic/platform=iOS Simulator
MASCOT          := $(ROOT)/Sources/FediqoUI/Resources/Media.xcassets/Mascot.imageset/mascot.svg
# Where the UI run leaves what it did, and what the coverage is read out of.
UITEST_RESULT   := $(DERIVED)/uitest.xcresult
UITEST_IOS_RESULT := $(DERIVED)/uitest-ios.xcresult

# The simulator the driven tests run on, found rather than named -- the same reason
# IOS_DESTINATION is generic: a device named here exists on one machine and not on the next.
# The first available iPad, whatever this Xcode ships.
#
# An iPad and not a phone. On a compact screen the rail is a `TabView`, which keeps every tab
# alive, so leaving a page and coming back would not rebuild the timeline and the test that
# matters most would pass without asking anything. Override it when you mean a particular one:
#
#     make -C Apps uitest-ios UITEST_IOS_ID=<udid>
UITEST_IOS_ID  ?= $(shell xcrun simctl list devices available | grep -m1 -E '^ *iPad' | \
	sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')

# Deferred, not `:=` -- a `make help` should not go asking git what the version is. The two
# come from scripts/version.sh so a build here and a build on a runner agree by construction
# rather than by someone remembering to keep two numbers in step.
VERSION        = $(shell $(ROOT)/scripts/version.sh --marketing)
BUILD_NUMBER   = $(shell $(ROOT)/scripts/version.sh --build)
STAMP          = MARKETING_VERSION=$(VERSION) CURRENT_PROJECT_VERSION=$(BUILD_NUMBER)

.PHONY: all run mac ios uitest uitest-ios publish shots shots-macos shots-ios version xcodeproj sync-assets clean test build upgrade help

all: help			# default action

run: mac			# build and launch the macOS app
	@open $(DERIVED)/Build/Products/Debug/Fediqo.app

# `| tail` is here because xcodebuild says a great deal and only the end of it is news. A
# pipeline reports the exit status of its last command, though, so without pipefail the tail
# would report success for every build that ever failed -- which is what CI was doing.
#
# The whole of what it said is kept beside the build. The last five lines name the files that
# failed and never the reason, so a build that broke on a runner and nowhere else left a log
# with no error in it at all -- which is a failure nobody can read, and one this project has
# already spent an afternoon on.
mac: xcodeproj		# build the macOS app
	@mkdir -p $(DERIVED)
	@set -o pipefail; xcodebuild -project $(XCODEPROJ) -scheme $(MACOS_SCHEME) \
		-configuration Debug -derivedDataPath $(DERIVED) \
		-destination 'platform=macOS' $(STAMP) build 2>&1 \
		| tee $(DERIVED)/mac-build.log | tail -5

ios: xcodeproj		# build the iOS app for the simulator
	@mkdir -p $(DERIVED)
	@set -o pipefail; xcodebuild -project $(XCODEPROJ) -scheme $(IOS_SCHEME) \
		-configuration Debug -derivedDataPath $(DERIVED) \
		-destination '$(IOS_DESTINATION)' $(STAMP) build 2>&1 \
		| tee $(DERIVED)/ios-build.log | tail -5

# The tests that need the app running. `swift test` reaches Core and the models above it and
# stops where SwiftUI begins -- nothing in a package can execute a view body -- so what a reader
# actually does is driven from here, by a second process that launches the first one.
#
# Thirty lines and not five, which is what everything else here keeps. A failed test says which
# test and why on separate lines and the rest of the run is between them, so five lines is the
# name with the reason cut off -- a job log that says something failed and refuses to say what.
#
# The result bundle is removed first because xcodebuild refuses to write over one; it is what a
# runner keeps when something fails. The coverage is read from the profile the run left in the
# derived data, not from the bundle -- see `scripts/ui_coverage.sh` for why -- and it is
# reported rather than gated: `scripts/coverage.sh` gates Core, and what this number should be
# is a question nobody can answer until it has been run a few times.
uitest: xcodeproj	# run the tests that drive the macOS app
	@rm -rf $(UITEST_RESULT)
	@set -o pipefail; xcodebuild -project $(XCODEPROJ) -scheme $(MACOS_SCHEME) \
		-configuration Debug -derivedDataPath $(DERIVED) \
		-destination 'platform=macOS' -enableCodeCoverage YES \
		-resultBundlePath $(UITEST_RESULT) $(STAMP) test 2>&1 \
		| tee $(DERIVED)/uitest.log | tail -30
	@$(ROOT)/scripts/ui_coverage.sh $(DERIVED)

# The same tests, the same app, on the simulator -- and the one CI can run. A hosted macOS
# runner will not grant an app the accessibility permission UI testing needs, so every test
# there fails at launch waiting sixty seconds for it; a simulator has no such trouble. The
# macOS target above stays because it is the app a person actually uses and needs no simulator
# booted to run.
uitest-ios: xcodeproj	# run the tests that drive the app on an iPad simulator
	@[ -n "$(UITEST_IOS_ID)" ] || { echo "no iPad simulator available"; exit 1; }
	@mkdir -p $(DERIVED)
	@rm -rf $(UITEST_IOS_RESULT)
	@set -o pipefail; xcodebuild -project $(XCODEPROJ) -scheme $(IOS_SCHEME) \
		-configuration Debug -derivedDataPath $(DERIVED) \
		-destination 'platform=iOS Simulator,id=$(UITEST_IOS_ID)' -enableCodeCoverage YES \
		-resultBundlePath $(UITEST_IOS_RESULT) $(STAMP) test 2>&1 \
		| tee $(DERIVED)/uitest-ios.log | tail -30
	@$(ROOT)/scripts/ui_coverage.sh $(DERIVED) ios

# The release, and the only target here that needs anything from outside the checkout.
# scripts/env.sh loads .env and hands the lane an environment; a runner has one already and
# runs this same line. Nothing about the release is written down anywhere else.
publish: xcodeproj	# archive, sign and send both apps to TestFlight
	@$(ROOT)/scripts/env.sh -- bundle exec fastlane publish

# The pictures the two stores ask for. Two commands rather than one, because they are two
# different machines' worth of work: the Mac app photographs itself in a second, and the phone
# needs two simulators booted and an app installed on each. Nothing here drives anything -- a
# hosted runner will not grant an app the accessibility permission UI testing needs (#30), so
# every picture is a state a launch variable reaches.
shots: shots-macos shots-ios	# take every screenshot both stores ask for

shots-macos: xcodeproj	# photograph the Mac app, both languages, 1280x800
	@$(ROOT)/scripts/shots.sh --macos

shots-ios: xcodeproj	# photograph the phone and the iPad, both languages
	@$(ROOT)/scripts/shots.sh --ios

version:			# show the version a build made here would report
	@echo "$(VERSION) ($(BUILD_NUMBER))"

xcodeproj: sync-assets	# generate Fediqo.xcodeproj from project.yml
	@command -v xcodegen >/dev/null || { echo "xcodegen is missing: brew install xcodegen"; exit 1; }
	@xcodegen generate --quiet --spec $(ROOT)/project.yml --project $(ROOT)

sync-assets:		# copy the artwork in assets/ into the asset catalog
	@cp $(ROOT)/assets/mascot.svg $(MASCOT)

clean:				# remove the generated project and everything it built
	@rm -rf $(XCODEPROJ) $(DERIVED)

test build upgrade:	# nothing here -- the package owns both
	@:

help:				# show this message
	@printf "Usage: make -C Apps [OPTION]\n"
	@printf "\n"
	@perl -nle 'print $$& if m{^[\w-]+:.*?#.*$$}' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?#"} {printf "    %-18s %s\n", $$1, $$2}'
