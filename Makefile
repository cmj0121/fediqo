SUBDIR := Apps

.PHONY: all clean test run build publish shots version upgrade help servers servers-down $(SUBDIR)

all: $(SUBDIR) 		# default action
	@[ -f .git/hooks/pre-commit ] || pre-commit install --install-hooks
	@git config commit.template .git-commit-template

clean: $(SUBDIR)	# clean-up environment
	@find . -name '*.sw[po]' -delete
	@rm -rf .build .bundle vendor/

test:				# run test
	swift test
	@scripts/version_test.sh

run: $(SUBDIR)		# run in the local environment -- the macOS app

build:				# build the binary/library
	swift build

publish: $(SUBDIR)	# archive, sign and send both apps to TestFlight
	@:

shots: $(SUBDIR)	# take the screenshots both stores ask for, in both languages
	@:

version:			# show the version a build made here would report
	@scripts/version.sh

upgrade:			# upgrade all the necessary packages
	pre-commit autoupdate

servers:			# bring up a real server of every protocol this app can join
	@scripts/servers-up.sh

servers-down:			# throw the local protocol servers away
	@scripts/servers-down.sh

help:				# show this message
	@printf "Usage: make [OPTION]\n"
	@printf "\n"
	@perl -nle 'print $$& if m{^[\w-]+:.*?#.*$$}' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?#"} {printf "    %-18s %s\n", $$1, $$2}'

$(SUBDIR):
	$(MAKE) -C $@ $(MAKECMDGOALS)
