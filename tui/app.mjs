import readline from "readline";
import { getContainerName, getContainerStatus } from "./lib/container.mjs";
import { execute } from "./lib/executor.mjs";
import {
  parse,
  needsContainer,
  getHelpLines,
  getPersonaLines,
  getReadMailLines,
  getListPresetsLines,
  getPresetInfoLines,
  COMMANDS,
} from "./lib/commands.mjs";
import {
  resolvePresetPath,
  extractPresetVars,
  parseInlineVars,
} from "./lib/preset-vars.mjs";
import { complete } from "./lib/completions.mjs";
import getBannerLines from "./components/Banner.mjs";
import { printLine, printLines } from "./components/Output.mjs";
import { printStatusBar } from "./components/StatusBar.mjs";
import { promptVars } from "./components/VarPrompt.mjs";

export function startApp() {
  const hostContainer = getContainerName();
  let currentStatus = "unknown";
  let busy = false;
  let runningChild = null;
  let awaitingVarInput = false;

  const iface = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
    completer: (line) => {
      const suggestions = complete(line);
      return [suggestions, line];
    },
    historySize: 100,
  });

  function showPrompt() {
    if (busy || awaitingVarInput) return;
    iface.setPrompt("\x1b[1m\x1b[32m  > \x1b[0m");
    iface.prompt();
  }

  function pollStatus() {
    currentStatus = getContainerStatus();
  }

  // Draw initial screen
  printStatusBar(hostContainer, currentStatus);
  printLines(getBannerLines());
  pollStatus();
  showPrompt();

  // Keep container status fresh
  const ticker = setInterval(pollStatus, 5000);

  // Handle Ctrl+C: cancel running child, or exit if idle
  iface.on("SIGINT", () => {
    if (awaitingVarInput) return; // VarPrompt owns this signal during prompting
    if (busy && runningChild) {
      runningChild.kill();
      runningChild = null;
      busy = false;
      printLine("  Cancelled.", "system");
      showPrompt();
    } else {
      clearInterval(ticker);
      process.stdout.write("\n");
      process.exit(0);
    }
  });

  iface.on("line", (raw) => {
    if (busy || awaitingVarInput) return;
    handleInput(raw.trim());
  });

  iface.on("close", () => {
    clearInterval(ticker);
    process.exit(0);
  });

  function launchProcess(cmd, args, extraEnv) {
    busy = true;
    printLine("  ... running (Ctrl+C to cancel)", "system");
    iface.pause();

    const handle = execute(
      cmd,
      args,
      {
        onStdout: (line) => printLine(line, "stdout"),
        onStderr: (line) => printLine(line, "stderr"),
        onExit: (code) => {
          if (code === 0) {
            printLine("  Done.", "success");
          } else if (code !== null) {
            printLine(`  Exited with code ${code}.`, "error");
          }
          busy = false;
          runningChild = null;
          pollStatus();
          iface.resume();
          showPrompt();
        },
      },
      extraEnv
    );

    runningChild = handle;
  }

  async function runSequence(steps) {
    for (const step of steps) {
      const parsed = parse(step);
      if (!parsed || parsed.error || !parsed.def.toSpawn) continue;

      const { cmd, args } = parsed.def.toSpawn(parsed.args);

      await new Promise((done) => {
        busy = true;
        printLine("  ... running (Ctrl+C to cancel)", "system");
        iface.pause();

        const handle = execute(cmd, args, {
          onStdout: (line) => printLine(line, "stdout"),
          onStderr: (line) => printLine(line, "stderr"),
          onExit: (code) => {
            if (code !== 0) {
              printLine(`  ${step} failed with code ${code}.`, "error");
            }
            busy = false;
            runningChild = null;
            iface.resume();
            done(code);
          },
        });

        runningChild = handle;
      });
    }

    printLine("  Done.", "success");
    pollStatus();
    showPrompt();
  }

  async function handleInput(input) {
    if (!input) {
      showPrompt();
      return;
    }

    printLine(`  > ${input}`, "system");

    const parsed = parse(input);

    if (!parsed) {
      showPrompt();
      return;
    }

    if (parsed.error) {
      printLine(`  ${parsed.error}`, "error");
      showPrompt();
      return;
    }

    const { name, args, def } = parsed;

    if (needsContainer(name) && currentStatus !== "up") {
      printLine("  Container is not running. Run 'up' first.", "error");
      showPrompt();
      return;
    }

    if (def.sequence) {
      runSequence(def.sequence);
      return;
    }

    if (def.builtin) {
      switch (name) {
        case "help":
          printLines(getHelpLines());
          break;
        case "clear":
          process.stdout.write("\x1b[2J\x1b[H");
          printStatusBar(hostContainer, currentStatus);
          break;
        case "exit":
        case "quit":
          clearInterval(ticker);
          iface.close();
          return;
        case "shell":
          printLine("  Interactive shells cannot run inside the TUI.", "info");
          printLine(`  Run instead: make agent-shell NAME=${args[0]}`, "info");
          break;
        case "personas":
          printLines(getPersonaLines());
          break;
        case "read-mail":
          printLines(getReadMailLines(args[0]));
          break;
        case "reset":
          printLine(
            "  Full reset requires sudo and cannot run inside the TUI.",
            "info"
          );
          printLine("  Run instead: make reset", "info");
          break;
        case "status": {
          pollStatus();
          const dot = currentStatus === "up" ? "\u25cf" : "\u25cb";
          const label = currentStatus === "up" ? "running" : "stopped";
          printLine(
            `  ${hostContainer}: ${dot} ${label}`,
            currentStatus === "up" ? "success" : "error"
          );
          break;
        }
        case "list-presets":
          printLines(getListPresetsLines());
          break;
        case "preset-info":
          printLines(getPresetInfoLines(args[0]));
          break;
      }
      showPrompt();
      return;
    }

    // load-preset: collect variable values before spawning
    if (name === "load-preset" && def.toSpawn) {
      const { envOverrides, remainingArgs } = parseInlineVars(args);
      const presetArg = remainingArgs[0];

      if (!presetArg) {
        printLine("  Error: Preset file is required.", "error");
        showPrompt();
        return;
      }

      const presetPath = resolvePresetPath(presetArg);
      if (!presetPath) {
        printLine(`  Preset not found: ${presetArg}`, "error");
        showPrompt();
        return;
      }

      const allVars = extractPresetVars(presetPath);
      const unresolved = allVars.filter(
        (v) => !(v.name in envOverrides) && !process.env[v.name]
      );

      if (unresolved.length === 0) {
        const { cmd, args: spawnArgs } = def.toSpawn(remainingArgs);
        launchProcess(cmd, spawnArgs, envOverrides);
        return;
      }

      const displayName = presetArg.replace("presets/", "").replace(".json", "");

      awaitingVarInput = true;
      iface.pause();
      const gathered = await promptVars(iface, displayName, allVars, envOverrides);
      iface.resume();
      awaitingVarInput = false;

      if (gathered === null) {
        printLine("  Preset loading cancelled.", "system");
        showPrompt();
        return;
      }

      const finalEnv = { ...envOverrides, ...gathered };
      printLine("  Variables configured. Loading preset...", "info");
      const { cmd, args: spawnArgs } = def.toSpawn(remainingArgs);
      launchProcess(cmd, spawnArgs, finalEnv);
      return;
    }

    if (def.toSpawn) {
      const { cmd, args: spawnArgs } = def.toSpawn(args);
      launchProcess(cmd, spawnArgs);
      return;
    }

    showPrompt();
  }
}
