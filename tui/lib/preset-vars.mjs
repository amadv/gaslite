import { readFileSync, existsSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const thisDir = dirname(fileURLToPath(import.meta.url));
const rootDir = resolve(thisDir, "..", "..");

/**
 * Locate a preset file from a user-supplied argument.
 * Accepts bare names, relative paths, and absolute paths.
 * Returns an absolute path string, or null if nothing matches.
 */
export function resolvePresetPath(file) {
  const direct = resolve(rootDir, file);
  if (existsSync(direct)) return direct;

  const fallbacks = [
    resolve(rootDir, "presets", file),
    resolve(rootDir, "presets", `${file}.json`),
    resolve(rootDir, `${file}.json`),
  ];

  for (const candidate of fallbacks) {
    if (existsSync(candidate)) return candidate;
  }

  return null;
}

/**
 * Scan a preset JSON file for ${VAR} and ${VAR:-default} placeholders.
 * Returns a deduplicated array in order of first occurrence.
 *
 * @param {string} filePath - Absolute path to the preset file
 * @returns {{ name: string, defaultValue: string|null }[]}
 */
export function extractPresetVars(filePath) {
  const contents = readFileSync(filePath, "utf-8");
  const re = /\$\{([A-Z_][A-Z0-9_]*)(?::-([^}]*))?\}/g;
  const found = new Set();
  const results = [];
  let hit;

  while ((hit = re.exec(contents)) !== null) {
    const varName = hit[1];
    if (found.has(varName)) continue;
    found.add(varName);
    results.push({
      name: varName,
      defaultValue: hit[2] !== undefined ? hit[2] : null,
    });
  }

  return results;
}

/**
 * Split command args into KEY=VALUE environment overrides and everything else.
 * Returns { envOverrides, remainingArgs }.
 */
export function parseInlineVars(args) {
  const envOverrides = {};
  const remainingArgs = [];

  for (const token of args) {
    const hit = token.match(/^([A-Z_][A-Z0-9_]*)=(.*)$/);
    if (hit) {
      envOverrides[hit[1]] = hit[2];
    } else {
      remainingArgs.push(token);
    }
  }

  return { envOverrides, remainingArgs };
}
