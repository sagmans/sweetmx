.PHONY: build test python-policy format format-check swiftformat-version swiftlint-version lint lint-scripts hooks bundle run stop status install uninstall clean icons \
        audit-swift-dependencies swift-sast duplication benchmark benchmark-baseline profile-app profile-trace \
        local-signing sign verify-sign check-adhoc notarize check-notarize check-notarize-creds \
        notary-check zip dmg dist tag tag-push release ship cask cask-render cask-check _gh-release \
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
DIST_DIR := $(BUILD_DIR)/dist

# Extract version from Info.plist (can override: make release VERSION=1.0.0)
VERSION ?= $(shell /usr/libexec/PlistBuddy -c "Print CFBundleVersion" Resources/Info.plist 2>/dev/null || echo "0.0.0")
ZIP_NAME := $(APP_NAME)-v$(VERSION)-macOS.zip
DMG_NAME := $(APP_NAME)-v$(VERSION)-macOS.dmg
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
# One flow for every release artifact; see the script header. The profile and
# the time limit go in the environment so each call site shows only the three
# things that differ: the artifact, its log, and what receives the ticket.
NOTARIZE_ARTIFACT := NOTARIZE_PROFILE="$(NOTARIZE_PROFILE)" NOTARIZE_TIMEOUT="$(NOTARIZE_TIMEOUT)" \
	bash scripts/notarize-artifact.sh
# The disk image is built, signed, and notarized here and moved to DIST_DIR
# only when Apple's ticket is on it. A failure or an interrupt at any step
# then leaves nothing at the release path for a later upload to pick up.
DMG_WORK_DIR := $(BUILD_DIR)/dmg-work
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
	CASK_LOCAL_DMG="$(DIST_DIR)/$(DMG_NAME)" \
	CASK_TAP_REPO="$(HOMEBREW_TAP_REPO)" CASK_TAP_PATH="$(HOMEBREW_CASK_PATH)" \
	bash scripts/publish-homebrew-cask.sh
ENTITLEMENTS := Resources/SweetMX.entitlements
# Menu bar status item artwork. Both files ship so AppKit can pick the @2x one
# on Retina screens instead of upscaling the 18 px file.
MENU_BAR_ICONS := Resources/MenuBarIconTemplate.png Resources/MenuBarIconTemplate@2x.png

# Exact SwiftFormat and SwiftLint pins live in mise.toml [tools] and are
# resolved + version-checked fail-closed by scripts/mise-tool.sh on demand.
MISE_TOOL := bash scripts/mise-tool.sh
# Defined before the path lists below, which expand it at once (:=).
PROFILE_SCRIPT := scripts/profile-app.swift
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
	@echo "  make test         - Run test suite"
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
	@echo "  make notarize     - Notarize the app and staple its ticket"
	@echo "  make check-notarize ID=xxx - Check notarization status"
	@echo ""
	@echo "$(GREEN)Packaging:$(NC)"
	@echo "  make zip          - Create signed .zip"
	@echo "  make dmg          - Create signed .dmg"
	@echo "  make dist         - Create both .zip and .dmg"
	@echo ""
	@echo "$(GREEN)Release:$(NC)"
	@echo "  make preflight    - Run all pre-release checks"
	@echo "  make tag          - Create signed git tag"
	@echo "  make tag-push     - Create and push tag"
	@echo "  make release      - Full release to GitHub"
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
	@swift build -c release
	@echo "$(GREEN)Build complete$(NC)"

python-policy:
	@bash scripts/check-python-runtime.sh

test: python-policy
	@echo "$(BLUE)Running tests...$(NC)"
	@swift test
	@echo "$(GREEN)All tests passed$(NC)"

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
	@swift build -c release
	@rm -f "$(BENCHMARK_RESULTS)"
	@$(BENCHMARK_RUN)
	@# Fails closed: a skipped or filtered-out test exits 0 without measuring anything.
	@test -s "$(BENCHMARK_RESULTS)" || { echo "$(RED)The performance gate measured nothing; is the test skipped?$(NC)" >&2; exit 1; }
	@echo "$(GREEN)Performance within baseline$(NC)"

# Rewrites the committed limits from this machine. Run only after an intended change, review the
# diff of benchmarks/baseline.json, and commit it with the change that moved the numbers.
# METRICS=name,name rewrites only those entries, so a new metric leaves the other limits alone.
benchmark-baseline:
	@swift build -c release
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

