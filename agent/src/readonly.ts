type Token = { word: string } | { op: string };

const harmlessRedirects = new Set([">/dev/null", "2>/dev/null", "&>/dev/null", "2>&1", "1>&2", ">&2"]);
const operators = ["&&", "||", "|", ";", "\n"];

/// Splits a command line into words and control operators. Returns undefined for anything it does not fully
/// understand or that could write or run other code: redirection to files, backticks, subshells, heredocs, `&`.
function tokenize(command: string): Token[] | undefined {
  const tokens: Token[] = [];
  let word = "", inWord = false, i = 0;
  const flush = () => {
    if (inWord) tokens.push({ word });
    word = "";
    inWord = false;
  };
  while (i < command.length) {
    const c = command[i];
    if (c === "'") {
      const end = command.indexOf("'", i + 1);
      if (end < 0) return undefined;
      word += command.slice(i + 1, end);
      inWord = true;
      i = end + 1;
    } else if (c === '"') {
      let j = i + 1;
      while (j < command.length && command[j] !== '"') {
        if (command[j] === "\\") j++;
        else if (command[j] === "`" || command.startsWith("$(", j)) return undefined;
        j++;
      }
      if (j >= command.length) return undefined;
      word += command.slice(i + 1, j);
      inWord = true;
      i = j + 1;
    } else if (c === "\\" && command[i + 1] === "\n") {
      i += 2;
    } else if (c === "\\") {
      word += command[i + 1] ?? "";
      inWord = true;
      i += 2;
    } else if (command.startsWith("$(", i)) {
      let depth = 1, j = i + 2;
      for (; j < command.length && depth > 0; j++) {
        if (command[j] === "(") depth++;
        if (command[j] === ")") depth--;
      }
      if (depth > 0 || !isReadOnlyCommand(command.slice(i + 2, j - 1))) return undefined;
      word += "$()";
      inWord = true;
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
      } else if ("<>&`(){}".includes(c)) {
        return undefined;
      } else {
        word += c;
        inWord = true;
        i++;
      }
    }
  }
  flush();
  return tokens;
}

const anyArgs = new Set(["ls", "cat", "head", "tail", "wc", "grep", "pwd", "which", "cd", "jq", "echo"]);
const gitSubcommands = new Set(["status", "log", "diff", "show", "branch", "rev-parse", "remote", "ls-files", "blame"]);
const findActions = new Set(["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprint0", "-fprintf", "-fls"]);
const branchChanges = /^(-[dDmMcCfu]|--delete|--move|--copy|--force|--set-upstream-to.*|--unset-upstream|--edit-description|--track.*|--no-track)$/;
const branchListing = /^(-l|--list|--contains|--no-contains|--merged|--no-merged|--points-at)$/;

function isReadOnlyGit(args: string[]): boolean {
  let i = 0;
  while (args[i] === "-C" || args[i] === "--no-pager") i += args[i] === "-C" ? 2 : 1;
  const sub = args[i], rest = args.slice(i + 1);
  if (!sub || !gitSubcommands.has(sub)) return false;
  if (rest.some((a) => a.startsWith("--output") || a === "--ext-diff")) return false;
  if (sub === "remote") return rest.length === 0 || (rest.length === 1 && ["-v", "--verbose"].includes(rest[0]));
  if (sub === "branch") {
    if (rest.some((a) => branchChanges.test(a))) return false;
    return rest.every((a) => a.startsWith("-")) || rest.some((a) => branchListing.test(a));
  }
  return true;
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

function isReadOnlySimple(words: string[]): boolean {
  const [name, ...args] = words;
  if (!name || name.includes("/") || name.includes("=")) return false;
  if (anyArgs.has(name)) return true;
  switch (name) {
    case "git": return isReadOnlyGit(args);
    case "gh": return isReadOnlyGh(args);
    case "rg": return !args.some((a) => a.startsWith("--pre"));
    case "find": return !args.some((a) => findActions.has(a));
    default: return false;
  }
}

/// Whether a Bash command only reads: one allowed command, or a pipeline, `&&`/`||`/`;` list or `for` loop made only of
/// them. Anything it is unsure about is not read-only, so the user is asked.
export function isReadOnlyCommand(command: string): boolean {
  const tokens = tokenize(command.trim());
  if (!tokens || tokens.length === 0) return false;
  const segments: string[][] = [[]];
  for (const token of tokens) {
    if ("op" in token) segments.push([]);
    else segments[segments.length - 1].push(token.word);
  }
  let loops = 0;
  for (const segment of segments) {
    if (segment.length === 0) continue;
    if (segment[0] === "for") {
      if (segment.length < 3 || segment[2] !== "in" || !/^[A-Za-z_]\w*$/.test(segment[1])) return false;
      loops++;
      continue;
    }
    if (segment[0] === "done" && segment.length === 1) {
      if (--loops < 0) return false;
      continue;
    }
    const words = segment[0] === "do" ? segment.slice(1) : segment;
    if (segment[0] === "do" && loops === 0) return false;
    if (!isReadOnlySimple(words)) return false;
  }
  return loops === 0;
}

/// Tools that run without asking: reading files and the WorkTime MCP tools, except send_to_agent, which hands a prompt to
/// another agent and so is asked about every time.
export function isAutoAllowedTool(tool: string): boolean {
  if (["Read", "Grep", "Glob"].includes(tool)) return true;
  return tool.startsWith("mcp__worktime__") && tool !== "mcp__worktime__send_to_agent";
}
