import { test } from "node:test";
import assert from "node:assert/strict";
import { missingFolderError } from "./folder.js";

test("a missing working folder is reported as such, not as a binary that failed to launch", () => {
  assert.deepEqual(missingFolderError("/gone", () => false),
    { type: "error", message: "This agent's folder no longer exists: /gone", missingFolder: "/gone" });
  assert.equal(missingFolderError("/here", () => true), undefined);
  assert.equal(missingFolderError(process.cwd()), undefined);
});