# ==============================================================================
# Code Signing & Notarization
# ==============================================================================

# Check if app has ad-hoc signature (common mistake)
check-adhoc:
	@echo "$(BLUE)Checking for ad-hoc signature...$(NC)"
	@if [ -d "$(APP_BUNDLE)" ]; then \
		SIG=$$(codesign -dv "$(APP_BUNDLE)" 2>&1 | grep "Signature=" | cut -d= -f2); \
		if [ "$$SIG" = "adhoc" ]; then \
			echo "$(RED)ERROR: App has ad-hoc signature!$(NC)"; \
			echo "$(RED)This will NOT work for distribution.$(NC)"; \
			echo "$(YELLOW)Run 'make sign' to sign with Developer ID.$(NC)"; \
			exit 1; \
		elif ! codesign -dvv "$(APP_BUNDLE)" 2>&1 | grep -q "^Authority=Developer ID Application"; then \
			echo "$(RED)ERROR: App is not signed with Developer ID (local builds use a self-signed identity).$(NC)"; \
			echo "$(YELLOW)Run 'make sign' to sign with Developer ID.$(NC)"; \
			exit 1; \
		else \
			echo "$(GREEN)OK: Signed with Developer ID$(NC)"; \
		fi \
	else \
		echo "$(YELLOW)No bundle found yet$(NC)"; \
	fi

# Check if Developer ID certificate is available
check-cert:
	@echo "$(BLUE)Checking Developer ID certificate...$(NC)"
	@if security find-identity -v -p codesigning | grep -q "$(TEAM_ID)"; then \
		echo "$(GREEN)OK: Developer ID certificate found$(NC)"; \
		security find-identity -v -p codesigning | grep "$(TEAM_ID)"; \
	else \
		echo "$(RED)ERROR: Developer ID certificate not found!$(NC)"; \
		echo "$(YELLOW)Expected: $(DEVELOPER_ID)$(NC)"; \
		echo ""; \
		echo "To fix:"; \
		echo "  1. Open Keychain Access"; \
		echo "  2. Import your Developer ID certificate"; \
		echo "  3. Or download from Apple Developer portal"; \
		exit 1; \
	fi

# Prove the stored notarization profile works before the long build, so a
# missing or revoked key stops a release in seconds and not after the tests.
check-notarize-creds:
	@echo "$(BLUE)Checking notarization credentials...$(NC)"
	@# notarytool's own message stays visible: it names the cause (no such
	@# profile, revoked key, no network), which this target cannot tell apart.
	@if timeout -k "$(NOTARIZE_CREDS_KILL_AFTER)" "$(NOTARIZE_CREDS_TIMEOUT)" \
		xcrun notarytool history --keychain-profile "$(NOTARIZE_PROFILE)" >/dev/null; then \
		echo "$(GREEN)OK: profile $(NOTARIZE_PROFILE) is accepted by Apple$(NC)"; \
	else \
		echo "$(RED)ERROR: profile $(NOTARIZE_PROFILE) failed the check (limit $(NOTARIZE_CREDS_TIMEOUT)s); the cause is above$(NC)"; \
		echo "$(YELLOW)See RELEASE.md, section 2 (Notarization Credentials)$(NC)"; \
		exit 1; \
	fi

# Sign the app bundle with Developer ID
sign: bundle check-cert
	@echo "$(BLUE)Signing $(APP_BUNDLE)...$(NC)"
	@# Sign the main executable first
	@if [ -f "$(ENTITLEMENTS)" ]; then \
		codesign --force --options runtime \
			--sign "$(DEVELOPER_ID)" \
			--entitlements "$(ENTITLEMENTS)" \
			--timestamp \
			"$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"; \
	else \
		codesign --force --options runtime \
			--sign "$(DEVELOPER_ID)" \
			--timestamp \
			"$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"; \
	fi
	@# Sign the bundle
	@if [ -f "$(ENTITLEMENTS)" ]; then \
		codesign --force --options runtime \
			--sign "$(DEVELOPER_ID)" \
			--entitlements "$(ENTITLEMENTS)" \
			--timestamp \
			"$(APP_BUNDLE)"; \
	else \
		codesign --force --options runtime \
			--sign "$(DEVELOPER_ID)" \
			--timestamp \
			"$(APP_BUNDLE)"; \
	fi
	@echo "$(GREEN)Signed: $(APP_BUNDLE)$(NC)"
	@# Verify signature immediately
	@$(MAKE) verify-sign --no-print-directory

