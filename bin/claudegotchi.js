#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const os = require("os");
const { execSync, spawn } = require("child_process");

// ── Paths ──────────────────────────────────────────────────────────────
const HOME = os.homedir();
const INSTALL_DIR = path.join(HOME, ".claude-plugins", "claudegotchi");
const CLAUDE_DIR = path.join(HOME, ".claude");
const SETTINGS_FILE = path.join(CLAUDE_DIR, "settings.json");
const DATA_DIR = INSTALL_DIR; // state.json, creature.json, etc. live here
const HOOK_CMD = path.join(INSTALL_DIR, "scripts", "breath-hook.sh");
const SERVER_SCRIPT = path.join(INSTALL_DIR, "web", "server.py");
const PID_FILE = path.join(DATA_DIR, ".dashboard.pid");
const PORT = 8420;

// ── Helpers ────────────────────────────────────────────────────────────
const green = (s) => `\x1b[38;5;42m${s}\x1b[0m`;
const dim = (s) => `\x1b[38;5;240m${s}\x1b[0m`;
const bold = (s) => `\x1b[1m${s}\x1b[0m`;
const red = (s) => `\x1b[38;5;196m${s}\x1b[0m`;

function log(msg) { console.log(`  ${msg}`); }

function findPackageRoot() {
  // When run via npx, __dirname is inside the npm cache.
  // The plugin files are bundled alongside bin/.
  return path.resolve(__dirname, "..");
}

function copyRecursive(src, dest) {
  if (!fs.existsSync(src)) return;
  const stat = fs.statSync(src);
  if (stat.isDirectory()) {
    fs.mkdirSync(dest, { recursive: true });
    for (const item of fs.readdirSync(src)) {
      if (item === "node_modules" || item === ".git" || item === "__pycache__" || item === ".superpowers" || item === ".gitignore") continue;
      copyRecursive(path.join(src, item), path.join(dest, item));
    }
  } else {
    fs.copyFileSync(src, dest);
    // Preserve executable bit
    if (src.endsWith(".sh") || src.endsWith(".py")) {
      fs.chmodSync(dest, 0o755);
    }
  }
}

function checkDeps() {
  const missing = [];
  try { execSync("which jq", { stdio: "ignore" }); } catch { missing.push("jq"); }
  try { execSync("which python3", { stdio: "ignore" }); } catch { missing.push("python3"); }
  try { execSync("which bash", { stdio: "ignore" }); } catch { missing.push("bash"); }
  return missing;
}

// ── Install ────────────────────────────────────────────────────────────
function install() {
  console.log();
  console.log(`  ${green("🥚 ClaudeGotchi")} — Developer Wellness for Claude Code`);
  console.log();

  // Check dependencies
  const missing = checkDeps();
  if (missing.length > 0) {
    log(red(`Missing dependencies: ${missing.join(", ")}`));
    if (missing.includes("jq")) {
      log(dim("  brew install jq  (macOS)"));
      log(dim("  apt install jq   (Linux)"));
    }
    process.exit(1);
  }

  // Copy plugin files
  const pkgRoot = findPackageRoot();
  log(`Installing to ${dim(INSTALL_DIR)}`);

  // Preserve existing data files
  const dataFiles = ["state.json", "creature.json", "history.jsonl", "config.json", "breath.db"];
  const preserved = {};
  for (const f of dataFiles) {
    const p = path.join(INSTALL_DIR, f);
    if (fs.existsSync(p)) {
      preserved[f] = fs.readFileSync(p);
    }
  }

  // Copy everything
  const dirs = [".claude-plugin", "hooks", "scripts", "web"];
  for (const dir of dirs) {
    copyRecursive(path.join(pkgRoot, dir), path.join(INSTALL_DIR, dir));
  }
  // Copy config template only if none exists
  const configSrc = path.join(pkgRoot, "config.json");
  const configDst = path.join(INSTALL_DIR, "config.json");
  if (!preserved["config.json"] && fs.existsSync(configSrc)) {
    fs.copyFileSync(configSrc, configDst);
  }

  // Restore preserved data
  for (const [f, data] of Object.entries(preserved)) {
    fs.writeFileSync(path.join(INSTALL_DIR, f), data);
  }

  log(`${green("✓")} Plugin files installed`);

  // Register hook in Claude Code settings
  registerHook();

  // Start dashboard server
  startDashboard();

  console.log();
  log(green("Installation complete!"));
  console.log();
  log(`${bold("To use:")} Start Claude Code normally — the hook is active.`);
  log(`${bold("Dashboard:")} http://localhost:${PORT}/dashboard.html`);
  log(`${bold("Commands:")}`);
  log(`  ${dim("claudegotchi dashboard")}  — Start/restart the dashboard`);
  log(`  ${dim("claudegotchi stop")}       — Stop the dashboard`);
  log(`  ${dim("claudegotchi status")}     — Show current status`);
  log(`  ${dim("claudegotchi report")}     — Print wellness report`);
  log(`  ${dim("claudegotchi uninstall")}  — Remove everything`);
  console.log();
}

