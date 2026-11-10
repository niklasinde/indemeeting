import { createInterface } from "node:readline";
import { query, type McpServerConfig, type PermissionResult, type Query } from "@anthropic-ai/claude-agent-sdk";

type Input =
  | { type: "prompt"; text: string; cwd: string; sessionId?: string }
  | { type: "permission"; id: string; allow: boolean }
  | { type: "interrupt" };

const model = process.env.WORKTIME_AGENT_MODEL ?? "claude-opus-5-5";
const tools = ["Read", "Grep", "Glob", "Edit", "Write", "Bash"];
const readOnly = (tool: string) => ["Read", "Grep", "Glob"].includes(tool) || tool.startsWith("mcp__worktime__");
const resultLimit = 4000;

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

function forward(message: any) {
  switch (message.type) {
    case "system":
      if (message.subtype === "init") send({ type: "session", sessionId: message.session_id });
      break;
    case "assistant":
      for (const block of message.message?.content ?? []) {
        if (block.type === "text" && block.text) send({ type: "text", text: block.text });
        if (block.type === "tool_use") send({ type: "tool_use", id: block.id, tool: block.name, input: block.input ?? {} });
      }
      break;
    case "user":
      if (!Array.isArray(message.message?.content)) break;
      for (const block of message.message.content) {
        if (block.type === "tool_result") {
          send({ type: "tool_result", id: block.tool_use_id, content: resultText(block.content), isError: block.is_error === true });
        }
      }
      break;
    case "result":
      send({
        type: "result", sessionId: message.session_id, isError: message.is_error === true || message.subtype !== "success",
        text: message.result ?? (message.errors ?? []).join("\n"), costUSD: message.total_cost_usd, turns: message.num_turns,
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
  const current = query({
    prompt: input.text,
    options: {
      model,
      cwd: input.cwd,
      resume: input.sessionId,
      tools,
      permissionMode: "default",
      settingSources: ["project"],
      mcpServers: mcpServers(),
      abortController: abort,
      canUseTool: (tool, toolInput) => new Promise<PermissionResult>((resolve) => {
        if (readOnly(tool)) return resolve({ behavior: "allow" });
        const id = String(++nextPermission);
        pending.set(id, resolve);
        send({ type: "permission_request", id, tool, input: toolInput });
      }),
    },
  });
  running = { query: current, abort };
  let finished = false;
  try {
    for await (const message of current) {
      forward(message);
      finished ||= message.type === "result";
    }
  } catch (error) {
    if (!finished) send({ type: "error", message: abort.signal.aborted ? "Stopped." : String((error as Error)?.message ?? error) });
  } finally {
    denyPending("The prompt ended.");
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
    case "interrupt":
      denyPending("The user stopped the agent.");
      if (running) running.query.interrupt().catch(() => running?.abort.abort());
      break;
    default:
      send({ type: "error", message: `Unknown message type: ${(input as { type?: string }).type}` });
  }
}

if (!process.env.ANTHROPIC_API_KEY) send({ type: "error", message: "ANTHROPIC_API_KEY is not set." });
send({ type: "ready", model });
createInterface({ input: process.stdin }).on("line", (line) => line.trim() && handle(line)).on("close", () => {
  running?.abort.abort();
  process.exit(0);
});