# Verify code signature
verify-sign:
	@echo "$(BLUE)Verifying signature...$(NC)"
	@echo ""
	@echo "--- Signature Details ---"
	@codesign -dv --verbose=2 "$(APP_BUNDLE)" 2>&1 | grep -E "(Identifier|Authority|TeamIdentifier|Signature|Runtime)" || true
	@echo ""
	@echo "--- Gatekeeper Check ---"
	@spctl -a -t exec -vv "$(APP_BUNDLE)" 2>&1 && echo "$(GREEN)Gatekeeper: PASSED$(NC)" || echo "$(YELLOW)Gatekeeper: May require notarization$(NC)"
	@echo ""
	@# Check for ad-hoc
	@SIG=$$(codesign -dv "$(APP_BUNDLE)" 2>&1 | grep "Signature=" | cut -d= -f2); \
	if [ "$$SIG" = "adhoc" ]; then \
		echo "$(RED)WARNING: Ad-hoc signature detected!$(NC)"; \
	fi

# Notarize the app and attach its ticket. Both happen in one target so no
# package target can run on a bundle that Apple accepted but has no ticket.
notarize: sign
	@echo "$(BLUE)Preparing for notarization...$(NC)"
	@mkdir -p "$(DIST_DIR)"
	@# Create ZIP for submission
	@echo "Creating ZIP for notarization..."
	@ditto -c -k --keepParent "$(APP_BUNDLE)" "$(DIST_DIR)/$(APP_NAME)-notarize.zip"
	@echo ""
	@echo "$(BLUE)Submitting to Apple notarization service...$(NC)"
	@echo "$(YELLOW)This may take 5-15 minutes...$(NC)"
	@echo ""
	@$(NOTARIZE_ARTIFACT) "$(DIST_DIR)/$(APP_NAME)-notarize.zip" \
		"$(DIST_DIR)/notarize.log" "$(APP_BUNDLE)"
	@rm -f "$(DIST_DIR)/$(APP_NAME)-notarize.zip"
	@echo "$(GREEN)Notarization ACCEPTED!$(NC)"

# Check notarization status by submission ID
check-notarize:
	@if [ -z "$(ID)" ]; then \
		echo "$(RED)Usage: make check-notarize ID=<submission-id>$(NC)"; \
		exit 1; \
	fi
	@echo "$(BLUE)Checking notarization status...$(NC)"
	@xcrun notarytool info "$(ID)" --keychain-profile "$(NOTARIZE_PROFILE)"
	@echo ""
	@echo "$(BLUE)Fetching detailed log...$(NC)"
	@xcrun notarytool log "$(ID)" --keychain-profile "$(NOTARIZE_PROFILE)" 2>/dev/null || echo "$(YELLOW)Log not available yet$(NC)"

# ==============================================================================
# Notarization Readiness Check (Apple Documentation Compliance)
# https://developer.apple.com/documentation/security/resolving-common-notarization-issues
# ==============================================================================

