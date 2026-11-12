import { test } from "node:test";
import assert from "node:assert/strict";
import { modes, parseMode, preToolDecision } from "./permissions.js";

const cwd = "/repo";
const rules = [{ kind: "bash" as const, value: "npm test" }, { kind: "edits" as const, value: "/repo" }];

test("only the offered modes pass; anything else is Ask", () => {
  assert.deepEqual([...modes], ["default", "auto", "acceptEdits", "plan"]);
  for (const mode of modes) assert.equal(parseMode(mode), mode);
  for (const other of ["bypassPermissions", "dontAsk", undefined, 3, ""]) assert.equal(parseMode(other), "default");
});

test("send_to_agent and complete_reminder are asked of the user in every mode", () => {
  for (const mode of modes) {
    assert.deepEqual(preToolDecision("mcp__worktime__send_to_agent", { text: "x" }, cwd, rules, mode), { kind: "ask" }, mode);
    assert.deepEqual(preToolDecision("mcp__worktime__complete_reminder", { id: "x" }, cwd, rules, mode), { kind: "ask" }, mode);
  }
});

test("the read-only list and saved rules apply first in every mode but Plan, which keeps only the read-only list", () => {
  for (const mode of modes) {
    assert.deepEqual(preToolDecision("Read", {}, cwd, [], mode), { kind: "allow" }, mode);
    assert.deepEqual(preToolDecision("mcp__worktime__jira_issue", {}, cwd, [], mode), { kind: "allow" }, mode);
    assert.deepEqual(preToolDecision("Bash", { command: "git log -3" }, cwd, [], mode), { kind: "allow", readOnly: true }, mode);
  }
  for (const mode of ["default", "auto", "acceptEdits"] as const) {
    assert.deepEqual(preToolDecision("Bash", { command: "npm test" }, cwd, rules, mode), { kind: "allow", rule: "npm test" }, mode);
    assert.deepEqual(preToolDecision("Edit", { file_path: "/repo/a.ts" }, cwd, rules, mode), { kind: "allow", rule: "/repo" }, mode);
  }
  assert.deepEqual(preToolDecision("Bash", { command: "npm test" }, cwd, rules, "plan"), { kind: "defer" });
  assert.deepEqual(preToolDecision("Edit", { file_path: "/repo/a.ts" }, cwd, rules, "plan"), { kind: "defer" });
});

test("the rest is left to the mode: canUseTool asks in Ask, the classifier decides first in Auto", () => {
  for (const mode of modes) {
    assert.deepEqual(preToolDecision("Bash", { command: "rm -rf build" }, cwd, rules, mode), { kind: "defer" }, mode);
    assert.deepEqual(preToolDecision("Write", { file_path: "/elsewhere/x" }, cwd, rules, mode), { kind: "defer" }, mode);
  }
});

test("an assistant's allowlist refuses unlisted MCP tools in every mode and leaves the other tools to the mode", () => {
  const allowed = ["mcp__worktime__time_report", "mcp__worktime__jira_issue"];
  for (const mode of modes) {
    assert.equal(preToolDecision("mcp__worktime__slack_thread", {}, cwd, rules, mode, allowed).kind, "deny", mode);
    assert.equal(preToolDecision("mcp__worktime__send_to_agent", {}, cwd, rules, mode, allowed).kind, "deny", mode);
    assert.equal(preToolDecision("mcp__worktime__complete_reminder", {}, cwd, rules, mode, allowed).kind, "deny", mode);
    assert.equal(preToolDecision("mcp__other__thing", {}, cwd, rules, mode, allowed).kind, "deny", mode);
    assert.deepEqual(preToolDecision("mcp__worktime__time_report", {}, cwd, [], mode, allowed), { kind: "allow" }, mode);
    assert.deepEqual(preToolDecision("Read", {}, cwd, [], mode, allowed), { kind: "allow" }, mode);
    for (const tool of ["notify", "scheduled_notifications", "cancel_notification", "add_reminder"]) {
      assert.deepEqual(preToolDecision(`mcp__worktime__${tool}`, {}, cwd, [], mode, allowed), { kind: "allow" }, `${tool} ${mode}`);
      assert.deepEqual(preToolDecision(`mcp__worktime__${tool}`, {}, cwd, [], mode), { kind: "allow" }, `${tool} ${mode}`);
    }
    assert.deepEqual(preToolDecision("Bash", { command: "rm -rf build" }, cwd, [], mode, allowed), { kind: "defer" }, mode);
  }
  assert.deepEqual(preToolDecision("mcp__worktime__send_to_agent", {}, cwd, [], "default", ["mcp__worktime__send_to_agent"]), { kind: "ask" });
  assert.equal(preToolDecision("mcp__worktime__slack_thread", {}, cwd, [], "default", []).kind, "deny");
});

test("without an allowlist every MCP tool is decided as before", () => {
  assert.deepEqual(preToolDecision("mcp__worktime__slack_thread", {}, cwd, [], "default"), { kind: "allow" });
});

test("Claude in Chrome is not touched by the allowlist", () => {
  assert.notEqual(preToolDecision("mcp__claude-in-chrome__navigate", {}, cwd, [], "default", []).kind, "deny");
});