// ── Hook Registration ──────────────────────────────────────────────────
function registerHook() {
  fs.mkdirSync(CLAUDE_DIR, { recursive: true });

  let settings = {};
  if (fs.existsSync(SETTINGS_FILE)) {
    try {
      settings = JSON.parse(fs.readFileSync(SETTINGS_FILE, "utf8"));
    } catch {
      // Backup corrupted settings
      fs.copyFileSync(SETTINGS_FILE, SETTINGS_FILE + ".bak");
      settings = {};
    }
  }

  // Check if hook already registered
  if (!settings.hooks) settings.hooks = {};
  if (!settings.hooks.UserPromptSubmit) settings.hooks.UserPromptSubmit = [];

  const existing = settings.hooks.UserPromptSubmit.find(
    (h) => h.hooks && h.hooks.some((hh) => hh.command && hh.command.includes("claudegotchi"))
  );

  if (!existing) {
    settings.hooks.UserPromptSubmit.push({
      matcher: "",
      hooks: [{ type: "command", command: HOOK_CMD }],
    });
    fs.writeFileSync(SETTINGS_FILE, JSON.stringify(settings, null, 2));
    log(`${green("✓")} Hook registered in ${dim(SETTINGS_FILE)}`);
  } else {
    log(`${green("✓")} Hook already registered`);
  }
}

// ── Dashboard Server ───────────────────────────────────────────────────
function startDashboard() {
  stopDashboard(true); // Kill any existing instance silently

  const child = spawn("python3", [SERVER_SCRIPT, String(PORT)], {
    detached: true,
    stdio: "ignore",
    env: { ...process.env, BREATH_DIR: DATA_DIR },
  });
  child.unref();

  fs.writeFileSync(PID_FILE, String(child.pid));
  log(`${green("✓")} Dashboard server started (PID ${child.pid}, port ${PORT})`);
}

function stopDashboard(silent = false) {
  if (fs.existsSync(PID_FILE)) {
    const pid = parseInt(fs.readFileSync(PID_FILE, "utf8").trim(), 10);
    try {
      process.kill(pid, "SIGTERM");
      if (!silent) log(`${green("✓")} Dashboard stopped (PID ${pid})`);
    } catch {
      // Process already dead
    }
    fs.unlinkSync(PID_FILE);
  } else if (!silent) {
    log(dim("No dashboard running."));
  }
}

function isDashboardRunning() {
  if (!fs.existsSync(PID_FILE)) return false;
  const pid = parseInt(fs.readFileSync(PID_FILE, "utf8").trim(), 10);
  try { process.kill(pid, 0); return pid; } catch { return false; }
}

