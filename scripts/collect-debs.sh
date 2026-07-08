#!/usr/bin/env bash
# collect-debs.sh — fetch the newest matching .deb for every tracked package.
#
# Reads packages.yaml. For each entry, scans the recent (non-prerelease unless
# overridden) releases of <repo> newest-first and resolves to the newest release
# whose assets include one matching <glob>, downloading it into
# pool/main/<letter>/<name>/.
#
# "Newest release CONTAINING a matching asset" (not simply the single latest
# release) is deliberate: shed and its siblings now ship SELECTIVE releases in
# which a given tag may omit some packages' .deb (e.g. a server-only tag carries
# no shed-desktop_*.deb). All components share one tag family, so a tag-pattern
# filter can't distinguish them — per-package asset scanning is the only robust
# resolution. See charliek/shed docs/discovery/monorepo-consolidation.md §4.4.
#
# The scan is bounded to the most recent releases (`gh release list --limit 30`)
# and stops at the first matching release, so the common case (newest release
# matches) costs a single extra API call. It logs which release each package
# resolved to, and notes explicitly when it walked past newer releases that
# lacked the asset.
#
# Hard-fails when NO release in the scan window contains a matching asset — that
# is a regression in the source repo's nfpms config and we want it to be loud.
# Skips when a package has no releases at all (legitimate state for a freshly
# onboarded entry that hasn't shipped its first release), or when the entry sets
# `optional: true` in packages.yaml (a tracked package with no matching .deb in
# any recent release yet — e.g. still onboarding its first Linux build).
#
# Inputs (env):
#   PACKAGES_FILE  Path to packages.yaml. Default: ./packages.yaml.
#   POOL_DIR       Output root. Default: ./pool.
#   PKG_FILTER     Optional package name; if set, only that package is fetched.
#   GH_TOKEN       Required by `gh` to authenticate against GitHub.
#
# Outputs:
#   pool/main/<l>/<name>/<name>_<version>_<arch>.deb files written.
#   Prints a summary table to stdout.

set -euo pipefail

PACKAGES_FILE="${PACKAGES_FILE:-packages.yaml}"
POOL_DIR="${POOL_DIR:-pool}"
PKG_FILTER="${PKG_FILTER:-}"

require() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "error: required command '$1' not found on PATH" >&2
		exit 1
	}
}
require yq
require gh

if [ ! -f "$PACKAGES_FILE" ]; then
	echo "error: $PACKAGES_FILE not found" >&2
	exit 1
fi

mkdir -p "$POOL_DIR/main"

count=$(yq '.packages | length // 0' "$PACKAGES_FILE")
if [ "$count" = "0" ] || [ -z "$count" ]; then
	echo "==> no packages tracked in $PACKAGES_FILE; nothing to collect"
	exit 0
fi

failures=0
fetched=0
skipped=0

# Single cleanup path for the per-package download tmpdir. Installed once here
# (not re-armed inside the loop) so it stays correct on every continue/exit
# path — the old per-iteration trap set/clear pairing leaked a stale trap on the
# failure `continue` branches. Each iteration sets $tmpdir, cleans it on its own
# exit paths, and resets it to ""; this trap only fires on an abnormal exit.
tmpdir=""
cleanup() {
	# Must return 0: this fires as the EXIT trap and a non-zero return would
	# become the script's exit status on an otherwise-successful run.
	if [ -n "$tmpdir" ]; then
		rm -rf "$tmpdir"
	fi
}
trap cleanup EXIT

