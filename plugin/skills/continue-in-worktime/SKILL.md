---
name: continue-in-worktime
description: Hand this Claude Code session over to the WorkTime app, which continues it as one of its agents (the pull request's agent when this checkout is on an open pull request's branch, else a new agent in this folder). Use when the user says "continue in WorkTime", "move this to WorkTime", "open this session in WorkTime" or "hand this over to the agent".
---

WorkTime opens `worktime://agent?session=<id>&cwd=<folder>` links: it shows this session's transcript in one of its agents and
continues a fork of it, so this session's own transcript is never written to by WorkTime.

1. Find this session's id. Use `$CLAUDE_SESSION_ID` when it is set. Otherwise it is the newest transcript in this folder's
   Claude Code project folder:

   ```sh
   cwd="$(pwd)"
   project="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$(printf '%s' "$cwd" | sed 's/[^A-Za-z0-9]/-/g')"
   id="${CLAUDE_SESSION_ID:-$(ls -t "$project"/*.jsonl 2>/dev/null | head -1 | xargs -n1 basename 2>/dev/null | sed 's/\.jsonl$//')}"
   echo "$id"
   ```

   Use the folder the session started in (where `claude` was run), not a folder you `cd`-ed into since. If no id is found,
   tell the user and stop. Only read these files; never change anything under `~/.claude`.

2. Open it in WorkTime, with the folder URL-encoded:

   ```sh
   open "worktime://agent?session=$id&cwd=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$cwd")"
   ```

3. Tell the user the session is open in WorkTime on the Main page, and that they should stop using this chat now: WorkTime
   continues from here, and carrying on in both would make the two conversations diverge.
