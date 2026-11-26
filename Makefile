.PHONY: build test wm-scenarios python-policy format format-check swiftformat-version swiftlint-version lint lint-scripts hooks bundle bundle-check run stop status install uninstall clean icons \
        audit-swift-dependencies swift-sast duplication benchmark benchmark-baseline profile-app profile-trace \
        local-signing sign verify-sign check-adhoc notarize check-notarize check-notarize-creds \
        notary-check zip dmg dist tag tag-push release ship cask cask-render cask-check _gh-release \
        check-release-tools check-release-notes record-release-inputs FORCE \
        preflight version-bump help

# ==============================================================================
# Configuration
# ==============================================================================

APP_NAME := SweetMX
BUNDLE_ID := com.sagmans.sweetmx
# Former bundle IDs, newest first, the sources of the one-time data migration.
# `make install` refuses while any of them runs: both apps would register the same
# global shortcuts, and the old app could write data after the migration copied it.
# Keep in step with `legacySources` in LegacyDataMigration.swift, in the same order.
LEGACY_BUNDLE_IDS := com.assagman.bitekey com.assagman.applebox
BUILD_DIR := .build/release
APP_BUNDLE := $(BUILD_DIR)/$(APP_NAME).app
INSTALL_DIR := $(HOME)/Applications
INSTALLED_BUNDLE := $(INSTALL_DIR)/$(APP_NAME).app
# Every installer action takes the same operands, so check and install can never
# guard different bundles.
INSTALLER_ARGS = "$(APP_BUNDLE)" "$(INSTALLED_BUNDLE)" "$(BUNDLE_ID)" $(LEGACY_BUNDLE_IDS)
LOCAL_INSTALLER := scripts/install-local.swift
# Owns every icon geometry and color constant, so all icon files come from one
# reviewed script instead of hand edits in a design tool.
ICON_GENERATOR := scripts/icons
# The generator spans several files, which `swift <file>` cannot run, so it is
# compiled into the ignored `.build` folder. Absolute source paths matter: the
# generator finds the repository root from its compile-time source path.
ICON_SOURCES := $(abspath $(wildcard $(ICON_GENERATOR)/*.swift))
ICON_BUILD_DIR := .build/icons
ICON_BINARY := $(ICON_BUILD_DIR)/render-icons
# Local builds sign with a stable self-signed identity (made once by `make local-signing`),
# because an ad-hoc signature changes on every build and macOS then forgets the app's
# privacy grants, such as the paste permission. Without that identity, builds fall back to
# ad-hoc and warn. Set LOCAL_SIGNING_IDENTITY to override, e.g. `-` to force ad-hoc.
# The keychain is read only inside `bundle`, so lint, format and test never touch it.
LOCAL_SIGNING_NAME := SweetMX Local Development
LOCAL_SIGNING_SETUP := scripts/setup-local-signing
LOCAL_SIGNING_IDENTITY ?=
ADHOC_SIGNING_IDENTITY := -
# `make stop` polls once per STOP_POLL_SECONDS, STOP_POLL_LIMIT times, before it fails.
STOP_POLL_SECONDS := 1
STOP_POLL_LIMIT := 10
LOG_DIR := $(HOME)/Library/Logs/$(APP_NAME)
# The release folder. It holds only finished artifacts that are ready to
# upload: each one is built in PACKAGE_WORK_DIR and moved here as the last step.
DIST_DIR := $(BUILD_DIR)/dist

# Extract version from Info.plist (can override: make release VERSION=1.0.0)
VERSION ?= $(shell /usr/libexec/PlistBuddy -c "Print CFBundleVersion" Resources/Info.plist 2>/dev/null || echo "0.0.0")
ZIP_NAME := $(APP_NAME)-v$(VERSION)-macOS.zip
DMG_NAME := $(APP_NAME)-v$(VERSION)-macOS.dmg
# The packages are real files, not phony targets, so a step that already ran
# is not run again: `make dist` after `make notarize`, or `make release` after
# `make dist`, sends nothing to Apple a second time.
ZIP_PATH := $(DIST_DIR)/$(ZIP_NAME)
DMG_PATH := $(DIST_DIR)/$(DMG_NAME)
# Public home of the project; release messages link here so a maintainer can
# open the new release in one click. Change it if the repository moves.
REPO_URL := https://github.com/sagmans/sweetmx

# Code signing configuration
DEVELOPER_ID := Developer ID Application: Ahmet Sercan Sagman (6C96BU4M82)
TEAM_ID := 6C96BU4M82
NOTARIZE_PROFILE := SweetMX-Notarize
# Longest wait for Apple's verdict on one submission (notarytool duration
# form). Apple's service is sometimes slow; one limit for every artifact keeps
# a slow day from failing the disk image after the app passed.
NOTARIZE_TIMEOUT := 30m
# Longest wait for the credential check in `preflight`, in seconds, so a dead
# network stops the release at once instead of hanging it.
NOTARIZE_CREDS_TIMEOUT := 60
# Grace period after that limit before the check is killed, in seconds.
NOTARIZE_CREDS_KILL_AFTER := 5
# Holds the signing, notarization, packaging and release targets; this file
# keeps their configuration.
RELEASE_MAKEFILE := release.mk
# The profile and the time limit go in the environment so each call site shows
# only what differs between artifacts.
NOTARIZE_ENV := NOTARIZE_PROFILE="$(NOTARIZE_PROFILE)" NOTARIZE_TIMEOUT="$(NOTARIZE_TIMEOUT)"
# One flow for every release artifact; see the script header.
NOTARIZE_SCRIPT := scripts/notarize-artifact.sh
NOTARIZE_ARTIFACT := $(NOTARIZE_ENV) bash $(NOTARIZE_SCRIPT)
# Owns the order of the disk image steps; see the script header.
DMG_PACKAGER := scripts/package-dmg.sh
# Every package is built here and moved to DIST_DIR only when it is complete
# (for the disk image: when Apple's ticket is on it). A failure or an
# interrupt at any step then leaves nothing at the release path for a later
# upload to pick up.
PACKAGE_WORK_DIR := $(BUILD_DIR)/package-work
# The archive Apple scans for the app. It is never a release artifact.
SUBMISSION_ZIP := $(PACKAGE_WORK_DIR)/$(APP_NAME)-notarize.zip
# Apple's answer to each submission. An answer records an attempt, a failed
# one included, so it stays out of DIST_DIR.
NOTARIZE_ANSWER_DIR := $(BUILD_DIR)/notarize
APP_NOTARIZE_ANSWER := $(NOTARIZE_ANSWER_DIR)/app.json
DMG_NOTARIZE_ANSWER := $(NOTARIZE_ANSWER_DIR)/dmg.json
# The file `stapler` writes into the bundle. The packages depend on it, so
# the ticket itself is the proof that the app was notarized: `make bundle`
# removes the bundle, and the ticket with it, on every rebuild.
APP_TICKET := $(APP_BUNDLE)/Contents/CodeResources
# Stops a package target when the bundle changed after it was notarized (a
# signature or an edit made by hand): the seal must hold and the ticket must
# validate.
REQUIRE_APP_TICKET = { codesign --verify --strict --deep "$(APP_BUNDLE)" && \
	xcrun stapler validate "$(APP_BUNDLE)" >/dev/null; } || { \
	echo "$(RED)ERROR: $(APP_BUNDLE) is not the app Apple notarized; run 'make notarize'$(NC)" >&2; exit 1; }
# Everything that changes the bytes of the bundle (files and folders); keep
# it in step with what `build`, `bundle` and `sign` read.
RELEASE_INPUTS := Makefile $(RELEASE_MAKEFILE) Package.swift Package.resolved Sources Resources $(ICON_GENERATOR)
# Holds the fingerprint of the inputs the notarized app was built from. A
# ticket counts only while the inputs on disk still give this fingerprint.
RELEASE_INPUTS_STAMP := $(BUILD_DIR)/release-inputs.sha256
# Owns the fingerprint and its comparison; see the script header.
RELEASE_INPUTS_CHECK := bash scripts/release-inputs.sh
# Exit status of its `current` action for "the inputs changed"; any other
# failure is an error and stops the release. Keep in step with the script.
RELEASE_INPUTS_CHANGED := 3
# Tools a release needs beyond Xcode: gh uploads, jq reads Apple's answer,
# timeout bounds the steps that wait on a network.
RELEASE_TOOLS := gh jq timeout
# Longest wait for the remote tag lookup in `preflight`, in seconds.
REMOTE_TAG_TIMEOUT := 30
# `git ls-remote --exit-code` status for "no such ref".
GIT_NO_SUCH_REF := 2
# Homebrew tap that serves the cask, in the form that `brew` takes.
HOMEBREW_TAP := sagmans/tap
HOMEBREW_CASK_TOKEN := sweetmx
# Homebrew reads the tap <owner>/<name> from <owner>/homebrew-<name>, Casks/.
HOMEBREW_TAP_REPO := $(dir $(HOMEBREW_TAP))homebrew-$(notdir $(HOMEBREW_TAP))
HOMEBREW_CASK_PATH := Casks/$(HOMEBREW_CASK_TOKEN).rb
# The cask is kept here and filled in at each release; see the file header.
HOMEBREW_CASK_TEMPLATE := packaging/homebrew/sweetmx.rb.template
# One flow for every cask step; see the script header. The local disk image
# is compared when it is there at run time, so the pipeline checks its own
# build and a later `make cask` from a clean clone still works.
HOMEBREW_CASK_SCRIPT = CASK_VERSION="$(VERSION)" CASK_TEMPLATE="$(HOMEBREW_CASK_TEMPLATE)" \
	CASK_REPO_URL="$(REPO_URL)" CASK_TEAM_ID="$(TEAM_ID)" \
	CASK_LOCAL_DMG="$(DMG_PATH)" \
	CASK_TAP_REPO="$(HOMEBREW_TAP_REPO)" CASK_TAP_PATH="$(HOMEBREW_CASK_PATH)" \
	bash scripts/publish-homebrew-cask.sh
# Where `make cask-render` writes its preview. Not DIST_DIR: the preview is
# not a release artifact, and its name carries no version.
CASK_RENDER_DIR := $(BUILD_DIR)/cask
ENTITLEMENTS := Resources/SweetMX.entitlements
# Menu bar status item artwork. Both files ship so AppKit can pick the @2x one
# on Retina screens instead of upscaling the 18 px file.
MENU_BAR_ICONS := Resources/MenuBarIconTemplate.png Resources/MenuBarIconTemplate@2x.png

# Exact SwiftFormat and SwiftLint pins live in mise.toml [tools] and are
# resolved + version-checked fail-closed by scripts/mise-tool.sh on demand.
MISE_TOOL := bash scripts/mise-tool.sh
# Defined before the path lists below, which expand it at once (:=).
PROFILE_SCRIPT := scripts/profile-app.swift
# `Sources` holds every target, the window manager ones included (WMCore, WMPlatform, wm-sim,
# wmctl), so format, lint, SAST and duplication cover a new target folder with no change here.
SWIFT_STYLE_PATHS := Package.swift Sources Tests $(PROFILE_SCRIPT) $(LOCAL_INSTALLER) $(ICON_GENERATOR)
# The performance gate builds with optimizations, as the shipped app is, plus -enable-testing so
# the benchmarks can reach internal types. Its own scratch path keeps those flags from forcing a
# full rebuild of the plain release build (.build/release) that `make bundle` uses, and back.
BENCHMARK_SCRATCH := .build/benchmark
BENCHMARK_FLAGS := -c release -Xswiftc -enable-testing --scratch-path $(BENCHMARK_SCRATCH)
BENCHMARK_FILTER := SweetMXBenchmarks
BENCHMARK_RESULTS := $(BENCHMARK_SCRATCH)/results.json
# The binary size metric reads the shipped build, not the -enable-testing one.
RELEASE_BINARY := $(BUILD_DIR)/$(APP_NAME)
# Bounds a whole gate run (release build plus about 30 s of measurement), so a hung benchmark
# fails the push instead of blocking it.
BENCHMARK_TIMEOUT := 900
# One command for the gate and for recording, so both always measure the same way.
BENCHMARK_RUN = SWEETMX_BENCHMARK=1 SWEETMX_BENCHMARK_BINARY="$(CURDIR)/$(RELEASE_BINARY)" \
	SWEETMX_BENCHMARK_RESULTS="$(CURDIR)/$(BENCHMARK_RESULTS)" \
	timeout $(BENCHMARK_TIMEOUT) swift test $(BENCHMARK_FLAGS) --filter $(BENCHMARK_FILTER)
# The shipped build holds the app only. The window manager development tools are debug builds
# for the scenario checks, so no release copy of them exists to be packaged by mistake.
RELEASE_BUILD := swift build -c release --product $(APP_NAME)
# Development tools that must never ship; the bundle guard refuses them by name, in any folder.
WM_DEV_TOOLS := wm-sim wmctl
# Lists what the bundle must not hold: any program but the app executable, and any file named as
# a development tool. Deny by default, so a later copy step cannot ship a second program unseen.
BUNDLE_STRAYS = find "$(APP_BUNDLE)" ! -type d \( -perm -u+x $(foreach tool,$(WM_DEV_TOOLS),-o -name "$(tool)") \) \
	! -path "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
# One command for `make bundle` and `make bundle-check`, so both judge a bundle the same way.
BUNDLE_GUARD = strays="$$($(BUNDLE_STRAYS))" || exit 1; \
	if [ -n "$$strays" ]; then \
		echo "error: $(APP_BUNDLE) may hold one program, $(APP_NAME); found:" >&2; echo "$$strays" >&2; exit 1; \
	fi
# Bounds one run of a window manager tool in a scenario check, so a hung tool fails `make test`
# instead of blocking it. Each run takes milliseconds.
WM_SCENARIO_TIMEOUT := 30
# One command for `make test` and `make wm-scenarios`, so both run the same checks. A shell
# fragment, not a sub-make, so `make -n test` stays a dry run.
WM_SCENARIOS = WM_SCENARIO_TIMEOUT=$(WM_SCENARIO_TIMEOUT) bash scripts/wm-scenarios.sh
# The app's Application Support folder; must match AppDataLocation.folderName in the app.
DATA_FOLDER_NAME := $(APP_NAME)
# Sampling window of `make profile-app`; long enough to span many clipboard polls.
PROFILE_SECONDS := 10
# Length and output of `make profile-trace`. Traces hold symbol names and timings, not clip text, but
# stay in the ignored build folder like every other local artifact.
TRACE_SECONDS := 30
TRACE_DIR := .build/profiles
TRACE_TEMPLATE := Time Profiler
SWIFT_SCAN_TIMEOUT := 120
# Resources is scanned for entitlements and Info.plist keys that weaken the
# hardened runtime or App Transport Security; the Swift rules skip it.
SWIFT_SAST_PATHS := Sources Resources $(PROFILE_SCRIPT) $(LOCAL_INSTALLER) $(ICON_GENERATOR)
# Production Swift only: tests repeat setup on purpose so each reads alone.
DUPLICATION_PATHS := Sources $(PROFILE_SCRIPT) $(LOCAL_INSTALLER) $(ICON_GENERATOR)
DUPLICATION_TIMEOUT := 120
# Bounds each `make icons` step (compile, sources, bitmaps) and the `make
# bundle` catalog step (about 3 s: one xcode-select, one actool compile), so a
# hung compile, AppKit load or Xcode tool fails the target instead of blocking
# the shell. The bitmaps step takes about 7 s (one xcode-select, seven ictool
# renders, one actool compile, two iconutil runs). Each tool also has its own
# timeout inside the generator, but their worst-case sum is several minutes,
# so this outer bound governs: a run of slow-but-alive tools stops at 120 s.
ICON_TIMEOUT := 120
# After ICON_TIMEOUT sends SIGTERM, a child that ignores it is killed this
# many seconds later, so `make icons` and the `make bundle` catalog step
# always return.
ICON_KILL_AFTER := 10
# The glass icon only renders from a compiled asset catalog, so `make bundle`
# has the generator compile the Icon Composer source. The output stays in the
# ignored `.build` folder because Assets.car is a build product, never
# committed. The generator also reads the minimum macOS version from
# Info.plist, so nothing is repeated here.
# $(CURDIR) makes the path absolute: actool's shared daemon resolves relative
# paths against its own working directory, possibly in another checkout.
ICON_CATALOG_DIR := $(CURDIR)/.build/app-icon
ICON_CATALOG := $(ICON_CATALOG_DIR)/Assets.car
# `rm -rf` of a bundle path is allowed only for a relative `.build/...*.app`
# path. A guard (not `override`) is used so a deliberate BUILD_DIR still works
# while an empty or absolute value, or `..`, is refused with a reason.
BUNDLE_PATH_PATTERN := .build/*?.app

# Colors for output
RED := \033[0;31m
GREEN := \033[0;32m
YELLOW := \033[0;33m
BLUE := \033[0;34m
NC := \033[0m  # No Color

# ==============================================================================
# Help
# ==============================================================================

help:
	@echo ""
	@echo "$(BLUE)SweetMX Makefile$(NC)"
	@echo "=================="
	@echo ""
	@echo "$(GREEN)Development:$(NC)"
	@echo "  make build        - Build release binary"
	@echo "  make test         - Run test suite and the window manager scenarios"
	@echo "  make wm-scenarios - Run only the window manager scenario checks"
	@echo "  make benchmark    - Performance gate against benchmarks/baseline.json"
	@echo "  make benchmark-baseline - Record new limits (METRICS=a,b for some only)"
	@echo "  make profile-app  - CPU, wakeups, memory and disk of the running app"
	@echo "  make profile-trace - Time Profiler trace of the running app (needs Xcode)"
	@echo "  make format       - Auto-format Sources/ and Tests/ (SwiftFormat)"
	@echo "  make format-check - Fail if formatting is needed (SwiftFormat --lint)"
	@echo "  make lint         - Run SwiftLint"
	@echo "  make lint-scripts - Format-check and lint repo shell and Python scripts"
	@echo "  make hooks        - Enable tracked git hooks (run once per clone)"
	@echo "  make icons        - Regenerate the committed icon files"
	@echo "  make bundle       - Create .app bundle"
	@echo "  make bundle-check - Fail if the bundle holds any program but the app"
	@echo "  make run          - Build, bundle, and run app"
	@echo "  make stop         - Stop running app"
	@echo "  make status       - Check if app is running"
	@echo "  make logs         - Stream app logs"
	@echo ""
	@echo "$(GREEN)Installation:$(NC)"
	@echo "  make local-signing - Create the local signing identity (once) so permissions survive rebuilds"
	@echo "  make install      - Install or update in ~/Applications"
	@echo "  make uninstall    - Move the local bundle to Trash, keeping history"
	@echo ""
	@echo "$(GREEN)Code Signing:$(NC)"
	@echo "  make sign         - Sign app with Developer ID"
	@echo "  make verify-sign  - Verify code signature"
	@echo "  make check-adhoc  - Check for ad-hoc signature (warning)"
	@echo "  make notary-check - $(YELLOW)FULL notarization readiness check$(NC)"
	@echo "  make notarize     - Build, sign, notarize the app and staple its ticket"
	@echo "  make check-notarize ID=xxx - Check notarization status"
	@echo ""
	@echo "$(GREEN)Packaging:$(NC)"
	@echo "  make zip          - Create .zip of the notarized app (notarizes if necessary)"
	@echo "  make dmg          - Create signed, notarized .dmg"
	@echo "  make dist         - Create both .zip and .dmg"
	@echo ""
	@echo "$(GREEN)Release:$(NC)"
	@echo "  make preflight    - Run all pre-release checks"
	@echo "  make tag          - Create signed git tag"
	@echo "  make tag-push     - Create and push tag"
	@echo "  make release      - Package if necessary, tag, push the tag, upload, publish the cask"
	@echo "  make cask         - Publish the Homebrew cask for the released version"
	@echo "  make cask-render  - Write that cask to a file; publish nothing"
	@echo "  make cask-check   - Check the cask template with brew style"
	@echo "  make ship         - $(YELLOW)FULL PIPELINE$(NC): clean → test → sign → notarize → dist → release → cask"
	@echo ""
	@echo "$(GREEN)Maintenance:$(NC)"
	@echo "  make clean        - Remove all build artifacts"
	@echo "  make version-bump V=x.y.z - Update version in Info.plist"
	@echo ""
	@echo "$(GREEN)Examples:$(NC)"
	@echo "  make ship VERSION=1.2.0 NOTES=\"Bug fixes\""
	@echo "  make release VERSION=1.2.0 NOTES_FILE=CHANGELOG.md"
	@echo "  make check-notarize ID=b9976e01-0b7d-4f0a-9a61-79d65ef0731a"
	@echo ""

# ==============================================================================
# Development
# ==============================================================================

build:
	@echo "$(BLUE)Building $(APP_NAME)...$(NC)"
	@$(RELEASE_BUILD)
	@echo "$(GREEN)Build complete$(NC)"

python-policy:
	@bash scripts/check-python-runtime.sh

test: python-policy
	@echo "$(BLUE)Running tests...$(NC)"
	@swift test
	@$(WM_SCENARIOS)
	@echo "$(GREEN)All tests passed$(NC)"

# Scenario checks drive the window manager tools as a user does; see the script header.
wm-scenarios:
	@$(WM_SCENARIOS)

audit-swift-dependencies:
	@bash scripts/audit-swift-dependencies.sh

swift-sast:
	@SWIFT_SCAN_TIMEOUT=$(SWIFT_SCAN_TIMEOUT) bash scripts/swift-sast.sh $(SWIFT_SAST_PATHS)

duplication:
	@DUPLICATION_TIMEOUT=$(DUPLICATION_TIMEOUT) bash scripts/check-duplication.sh $(DUPLICATION_PATHS)

# Performance gate: measures hot paths, memory, idle cost and binary size, and fails when a metric
# passes its limit in benchmarks/baseline.json. See docs/PERFORMANCE.md.
benchmark:
	@echo "$(BLUE)Running the performance gate (release build)...$(NC)"
	@$(RELEASE_BUILD)
	@rm -f "$(BENCHMARK_RESULTS)"
	@$(BENCHMARK_RUN)
	@# Fails closed: a skipped or filtered-out test exits 0 without measuring anything.
	@test -s "$(BENCHMARK_RESULTS)" || { echo "$(RED)The performance gate measured nothing; is the test skipped?$(NC)" >&2; exit 1; }
	@echo "$(GREEN)Performance within baseline$(NC)"

# Rewrites the committed limits from this machine. Run only after an intended change, review the
# diff of benchmarks/baseline.json, and commit it with the change that moved the numbers.
# METRICS=name,name rewrites only those entries, so a new metric leaves the other limits alone.
benchmark-baseline:
	@$(RELEASE_BUILD)
	@SWEETMX_BENCHMARK_RECORD="$(or $(METRICS),1)" $(BENCHMARK_RUN)

# Read-only resource reading of the running app: CPU, wakeups, memory, disk I/O and disk space.
profile-app:
	@swift "$(PROFILE_SCRIPT)" "$(BUNDLE_ID)" "$(PROFILE_SECONDS)" "$(DATA_FOLDER_NAME)"

# Time Profiler trace of the running app, with the PerformanceSignposts intervals on the Points of
# Interest track. Needs Xcode; open the result with `open <trace>`. xctrace can exit non-zero for
# a side stream (os_log) while the samples are fine, so only a missing trace fails the target.
profile-trace:
	@pid="$$(pgrep -x "$(APP_NAME)" | head -n 1)"; \
	if [ -z "$$pid" ]; then echo "$(RED)$(APP_NAME) is not running; start it with 'make run'$(NC)" >&2; exit 1; fi; \
	mkdir -p "$(TRACE_DIR)"; \
	out="$(TRACE_DIR)/$(APP_NAME)-$$(date +%Y%m%d-%H%M%S).trace"; \
	status=0; xcrun xctrace record --template "$(TRACE_TEMPLATE)" --attach "$$pid" --time-limit "$(TRACE_SECONDS)s" \
		--output "$$out" --no-prompt || status=$$?; \
	if [ ! -d "$$out" ]; then echo "$(RED)No trace recorded (xctrace exit $$status)$(NC)" >&2; exit 1; fi; \
	if [ "$$status" -ne 0 ]; then echo "$(YELLOW)xctrace reported run issues (exit $$status); the trace is still readable$(NC)"; fi; \
	echo "$(GREEN)Trace saved: $$out$(NC)"

# ==============================================================================
# Code Style
# ==============================================================================

# Fails closed when SwiftFormat does not match the exact pin in mise.toml.
swiftformat-version:
	@$(MISE_TOOL) check swiftformat

format:
	@echo "$(BLUE)Formatting Swift sources (SwiftFormat)...$(NC)"
	@$(MISE_TOOL) run swiftformat -- $(SWIFT_STYLE_PATHS)
	@echo "$(GREEN)Formatting complete$(NC)"

format-check:
	@echo "$(BLUE)Checking formatting (SwiftFormat --lint)...$(NC)"
	@if [ "$$GITHUB_ACTIONS" = "true" ]; then \
		$(MISE_TOOL) run swiftformat -- $(SWIFT_STYLE_PATHS) --lint --reporter github-actions-log; \
	else \
		$(MISE_TOOL) run swiftformat -- $(SWIFT_STYLE_PATHS) --lint; \
	fi
	@echo "$(GREEN)Formatting OK$(NC)"

hooks:
	@./scripts/setup-hooks

# Fails closed when SwiftLint does not match the exact pin in mise.toml.
swiftlint-version:
	@$(MISE_TOOL) check swiftlint

lint:
	@echo "$(BLUE)Linting Swift sources (SwiftLint)...$(NC)"
	@REPORTER=xcode; \
	if [ "$$GITHUB_ACTIONS" = "true" ]; then REPORTER=github-actions-logging; fi; \
	$(MISE_TOOL) run swiftlint -- lint --strict --config .swiftlint.yml --force-exclude --reporter $$REPORTER
	@echo "$(GREEN)Lint OK$(NC)"

lint-scripts:
	@echo "$(BLUE)Checking repo shell and Python scripts (shellcheck, shfmt, ruff)...$(NC)"
	@bash scripts/lint-scripts.sh
	@echo "$(GREEN)Scripts OK$(NC)"

# One compile rule for `icons` and `bundle`, so both always run the same
# generator build. Absolute source paths matter: see ICON_SOURCES.
$(ICON_BINARY): $(ICON_SOURCES)
	@echo "$(BLUE)Compiling the icon generator...$(NC)"
	@mkdir -p "$(ICON_BUILD_DIR)"
	@# Links to a temp name, then renames: a compile killed by the timeout
	@# must not leave a partial binary that make later treats as up to date.
	@rm -f "$(ICON_BINARY).tmp"
	@timeout -k $(ICON_KILL_AFTER) $(ICON_TIMEOUT) swiftc -O $(ICON_SOURCES) -o "$(ICON_BINARY).tmp"
	@mv -f "$(ICON_BINARY).tmp" "$(ICON_BINARY)"

# Regenerates the committed icon files from the generator's constants. Run it
# after changing the mark, then commit the outputs: the build reads the
# committed files, so `swift run` and `make bundle` never need to redraw.
icons: $(ICON_BINARY)
	@echo "$(BLUE)Generating icon sources...$(NC)"
	@timeout -k $(ICON_KILL_AFTER) $(ICON_TIMEOUT) "$(ICON_BINARY)" sources
	@echo "$(BLUE)Rendering icon bitmaps (needs Xcode)...$(NC)"
	@timeout -k $(ICON_KILL_AFTER) $(ICON_TIMEOUT) "$(ICON_BINARY)" bitmaps

# A new input of the bundle must also go in RELEASE_INPUTS, or a release can
# reuse an app built without it.
bundle: build $(ICON_BINARY)
	@# Refuse an unsafe bundle path before anything is removed.
	@case "$(APP_BUNDLE)" in \
		*..*) echo "error: APP_BUNDLE \"$(APP_BUNDLE)\" contains '..'; refusing to remove it" >&2; exit 1 ;; \
		$(BUNDLE_PATH_PATTERN)) ;; \
		*) echo "error: APP_BUNDLE \"$(APP_BUNDLE)\" is not a relative .build/*.app path; refusing to remove it" >&2; exit 1 ;; \
	esac
	@echo "$(BLUE)Compiling the app icon (needs Xcode)...$(NC)"
	@# Compile before the bundle exists, and drop any older bundle on failure: a
	@# bundle without the glass icon must never look finished.
	@timeout -k $(ICON_KILL_AFTER) $(ICON_TIMEOUT) "$(ICON_BINARY)" catalog "$(ICON_CATALOG_DIR)" \
		|| { rm -rf "$(APP_BUNDLE)"; exit 1; }
	@echo "$(BLUE)Creating app bundle...$(NC)"
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS" "$(APP_BUNDLE)/Contents/Resources"
	@cp "$(BUILD_DIR)/$(APP_NAME)" "$(APP_BUNDLE)/Contents/MacOS/"
	@cp Resources/Info.plist "$(APP_BUNDLE)/Contents/"
	@# Both icons ship: Assets.car gives macOS 26 the glass icon, and the committed
	@# .icns stays for the Finder fallback and for the dmg, which reads it directly.
	@cp "$(ICON_CATALOG)" "$(APP_BUNDLE)/Contents/Resources/"
	@cp Resources/AppIcon.icns "$(APP_BUNDLE)/Contents/Resources/"
	@cp $(MENU_BAR_ICONS) "$(APP_BUNDLE)/Contents/Resources/"
	@# Touch app bundle to refresh icon cache
	@touch "$(APP_BUNDLE)"
	@# Copy entitlements if exists (for reference, not embedded in bundle)
	@if [ -f "$(ENTITLEMENTS)" ]; then \
		cp "$(ENTITLEMENTS)" "$(APP_BUNDLE)/Contents/Resources/"; \
	fi
	@# After the last copy and before signing, so no step can add a program unseen. A refused
	@# bundle is dropped: it must never look finished.
	@( $(BUNDLE_GUARD) ) || { rm -rf "$(APP_BUNDLE)"; exit 1; }
	@# Seal the whole bundle: the linker signs only the binary, and macOS privacy grants
	@# (paste permission, Screen Recording) never match a bundle whose resources are unsealed.
	@# The setup script resolves the identity so a duplicate or a failed keychain query stops
	@# the build with a reason instead of a vague codesign error.
	@identity="$(LOCAL_SIGNING_IDENTITY)"; \
	if [ -z "$$identity" ]; then \
		identity="$$(bash "$(LOCAL_SIGNING_SETUP)" --resolve "$(LOCAL_SIGNING_NAME)")" || exit 1; \
	fi; \
	if [ -z "$$identity" ] || [ "$$identity" = "$(ADHOC_SIGNING_IDENTITY)" ]; then \
		identity="$(ADHOC_SIGNING_IDENTITY)"; \
		echo "$(YELLOW)Ad-hoc signing: macOS forgets the paste permission after each build. Run 'make local-signing' once to keep it.$(NC)"; \
	fi; \
	codesign --force --sign "$$identity" "$(APP_BUNDLE)"
	@codesign --verify --strict "$(APP_BUNDLE)"
	@echo "$(GREEN)Bundle created: $(APP_BUNDLE)$(NC)"

# Judges an existing bundle with the guard that `make bundle` uses; changes nothing.
bundle-check:
	@$(BUNDLE_GUARD)
	@echo "$(GREEN)Bundle holds only $(APP_NAME)$(NC)"

run: stop bundle
	@mkdir -p "$(LOG_DIR)"
	@open "$(APP_BUNDLE)"
	@echo "$(GREEN)Started $(APP_NAME)$(NC)"

# Stops every running copy, dev or release: they share the bundle ID and the global hotkeys,
# so only one may run, and the installer refuses to replace a bundle while any copy runs.
# Fails when a copy outlives the wait, so `install` never races a live process.
# A shell fragment, not a sub-make, so `install` can run it mid-recipe without
# referencing $(MAKE), which would make `make -n install` run the real install.
STOP_APP = if pkill -x "$(APP_NAME)" 2>/dev/null; then \
	for _ in $$(seq $(STOP_POLL_LIMIT)); do pgrep -x "$(APP_NAME)" >/dev/null || break; sleep $(STOP_POLL_SECONDS); done; \
	if pgrep -x "$(APP_NAME)" >/dev/null; then \
		echo "$(RED)$(APP_NAME) still running after $(STOP_POLL_LIMIT) checks; quit it from the menu bar$(NC)"; exit 1; \
	fi; \
	echo "$(YELLOW)Stopped $(APP_NAME)$(NC)"; \
fi

stop:
	@$(STOP_APP)

status:
	@pgrep -x $(APP_NAME) >/dev/null && echo "$(GREEN)$(APP_NAME) running (PID: $$(pgrep -x $(APP_NAME)))$(NC)" || echo "$(YELLOW)$(APP_NAME) not running$(NC)"

logs:
	@log stream --style compact --predicate 'subsystem == "$(BUNDLE_ID)"' 2>/dev/null || echo "No logs yet"

# ==============================================================================
# Installation
# ==============================================================================

# Creates the stable local signing identity once; see LOCAL_SIGNING_NAME above.
local-signing:
	@bash "$(LOCAL_SIGNING_SETUP)" "$(LOCAL_SIGNING_NAME)"

# Bundle and check first, then stop, so the running copy keeps working during the
# build and is never stopped for an install the guards would refuse.
# `check` prints the bundle that ran. A failed install leaves the installed bundle
# untouched (install-local.swift swaps it in with one atomic rename as its last
# step), so the bundle that ran is opened again; a successful one opens the new copy.
# A copy that was not running stays closed.
install: bundle
	@running_bundle="$$(swift "$(LOCAL_INSTALLER)" check $(INSTALLER_ARGS))" || exit 1; \
	$(STOP_APP); \
	if swift "$(LOCAL_INSTALLER)" install $(INSTALLER_ARGS); then \
		if [ -n "$$running_bundle" ] && ! open "$(INSTALLED_BUNDLE)"; then \
			echo "$(RED)Installed, but $(APP_NAME) did not open; open $(INSTALLED_BUNDLE)$(NC)"; exit 1; \
		fi; \
	else \
		status=$$?; \
		if [ -n "$$running_bundle" ] && [ -d "$$running_bundle" ] && open "$$running_bundle"; then \
			echo "$(YELLOW)Install failed; reopened $$running_bundle$(NC)"; \
		elif [ -n "$$running_bundle" ]; then \
			echo "$(RED)Install failed and $(APP_NAME) was not reopened; open $$running_bundle$(NC)"; \
		fi; \
		exit $$status; \
	fi

uninstall:
	@swift "$(LOCAL_INSTALLER)" uninstall $(INSTALLER_ARGS)

# The release steps must run in the order written: a cask before its GitHub
# release would publish a broken state. This turns off `make -j` for every
# target of this file and of the included one; the Swift build is parallel
# on its own.
.NOTPARALLEL:

# The signing, notarization, packaging and release targets live in their
# own file, so the release flow reads as one unit.
include $(RELEASE_MAKEFILE)

# ==============================================================================
# Utilities
# ==============================================================================

# Bump version in Info.plist
# Usage: make version-bump V=1.2.0
version-bump:
	@if [ -z "$(V)" ]; then \
		echo "$(RED)Usage: make version-bump V=x.y.z$(NC)"; \
		echo "Current version: $(VERSION)"; \
		exit 1; \
	fi
	@echo "$(BLUE)Bumping version to $(V)...$(NC)"
	@/usr/libexec/PlistBuddy -c "Set CFBundleVersion $(V)" Resources/Info.plist
	@/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $(V)" Resources/Info.plist
	@echo "$(GREEN)Version updated to $(V)$(NC)"
	@echo ""
	@echo "Don't forget to commit:"
	@echo "  git add Resources/Info.plist"
	@echo "  git commit -s -m \"chore: bump version to $(V)\""

# ==============================================================================
# Clean
# ==============================================================================

clean: stop
	@echo "$(BLUE)Cleaning build artifacts...$(NC)"
	@swift package clean 2>/dev/null || true
	@rm -rf .build
	@rm -rf .swiftpm
	@rm -rf build
	@rm -rf DerivedData
	@rm -rf *.xcodeproj
	@rm -rf xcuserdata
	@rm -rf *.dSYM *.dSYM.zip
	@find . -name ".DS_Store" -delete 2>/dev/null || true
	@echo "$(GREEN)Cleaned$(NC)"
