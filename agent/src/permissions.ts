import { builtInAllowed, isAutoAllowedTool, isReadOnlyCommand } from "./readonly.js";
import { matchRules, type Rule } from "./rules.js";

/// The permission modes the app offers. bypassPermissions and dontAsk are never passed on.
export const modes = ["default", "auto", "acceptEdits", "plan"] as const;
export type Mode = (typeof modes)[number];

export function parseMode(value: unknown): Mode {
  return modes.find((m) => m === value) ?? "default";
}

/// What happens to a call before the mode decides: asked of the user in every mode, allowed by the read-only list or a
/// saved rule (`rule` names it; undefined for a read-only command, absent for an allowed tool), or left to the mode.
export type Decision = { kind: "ask" } | { kind: "allow"; rule?: string; readOnly?: boolean } | { kind: "defer" };

export function preToolDecision(tool: string, input: Record<string, unknown>, cwd: string, rules: Rule[], mode: Mode): Decision {
  if (builtInAllowed.alwaysAsk.includes(tool)) return { kind: "ask" };
  if (isAutoAllowedTool(tool)) return { kind: "allow" };
  if (tool === "Bash" && typeof input.command === "string" && isReadOnlyCommand(input.command)) return { kind: "allow", readOnly: true };
  if (mode === "plan") return { kind: "defer" };
  const rule = matchRules(rules, tool, input, cwd);
  return rule ? { kind: "allow", rule } : { kind: "defer" };
}
