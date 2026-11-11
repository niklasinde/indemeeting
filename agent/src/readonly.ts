type Token = { word: string; start: number; end: number } | { op: string };
type Word = { word: string; start: number; end: number };

const harmlessRedirects = new Set([">/dev/null", "2>/dev/null", "&>/dev/null", "2>&1", "1>&2", ">&2"]);
const operators = ["&&", "||", "|", ";", "\n"];

/// Splits a command line into words and control operators. Returns undefined for anything it does not fully
/// understand or that could write or run other code: redirection to files, backticks, subshells, heredocs, `&`.
function tokenize(command: string): Token[] | undefined {
  const tokens: Token[] = [];
  let word = "", inWord = false, start = 0, i = 0;
  const begin = () => {
    if (!inWord) start = i;
    inWord = true;
  };
  const flush = () => {
    if (inWord) tokens.push({ word, start, end: i });
    word = "";
    inWord = false;
  };
  while (i < command.length) {
    const c = command[i];
    if (c === "'") {
      const end = command.indexOf("'", i + 1);
      if (end < 0) return undefined;
      begin();
      word += command.slice(i + 1, end);
      i = end + 1;
    } else if (c === '"') {
      let j = i + 1;
      while (j < command.length && command[j] !== '"') {
        if (command[j] === "\\") j++;
        else if (command[j] === "`" || command.startsWith("$(", j)) return undefined;
        j++;
      }
      if (j >= command.length) return undefined;
      begin();
      word += command.slice(i + 1, j);
      i = j + 1;
    } else if (c === "\\" && command[i + 1] === "\n") {
      i += 2;
    } else if (c === "\\") {
      begin();
      word += command[i + 1] ?? "";
      i += 2;
    } else if (command.startsWith("$(", i)) {
      let depth = 1, j = i + 2;
      for (; j < command.length && depth > 0; j++) {
        if (command[j] === "(") depth++;
        if (command[j] === ")") depth--;
      }
      if (depth > 0 || !isReadOnlyCommand(command.slice(i + 2, j - 1))) return undefined;
      begin();
      word += "$()";
      i = j;
    } else if (c === " " || c === "\t") {
      flush();
      i++;
    } else {
      const redirect = inWord ? undefined
        : [...harmlessRedirects].find((r) => command.startsWith(r, i) && /^([\s;|&]|$)/.test(command.charAt(i + r.length)));
      if (redirect) {
        i += redirect.length;
        continue;
      }
      const op = operators.find((o) => command.startsWith(o, i));
      if (op) {
        flush();
        tokens.push({ op });
        i += op.length;
      } else if ("<>&`()".includes(c)) {
        return undefined;
      } else {
        begin();
        word += c;
        i++;
      }
    }
  }
  flush();
  return tokens;
}

const anyArgs = new Set([
  "ls", "cat", "head", "tail", "wc", "grep", "pwd", "which", "cd", "jq", "echo",
  "cut", "tr", "basename", "dirname", "realpath", "stat", "true", "false", "test", "[",
]);
const gitSubcommands = new Set([
  "status", "log", "diff", "show", "branch", "rev-parse", "remote", "ls-files", "blame",
  "grep", "ls-tree", "cat-file", "show-ref", "merge-base", "rev-list", "describe", "shortlog", "config",
]);
const findActions = new Set(["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprint0", "-fprintf", "-fls"]);
const branchChanges = /^(-[dDmMcCfu]|--delete|--move|--copy|--force|--set-upstream-to.*|--unset-upstream|--edit-description|--track.*|--no-track)$/;
const branchListing = /^(-l|--list|--contains|--no-contains|--merged|--no-merged|--points-at)$/;
const configReads = /^(--get|--get-all|--get-regexp|--get-urlmatch|--list|-l)$/;
const configWrites = /^(--add|--unset|--unset-all|--replace-all|--rename-section|--remove-section|-e|--edit)$/;

function isReadOnlyGit(args: string[]): boolean {
  let i = 0;
  while (args[i] === "-C" || args[i] === "--no-pager") i += args[i] === "-C" ? 2 : 1;
  const sub = args[i], rest = args.slice(i + 1);
  if (!sub || !gitSubcommands.has(sub)) return false;
  if (rest.some((a) => a.startsWith("--output") || a === "--ext-diff")) return false;
  switch (sub) {
    case "remote": return rest.length === 0 || (rest.length === 1 && ["-v", "--verbose"].includes(rest[0]));
    case "branch":
      if (rest.some((a) => branchChanges.test(a))) return false;
      return rest.every((a) => a.startsWith("-")) || rest.some((a) => branchListing.test(a));
    case "grep": return !rest.some((a) => /^-[A-Za-z]*O/.test(a) || a.startsWith("--open-files-in-pager"));
    case "cat-file":
      return rest.some((a) => ["-p", "-t", "-s"].includes(a)) && rest.every((a) => !a.startsWith("-") || ["-p", "-t", "-s", "-e"].includes(a));
    case "config": return rest.some((a) => configReads.test(a)) && !rest.some((a) => configWrites.test(a));
    default: return true;
  }
}

