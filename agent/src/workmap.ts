/// What the app's work map needs beyond the transcript: hook runs and how full the context window is.

/// The app's own permission hook runs before every tool call, so PreToolUse runs are left out.
const skippedHookEvents = ["PreToolUse"];

export function hookMessage(message: any): Record<string, unknown> | undefined {
  const phase = message?.subtype === "hook_started" ? "started" : message?.subtype === "hook_response" ? "ended" : undefined;
  if (!phase || typeof message.hook_id !== "string" || skippedHookEvents.includes(message.hook_event)) return undefined;
  return {
    type: "hook", id: message.hook_id, name: message.hook_name ?? message.hook_event, event: message.hook_event, phase,
    ...(phase === "ended" ? { isError: message.outcome === "error" } : {}),
  };
}

function contextMessage(tokens: number, max: number | undefined) {
  return { type: "context", tokens, ...(max && max > 0 ? { max, percent: Math.min(100, Math.round((tokens / max) * 100)) } : {}) };
}

/// The window as the session reports it.
export function reportedContext(report: any): Record<string, unknown> | undefined {
  if (typeof report?.totalTokens !== "number" || typeof report?.maxTokens !== "number" || report.maxTokens <= 0) return undefined;
  return contextMessage(report.totalTokens, report.maxTokens);
}

/// The window as one model turn's usage shows it; without a known window size only the tokens.
export function usageContext(usage: any, window: number | undefined): Record<string, unknown> | undefined {
  const tokens = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens"]
    .reduce((sum, key) => sum + (typeof usage?.[key] === "number" ? usage[key] : 0), 0);
  return tokens > 0 ? contextMessage(tokens, window) : undefined;
}

/// The largest context window among the models a result reports.
export function contextWindow(modelUsage: unknown): number | undefined {
  const windows = Object.values((modelUsage ?? {}) as Record<string, any>)
    .map((usage) => usage?.contextWindow).filter((value) => typeof value === "number" && value > 0);
  return windows.length ? Math.max(...windows) : undefined;
}
