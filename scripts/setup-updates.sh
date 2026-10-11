#!/bin/bash
# One-time setup for auto-update: creates the EdDSA signing key in your login Keychain and writes the
# public half into project.yml. Back the private key up (generate_keys -x file); losing it means
# existing installs can never verify another update.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN=$(find build/SourcePackages/artifacts -path "*Sparkle/bin" -type d | head -1)
[ -n "$BIN" ] || { echo "Build the project once first so Sparkle's tools are fetched."; exit 1; }
"$BIN/generate_keys" >/dev/null
PUBLIC=$("$BIN/generate_keys" -p)
sed -i '' -E "s|SUPublicEDKey: .*|SUPublicEDKey: $PUBLIC|" project.yml
echo "Public key $PUBLIC written to project.yml."
