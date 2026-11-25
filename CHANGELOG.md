# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic
Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Homebrew install from the tap `sagmans/tap`:
  `brew install --cask sagmans/tap/sweetmx`. Each release publishes its cask
  to the tap

## [1.1.2] - 2026-11-25

### Added

- Install steps in the README for the release download
- MIT license
- Contributing guide and security policy with a private reporting path
- GitHub issue templates (bug report, feature request, docs improvement, chore)

### Changed

- Renamed AppleBox to SweetMX, with the new bundle ID `com.sagmans.sweetmx`.
  The first launch copies clip history, recent apps, and shortcut choices
  from AppleBox, or from Bitekey, the name of unreleased builds in between.
  Each kind of data comes from the newest old app that left it. Old data is
  not changed. macOS asks again for the paste permission.
- Replaced the apple-shaped logo with a candy (bonbon) icon on the launcher's
  violet. The app ships a native glass icon, so `make bundle` and
  `make install` need full Xcode, not only the Command Line Tools
- CI installs exact, checksum-verified SwiftFormat 0.63.1 and SwiftLint 0.65.1
  instead of the latest Homebrew release, so style checks no longer drift
- `make format` and `make format-check` (and so the pre-commit hook) require
  SwiftFormat 0.64.1 exactly, because the local hooks replaced CI and used
  whatever SwiftFormat release was installed
- `make lint` (and so the pre-commit hook) requires SwiftLint 0.65.1 exactly,
  for the same reason

### Removed

- README static coverage badge and the old story checklist, which no longer
  matched the project

### Fixed

- The release disk image is signed, so Gatekeeper accepts the image and not
  only the app in it. A failed notarization of the image stops the release
- README GitHub Actions tests badge link
- Info.plist bundle version fields now correctly set to 1.1.2
- Clipboard accessibility label test no longer races the 0.5 s clipboard monitor
  timer
- All clipboard tests poll the pasteboard directly instead of waiting a fixed
  0.6 s for the monitor timer, so they no longer flake on loaded runners

## [1.1.1] - 2026-01-17

### Added

- Code signing and notarization support in build system

### Changed

- Improved clean target to remove additional build artifacts

### Fixed

- Deterministic persistence flush and atomic writes for clipboard data
- Thread-safety in MockFileSystem for tests

## [1.1.0] - 2026-01-15

### Added

- Packaging and release automation via Makefile
- Release guide documentation

### Changed

- Updated platform requirements for macOS 26

## [1.0.0] - 2026-01-15

### Added

- Alternative hotkey shortcuts (Cmd+F1 and Cmd+F2)
- Fuzzy match highlighting in clipboard sidecar
- Exact substring match prioritization in fuzzy matcher
- Recent apps display with instant search
- Premium panel system for header/results/sidecar
- Clipboard sidecar preview panel with visibility rules
- macOS accessibility settings support in styling
- Makefile and Info.plist for macOS build

### Changed

- Search updates on each keystroke for instant feedback
- Faster fuzzy matching algorithm
- Cached indices for fast startup
- Refined glass styling for UI
- Polished results list with card rows and refined selection
- Upgraded search header bar styling and focus treatment
- Aligned sidecar preview styling with lower contrast

### Fixed

- Single-line display enforcement for clipboard list items
- Esc key now clears and closes search properly
- Carbon global hotkeys implementation
- Centered search text and selection highlight