// ── Status ─────────────────────────────────────────────────────────────
function showStatus() {
  console.log();
  log(green("ClaudeGotchi Status"));
  console.log();

  // Install status
  const installed = fs.existsSync(path.join(INSTALL_DIR, "scripts", "breath-hook.sh"));
  log(`Installed: ${installed ? green("yes") : red("no")} ${dim(INSTALL_DIR)}`);

  // Hook status
  let hookRegistered = false;
  if (fs.existsSync(SETTINGS_FILE)) {
    try {
      const s = JSON.parse(fs.readFileSync(SETTINGS_FILE, "utf8"));
      hookRegistered = s.hooks?.UserPromptSubmit?.some(
        (h) => h.hooks?.some((hh) => hh.command?.includes("claudegotchi"))
      );
    } catch {}
  }
  log(`Hook: ${hookRegistered ? green("registered") : red("not registered")}`);

  // Dashboard
  const pid = isDashboardRunning();
  log(`Dashboard: ${pid ? green(`running (PID ${pid})`) : dim("stopped")}`);
  if (pid) log(`  ${dim(`http://localhost:${PORT}/dashboard.html`)}`);

  // Data files
  const dataFiles = ["state.json", "creature.json", "history.jsonl", "config.json", "breath.db"];
  const existing = dataFiles.filter((f) => fs.existsSync(path.join(INSTALL_DIR, f)));
  log(`Data: ${existing.length}/${dataFiles.length} files ${dim(existing.join(", "))}`);

  // Creature
  const creaturePath = path.join(INSTALL_DIR, "creature.json");
  if (fs.existsSync(creaturePath)) {
    try {
      const c = JSON.parse(fs.readFileSync(creaturePath, "utf8"));
      if (c.species) {
        log(`Creature: ${c.name || "Unnamed"} the ${c.species} (stage ${c.stage}, ${c.hp}hp, ${c.coins}💎)`);
      } else {
        log(`Creature: ${dim("egg (unhatched)")}`);
      }
    } catch {}
  }

  console.log();
}

// ── Report ─────────────────────────────────────────────────────────────
function showReport() {
  const reportScript = path.join(INSTALL_DIR, "scripts", "breath-report.sh");
  if (!fs.existsSync(reportScript)) {
    log(red("Not installed. Run: npx claudegotchi"));
    process.exit(1);
  }
  try {
    execSync(`BREATH_DIR="${DATA_DIR}" bash "${reportScript}"`, { stdio: "inherit" });
  } catch {}
}

// ── Uninstall ──────────────────────────────────────────────────────────
function uninstall() {
  console.log();
  log(`${red("Uninstalling ClaudeGotchi")}`);

  // Stop dashboard
  stopDashboard(true);

  // Remove hook from settings
  if (fs.existsSync(SETTINGS_FILE)) {
    try {
      const settings = JSON.parse(fs.readFileSync(SETTINGS_FILE, "utf8"));
      if (settings.hooks?.UserPromptSubmit) {
        settings.hooks.UserPromptSubmit = settings.hooks.UserPromptSubmit.filter(
          (h) => !h.hooks?.some((hh) => hh.command?.includes("claudegotchi"))
        );
        if (settings.hooks.UserPromptSubmit.length === 0) {
          delete settings.hooks.UserPromptSubmit;
        }
        if (Object.keys(settings.hooks).length === 0) {
          delete settings.hooks;
        }
        fs.writeFileSync(SETTINGS_FILE, JSON.stringify(settings, null, 2));
        log(`${green("✓")} Hook removed from settings`);
      }
    } catch {}
  }

  // Remove install dir
  if (fs.existsSync(INSTALL_DIR)) {
    fs.rmSync(INSTALL_DIR, { recursive: true, force: true });
    log(`${green("✓")} Removed ${INSTALL_DIR}`);
  }

  log(green("Uninstalled."));
  console.log();
}

// ── CLI Router ─────────────────────────────────────────────────────────
const cmd = process.argv[2] || "install";

switch (cmd) {
  case "install":
    install();
    break;
  case "dashboard":
  case "dash":
    startDashboard();
    log(`Dashboard: http://localhost:${PORT}/dashboard.html`);
    break;
  case "stop":
    stopDashboard();
    break;
  case "status":
    showStatus();
    break;
  case "report":
    showReport();
    break;
  case "uninstall":
  case "remove":
    uninstall();
    break;
  case "help":
  case "--help":
  case "-h":
    console.log();
    console.log(`  ${green("ClaudeGotchi")} — Developer Wellness for Claude Code`);
    console.log();
    console.log("  Usage: claudegotchi [command]");
    console.log();
    console.log("  Commands:");
    console.log(`    ${bold("install")}     Install plugin + register hook + start dashboard (default)`);
    console.log(`    ${bold("dashboard")}   Start/restart the dashboard server`);
    console.log(`    ${bold("stop")}        Stop the dashboard server`);
    console.log(`    ${bold("status")}      Show install/hook/creature status`);
    console.log(`    ${bold("report")}      Print wellness intelligence report`);
    console.log(`    ${bold("uninstall")}   Remove everything`);
    console.log();
    break;
  default:
    console.error(`  Unknown command: ${cmd}. Run: claudegotchi help`);
    process.exit(1);
}
