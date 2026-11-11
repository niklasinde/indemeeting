import { test } from "node:test";
import assert from "node:assert/strict";
import { builtInAllowed, handledCommands, isAutoAllowedTool, isReadOnlyCommand, nonReadOnlyParts } from "./readonly.js";

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
    "git grep -n -A6 'URL_FETCHER' HEAD -- finq/jobs/pdf/base.py",
    "git ls-tree -r --name-only HEAD finq/templates",
    "git cat-file -p HEAD:README.md",
    "git cat-file -t HEAD",
    "git show-ref --heads",
    "git merge-base HEAD origin/main",
    "git rev-list --count HEAD",
    "git describe --tags",
    "git shortlog -sn",
    "git config --get remote.origin.url",
    "git config --list",
    "sed -n '1,20p' file.txt",
    "sed 's/^[^:]*:\\([^:]*\\):/\\1:/' x",
    "sed -E -e 's/foo/bar/g' -e '/error/d' x",
    "sed 's,/a,/b,' x",
    "cat x | sort -rn | uniq -c | sort -k2",
    "uniq -c file",
    "cut -d: -f1 /etc/hosts | tr a-z A-Z",
    "awk -F: '{ print $1 }' file",
    "awk -v n=2 'NR == 1 { print $n }'",
    "basename a/b.c; dirname a/b.c; realpath .; stat x; file x",
    "diff -u a b",
    "date +%Y-%m-%d",
    "env",
    "true; false",
    "test -f x && echo yes",
    "[ -d x ] || echo no",
    "printf '%s\\n' a b",
    "R=HEAD; git log $R",
    "R=HEAD; git log ${R} -1",
    "R=$(git rev-parse HEAD); git show $R",
    "cd x 2>/dev/null || { echo 'no repo'; exit 1; }",
    "{ git status; git log -1; } 2>&1 | head",
    "exit",
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
    "git fetch origin",
    "git grep -O foo",
    "git grep -nOvim foo",
    "git grep --open-files-in-pager=vim foo",
    "git cat-file --textconv HEAD:x",
    "git cat-file HEAD",
    "git config user.name x",
    "git config --unset --get x",
    "git config --add x y",
    "sed -i 's/a/b/' x",
    "sed -i.bak 's/a/b/' x",
    "sed -I '' 's/a/b/' x",
    "sed --in-place 's/a/b/' x",
    "sed -f script.sed x",
    "sed 's/a/b/w out' x",
    "sed 's/a/b/e' x",
    "sed -n '/x/w out' x",
    "sed '1e date' x",
    "sed 'W out' x",
    "sed",
    "sort -o out x",
    "sort --output=out x",
    "sort --compress-program=sh x",
    "uniq in out",
    "awk '{ system(\"rm x\") }'",
    "awk '{ print > \"out\" }' x",
    "awk '{ print | \"sh\" }' x",
    "awk -f prog.awk x",
    "awk -i inplace '{ print }' x",
    "file -C -m magic",
    "date -s 2020-01-01",
    "date 0101000020",
    "env rm x",
    "printf -v PATH /tmp",
    "xargs rm",
    "PATH=/tmp; ls",
    "HOME=/tmp",
    "GIT_PAGER=sh",
    "R=a; R=--output=x; git diff $R",
    "R=--output=x; git diff $R",
    "R=$(rm x); echo $R",
    "R=rm; $R x",
    "{ ls; ",
    "ls; }",
    "{ ls }",
    "exit 1 2",
  ]) {
    assert.equal(isReadOnlyCommand(command), false, command);
  }
});

test("nonReadOnlyParts names only the parts that are not read-only", () => {
  const command = `cd ~/git/quiddly/finq.api 2>/dev/null || { echo "no local repo"; exit 1; }; git fetch -q origin claude/QDLY-9052-escape-pdf-einvoice 2>&1 | tail -2; R=FETCH_HEAD; echo "== x"; git grep -n "FinqExtension\\|jinja_extension" $R -- 'finq/*.py' | grep -v "^.*jinja_extension.py:" ; git grep -n -A6 "URL_FETCHER_INCLUDED =" $R -- finq/jobs/pdf/base.py; git grep -n -o '<img[^>]*src="[^"]*"' $R -- finq/jobs/pdf/templates | sed 's/^[^:]*:\\([^:]*\\):/\\1:/' | sort | uniq -c | sort -rn | head -20; git ls-tree -r --name-only $R finq/templates 2>/dev/null | sed 's/.*\\.//' | sort | uniq -c`;
  assert.deepEqual(nonReadOnlyParts(command), ["git fetch -q origin claude/QDLY-9052-escape-pdf-einvoice"]);
  assert.equal(isReadOnlyCommand(command), false);
  assert.deepEqual(nonReadOnlyParts("git status && rm x | head; npm test"), ["rm x", "npm test"]);
  assert.deepEqual(nonReadOnlyParts("ls; echo `rm x`"), ["ls; echo `rm x`"]);
  assert.deepEqual(nonReadOnlyParts("git log -1"), []);
});

test("worktime tools run without asking, except send_to_agent", () => {
  for (const tool of ["Read", "Grep", "Glob", "mcp__worktime__attention", "mcp__worktime__agent_session", "mcp__worktime__github_pr"]) {
    assert.equal(isAutoAllowedTool(tool), true, tool);
  }
  for (const tool of ["mcp__worktime__send_to_agent", "Edit", "Write", "Bash", "mcp__other__read"]) {
    assert.equal(isAutoAllowedTool(tool), false, tool);
  }
  for (const tool of ["mcp__worktime__jira_issue", "mcp__worktime__jira_search", "mcp__worktime__slack_thread", "mcp__worktime__slack_search"]) {
    assert.equal(isAutoAllowedTool(tool), true, tool);
  }
});

test("the built-in list Settings shows names exactly the commands the checks know", () => {
  const listed = builtInAllowed.commands.map((c) => c.name).sort();
  assert.deepEqual(listed, handledCommands().sort());
  assert.equal(new Set(listed).size, listed.length, "no duplicates");
  for (const command of builtInAllowed.commands) {
    assert.ok(command.anyArgs || command.note, `${command.name} has a note or runs with any arguments`);
  }
  assert.equal(isReadOnlyCommand("constructor"), false, "names are looked up as own keys only");
});
