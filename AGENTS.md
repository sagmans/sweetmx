# AGENTS.md

SweetMX: a macOS launcher (app search and clipboard history) in Swift. See
`README.md` and `docs/TESTING.md`.

## Targets

`Package.swift` holds the app and the window manager. The window manager is off
by default; its switch is in the SweetMX menu and does nothing yet.

| Target | Holds | May import |
| --- | --- | --- |
| `SweetMX` | The app: app search, clipboard history, the menu. | AppKit and the system frameworks |
| `WMCore` | The window manager model. It never touches a real window. | Foundation only |
| `WMPlatform` | Real windows, keys and touches. No default main-actor isolation. | `WMCore`, AppKit |
| `wm-sim` | Development tool. Runs the model with no window and no permission. | `WMCore` |
| `wmctl` | Development tool. Will talk to a development build over a socket. | Foundation only |

`wm-sim` and `wmctl` never ship: `make bundle` fails when `SweetMX.app` holds
any program but the app executable, and the release build makes the app only.
Keep shared window manager code in `WMCore`
so `make duplication` stays clean.

Scenario checks prove each window manager step. `scripts/wm-scenarios.sh` runs
the tools as a user does and compares their output and exit status. `make test`
runs it after the Swift suite, so `pre-push` runs it on each pushed tip;
`make wm-scenarios` runs it alone.

The model is one value, `WMState`. `reduce(state, input)` is the only way to
change it, and it returns the effects for real windows. Prove a change to the
model with a scenario file in `Tests/WMScenarios/` (inputs in `<name>.scn`, the
screen after each line in `<name>.expected`), not with a unit test. Read an
expected file line by line before you commit it. `wm-sim --fuzz` applies random
inputs and checks the rules in `Sources/WMCore/StateCheck.swift` after each
one; add a rule there when the model gains a promise. See `docs/TESTING.md`.

## Git hooks

After cloning, run `scripts/setup-hooks` once. It sets
`core.hooksPath=.githooks` for this clone and its worktrees. The hooks run the
generic checks first (DCO sign-off, message structure, gitleaks secret scan,
signed commits on push), then this repo's checks in `.githooks/<hook>.d/`. They
replace pull-request CI.

All checks must pass before a push. Never bypass them with `--no-verify`. The
generic files in `.githooks/` and `scripts/setup-hooks` are copies of the dotf
template (`templates/githooks/`); change them there, not here.

- `pre-commit` checks a snapshot of the Git index so partial commits use the
  staged files and tool pins. It runs `make format-check` and `make lint` on
  Swift, then checks staged shell and Python scripts with the `shellcheck`,
  `shfmt` and `ruff` releases in `mise.toml`.
- `pre-push` runs format, lint, and script checks (`make lint-scripts`), checks
  the Homebrew cask template with `brew style` (`make cask-check`), audits
  the Swift dependency revisions, scans Swift code and bundle config with the
  rules in `.semgrep-swift.yml` (`make swift-sast`), blocks duplicated
  production Swift (`make duplication`), builds, and runs the test suite and the
  performance gate (`make benchmark`) once on each pushed tip. A push is one
  commit or a group of commits with one goal; the generic signature, sign-off,
  message and secret checks still run on every pushed commit. The suite includes
  the app search and clipboard smoke flows, and `make test` ends with the window
  manager scenario checks. The Swift checks read all of `Sources`, so they cover
  every target.
- `make benchmark` fails when a metric passes its limit in
  `benchmarks/baseline.json`. Fix the regression; never raise a limit to pass.
  Re-record with `make benchmark-baseline` only for an intended change, and
  commit the new baseline with that change. See `docs/PERFORMANCE.md`.
- Both repo checks need macOS. On another host they fail with a clear reason;
  they do not skip.
- `make format` and `make format-check` need the exact SwiftFormat release in
  `mise.toml` (`swiftformat`). To move to a new release, change that pin and
  `--minversion` in `.swiftformat`, run `make format`, and commit all of it
  together.
- `make lint` needs the exact SwiftLint release in `mise.toml` (`swiftlint`).
  To move to a new release, change that pin and `swiftlint_version` in
  `.swiftlint.yml`, fix the new findings, and commit all of it together.

Commit messages follow `.githooks/GIT_CONVENTION.md`, which `commit-msg` and
`pre-push` enforce. The generic checks need gitleaks, osv-scanner, semgrep,
lizard and markdownlint-cli2, plus actionlint and zizmor when a push changes
workflow files. A missing tool blocks the hook.
The Swift checks also need `jq`, `curl`, and `timeout`. The cask check needs
`brew`; a new Homebrew style rule can block a push until the cask template
is corrected. Install the tools
from `mise.toml` and a uv-managed Python 3.11 or newer before running the
hooks. Pin validation uses Python's TOML reader offline.
