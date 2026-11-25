#!/usr/bin/env bash
# One notarization flow for every release artifact (the app archive and the
# disk image). The Makefile target `notarize` and scripts/package-dmg.sh both
# call it, so a release cannot pass with one artifact checked more weakly than
# the other.
#
# It fails closed: a submission error, a status other than Accepted, an answer
# that cannot be read, a failed staple, or a ticket that does not validate all
# stop the release.
#
# Usage:
#   NOTARIZE_PROFILE=<keychain-profile> NOTARIZE_TIMEOUT=<duration> \
#     scripts/notarize-artifact.sh <artifact> <answer-file> <staple-target>
#
# The profile and the time limit come from the environment because they are
# the same for every artifact; the Makefile passes them on each call. The time
# limit uses the notarytool form (for example 30m).
#
# <answer-file> receives Apple's answer as JSON. It is a record of one
# attempt, not a release artifact, so callers keep it out of the release
# folder.
#
# <staple-target> is what receives the ticket. For the disk image it is the
# submitted file. For the app it is the bundle, because Apple takes an archive
# of the bundle but a ticket cannot be attached to an archive.
set -euo pipefail

# Apple's answer is read as JSON, not as text: the JSON field names are a
# documented interface of notarytool, while the wording and layout of its text
# output can change between Xcode releases.
readonly ANSWER_FORMAT='json'
readonly STATUS_FIELD='status'
readonly ID_FIELD='id'
readonly ACCEPTED_STATUS='Accepted'
# The ID comes from the network and is printed inside a command the maintainer
# may paste, so only the UUID alphabet is let through.
readonly SUBMISSION_ID_PATTERN='^[0-9a-fA-F-]+$'
readonly USAGE='usage: NOTARIZE_PROFILE=<profile> NOTARIZE_TIMEOUT=<duration> notarize-artifact.sh <artifact> <answer-file> <staple-target>'

fail() {
	echo "notarize-artifact: ERROR: $1" >&2
	exit 1
}

# Prints one text field of Apple's answer, or nothing when the answer is
# missing, is not one JSON object, or lacks the field. Callers compare the
# result with an expected value, so an unreadable answer is never accepted.
answer_field() {
	local answer="$1" field="$2"
	jq -er --arg field "$field" '.[$field] | strings' "$answer" 2>/dev/null || true
}

# The maintainer needs the submission ID to read Apple's rejection log, so it
# is printed with the exact follow-up command.
print_followup() {
	local answer="$1"
	local submission_id
	submission_id="$(answer_field "$answer" "$ID_FIELD")"
	echo "notarize-artifact: Apple's answer: $answer" >&2
	if [[ $submission_id =~ $SUBMISSION_ID_PATTERN ]]; then
		echo "notarize-artifact: details: make check-notarize ID=$submission_id" >&2
	fi
}

main() {
	if [ "$#" -ne 3 ] || [ -z "${NOTARIZE_PROFILE:-}" ] || [ -z "${NOTARIZE_TIMEOUT:-}" ]; then
		fail "$USAGE"
	fi
	local profile="$NOTARIZE_PROFILE" wait_limit="$NOTARIZE_TIMEOUT"
	local artifact="$1" answer="$2" staple_target="$3"

	command -v jq >/dev/null 2>&1 || fail "jq not found; it reads Apple's answer (brew install jq)"
	[ -f "$artifact" ] || fail "artifact not found: $artifact"
	[ -e "$staple_target" ] || fail "staple target not found: $staple_target"

	# An answer from an earlier attempt must not pass for this one.
	rm -f "$answer"

	echo "Submitting $artifact to Apple (profile $profile, wait limit $wait_limit)..."
	echo "No progress is shown until Apple answers."
	local started="$SECONDS"
	local submit_status=0
	# notarytool exits 0 for a rejected submission, so both the exit status and
	# the reported status decide the result. Its error text goes to the
	# terminal on stderr; only the JSON answer goes to the file.
	xcrun notarytool submit "$artifact" \
		--keychain-profile "$profile" \
		--wait \
		--timeout "$wait_limit" \
		--output-format "$ANSWER_FORMAT" >"$answer" || submit_status="$?"
	local elapsed=$((SECONDS - started))

	local status
	status="$(answer_field "$answer" "$STATUS_FIELD")"
	if [ "$submit_status" -ne 0 ] || [ "$status" != "$ACCEPTED_STATUS" ]; then
		print_followup "$answer"
		fail "notarization of $artifact not accepted (exit $submit_status, status '${status:-unreadable}', ${elapsed}s)"
	fi
	echo "Notarization accepted: $artifact (${elapsed}s)"

	xcrun stapler staple "$staple_target" ||
		fail "could not staple the ticket to $staple_target"
	xcrun stapler validate "$staple_target" ||
		fail "stapled ticket does not validate: $staple_target"
	echo "Stapled and validated: $staple_target"
}

main "$@"
