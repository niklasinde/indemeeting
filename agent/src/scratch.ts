import { lstatSync, realpathSync } from "node:fs";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";

/// Where Claude Code keeps an agent's scratchpads: `<tmp>/claude-<uid>/<project>/<session>/scratchpad`. Undefined when
/// that cannot be worked out, so nothing is treated as scratch.
function defaultBase(): string | undefined {
  try {
    return join(realpathSync("/tmp"), `claude-${process.getuid?.() ?? ""}`);
  } catch {
    return undefined;
  }
}

let base = defaultBase();

export function setScratchBase(value: string | undefined) {
  base = value;
}

/// The real path of `path` with symlinks resolved as far as it exists; undefined for a dangling symlink or an unreadable folder.
function resolved(path: string): string | undefined {
  const rest: string[] = [];
  for (let existing = resolve(path); ; ) {
    try {
      return join(realpathSync(existing), ...[...rest].reverse());
    } catch {
      try {
        lstatSync(existing);
        return undefined;
      } catch {
        const parent = dirname(existing);
        if (parent === existing) return undefined;
        rest.push(basename(existing));
        existing = parent;
      }
    }
  }
}

/// Whether an absolute path, after resolving symlinks, is in an agent's scratchpad (or is the scratchpad itself unless `strict`).
export function scratchPath(path: string, strict = false): boolean {
  if (!base || !isAbsolute(path) || /[*?\[\]{}~$`!#]/.test(path) || path.split("/").includes("..")) return false;
  const real = resolved(path);
  const inside = real && relative(base, real);
  if (!inside || inside.startsWith("..") || isAbsolute(inside)) return false;
  const segments = inside.split(sep);
  return segments[2] === "scratchpad" && segments.length > (strict ? 3 : 2);
}

/// A command whose flags are all single letters from `letters` and whose operands (the last one for "last") are in the scratchpad.
function inScratch(letters: string, operands: "all" | "last", strict = false) {
  return (args: string[]): boolean => {
    const paths: string[] = [];
    for (const arg of args) {
      if (!arg.startsWith("-")) paths.push(arg);
      else if (!/^-[A-Za-z]+$/.test(arg) || [...arg.slice(1)].some((c) => !letters.includes(c))) return false;
    }
    const checked = operands === "last" ? paths.slice(-1) : paths;
    return paths.length >= (operands === "last" ? 2 : 1) && checked.every((p) => scratchPath(p, strict));
  };
}

/// Commands that only change files inside the scratchpad, which is the agent's own to write to.
export const scratchCommands = new Map<string, (args: string[]) => boolean>([
  ["mkdir", inScratch("p", "all")],
  ["touch", inScratch("", "all")],
  ["tee", inScratch("a", "all")],
  ["cp", inScratch("RrpaiLnv", "last")],
  ["mv", inScratch("finv", "all", true)],
  ["rm", inScratch("rRfv", "all", true)],
]);
