import { test } from "node:test";
import assert from "node:assert/strict";
import { modes, preToolDecision } from "./permissions.js";
import { delegateRule, hasDelegateRules, matchDelegate, matchRules, parseRules, suggestRules, type Rule } from "./rules.js";

const tool = "mcp__worktime__send_to_agent";
const rule = delegateRule("work", "assistant:work:reviewer");
const rules: Rule[] = [{ kind: "delegate", value: rule }];

test("a delegate rule matches Main of that workspace and that resolved target only", () => {
  assert.equal(matchDelegate(rules, "work", "assistant:work:reviewer"), rule);
  assert.equal(matchDelegate(rules, "work", "assistant:work:developer"), undefined, "another target");
  assert.equal(matchDelegate(rules, "personal", "assistant:work:reviewer"), undefined, "another workspace");
  assert.equal(matchDelegate(rules, "work", undefined), undefined, "ambiguous or unresolved");
  assert.equal(matchDelegate(rules, undefined, "assistant:work:reviewer"), undefined, "not a Main");
  assert.equal(matchDelegate(rules, "work", "Review"), undefined, "never free text");
  assert.equal(hasDelegateRules(rules, "work"), true);
  assert.equal(hasDelegateRules(rules, "personal"), false);
  assert.equal(hasDelegateRules(rules, undefined), false);
});

test("delegate rules are parsed, never offered and never matched as a tool or command", () => {
  assert.deepEqual(parseRules([{ kind: "delegate", value: rule }]), rules);
  assert.deepEqual(suggestRules(tool, { agent: "Reviewer" }, "/repo"), []);
  assert.equal(matchRules([{ kind: "tool", value: tool }, ...rules], tool, { agent: "Reviewer" }, "/repo"), undefined);
});

test("send_to_agent runs without asking only with a delegate rule, in every mode, marked as a rule", () => {
  for (const mode of modes) {
    assert.deepEqual(preToolDecision(tool, { text: "x" }, "/repo", rules, mode, undefined, rule), { kind: "allow", rule }, mode);
    assert.deepEqual(preToolDecision(tool, { text: "x" }, "/repo", rules, mode, undefined, undefined), { kind: "ask" }, mode);
  }
  assert.equal(preToolDecision(tool, {}, "/repo", rules, "default", ["mcp__worktime__time_report"], rule).kind, "deny", "an assistant's allowlist still applies");
});
