// ANSI color codes keyed by output type
const COLOR_MAP = {
  stdout: "",
  stderr: "\x1b[31m",
  info: "\x1b[36m",
  success: "\x1b[32m",
  error: "\x1b[1m\x1b[31m",
  system: "\x1b[90m",
};

const RESET = "\x1b[0m";

export function printLine(text, type) {
  const color = COLOR_MAP[type] ?? "";
  process.stdout.write(color + text + (color ? RESET : "") + "\n");
}

export function printLines(lines) {
  for (const item of lines) {
    printLine(item.text, item.type);
  }
}
