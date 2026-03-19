#!/usr/bin/env node
import { startApp } from "./app.mjs";

if (!process.stdin.isTTY) {
  console.error("gaslite requires an interactive terminal (TTY).");
  console.error("Run it directly: node cli.mjs  or  make tui");
  process.exit(1);
}

startApp();
