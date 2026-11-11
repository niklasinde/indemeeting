import { createInterface } from "node:readline";
import { query, type McpServerConfig, type PermissionResult, type Query } from "@anthropic-ai/claude-agent-sdk";
import { isAutoAllowedTool, isReadOnlyCommand } from "./readonly.js";
import { matchRules, parseRules, suggestRules, type Rule } from "./rules.js";

type Input =
  | { type: "prompt"; text: string; cwd: string; sessionId?: string; model?: string; appendSystemPrompt?: string }
  | { type: "permission"; id: string; allow: boolean }
  | { type: "interrupt" }
  | { type: "rules"; rules: unknown };

const model = process.env.WORKTIME_AGENT_MODEL ?? "claude-opus-5-5";
const tools = ["Read", "Grep", "Glob", "Edit", "Write", "Bash"];
/// Tool calls allowed without asking, with the rule that allowed them when it was one of the user's.
const autoAllowed = new Map<string, string | undefined>();
let rules: Rule[] = [];
const resultLimit = 4000;
const authErrors = ["authentication_failed", "oauth_org_not_allowed"];
const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"].includes(key)));

const pending = new Map<string, (result: PermissionResult) => void>();
let running: { query: Query; abort: AbortController } | undefined;
let nextPermission = 0;

function send(message: Record<string, unknown>) {
  process.stdout.write(JSON.stringify(message) + "\n");
}

function mcpServers(): Record<string, McpServerConfig> {
  const command = process.env.WORKTIME_MCP_COMMAND;
  return command ? { worktime: { type: "stdio", command, args: ["--mcp"] } } : {};
}

function resultText(content: unknown): string {
  const text = typeof content === "string" ? content
    : Array.isArray(content) ? content.map((part) => (part?.type === "text" ? part.text : `[${part?.type ?? "content"}]`)).join("\n")
    : JSON.stringify(content ?? "");
  return text.length > resultLimit ? text.slice(0, resultLimit) + "\n…" : text;
}

function forward(message: any, model: string) {
  switch (message.type) {
    case "system":
      if (message.subtype === "init") send({ type: "session", sessionId: message.session_id });
      break;
    case "assistant":
      if (authErrors.includes(message.error)) {
        return send({ type: "error", message: resultText(message.message?.content) || message.error, auth: true });
      }
      for (const block of message.message?.content ?? []) {
        if (block.type === "text" && block.text) send({ type: "text", text: block.text });
        if (block.type === "tool_use") send({ type: "tool_use", id: block.id, tool: block.name, input: block.input ?? {} });
      }
      break;
    case "user":
      if (!Array.isArray(message.message?.content)) break;
      for (const block of message.message.content) {
        if (block.type === "tool_result") {
          const rule = autoAllowed.get(block.tool_use_id);
          send({
            type: "tool_result", id: block.tool_use_id, content: resultText(block.content), isError: block.is_error === true,
            auto: autoAllowed.delete(block.tool_use_id), rule,
          });
        }
      }
      break;
    case "result":
      send({
        type: "result", sessionId: message.session_id, isError: message.is_error === true || message.subtype !== "success",
        text: message.result ?? (message.errors ?? []).join("\n"), turns: message.num_turns, model,
      });
      break;
  }
}

function denyPending(reason: string) {
  for (const resolve of pending.values()) resolve({ behavior: "deny", message: reason, interrupt: true });
  pending.clear();
}

async function run(input: Extract<Input, { type: "prompt" }>) {
  if (running) return send({ type: "error", message: "The agent is still working on the previous prompt." });
  const abort = new AbortController();
  const promptModel = input.model || model;
  const current = query({
    prompt: input.text,
    options: {
      model: promptModel,
      cwd: input.cwd,
      resume: input.sessionId,
      tools,
      ...(input.appendSystemPrompt ? { systemPrompt: { type: "preset", preset: "claude_code", append: input.appendSystemPrompt } } : {}),
      permissionMode: "default",
      settingSources: ["project"],
      env,
      mcpServers: mcpServers(),
      abortController: abort,
      canUseTool: (tool, toolInput, { toolUseID }) => new Promise<PermissionResult>((resolve) => {
        if (isAutoAllowedTool(tool)) return resolve({ behavior: "allow" });
        if (tool === "Bash" && typeof toolInput.command === "string" && isReadOnlyCommand(toolInput.command)) {
          autoAllowed.set(toolUseID, undefined);
          return resolve({ behavior: "allow" });
        }
        const rule = matchRules(rules, tool, toolInput, input.cwd);
        if (rule) {
          autoAllowed.set(toolUseID, rule);
          return resolve({ behavior: "allow" });
        }
        const id = String(++nextPermission);
        pending.set(id, resolve);
        send({ type: "permission_request", id, tool, input: toolInput, offer: suggestRules(tool, toolInput, input.cwd) });
      }),
    },
  });
  running = { query: current, abort };
  let finished = false;
  try {
    for await (const message of current) {
      forward(message, promptModel);
      finished ||= message.type === "result";
    }
  } catch (error) {
    if (!finished) send({ type: "error", message: abort.signal.aborted ? "Stopped." : String((error as Error)?.message ?? error) });
  } finally {
    denyPending("The prompt ended.");
    autoAllowed.clear();
    running = undefined;
    send({ type: "idle" });
  }
}

function handle(line: string) {
  let input: Input;
  try {
    input = JSON.parse(line);
  } catch {
    return send({ type: "error", message: "Not a JSON line." });
  }
  switch (input.type) {
    case "prompt":
      void run(input);
      break;
    case "permission": {
      const resolve = pending.get(input.id);
      pending.delete(input.id);
      resolve?.(input.allow ? { behavior: "allow" } : { behavior: "deny", message: "The user denied this tool call." });
      break;
    }
    case "rules":
      rules = parseRules(input.rules);
      break;
    case "interrupt":
      denyPending("The user stopped the agent.");
      if (running) running.query.interrupt().catch(() => running?.abort.abort());
      break;
    default:
      send({ type: "error", message: `Unknown message type: ${(input as { type?: string }).type}` });
  }
}

send({ type: "ready", model });
createInterface({ input: process.stdin }).on("line", (line) => line.trim() && handle(line)).on("close", () => {
  running?.abort.abort();
  process.exit(0);
});
