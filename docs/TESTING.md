# SweetMX Testing Guide

This document provides a comprehensive guide to the testing architecture,
patterns, and practices used in the SweetMX project.

## Table of Contents

- [Overview](#overview)
- [Directory Structure](#directory-structure)
- [Running Tests](#running-tests)
- [Test Categories](#test-categories)
- [Dependency Injection](#dependency-injection)
- [Writing New Unit Tests](#writing-new-unit-tests)
- [Writing New Mocks](#writing-new-mocks)
- [Snapshot Testing](#snapshot-testing)
- [Local Checks (Git Hooks)](#local-checks-git-hooks)
- [Code Coverage](#code-coverage)

---

## Overview

SweetMX uses a comprehensive testing strategy that includes:

- **Unit Tests** - Testing individual components in isolation
- **Integration Tests** - Testing component interactions end-to-end
- **UI Tests** - Testing launcher state, panel key routing, and the views
- **Snapshot Tests** - Catching visual regressions
- **Accessibility Tests** - Ensuring the UI is accessible

All tests are built on top of XCTest and use dependency injection to enable
thorough testing without requiring actual system interactions.

---

## Directory Structure

```text
SweetMX/
├── Sources/SweetMX/
│   ├── Protocols/           # Dependency abstraction protocols
│   │   ├── FileSystemProtocol.swift
│   │   ├── PasteboardProtocol.swift
│   │   ├── WorkspaceProtocol.swift
│   │   └── EventSourceProtocol.swift
│   ├── System/              # Production implementations
│   │   ├── SystemFileManager.swift
│   │   ├── SystemPasteboard.swift
│   │   ├── SystemWorkspace.swift
│   │   └── SystemEventSource.swift
│   ├── Models/              # Observable launcher state (LauncherModel and sub-models)
│   ├── Shell/               # Panel, controller, and key routing
│   ├── UI/                  # SwiftUI views, design tokens, and caches
│   └── ...                  # Core application files
│
├── Sources/WMCore/          # Window manager model (Foundation only)
├── Sources/WMPlatform/      # Real windows, keys and touches
├── Sources/wm-sim/          # Development tool: runs the model, no window needed
├── Sources/wmctl/           # Development tool: control client (no commands yet)
│
├── Tests/WMScenarios/       # Window manager scenario files and expected output
│   └── invalid/             # Files that wm-sim must refuse, and the error for each
│
├── Tests/SweetMXTests/
│   ├── Mocks/               # Mock implementations for testing
│   │   ├── MockFileSystem.swift
│   │   ├── MockPasteboard.swift
│   │   ├── MockWorkspace.swift
│   │   └── MockEventSource.swift
│   ├── __Snapshots__/       # Snapshot reference images
│   │   └── SnapshotTests/   # Per-test-class snapshots
│   ├── SearchServiceTests.swift
│   ├── ApplicationIndexerTests.swift
│   ├── ClipboardManagerTests.swift
│   ├── FuzzyMatcherTests.swift
│   ├── LauncherModelTests.swift
│   ├── SearchFlowIntegrationTests.swift
│   ├── ClipboardFlowIntegrationTests.swift
│   ├── SnapshotTests.swift
│   └── AccessibilityTests.swift
│
├── .githooks/
│   ├── lib/                 # generic checks (copied from the dotf template)
│   ├── pre-commit.d/        # Format and lint checks (macOS only, fail elsewhere)
│   └── pre-push.d/          # Build and test checks (macOS only, fail elsewhere)
│
└── scripts/
    ├── setup-hooks          # Sets core.hooksPath=.githooks for this clone
    ├── wm-scenarios.sh      # Window manager scenario checks (run by make test)
    ├── coverage-report.sh   # Local coverage reporting
    └── coverage-badge.py    # Coverage badge generation
```

---

## Running Tests

### Run All Tests

```bash
swift test
```

### Run Tests with Verbose Output

```bash
swift test -v
```

### Run a Specific Test Class

```bash
swift test --filter SearchServiceTests
```

### Run a Specific Test Method

```bash
swift test --filter SearchServiceTests.testExactMatchScoresHighest
```

### Run Tests with Code Coverage

```bash
swift test --enable-code-coverage
```

### Build Before Testing (Recommended)

Running `swift build` before `swift test` provides faster feedback on
compilation errors:

```bash
swift build && swift test
```

---

## Test Categories

### Unit Tests

Unit tests verify individual components work correctly in isolation using mock
dependencies.

| Test File                       | Component            | What It Tests                                      |
| ------------------------------- | -------------------- | -------------------------------------------------- |
| `SearchServiceTests.swift`      | `SearchService`      | Fuzzy matching algorithm, scoring, result ordering |
| `ApplicationIndexerTests.swift` | `ApplicationIndexer` | Directory scanning, .app detection, deduplication  |
| `ClipboardManagerTests.swift`   | `ClipboardManager`   | Clipboard monitoring, history limits, persistence  |

### Integration Tests

Integration tests verify multiple components work together correctly.

| Test File                             | Components                                      | What It Tests                   |
| ------------------------------------- | ----------------------------------------------- | ------------------------------- |
| `SearchFlowIntegrationTests.swift`    | FileSystem + ApplicationIndexer + SearchService | End-to-end search flow          |
| `ClipboardFlowIntegrationTests.swift` | Pasteboard + ClipboardManager + FileSystem      | Clipboard capture and retrieval |

### UI Tests

UI tests verify window behavior and user interaction handling.

| Test File                  | Component                                              | What It Tests                                                       |
| -------------------------- | ------------------------------------------------------ | ------------------------------------------------------------------- |
| `LauncherModelTests.swift` | `LauncherModel`, `LauncherController`, `LauncherPanel` | Show/hide, mode switching, selection, panel key routing, activation |
| `FuzzyMatcherTests.swift`  | Match runs                                             | Which characters a query highlights                                 |

### Snapshot Tests

Snapshot tests capture visual state and detect regressions.

| Test File             | What It Captures                                                                                                      |
| --------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `SnapshotTests.swift` | Empty state, search results, clipboard mode, preview pane, row selection. Each case has a light and a dark reference. |

### Accessibility Tests

Accessibility tests ensure the UI works with VoiceOver and keyboard navigation.

| Test File                  | What It Tests                                                                  |
| -------------------------- | ------------------------------------------------------------------------------ |
| `AccessibilityTests.swift` | Row labels and hints, panel label, hosted AppKit controls, keyboard navigation |

### Window manager scenario checks

The window manager lives in four targets beside the app, and it is off by
default. [AGENTS.md](../AGENTS.md#targets) lists the targets and what each may
import.

A scenario check runs a tool as a user does and compares its output and its
exit status with the expected result. The checks are in
`scripts/wm-scenarios.sh`. `make test` runs them after the Swift suite, so the
`pre-push` hook runs them on each pushed tip. To run them alone:

```bash
make wm-scenarios
```

| Scenario                                  | Passes when                                   |
| ----------------------------------------- | --------------------------------------------- |
| `wm-sim --version`                        | It prints `wm-sim` and the model version.     |
| `wm-sim` with no argument                 | It prints the usage text and exits 64.        |
| `wm-sim` with an unknown flag             | It prints the usage text and exits 64.        |
| `wm-sim --version` with an extra argument | It prints the usage text and exits 64.        |
| `wm-sim` with a file that does not exist  | It says it cannot read the file and exits 66. |
| `wm-sim --fuzz 0`, or a seed of `x`       | It prints the usage text and exits 64.        |
| Each file in `Tests/WMScenarios/`         | The output equals its `.expected` file.       |
| Each file in `Tests/WMScenarios/invalid/` | It prints the one expected error, exits 65.   |
| `wm-sim --fuzz 100000`                    | Every rule holds after each random input.     |
| `wmctl query`                             | It says it has no commands yet and exits 69.  |

The model version is `WMVersion.current` in `Sources/WMCore`. It is apart from
the app version in `Resources/Info.plist`.

#### Scenario files

The window manager model is one value. `reduce` takes the state and one input,
and returns the next state and the effects for real windows. A scenario file is
a list of inputs. `wm-sim <file>` runs them with no real window and prints the
screen after each line. The run fails when the output is not equal to the
`.expected` file beside the scenario.

| Scenario file          | Passes when                                                       |
| ---------------------- | ----------------------------------------------------------------- |
| `three-way-split.scn`  | Three windows tile the screen exactly.                            |
| `zoom-in.scn`          | The zoomed window gets the full screen. The others are hidden.    |
| `zoom-create.scn`      | The slot of the zoomed window holds three windows after zoom out. |
| `deep-zoom.scn`        | After 50 zoom levels and back, the first layout returns.          |
| `grid-walk.scn`        | After 1000 grid moves and a jump back, one workspace exists.      |
| `destroy-zoomed.scn`   | The view moves to the parent. The focus lands on a sibling.       |
| `zoom-out-at-root.scn` | Nothing changes and no effect is made.                            |
| `tree-edits.scn`       | Split, move, resize and focus change the tree as the file says.   |
| `workspaces.scn`       | A sent window is hidden. The view follows the system focus.       |
| `gaps.scn`             | Windows keep the gaps from the screen edge and from each other.   |
| `large-gaps.scn`       | A gap larger than a window leaves it on the screen with no area.  |
| `zoom-split.scn`       | A split asked for on a zoomed window sets where the next opens.   |
| `weight-drift.scn`     | After 600 rounds of resize and send, the windows keep their area. |
| `resize-floor.scn`     | A window at its smallest size stays there and can still grow.     |

The first seven are the proof that the window manager plan asks for. The run
fails when one of them is missing.

One line is one input. A line that starts with `#` is a comment.

| Line                                 | Input                                                        |
| ------------------------------------ | ------------------------------------------------------------ |
| `create`                             | A window opens. Windows get the numbers 1, 2, 3 in order.    |
| `destroy <window>`                   | A window closes.                                             |
| `focused <window>`                   | The system gave the focus to a window.                       |
| `screen <x> <y> <width> <height>`    | The display changed. The start is `0 0 1920 1080`.           |
| `focus <direction>`                  | Focus the window in that direction.                          |
| `move <direction>`                   | Move the focused window one step. A swap keeps its size.     |
| `split horizontal` or `vertical`     | The next window opens beside the focused one on that axis.   |
| `resize <direction> <amount>`        | Grow the focused window by that part of its split.           |
| `zoom in` or `zoom out`              | Go one level into the tree, or one level out.                |
| `grid <direction>`                   | Go to the next workspace on the grid.                        |
| `goto <x> <y>`                       | Go to the workspace at that cell.                            |
| `send <x> <y>`                       | Send the focused window to the workspace at that cell.       |
| `repeat <count> <input> ; <input>`   | Run the inputs that many times, then print one result.       |
| `gaps <inner> <outer>`               | Set the gaps. Only as the first line that does something.    |

A direction is `left`, `right`, `up` or `down`. Each result block has these
lines:

```text
> zoom in
grid 0,0 workspaces 1 zoom 1
tree h(1 @2* 3)
frame 2 0 0 1920 1080
hidden 1 3
effects 3
  hide 1
  hide 3
  frame 2 0 0 1920 1080
```

- `grid` shows the current cell, the number of workspaces, and the zoom depth.
- `tree` shows the splits as `h(...)` and `v(...)`. `@` marks the node that
  fills the screen. `*` marks the focused window.
- `frame` shows a visible window as `x y width height`, in whole points.
- `effects` lists what the platform layer must do. A `repeat` line shows the
  count only.

To add a scenario, write the `.scn` file and record its output:

```bash
cd Tests/WMScenarios
swift run wm-sim my-case.scn > my-case.expected
```

Read the expected file line by line before you commit it. The file is the
proof, so a wrong line in it makes a wrong layout pass.

The model sets no smallest window size. A window deep in a tree can get a frame
with no area, as in `deep-zoom.expected`. The platform layer will handle the
size that a real window accepts.

#### Property run

`wm-sim --fuzz <steps>` applies random inputs and checks the rules in
`Sources/WMCore/StateCheck.swift` after each one:

- Every window is in the tree once.
- `viewRoot` and `focus` name existing nodes, and the focus is inside the view.
- Each split has a child, and its weights keep one scale.
- The current cell exists, and no other workspace is empty.
- Visible frames never overlap.
- Visible frames stay on the screen. With no gaps, they cover all of it.

It also applies the effects of each step to a copy of the screen. The copy must
equal what the state shows, so no input can forget to move or hide a window.
Before the run, it gives the check one broken state for each rule. The run
fails if the check misses one.

The run has five parts of equal length. Each part starts from an empty state
with its own gaps: none, a usual size, an inner gap with no outer gap, a gap
larger than the screen, and a very large number.

The seed is fixed, so each run uses the same inputs. A failure prints the
seed, the step and the step count. Use the same three to see it again. To
try other inputs:

```bash
swift run wm-sim --fuzz 100000 --seed 7
```

`wm-sim` and `wmctl` are never in `SweetMX.app`. `make bundle` fails when the
bundle holds any program but the app executable, in any folder.
`make bundle-check` runs the same check on a bundle that exists.

### Window Manager switch (manual check)

Run a dev build (`make run`) and open the SweetMX menu. **Window Manager** must
show with no checkmark. Choose it: a checkmark appears and nothing else
changes. Quit and start SweetMX again: the checkmark is still there. Choose it
again to turn it off. App search and the clipboard history must work the same
in both states.

### Paste permission (manual check)

Automatic paste needs the paste permission, which tests cannot give.
`MockEventSource` stands in for it. To check the real prompt, run a dev build
without the grant. At launch, macOS must show its permission prompt, the menu
bar icon must carry an orange dot, and **Relaunch to Enable Paste** must show an
orange icon and title. Open clipboard history and press Return on a clip: no
second prompt may appear, and the footer toast must say to allow SweetMX in
Privacy & Security settings and then relaunch it, and SweetMX must appear under
System Settings, Privacy & Security, Device Control & Data Access (macOS 27) or
Accessibility (macOS 26). After you turn the permission on, choose that item:
SweetMX restarts with its history, the item and the dot are gone, and Return
pastes into the previous app.

To check that the grant survives a rebuild, sign with the local identity
(`make local-signing` once), grant the permission, run `make install` again,
and press Return on a clip. It must paste with no new grant. If SweetMX was
granted while it had another signature, remove it with **−** and add it again
with **+** first; turning the switch off and on keeps the old signature.

---

## Dependency Injection

SweetMX uses protocol-based dependency injection to enable testing without
system interactions.

### Protocol Pattern

Each external dependency has:

1. **A Protocol** defining the interface (in `Sources/SweetMX/Protocols/`)
2. **A System Implementation** using real system APIs (in
   `Sources/SweetMX/System/`)
3. **A Mock Implementation** for testing (in `Tests/SweetMXTests/Mocks/`)

### Example: FileSystemProtocol

```swift
// Protocol (Sources/SweetMX/Protocols/FileSystemProtocol.swift)
protocol FileSystemProtocol {
    var homeDirectoryForCurrentUser: URL { get }
    func fileExists(atPath path: String) -> Bool
    func contentsOfDirectory(at url: URL, ...) throws -> [URL]
    // ... other methods
}

// System Implementation (Sources/SweetMX/System/SystemFileManager.swift)
final class SystemFileManager: FileSystemProtocol {
    private let fileManager: FileManager
    
    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }
    
    var homeDirectoryForCurrentUser: URL {
        fileManager.homeDirectoryForCurrentUser
    }
    // ... implementation using FileManager
}

// Mock Implementation (Tests/SweetMXTests/Mocks/MockFileSystem.swift)
final class MockFileSystem: FileSystemProtocol {
    var mockHomeDirectory: URL = URL(fileURLWithPath: "/Users/testuser")
    var existingFiles: [String: Bool] = [:]
    var directoryContents: [URL: [URL]] = [:]
    
    // Track invocations for verification
    var fileExistsAtPathCalls: [String] = []
    
    // ... implementation returning configurable values
}
```

### Injecting Dependencies

Components accept dependencies via initializer with default production
implementations:

```swift
class ApplicationIndexer {
    private let fileSystem: FileSystemProtocol
    
    // Default parameter for production use
    init(fileSystem: FileSystemProtocol = SystemFileManager()) {
        self.fileSystem = fileSystem
    }
}

// In tests:
let mockFileSystem = MockFileSystem()
let indexer = ApplicationIndexer(fileSystem: mockFileSystem)
```

---

## Writing New Unit Tests

### 1. Create the Test File

Create a new file in `Tests/SweetMXTests/` following the naming convention
`{Component}Tests.swift`:

```swift
import XCTest
@testable import SweetMX

final class MyComponentTests: XCTestCase {
    // Test setup
}
```

### 2. Set Up Mocks

Use `setUp()` to create fresh mocks for each test:

```swift
private var mockFileSystem: MockFileSystem!
private var component: MyComponent!

override func setUp() {
    super.setUp()
    mockFileSystem = MockFileSystem()
    component = MyComponent(fileSystem: mockFileSystem)
}

override func tearDown() {
    mockFileSystem = nil
    component = nil
    super.tearDown()
}
```

### 3. Configure Mock State

Set up the mock to return specific values for your test scenario:

```swift
func testFindsApplications() {
    // Configure mock
    let appsDir = URL(fileURLWithPath: "/Applications")
    let safari = appsDir.appendingPathComponent("Safari.app")
    mockFileSystem.addDirectory(at: appsDir, contents: [safari])
    mockFileSystem.existingFiles[safari.path] = true
    
    // Execute
    let result = component.scan()
    
    // Verify
    XCTAssertEqual(result.count, 1)
    XCTAssertEqual(result.first?.name, "Safari")
}
```

### 4. Verify Mock Invocations

Check that the component called the expected methods:

```swift
func testChecksFileExistence() {
    component.checkPath("/some/path")
    
    XCTAssertTrue(mockFileSystem.fileExistsAtPathCalls.contains("/some/path"))
}
```

### 5. Test Edge Cases

Always include tests for:

- Empty inputs
- Missing or invalid data
- Error conditions
- Boundary conditions

---

## Writing New Mocks

### 1. Create the Mock File

Create a new file in `Tests/SweetMXTests/Mocks/` named `Mock{Component}.swift`:

```swift
import Foundation
@testable import SweetMX

final class MockNewService: NewServiceProtocol {
    // Implementation
}
```

### 2. Add Configurable Properties

Allow tests to set expected return values:

```swift
/// Configurable return value for getData()
var mockData: Data?

/// Error to throw from getData() if set
var getDataError: Error?

func getData() throws -> Data? {
    if let error = getDataError {
        throw error
    }
    return mockData
}
```

### 3. Add Invocation Tracking

Track method calls for verification:

```swift
/// Tracks all getData() calls
var getDataCalls: Int = 0

func getData() throws -> Data? {
    getDataCalls += 1
    // ... rest of implementation
}
```

### 4. Add Helper Methods

Provide convenient methods for common operations:

```swift
/// Clears all recorded invocations
func resetInvocations() {
    getDataCalls = 0
    // ... reset other tracking
}

/// Simulates external change
func simulateChange(data: Data) {
    mockData = data
    // ... update state
}
```

---

## Snapshot Testing

SweetMX uses
[swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing)
for visual regression testing.

### How It Works

1. Each test hosts the SwiftUI launcher at its panel size.
2. The test renders it once in the light look and once in the dark look.
3. The test compares each image with its reference. It fails if they differ.

The snapshot suite sets the `launcherSnapshotMode` environment value. In this
mode every glass surface becomes a fixed opaque background. Real glass shows
what is behind the panel and follows the display profile, so its pixels change
from one machine to the next. The references check layout, text, selection, and
content colors. They do not check the glass material.

> Note: Image snapshots can differ across macOS/Xcode versions due to font/color
> rendering. `SnapshotTests` run only on macOS 26 or later, and they skip when
> `CI` is `true`.

### Snapshot File Location

Reference images are stored in:

```text
Tests/SweetMXTests/__Snapshots__/SnapshotTests/{testMethodName}.{light|dark}.png
```

### Updating Snapshots

A missing reference makes the test fail and writes the image. To change
references on purpose, record them:

```bash
RECORD_SNAPSHOTS=1 swift test --filter SnapshotTests
```

`RECORD_SNAPSHOTS` accepts `1` or `true`. Recording rewrites every reference
that the filter selects.

1. Run the command above.
2. Open the changed images and check that the change is intended.
3. Run `swift test --filter SnapshotTests` without the flag. It must pass.
4. Commit the new images with the change that caused them.

---

## Local Checks (Git Hooks)

SweetMX has no push or pull-request CI. Every check runs on the developer's Mac
through tracked git hooks, which saves macOS Actions minutes (billed at 10x).

### Setting Up Hooks

Run once per clone:

```bash
make hooks   # same as ./scripts/setup-hooks
```

`scripts/setup-hooks` sets the local `core.hooksPath=.githooks`; it needs
nothing outside this repo. Each hook runs the generic checks first (sign-off,
message structure, gitleaks secret scan, signed commits on push), then every
script in `.githooks/<hook>.d/`. `pre-push` checks signature, sign-off,
message and secrets on each pushed commit, and runs the scanners, build,
tests and performance gate once on each pushed tip. The gate is described in
[PERFORMANCE.md](PERFORMANCE.md).

### What the Hooks Run

| Hook                   | Checks                                                                                                         |
| ---------------------- | -------------------------------------------------------------------------------------------------------------- |
| `pre-commit`           | gitleaks (staged), `make format-check`, `make lint`                                                            |
| `pre-push`, per commit | sign-off, signature, message, gitleaks                                                                         |
| `pre-push`, per tip    | `make format-check lint audit-swift-dependencies swift-sast duplication`, `swift build`, `make test benchmark` |

`make swift-sast` runs the rules in `.semgrep-swift.yml` on `Sources`,
`Resources` and the Swift scripts. Inline `nosemgrep` comments are ignored;
an exception must be a reviewed `paths.exclude` in the rule. One exists: the
console output rule leaves out `Sources/wm-sim`, because a command-line tool
gives its result on standard output. Semgrep's Swift
parser skips some newer syntax; the scan lists each skipped span and fails
when a span is longer than `MAX_SKIPPED_LINES` in `scripts/swift-sast.sh`.
`make duplication` fails on any duplicated block in production Swift; tests
are not scanned. Format, lint, SAST and duplication all read the whole
`Sources` folder, so they cover the window manager targets too.

The Swift checks need macOS; on other systems they fail with a clear reason.

### Bypassing Hooks

Do not use `git commit --no-verify` or `git push --no-verify`: nothing else
checks the code before review.

### Disabling Hooks

All checks must pass before a push; there is no supported way to disable them.

---

## Code Coverage

### Viewing Coverage Locally

Use the coverage script for easy local viewing:

```bash
# Per-file coverage report
./scripts/coverage-report.sh

# Summary only
./scripts/coverage-report.sh --summary

# Interactive HTML report (opens in browser)
./scripts/coverage-report.sh --html

# Raw JSON data
./scripts/coverage-report.sh --json
```

### Manual Coverage Commands

```bash
# Run tests with coverage
swift test --enable-code-coverage

# Get coverage JSON path
swift test --show-codecov-path

# Generate text report
BIN_PATH=$(swift build --show-bin-path)
xcrun llvm-cov report \
  "${BIN_PATH}/SweetMXPackageTests.xctest/Contents/MacOS/SweetMXPackageTests" \
  -instr-profile="${BIN_PATH}/codecov/default.profdata" \
  -ignore-filename-regex='.build|Tests'
```

### Coverage in CI

The CI pipeline automatically:

1. Runs tests with coverage enabled
2. Generates a coverage report
3. Creates a coverage badge artifact
4. Displays coverage percentage in the workflow summary

### Coverage Goals

While there's no enforced minimum, aim for:

- **80%+** coverage for core business logic (SearchService, ApplicationIndexer,
  ClipboardManager)
- **60%+** overall line coverage
- Focus on testing important code paths over hitting percentage targets

---

## Best Practices

### General

- Run `swift build` before `swift test` for faster feedback
- Use descriptive test method names: `test{Scenario}_{ExpectedBehavior}`
- Keep tests focused - one assertion concept per test
- Clean up in `tearDown()` to prevent test pollution

### Mocks

- Create fresh mocks in each test's `setUp()`
- Use helper methods to reduce mock configuration boilerplate
- Track invocations only when you need to verify calls

### Async/Timer-Based Tests

Some tests involve timers (e.g., ClipboardManager's polling). For these:

```swift
// Wait for timer to fire
RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.6))
```

Consider adding direct access methods for faster unit testing when appropriate.

### Snapshot Test Practices

- Use `layoutSubtreeIfNeeded()` before capturing snapshots
- Keep snapshot sizes reasonable (the default window size is fine)
- Review snapshot changes carefully before committing

---

## Troubleshooting

### Tests Fail with "No such module 'SweetMX'"

Run `swift build` first to compile the main module:

```bash
swift build && swift test
```

### Snapshot Tests Fail with a Missing Reference

A new snapshot test has no reference yet. Record it with `RECORD_SNAPSHOTS=1`
(see [Updating Snapshots](#updating-snapshots)), check the image, and run the
suite again without the flag.

### Timer-Based Tests Are Slow

ClipboardManager tests use `RunLoop.current.run(until:)` to wait for timers.
This adds ~0.5 seconds per clipboard change simulation. This is intentional for
realistic testing.

### Pre-Commit Hook Not Running

Make sure this clone points at the repo hooks:

```bash
./scripts/setup-hooks
git config --show-origin --get core.hooksPath
# Should print .githooks from .git/config
```