notary-check: sign
	@echo ""
	@echo "$(BLUE)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo "$(BLUE)  NOTARIZATION READINESS CHECK                                   $(NC)"
	@echo "$(BLUE)  Based on: Apple Developer Documentation                        $(NC)"
	@echo "$(BLUE)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo ""
	@PASS=0; FAIL=0; WARN=0; \
	\
	echo "$(BLUE)[1/9] Code Signature Verification (--deep --strict)$(NC)"; \
	if codesign -vvv --deep --strict "$(APP_BUNDLE)" 2>&1; then \
		echo "$(GREEN)  ✓ PASS: Code signature valid$(NC)"; \
		PASS=$$((PASS+1)); \
	else \
		echo "$(RED)  ✗ FAIL: Code signature invalid$(NC)"; \
		FAIL=$$((FAIL+1)); \
	fi; \
	echo ""; \
	\
	echo "$(BLUE)[2/9] Developer ID Certificate$(NC)"; \
	AUTHORITY=$$(codesign -dvv "$(APP_BUNDLE)" 2>&1 | grep "Authority=Developer ID" | head -1); \
	if [ -n "$$AUTHORITY" ]; then \
		echo "$(GREEN)  ✓ PASS: $$AUTHORITY$(NC)"; \
		PASS=$$((PASS+1)); \
	else \
		echo "$(RED)  ✗ FAIL: Not signed with Developer ID certificate$(NC)"; \
		FAIL=$$((FAIL+1)); \
	fi; \
	echo ""; \
	\
	echo "$(BLUE)[3/9] Team Identifier$(NC)"; \
	TEAM=$$(codesign -dvv "$(APP_BUNDLE)" 2>&1 | grep "TeamIdentifier=" | cut -d= -f2); \
	if [ -n "$$TEAM" ] && [ "$$TEAM" != "not set" ]; then \
		echo "$(GREEN)  ✓ PASS: TeamIdentifier=$$TEAM$(NC)"; \
		PASS=$$((PASS+1)); \
	else \
		echo "$(RED)  ✗ FAIL: TeamIdentifier not set$(NC)"; \
		FAIL=$$((FAIL+1)); \
	fi; \
	echo ""; \
	\
	echo "$(BLUE)[4/9] Hardened Runtime$(NC)"; \
	FLAGS=$$(codesign -dvv "$(APP_BUNDLE)" 2>&1 | grep "flags=" | head -1); \
	if echo "$$FLAGS" | grep -q "runtime"; then \
		echo "$(GREEN)  ✓ PASS: Hardened runtime enabled$(NC)"; \
		echo "    $$FLAGS"; \
		PASS=$$((PASS+1)); \
	else \
		echo "$(RED)  ✗ FAIL: Hardened runtime NOT enabled$(NC)"; \
		echo "    $$FLAGS"; \
		echo "$(YELLOW)    Fix: Add --options runtime to codesign$(NC)"; \
		FAIL=$$((FAIL+1)); \
	fi; \
	echo ""; \
	\
	echo "$(BLUE)[5/9] Secure Timestamp$(NC)"; \
	TIMESTAMP=$$(codesign -dvv "$(APP_BUNDLE)" 2>&1 | grep "Timestamp="); \
	SIGNEDTIME=$$(codesign -dvv "$(APP_BUNDLE)" 2>&1 | grep "Signed Time"); \
	if [ -n "$$TIMESTAMP" ]; then \
		echo "$(GREEN)  ✓ PASS: Secure timestamp present$(NC)"; \
		echo "    $$TIMESTAMP"; \
		PASS=$$((PASS+1)); \
	elif [ -n "$$SIGNEDTIME" ]; then \
		echo "$(RED)  ✗ FAIL: No secure timestamp (only Signed Time found)$(NC)"; \
		echo "$(YELLOW)    Fix: Add --timestamp to codesign$(NC)"; \
		FAIL=$$((FAIL+1)); \
	else \
		echo "$(RED)  ✗ FAIL: No timestamp found$(NC)"; \
		FAIL=$$((FAIL+1)); \
	fi; \
	echo ""; \
	\
	echo "$(BLUE)[6/9] get-task-allow Entitlement (must NOT be present)$(NC)"; \
	ENTITLEMENTS=$$(codesign -d --entitlements :- "$(APP_BUNDLE)" 2>&1); \
	if echo "$$ENTITLEMENTS" | grep -q "get-task-allow.*true"; then \
		echo "$(RED)  ✗ FAIL: get-task-allow=true found (debug entitlement)$(NC)"; \
		echo "$(YELLOW)    Fix: Remove get-task-allow or set to false$(NC)"; \
		echo "$(YELLOW)    This is injected by Xcode for debug builds$(NC)"; \
		FAIL=$$((FAIL+1)); \
	else \
		echo "$(GREEN)  ✓ PASS: get-task-allow not present$(NC)"; \
		PASS=$$((PASS+1)); \
	fi; \
	echo ""; \
	\
	echo "$(BLUE)[7/9] Entitlements Format (must NOT be binary plist)$(NC)"; \
	if echo "$$ENTITLEMENTS" | grep -q "bplist00"; then \
		echo "$(RED)  ✗ FAIL: Binary plist entitlements detected$(NC)"; \
		echo "$(YELLOW)    Fix: Use XML format for entitlements file$(NC)"; \
		FAIL=$$((FAIL+1)); \
	else \
		echo "$(GREEN)  ✓ PASS: Entitlements are not binary plist$(NC)"; \
		PASS=$$((PASS+1)); \
	fi; \
	echo ""; \
	\
	echo "$(BLUE)[8/9] Ad-hoc Signature Check$(NC)"; \
	SIG=$$(codesign -dv "$(APP_BUNDLE)" 2>&1 | grep "Signature=" | cut -d= -f2); \
	if [ "$$SIG" = "adhoc" ]; then \
		echo "$(RED)  ✗ FAIL: Ad-hoc signature detected$(NC)"; \
		echo "$(YELLOW)    Fix: Sign with Developer ID certificate$(NC)"; \
		FAIL=$$((FAIL+1)); \
	else \
		echo "$(GREEN)  ✓ PASS: Not ad-hoc signed$(NC)"; \
		PASS=$$((PASS+1)); \
	fi; \
	echo ""; \
	\
	echo "$(BLUE)[9/9] Gatekeeper Assessment$(NC)"; \
	SPCTL_OUT=$$(spctl -a -vvv --type exec "$(APP_BUNDLE)" 2>&1); \
	SPCTL_EXIT=$$?; \
	if [ $$SPCTL_EXIT -eq 0 ]; then \
		echo "$(GREEN)  ✓ PASS: Gatekeeper approved$(NC)"; \
		echo "$$SPCTL_OUT" | head -2 | sed 's/^/    /'; \
		PASS=$$((PASS+1)); \
	elif echo "$$SPCTL_OUT" | grep -q "Unnotarized Developer ID"; then \
		echo "$(YELLOW)  ⚠ WARN: Signed but not yet notarized$(NC)"; \
		echo "$$SPCTL_OUT" | head -2 | sed 's/^/    /'; \
		WARN=$$((WARN+1)); \
	else \
		echo "$(RED)  ✗ FAIL: Gatekeeper rejected$(NC)"; \
		echo "$$SPCTL_OUT" | head -3 | sed 's/^/    /'; \
		FAIL=$$((FAIL+1)); \
	fi; \
	echo ""; \
	\
	echo "$(BLUE)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"; \
	echo "$(BLUE)  SUMMARY$(NC)"; \
	echo "$(BLUE)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"; \
	echo ""; \
	echo "  $(GREEN)PASS: $$PASS$(NC)  $(YELLOW)WARN: $$WARN$(NC)  $(RED)FAIL: $$FAIL$(NC)"; \
	echo ""; \
	if [ $$FAIL -eq 0 ]; then \
		if [ $$WARN -eq 0 ]; then \
			echo "$(GREEN)  ✓ READY FOR NOTARIZATION$(NC)"; \
		else \
			echo "$(GREEN)  ✓ READY FOR NOTARIZATION (warnings are expected before notarization)$(NC)"; \
		fi; \
		echo ""; \
		echo "  Next step:"; \
		echo "    make notarize"; \
	else \
		echo "$(RED)  ✗ NOT READY - Fix the failures above$(NC)"; \
		exit 1; \
	fi; \
	echo ""

