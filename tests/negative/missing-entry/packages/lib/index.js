const isOdd = require("is-odd");
const is = require("@sindresorhus/is");

module.exports = (n) => is.number(n) && isOdd(n);
