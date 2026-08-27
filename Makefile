SUBDIR := Apps

.PHONY: all clean test run build publish version upgrade help $(SUBDIR)

all: $(SUBDIR) 		# default action
	@[ -f .git/hooks/pre-commit ] || pre-commit install --install-hooks
	@git config commit.template .git-commit-template

clean: $(SUBDIR)	# clean-up environment
	@find . -name '*.sw[po]' -delete
	@rm -rf .build

test:				# run test
	swift test

run: $(SUBDIR)		# run in the local environment -- the macOS app

build:				# build the binary/library
	swift build

publish: $(SUBDIR)	# archive, sign and send both apps to TestFlight
	@:

version:			# show the version a build made here would report
	@scripts/version.sh

upgrade:			# upgrade all the necessary packages
	pre-commit autoupdate

help:				# show this message
	@printf "Usage: make [OPTION]\n"
	@printf "\n"
	@perl -nle 'print $$& if m{^[\w-]+:.*?#.*$$}' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?#"} {printf "    %-18s %s\n", $$1, $$2}'

$(SUBDIR):
	$(MAKE) -C $@ $(MAKECMDGOALS)
