#!/usr/bin/env bash
# Scenario checks for the window manager: run its development tools as a user
# does and compare what they print and how they exit. They carry the proof for
# each window manager step, so `make test` runs them and `pre-push` runs them
# on every pushed tip. Later steps add scenario files to the same run.
# Usage: WM_SCENARIO_TIMEOUT=<s> scripts/wm-scenarios.sh   (make wm-scenarios)
set -euo pipefail

readonly RUN_SECONDS="${WM_SCENARIO_TIMEOUT:?set by make wm-scenarios}"
readonly SIMULATOR=wm-sim
readonly CONTROL=wmctl
# The model version is semantic; the exact value lives only in WMCore.
readonly VERSION_LINE="^${SIMULATOR} [0-9]+\.[0-9]+\.[0-9]+\$"
readonly USAGE_LINE="usage: ${SIMULATOR} .*"
# sysexits.h values the tools use: a bad command line, and a service that is
# not there yet.
readonly EXIT_OK=0
readonly EXIT_USAGE=64
readonly EXIT_UNAVAILABLE=69

if ! command -v timeout >/dev/null 2>&1; then
	printf '❌ wm-scenarios: timeout is not installed\n' >&2
	exit 1
fi

scratch=$(mktemp -d "${TMPDIR:-/tmp}/wm-scenarios.XXXXXX")
cleanup() {
	case "$scratch" in
	*/wm-scenarios.*) rm -rf -- "$scratch" ;;
	esac
}
trap cleanup EXIT

swift build --product "$SIMULATOR" >&2
swift build --product "$CONTROL" >&2
bin_dir=$(swift build --show-bin-path)

failures=0
# The stream must be empty; a scenario names this where it expects no output.
readonly EMPTY='-'

# stream_matches <file> <pattern | EMPTY>: every line must match the pattern.
stream_matches() {
	if [[ "$2" == "$EMPTY" ]]; then
		[[ ! -s "$1" ]]
	else
		# grep exits 1 when no line fails the pattern. Any other status,
		# such as 2 for a pattern that does not compile, must not pass.
		local status=0
		grep -Evqx -- "$2" "$1" || status=$?
		[[ -s "$1" && "$status" -eq 1 ]]
	fi
}

# scenario <name> <exit> <stdout pattern> <stderr pattern> <tool> [args...]
# One call per scenario, so a new one is one line and every scenario judges
# the exit status and both streams: none can pass on a partial check.
scenario() {
	local name=$1 expected=$2 out_pattern=$3 err_pattern=$4 status=0 problems=''
	shift 4
	timeout "$RUN_SECONDS" "$bin_dir/$1" "${@:2}" >"$scratch/stdout" 2>"$scratch/stderr" || status=$?
	[[ "$status" -eq "$expected" ]] || problems+=" exit=$status (expected $expected)"
	stream_matches "$scratch/stdout" "$out_pattern" || problems+=' stdout'
	stream_matches "$scratch/stderr" "$err_pattern" || problems+=' stderr'
	if [[ -z "$problems" ]]; then
		printf 'ok   %s\n' "$name"
		return 0
	fi
	failures=$((failures + 1))
	{
		printf '❌ wm-scenarios: %s: unexpected%s (%s)\n' "$name" "$problems" "$*"
		printf -- '--- stdout\n'
		cat "$scratch/stdout"
		printf -- '--- stderr\n'
		cat "$scratch/stderr"
	} >&2
}

scenario "$SIMULATOR --version prints the version" "$EXIT_OK" "$VERSION_LINE" "$EMPTY" "$SIMULATOR" --version
# A tool that ignored a bad command line would let a later scenario pass
# without running it.
scenario "$SIMULATOR rejects no argument" "$EXIT_USAGE" "$EMPTY" "$USAGE_LINE" "$SIMULATOR"
scenario "$SIMULATOR rejects an unknown flag" "$EXIT_USAGE" "$EMPTY" "$USAGE_LINE" "$SIMULATOR" --no-such-flag
scenario "$SIMULATOR rejects an extra argument" "$EXIT_USAGE" "$EMPTY" "$USAGE_LINE" "$SIMULATOR" --version extra
scenario "$CONTROL says it has no commands yet" "$EXIT_UNAVAILABLE" "$EMPTY" "${CONTROL}: no commands yet.*" "$CONTROL" query

if [[ "$failures" -gt 0 ]]; then
	printf '❌ wm-scenarios: %s scenario check(s) failed\n' "$failures" >&2
	exit 1
fi
printf 'Window manager scenarios OK\n'
