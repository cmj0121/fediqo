ROOT          := ..
MACOS_SCHEME  := Fediqo
IOS_SCHEME    := Fediqo-iOS
IOS_DEVICE    ?= iPad Pro 11-inch (M5)
XCODEPROJ     := $(ROOT)/Fediqo.xcodeproj
DERIVED       := $(ROOT)/.build/xcode
MASCOT        := $(ROOT)/Sources/FediqoUI/Resources/Media.xcassets/Mascot.imageset/mascot.svg

# Deferred, not `:=` -- a `make help` should not go asking git what the version is. The two
# come from scripts/version.sh so a build here and a build on a runner agree by construction
# rather than by someone remembering to keep two numbers in step.
VERSION        = $(shell $(ROOT)/scripts/version.sh --marketing)
BUILD_NUMBER   = $(shell $(ROOT)/scripts/version.sh --build)
STAMP          = MARKETING_VERSION=$(VERSION) CURRENT_PROJECT_VERSION=$(BUILD_NUMBER)

.PHONY: all run mac ios version xcodeproj sync-assets clean test build upgrade help

all: help			# default action

run: mac			# build and launch the macOS app
	@open $(DERIVED)/Build/Products/Debug/Fediqo.app

mac: xcodeproj		# build the macOS app
	@xcodebuild -project $(XCODEPROJ) -scheme $(MACOS_SCHEME) \
		-configuration Debug -derivedDataPath $(DERIVED) \
		-destination 'platform=macOS' $(STAMP) build | tail -5

ios: xcodeproj		# build the iOS app for the simulator
	@xcodebuild -project $(XCODEPROJ) -scheme $(IOS_SCHEME) \
		-configuration Debug -derivedDataPath $(DERIVED) \
		-destination 'platform=iOS Simulator,name=$(IOS_DEVICE)' $(STAMP) build | tail -5

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
