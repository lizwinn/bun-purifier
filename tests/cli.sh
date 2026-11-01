#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# The checks of the bun-purifier command that need the network or Nix
# itself, which a sandboxed check has neither of. CI runs this from the
# repository root after `nix flake check`.
#
#   1. The lock run: relocking every fixture with --force writes the
#      lockfile it already has, byte for byte, and so does relocking
#      elysia (a real project, at the commit tests/dependencies pins) from
#      a fresh checkout.
#   2. The interactive install: `install` sets up the workspace fixture
#      from its lock, twice, and the app then builds and runs.
#   3. The everyday loop: after `bun add`, `install` refuses the stale
#      lock and names `bun-purifier lock`; after the lock, it installs.
#      A lockfile edited by hand is refused the same way.
#   4. Publishing: `publish` sends the tarball Nix packed to a registry
#      that records it.
set -euo pipefail

# Runs a command that must fail, and checks that its error output names
# `expected`.
fails_with() {
  local expected=$1
  shift
  if "$@" 2> "$work/err"; then
    echo "succeeded, but should have failed: $*"
    exit 1
  fi
  if ! grep -F -- "$expected" "$work/err" > /dev/null; then
    echo "the error of $* does not say: $expected"
    cat "$work/err"
    exit 1
  fi
}

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

elysia_rev=$("$jq" -r .nodes.elysia.locked.rev tests/dependencies/flake.lock)
git clone --quiet https://github.com/elysiajs/elysia "$work/elysia"
git -C "$work/elysia" checkout --quiet "$elysia_rev"
start=$(date +%s)
(cd "$work/elysia" && "$cli" lock)
echo "elysia relocked in $(($(date +%s) - start)) s"
cmp "$work/elysia/bun-purifier.lock.json" tests/real-world/elysia/bun-purifier.lock.json

echo "== interactive install"
cp -r tests/fixtures/workspace "$work/workspace"
(cd "$work/workspace" && "$cli" install && "$cli" install)
(cd "$work/workspace/packages/app" && "$bun" run build)
actual=$("$bun" "$work/workspace/packages/app/dist/main.js")
if [ "$actual" != "3 is odd: true" ]; then
  echo "the app printed: $actual"
  exit 1
fi

echo "== everyday loop"
cp -r tests/fixtures/workspace "$work/loop"
(cd "$work/loop/packages/lib" && "$bun" add ms@2.1.3)
(cd "$work/loop" && fails_with 'Run `bun-purifier lock`' "$cli" install)
(cd "$work/loop" && "$cli" lock && "$cli" install)
grep -F '"url": "https://registry.npmjs.org/ms/-/ms-2.1.3.tgz"' "$work/loop/bun-purifier.lock.json" > /dev/null
sed -i 's/"hash": "sha512-W/"hash": "sha512-X/' "$work/loop/bun-purifier.lock.json"
(cd "$work/loop" && fails_with 'bun-purifier lock --force' "$cli" install)

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
