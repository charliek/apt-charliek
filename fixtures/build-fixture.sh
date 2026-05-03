#!/usr/bin/env bash
# build-fixture.sh — regenerate fixtures/hello_0.0.1_amd64.deb.
#
# Produces a tiny no-op deb used by ci.yml's fixture publish path. The deb
# itself is committed to the repo so CI doesn't need nfpm; this script is
# only for regenerating the fixture if its contents ever need to change.
#
# Requires nfpm on PATH:
#   - macOS:   brew install goreleaser/tap/nfpm
#   - Linux:   curl -sfL https://nfpm.goreleaser.com/install.sh | sh -s -- -b ~/.local/bin
#   - Go:      go install github.com/goreleaser/nfpm/v2/cmd/nfpm@latest
#
# Output: fixtures/hello_0.0.1_amd64.deb (overwrites if present).

set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v nfpm >/dev/null 2>&1; then
	cat >&2 <<'EOF'
error: nfpm not found on PATH. Install via one of:
  brew install goreleaser/tap/nfpm        # macOS
  go install github.com/goreleaser/nfpm/v2/cmd/nfpm@latest
  curl -sfL https://nfpm.goreleaser.com/install.sh | sh -s -- -b ~/.local/bin
EOF
	exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat >"$work/hello.sh" <<'EOF'
#!/bin/sh
echo "hello from apt-charliek fixture"
EOF
chmod +x "$work/hello.sh"

cat >"$work/nfpm.yaml" <<EOF
name: hello
arch: amd64
version: "0.0.1"
maintainer: "apt-charliek fixtures <fixtures@example.invalid>"
description: |
  Tiny no-op package used by apt-charliek's CI fixture publish path. Not for
  real installation. Regenerated from fixtures/build-fixture.sh.
license: MIT
section: misc
priority: optional
contents:
  - src: $work/hello.sh
    dst: /usr/bin/hello
EOF

mkdir -p fixtures
nfpm pkg --config "$work/nfpm.yaml" --packager deb \
	--target fixtures/hello_0.0.1_amd64.deb

echo "==> wrote fixtures/hello_0.0.1_amd64.deb"
ls -l fixtures/hello_0.0.1_amd64.deb