# ==============================================================================
# Packaging
# ==============================================================================

# Create signed and notarized ZIP
zip: notarize
	@echo "$(BLUE)Creating ZIP package...$(NC)"
	@mkdir -p "$(DIST_DIR)"
	@cd "$(BUILD_DIR)" && zip -r -q "dist/$(ZIP_NAME)" "$(APP_NAME).app"
	@echo "$(GREEN)Created: $(DIST_DIR)/$(ZIP_NAME)$(NC)"
	@ls -lh "$(DIST_DIR)/$(ZIP_NAME)"

# Create signed and notarized DMG
dmg: notarize
	@echo "$(BLUE)Creating DMG package...$(NC)"
	@mkdir -p "$(DIST_DIR)"
	@# An image from an earlier build must not pass for this one.
	@rm -f "$(DIST_DIR)/$(DMG_NAME)"
	@rm -rf "$(DMG_WORK_DIR)"
	@mkdir -p "$(DMG_WORK_DIR)/staging"
	@# Copy app and create Applications symlink
	@cp -R "$(APP_BUNDLE)" "$(DMG_WORK_DIR)/staging/"
	@ln -sf /Applications "$(DMG_WORK_DIR)/staging/Applications"
	@# Add volume icon for DMG (shows in Finder when mounted)
	@cp Resources/AppIcon.icns "$(DMG_WORK_DIR)/staging/.VolumeIcon.icns"
	@hdiutil create -volname "$(APP_NAME)" \
		-srcfolder "$(DMG_WORK_DIR)/staging" \
		-ov -format UDZO \
		"$(DMG_WORK_DIR)/$(DMG_NAME)" \
		>/dev/null
	@# Gatekeeper judges the disk image on its own signature, so an unsigned
	@# image is reported as "no usable signature" even with a notarized app in it.
	@codesign --force --sign "$(DEVELOPER_ID)" --timestamp "$(DMG_WORK_DIR)/$(DMG_NAME)"
	@# A release image must carry its own ticket.
	@echo "$(BLUE)Notarizing DMG...$(NC)"
	@$(NOTARIZE_ARTIFACT) "$(DMG_WORK_DIR)/$(DMG_NAME)" \
		"$(DIST_DIR)/notarize-dmg.log" "$(DMG_WORK_DIR)/$(DMG_NAME)"
	@mv "$(DMG_WORK_DIR)/$(DMG_NAME)" "$(DIST_DIR)/$(DMG_NAME)"
	@rm -rf "$(DMG_WORK_DIR)"
	@echo "$(GREEN)Created: $(DIST_DIR)/$(DMG_NAME)$(NC)"
	@ls -lh "$(DIST_DIR)/$(DMG_NAME)"

