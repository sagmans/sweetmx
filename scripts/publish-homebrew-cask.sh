#!/usr/bin/env bash
# Fills the Homebrew cask template for one release and publishes it to the
# tap, so `brew install` and `brew upgrade` deliver the release that is on
# GitHub. The Makefile targets `cask-check`, `cask-render` and `cask` call it;
# the pre-push hook runs `cask-check`, and `make ship` and `make release` end
# with `cask`.
#
# The checksum comes from the disk image at the address in the cask itself,
# not from the local build: the cask must describe the file that users get.
# When the local build is present too, the two must match.
#
# It fails closed: a bad version, an address outside this project's releases,
# a failed download, an image that is not signed by the release team or has
# no valid notarization ticket, a checksum that differs from the local build,
# a tap that has a newer version, or a failed commit or push all stop it, and
# nothing reaches the tap.
#
# Usage:
#   CASK_VERSION=<x.y.z> CASK_TEMPLATE=<path> CASK_TOKEN=<cask-token> \
#     CASK_BUNDLE_ID=<bundle-id> CASK_REPO_URL=<https://github.com/owner/repo> \
#     CASK_TAP_REPO=<owner/homebrew-name> CASK_TEAM_ID=<apple-team-id> \
#     [CASK_LOCAL_DMG=<path>] \
#     scripts/publish-homebrew-cask.sh render <output-file>
#   <the same variables> scripts/publish-homebrew-cask.sh publish
#
#   <the variables of render, CASK_TEAM_ID not needed> scripts/publish-homebrew-cask.sh check
#
# `check` needs no release: it checks the address in the template, fills the
# template with a stand-in checksum and runs `brew style` on it, so a template
# mistake is found before a release and not after it. `render` writes the
# cask to a file and changes nothing else. `publish` commits that same
# content to the tap.
# CASK_LOCAL_DMG has two uses. Its file name is the disk image name that the
# release builds: when it is set, the address in the cask must end with that
# name, in every mode. Its content is compared only when the file is there,
# so the same call works in the release pipeline and later from a clean clone.
set -euo pipefail

readonly USAGE='usage: CASK_VERSION=<x.y.z> CASK_TEMPLATE=<path> CASK_TOKEN=<token> CASK_BUNDLE_ID=<id> CASK_REPO_URL=<url> CASK_TAP_REPO=<owner/homebrew-name> publish-homebrew-cask.sh check | render <output-file> | publish (render and publish also need CASK_TEAM_ID)'
readonly VERSION_PATTERN='^[0-9]+\.[0-9]+\.[0-9]+$'
readonly SHA256_PATTERN='^[0-9a-f]{64}$'
# The forms that Homebrew and macOS accept; they also keep both values safe
# as replacement text.
readonly TOKEN_PATTERN='^[a-z0-9]+(-[a-z0-9]+)*$'
readonly BUNDLE_ID_PATTERN='^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$'
readonly TEAM_ID_PATTERN='^[A-Z0-9]{10}$'
readonly REPO_URL_PATTERN='^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
# A release asset name: one path part, so the address cannot leave the release.
readonly ASSET_NAME_PATTERN='^[A-Za-z0-9_.-]+\.dmg$'
# Homebrew finds a tap only in a repository named homebrew-<name>, and its
# casks only in this folder.
readonly TAP_CASK_DIR='Casks'
readonly TAP_REPO_PATTERN='^[A-Za-z0-9_.-]+/homebrew-[A-Za-z0-9_.-]+$'
# Any name in this form that is left in a cask is a placeholder nobody filled.
readonly PLACEHOLDER_PATTERN='@[A-Z0-9_]+@'
# The token Homebrew replaces with the cask version inside the address.
readonly VERSION_INTERPOLATION='#{version}'
# A release asset can take a moment to be served after the upload, so the
# download retries a bounded number of times; curl backs off between tries.
readonly DOWNLOAD_RETRIES=5
readonly DOWNLOAD_TIMEOUT_SECONDS=300
# Limits for the Git network steps, so a dead network stops the release step
# and does not hang it. The push has a longer limit: the tap's pre-push hook
# checks the cask inside it.
readonly CLONE_TIMEOUT_SECONDS=120
readonly PUSH_TIMEOUT_SECONDS=900
readonly KILL_AFTER_SECONDS=10
readonly SSH_CONNECT_TIMEOUT_SECONDS=20
# A connection that goes silent ends after interval x count seconds, so SSH
# does not outlive the Git command that started it.
readonly SSH_ALIVE_INTERVAL_SECONDS=15
readonly SSH_ALIVE_COUNT=4
# `check` has no released image, so the cask gets a checksum that is valid in
# form only. The file is never published.
readonly STAND_IN_SHA256='0000000000000000000000000000000000000000000000000000000000000000'
# `brew style` installs its own tools on the first run; later runs take seconds.
readonly STYLE_TIMEOUT_SECONDS=600
# The tap's own hooks check the cask before it leaves the machine; a fresh
# clone has them only after this script from the tap has run.
readonly TAP_HOOK_SETUP='scripts/setup-hooks'
# Git settings that say who commits, with which key, and in which key format.
readonly IDENTITY_KEY_PATTERN='^(user|gpg)\.'

