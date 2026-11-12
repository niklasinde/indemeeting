import { dirname, resolve, sep } from "node:path";
import { isChromeTool } from "./chrome.js";
import { builtInAllowed, commandParts } from "./readonly.js";

export type Rule = { kind: "bash" | "edits" | "tool" | "delegate"; value: string };

const editTools = ["Edit", "Write"];
/// Tools that are asked about every time, so they are never offered or matched as a rule.
const alwaysAsk = new Set(builtInAllowed.alwaysAsk);
export const delegateTool = "mcp__worktime__send_to_agent";

export function parseRules(value: unknown): Rule[] {
  if (!Array.isArray(value)) return [];
  return value.filter((r): r is Rule => ["bash", "edits", "tool", "delegate"].includes(r?.kind) && typeof r?.value === "string" && r.value.trim() !== "");
}

/// The rule saved for one command: its first word, plus the second when it reads like a subcommand (`git fetch`,
/// `npm test`) and the first is not a path (`./test.sh`). Undefined for a command that does not start with a name.
export function prefixRule(words: string[]): string | undefined {
  const [name, sub] = words;
  if (!name || !/^[\w.\/~+-]+$/.test(name) || name === "for") return undefined;
  return !name.includes("/") && sub && /^[A-Za-z][\w:.-]*$/.test(sub) ? `${name} ${sub}` : name;
}

function filePath(input: Record<string, unknown>, cwd: string): string | undefined {
  return typeof input.file_path === "string" ? resolve(cwd, input.file_path) : undefined;
}

function isInside(path: string, folder: string): boolean {
  return path === folder || path.startsWith(folder.endsWith(sep) ? folder : folder + sep);
}

/// What Always allow would save for a call: one prefix rule per Bash command that is not read-only (none when the line writes
/// a file outside the scratchpad, which no rule covers), the project folder
/// (or the file's folder outside it) for edits, the tool itself otherwise. Empty when nothing can be offered.
export function suggestRules(tool: string, input: Record<string, unknown>, cwd: string): Rule[] {
  if (alwaysAsk.has(tool) || isChromeTool(tool)) return [];
  if (tool === "Bash") {
    const parts = typeof input.command === "string" ? commandParts(input.command) : undefined;
    const prefixes = parts?.map((p) => prefixRule(p.words));
    if (!prefixes?.length || prefixes.some((p) => p === undefined) || parts?.some((p) => p.redirected)) return [];
    return [...new Set(prefixes as string[])].map((value) => ({ kind: "bash", value }));
  }
  if (editTools.includes(tool)) {
    const path = filePath(input, cwd);
    if (!path) return [];
    return [{ kind: "edits", value: isInside(path, resolve(cwd)) ? resolve(cwd) : dirname(path) }];
  }
  return [{ kind: "tool", value: tool }];
}

/// The rule saved when Main of `workspace` may message the agent with canonical key `target`.
export const delegateRule = (workspace: string, target: string) => `delegate:${workspace}:${target}`;

/// The delegate rule allowing Main of `workspace` to message `target`, which the app resolved from the call; never matched
/// on the call's own text.
export function matchDelegate(rules: Rule[], workspace: string | undefined, target: string | undefined): string | undefined {
  if (!workspace || !target) return undefined;
  return rules.find((r) => r.kind === "delegate" && r.value === delegateRule(workspace, target))?.value;
}

export const hasDelegateRules = (rules: Rule[], workspace: string | undefined) =>
  workspace !== undefined && rules.some((r) => r.kind === "delegate" && r.value.startsWith(delegateRule(workspace, "")));

function startsWith(words: string[], prefix: string): boolean {
  const wanted = prefix.split(" ").filter(Boolean);
  return wanted.length > 0 && wanted.every((w, i) => words[i] === w);
}

/// The rules that allow a call, joined for the transcript; undefined unless every part that is not read-only matches one.
/// Parts are the simple commands of the parsed line, so a rule never reaches across `;`, `&&` or `|`.
export function matchRules(rules: Rule[], tool: string, input: Record<string, unknown>, cwd: string): string | undefined {
  if (alwaysAsk.has(tool) || isChromeTool(tool)) return undefined;
  if (tool === "Bash") {
    const parts = typeof input.command === "string" ? commandParts(input.command) : undefined;
    if (!parts?.length || parts.some((p) => p.redirected)) return undefined;
    const used = parts.map((p) => rules.find((r) => r.kind === "bash" && startsWith(p.words, r.value))?.value);
    return used.every(Boolean) ? [...new Set(used)].join(", ") : undefined;
  }
  if (editTools.includes(tool)) {
    const path = filePath(input, cwd);
    return path ? rules.find((r) => r.kind === "edits" && isInside(path, resolve(r.value)))?.value : undefined;
  }
  return rules.find((r) => r.kind === "tool" && r.value === tool)?.value;
}
