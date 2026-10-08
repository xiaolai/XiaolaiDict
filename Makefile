# XiaolaiDict — the menu. Code and tests live in SwiftPM; the bundle transaction — build, assemble, sign,
# verify, publish, all under one lock — lives in Tools/build-bundle.sh.
#
#   make          swift test, then bring .build/XiaolaiDict.app up to date
#   make run      the same, then quit the running copy, open the new one and check it answers
#   make test     lint, swift test, and the icon generator's tests
#   make portability  typecheck Sources/ReviewKit alone for iOS, watchOS, tvOS and macOS; every
#                 target that runs swift test runs it first
#   make lint     SwiftLint's correctness rules over Sources, warnings failing (.swiftlint.yml)
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
.PHONY: all run test test-swift test-tools lint icon strings e2e e2e-status release clean metal-guard portability

# Machine-local settings, untracked: the name of your end-to-end machine and anything else that
# belongs to one developer's network rather than to this project. Read BEFORE the defaults below,
# because `?=` only fills a variable that is still unset. Absent is normal — `-` is what makes a
# missing file silent here and a missing host loud at the point of use.
-include local.mk

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
# No default: it is a host on your own network, so it is set in `local.mk` or the environment
# rather than committed. The `e2e` target says so when it is missing.
E2E_HOST ?=

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
all: lint test-swift
	@Tools/build-bundle.sh build

run: lint test-swift
	@Tools/build-bundle.sh run

test: lint test-swift test-tools

# The Metal toolchain lives on a cryptex whose directory name changes when it remounts, and the
# build cache keeps the old absolute path — so the next build dies with "unable to spawn process
# '…/metal'": zero `Test run with` lines and exit 1, a build failure wearing a test failure's
# clothes. Run before every build rather than diagnosed after one, because it cost an hour twice and
# the hand-typed cure named the wrong directory both times. ADR-0026.
metal-guard:
	@Tools/metal-cache-guard.sh

# **ReviewKit typechecks for iOS, watchOS, tvOS and macOS 27 on every build that tests** — ADR-0047.
# Compiled alone, so no module in .build can satisfy it, and with -DSWIFT_PACKAGE, the condition every
# real build compiles under; the compiler lists what it imports on each, which must be exactly
# `--imports`, and the Swift parser is asked whether it holds a directive. A prerequisite of
# `test-swift` rather than of each target that tests, so `all`, `run`, `test` and `release` all have it
# and a new path that tests inherits it; `ModuleBoundaryTests.portabilityRunsOnEveryTestedBuild` reads
# this file to keep it so, and holds `--imports` to its own table. It needs the iOS, watchOS and tvOS
# platform SDKs on every Mac that builds, and says which one is missing.
portability:
	@Tools/portability.sh --imports Foundation Sources/ReviewKit -DSWIFT_PACKAGE

# **A warning the compiler wrote down fails the build, whatever the compiler exited with** — ADR-0052.
# `-warnings-as-errors` lets one kind through (a property's type inferred from a module its file does not
# import), so after the tests the gate reads every source's diagnostics file in the configuration they
# were built in. It reads files and not this log: a build that recompiles nothing prints nothing, and the
# file a source's last compile wrote is still there. The bundle's own build — release, and for a development
# bundle the capture instruments' code this one never compiles — is read by `Tools/build-bundle.sh` after it.
DIAGNOSTICS := .build/out/Intermediates.noindex/XiaolaiDict.build/Debug

test-swift: metal-guard portability
	swift test; status=$$?; Tools/compiler-warnings.py $(DIAGNOSTICS) || status=1; \
	Tools/clean-test-defaults.sh || status=1; Tools/clean-test-scratch.sh || status=1; exit $$status

# Correctness rules only — `.swiftlint.yml` says which and why. `--strict` because a warning nobody
# fails on is a warning nobody reads. The version is pinned: a new SwiftLint can add findings to a rule,
# and a gate that moves by itself is not a gate.
SWIFTLINT_VERSION := 0.65.1
lint:
	@command -v swiftlint >/dev/null || { echo "swiftlint not found: brew install swiftlint" >&2; exit 1; }
	@test "$$(swiftlint version)" = "$(SWIFTLINT_VERSION)" || \
	  { echo "swiftlint $$(swiftlint version), this gate is pinned to $(SWIFTLINT_VERSION)" >&2; exit 1; }
	swiftlint lint --strict --quiet

# The Python suite: the icon generator, and the ladder gate `e2e.sh` decides a release with.
# Named for the directory rather than for the icon, because it stopped being only the icon's.
#
# `Tools/fsrs` is the second root: the scheduler's numerical reference and its own tests, kept
# together because they are one artefact. Its 11 tests passed for six days with no gate running them,
# and a reference nothing checks is exactly what gets ported to Swift with a wrong constant in it.
#
# **Tracked, unlike the specification it belongs to.** It first went in under `dev-docs/`, which is
# gitignored — so this line made `make test` pass here and fail on any fresh clone, discovery of a
# missing directory being an `ImportError`. A gate that depends on an untracked file is not a gate.
test-tools:
	python3 -m unittest discover -s Tools/tests
	python3 -m unittest discover -s Tools/fsrs

# Re-extract every localizable string into Strings/Localizable.xcstrings, the file a
# translator is given. Run it after adding or changing anything the reader reads.
strings: metal-guard
	Tools/strings.sh

icon:
	@Tools/build-bundle.sh icon

e2e: all
	@[ -n "$(E2E_HOST)" ] || { \
	  echo "E2E_HOST is not set. The end-to-end tests run on a second Mac, reached over SSH."; \
	  echo "Set it once in local.mk (untracked):   echo 'E2E_HOST = your-ssh-host' > local.mk"; \
	  echo "or per run:                            make e2e E2E_HOST=your-ssh-host"; \
	  exit 1; }
	@Tools/e2e.sh "$(E2E_HOST)" $(STAGES)

# Reads the record rather than running anything. The script is the one implementation of it: the end
# of a run prints the same table from the same place, and a second copy here had already lost a
# column.
e2e-status:
	@Tools/e2e-status.sh show

# Tests first, as for every bundle: nothing is published over a failing suite, and a notarised
# one least of all, since it is the build other people download.
release: lint test-swift
	@Tools/release.sh

clean:
	@Tools/build-bundle.sh clean
