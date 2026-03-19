// Renders a single-line status bar showing the container name and run state
export function printStatusBar(containerName, status) {
  const dot = status === "up" ? "\u25cf" : "\u25cb";
  const stateLabel = status === "up" ? "running" : "stopped";
  const stateColor = status === "up" ? "\x1b[32m" : "\x1b[31m";
  process.stdout.write(
    `\x1b[1m\x1b[36m  gaslite\x1b[0m  \x1b[90m\u2502  ${containerName}\x1b[0m  ${stateColor}${dot} ${stateLabel}\x1b[0m\n`
  );
}
