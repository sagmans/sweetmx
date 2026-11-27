#!/usr/bin/env bash
# Scenario checks for the window manager: run its development tools as a user
# does and compare what they print and how they exit. They carry the proof for
# each window manager step, so `make test` runs them and `pre-push` runs them
# on every pushed tip.
#
# A scenario file (Tests/WMScenarios/<name>.scn) is a list of inputs for the
# window manager model. `wm-sim` prints the screen after each line, and that
# output must equal <name>.expected byte for byte. To add or change one, write
# the .scn file, run `swift run wm-sim <file> > <name>.expected`, and read the
# result line by line before committing it: the expected file is the proof.
# Usage: WM_SCENARIO_TIMEOUT=<s> WM_FUZZ_TIMEOUT=<s> scripts/wm-scenarios.sh
#        (make wm-scenarios)
set -euo pipefail

readonly RUN_SECONDS="${WM_SCENARIO_TIMEOUT:?set by make wm-scenarios}"
readonly FUZZ_SECONDS="${WM_FUZZ_TIMEOUT:?set by make wm-scenarios}"
readonly SIMULATOR=wm-sim
readonly CONTROL=wmctl
# The model version is semantic; the exact value lives only in WMCore.
readonly VERSION_LINE="^${SIMULATOR} [0-9]+\.[0-9]+\.[0-9]+\$"
readonly USAGE_LINE="usage: ${SIMULATOR} .*"
# sysexits.h values the tools use: a bad command line, and a service that is
# not there yet.
readonly EXIT_OK=0
readonly EXIT_USAGE=64
readonly EXIT_DATA=65
readonly EXIT_NO_INPUT=66
readonly EXIT_UNAVAILABLE=69
readonly SCENARIO_DIR=Tests/WMScenarios
# Files the model must refuse; each has the one error line it must print.
readonly INVALID_DIR="$SCENARIO_DIR/invalid"
readonly SCENARIO_SUFFIX=.scn
readonly EXPECTED_SUFFIX=.expected
# The scenarios that the window manager plan names as proof of the model. The
# run fails when one is missing, so deleting a file cannot make it pass.
readonly REQUIRED_SCENARIOS=(three-way-split zoom-in zoom-create deep-zoom grid-walk destroy-zoomed zoom-out-at-root)
# Random inputs in the property run, and the line a clean run prints.
readonly FUZZ_STEPS=100000
readonly FUZZ_LINE="^fuzz ok: steps=${FUZZ_STEPS} seed=[0-9]+ rules=[1-9][0-9]* .*\$"

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

# run_tool <seconds> <tool> [args...]: runs one tool with a time limit and
# leaves its streams in the scratch folder and its exit status in `status`.
run_tool() {
	status=0
	: >"$scratch/diff"
	timeout "$1" "$bin_dir/$2" "${@:3}" >"$scratch/stdout" 2>"$scratch/stderr" || status=$?
}

# judge <name> <problems> <command...>: counts and prints one result. Both
# kinds of scenario end here, so a failure always shows the same evidence.
judge() {
	local name=$1 problems=$2
	shift 2
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
		printf -- '--- difference from the expected file\n'
		cat "$scratch/diff"
	} >&2
}

# scenario <name> <seconds> <exit> <stdout> <stderr> <tool> [args...]
# Each stream is a pattern for every line, or EMPTY. One call per scenario, so
# a new one is one line and every scenario judges the exit status and both
# streams: none can pass on a partial check. The time limit is an argument, so
# no scenario runs under a limit that an earlier line left behind.
scenario() {
	local name=$1 seconds=$2 expected=$3 out_pattern=$4 err_pattern=$5 status problems=''
	shift 5
	run_tool "$seconds" "$@"
	[[ "$status" -eq "$expected" ]] || problems+=" exit=$status (expected $expected)"
	stream_matches "$scratch/stdout" "$out_pattern" || problems+=' stdout'
	stream_matches "$scratch/stderr" "$err_pattern" || problems+=' stderr'
	judge "$name" "$problems" "$@"
}

# scenario_exact <name> <exit> <stream> <expected file> <tool> [args...]
# <stream> (stdout or stderr) must equal the file byte for byte, and the other
# stream must be empty. A pattern cannot prove a whole screen; a file can.
scenario_exact() {
	local name=$1 expected=$2 stream=$3 file=$4 other=stderr status problems=''
	shift 4
	[[ "$stream" == stdout ]] || other=stdout
	run_tool "$RUN_SECONDS" "$@"
	[[ "$status" -eq "$expected" ]] || problems+=" exit=$status (expected $expected)"
	diff -u -- "$file" "$scratch/$stream" >"$scratch/diff" 2>&1 || problems+=" $stream"
	stream_matches "$scratch/$other" "$EMPTY" || problems+=" $other"
	judge "$name" "$problems" "$@"
}

