import is from "@sindresorhus/is";
import kleur from "kleur";

kleur.enabled = false;
console.log(kleur.green(`number: ${is.number(1)}`));
