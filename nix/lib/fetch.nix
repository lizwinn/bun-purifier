# SPDX-License-Identifier: MIT
#
# The fetcher for the archives of a bun-purifier lock. An archive entry is
# `{ path, archive = { url, mirrors, stripTop }, hash }`; this fetches the
# archive file from `url`, or from a URL of `mirrors` when `url` fails, and
# cache.nix unpacks it.
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
# { name, urls, hash }, as nixpkgs' fetchurl takes them, and is the place
# for credentials (nixpkgs' fetchurl takes `netrcPhase`) or more mirrors.
{
  lock,
  fetchurl ? null,
}:
artifact:
let
  name = lock.artifactName artifact + ".tgz";
  inherit (artifact.archive) url;
  urls = [ url ] ++ artifact.archive.mirrors;
in
if fetchurl != null then
  fetchurl {
    inherit name urls;
    inherit (artifact) hash;
  }
else
  derivation {
    inherit name url urls;
    builder = "builtin:fetchurl";
    system = "builtin";
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