# fail <message>: a problem with the scenario files themselves.
fail() {
	failures=$((failures + 1))
	printf '❌ wm-scenarios: %s\n' "$1" >&2
}

# scenario_files <folder> <exit> <stream>: runs every scenario file in a
# folder. <stream> is the one that must equal the expected file (stdout for a
# good file, stderr for a refused one); the other must be empty.
scenario_files() {
	local folder=$1 expected=$2 stream=$3 file base found=0
	for file in "$folder"/*"$SCENARIO_SUFFIX"; do
		[[ -f "$file" ]] || continue
		found=$((found + 1))
		base=${file%"$SCENARIO_SUFFIX"}
		if [[ ! -f "$base$EXPECTED_SUFFIX" ]]; then
			fail "$file has no ${base##*/}$EXPECTED_SUFFIX"
		else
			scenario_exact "$file" "$expected" "$stream" "$base$EXPECTED_SUFFIX" "$SIMULATOR" "$file"
		fi
	done
	# A folder with no scenario would pass by running nothing.
	[[ "$found" -gt 0 ]] || fail "no scenario file in $folder"
	for file in "$folder"/*"$EXPECTED_SUFFIX"; do
		[[ -f "$file" ]] || continue
		[[ -f "${file%"$EXPECTED_SUFFIX"}$SCENARIO_SUFFIX" ]] || fail "$file has no scenario file"
	done
}

scenario "$SIMULATOR --version prints the version" "$RUN_SECONDS" "$EXIT_OK" "$VERSION_LINE" "$EMPTY" "$SIMULATOR" --version
# A tool that ignored a bad command line would let a later scenario pass
# without running it.
scenario "$SIMULATOR rejects no argument" "$RUN_SECONDS" "$EXIT_USAGE" "$EMPTY" "$USAGE_LINE" "$SIMULATOR"
scenario "$SIMULATOR rejects an unknown flag" "$RUN_SECONDS" "$EXIT_USAGE" "$EMPTY" "$USAGE_LINE" "$SIMULATOR" --no-such-flag
scenario "$SIMULATOR rejects an extra argument" "$RUN_SECONDS" "$EXIT_USAGE" "$EMPTY" "$USAGE_LINE" "$SIMULATOR" --version extra
scenario "$SIMULATOR rejects a missing scenario file" "$RUN_SECONDS" "$EXIT_NO_INPUT" "$EMPTY" "${SIMULATOR}: .*: cannot read the file" "$SIMULATOR" "$SCENARIO_DIR/no-such-file$SCENARIO_SUFFIX"
scenario "$SIMULATOR rejects a property run of no steps" "$RUN_SECONDS" "$EXIT_USAGE" "$EMPTY" "$USAGE_LINE" "$SIMULATOR" --fuzz 0
scenario "$SIMULATOR rejects a seed that is not a number" "$RUN_SECONDS" "$EXIT_USAGE" "$EMPTY" "$USAGE_LINE" "$SIMULATOR" --fuzz 10 --seed x

for name in "${REQUIRED_SCENARIOS[@]}"; do
	[[ -f "$SCENARIO_DIR/$name$SCENARIO_SUFFIX" ]] || fail "required scenario $name is missing"
done
scenario_files "$SCENARIO_DIR" "$EXIT_OK" stdout
scenario_files "$INVALID_DIR" "$EXIT_DATA" stderr

# Random inputs with the rules of a sound state checked after each one. The
# seed is fixed, so the run is the same on every machine and a failure can be
# replayed. A debug build takes about 11 s for this many steps.
scenario "$SIMULATOR --fuzz $FUZZ_STEPS keeps every rule" "$FUZZ_SECONDS" "$EXIT_OK" "$FUZZ_LINE" "$EMPTY" "$SIMULATOR" --fuzz "$FUZZ_STEPS"

scenario "$CONTROL says it has no commands yet" "$RUN_SECONDS" "$EXIT_UNAVAILABLE" "$EMPTY" "${CONTROL}: no commands yet.*" "$CONTROL" query

if [[ "$failures" -gt 0 ]]; then
	printf '❌ wm-scenarios: %s scenario check(s) failed\n' "$failures" >&2
	exit 1
fi
printf 'Window manager scenarios OK\n'
