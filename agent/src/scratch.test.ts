import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { nonReadOnlyParts } from "./readonly.js";
import { matchRules, suggestRules } from "./rules.js";
import { setScratchBase } from "./scratch.js";

const home = realpathSync(mkdtempSync(join(tmpdir(), "scratch-")));
const scratch = join(home, "project", "session", "scratchpad");
mkdirSync(scratch, { recursive: true });
mkdirSync(join(home, "outside"));
symlinkSync(join(home, "outside"), join(scratch, "link"));
symlinkSync(join(home, "outside", "missing"), join(scratch, "dangling"));

function withScratch(run: () => void) {
  setScratchBase(home);
  try {
    run();
  } finally {
    setScratchBase(undefined);
  }
}

test("writing inside the agent's scratchpad is allowed", () => {
  withScratch(() => {
    for (const command of [
      `S=${scratch} && mkdir -p $S && gh pr diff 2504 --repo o/r > $S/pr.diff; wc -l $S/pr.diff; gh pr view 2504 --json title; gh api repos/o/r/pulls/1/comments --jq '.[].body'`,
      `echo hi > ${scratch}/a.txt`,
      `echo hi >> ${scratch}/a.txt`,
      `echo hi >${scratch}/a.txt 2>/dev/null`,
      `mkdir -p ${scratch}/sub/dir && touch ${scratch}/sub/dir/f && cp /etc/hosts ${scratch}/sub/`,
      `mv ${scratch}/a ${scratch}/b && rm -f ${scratch}/b && rm -rf ${scratch}/sub`,
      `echo x | tee -a ${scratch}/log`,
    ]) {
      assert.deepEqual(nonReadOnlyParts(command), [], command);
    }
  });
});

test("writing anywhere else, through .. or a symlink, or without a known scratchpad asks", () => {
  withScratch(() => {
    for (const command of [
      `echo hi > ${home}/outside/a.txt`,
      "echo hi > /tmp/a.txt",
      "echo hi > a.txt",
      `echo hi > ${scratch}/../a.txt`,
      `echo hi > ${scratch}/link/a.txt`,
      `echo hi > ${scratch}/dangling`,
      `echo hi > ${scratch}/*`,
      "echo hi > ~/x",
      `mkdir -p ${home}/outside/x`,
      `mkdir -p ${scratch}/link/x`,
      `cp ${scratch}/a ${home}/outside/`,
      `mv ${scratch}/a ${home}/outside/`,
      `mv /etc/hosts ${scratch}/`,
      `rm -rf ${scratch}`,
      `rm -rf ${scratch}/link`,
      `rm -rf ${scratch}/../project`,
      `rm -rf ${scratch}/*`,
      `rm --recursive ${scratch}/x`,
      `echo hi > ${scratch}/a &`,
      `echo hi 2> ${scratch}/a`,
      "echo > ",
      `> ${scratch}/a`,
      `tee ${home}/outside/x`,
    ]) {
      assert.notDeepEqual(nonReadOnlyParts(command), [], command);
    }
  });
  assert.notDeepEqual(nonReadOnlyParts(`echo hi > ${scratch}/a.txt`), [], "no root known, nothing is scratch");
});

test("a redirect into the scratchpad is covered by the rules for the commands; one outside is not offered or matched", () => {
  withScratch(() => {
    const rules = [{ kind: "bash" as const, value: "npm test" }];
    const line = `npm test > ${scratch}/out.txt`;
    assert.deepEqual(suggestRules("Bash", { command: line }, "/repo"), rules);
    assert.equal(matchRules(rules, "Bash", { command: line }, "/repo"), "npm test");
    assert.deepEqual(suggestRules("Bash", { command: "npm test > /etc/out" }, "/repo"), []);
    assert.equal(matchRules(rules, "Bash", { command: "npm test > /etc/out" }, "/repo"), undefined);
    assert.equal(matchRules(rules, "Bash", { command: `npm test > ${scratch}/../out` }, "/repo"), undefined);
  });
});

test.after(() => rmSync(home, { recursive: true }));
