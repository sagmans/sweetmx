#!/usr/bin/env bash
# Decides whether the notarized app was built from the release inputs that
# are on disk now. The Makefile target `notarize` and the ticket rule use it,
# so a package step reuses a notarized app only for the same inputs.
#
# File times cannot answer this: Apple's wait is long enough for an edit, and
# a deleted file leaves no time behind. So the names and contents of the
# inputs are hashed into one fingerprint.
#
# Usage:
#   scripts/release-inputs.sh record  <stamp> <input>...
#   scripts/release-inputs.sh commit  <stamp>
#   scripts/release-inputs.sh current <stamp> <input>...
#
# `record` runs before the build reads the inputs and keeps the fingerprint
# apart from the stamp. `commit` runs when Apple's ticket is on the bundle and
# makes that fingerprint the stamp, so the stamp never describes a build that
# was not notarized. `current` exits 0 only when the inputs match the stamp.
#
# Each <input> is a file or a folder. It fails closed: an input that is
# missing or cannot be read stops the command, and a stamp that is missing
# counts as "not current".
set -euo pipefail

readonly PENDING_SUFFIX='.pending'
# Finder writes this file into folders on its own; it is never an input.
readonly IGNORED_NAME='.DS_Store'
readonly HASH_BITS=256
# Exit status of `current` when the inputs differ from the stamp, apart from
# 1, which is an error.
readonly NOT_CURRENT=3
readonly USAGE='usage: release-inputs.sh record|current <stamp> <input>... | commit <stamp>'

fail() {
	echo "release-inputs: ERROR: $1" >&2
	exit 1
}

# One hash over the sorted list of "hash  path" lines, so a renamed, added or
# deleted file changes it as much as an edited one.
fingerprint() {
	local input
	for input in "$@"; do
		[ -e "$input" ] || fail "release input not found: $input"
	done
	find "$@" -type f ! -name "$IGNORED_NAME" -print0 |
		LC_ALL=C sort -z |
		xargs -0 shasum -a "$HASH_BITS" |
		shasum -a "$HASH_BITS" |
		cut -d ' ' -f 1
}

main() {
	[ "$#" -ge 2 ] || fail "$USAGE"
	local action="$1" stamp="$2"
	shift 2
	local pending="$stamp$PENDING_SUFFIX"

	case "$action" in
	record)
		[ "$#" -ge 1 ] || fail "$USAGE"
		mkdir -p "$(dirname "$stamp")"
		local recorded
		recorded="$(fingerprint "$@")"
		printf '%s\n' "$recorded" >"$pending"
		;;
	commit)
		[ "$#" -eq 0 ] || fail "$USAGE"
		[ -f "$pending" ] || fail "no recorded fingerprint: $pending"
		mv -f "$pending" "$stamp"
		;;
	current)
		[ "$#" -ge 1 ] || fail "$USAGE"
		local now
		now="$(fingerprint "$@")"
		if [ -f "$stamp" ] && [ "$now" = "$(cat "$stamp")" ]; then
			exit 0
		fi
		exit "$NOT_CURRENT"
		;;
	*)
		fail "$USAGE"
		;;
	esac
}

main "$@"
