"""Claude Breath — SQLite persistence layer.

Stores all wellness state in a single breath.db file so nothing is lost.
JSON files remain the fast-path for bash hooks; this module syncs between them.

Usage:
    from db import BreathDB
    db = BreathDB("/path/to/data/dir")
    db.sync_from_json()   # Import latest JSON → SQLite
    db.sync_to_json()     # Export SQLite → JSON files
    db.save_state(data)   # Direct write to both SQLite + JSON
"""

import json
import os
import sqlite3

SCHEMA_VERSION = 1

SCHEMA = """
CREATE TABLE IF NOT EXISTS kv (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS history (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    date        TEXT NOT NULL,
    start       TEXT,
    end_time    TEXT,
    duration_min INTEGER,
    prompts     INTEGER,
    breaks      INTEGER,
    nudges_fired INTEGER,
    peak_velocity INTEGER,
    frustration_events INTEGER,
    score       INTEGER,
    raw_json    TEXT,
    created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_history_date ON history(date);

CREATE TABLE IF NOT EXISTS schema_version (
    version INTEGER PRIMARY KEY
);
"""

# JSON files that map to kv table entries
KV_FILES = {
    "state": "state.json",
    "creature": "creature.json",
    "config": "config.json",
}


class BreathDB:
    def __init__(self, data_dir: str):
        self.data_dir = data_dir
        self.db_path = os.path.join(data_dir, "breath.db")
        self._conn = None
        self._ensure_schema()

    @property
    def conn(self) -> sqlite3.Connection:
        if self._conn is None:
            self._conn = sqlite3.connect(self.db_path)
            self._conn.row_factory = sqlite3.Row
            self._conn.execute("PRAGMA journal_mode=WAL")
            self._conn.execute("PRAGMA busy_timeout=3000")
        return self._conn

    def _ensure_schema(self):
        c = self.conn
        c.executescript(SCHEMA)
        row = c.execute(
            "SELECT version FROM schema_version ORDER BY version DESC LIMIT 1"
        ).fetchone()
        if not row:
            c.execute(
                "INSERT INTO schema_version (version) VALUES (?)", (SCHEMA_VERSION,)
            )
        c.commit()

    def close(self):
        if self._conn:
            self._conn.close()
            self._conn = None

    # --- KV operations (state, creature, config) ---

    def get_kv(self, key: str) -> dict | None:
        row = self.conn.execute(
            "SELECT value FROM kv WHERE key = ?", (key,)
        ).fetchone()
        if row:
            try:
                return json.loads(row["value"])
            except json.JSONDecodeError:
                return None
        return None

    def set_kv(self, key: str, data: dict):
        value = json.dumps(data)
        self.conn.execute(
            "INSERT INTO kv (key, value, updated_at) VALUES (?, ?, CURRENT_TIMESTAMP) "
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = CURRENT_TIMESTAMP",
            (key, value),
        )
        self.conn.commit()

    # --- History operations ---

    def append_history(self, entry: dict):
        self.conn.execute(
            """INSERT INTO history (date, start, end_time, duration_min, prompts, breaks,
               nudges_fired, peak_velocity, frustration_events, score, raw_json)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                entry.get("date"),
                entry.get("start"),
                entry.get("end"),
                entry.get("duration_min"),
                entry.get("prompts"),
                entry.get("breaks"),
                entry.get("nudges_fired"),
                entry.get("peak_velocity"),
                entry.get("frustration_events"),
                entry.get("score"),
                json.dumps(entry),
            ),
        )
        self.conn.commit()

    def get_history(self, days: int = 14) -> list[dict]:
        rows = self.conn.execute(
            "SELECT raw_json FROM history ORDER BY date DESC, id DESC LIMIT ?",
            (days * 10,),  # ~10 sessions per day max
        ).fetchall()
        result = []
        for row in rows:
            try:
                result.append(json.loads(row["raw_json"]))
            except (json.JSONDecodeError, TypeError):
                pass
        result.reverse()
        return result

    # --- Sync: JSON files <-> SQLite ---

    def sync_from_json(self):
        """Import JSON files into SQLite (bash hooks may have updated them)."""
        for key, filename in KV_FILES.items():
            path = os.path.join(self.data_dir, filename)
            if not os.path.isfile(path):
                continue
            try:
                with open(path) as f:
                    data = json.load(f)
                # Only update if JSON is newer or DB is empty
                existing = self.get_kv(key)
                if data != existing:
                    self.set_kv(key, data)
            except (json.JSONDecodeError, OSError):
                pass

        # Sync history.jsonl → SQLite (append new entries)
        history_path = os.path.join(self.data_dir, "history.jsonl")
        if os.path.isfile(history_path):
            db_count = self.conn.execute(
                "SELECT COUNT(*) as c FROM history"
            ).fetchone()["c"]
            try:
                with open(history_path) as f:
                    lines = [
                        l.strip() for l in f.readlines() if l.strip()
                    ]
                if len(lines) > db_count:
                    # Append only new entries
                    for line in lines[db_count:]:
                        try:
                            entry = json.loads(line)
                            self.append_history(entry)
                        except json.JSONDecodeError:
                            pass
            except OSError:
                pass

    def sync_to_json(self):
        """Export SQLite data back to JSON files (restore after data loss)."""
        for key, filename in KV_FILES.items():
            data = self.get_kv(key)
            if data is None:
                continue
            path = os.path.join(self.data_dir, filename)
            tmp = path + ".tmp"
            with open(tmp, "w") as f:
                json.dump(data, f, indent=2)
            os.replace(tmp, path)

        # Export history
        entries = self.get_history(days=365)
        if entries:
            path = os.path.join(self.data_dir, "history.jsonl")
            tmp = path + ".tmp"
            with open(tmp, "w") as f:
                for entry in entries:
                    f.write(json.dumps(entry) + "\n")
            os.replace(tmp, path)

    def restore_if_needed(self):
        """If JSON files are missing but DB has data, restore them."""
        restored = []
        for key, filename in KV_FILES.items():
            path = os.path.join(self.data_dir, filename)
            if not os.path.isfile(path):
                data = self.get_kv(key)
                if data:
                    tmp = path + ".tmp"
                    with open(tmp, "w") as f:
                        json.dump(data, f, indent=2)
                    os.replace(tmp, path)
                    restored.append(filename)

        history_path = os.path.join(self.data_dir, "history.jsonl")
        if not os.path.isfile(history_path):
            entries = self.get_history(days=365)
            if entries:
                tmp = history_path + ".tmp"
                with open(tmp, "w") as f:
                    for entry in entries:
                        f.write(json.dumps(entry) + "\n")
                os.replace(tmp, history_path)
                restored.append("history.jsonl")

        return restored

    # --- Convenience: save + sync ---

    def save_state(self, data: dict):
        """Write state to both SQLite and JSON."""
        self.set_kv("state", data)
        self._write_json("state.json", data)

    def save_creature(self, data: dict):
        """Write creature to both SQLite and JSON."""
        self.set_kv("creature", data)
        self._write_json("creature.json", data)

    def save_config(self, data: dict):
        """Write config to both SQLite and JSON."""
        self.set_kv("config", data)
        self._write_json("config.json", data)

    def _write_json(self, filename: str, data: dict):
        path = os.path.join(self.data_dir, filename)
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(data, f, indent=2)
        os.replace(tmp, path)
