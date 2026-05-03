#!/usr/bin/env bash
# collect-debs.sh — fetch the latest matching .deb for every tracked package.
#
# Reads packages.yaml. For each entry, queries GitHub for the latest
# (non-prerelease unless overridden) release of <repo>, downloads any release
# asset matching <glob> into pool/main/<letter>/<name>/.
#
# Hard-fails when a package's *latest* release exists but contains no matching
# asset — that's a regression in the source repo's nfpms config and we want it
# to be loud. Skips silently when a package has no releases at all (legitimate
# state for a freshly-onboarded entry that hasn't shipped its first release).
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

for i in $(seq 0 $((count - 1))); do
	name=$(yq -r ".packages[$i].name" "$PACKAGES_FILE")
	repo=$(yq -r ".packages[$i].repo" "$PACKAGES_FILE")
	# Default the glob to <name>_*.deb (not just *.deb) so that if a source
	# repo ever attaches an unrelated .deb to a release we don't pull it in.
	glob=$(yq -r ".packages[$i].glob // \"${name}_*.deb\"" "$PACKAGES_FILE")
	include_pre=$(yq -r ".packages[$i].include_prerelease // false" "$PACKAGES_FILE")

	if [ -n "$PKG_FILTER" ] && [ "$PKG_FILTER" != "$name" ]; then
		continue
	fi

	letter=$(echo "$name" | cut -c1 | tr '[:upper:]' '[:lower:]')
	target="$POOL_DIR/main/$letter/$name"
	mkdir -p "$target"

	echo "==> $name ($repo)"

	# Pick the latest release tag, optionally filtering out pre-releases.
	if [ "$include_pre" = "true" ]; then
		jq_filter='[.[]] | sort_by(.publishedAt) | reverse | .[0].tagName'
	else
		jq_filter='[.[] | select(.isPrerelease|not)] | sort_by(.publishedAt) | reverse | .[0].tagName'
	fi

	# Don't suppress stderr or `|| true` here — gh exits 0 with empty output
	# when a repo simply has no releases, and exits non-zero on real failures
	# (auth, rate limit, network, ACL). Silently treating those as "no
	# releases" would let the publish workflow ship a stale apt repo without
	# alerting the operator. Let real failures propagate (set -e at the top
	# of the script will trip).
	tag=$(gh release list --repo "$repo" --limit 30 \
		--json tagName,isPrerelease,publishedAt \
		--jq "$jq_filter")

	if [ -z "$tag" ] || [ "$tag" = "null" ]; then
		echo "    no releases on $repo yet; skipping (not a failure)"
		skipped=$((skipped + 1))
		continue
	fi

	echo "    latest tag: $tag"

	# Download into a tmp dir so we can detect "no matching assets" vs
	# "asset already present".
	tmpdir=$(mktemp -d)
	trap 'rm -rf "$tmpdir"' EXIT

	if ! gh release download "$tag" --repo "$repo" \
		--pattern "$glob" --dir "$tmpdir" --clobber 2>/dev/null; then
		echo "    FAIL: latest release $tag has no asset matching '$glob'" >&2
		echo "          fix the source repo's nfpms config and re-cut the release" >&2
		failures=$((failures + 1))
		rm -rf "$tmpdir"
		continue
	fi

	matched=$(find "$tmpdir" -maxdepth 1 -name '*.deb' | wc -l)
	if [ "$matched" = "0" ]; then
		echo "    FAIL: latest release $tag has no .deb asset matching '$glob'" >&2
		failures=$((failures + 1))
		rm -rf "$tmpdir"
		continue
	fi

	for deb in "$tmpdir"/*.deb; do
		base=$(basename "$deb")
		mv -f "$deb" "$target/$base"
		echo "    + $target/$base"
		fetched=$((fetched + 1))
	done
	rm -rf "$tmpdir"
	trap - EXIT
done

echo
echo "==> collect summary: fetched=$fetched skipped=$skipped failed=$failures"

if [ "$failures" -gt 0 ]; then
	exit 1
fi