function isReadOnlyGh(args: string[]): boolean {
  if (args[0] === "pr") return ["view", "diff", "checks", "list", "status"].includes(args[1]);
  if (args[0] !== "api") return false;
  for (let i = 1; i < args.length; i++) {
    const a = args[i];
    if (/^(-f|-F|--field|--raw-field|--input)/.test(a)) return false;
    if (a === "-X" || a === "--method") {
      if (args[++i]?.toUpperCase() !== "GET") return false;
    } else if (/^(-X|--method=)/.test(a) && a.replace(/^(-X|--method=)/, "").toUpperCase() !== "GET") {
      return false;
    }
  }
  return true;
}

/// Skips one `s` or `y` command, a `/regex/` or a `\cregexc` address starting at `i`. Returns the index after it, or
/// undefined when it is something else or would write (an `s` flag of `w`, `W` or `e`).
function skipSedPart(script: string, i: number): number | undefined {
  const c = script[i];
  const delimiterAt = (j: number) => script[j] !== undefined && !/[\w\s\\]/.test(script[j]);
  const skipTo = (j: number, delimiter: string) => {
    while (j < script.length && script[j] !== delimiter) j += script[j] === "\\" ? 2 : 1;
    return j < script.length ? j + 1 : undefined;
  };
  if (c === "/") return skipTo(i + 1, "/");
  if (c === "\\" && delimiterAt(i + 1)) return skipTo(i + 2, script[i + 1]);
  if ((c === "s" || c === "y") && delimiterAt(i + 1)) {
    let j: number | undefined = skipTo(i + 2, script[i + 1]);
    if (j !== undefined) j = skipTo(j, script[i + 1]);
    if (j === undefined) return undefined;
    const flags = /^[A-Za-z0-9]*/.exec(script.slice(j))![0];
    return /[wWe]/.test(flags) ? undefined : j + flags.length;
  }
  return undefined;
}

/// A sed script that cannot write files or run commands: outside its `s`/`y` commands and regex addresses, no `w`,
/// `W` or `e` letters at all.
function isReadOnlySedScript(script: string): boolean {
  let i = 0;
  while (i < script.length) {
    if ("/\\sy".includes(script[i])) {
      const next = skipSedPart(script, i);
      if (next === undefined) {
        if (script[i] !== "s" && script[i] !== "y") return false;
      } else {
        i = next;
        continue;
      }
    }
    if (/[wWe]/.test(script[i])) return false;
    i++;
  }
  return true;
}

function isReadOnlySed(args: string[]): boolean {
  const scripts: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (/^-[A-Za-z]*[iIf]/.test(a) || a.startsWith("--in-place") || a.startsWith("--file")) return false;
    if (a === "-e" || a === "--expression") scripts.push(args[++i] ?? "");
    else if (a.startsWith("--expression=")) scripts.push(a.slice("--expression=".length));
    else if (!a.startsWith("-") && scripts.length === 0) scripts.push(a);
  }
  return scripts.length > 0 && scripts.every(isReadOnlySedScript);
}

function isReadOnlyAwk(args: string[]): boolean {
  let program: string | undefined;
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "-F" || a === "-v") i++;
    else if (/^-[Fv]./.test(a)) continue;
    else if (a.startsWith("-")) return false;
    else if (program === undefined) program = a;
  }
  return program !== undefined && !/system|getline|[|>]|@load|@include/.test(program);
}

function isReadOnlyUniq(args: string[]): boolean {
  let positionals = 0;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "-f" || args[i] === "-s") i++;
    else if (!args[i].startsWith("-")) positionals++;
  }
  return positionals <= 1;
}

function isReadOnlySimple(words: string[]): boolean {
  const [name, ...args] = words;
  if (!name || name.includes("/") || name.includes("=") || name.includes("$")) return false;
  if (anyArgs.has(name)) return true;
  switch (name) {
    case "git": return isReadOnlyGit(args);
    case "gh": return isReadOnlyGh(args);
    case "rg": return !args.some((a) => a.startsWith("--pre"));
    case "find": return !args.some((a) => findActions.has(a));
    case "sed": return isReadOnlySed(args);
    case "awk": return isReadOnlyAwk(args);
    case "uniq": return isReadOnlyUniq(args);
    case "sort": return !args.some((a) => /^-[A-Za-z]*o/.test(a) || a.startsWith("--output") || a.startsWith("--compress-program"));
    case "diff": return !args.some((a) => a.startsWith("--output") || /^-[A-Za-z]*o/.test(a));
    case "file": return !args.some((a) => /^-[A-Za-z]*C/.test(a) || a === "--compile");
    case "date": return args.every((a) => a.startsWith("+") || ["-u", "-R", "--utc"].includes(a) || /^(-I|--iso-8601)/.test(a));
    case "printf": return !args.some((a) => a === "-v");
    case "env": return args.length === 0;
    case "exit": return args.length === 0 || (args.length === 1 && /^\d+$/.test(args[0]));
    default: return false;
  }
}

