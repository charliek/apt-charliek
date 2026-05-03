#!/usr/bin/env bash
# verify.sh — smoke-test the apt repo end-to-end inside a ubuntu:noble container.
#
# Two modes:
#   --local             Mount $PWD into the container, serve the repo over
#                       file:///repo, import ./pubkey.gpg into apt's keyring.
#                       Used after FIXTURE_MODE publish.
#   --url <base-url>    Add the source list line for the public URL, fetch the
#                       pubkey from <url>/pubkey.gpg.
#
# Both modes:
#   - apt update (proves the signature verifies and Release/Packages parse)
#   - For each tracked package: apt-cache policy <name>
#     (proves the package is visible in the index)
#
# The --local --pkg <name> override exists for fixture testing where the
# fixture package isn't in packages.yaml ('hello' instead of 'prox' etc.).

set -euo pipefail

mode=""
url=""
pkg_override=""

while [ $# -gt 0 ]; do
	case "$1" in
	--local)
		mode="local"
		shift
		;;
	--url)
		mode="url"
		url="$2"
		shift 2
		;;
	--pkg)
		pkg_override="$2"
		shift 2
		;;
	*)
		echo "usage: $0 (--local | --url <base-url>) [--pkg <name>]" >&2
		exit 2
		;;
	esac
done

if [ -z "$mode" ]; then
	echo "usage: $0 (--local | --url <base-url>) [--pkg <name>]" >&2
	exit 2
fi

require() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "error: required command '$1' not found on PATH" >&2
		exit 1
	}
}
require docker
require yq

# Build the list of packages to probe.
if [ -n "$pkg_override" ]; then
	pkgs=("$pkg_override")
else
	mapfile -t pkgs < <(yq -r '.packages[].name // empty' packages.yaml)
fi
if [ "${#pkgs[@]}" = "0" ]; then
	echo "    (no tracked packages to probe; verifying repo metadata only)"
fi

# Compose the in-container script.
case "$mode" in
local)
	[ -f ./pubkey.gpg ] || {
		echo "error: ./pubkey.gpg missing — run scripts/publish.sh first" >&2
		exit 1
	}
	src_line="deb [signed-by=/etc/apt/keyrings/apt-charliek.gpg] file:///repo noble main"
	keyring_setup="cp /repo/pubkey.gpg /etc/apt/keyrings/apt-charliek.gpg"
	mount_args=(-v "$PWD:/repo:ro")
	;;
url)
	[ -n "$url" ] || {
		echo "error: --url requires a value" >&2
		exit 2
	}
	src_line="deb [signed-by=/etc/apt/keyrings/apt-charliek.gpg] $url noble main"
	keyring_setup="curl -fsSL '$url/pubkey.gpg' >/etc/apt/keyrings/apt-charliek.gpg"
	mount_args=()
	;;
esac

probe_lines=""
for p in "${pkgs[@]}"; do
	probe_lines+="echo '== apt-cache policy $p ==' && apt-cache policy '$p' && "
done

container_script=$(
	cat <<EOF
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq --no-install-recommends ca-certificates curl gnupg >/dev/null
mkdir -p /etc/apt/keyrings
$keyring_setup
echo '$src_line' >/etc/apt/sources.list.d/apt-charliek.list
echo '== sources.list.d/apt-charliek.list =='
cat /etc/apt/sources.list.d/apt-charliek.list
echo '== apt update =='
apt-get update
${probe_lines}true
echo '== verify.sh: smoke test passed =='
EOF
)

echo "==> running smoke test in ubuntu:noble (mode=$mode)"
docker run --rm "${mount_args[@]}" ubuntu:noble bash -c "$container_script"
