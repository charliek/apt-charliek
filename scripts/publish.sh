#!/usr/bin/env bash
# publish.sh — generate apt repo metadata, sign it, upload to GCS.
#
# Pipeline:
#   1. Set up an isolated GPG keyring; import APT_SIGNING_KEY (or, in
#      FIXTURE_MODE, generate an ephemeral test key).
#   2. (real mode) rsync gs://$BUCKET/pool → ./pool, then expect the caller
#      to have run scripts/collect-debs.sh to add new debs.
#   3. For each architecture: apt-ftparchive packages → Packages, gzip.
#   4. apt-ftparchive release → Release.
#   5. gpg --clearsign → InRelease;  gpg --detach-sign --armor → Release.gpg.
#   6. Export pubkey to ./pubkey.gpg (binary) and ./pubkey.asc (armored).
#   7. (real mode) Upload pool/ first (additive), then dists/ (atomic flip
#      with InRelease last), set Cache-Control: no-cache on dists/*.
#
# Inputs (env):
#   BUCKET                gs:// URL. Default gs://apt.stridelabs.ai.
#   APT_SIGNING_KEY       Armored secret key. Required unless FIXTURE_MODE=1.
#   APT_SIGNING_KEY_FPR   Fingerprint. Required unless FIXTURE_MODE=1.
#   FIXTURE_MODE          "1" to skip GCS sync/upload and use an ephemeral key.
#   PACKAGES_FILE         Default ./packages.yaml.

set -euo pipefail

BUCKET="${BUCKET:-gs://apt.stridelabs.ai}"
PACKAGES_FILE="${PACKAGES_FILE:-packages.yaml}"
FIXTURE_MODE="${FIXTURE_MODE:-0}"

require() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "error: required command '$1' not found on PATH" >&2
		exit 1
	}
}
require apt-ftparchive
require gpg
require yq
require gzip
if [ "$FIXTURE_MODE" != "1" ]; then
	require gcloud
fi

if [ ! -f "$PACKAGES_FILE" ]; then
	echo "error: $PACKAGES_FILE not found" >&2
	exit 1
fi

suite=$(yq -r '.suite // "noble"' "$PACKAGES_FILE")
component=$(yq -r '.component // "main"' "$PACKAGES_FILE")
mapfile -t arches < <(yq -r '.architectures[]' "$PACKAGES_FILE")
[ "${#arches[@]}" -gt 0 ] || arches=(amd64 arm64)

# ---- 1. GPG keyring setup -------------------------------------------------

GNUPGHOME=$(mktemp -d)
export GNUPGHOME
chmod 700 "$GNUPGHOME"
trap 'rm -rf "$GNUPGHOME"' EXIT

if [ "$FIXTURE_MODE" = "1" ]; then
	echo "==> FIXTURE_MODE: generating ephemeral signing key"
	gpg --batch --quick-generate-key \
		'apt-charliek fixture <fixture@example.invalid>' \
		ed25519 sign 0 >/dev/null 2>&1
	APT_SIGNING_KEY_FPR=$(gpg --list-secret-keys --with-colons |
		awk -F: '/^fpr:/ { print $10; exit }')
	echo "    fixture fingerprint: $APT_SIGNING_KEY_FPR"
else
	if [ -z "${APT_SIGNING_KEY:-}" ] || [ -z "${APT_SIGNING_KEY_FPR:-}" ]; then
		echo "error: APT_SIGNING_KEY and APT_SIGNING_KEY_FPR must be set" >&2
		exit 1
	fi
	echo "==> importing signing key (fpr: $APT_SIGNING_KEY_FPR)"
	echo "$APT_SIGNING_KEY" | gpg --batch --import 2>/dev/null
fi

# ---- 2. Sync existing pool from GCS ---------------------------------------

mkdir -p pool/main

