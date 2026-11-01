import kleur from "kleur";
import ms from "ms";

kleur.enabled = false;
console.log(kleur.bold(`built from a lockfile outside its source, ${ms("1m")} ms`));