const assignment = /^([A-Za-z_]\w*)=(.*)$/s;
const sensitiveVariable = /^(PATH|HOME|IFS|ENV|BASH_ENV|CDPATH|SHELLOPTS|BASHOPTS|PROMPT_COMMAND|PS4|GLOBIGNORE|SHELL|EDITOR|VISUAL|BROWSER|TMPDIR|ZDOTDIR|(LD|DYLD|GIT|NODE|PYTHON)_\w*|\w*PAGER\w*)$/;

/// Replaces `$NAME` and `${NAME}` of variables set earlier in the same command with their values, splitting the result
/// on whitespace like an unquoted expansion would.
function expand(words: string[], variables: Map<string, string>): string[] {
  return words.flatMap((w) => {
    const expanded = w.replace(/\$(?:\{([A-Za-z_]\w*)\}|([A-Za-z_]\w*))/g, (m, braced, bare) => variables.get(braced ?? bare) ?? m);
    return expanded === w ? [w] : expanded.split(/\s+/).filter(Boolean);
  });
}

/// The simple commands of a Bash command line that are not read-only, as they appear in it. Empty when the whole
/// command only reads: allowed commands joined by pipes, `&&`, `||`, `;`, `{ ...; }` groups and `for` loops, plus plain
/// variable assignments used in later arguments. When the line cannot be understood at all, the whole line is returned.
export function nonReadOnlyParts(command: string): string[] {
  const trimmed = command.trim();
  const tokens = tokenize(trimmed);
  if (!tokens || tokens.length === 0) return [trimmed];
  const segments: Word[][] = [[]];
  for (const token of tokens) {
    if ("op" in token) segments.push([]);
    else segments[segments.length - 1].push(token);
  }
  const variables = new Map<string, string>();
  const assign = (name: string, value: string) => {
    if (variables.has(name) || name in process.env || sensitiveVariable.test(name)) return false;
    variables.set(name, value);
    return true;
  };
  const parts: string[] = [];
  let loops = 0, groups = 0;
  for (const segment of segments) {
    let rest = segment;
    while (rest[0]?.word === "{" || rest[0]?.word === "do") {
      if (rest[0].word === "do" && loops === 0) return [trimmed];
      if (rest[0].word === "{") groups++;
      rest = rest.slice(1);
    }
    if (rest.length === 0) continue;
    const words = rest.map((t) => t.word);
    if (words.length === 1 && words[0] === "}") {
      if (--groups < 0) return [trimmed];
      continue;
    }
    if (words.length === 1 && words[0] === "done") {
      if (--loops < 0) return [trimmed];
      continue;
    }
    if (words[0] === "for") {
      if (words.length < 3 || words[2] !== "in" || !/^[A-Za-z_]\w*$/.test(words[1])) return [trimmed];
      loops++;
      if (!assign(words[1], expand(words.slice(3), variables).join(" "))) parts.push(trimmed.slice(rest[0].start, rest[rest.length - 1].end));
      continue;
    }
    const text = trimmed.slice(rest[0].start, rest[rest.length - 1].end);
    if (words.every((w) => assignment.test(w))) {
      for (const w of words) {
        const [, name, value] = assignment.exec(w)!;
        if (!assign(name, expand([value], variables).join(" "))) parts.push(text);
      }
      continue;
    }
    if (!isReadOnlySimple(expand(words, variables))) parts.push(text);
  }
  return loops === 0 && groups === 0 ? [...new Set(parts)] : [trimmed];
}

/// Whether a Bash command only reads. Anything it is unsure about is not read-only, so the user is asked.
export function isReadOnlyCommand(command: string): boolean {
  return nonReadOnlyParts(command).length === 0;
}

/// Tools that run without asking: reading files and the WorkTime MCP tools, except send_to_agent, which hands a prompt to
/// another agent and so is asked about every time.
export function isAutoAllowedTool(tool: string): boolean {
  if (["Read", "Grep", "Glob"].includes(tool)) return true;
  return tool.startsWith("mcp__worktime__") && tool !== "mcp__worktime__send_to_agent";
}
