# XiaolaiDict — the menu. Code and tests live in SwiftPM; the bundle transaction — build, assemble, sign,
# verify, publish, all under one lock — lives in Tools/build-bundle.sh.
#
#   make          swift test, then bring .build/XiaolaiDict.app up to date
#   make run      the same, then quit the running copy, open the new one and check it answers
#   make test     swift test, and the icon generator's tests
#   make icon     regenerate Resources/XiaolaiDict.icon and MenuBarIcon.svg from Tools/icon
#   make e2e      the same as make, then the end-to-end tests on the E2E machine (E2E_HOST).
#                 STAGES="drawer recogniser" runs only those; with none, all of them. A full run
#                 costs minutes and most changes touch one or two.
#   make e2e-status  what each stage last did, and on which build
#   make release BUILD_NUMBER=<n>
#                 swift test, then sign with a secure timestamp, notarise and staple the app, and
#                 package it as a signed, notarised, stapled .dmg in .build/release — failing unless
#                 Gatekeeper accepts both as "Notarized Developer ID". Needs network, and the shared
#                 notarytool keychain profile (NOTARY_PROFILE, chase-notary)
#   make clean    remove the bundle and staging (not SwiftPM's build cache)
#
# Nothing here is decided by timestamps: the script rebuilds when a digest of the inputs' names and
# contents changes, or when the published bundle fails verification.

# Recipes share the stage and the bundle; within one make they run in order. Across makes, the
# script's lock does the same.
.NOTPARALLEL:
# Stated, not inferred from position: make's default is "the first target", which is a property
# of where a line was pasted rather than of intent.
.DEFAULT_GOAL := all
.PHONY: all run test test-swift test-icon icon strings e2e e2e-status release clean

# A Developer ID, never ad hoc, for two reasons:
#   - macOS keys Accessibility and Screen Recording grants on the signing identity. An ad-hoc
#     signature changes with every byte, so every build would have to be granted again.
#   - The dictionary service accepts only a caller signed by the same team. An ad-hoc build
#     would produce an app whose every lookup the service refuses.
# So a missing identity stops the build rather than falling back.
SIGN_ID ?= Developer ID Application: HANDO K.K. (Y53RSUA3SM)
# Empty for a development build, numbered from the clock. Releases pass the release counter's value.
BUILD_NUMBER ?=
# The SSH name of the machine end-to-end tests run on. They never run on the machine that builds.
E2E_HOST ?= mbp16

# Handed to the script through the environment, as data: never spliced into a shell command,
# where a quote in the identity would become code.
export XIAOLAIDICT_SIGN_ID := $(SIGN_ID)
export XIAOLAIDICT_BUILD_NUMBER := $(BUILD_NUMBER)
# The notarytool keychain profile a release notarises with. A name and nothing more: the
# credentials live in the login keychain, never in this file or in a build's environment. Shared
# with this developer's other projects rather than made per repository — it authenticates the
# account, not the app, and a second copy of one password is a second thing to rotate.
NOTARY_PROFILE ?= chase-notary
export XIAOLAIDICT_NOTARY_PROFILE := $(NOTARY_PROFILE)

# No bundle is published over failing tests. The Swift tests cover what the bundle is compiled
# from. The icon generator reaches the bundle only by regenerating Resources/, and the script runs
# its tests with every regeneration — which a change to the generator always triggers — before any
# bundle is built from the result: they run exactly when they can affect what is published.
all: test-swift
	@Tools/build-bundle.sh build

run: test-swift
	@Tools/build-bundle.sh run

test: test-swift test-icon

test-swift:
	swift test; status=$$?; Tools/clean-test-defaults.sh || status=1; \
	Tools/clean-test-scratch.sh || status=1; exit $$status

test-icon:
	python3 -m unittest discover -s Tools/tests

# Re-extract every localizable string into Strings/Localizable.xcstrings, the file a
# translator is given. Run it after adding or changing anything the reader reads.
strings:
	Tools/strings.sh

icon:
	@Tools/build-bundle.sh icon

e2e: all
	@Tools/e2e.sh "$(E2E_HOST)" $(STAGES)

# Reads the record rather than running anything. A stage whose build no longer matches the one on
# disk is shown as stale: a pass is a fact about the build it ran on and expires with it.
e2e-status:
	@build=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" .build/XiaolaiDict.app/Contents/Info.plist 2>/dev/null || echo none); \
	echo "bundle on disk: $$build"; \
	if [ -f .build/e2e-status.tsv ]; then \
		sort .build/e2e-status.tsv | while IFS=$$'\t' read -r name result ran when; do \
			if [ "$$ran" != "$$build" ]; then \
				printf '  %-14s %-4s stale (ran on %s, %s)\n' "$$name" "$$result" "$$ran" "$$when"; \
			else \
				printf '  %-14s %-4s %s\n' "$$name" "$$result" "$$when"; \
			fi; \
		done; \
	else echo "  nothing recorded yet"; fi

# Tests first, as for every bundle: nothing is published over a failing suite, and a notarised
# one least of all, since it is the build other people download.
release: test-swift
	@Tools/release.sh

clean:
	@Tools/build-bundle.sh clean
