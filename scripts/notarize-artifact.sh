#!/usr/bin/env bash
# One notarization flow for every release artifact (the app archive and the
# disk image). The Makefile targets `notarize` and `dmg` both call it, so a
# release cannot pass with one artifact checked more weakly than the other.
#
# It fails closed: a submission error, a status other than Accepted, a failed
# staple, or a ticket that does not validate all stop the release.
#
# Usage:
#   NOTARIZE_PROFILE=<keychain-profile> NOTARIZE_TIMEOUT=<duration> \
#     scripts/notarize-artifact.sh <artifact> <log> <staple-target>
#
# The profile and the time limit come from the environment because they are
# the same for every artifact; the Makefile exports them once. The time limit
# uses the notarytool form (for example 30m).
#
# <staple-target> is what receives the ticket. For the disk image it is the
# submitted file. For the app it is the bundle, because Apple takes an archive
# of the bundle but a ticket cannot be attached to an archive.
set -euo pipefail

readonly ACCEPTED_MARKER='status: Accepted'
readonly SUBMISSION_ID_PATTERN='^[[:space:]]*id:[[:space:]]*[0-9a-fA-F-]+$'
readonly USAGE='usage: NOTARIZE_PROFILE=<profile> NOTARIZE_TIMEOUT=<duration> notarize-artifact.sh <artifact> <log> <staple-target>'

fail() {
	echo "notarize-artifact: ERROR: $1" >&2
	exit 1
}

# The maintainer needs the submission ID to read Apple's rejection log, so it
# is printed with the exact follow-up command.
print_followup() {
	local log="$1"
	local submission_id
	submission_id="$(grep -E -m1 "$SUBMISSION_ID_PATTERN" "$log" | awk '{print $2}' || true)"
	echo "notarize-artifact: log: $log" >&2
	if [ -n "$submission_id" ]; then
		echo "notarize-artifact: details: make check-notarize ID=$submission_id" >&2
	fi
}

main() {
	if [ "$#" -ne 3 ] || [ -z "${NOTARIZE_PROFILE:-}" ] || [ -z "${NOTARIZE_TIMEOUT:-}" ]; then
		fail "$USAGE"
	fi
	local profile="$NOTARIZE_PROFILE" timeout="$NOTARIZE_TIMEOUT"
	local artifact="$1" log="$2" staple_target="$3"

	[ -f "$artifact" ] || fail "artifact not found: $artifact"
	[ -e "$staple_target" ] || fail "staple target not found: $staple_target"

	echo "Submitting $artifact to Apple (profile $profile, timeout $timeout)..."
	local started="$SECONDS"
	local submit_status=0
	# notarytool exits 0 for a rejected submission, so both the exit status and
	# the reported status decide the result.
	xcrun notarytool submit "$artifact" \
		--keychain-profile "$profile" \
		--wait \
		--timeout "$timeout" 2>&1 | tee "$log" || submit_status="$?"
	local elapsed=$((SECONDS - started))

	if [ "$submit_status" -ne 0 ] || ! grep -q "$ACCEPTED_MARKER" "$log"; then
		print_followup "$log"
		fail "notarization of $artifact not accepted (exit $submit_status, ${elapsed}s)"
	fi
	echo "Notarization accepted: $artifact (${elapsed}s)"

	xcrun stapler staple "$staple_target" ||
		fail "could not staple the ticket to $staple_target"
	xcrun stapler validate "$staple_target" ||
		fail "stapled ticket does not validate: $staple_target"
	echo "Stapled and validated: $staple_target"
}

main "$@"
