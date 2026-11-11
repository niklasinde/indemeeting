import { existsSync } from "node:fs";

/// Spawning Claude Code in a folder that no longer exists fails with ENOENT, which the SDK reports as a native binary that
/// failed to launch. The error to send instead, or undefined when the folder is there.
export function missingFolderError(cwd: string, exists: (path: string) => boolean = existsSync) {
  return exists(cwd) ? undefined : { type: "error", message: `This agent's folder no longer exists: ${cwd}`, missingFolder: cwd };
}
