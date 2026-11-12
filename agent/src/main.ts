import { createInterface } from "node:readline";
import { missingFolderError } from "./folder.js";
import { query, type HookCallback, type PermissionResult, type Query } from "@anthropic-ai/claude-agent-sdk";
import { chromeResultStatus, chromeServerStatus, isChromeTool } from "./chrome.js";
import { mcpServers, sessionOptions, type PromptOptions } from "./options.js";
import { parseMode, preToolDecision, type Decision, type Mode } from "./permissions.js";
import { contextWindow, hookMessage, reportedContext, usageContext } from "./workmap.js";
import { delegateTool, hasDelegateRules, matchDelegate, parseRules, suggestRules, type Rule } from "./rules.js";

type Input =
  | ({ type: "prompt"; text: string; model?: string; permissionMode?: string } & PromptOptions)
  | { type: "permission"; id: string; allow: boolean }
  | { type: "target"; id: string; key?: string }
  | { type: "mode"; mode: string }
  | { type: "interrupt" }
  | { type: "rules"; rules: unknown };

const model = process.env.WORKTIME_AGENT_MODEL ?? "claude-opus-5-5";
/// Tool calls allowed without asking, with the rule that allowed them when it was one of the user's.
const autoAllowed = new Map<string, string | undefined>();
/// Claude in Chrome calls waiting for their result, which tells whether the extension is connected.
const chromeCalls = new Set<string>();
let rules: Rule[] = [];
const resultLimit = 4000;
const authErrors = ["authentication_failed", "oauth_org_not_allowed"];
const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"].includes(key)));

const resolving = new Map<string, (key?: string) => void>();
const resolveTimeout = 5000;
const pending = new Map<string, (result: PermissionResult) => void>();
let running: { query: Query; abort: AbortController } | undefined;
let nextPermission = 0;
let mode: Mode = "default";
/// Calls the user allowed in the PreToolUse hook, so canUseTool does not ask a second time.
const hookAllowed = new Set<string>();
/// A hook waits as long as the user takes to answer.
const hookTimeout = 24 * 3600;
/// The context window of the models used so far, and the model turn the context was last reported for.
let knownWindow: number | undefined;
let reportedTurn: string | undefined;

/// How full the context window is after a model turn: asked of the session, else worked out from the turn's usage.
function reportContext(usage: unknown) {
  const fallback = () => usageContext(usage, knownWindow);
  const report = (context: Record<string, unknown> | undefined) => context && send(context);
  const current = running?.query;
  if (!current) return report(fallback());
  current.getContextUsage({ detail: "summary" }).then((answer) => report(reportedContext(answer) ?? fallback()), () => report(fallback()));
}

/// The key the app would deliver this send_to_agent call to, resolved by the same code as the tool; undefined when unclear.
function resolveTarget(input: Record<string, unknown>): Promise<string | undefined> {
  return new Promise((resolve) => {
    const id = String(++nextPermission);
    const timer = setTimeout(() => resolving.delete(id) && resolve(undefined), resolveTimeout);
    resolving.set(id, (key) => (clearTimeout(timer), resolve(key)));
    send({ type: "resolve_target", id, input });
  });
}

/// The decision for a call; a send_to_agent from a Main is looked at against its delegate rules first.
async function decide(tool: string, input: Record<string, unknown>, options: PromptOptions) {
  const check = tool === delegateTool && hasDelegateRules(rules, options.delegateFrom);
  const delegated = check ? matchDelegate(rules, options.delegateFrom, await resolveTarget(input)) : undefined;
  return preToolDecision(tool, input, options.cwd, rules, mode, options.allowedMcpTools, delegated);
}

function ask(tool: string, input: Record<string, unknown>, cwd: string): Promise<PermissionResult> {
  return new Promise((resolve) => {
    const id = String(++nextPermission);
    pending.set(id, resolve);
    send({ type: "permission_request", id, tool, input, offer: suggestRules(tool, input, cwd) });
  });
}

/// Applies an allow decision: read-only commands and rule matches are marked auto in the transcript.
function allowed(decision: Extract<Decision, { kind: "allow" }>, toolUseID: string): PermissionResult {
  if (decision.readOnly || decision.rule) autoAllowed.set(toolUseID, decision.rule);
  return { behavior: "allow" };
}