work_dir=''
# The release that the cask describes. main checks each value once and locks
# it; the other functions read them, so no call can hand them over in the
# wrong order. The names are long so that no function reuses one as a local.
cask_token=''
cask_bundle_id=''
cask_version=''
# Filled by load_release_identity; a global because Bash cannot return an array.
identity_args=()

fail() {
	echo "publish-homebrew-cask: ERROR: $1" >&2
	exit 1
}

cleanup() {
	if [ -n "$work_dir" ] && [ -d "$work_dir" ]; then
		rm -rf -- "$work_dir"
	fi
}

sha256_of() {
	local sha256
	sha256="$(shasum -a 256 -- "$1" | awk '{print $1}')"
	[[ $sha256 =~ $SHA256_PATTERN ]] || fail "unexpected checksum '$sha256' for $1"
	printf '%s\n' "$sha256"
}

# Reads the version that a cask file names; empty when the file is not there.
# A file with no readable version stops the step: the downgrade guard must
# not take it for a tap that has no cask yet.
cask_version_of() {
	local found
	[ -f "$1" ] || return 0
	found="$(sed -n 's/^[[:space:]]*version "\(.*\)"[[:space:]]*$/\1/p' "$1" | head -n 1)"
	[[ $found =~ $VERSION_PATTERN ]] || fail "cannot read the version in $1"
	printf '%s\n' "$found"
}

