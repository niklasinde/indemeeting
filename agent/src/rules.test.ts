import { test } from "node:test";
import assert from "node:assert/strict";
import { matchRules, parseRules, prefixRule, suggestRules, type Rule } from "./rules.js";

const cwd = "/work/repo";
const bash = (...values: string[]): Rule[] => values.map((value) => ({ kind: "bash", value }));
const run = (rules: Rule[], command: string) => matchRules(rules, "Bash", { command }, cwd);

test("prefix rules take the command and its subcommand", () => {
  assert.equal(prefixRule(["git", "fetch", "-q", "origin"]), "git fetch");
  assert.equal(prefixRule(["npm", "test"]), "npm test");
  assert.equal(prefixRule(["./test.sh", "--fast"]), "./test.sh");
  assert.equal(prefixRule(["rm", "-rf", "build"]), "rm");
  assert.equal(prefixRule(["make"]), "make");
  assert.equal(prefixRule(["swift", "build", "-c", "release"]), "swift build");
  assert.equal(prefixRule(["FOO=1", "npm", "test"]), undefined);
  assert.equal(prefixRule(["$CMD", "x"]), undefined);
});

test("Always allow offers a rule for each part that is not read-only", () => {
  assert.deepEqual(suggestRules("Bash", { command: "git status && git fetch -q origin; npm test 2>&1 | tail -5" }, cwd),
    bash("git fetch", "npm test"));
  assert.deepEqual(suggestRules("Bash", { command: "./test.sh && ./test.sh --fast" }, cwd), bash("./test.sh"));
  assert.deepEqual(suggestRules("Bash", { command: "npm test > out.txt" }, cwd), [], "a line it cannot parse");
  assert.deepEqual(suggestRules("Bash", { command: "FOO=1 npm test" }, cwd), []);
  assert.deepEqual(suggestRules("Edit", { file_path: "/work/repo/Sources/a.swift" }, cwd), [{ kind: "edits", value: "/work/repo" }]);
  assert.deepEqual(suggestRules("Write", { file_path: "/tmp/x/notes.md" }, cwd), [{ kind: "edits", value: "/tmp/x" }]);
  assert.deepEqual(suggestRules("mcp__worktime__other", {}, cwd), [{ kind: "tool", value: "mcp__worktime__other" }]);
  assert.deepEqual(suggestRules("mcp__worktime__send_to_agent", { text: "x" }, cwd), []);
});

test("a Bash call is allowed only when every part that is not read-only matches a rule", () => {
  const rules = bash("git fetch", "npm test");
  assert.equal(run(rules, "git fetch -q origin main"), "git fetch");
  assert.equal(run(rules, "git status && git fetch && npm test -- --watch=false | tail"), "git fetch, npm test");
  assert.equal(run(rules, "git fetch; rm -rf /"), undefined, "one part matches, the other does not");
  assert.equal(run(rules, "npm test && npm publish"), undefined);
  assert.equal(run(rules, "git fetch | sh"), undefined);
  assert.equal(run(rules, "git fetchall"), undefined, "whole words only");
  assert.equal(run(rules, "git"), undefined);
  assert.equal(run(rules, "npm test & rm x"), undefined, "a line it cannot parse is never matched");
  assert.equal(run(rules, "npm test > /etc/hosts"), undefined);
  assert.equal(run(rules, "X=publish; npm $X"), undefined, "variables are expanded before matching");
  assert.equal(run(rules, "X=test; npm $X"), "npm test");
  assert.equal(run(bash("git"), "git push --force"), "git");
  assert.equal(run([{ kind: "tool", value: "Bash" }], "rm x"), undefined, "only bash rules match Bash");
  assert.equal(run(rules, "git status"), undefined, "nothing to match when it only reads");
});

test("edit rules cover their folder and nothing outside it", () => {
  const rules: Rule[] = [{ kind: "edits", value: "/work/repo" }];
  assert.equal(matchRules(rules, "Edit", { file_path: "/work/repo/a/b.swift" }, cwd), "/work/repo");
  assert.equal(matchRules(rules, "Write", { file_path: "a/b.swift" }, cwd), "/work/repo", "relative to the folder");
  assert.equal(matchRules(rules, "Edit", { file_path: "/work/repo/../other/x" }, cwd), undefined);
  assert.equal(matchRules(rules, "Edit", { file_path: "/work/repository/x" }, cwd), undefined);
  assert.equal(matchRules(rules, "Bash", { command: "touch /work/repo/x" }, cwd), undefined);
});

test("tool rules match the tool, never send_to_agent", () => {
  assert.equal(matchRules([{ kind: "tool", value: "mcp__x__y" }], "mcp__x__y", {}, cwd), "mcp__x__y");
  assert.equal(matchRules([{ kind: "tool", value: "mcp__x__y" }], "mcp__x__z", {}, cwd), undefined);
  const send = "mcp__worktime__send_to_agent";
  assert.equal(matchRules([{ kind: "tool", value: send }], send, {}, cwd), undefined);
});

test("rules from the app are checked", () => {
  assert.deepEqual(parseRules([{ kind: "bash", value: "npm test" }, { kind: "other", value: "x" }, { kind: "bash", value: " " }, null]),
    bash("npm test"));
  assert.deepEqual(parseRules("x"), []);
});