# Create both distribution packages
dist: zip dmg
	@echo ""
	@echo "$(GREEN)Distribution packages ready:$(NC)"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@ls -lh "$(DIST_DIR)/"*.zip "$(DIST_DIR)/"*.dmg 2>/dev/null || true
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ==============================================================================
# Release
# ==============================================================================

# Pre-flight checks before release
preflight: check-cert check-notarize-creds
	@echo ""
	@echo "$(BLUE)Running pre-flight checks...$(NC)"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo ""
	@# Check git status
	@echo "$(BLUE)[1/6] Git status...$(NC)"
	@if [ -n "$$(git status --porcelain)" ]; then \
		echo "$(YELLOW)WARNING: Uncommitted changes detected$(NC)"; \
		git status --short; \
	else \
		echo "$(GREEN)OK: Working tree clean$(NC)"; \
	fi
	@echo ""
	@# Check version
	@echo "$(BLUE)[2/6] Version check...$(NC)"
	@echo "Current version: $(VERSION)"
	@if git tag | grep -q "^v$(VERSION)$$"; then \
		echo "$(RED)ERROR: Tag v$(VERSION) already exists!$(NC)"; \
		echo "$(YELLOW)Use: make version-bump V=x.y.z$(NC)"; \
	else \
		echo "$(GREEN)OK: Tag v$(VERSION) available$(NC)"; \
	fi
	@echo ""
	@# Check gh cli
	@echo "$(BLUE)[3/6] GitHub CLI...$(NC)"
	@if command -v gh >/dev/null 2>&1; then \
		echo "$(GREEN)OK: gh CLI available$(NC)"; \
		gh auth status 2>&1 | head -2 || true; \
	else \
		echo "$(RED)ERROR: gh CLI not found$(NC)"; \
		echo "$(YELLOW)Install: brew install gh$(NC)"; \
	fi
	@echo ""
	@# Check signing cert (already done above)
	@echo "$(BLUE)[4/6] Code signing certificate...$(NC)"
	@echo "$(GREEN)OK: Checked above$(NC)"
	@echo ""
	@# Check notarization credentials
	@echo "$(BLUE)[5/6] Notarization credentials...$(NC)"
	@echo "Profile: $(NOTARIZE_PROFILE)"
	@echo "$(GREEN)OK: Checked above$(NC)"
	@echo ""
	@# Check Swift
	@echo "$(BLUE)[6/6] Swift toolchain...$(NC)"
	@swift --version | head -1
	@echo "$(GREEN)OK$(NC)"
	@echo ""
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "$(GREEN)Pre-flight checks complete$(NC)"
	@echo ""

# Create signed git tag
tag:
	@echo "$(BLUE)Creating git tag v$(VERSION)...$(NC)"
	@git tag -s -a "v$(VERSION)" -m "Release v$(VERSION)"
	@echo "$(GREEN)Created tag: v$(VERSION)$(NC)"

# Push tag to remote
tag-push: tag
	@echo "$(BLUE)Pushing tag to origin...$(NC)"
	@git push origin "v$(VERSION)"
	@echo "$(GREEN)Pushed tag: v$(VERSION)$(NC)"