# Writes the cask for the given checksum. Each placeholder stands beside its
# value, so the two cannot be paired wrongly. The placeholders are checked
# before and after, so a template that lost one cannot give a cask that looks
# filled.
render() {
	local template="$1" output="$2" sha256="$3" index
	local fills=('@TOKEN@' "$cask_token" '@BUNDLE_ID@' "$cask_bundle_id" '@VERSION@' "$cask_version" '@SHA256@' "$sha256")
	local substitutions=()
	for ((index = 0; index < ${#fills[@]}; index += 2)); do
		grep -q -- "${fills[index]}" "$template" ||
			fail "template has no ${fills[index]}: $template"
		substitutions+=(-e "s/${fills[index]}/${fills[index + 1]}/g")
	done
	sed "${substitutions[@]}" "$template" >"$output"
	if grep -Eq -- "$PLACEHOLDER_PATTERN" "$output"; then
		fail "placeholders left in the rendered cask: $output"
	fi
}

# The address that Homebrew will download, read from the cask so the checksum
# cannot describe a different file. It must be an asset of this version's
# release in this project: a template that points elsewhere is a mistake or
# an attack, and its checksum must not be published. When the name of the
# disk image that the release builds is known, the address must end with it.
download_url_of() {
	local template="$1" repo_url="$2" built_name="$3" url prefix
	url="$(sed -n 's/^[[:space:]]*url "\(.*\)".*$/\1/p' "$template" | head -n 1)"
	url="${url//"$VERSION_INTERPOLATION"/$cask_version}"
	prefix="$repo_url/releases/download/v$cask_version/"
	if [ "${url#"$prefix"}" = "$url" ] || ! [[ ${url#"$prefix"} =~ $ASSET_NAME_PATTERN ]]; then
		fail "cask url is not a disk image under $prefix: '$url'"
	fi
	if [ -n "$built_name" ] && [ "${url##*/}" != "$built_name" ]; then
		fail "cask url names '${url##*/}', but the release builds '$built_name'"
	fi
	printf '%s\n' "$url"
}

download_release() {
	local url="$1" image="$2"
	echo "Downloading $url ..."
	local started="$SECONDS"
	curl --fail --location --silent --show-error \
		--proto '=https' --proto-redir '=https' \
		--retry "$DOWNLOAD_RETRIES" --retry-all-errors \
		--max-time "$DOWNLOAD_TIMEOUT_SECONDS" \
		--output "$image" "$url" ||
		fail "could not download $url (after $((SECONDS - started))s, $DOWNLOAD_RETRIES retries)"
}

# A cask must never send users an image that Gatekeeper refuses, or one that
# another team signed. A notarization ticket alone does not say whose image
# it is, so the signature must chain to Apple and to the release team.
verify_release() {
	local image="$1" url="$2" team_id="$3"
	codesign --verify --strict \
		-R="anchor apple generic and certificate leaf[subject.OU] = \"$team_id\"" "$image" ||
		fail "released image is not signed by team '$team_id' with an Apple certificate: $url"
	xcrun stapler validate "$image" ||
		fail "released image has no valid notarization ticket: $url"
}

# When this machine has the image that the release was built from, the
# released file must be that same file.
compare_local_build() {
	local local_dmg="$1" sha256="$2" local_sha256
	if [ ! -f "$local_dmg" ]; then
		echo "No local build at '$local_dmg'; the checksum comes from the release only."
		return 0
	fi
	local_sha256="$(sha256_of "$local_dmg")"
	[ "$sha256" = "$local_sha256" ] ||
		fail "released image differs from $local_dmg (released $sha256, local $local_sha256); if you built again after the release, remove the local file"
	echo "Released image matches the local build."
}

# The tap commit is made by the person who releases. Git often sets the name,
# the email, and the signing key only for some folders, and a clone in a
# temporary folder is outside them. The identity of this repository is thus
# read here and given to each Git command that commits or pushes in the tap.
load_release_identity() {
	local entry
	identity_args=()
	while IFS= read -r -d '' entry; do
		case "$entry" in
		*$'\n'*) identity_args+=(-c "${entry%%$'\n'*}=${entry#*$'\n'}") ;;
		# A setting with no value is a true flag; Git takes it as the bare key.
		*) identity_args+=(-c "$entry") ;;
		esac
	done < <(git config --null --get-regexp "$IDENTITY_KEY_PATTERN" || true)
	git config --get user.email >/dev/null ||
		fail "this repository has no Git identity (user.email) to commit the cask with"
}

# Runs one Git network step with a time limit. SSH must not ask a question:
# under the limit a prompt cannot be answered and would look like a dead
# network. --foreground lets Ctrl-C reach Git and the tap hooks. Its cost: at
# the limit only Git gets the signal: SSH has its own limits below, and the
# tap hooks bound their own steps.
bounded_git() {
	local limit="$1" ssh_command
	shift
	# The maintainer's own SSH command stays, found in the order Git uses;
	# only the options are added. GIT_SSH names a program, so it is quoted;
	# that program must take the options of `ssh`.
	ssh_command="${GIT_SSH_COMMAND:-$(git config --get core.sshCommand || printf '%q' "${GIT_SSH:-ssh}")}"
	GIT_SSH_COMMAND="$ssh_command -o BatchMode=yes -o ConnectTimeout=$SSH_CONNECT_TIMEOUT_SECONDS -o ServerAliveInterval=$SSH_ALIVE_INTERVAL_SECONDS -o ServerAliveCountMax=$SSH_ALIVE_COUNT" \
		timeout --foreground -k "$KILL_AFTER_SECONDS" "$limit" git "$@"
}

# An older version must not replace a newer one: a mistyped version in a
# repair run would send new installs back to an old release.
refuse_downgrade() {
	local current="$1" tap_repo="$2" newest
	[ -n "$current" ] || return 0
	newest="$(printf '%s\n%s\n' "$current" "$cask_version" | sort -V | tail -n 1)"
	[ "$newest" = "$cask_version" ] ||
		fail "tap $tap_repo has version $current, newer than $cask_version; nothing published"
}

# Finds a template mistake with no release, so it can run before each push
# of this repository. The network is used only when `brew style` installs
# its tools on the first run. --foreground lets Ctrl-C stop the style run.
check_template() {
	local template="$1" cask="$2"
	command -v brew >/dev/null || fail "brew not found; install Homebrew to check the cask"
	render "$template" "$cask" "$STAND_IN_SHA256"
	HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1 \
		timeout --foreground -k "$KILL_AFTER_SECONDS" "$STYLE_TIMEOUT_SECONDS" brew style "$cask" ||
		fail "brew style found offenses in the cask from $template, or did not finish in ${STYLE_TIMEOUT_SECONDS}s"
	echo "Cask template OK: $template"
}

publish() {
	local cask="$1" tap_repo="$2" clone="$3" current
	# Homebrew loads a cask only from the file that has its token as name.
	local tap_path="$TAP_CASK_DIR/$cask_token.rb"
	load_release_identity

	bounded_git "$CLONE_TIMEOUT_SECONDS" clone --quiet --depth 1 "git@github.com:$tap_repo.git" "$clone" ||
		fail "could not clone the tap $tap_repo (${CLONE_TIMEOUT_SECONDS}s limit); check that your SSH key for GitHub is in ssh-agent"
	current="$(cask_version_of "$clone/$tap_path")"
	refuse_downgrade "$current" "$tap_repo"
	mkdir -p "$clone/$TAP_CASK_DIR"
	cp "$cask" "$clone/$tap_path"
	git -C "$clone" add -- "$tap_path"
	if git -C "$clone" diff --cached --quiet; then
		echo "Tap $tap_repo already has the cask for $cask_version; nothing to publish."
		return 0
	fi
	[ -x "$clone/$TAP_HOOK_SETUP" ] ||
		fail "tap $tap_repo has no $TAP_HOOK_SETUP; its checks must run before a publish"
	(cd "$clone" && "./$TAP_HOOK_SETUP") || fail "could not set up the tap hooks in $tap_repo"
	git "${identity_args[@]}" -C "$clone" commit --quiet -s -S \
		-m "feat($cask_token): update to $cask_version" \
		-m "Release $cask_version is out. The cask must point to its disk image
so that an install or an upgrade delivers this release." ||
		fail "could not commit the cask for $cask_version to $tap_repo"
	bounded_git "$PUSH_TIMEOUT_SECONDS" "${identity_args[@]}" -C "$clone" push --quiet origin HEAD ||
		fail "could not push the cask for $cask_version to $tap_repo (${PUSH_TIMEOUT_SECONDS}s limit); run 'make cask' again"
	echo "Published $tap_path for $cask_version to $tap_repo ($(git -C "$clone" rev-parse --short HEAD))."
}

main() {
	local mode="${1:-}"
	local template="${CASK_TEMPLATE:-}" local_dmg="${CASK_LOCAL_DMG:-}"
	local repo_url="${CASK_REPO_URL:-}" team_id="${CASK_TEAM_ID:-}"
	local tap_repo="${CASK_TAP_REPO:-}"
	cask_token="${CASK_TOKEN:-}"
	cask_bundle_id="${CASK_BUNDLE_ID:-}"
	cask_version="${CASK_VERSION:-}"
	case "$mode" in
	check) [ "$#" -eq 1 ] || fail "$USAGE" ;;
	render) [ "$#" -eq 2 ] || fail "$USAGE" ;;
	publish) [ "$#" -eq 1 ] || fail "$USAGE" ;;
	*) fail "$USAGE" ;;
	esac
	[[ $cask_version =~ $VERSION_PATTERN ]] || fail "CASK_VERSION is not x.y.z: '$cask_version'"
	[ -f "$template" ] || fail "CASK_TEMPLATE not found: '$template'"
	[[ $cask_token =~ $TOKEN_PATTERN ]] || fail "CASK_TOKEN is not a cask token: '$cask_token'"
	[[ $cask_bundle_id =~ $BUNDLE_ID_PATTERN ]] || fail "CASK_BUNDLE_ID is not a bundle ID: '$cask_bundle_id'"
	[[ $repo_url =~ $REPO_URL_PATTERN ]] || fail "CASK_REPO_URL is not https://github.com/<owner>/<repo>: '$repo_url'"
	# Checked in every mode, so a wrong tap stops a push of this repository
	# and not a release.
	[[ $tap_repo =~ $TAP_REPO_PATTERN ]] || fail "CASK_TAP_REPO is not <owner>/homebrew-<name>: '$tap_repo'"
	readonly cask_token cask_bundle_id cask_version

	work_dir="$(mktemp -d)"
	trap cleanup EXIT
	# Named as it is in the tap, so `brew style` reads it as a cask.
	local url sha256 image="$work_dir/release.dmg" cask="$work_dir/Casks/cask.rb"
	mkdir "$work_dir/Casks"
	# Checked in every mode, with no network: a wrong address must stop a
	# push of this repository and not a release.
	url="$(download_url_of "$template" "$repo_url" "${local_dmg##*/}")"
	if [ "$mode" = check ]; then
		check_template "$template" "$cask"
		return 0
	fi

	[[ $team_id =~ $TEAM_ID_PATTERN ]] || fail "CASK_TEAM_ID is not an Apple team ID: '$team_id'"
	download_release "$url" "$image"
	sha256="$(sha256_of "$image")"
	verify_release "$image" "$url" "$team_id"
	compare_local_build "$local_dmg" "$sha256"
	render "$template" "$cask" "$sha256"
	echo "Cask for $cask_version: sha256 $sha256"

	if [ "$mode" = render ]; then
		cp "$cask" "$2"
		echo "Rendered: $2"
	else
		publish "$cask" "$tap_repo" "$work_dir/tap"
	fi
}

main "$@"
