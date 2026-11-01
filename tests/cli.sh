#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# The checks of the bun-purifier command that need the network or Nix
# itself, which a sandboxed check has neither of. CI runs this from the
# repository root after `nix flake check`.
#
#   1. The lock run: relocking every fixture with --force writes the
#      lockfile it already has.
#   2. The interactive install: `install` sets up the workspace fixture
#      from its lock, twice, and the app then builds and runs.
#   3. Publishing: `publish` sends the tarball Nix packed to a registry
#      that records it.
set -euo pipefail

cli=$(nix build --no-link --print-out-paths '.#bun-purifier')/bin/bun-purifier
bun=$(nix build --no-link --print-out-paths '.#bun-purifier.bun')/bin/bun
jq=$(nix build --no-link --print-out-paths --inputs-from . 'nixpkgs#jq.bin')/bin/jq
# Package scripts call bun by name.
PATH=$(dirname "$bun"):$PATH
work=$(mktemp -d)
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT

echo "== lock run"
for fixture in workspace sources paths/app registries; do
  (cd "tests/fixtures/$fixture" && "$cli" lock --force)
done
git diff --exit-code -- tests/fixtures

echo "== interactive install"
cp -r tests/fixtures/workspace "$work/workspace"
(cd "$work/workspace" && "$cli" install && "$cli" install)
(cd "$work/workspace/packages/app" && "$bun" run build)
actual=$("$bun" "$work/workspace/packages/app/dist/main.js")
if [ "$actual" != "3 is odd: true" ]; then
  echo "the app printed: $actual"
  exit 1
fi

echo "== publish"
"$bun" tests/registry.ts 4873 "$work/request.json" &
for _ in $(seq 50); do
  (exec 3<>/dev/tcp/127.0.0.1/4873) 2>/dev/null && break
  sleep 0.1
done
(cd "$work/workspace/packages/app" &&
  env NPM_CONFIG_TOKEN=test "$cli" publish --registry http://127.0.0.1:4873/)
wait
expected=$(nix build --no-link --print-out-paths --file "$(nix build --no-link --print-out-paths '.#bun-purifier')/share/bun-purifier/nix/lib/interactive.nix" \
  --argstr nixpkgs "$(grep -o "BUN_PURIFIER_NIXPKGS='[^']*'" "$cli" | cut -d"'" -f2)" \
  --argstr src "$work/workspace" --argstr package fixture-app package)
"$jq" -r '._attachments[].data' "$work/request.json" | base64 -d > "$work/sent.tgz"
cmp "$work/sent.tgz" "$expected"/*.tgz

echo "== all CLI checks passed"
