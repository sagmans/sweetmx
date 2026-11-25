#!/usr/bin/env bash
# Builds the release disk image. The Makefile target `dmg` calls it; it is a
# script and not a recipe so the order of its steps can be run and tested
# without Make.
#
# The order is the contract: stage, create, sign, notarize, staple, and only
# then move the image to its release path. Every step before the move works in
# a private folder, so a failure or an interrupt leaves nothing at the release
# path for a later upload to pick up.
#
# Usage:
#   NOTARIZE_PROFILE=<keychain-profile> NOTARIZE_TIMEOUT=<duration> \
#     scripts/package-dmg.sh <app-bundle> <volume-icon> <signing-identity> \
#       <work-parent> <answer-file> <output-dmg>
#
# <app-bundle> must already carry its notarization ticket; the image only
# wraps it. <work-parent> is where the private folder is made. <answer-file>
# and the two environment values go to scripts/notarize-artifact.sh unchanged.
set -euo pipefail

readonly BUNDLE_SUFFIX='.app'
# Gives the mounted image its drag-to-install target.
readonly APPLICATIONS_DIR='/Applications'
readonly APPLICATIONS_LINK='Applications'
# Finder reads the volume icon from this name at the volume root.
readonly VOLUME_ICON_NAME='.VolumeIcon.icns'
# Compressed read-only image, the format every supported macOS opens.
readonly IMAGE_FORMAT='UDZO'
readonly STAGING_NAME='staging'
readonly WORK_TEMPLATE='dmg.XXXXXX'
# Longest time for one local step (image creation, signing with a timestamp
# from Apple's server), in seconds, so a hung tool fails the release instead
# of blocking it. Both steps take a few seconds.
readonly STEP_TIMEOUT=300
# Grace period after that limit before the step is killed, in seconds.
readonly STEP_KILL_AFTER=10
readonly USAGE='usage: NOTARIZE_PROFILE=<profile> NOTARIZE_TIMEOUT=<duration> package-dmg.sh <app-bundle> <volume-icon> <signing-identity> <work-parent> <answer-file> <output-dmg>'

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly NOTARIZE_SCRIPT="$script_dir/notarize-artifact.sh"

# Set by main once the private folder exists; the exit trap removes only it.
work_dir=''

fail() {
	echo "package-dmg: ERROR: $1" >&2
	exit 1
}

# Runs on every exit path, so an unfinished image never outlives the run.
remove_work_dir() {
	if [ -n "$work_dir" ]; then
		rm -rf "$work_dir"
	fi
}

bounded() {
	timeout -k "$STEP_KILL_AFTER" "$STEP_TIMEOUT" "$@"
}

main() {
	if [ "$#" -ne 6 ]; then
		fail "$USAGE"
	fi
	local app_bundle="$1" volume_icon="$2" signing_identity="$3"
	local work_parent="$4" answer="$5" output="$6"

	[ -d "$app_bundle" ] || fail "app bundle not found: $app_bundle"
	[ -f "$volume_icon" ] || fail "volume icon not found: $volume_icon"
	[ -n "$signing_identity" ] || fail "signing identity is empty"
	[ -n "$output" ] || fail "output path is empty"
	command -v timeout >/dev/null 2>&1 || fail "timeout not found (brew install coreutils)"

	local volume_name
	volume_name="$(basename "$app_bundle" "$BUNDLE_SUFFIX")"

	# An image from an earlier build must not pass for this one.
	rm -f "$output"

	mkdir -p "$work_parent" "$(dirname "$output")"
	work_dir="$(mktemp -d "$work_parent/$WORK_TEMPLATE")"
	trap remove_work_dir EXIT
	local staging="$work_dir/$STAGING_NAME"
	# Apple shows the submitted file name, so the image has its release name
	# from the start.
	local image
	image="$work_dir/$(basename "$output")"

	echo "Creating the disk image..."
	mkdir "$staging"
	cp -R "$app_bundle" "$staging/"
	ln -s "$APPLICATIONS_DIR" "$staging/$APPLICATIONS_LINK"
	cp "$volume_icon" "$staging/$VOLUME_ICON_NAME"
	# diskutil image is Apple's replacement for hdiutil create, which prints a
	# deprecation warning on each call.
	bounded diskutil image create from --format "$IMAGE_FORMAT" \
		--volumeName "$volume_name" "$staging" "$image" >/dev/null ||
		fail "could not create the disk image from $staging"

	# Gatekeeper judges the disk image on its own signature, so an unsigned
	# image is reported as "no usable signature" even with a notarized app in it.
	bounded codesign --force --sign "$signing_identity" --timestamp "$image" ||
		fail "could not sign the disk image"

	# A release image must carry its own ticket.
	bash "$NOTARIZE_SCRIPT" "$image" "$answer" "$image"

	mv -f "$image" "$output"
	echo "Disk image ready: $output"
}

main "$@"
