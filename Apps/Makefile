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

# Deferred, not `:=` -- a `make help` should not go asking git what the version is. The two
# come from scripts/version.sh so a build here and a build on a runner agree by construction
# rather than by someone remembering to keep two numbers in step.
VERSION        = $(shell $(ROOT)/scripts/version.sh --marketing)
BUILD_NUMBER   = $(shell $(ROOT)/scripts/version.sh --build)
STAMP          = MARKETING_VERSION=$(VERSION) CURRENT_PROJECT_VERSION=$(BUILD_NUMBER)

.PHONY: all run mac ios uitest publish version xcodeproj sync-assets clean test build upgrade help

all: help			# default action

run: mac			# build and launch the macOS app
	@open $(DERIVED)/Build/Products/Debug/Fediqo.app

# `| tail` is here because xcodebuild says a great deal and only the end of it is news. A
# pipeline reports the exit status of its last command, though, so without pipefail the tail
# would report success for every build that ever failed -- which is what CI was doing.
mac: xcodeproj		# build the macOS app
	@set -o pipefail; xcodebuild -project $(XCODEPROJ) -scheme $(MACOS_SCHEME) \
		-configuration Debug -derivedDataPath $(DERIVED) \
		-destination 'platform=macOS' $(STAMP) build | tail -5

ios: xcodeproj		# build the iOS app for the simulator
	@set -o pipefail; xcodebuild -project $(XCODEPROJ) -scheme $(IOS_SCHEME) \
		-configuration Debug -derivedDataPath $(DERIVED) \
		-destination '$(IOS_DESTINATION)' $(STAMP) build | tail -5

# The tests that need the app running. `swift test` reaches Core and the models above it and
# stops where SwiftUI begins -- nothing in a package can execute a view body -- so what a reader
# actually does is driven from here, by a second process that launches the first one.
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
		-resultBundlePath $(UITEST_RESULT) $(STAMP) test | tail -5
	@$(ROOT)/scripts/ui_coverage.sh $(DERIVED)

# The release, and the only target here that needs anything from outside the checkout.
# scripts/env.sh loads .env and hands the lane an environment; a runner has one already and
# runs this same line. Nothing about the release is written down anywhere else.
publish: xcodeproj	# archive, sign and send both apps to TestFlight
	@$(ROOT)/scripts/env.sh -- bundle exec fastlane publish

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
