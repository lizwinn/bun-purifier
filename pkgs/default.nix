# SPDX-License-Identifier: MIT
{ callPackage, ... }:
{
  # The bun-purifier command: `lock`, `install` and `publish`.
  bun-purifier = callPackage ./bun-purifier { };
}