# Full release without the clean build and the tests of `ship`.
# Usage: make release NOTES="Release notes here"
#    or: make release NOTES_FILE=RELEASE_NOTES.md
release: dist tag-push _gh-release cask

# Create the GitHub release with its artifacts. One recipe for `release` and
# `ship`, so both publish the same files in the same way.
_gh-release:
	@echo "$(BLUE)Creating GitHub release...$(NC)"
	@if [ -n "$(NOTES_FILE)" ] && [ -f "$(NOTES_FILE)" ]; then \
		gh release create "v$(VERSION)" \
			--title "$(APP_NAME) v$(VERSION)" \
			--notes-file "$(NOTES_FILE)" \
			"$(DIST_DIR)/$(ZIP_NAME)" \
			"$(DIST_DIR)/$(DMG_NAME)"; \
	elif [ -n "$(NOTES)" ]; then \
		gh release create "v$(VERSION)" \
			--title "$(APP_NAME) v$(VERSION)" \
			--notes "$(NOTES)" \
			"$(DIST_DIR)/$(ZIP_NAME)" \
			"$(DIST_DIR)/$(DMG_NAME)"; \
	else \
		echo "$(RED)ERROR: Provide NOTES='...' or NOTES_FILE=path$(NC)"; \
		exit 1; \
	fi
	@echo ""
	@echo "$(GREEN)Released: $(REPO_URL)/releases/tag/v$(VERSION)$(NC)"

# ==============================================================================
# Homebrew cask
# ==============================================================================

# Publish the cask for the released version to the tap, after the GitHub
# release: the checksum comes from the released image. Safe to run again.
cask:
	@echo "$(BLUE)Publishing the Homebrew cask for v$(VERSION)...$(NC)"
	@$(HOMEBREW_CASK_SCRIPT) publish
	@echo "$(GREEN)Install: brew install --cask $(HOMEBREW_TAP)/$(HOMEBREW_CASK_TOKEN)$(NC)"

# Check the cask template; needs no release, so a mistake stops a push.
cask-check:
	@echo "$(BLUE)Checking the Homebrew cask template...$(NC)"
	@$(HOMEBREW_CASK_SCRIPT) check

# Write the exact file that `make cask` would publish; publish nothing.
cask-render:
	@mkdir -p "$(DIST_DIR)"
	@$(HOMEBREW_CASK_SCRIPT) render "$(DIST_DIR)/$(notdir $(HOMEBREW_CASK_PATH))"

# ==============================================================================
# SHIP - Complete Release Pipeline
# ==============================================================================
# 
# This is the ONE target to rule them all.
# Runs the complete pipeline from clean state to GitHub release.
#
# Usage:
#   make ship VERSION=1.2.0 NOTES="Bug fixes and improvements"
#   make ship VERSION=1.2.0 NOTES_FILE=CHANGELOG.md
#
# Pipeline:
#   1. clean      - Remove all build artifacts
#   2. preflight  - Verify certificates, git status, tools
#   3. test       - Run full test suite
#   4. build      - Compile release binary
#   5. bundle     - Create .app bundle
#   6. sign       - Sign with Developer ID (hardened runtime)
#   7. notarize   - Submit to Apple, wait for approval, attach the ticket
#   8. dist       - Create the .zip and the notarized .dmg
#   9. tag-push   - Create and push git tag
#  10. release    - Create GitHub release with artifacts
#  11. cask       - Publish the Homebrew cask for the new release
#
# ==============================================================================

# The release steps must run in the order written: a cask before its GitHub
# release would publish a broken state. This turns off `make -j` for the
# whole file; the Swift build is parallel on its own.
.NOTPARALLEL:

ship: clean preflight test notarize dist tag-push _gh-release cask
	@echo ""
	@echo "$(GREEN)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo "$(GREEN)  SHIP COMPLETE: $(APP_NAME) v$(VERSION)$(NC)"
	@echo "$(GREEN)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo ""
	@echo "  Release URL: $(REPO_URL)/releases/tag/v$(VERSION)"
	@echo ""
	@echo "  Artifacts:"
	@ls -lh "$(DIST_DIR)/"*.zip "$(DIST_DIR)/"*.dmg 2>/dev/null | awk '{print "    " $$9 " (" $$5 ")"}'
	@echo ""

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
