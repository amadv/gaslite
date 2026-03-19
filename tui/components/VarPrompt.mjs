/**
 * Interactively collect values for preset environment variables.
 *
 * Returns a { VAR: "value" } map for answered variables,
 * or null if the user pressed Ctrl+C to cancel.
 */
export async function promptVars(rl, presetName, vars, envOverrides) {
  // Only ask about vars not already supplied via overrides or environment
  const pending = vars.filter(
    (v) => !(v.name in envOverrides) && !process.env[v.name]
  );

  if (pending.length === 0) return {};

  const answers = {};

  for (let idx = 0; idx < pending.length; idx++) {
    const variable = pending[idx];
    const counter = `(${idx + 1}/${pending.length})`;
    const defaultHint =
      variable.defaultValue !== null
        ? ` (default: ${variable.defaultValue})`
        : " (required, no default)";

    process.stdout.write(
      `\n\x1b[1m\x1b[36m  Configure ${presetName}\x1b[0m  \x1b[90m${counter}\x1b[0m\n`
    );
    process.stdout.write(
      `  \x1b[33m${variable.name}\x1b[0m\x1b[90m${defaultHint}\x1b[0m\n`
    );
    process.stdout.write(
      `\x1b[90m  Press Enter to accept default, Ctrl+C to cancel\x1b[0m\n`
    );

    const reply = await askQuestion(rl, "\x1b[1m\x1b[32m  > \x1b[0m");
    if (reply === null) return null; // user cancelled

    const value = reply.trim();
    if (value) {
      answers[variable.name] = value;
    } else if (variable.defaultValue !== null) {
      answers[variable.name] = variable.defaultValue;
    }
  }

  return answers;
}

/**
 * Wrap rl.question as a Promise that resolves to the user's input,
 * or null if SIGINT fires while waiting.
 */
function askQuestion(rl, promptText) {
  return new Promise((resolve) => {
    const cancelHandler = () => resolve(null);
    rl.once("SIGINT", cancelHandler);
    rl.question(promptText, (input) => {
      rl.removeListener("SIGINT", cancelHandler);
      resolve(input);
    });
  });
}
