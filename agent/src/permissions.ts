import { isChromeRead, isChromeTool } from "./chrome.js";
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
export type Decision = { kind: "ask" } | { kind: "allow"; rule?: string; readOnly?: boolean } | { kind: "defer" } | { kind: "deny"; reason: string };

/// An assistant's MCP allowlist: tools of other servers and unlisted ones are refused, whatever the mode or the rules. Claude in
/// Chrome keeps its own rules, and tools that are not MCP tools follow the permission mode.
export function mcpDenied(tool: string, allowed: string[] | undefined): boolean {
  return allowed !== undefined && tool.startsWith("mcp__") && !isChromeTool(tool) && !allowed.includes(tool);
}

/// Claude in Chrome acts in the user's own browser, so only its reads run without asking, in every mode and whatever the rules.
/// `delegated` is the delegate rule that lets this call of send_to_agent through, the only thing that does.
export function preToolDecision(tool: string, input: Record<string, unknown>, cwd: string, rules: Rule[], mode: Mode, allowedMcp?: string[], delegated?: string): Decision {
  if (mcpDenied(tool, allowedMcp)) return { kind: "deny", reason: `${tool} is not one of this assistant's tools. Its role file lists the tools it may use.` };
  if (isChromeTool(tool)) return isChromeRead(tool, input) ? { kind: "allow", readOnly: true } : { kind: "ask" };
  if (builtInAllowed.alwaysAsk.includes(tool)) return delegated ? { kind: "allow", rule: delegated } : { kind: "ask" };
  if (isAutoAllowedTool(tool)) return { kind: "allow" };
  if (tool === "Bash" && typeof input.command === "string" && isReadOnlyCommand(input.command)) return { kind: "allow", readOnly: true };
  if (mode === "plan") return { kind: "defer" };
  const rule = matchRules(rules, tool, input, cwd);
  return rule ? { kind: "allow", rule } : { kind: "defer" };
}
