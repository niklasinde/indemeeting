import type { McpServerConfig, Options } from "@anthropic-ai/claude-agent-sdk";
import { chromeArgs } from "./chrome.js";
import type { Mode } from "./permissions.js";

export const tools = ["Read", "Grep", "Glob", "Edit", "Write", "Bash"];

export type PromptOptions = { cwd: string; sessionId?: string; forkSession?: boolean; appendSystemPrompt?: string; chrome?: boolean };

/// The session options that come from the prompt; the sidecar adds its environment, MCP servers, hooks and permission callback.
export function sessionOptions(input: PromptOptions, model: string, mode: Mode): Options {
  return {
    model,
    cwd: input.cwd,
    resume: input.sessionId,
    ...(input.sessionId && input.forkSession === true ? { forkSession: true } : {}),
    tools,
    ...(input.appendSystemPrompt ? { systemPrompt: { type: "preset", preset: "claude_code", append: input.appendSystemPrompt } } : {}),
    permissionMode: mode,
    settingSources: ["project"],
    extraArgs: chromeArgs(input.chrome === true),
  };
}

/// WorkTime's MCP server, started through the app's binary; a Main's workspace reaches it so its tools default to that workspace.
export function mcpServers(env: NodeJS.ProcessEnv): Record<string, McpServerConfig> {
  const command = env.WORKTIME_MCP_COMMAND;
  const workspace = env.WORKTIME_WORKSPACE;
  if (!command) return {};
  return { worktime: { type: "stdio", command, args: ["--mcp"], ...(workspace ? { env: { WORKTIME_WORKSPACE: workspace } } : {}) } };
}
