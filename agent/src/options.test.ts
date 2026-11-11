import { test } from "node:test";
import assert from "node:assert/strict";
import { sessionOptions } from "./options.js";

test("an imported session is forked on resume, so its transcript is never appended to", () => {
  const forked = sessionOptions({ cwd: "/repo", sessionId: "s", forkSession: true }, "m", "default");
  assert.equal(forked.resume, "s");
  assert.equal(forked.forkSession, true);
  assert.equal(sessionOptions({ cwd: "/repo", sessionId: "s" }, "m", "default").forkSession, undefined);
  assert.equal(sessionOptions({ cwd: "/repo", forkSession: true }, "m", "default").forkSession, undefined);
});
