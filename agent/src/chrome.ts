/// Claude in Chrome: the CLI's built-in MCP server driving the user's Chrome through the browser extension.
const chromeTool = /^mcp__claude[-_]in[-_]chrome__(.+)$/i;
/// Tools that only read what the browser shows; everything else (navigating, clicking, typing, forms, scripts, uploads) asks.
const reads = new Set(["tabs_context_mcp", "list_connected_browsers", "read_page", "get_page_text", "find"]);
const computerReads = new Set(["screenshot", "zoom"]);

export function isChromeTool(tool: string): boolean {
  return chromeTool.test(tool);
}

export function isChromeRead(tool: string, input: Record<string, unknown>): boolean {
  const name = chromeTool.exec(tool)?.[1];
  if (!name) return false;
  return reads.has(name) || (name === "computer" && typeof input.action === "string" && computerReads.has(input.action));
}

/// The CLI flag for each session: `--no-chrome` when off, so a global "enabled by default" setting does not switch it on.
export function chromeArgs(enabled: boolean): Record<string, null> {
  return enabled ? { chrome: null } : { "no-chrome": null };
}

/// The extension's state from a Chrome tool's result: connected when it worked, its error text when the browser could not be
/// reached, and undefined for any other failure (a missing element, a denied call), which says nothing about the connection.
export function chromeResultStatus(isError: boolean, text: string): { connected: boolean; message?: string } | undefined {
  if (!isError) return { connected: true };
  return /not connected|extension|connection|no (connected )?browser/i.test(text) ? { connected: false, message: text } : undefined;
}

/// The extension's state from a session's MCP server list: undefined when the server is not listed, so nothing is known yet.
export function chromeServerStatus(servers: unknown): { connected: boolean; message?: string } | undefined {
  if (!Array.isArray(servers)) return undefined;
  const server = servers.find((s) => typeof s?.name === "string" && /^claude[-_]in[-_]chrome$/i.test(s.name));
  if (!server) return undefined;
  return server.status === "connected" ? { connected: true } : { connected: false, message: `its MCP server is ${server.status ?? "not running"}` };
}
