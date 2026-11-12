import assert from "node:assert/strict";
import { test } from "node:test";
import { contextWindow, hookMessage, reportedContext, usageContext } from "./workmap.js";

test("a hook run is forwarded with its phase", () => {
  const started = { type: "system", subtype: "hook_started", hook_id: "h1", hook_name: "PostToolUse:Edit", hook_event: "PostToolUse" };
  assert.deepEqual(hookMessage(started), { type: "hook", id: "h1", name: "PostToolUse:Edit", event: "PostToolUse", phase: "started" });
  assert.deepEqual(hookMessage({ ...started, subtype: "hook_response", outcome: "error" }),
    { type: "hook", id: "h1", name: "PostToolUse:Edit", event: "PostToolUse", phase: "ended", isError: true });
});

test("the app's own permission hook and other system messages are not hook runs", () => {
  assert.equal(hookMessage({ type: "system", subtype: "hook_started", hook_id: "h1", hook_name: "PreToolUse:Bash", hook_event: "PreToolUse" }), undefined);
  assert.equal(hookMessage({ type: "system", subtype: "init" }), undefined);
  assert.equal(hookMessage({ type: "system", subtype: "hook_progress", hook_id: "h1", hook_event: "Stop" }), undefined);
});

test("the reported context gives tokens, window and percent", () => {
  assert.deepEqual(reportedContext({ totalTokens: 20_000, maxTokens: 200_000, percentage: 10 }), { type: "context", tokens: 20_000, max: 200_000, percent: 10 });
  assert.equal(reportedContext({ totalTokens: 5 }), undefined);
});

test("a turn's usage counts input, cache and output tokens", () => {
  const usage = { input_tokens: 10, cache_read_input_tokens: 15_000, cache_creation_input_tokens: 4_000, output_tokens: 990 };
  assert.deepEqual(usageContext(usage, 200_000), { type: "context", tokens: 20_000, max: 200_000, percent: 10 });
  assert.deepEqual(usageContext(usage, undefined), { type: "context", tokens: 20_000 });
  assert.equal(usageContext({}, 200_000), undefined);
  assert.equal(usageContext(undefined, 200_000), undefined);
});

test("the context window comes from the result's model usage", () => {
  assert.equal(contextWindow({ a: { contextWindow: 200_000 }, b: { contextWindow: 1_000_000 } }), 1_000_000);
  assert.equal(contextWindow({}), undefined);
  assert.equal(contextWindow(undefined), undefined);
});