/// Runs before the mode decides, so the read-only list and saved rules apply in every mode and send_to_agent is asked
/// of the user even where the auto mode classifier would otherwise answer.
function preToolUse(options: PromptOptions): HookCallback {
  return async (hook) => {
    if (hook.hook_event_name !== "PreToolUse") return {};
    const input = (hook.tool_input ?? {}) as Record<string, unknown>;
    const cwd = options.cwd;
    const decision = await decide(hook.tool_name, input, options);
    if (decision.kind === "defer") return {};
    if (decision.kind === "deny") {
      return { hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: decision.reason } };
    }
    const result = decision.kind === "allow" ? allowed(decision, hook.tool_use_id) : await ask(hook.tool_name, input, cwd);
    if (result.behavior === "allow") hookAllowed.add(hook.tool_use_id);
    return {
      hookSpecificOutput: {
        hookEventName: "PreToolUse", permissionDecision: result.behavior === "allow" ? "allow" : "deny",
        ...(result.behavior === "deny" ? { permissionDecisionReason: result.message } : {}),
      },
    };
  };
}

function send(message: Record<string, unknown>) {
  process.stdout.write(JSON.stringify(message) + "\n");
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
      if (message.subtype === "init") {
        send({ type: "session", sessionId: message.session_id });
        const chrome = chromeServerStatus(message.mcp_servers);
        if (chrome && !chrome.connected) send({ type: "chrome", ...chrome });
      } else {
        const hook = hookMessage(message);
        if (hook) send(hook);
      }
      break;
    case "assistant":
      if (authErrors.includes(message.error)) {
        return send({ type: "error", message: resultText(message.message?.content) || message.error, auth: true });
      }
      for (const block of message.message?.content ?? []) {
        if (block.type === "text" && block.text) send({ type: "text", text: block.text });
        if (block.type === "tool_use") {
          send({ type: "tool_use", id: block.id, tool: block.name, input: block.input ?? {} });
          if (isChromeTool(block.name)) chromeCalls.add(block.id);
        }
      }
      if (!message.parent_tool_use_id && message.message?.id && message.message.id !== reportedTurn) {
        reportedTurn = message.message.id;
        reportContext(message.message.usage);
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
          const chrome = chromeCalls.delete(block.tool_use_id) ? chromeResultStatus(block.is_error === true, resultText(block.content)) : undefined;
          if (chrome) send({ type: "chrome", ...chrome });
        }
      }
      break;
    case "result":
      knownWindow = contextWindow(message.modelUsage) ?? knownWindow;
      send({
        type: "result", sessionId: message.session_id, isError: message.is_error === true || message.subtype !== "success",
        text: message.result ?? (message.errors ?? []).join("\n"), turns: message.num_turns, model, permissionMode: mode,
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
  const missing = missingFolderError(input.cwd);
  if (missing) {
    send(missing);
    return send({ type: "idle" });
  }
  const abort = new AbortController();
  const promptModel = input.model || model;
  mode = parseMode(input.permissionMode);
  const current = query({
    prompt: input.text,
    options: {
      ...sessionOptions(input, promptModel, mode),
      env,
      mcpServers: mcpServers(process.env),
      abortController: abort,
      includeHookEvents: true,
      hooks: { PreToolUse: [{ hooks: [preToolUse(input)], timeout: hookTimeout }] },
      canUseTool: async (tool, toolInput, { toolUseID }) => {
        if (hookAllowed.delete(toolUseID)) return { behavior: "allow" };
        const decision = await decide(tool, toolInput, input);
        if (decision.kind === "deny") return { behavior: "deny", message: decision.reason };
        return decision.kind === "allow" ? allowed(decision, toolUseID) : ask(tool, toolInput, input.cwd);
      },
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
    if (!finished) {
      send(abort.signal.aborted ? { type: "error", message: "Stopped." }
        : missingFolderError(input.cwd) ?? { type: "error", message: String((error as Error)?.message ?? error) });
    }
  } finally {
    denyPending("The prompt ended.");
    autoAllowed.clear();
    hookAllowed.clear();
    chromeCalls.clear();
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
    case "target": {
      const resolve = resolving.get(input.id);
      resolving.delete(input.id);
      resolve?.(input.key);
      break;
    }
    case "mode":
      mode = parseMode(input.mode);
      running?.query.setPermissionMode(mode).catch(() => {});
      break;
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
