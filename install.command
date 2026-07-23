#!/usr/bin/env bash
# install.command — one-click launcher for the fresh-install setup.
#
# Downloads the current fresh-install.sh, Brewfile, and macos-defaults.sh
# straight from the repo and runs them. This file is intentionally generic —
# it never needs to be re-bundled when those three files change.

set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/ty-mer/mac-setup/main"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "=== Fresh install ==="
echo "Fetching setup files..."

curl -fsSL "$REPO_RAW/fresh-install.sh" -o "$WORKDIR/fresh-install.sh"
curl -fsSL "$REPO_RAW/Brewfile" -o "$WORKDIR/Brewfile"
curl -fsSL "$REPO_RAW/macos-defaults.sh" -o "$WORKDIR/macos-defaults.sh"
chmod +x "$WORKDIR/fresh-install.sh" "$WORKDIR/macos-defaults.sh"

cd "$WORKDIR"
./fresh-install.sh

echo
read -r -p "Setup finished. Press Return to close this window..." _