if [ "$FIXTURE_MODE" != "1" ]; then
	echo "==> rsync $BUCKET/pool → ./pool"
	if gcloud storage ls "$BUCKET/pool/" >/dev/null 2>&1; then
		gcloud storage rsync --recursive "$BUCKET/pool" ./pool
	else
		echo "    (no pool/ in bucket yet — first publish)"
	fi
fi

# ---- 3. Generate Packages files per architecture --------------------------

dist_root="dists/$suite/$component"
rm -rf "dists/$suite"
for arch in "${arches[@]}"; do
	bin_dir="$dist_root/binary-$arch"
	mkdir -p "$bin_dir"
	echo "==> apt-ftparchive packages --arch $arch"
	apt-ftparchive --arch "$arch" packages pool/"$component" \
		>"$bin_dir/Packages"
	gzip -kf "$bin_dir/Packages"
	echo "    $(wc -l <"$bin_dir/Packages") Packages lines, $(wc -c <"$bin_dir/Packages.gz") bytes gzipped"
done

# ---- 4. Generate Release ---------------------------------------------------

echo "==> apt-ftparchive release"
(
	cd "dists/$suite"
	apt-ftparchive -c "../../apt-ftparchive.conf" release . >Release
)

# ---- 5. Sign InRelease + Release.gpg --------------------------------------

echo "==> gpg --clearsign InRelease"
gpg --batch --yes --pinentry-mode loopback \
	--default-key "$APT_SIGNING_KEY_FPR" \
	--output "dists/$suite/InRelease" \
	--clearsign "dists/$suite/Release"

echo "==> gpg --detach-sign Release.gpg"
gpg --batch --yes --pinentry-mode loopback \
	--default-key "$APT_SIGNING_KEY_FPR" \
	--output "dists/$suite/Release.gpg" \
	--detach-sign --armor "dists/$suite/Release"

# ---- 6. Export pubkey -----------------------------------------------------

echo "==> exporting pubkey"
gpg --armor --export "$APT_SIGNING_KEY_FPR" >./pubkey.asc
gpg --export "$APT_SIGNING_KEY_FPR" >./pubkey.gpg

# ---- 7. Upload to GCS (skipped in fixture mode) ---------------------------

if [ "$FIXTURE_MODE" = "1" ]; then
	echo "==> FIXTURE_MODE: skipping GCS upload"
	echo "==> done. inspect dists/$suite/ and pubkey.gpg locally."
	exit 0
fi

echo "==> uploading pool/ to $BUCKET (additive first)"
gcloud storage rsync --recursive ./pool "$BUCKET/pool"

echo "==> uploading pubkey.{gpg,asc} to $BUCKET"
gcloud storage cp ./pubkey.gpg "$BUCKET/pubkey.gpg"
gcloud storage cp ./pubkey.asc "$BUCKET/pubkey.asc"

echo "==> uploading dists/ to $BUCKET (atomic flip; InRelease last)"
# Upload Packages files first
for arch in "${arches[@]}"; do
	gcloud storage cp "$dist_root/binary-$arch/Packages" \
		"$BUCKET/$dist_root/binary-$arch/Packages"
	gcloud storage cp "$dist_root/binary-$arch/Packages.gz" \
		"$BUCKET/$dist_root/binary-$arch/Packages.gz"
done
# Then Release + Release.gpg
gcloud storage cp "dists/$suite/Release" "$BUCKET/dists/$suite/Release"
gcloud storage cp "dists/$suite/Release.gpg" "$BUCKET/dists/$suite/Release.gpg"
# Finally InRelease — apt fetches this first, so flip it last
gcloud storage cp "dists/$suite/InRelease" "$BUCKET/dists/$suite/InRelease"

echo "==> stamping Cache-Control: no-cache on dists/* (belt-and-suspenders for Cloudflare)"
gcloud storage objects update --cache-control="no-cache" \
	"$BUCKET/dists/**" >/dev/null

echo "==> done. published $suite at $BUCKET"
