import isPlainObj from "is-plain-obj";
import ms from "ms";

console.log(`plain object: ${isPlainObj({})}, one day: ${ms("1d")} ms`);
