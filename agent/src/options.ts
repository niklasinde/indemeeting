import type { Options } from "@anthropic-ai/claude-agent-sdk";
import { chromeArgs } from "./chrome.js";
import type { Mode } from "./permissions.js";

export const tools = ["Read", "Grep", "Glob", "Edit", "Write", "Bash"];

export type PromptOptions = { cwd: string; sessionId?: string; appendSystemPrompt?: string; chrome?: boolean };

/// The session options that come from the prompt; the sidecar adds its environment, MCP servers, hooks and permission callback.
export function sessionOptions(input: PromptOptions, model: string, mode: Mode): Options {
  return {
    model,
    cwd: input.cwd,
    resume: input.sessionId,
    tools,
    ...(input.appendSystemPrompt ? { systemPrompt: { type: "preset", preset: "claude_code", append: input.appendSystemPrompt } } : {}),
    permissionMode: mode,
    settingSources: ["project"],
    extraArgs: chromeArgs(input.chrome === true),
  };
}
