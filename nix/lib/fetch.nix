# SPDX-License-Identifier: MIT
#
# The fetcher for locked artifacts. Every artifact of a bun-purifier lock
# is an archive entry, `{ path, archive = { url, stripTop }, hash }`; this
# fetches the archive file, and cache.nix unpacks it.
#
# By default each archive is a fixed-output derivation on Nix's built-in
# fetcher (the same derivation <nix/fetchurl.nix> makes), so neither the
# interactive mode nor a sandboxed build needs nixpkgs to download. A
# fixed-output store path depends only on its name and hash, so the
# default fetcher and nixpkgs' fetchurl produce the same paths.
#
# The hash of an artifact is the SRI integrity hash from bun.lock, mostly
# SHA-512.
#
# `fetchurl`, when given, replaces the built-in fetcher. It is called with
# { name, url, hash } and is the place for credentials (nixpkgs' fetchurl
# takes `netrcPhase`) or mirrors.
{
  lock,
  fetchurl ? null,
}:
artifact:
let
  name = lock.artifactName artifact + ".tgz";
  inherit (artifact.archive) url;
in
if fetchurl != null then
  fetchurl {
    inherit name url;
    inherit (artifact) hash;
  }
else
  derivation {
    inherit name url;
    builder = "builtin:fetchurl";
    system = "builtin";
    urls = [ url ];
    outputHash = artifact.hash;
    outputHashMode = "flat";
    unpack = false;
    executable = false;
    preferLocalBuild = true;
    impureEnvVars = [
      "http_proxy"
      "https_proxy"
      "ftp_proxy"
      "all_proxy"
      "no_proxy"
    ];
  }
