# Pinned in the lock, because a release should not change because somebody upgraded a laptop.
# The certificate repository was written by 2.233.0 and match reads what wrote it.
#
# Moved 2.238.0 -> 2.240.1 deliberately, and the lock is where that decision is recorded. Apple
# moved the endpoint spaceship bootstraps its session from, so 2.238.0 answered every login with
# `Service key is empty` and a 404 from Olympus -- fastlane #30199, and #30206 in 2.240.0 is
# "read the App Store Connect API key from where Apple keeps it now". Nothing here could be
# published until this moved: the failure is in the sign-in, before any archive.
source "https://rubygems.org"

gem "fastlane", "~> 2.228"