for i in $(seq 0 $((count - 1))); do
	name=$(yq -r ".packages[$i].name" "$PACKAGES_FILE")
	repo=$(yq -r ".packages[$i].repo" "$PACKAGES_FILE")
	# Default the glob to <name>_*.deb (not just *.deb) so that if a source
	# repo ever attaches an unrelated .deb to a release we don't pull it in.
	glob=$(yq -r ".packages[$i].glob // \"${name}_*.deb\"" "$PACKAGES_FILE")
	include_pre=$(yq -r ".packages[$i].include_prerelease // false" "$PACKAGES_FILE")
	# optional=true: a missing .deb in the latest release is a warning, not a
	# hard failure — for a package still onboarding its first .deb.
	optional=$(yq -r ".packages[$i].optional // false" "$PACKAGES_FILE")

	if [ -n "$PKG_FILTER" ] && [ "$PKG_FILTER" != "$name" ]; then
		continue
	fi

	letter=$(echo "$name" | cut -c1 | tr '[:upper:]' '[:lower:]')
	target="$POOL_DIR/main/$letter/$name"
	mkdir -p "$target"

	echo "==> $name ($repo)"

	# Build a newest-first list of candidate release tags, applying the same
	# prerelease filtering as before. We scan these tags (not just the single
	# latest release) so a selective release that omits this package's .deb
	# resolves back to the newest release that DOES carry it.
	if [ "$include_pre" = "true" ]; then
		jq_filter='[.[]] | sort_by(.publishedAt) | reverse | .[].tagName'
	else
		jq_filter='[.[] | select(.isPrerelease|not)] | sort_by(.publishedAt) | reverse | .[].tagName'
	fi

	# Don't suppress stderr or `|| true` here — gh exits 0 with empty output
	# when a repo simply has no releases, and exits non-zero on real failures
	# (auth, rate limit, network, ACL). Silently treating those as "no
	# releases" would let the publish workflow ship a stale apt repo without
	# alerting the operator. Capture via command substitution (not process
	# substitution) so `set -e` still trips on a real gh failure.
	tags_raw=$(gh release list --repo "$repo" --limit 30 \
		--json tagName,isPrerelease,publishedAt \
		--jq "$jq_filter")

	if [ -z "$tags_raw" ]; then
		echo "    no releases on $repo yet; skipping (not a failure)"
		skipped=$((skipped + 1))
		continue
	fi

	mapfile -t candidate_tags <<<"$tags_raw"

	# Scan newest-first for the first release whose assets match the glob. Only
	# the asset NAMES are queried per candidate (one API call each), and the
	# scan stops at the first match — so the common case (newest release
	# matches) costs a single extra call. Newer releases walked past without a
	# matching asset are recorded so the skip can be logged explicitly.
	resolved_tag=""
	walked_past=()
	for cand in "${candidate_tags[@]}"; do
		[ -z "$cand" ] && continue
		# A transient API failure (network, rate limit) must fail THIS package
		# only, not hard-exit the whole run under set -e.
		if ! asset_names=$(gh release view "$cand" --repo "$repo" \
			--json assets --jq '.assets[].name' 2>/dev/null); then
			echo "    FAIL: could not query assets for ${cand} on ${repo} (network/auth/rate limit?)" >&2
			failures=$((failures + 1))
			continue 2
		fi
		cand_match=""
		while IFS= read -r asset; do
			[ -z "$asset" ] && continue
			# shellcheck disable=SC2254 # $glob is a shell pattern by design
			case "$asset" in
			$glob)
				cand_match="$asset"
				break
				;;
			esac
		done <<<"$asset_names"
		if [ -n "$cand_match" ]; then
			resolved_tag="$cand"
			break
		fi
		walked_past+=("$cand")
	done

	if [ -z "$resolved_tag" ]; then
		if [ "$optional" = "true" ]; then
			echo "    no release in the last ${#candidate_tags[@]} has an asset matching '$glob'; skipping (optional)"
			skipped=$((skipped + 1))
			continue
		fi
		echo "    FAIL: no release in the last ${#candidate_tags[@]} on $repo has an asset matching '$glob'" >&2
		echo "          fix the source repo's nfpms config and re-cut a release" >&2
		failures=$((failures + 1))
		continue
	fi

	if [ "${#walked_past[@]}" -gt 0 ]; then
		echo "    latest release ${walked_past[0]} has no matching asset; using $resolved_tag (walked past ${#walked_past[@]}: ${walked_past[*]})"
	else
		echo "    resolved tag: $resolved_tag"
	fi

	# Download from the resolved release only, into a tmp dir so we can detect
	# a download-vs-asset mismatch. $tmpdir is cleaned on every exit path below;
	# the EXIT trap (installed once above the loop) covers an abnormal exit
	# between here and the cleanup.
	tmpdir=$(mktemp -d)

	if ! gh release download "$resolved_tag" --repo "$repo" \
		--pattern "$glob" --dir "$tmpdir" --clobber 2>/dev/null; then
		rm -rf "$tmpdir"
		tmpdir=""
		# The asset-name scan already confirmed a match, so a download failure
		# here is a real error (network/ACL/rate limit), not a missing asset.
		echo "    FAIL: could not download '$glob' from $resolved_tag on $repo" >&2
		failures=$((failures + 1))
		continue
	fi

	matched=$(find "$tmpdir" -maxdepth 1 -name '*.deb' | wc -l)
	if [ "$matched" = "0" ]; then
		rm -rf "$tmpdir"
		tmpdir=""
		# The scan matched an asset name but no .deb landed — a glob vs
		# download-pattern mismatch. Surface it loudly rather than shipping
		# nothing.
		echo "    FAIL: $resolved_tag matched '$glob' but downloaded no .deb" >&2
		failures=$((failures + 1))
		continue
	fi

	for deb in "$tmpdir"/*.deb; do
		base=$(basename "$deb")
		mv -f "$deb" "$target/$base"
		echo "    + $target/$base"
		fetched=$((fetched + 1))
	done
	rm -rf "$tmpdir"
	tmpdir=""
done

echo
echo "==> collect summary: fetched=$fetched skipped=$skipped failed=$failures"

if [ "$failures" -gt 0 ]; then
	exit 1
fi
