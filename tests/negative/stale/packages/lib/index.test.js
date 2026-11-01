import { expect, test } from "bun:test";
import isOddNumber from "./index.js";

test("odd numbers", () => {
  expect(isOddNumber(3)).toBe(true);
  expect(isOddNumber(4)).toBe(false);
});
