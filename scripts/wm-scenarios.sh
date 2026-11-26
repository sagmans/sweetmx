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

# run_tool <name> <expected exit> <tool> [args...]: leaves stdout and stderr
# in the scratch folder for the caller to compare.
run_tool() {
	local name=$1 expected=$2 status=0
	shift 2
	timeout "$RUN_SECONDS" "$bin_dir/$1" "${@:2}" >"$scratch/stdout" 2>"$scratch/stderr" || status=$?
	if [[ "$status" -ne "$expected" ]]; then
		printf '❌ wm-scenarios: %s: exit %s, expected %s (%s)\n' "$name" "$status" "$expected" "$*" >&2
		cat "$scratch/stderr" >&2
		failures=$((failures + 1))
		return 1
	fi
}

# expect <name> <file> <pattern | empty>: an empty pattern means the stream
# must be empty.
expect() {
	local name=$1 file="$scratch/$2" pattern=$3
	if [[ -z "$pattern" ]]; then
		[[ ! -s "$file" ]] && return 0
	elif grep -Eqx -- "$pattern" "$file"; then
		return 0
	fi
	printf '❌ wm-scenarios: %s: unexpected %s:\n' "$name" "$2" >&2
	cat "$file" >&2
	failures=$((failures + 1))
}

pass() {
	printf 'ok   %s\n' "$1"
}

name="$SIMULATOR --version prints the version"
if run_tool "$name" "$EXIT_OK" "$SIMULATOR" --version; then
	before=$failures
	expect "$name" stdout "$VERSION_LINE"
	expect "$name" stderr ''
	[[ "$failures" -eq "$before" ]] && pass "$name"
fi

# A tool that ignored a bad command line would let a later scenario pass
# without running it.
for bad in '' '--no-such-flag' '--version extra'; do
	name="$SIMULATOR rejects '${bad}'"
	# shellcheck disable=SC2086  # split on purpose: each word is one argument
	if run_tool "$name" "$EXIT_USAGE" "$SIMULATOR" $bad; then
		before=$failures
		expect "$name" stdout ''
		expect "$name" stderr "usage: ${SIMULATOR} .*"
		[[ "$failures" -eq "$before" ]] && pass "$name"
	fi
done

name="$CONTROL reports that it has no commands yet"
if run_tool "$name" "$EXIT_UNAVAILABLE" "$CONTROL" query; then
	before=$failures
	expect "$name" stdout ''
	[[ "$failures" -eq "$before" ]] && pass "$name"
fi

if [[ "$failures" -gt 0 ]]; then
	printf '❌ wm-scenarios: %s scenario check(s) failed\n' "$failures" >&2
	exit 1
fi
printf 'Window manager scenarios OK\n'
