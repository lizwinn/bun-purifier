#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# The checks that need the network or Nix itself, which a sandboxed check
# has neither of. CI runs them from the repository root, each section as a
# job or a step; with no arguments, every section runs.
#
#   relock            relocking every fixture and elysia (a real project, at
#                     the commit tests/dependencies pins) writes the
#                     lockfile it already has, byte for byte
#                     (conformance-relock)
#   offline-prefetch  `bun-purifier prefetch` in a copy of the workspace
#                     fixture under $OFFLINE_DIR
#   offline-loop      the everyday loop in that copy, which CI runs with
#                     the network cut: `bun install`, `bun run build`, the
#                     app and `bun test` (conformance-offline)
#   loop              after `bun add`, `prefetch` refuses the stale lock
#                     and names `bun-purifier lock`; after the lock it
#                     installs; a lockfile edited by hand is refused
#   publish           `publish` sends the release tarball Nix built to a
#                     registry that records it
#   nix-errors        a Nix build of a truncated lockfile names
#                     `bun-purifier lock --force` (conformance-malformed)
#   rebuild           `nix build --rebuild` of a fixture gives the same
#                     output (conformance-rebuild)
set -euo pipefail

work=$(mktemp -d)
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT
OFFLINE_DIR=${OFFLINE_DIR:-$work/offline}

cli=$(nix build --no-link --print-out-paths '.#bun-purifier')/bin/bun-purifier
bun=$(nix build --no-link --print-out-paths '.#bun-purifier.bun')/bin/bun
# Package scripts call bun by name.
PATH=$(dirname "$bun"):$PATH

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

relock() {
  for fixture in workspace sources paths/app registries; do
    (cd "tests/fixtures/$fixture" && "$cli" lock --force)
  done
  cp tests/external/bun.lock tests/external/src/
  (cd tests/external/src && "$cli" lock --force --lockfile ../bun-purifier.lock.json)
  rm tests/external/src/bun.lock
  git diff --exit-code -- tests/fixtures tests/external

  local jq rev
  jq=$(nix build --no-link --print-out-paths --inputs-from . 'nixpkgs#jq.bin')/bin/jq
  rev=$("$jq" -r .nodes.elysia.locked.rev tests/dependencies/flake.lock)
  git clone --quiet https://github.com/elysiajs/elysia "$work/elysia"
  git -C "$work/elysia" checkout --quiet "$rev"
  local start
  start=$(date +%s)
  (cd "$work/elysia" && "$cli" lock)
  echo "elysia relocked in $(($(date +%s) - start)) s"
  cmp "$work/elysia/bun-purifier.lock.json" tests/real-world/elysia/bun-purifier.lock.json
}

offline_prefetch() {
  rm -rf "$OFFLINE_DIR"
  cp -r tests/fixtures/workspace "$OFFLINE_DIR"
  (cd "$OFFLINE_DIR" && "$cli" prefetch)
}

offline_loop() {
  (cd "$OFFLINE_DIR" && "$bun" install)
  (cd "$OFFLINE_DIR/packages/app" && "$bun" run build)
  local actual
  actual=$("$bun" "$OFFLINE_DIR/packages/app/dist/main.js")
  if [ "$actual" != "3 is odd: true" ]; then
    echo "the app printed: $actual"
    exit 1
  fi
  (cd "$OFFLINE_DIR/packages/lib" && "$bun" test)
}

loop() {
  cp -r tests/fixtures/workspace "$work/loop"
  (cd "$work/loop" && "$cli" prefetch && "$cli" prefetch)
  (cd "$work/loop/packages/lib" && "$bun" add ms@2.1.3)
  (cd "$work/loop" && fails_with 'Run `bun-purifier lock`' "$cli" prefetch)
  (cd "$work/loop" && "$cli" lock && "$cli" prefetch)
  grep -F '"url": "https://registry.npmjs.org/ms/-/ms-2.1.3.tgz"' "$work/loop/bun-purifier.lock.json" > /dev/null
  sed -i 's/"hash": "sha512-W/"hash": "sha512-X/' "$work/loop/bun-purifier.lock.json"
  (cd "$work/loop" && fails_with 'bun-purifier lock --force' "$cli" prefetch)
}

publish() {
  cp -r tests/fixtures/workspace "$work/publish"
  "$bun" tests/registry.ts 4873 "$work/request.json" &
  for _ in $(seq 50); do
    (exec 3<>/dev/tcp/127.0.0.1/4873) 2>/dev/null && break
    sleep 0.1
  done
  (cd "$work/publish/packages/app" &&
    env NPM_CONFIG_TOKEN=test "$cli" publish --registry http://127.0.0.1:4873/)
  wait
  local jq lib nixpkgs expected
  jq=$(nix build --no-link --print-out-paths --inputs-from . 'nixpkgs#jq.bin')/bin/jq
  lib=$(dirname "$cli")/../share/bun-purifier/nix/lib
  nixpkgs=$(grep -o "BUN_PURIFIER_NIXPKGS='[^']*'" "$cli" | cut -d"'" -f2)
  expected=$(nix build --no-link --print-out-paths --file "$lib/interactive.nix" \
    --argstr nixpkgs "$nixpkgs" --argstr src "$work/publish" \
    --argstr lockFile "$work/publish/bun-purifier.lock.json" --argstr package fixture-app release)
  "$jq" -r '._attachments[].data' "$work/request.json" | base64 -d > "$work/sent.tgz"
  cmp "$work/sent.tgz" "$expected"/*.tgz
}

nix_errors() {
  local lib nixpkgs
  lib=$(dirname "$cli")/../share/bun-purifier/nix/lib
  nixpkgs=$(grep -o "BUN_PURIFIER_NIXPKGS='[^']*'" "$cli" | cut -d"'" -f2)
  fails_with 'not valid JSON. Run `bun-purifier lock --force`' \
    nix build --no-link --file "$lib/interactive.nix" --argstr nixpkgs "$nixpkgs" \
    --argstr lockFile "$PWD/tests/negative/malformed/bun-purifier.lock.json" cache
}

rebuild() {
  local check
  check=".#checks.$(uname -m)-linux.workspace-project"
  nix build --no-link "$check"
  nix build --no-link --rebuild "$check"
}

sections=("$@")
[ ${#sections[@]} -gt 0 ] || sections=(relock offline-prefetch offline-loop loop publish nix-errors rebuild)
for section in "${sections[@]}"; do
  echo "== $section"
  "${section//-/_}"
done
echo "== passed: ${sections[*]}"
