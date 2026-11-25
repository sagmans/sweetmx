# Signing, notarization, packaging and release targets of SweetMX.
# The Makefile includes this file and keeps every configuration value, so a
# release setting is still changed in one place. See RELEASE.md.

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

# Taken before the build reads the inputs, and kept apart until Apple's
# ticket is on the bundle: the stamp must never describe a build that was
# not notarized.
record-release-inputs:
	@$(RELEASE_INPUTS_CHECK) record "$(RELEASE_INPUTS_STAMP)" $(RELEASE_INPUTS)

# Notarize the app and attach its ticket. Both happen in one target so no
# package target can run on a bundle that Apple accepted but has no ticket.
# The fingerprint comes first: an edit made later, during the build or
# Apple's wait, then differs from the stamp and the next package step
# notarizes again.
notarize: record-release-inputs sign
	@echo "$(BLUE)Preparing for notarization...$(NC)"
	@mkdir -p "$(PACKAGE_WORK_DIR)" "$(NOTARIZE_ANSWER_DIR)"
	@# `sign` made a new bundle, so packages of an earlier one must not pass
	@# for it, even when Apple rejects this submission.
	@rm -f "$(ZIP_PATH)" "$(DMG_PATH)"
	@# Create ZIP for submission
	@echo "Creating ZIP for notarization..."
	@rm -f "$(SUBMISSION_ZIP)"
	@ditto -c -k --keepParent "$(APP_BUNDLE)" "$(SUBMISSION_ZIP)"
	@echo ""
	@echo "$(BLUE)Submitting to Apple notarization service...$(NC)"
	@echo "$(YELLOW)This may take 5-15 minutes...$(NC)"
	@echo ""
	@$(NOTARIZE_ARTIFACT) "$(SUBMISSION_ZIP)" "$(APP_NOTARIZE_ANSWER)" "$(APP_BUNDLE)"
	@rm -f "$(SUBMISSION_ZIP)"
	@$(RELEASE_INPUTS_CHECK) commit "$(RELEASE_INPUTS_STAMP)"
	@echo "$(GREEN)Notarization ACCEPTED!$(NC)"

# Never a file; makes a rule run each time it is considered.
FORCE:

# Notarizes only when the bundle has no ticket or the inputs are not those of
# the ticket. `make notarize` always sends; the packages go through here.
# The check runs each time and compares contents, not file times (make 3.81
# compares whole seconds). When it passes, the ticket file is not touched, so
# the packages stay up to date.
$(APP_TICKET): FORCE
	@status=0; $(RELEASE_INPUTS_CHECK) current "$(RELEASE_INPUTS_STAMP)" $(RELEASE_INPUTS) || status=$$?; \
	if [ "$$status" -eq 0 ] && [ -f "$@" ]; then exit 0; fi; \
	if [ "$$status" -ne 0 ] && [ "$$status" -ne "$(RELEASE_INPUTS_CHANGED)" ]; then exit "$$status"; fi; \
	echo "$(YELLOW)No notarized app for the current sources (a new build, or 'make run' or 'make install' replaced the bundle); notarizing...$(NC)"; \
	$(MAKE) notarize --no-print-directory

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

# Create the ZIP of the notarized app
$(ZIP_PATH): $(APP_TICKET)
	@$(REQUIRE_APP_TICKET)
	@echo "$(BLUE)Creating ZIP package...$(NC)"
	@mkdir -p "$(PACKAGE_WORK_DIR)" "$(DIST_DIR)"
	@# `ditto` writes a new archive each time and keeps symlinks, as it does
	@# for the archive Apple scanned.
	@ditto -c -k --keepParent "$(APP_BUNDLE)" "$(PACKAGE_WORK_DIR)/$(ZIP_NAME)"
	@mv -f "$(PACKAGE_WORK_DIR)/$(ZIP_NAME)" "$(ZIP_PATH)"
	@echo "$(GREEN)Created: $(ZIP_PATH)$(NC)"
	@ls -lh "$(ZIP_PATH)"

zip: $(ZIP_PATH)

# Create the signed and notarized DMG
$(DMG_PATH): $(APP_TICKET) $(DMG_PACKAGER) $(NOTARIZE_SCRIPT)
	@$(REQUIRE_APP_TICKET)
	@echo "$(BLUE)Creating DMG package...$(NC)"
	@mkdir -p "$(NOTARIZE_ANSWER_DIR)"
	@$(NOTARIZE_ENV) bash "$(DMG_PACKAGER)" "$(APP_BUNDLE)" Resources/AppIcon.icns \
		"$(DEVELOPER_ID)" "$(PACKAGE_WORK_DIR)" "$(DMG_NOTARIZE_ANSWER)" "$(DMG_PATH)"
	@echo "$(GREEN)Created: $(DMG_PATH)$(NC)"
	@ls -lh "$(DMG_PATH)"

dmg: $(DMG_PATH)

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
# A missing tool fails the release at a late step, or under a wrong name
# (a missing `timeout` reads as a failed credential check), so it stops first.
check-release-tools:
	@echo "$(BLUE)Checking release tools...$(NC)"
	@for tool in $(RELEASE_TOOLS); do \
		if command -v "$$tool" >/dev/null 2>&1; then \
			echo "$(GREEN)OK: $$tool available$(NC)"; \
		else \
			echo "$(RED)ERROR: $$tool not found$(NC)"; \
			echo "$(YELLOW)See RELEASE.md, section Required Tools$(NC)"; \
			exit 1; \
		fi; \
	done

preflight: check-release-tools check-cert check-notarize-creds
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
	@# A release of an existing tag fails at the tag step, after the long
	@# build and two waits for Apple, so it stops here.
	@# The remote is asked too: a tag pushed from another machine is not here
	@# until a fetch. A lookup that fails stops the release, as a tag would.
	@# --foreground: git may have to ask for a key passphrase on the terminal.
	@remote=0; timeout --foreground "$(REMOTE_TAG_TIMEOUT)" git ls-remote --exit-code --tags origin \
		"refs/tags/v$(VERSION)" >/dev/null || remote=$$?; \
	if git rev-parse -q --verify "refs/tags/v$(VERSION)" >/dev/null || [ "$$remote" -eq 0 ]; then \
		echo "$(RED)ERROR: Tag v$(VERSION) already exists!$(NC)"; \
		echo "$(YELLOW)Use: make version-bump V=x.y.z$(NC)"; \
		exit 1; \
	elif [ "$$remote" -ne "$(GIT_NO_SUCH_REF)" ]; then \
		echo "$(RED)ERROR: could not ask origin for tag v$(VERSION) (git exit $$remote, limit $(REMOTE_TAG_TIMEOUT)s)$(NC)"; \
		exit 1; \
	else \
		echo "$(GREEN)OK: Tag v$(VERSION) available$(NC)"; \
	fi
	@echo ""
	@echo "$(BLUE)[3/6] Release tools...$(NC)"
	@echo "$(GREEN)OK: Checked above$(NC)"
	@gh auth status 2>&1 | head -2 || true
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
