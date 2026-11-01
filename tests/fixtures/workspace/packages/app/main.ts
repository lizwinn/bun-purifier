#!/usr/bin/env bun
import kleur from "kleur";
import isOddNumber from "@fixture/lib";

console.log(kleur.green(`3 is odd: ${isOddNumber(3)}`));
