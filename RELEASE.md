# SweetMX Release Guide

## Overview

This document outlines the complete release process for SweetMX, including
code signing and notarization for macOS distribution.

```text
┌─────────────────────────────────────────────────────────────────┐
│  make ship  (does everything below automatically)              │
└─────────────────────────────────────────────────────────────────┘
                              │
       ┌──────────────────────┼──────────────────────┐
       ▼                      ▼                      ▼
   ┌────────┐           ┌──────────┐          ┌──────────┐
   │ clean  │    →      │  test    │    →     │  build   │
   └────────┘           └──────────┘          └──────────┘
                                                   │
       ┌──────────────────────┬──────────────────────┘
       ▼                      ▼                      
   ┌────────┐           ┌──────────┐          ┌──────────┐
   │ bundle │    →      │  sign    │    →     │ notarize │
   └────────┘           └──────────┘          └──────────┘
                                                   │
       ┌──────────────────────┬──────────────────────┘
       ▼                      ▼                      
   ┌────────┐           ┌──────────┐          ┌──────────┐
   │  dist  │    →      │ tag-push │    →     │ release  │
   └────────┘           └──────────┘          └──────────┘
                                                   │
                              ┌──────────────────────┘
                              ▼
                         ┌──────────┐
                         │   cask   │
                         └──────────┘
```

---

## Quick Start

### One-Command Release

```bash
make ship VERSION=1.2.0 NOTES="Bug fixes and performance improvements"
```

This runs the **complete pipeline**:

1. Clean all build artifacts
2. Run pre-flight checks
3. Execute test suite
4. Build release binary
5. Create app bundle
6. Sign with Developer ID
7. Submit the app to Apple notarization and staple its ticket
8. Create the .zip and .dmg packages; the .dmg is signed, notarized, and
   stapled too
9. Create git tag and push
10. Create GitHub release with artifacts
11. Publish the Homebrew cask for the new release

The pipeline waits for Apple two times: one time for the app and one time
for the disk image. Each wait has a limit of 30 minutes.

---

## Prerequisites

### Required Tools

| Tool | Purpose | Install |
| ------ | --------- | --------- |
| Xcode 26 or later (full app) | Compiler, codesign, `actool` | App Store |
| gh | GitHub CLI | `brew install gh` |
| jq | Reads Apple's notarization answer | `brew install jq` |
| timeout | Time limits on release steps | Part of macOS 27; before that `brew install coreutils` |
| Developer ID cert | Code signing | Apple Developer Portal |

Xcode supplies the Swift compiler, `codesign`, and the app icon compiler
(`actool`, Icon Composer). After the install, select it:

```bash
xcode-select -s /Applications/Xcode.app
```

### One-Time Setup

#### 1. Developer ID Certificate

```bash
# Verify certificate is installed
security find-identity -v -p codesigning | grep "Developer ID"
```

Expected output:

```text
A4B489BB... "Developer ID Application: Your Name (TEAM_ID)"
```

If missing:

1. Go to [Apple Developer Portal](https://developer.apple.com/account/resources/certificates)
2. Create "Developer ID Application" certificate
3. Download and double-click to install in Keychain

#### 2. Notarization Credentials

Releases need the notary keychain profile `SweetMX-Notarize`. The profile
holds an App Store Connect API key. Use an API key, not an app-specific
password: the key has only the role you give it, and you can revoke it
without a change to your Apple ID.

1. Open [App Store Connect API keys](https://appstoreconnect.apple.com/access/integrations/api)
   and select **Team Keys**.
2. Generate a key with **Developer** access.
3. Download the `.p8` file. Apple lets you download it one time only. Record
   the Key ID and the Issuer ID from the same page.
4. Store the profile:

   ```bash
   xcrun notarytool store-credentials "SweetMX-Notarize" \
       --key "/path/to/AuthKey_YOUR_KEY_ID.p8" \
       --key-id "YOUR_KEY_ID" \
       --issuer "YOUR_ISSUER_ID"
   ```

5. Make sure that the profile works:

   ```bash
   xcrun notarytool history --keychain-profile "SweetMX-Notarize"
   ```

6. The keychain now holds a copy of the key, and the profile works without
   the file. Save the `.p8` file in your password manager, then delete it
   from the disk.

Never put the `.p8` file in the repository. It is a secret.

#### 3. GitHub CLI Authentication

```bash
gh auth login
```

---

## Code Signing Deep Dive

### Why Code Signing?

```text
┌─────────────────────────────────────────────────────────────────┐
│  Without Signing              │  With Signing + Notarization    │
├───────────────────────────────┼─────────────────────────────────┤
│  ❌ "damaged and can't be     │  ✅ Opens normally              │
│     opened" error             │                                  │
│  ❌ Blocked by Gatekeeper     │  ✅ Gatekeeper approved          │
│  ❌ Scary security warnings   │  ✅ No warnings                  │
│  ❌ Users must bypass security│  ✅ Professional distribution    │
└───────────────────────────────┴─────────────────────────────────┘
```

### Signing Components

| Component | Purpose |
| ----------- | --------- |
| Developer ID Certificate | Proves you're a registered Apple developer |
| Hardened Runtime | Security protections required for notarization |
| Timestamp | Proves when app was signed (valid even after cert expires) |
| Entitlements | Declares app's security permissions |

### Ad-Hoc vs Developer ID Signing

```text
┌─────────────────────────────────────────────────────────────────┐
│  Ad-Hoc Signature (BAD)        │  Developer ID (GOOD)           │
├────────────────────────────────┼────────────────────────────────┤
│  Signature=adhoc               │  Signature size=9057           │
│  TeamIdentifier=not set        │  TeamIdentifier=6C96BU4M82     │
│  Authority=(none)              │  Authority=Developer ID App... │
│                                │  Authority=Apple Root CA       │
├────────────────────────────────┼────────────────────────────────┤
│  ❌ Cannot notarize            │  ✅ Can notarize                │
│  ❌ Blocked by Gatekeeper      │  ✅ Gatekeeper approved         │
└────────────────────────────────┴────────────────────────────────┘
```

Check your app's signature:

```bash
make check-adhoc
# or manually:
codesign -dv --verbose=2 .build/release/SweetMX.app 2>&1 | grep -E "Signature|Authority|Team"
```

### Entitlements

The `Resources/SweetMX.entitlements` file declares security permissions:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>com.apple.security.automation.apple-events</key>
    <true/>
</dict>
</plist>
```

| Entitlement | Purpose |
| --- | --- |
| `app-sandbox=false` | No sandbox: system-wide hotkeys need it |
| `automation.apple-events` | Send Apple Events for window management |

---

## Notarization Deep Dive

### What is Notarization?

Apple scans your app for malware and issues a "ticket" proving it's safe.

```text
┌──────────────┐      ┌──────────────┐      ┌──────────────┐
│  Your Mac    │ ───▶ │ Apple Server │ ───▶ │  Your Mac    │
│  Submit .zip │      │  Scan App    │      │  Get Ticket  │
└──────────────┘      │  (~5-15 min) │      │  Staple App  │
                      └──────────────┘      └──────────────┘
```

### Notarization Status

| Status | Meaning |
| -------- | --------- |
| `In Progress` | Apple is scanning (wait 5-15 min) |
| `Accepted` | ✅ App approved, ready to staple |
| `Invalid` | ❌ Issues found, check log |
| `Rejected` | ❌ Malware or policy violation |

### Check Notarization Status

```bash
# By submission ID
make check-notarize ID=b9976e01-0b7d-4f0a-9a61-79d65ef0731a

# Get detailed log
xcrun notarytool log <ID> --keychain-profile "SweetMX-Notarize"
```

Each submission stores Apple's answer as JSON in `.build/release/notarize/`:
`app.json` for the app and `dmg.json` for the disk image. A failed submission
prints the path of its answer and the `make check-notarize` command with its
ID.

### Common Notarization Issues

| Issue | Cause | Fix |
| ------- | ------- | ----- |
| Stuck "In Progress" | Ad-hoc signed | Re-sign with Developer ID |
| Invalid signature | No hardened runtime | Add `--options runtime` |
| Missing timestamp | No `--timestamp` flag | Add `--timestamp` to codesign |
| Credentials error | Wrong keychain profile | Re-store credentials |

---

## Makefile Targets Reference

### Development

```bash
make build          # Build release binary
make test           # Run test suite
make bundle         # Create .app bundle
make run            # Build + run app
make stop           # Stop running app
make logs           # Stream app logs
```

### Code Signing

```bash
make sign           # Sign with Developer ID
make verify-sign    # Verify signature details
make check-adhoc    # Check for ad-hoc signature (error if found)
make check-cert     # Verify Developer ID cert exists
```

### Notarization

```bash
make check-notarize-creds   # Verify the stored notarization profile
make notarize       # Build, sign, submit to Apple, wait, staple the ticket
make check-notarize ID=xxx  # Check submission status
```

### Packaging

```bash
make zip            # Create .zip of the notarized app
make dmg            # Create signed, notarized .dmg (second wait for Apple)
make dist           # Create both packages
```

The package targets do only the work that is not done. They submit the app
only when the bundle has no ticket, or when the sources or resources are not
those the notarized app was built from. They build a package only when it is
missing or older than the ticket. `make notarize` always builds and submits
again, and it removes the packages of the earlier bundle.

`make run`, `make install`, `make bundle`, `make sign`, and
`make notary-check` build the bundle again, which removes the ticket. After
one of them, the next package target submits the app and the disk image
again. To test a release, open the packages in `.build/release/dist/`.

Packages are built in `.build/release/package-work/` and moved to
`.build/release/dist/` when they are complete. The release folder holds only
files that are ready to upload.

### Release

```bash
make preflight      # Run all pre-release checks
make tag            # Create signed git tag
make tag-push       # Create + push tag
make release        # Package if necessary, tag, push the tag, upload, publish the cask
make cask           # Publish the Homebrew cask for the released version
make cask-render    # Write that cask to a file; publish nothing
make cask-check     # Check the cask template with brew style
make ship           # COMPLETE PIPELINE (recommended)
```

### Utilities

```bash
make version-bump V=1.2.0   # Update version in Info.plist
make clean                   # Remove all build artifacts
make help                    # Show all targets
```

---

## Step-by-Step Manual Release

If you need more control than `make ship`:

One manual release sends each artifact to Apple one time: the app in step 4
and the disk image in step 5. A step that is repeated without a change sends
nothing. Do not change files or run `make run` between step 4 and step 6: a
change makes the next step submit again. A new file counts as a change too,
for example a swap file that an editor writes into `Sources/` while a file is
open, so close the editor first.

### 1. Pre-flight Checks

```bash
make preflight
```

The checks stop on a missing release tool, on a failed certificate or
credential check, and on a tag that exists for this version, here or on
`origin`.

### 2. Run Tests

```bash
make test
```

### 3. Build and Sign

```bash
make sign
make verify-sign
```

This step is optional. It lets you examine the signature before Apple gets
the app. Step 4 builds and signs again.

### 4. Notarize

```bash
make notarize
```

If timeout occurs, check status:

```bash
make check-notarize ID=<submission-id>
```

`make notarize` also staples the ticket to the app and validates it.

### 5. Package

```bash
make dist
```

This step uses the app from step 4 and submits only the disk image.

### 6. Release

```bash
make release NOTES="Your release notes"
```

This step uses the packages from step 5. It creates the tag, pushes it, and
uploads the packages. Do not run `make tag-push` first: `make release` runs
it, and a tag that exists stops the release.

`make release` and `make ship` stop before they do anything else if you give
no notes, or if the file in `NOTES_FILE` is not there.

`make release` also publishes the Homebrew cask as its last step.

---

## Homebrew Cask

People can install SweetMX with
`brew install --cask sagmans/tap/sweetmx`. The cask is in the tap repository
[sagmans/homebrew-tap](https://github.com/sagmans/homebrew-tap), in
`Casks/sweetmx.rb`.

### How the cask is updated

`make ship` and `make release` end with `make cask`. You do not edit the tap
by hand. `make cask` does these steps:

1. It downloads the disk image of the release from GitHub, from the address
   in the cask.
2. It makes sure that the image is signed by the release team and has a
   valid notarization ticket.
3. It calculates the SHA-256 of the image. If `.build/release/dist` has a
   disk image for this version, the two files must be the same.
4. It fills a copy of `packaging/homebrew/sweetmx.rb.template` with the
   version and the SHA-256. The template itself does not change.
5. It commits the result to the tap with your signature and pushes it. The
   checks of the tap run before the push.

If one step fails, nothing goes to the tap, and the GitHub release stays as
it is. Correct the cause, then run the step again:

```bash
make cask VERSION=1.2.0
```

It is safe to run `make cask` more than one time. If the tap has the same
cask for that version, the command changes nothing. If the tap has a newer
version, the command stops and changes nothing.

To publish the cask you need push access to the tap over SSH, and a Git
identity with a signing key in this clone. Put the SSH key in `ssh-agent`
first: the step cannot answer a passphrase prompt.

### Change the cask

Change `packaging/homebrew/sweetmx.rb.template`, not the file in the tap:
the next release replaces the file in the tap. Check the change:

```bash
make cask-check
```

`make cask-check` checks the address in the template and runs `brew style`
on it. It needs no release, and
it runs before each push of this repository, so a mistake in the template
stops before a release. The tap runs the same check when `make cask` pushes.

To see the exact file for a version that is released, run
`make cask-render VERSION=1.1.2`. It writes `.build/release/cask/sweetmx.rb`
and publishes nothing.

If the app starts to save data in a new place, add the place to the `zap`
list. A plain uninstall must not remove user data.

### Check a published cask

```bash
brew update
brew install --cask sagmans/tap/sweetmx
brew style --cask sagmans/tap/sweetmx
brew audit --cask --strict sagmans/tap/sweetmx
brew uninstall --cask sweetmx
```

Homebrew loads a cask from a tap only when you trust it. The install with
the full name trusts this cask, so the install goes first. The uninstall
removes the trust again.

---

## Troubleshooting

### "damaged and can't be opened"

**Cause**: App not notarized or notarization ticket not stapled.

```bash
# Check if notarized
spctl -a -t exec -vv .build/release/SweetMX.app

# If not, re-notarize (this also staples the ticket)
make notarize
```

### Notarization Stuck "In Progress"

**Cause**: Usually ad-hoc signed app.

```bash
# Check signature
make check-adhoc

# If ad-hoc, re-sign properly
make sign
make notarize
```

### "Developer ID Application" certificate not found

```bash
# List available certificates
security find-identity -v -p codesigning

# If missing, download from Apple Developer Portal
```

### Gatekeeper Blocks App

```bash
# Verify app passes Gatekeeper
spctl -a -t exec -vv .build/release/SweetMX.app

# Should show: "accepted" and "Notarized Developer ID"
```

### Git Tag Already Exists

`make preflight` stops when the tag of this version exists. For a new
release, use `make version-bump V=x.y.z`. Delete a tag only if its release
was not published:

```bash
# Delete local tag
git tag -d v1.2.0

# Delete remote tag
git push origin --delete v1.2.0
```

### Homebrew Still Installs the Old Version

**Cause**: The cask step failed after the GitHub release was made.

```bash
# Publish the cask for the released version
make cask VERSION=1.2.0
```

If the message is "released image differs", you built the disk image again
after the release. Remove `.build/release/dist/SweetMX-v1.2.0-macOS.dmg`,
then run the command again.

### GitHub Release Already Exists

```bash
# Delete release (keeps tag)
gh release delete v1.2.0 --yes

# Or delete both
gh release delete v1.2.0 --yes
git push origin --delete v1.2.0
```

---

## Configuration Reference

### Makefile Variables

| Variable | Default | Description |
| ---------- | --------- | ------------- |
| `VERSION` | from Info.plist | Release version |
| `DEVELOPER_ID` | hardcoded | Code signing certificate |
| `TEAM_ID` | `6C96BU4M82` | Apple Team ID |
| `NOTARIZE_PROFILE` | `SweetMX-Notarize` | Keychain profile name |
| `NOTES` | (required) | Release notes inline |
| `NOTES_FILE` | (optional) | Path to release notes file |
| `HOMEBREW_TAP` | `sagmans/tap` | Tap that gets the cask |

### Override Examples

```bash
# Custom version
make ship VERSION=2.0.0 NOTES="Major release"

# Release notes from file
make ship VERSION=1.2.0 NOTES_FILE=CHANGELOG.md

# Just check notarization (different ID)
make check-notarize ID=abc123-def456
```

---

## Release Checklist

```text
Pre-Release:
[ ] Working tree clean (git status)
[ ] Version bumped in Info.plist
[ ] CHANGELOG updated (if maintained)
[ ] All tests pass

Signing:
[ ] Developer ID certificate valid
[ ] Notarization credentials stored
[ ] App signed with hardened runtime
[ ] NOT ad-hoc signed

Notarization:
[ ] Submitted to Apple
[ ] Status: Accepted
[ ] Ticket stapled to app
[ ] Disk image submitted to Apple
[ ] Disk image status: Accepted
[ ] Ticket stapled to disk image

Packaging:
[ ] .zip created
[ ] .dmg created and signed
[ ] Both verified (can open on fresh Mac)

Release:
[ ] Git tag created and pushed
[ ] GitHub release created
[ ] Assets uploaded
[ ] Release URL works
[ ] Homebrew cask published to the tap

Post-Release:
[ ] Download and test artifact
[ ] App opens without Gatekeeper warning
[ ] `brew install --cask sagmans/tap/sweetmx` installs the new version
```

---

## Version History

| Version | Date | Notes |
| --- | --- | --- |
| 1.1.0 | 2026-01-15 | Code signing & notarization support |
| 1.0.0 | 2026-01-15 | Initial release |
