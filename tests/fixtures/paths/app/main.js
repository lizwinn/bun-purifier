import isPlainObj from "is-plain-obj";
import packed from "packed";
import shared from "shared";
import vendored from "vendored";

console.log(`${shared} ${vendored} ${packed} plain:${isPlainObj({})}`);
