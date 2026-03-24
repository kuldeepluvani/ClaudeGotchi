#!/usr/bin/env python3
"""Claude Breath Dashboard Server — serves static files + JSON API for shop/config.

All mutations are persisted to both JSON files (for fast bash hook reads)
and SQLite (durable backup via breath.db). On startup, syncs JSON → SQLite
and restores any missing JSON files from the database.
"""

import json
import os
import sys
from http.server import HTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse

# Data directory — resolved from BREATH_DIR or parent of web/
BREATH_DIR = os.environ.get(
    "BREATH_DIR",
    os.environ.get("CLAUDE_PLUGIN_DATA", str(Path(__file__).resolve().parent.parent)),
)
SCRIPT_DIR = str(Path(__file__).resolve().parent.parent / "scripts")
WEB_DIR = str(Path(__file__).resolve().parent)

# Import DB layer (same directory)
sys.path.insert(0, WEB_DIR)
from db import BreathDB  # noqa: E402

# Global DB instance — initialized in main()
db: "BreathDB | None" = None

DATA_FILES = {
    "/state.json": "state.json",
    "/creature.json": "creature.json",
    "/history.jsonl": "history.jsonl",
    "/config.json": "config.json",
}


def read_json(name):
    path = os.path.join(BREATH_DIR, name)
    if not os.path.isfile(path):
        return None
    with open(path) as f:
        return json.load(f)


def write_json(name, data):
    path = os.path.join(BREATH_DIR, name)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, path)
    # Persist to SQLite
    if db:
        key_map = {"state.json": "state", "creature.json": "creature", "config.json": "config"}
        key = key_map.get(name)
        if key:
            db.set_kv(key, data)


def read_raw(name):
    path = os.path.join(BREATH_DIR, name)
    if not os.path.isfile(path):
        return ""
    with open(path) as f:
        return f.read()


class BreathHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=WEB_DIR, **kwargs)

    def log_message(self, format, *args):
        # Quiet logging — only errors
        if args and str(args[0]).startswith("4") or str(args[0]).startswith("5"):
            super().log_message(format, *args)

    def send_json(self, data, status=200):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self):
        path = urlparse(self.path).path
        # Serve data files directly from BREATH_DIR
        if path in DATA_FILES:
            name = DATA_FILES[path]
            full = os.path.join(BREATH_DIR, name)
            if not os.path.isfile(full):
                self.send_json({}, 404)
                return
            raw = read_raw(name)
            body = raw.encode()
            ct = "application/x-ndjson" if name.endswith(".jsonl") else "application/json"
            self.send_response(200)
            self.send_header("Content-Type", ct)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            self.wfile.write(body)
            return
        # Default: serve static files from web/
        super().do_GET()

    def do_POST(self):
        path = urlparse(self.path).path
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length > 0 else b""
        try:
            payload = json.loads(body) if body else {}
        except json.JSONDecodeError:
            payload = {}

        if path.startswith("/api/shop/"):
            self.handle_shop(path, payload)
        elif path == "/api/config":
            self.handle_config(payload)
        else:
            self.send_json({"error": "not found"}, 404)

    def handle_shop(self, path, payload):
        action = path.split("/")[-1]
        creature = read_json("creature.json")
        if not creature:
            self.send_json({"error": "no creature data"}, 400)
            return

        coins = creature.get("coins", 0)
        hp = creature.get("hp", 0)
        ghost = creature.get("ghost_sessions_remaining", 0)
        if action == "feed":
            if coins < 15:
                self.send_json({"error": "not enough coins", "coins": coins})
                return
            creature["coins"] = coins - 15
            creature["hp"] = min(100, hp + 20)
            creature["mood"] = self._mood(creature["hp"])
            write_json("creature.json", creature)
            self.send_json({"ok": True, "action": "fed", "hp": creature["hp"], "coins": creature["coins"]})

        elif action == "shield":
            if coins < 30:
                self.send_json({"error": "not enough coins", "coins": coins})
                return
            creature["coins"] = coins - 30
            creature["shield_active"] = True
            write_json("creature.json", creature)
            self.send_json({"ok": True, "action": "shielded", "coins": creature["coins"]})

        elif action == "revive":
            if coins < 50:
                self.send_json({"error": "not enough coins", "coins": coins})
                return
            if ghost <= 0:
                self.send_json({"error": "creature is not dead"})
                return
            creature["coins"] = coins - 50
            creature["ghost_sessions_remaining"] = 0
            creature["hp"] = 30
            creature["mood"] = "sick"
            write_json("creature.json", creature)
            self.send_json({"ok": True, "action": "revived", "hp": 30, "coins": creature["coins"]})

        elif action == "name":
            name = payload.get("name", "").strip()
            if not name:
                self.send_json({"error": "name required"})
                return
            if coins < 10:
                self.send_json({"error": "not enough coins", "coins": coins})
                return
            creature["coins"] = coins - 10
            creature["name"] = name
            write_json("creature.json", creature)
            self.send_json({"ok": True, "action": "named", "name": name, "coins": creature["coins"]})

        else:
            self.send_json({"error": "unknown action"}, 400)

    def handle_config(self, payload):
        config = read_json("config.json")
        if not config:
            config = {}
        # Merge only known keys
        allowed = {
            "nudge_system_message", "nudge_thresholds_min", "prompt_density_threshold",
            "off_hours_multiplier", "off_hours_start", "off_hours_end",
            "weekend_multiplier", "break_gap_min", "session_gap_min",
            "nudge_cooldown_min", "explicit_acknowledgment", "escalation_timeout_min",
            "vault_summaries", "vault_summary_path", "history_retention_days",
            "velocity_window_sec", "velocity_threshold", "frustration_threshold",
            "streak_alert_days", "adaptive_thresholds", "message_variety",
        }
        for k, v in payload.items():
            if k in allowed:
                config[k] = v
        write_json("config.json", config)
        self.send_json({"ok": True, "config": config})

    @staticmethod
    def _mood(hp):
        if hp <= 0: return "dead"
        if hp <= 19: return "critical"
        if hp <= 39: return "sick"
        if hp <= 59: return "hungry"
        if hp <= 79: return "content"
        return "thriving"


def main():
    global db
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8420

    # Initialize SQLite database
    os.makedirs(BREATH_DIR, exist_ok=True)
    db = BreathDB(BREATH_DIR)

    # Restore any missing JSON files from DB (crash recovery)
    restored = db.restore_if_needed()
    if restored:
        print(f"   Restored from DB: {', '.join(restored)}")

    # Sync current JSON state into DB
    db.sync_from_json()

    server = HTTPServer(("127.0.0.1", port), BreathHandler)
    print(f"\033[38;5;42m🌿 Claude Breath Dashboard\033[0m")
    print(f"   http://localhost:{port}/dashboard.html")
    print(f"   Data: {BREATH_DIR}")
    print(f"   DB:   {db.db_path}")
    print(f"   API:  POST /api/shop/{{feed,shield,revive,name}}")
    print(f"         POST /api/config")
    print(f"   Press Ctrl+C to stop\n")

    # Periodic sync: bash hooks write JSON directly, so we sync every ~30s
    import threading
    def periodic_sync():
        while True:
            import time
            time.sleep(30)
            try:
                if db:
                    db.sync_from_json()
            except Exception:
                pass

    sync_thread = threading.Thread(target=periodic_sync, daemon=True)
    sync_thread.start()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n\033[38;5;240mShutting down — final DB sync...\033[0m")
        if db:
            db.sync_from_json()
            db.close()
        server.server_close()


if __name__ == "__main__":
    main()
