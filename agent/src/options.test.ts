import { test } from "node:test";
import assert from "node:assert/strict";
import { mcpServers, sessionOptions } from "./options.js";

test("an imported session is forked on resume, so its transcript is never appended to", () => {
  const forked = sessionOptions({ cwd: "/repo", sessionId: "s", forkSession: true }, "m", "default");
  assert.equal(forked.resume, "s");
  assert.equal(forked.forkSession, true);
  assert.equal(sessionOptions({ cwd: "/repo", sessionId: "s" }, "m", "default").forkSession, undefined);
  assert.equal(sessionOptions({ cwd: "/repo", forkSession: true }, "m", "default").forkSession, undefined);
});

test("the MCP server gets the Main's workspace only when there is one", () => {
  assert.deepEqual(mcpServers({}), {});
  assert.deepEqual(mcpServers({ WORKTIME_MCP_COMMAND: "/app" }), { worktime: { type: "stdio", command: "/app", args: ["--mcp"] } });
  assert.deepEqual(mcpServers({ WORKTIME_MCP_COMMAND: "/app", WORKTIME_WORKSPACE: "personal" }).worktime,
    { type: "stdio", command: "/app", args: ["--mcp"], env: { WORKTIME_WORKSPACE: "personal" } });
  assert.deepEqual(mcpServers({ WORKTIME_MCP_COMMAND: "/app", WORKTIME_WORKSPACE: "work", WORKTIME_AGENT: "topic:abc" }).worktime,
    { type: "stdio", command: "/app", args: ["--mcp"], env: { WORKTIME_WORKSPACE: "work", WORKTIME_AGENT: "topic:abc" } });
});
