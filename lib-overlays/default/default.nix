# SPDX-License-Identifier: MIT
#
# The `bun-purifier` library namespace. It holds nothing: the builder
# needs a package set, so it is the package `buildBunProject` that the
# default package overlay adds.
{ ... }:
{

  overlay = final: prev: {
    bun-purifier = prev.bun-purifier or { };
  };

}
