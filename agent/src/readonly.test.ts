import { test } from "node:test";
import assert from "node:assert/strict";
import { isAutoAllowedTool, isReadOnlyCommand } from "./readonly.js";

test("read-only commands are allowed", () => {
  for (const command of [
    "gh pr view 12 --json title,body",
    "gh pr diff https://github.com/o/r/pull/12",
    "gh pr checks 12 -R o/r",
    "gh api repos/o/r/pulls/12/comments --paginate",
    "gh api -X GET repos/o/r/pulls",
    "gh api --method=get repos/o/r",
    "git status --short",
    "git log --oneline -20 && git diff HEAD~1 -- Sources",
    "git -C ~/git/x show HEAD:README.md",
    "git branch -a --sort=-committerdate",
    "git branch --list 'NI/*'",
    "git remote -v",
    "ls -la; pwd",
    "rg -n 'canUseTool' agent/src | head -20",
    "grep -rn foo . | wc -l",
    "find . -name '*.swift' -not -path './.build/*'",
    "for f in a.swift b.swift; do wc -l $f; done",
    "cat $(git rev-parse --show-toplevel)/README.md",
    "gh pr view 12 2>/dev/null || echo missing",
    "gh pr view 12 --json files | jq '.files[].path'",
    "cd agent && git log -3",
  ]) {
    assert.equal(isReadOnlyCommand(command), true, command);
  }
});

test("anything that writes, runs other code or is unclear asks", () => {
  for (const command of [
    "",
    "rm -rf dist",
    "sudo ls",
    "git commit -m x",
    "git push",
    "git checkout main",
    "git branch new-branch",
    "git branch -D old",
    "git remote add x y",
    "git diff --output=patch.txt",
    "git -c core.pager=sh log",
    "gh pr merge 12",
    "gh pr comment 12 -b hi",
    "gh api -X POST repos/o/r/issues",
    "gh api repos/o/r/issues -f title=x",
    "gh api --method DELETE repos/o/r",
    "gh api graphql -F query=@q.graphql",
    "ls > files.txt",
    "cat a >> b",
    "git log | tee log.txt",
    "find . -name x -delete",
    "find . -exec rm {} \\;",
    "rg --pre ./script foo",
    "echo `rm x`",
    "cat $(rm x)",
    "cat \"$(rm x)\"",
    "ls & rm x",
    "(cd x && rm y)",
    "FOO=1 ls",
    "/bin/rm x",
    "npm test",
    "for f in *; do rm $f; done",
    "for f in *; do ls $f",
    "cat <<EOF\nx\nEOF",
    "ls 'unterminated",
  ]) {
    assert.equal(isReadOnlyCommand(command), false, command);
  }
});

test("worktime tools run without asking, except send_to_agent", () => {
  for (const tool of ["Read", "Grep", "Glob", "mcp__worktime__attention", "mcp__worktime__agent_session", "mcp__worktime__github_pr"]) {
    assert.equal(isAutoAllowedTool(tool), true, tool);
  }
  for (const tool of ["mcp__worktime__send_to_agent", "Edit", "Write", "Bash", "mcp__other__read"]) {
    assert.equal(isAutoAllowedTool(tool), false, tool);
  }
});
