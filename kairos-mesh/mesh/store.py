"""Everything the shared brain remembers, in one SQLite file.

- devices:    the person's devices. "This computer" (the Mac running the hub) joins by itself; any other device
              joins with a one-time pairing code shown on a device that already joined.
- cards:      what each device's agent can do (its skills) and its state, A2A Agent Card style.
- tasks:      work handed from one device to another, with A2A-style states. The device doing the work moves it
              along; the device that asked can watch it.
- turns:      ONE conversation across every device, each turn tagged with the device it was said on. This is what
              lets the Mac answer "how's my flight search going?" about a task started on the iPhone.
- log:        every change, hash-chained, so "what did my devices do for each other today?" has a checkable answer.

One person per hub for now (family sharing comes later). Use one Store per database file; it is thread-safe.
"""
from __future__ import annotations

import hashlib
import json
import os
import secrets
import sqlite3
import threading
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

SCHEMA = """
CREATE TABLE IF NOT EXISTS devices (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  platform TEXT,
  this_computer INTEGER NOT NULL DEFAULT 0,
  created TEXT NOT NULL,
  last_seen TEXT,
  removed INTEGER NOT NULL DEFAULT 0
);
-- One device can have several logins: on the Mac, the agent node and the browser page are both "this computer".
CREATE TABLE IF NOT EXISTS tokens (
  token_hash TEXT PRIMARY KEY,
  device_id TEXT NOT NULL,
  created TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS pair_codes (
  code_hash TEXT PRIMARY KEY,
  created_by TEXT NOT NULL,
  expires TEXT NOT NULL,
  used INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS cards (
  device_id TEXT PRIMARY KEY,
  agent TEXT,
  skills TEXT NOT NULL DEFAULT '[]',
  state TEXT NOT NULL DEFAULT '{}',
  updated TEXT NOT NULL,
  polled TEXT
);
CREATE TABLE IF NOT EXISTS tasks (
  id TEXT PRIMARY KEY,
  from_device TEXT NOT NULL,
  to_device TEXT NOT NULL,
  words TEXT NOT NULL,
  status TEXT NOT NULL,
  progress TEXT NOT NULL DEFAULT '[]',
  answer TEXT,
  created TEXT NOT NULL,
  updated TEXT NOT NULL,
  expires TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS tasks_to ON tasks(to_device, status, created);
CREATE TABLE IF NOT EXISTS turns (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  device_id TEXT NOT NULL,
  role TEXT NOT NULL,
  text TEXT NOT NULL,
  created TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS log (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL,
  device_id TEXT,
  payload TEXT NOT NULL,
  created TEXT NOT NULL,
  prev_hash TEXT NOT NULL,
  hash TEXT NOT NULL
);
"""

# A2A task states. "input-required" means the device doing the work is waiting for its owner (e.g. Face ID).
STATES = ("submitted", "working", "input-required", "completed", "failed", "rejected", "canceled", "expired")
FINISHED = ("completed", "failed", "rejected", "canceled", "expired")
WORKER_MAY_SET = ("working", "input-required", "completed", "failed", "rejected")

ONLINE_SECONDS = 40       # a device re-polls at least every 25 s, so 40 s of silence means it's away
# A device that takes a task must say something about it (any update) within this time, or the task goes back in
# the queue. Otherwise a task handed to a long-poll whose device had just died (an app killed, Wi-Fi dropped) would
# sit "working" until it expired.
LEASE_SECONDS = 30
MAX_WAIT = 25.0           # longest a single long-poll (or a wait for an answer) is held open
MAX_WORDS = 2000
MAX_ANSWER = 4000
MAX_TURN = 2000
PAIR_CODE_SECONDS = 600
# Wrong pairing codes allowed across the whole hub per PAIR_CODE_SECONDS. A code is 1 in a million, so this caps a
# guesser at 20 tries per code's life, from any number of addresses (the hub may be reachable through a tunnel).
# The cost: someone guessing can hold up pairing for a few minutes. That's fine; pairing is rare.
MAX_WRONG_CODES = 20
GENESIS = "0" * 64
DEFAULT_DB = Path(__file__).resolve().parent.parent / "data" / "mesh.db"


def db_path() -> str:
    """The hub's database: KAIROS_MESH_DB, or data/mesh.db in this repo. The hub and `kairos pair` both use it."""
    return os.environ.get("KAIROS_MESH_DB", str(DEFAULT_DB))


class MeshError(Exception):
    """A request the hub refuses, with the HTTP status the route should answer."""

    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status


def now() -> datetime:
    return datetime.now(timezone.utc)


def iso(dt: datetime) -> str:
    return dt.isoformat(timespec="seconds").replace("+00:00", "Z")


def parse(s: str | None) -> datetime | None:
    return datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None


def hash_secret(s: str) -> str:
    return hashlib.sha256(s.encode()).hexdigest()


def clean(s: Any, n: int) -> str:
    """Printable text only, trimmed to n characters. Keeps newlines, tabs and the zero-width (non-)joiners that
    Telugu and Hindi spelling needs."""
    text = "".join(ch for ch in str(s or "") if ch in "\n\t‌‍" or ch.isprintable())
    return text[:n].strip()


class Store:
    def __init__(self, path: str | os.PathLike):
        self.path = str(path)
        Path(self.path).parent.mkdir(parents=True, exist_ok=True)
        self._local = threading.local()
        self._changed = threading.Condition()  # notified on every task change; waiters re-check their own rows
        self._log_lock = threading.Lock()
        self._wrong_codes: list[datetime] = []  # when recent wrong pairing codes were tried (memory only)
        self._wrong_lock = threading.Lock()
        c = self._c()
        c.executescript(SCHEMA)
        if "lease_until" not in {r["name"] for r in c.execute("PRAGMA table_info(tasks)")}:
            c.execute("ALTER TABLE tasks ADD COLUMN lease_until TEXT")  # databases made before leases existed
        c.commit()

    # ---------- plumbing ----------

    def _c(self) -> sqlite3.Connection:
        c = getattr(self._local, "conn", None)
        if c is None:
            c = sqlite3.connect(self.path, check_same_thread=False, timeout=10)
            c.row_factory = sqlite3.Row
            c.execute("PRAGMA journal_mode=WAL")
            self._local.conn = c
        if c.in_transaction:
            c.rollback()
        return c

    def _notify(self) -> None:
        with self._changed:
            self._changed.notify_all()

    def _wait(self, seconds: float) -> None:
        with self._changed:
            self._changed.wait(timeout=min(max(seconds, 0.0), 5.0))

    def log(self, kind: str, device_id: str | None, payload: dict) -> dict:
        """Append to the hash-chained log: each entry's hash covers the previous hash and its own content."""
        with self._log_lock:
            c = self._c()
            c.execute("BEGIN IMMEDIATE")  # another process (`kairos pair`) may append at the same moment
            last = c.execute("SELECT hash FROM log ORDER BY seq DESC LIMIT 1").fetchone()
            prev = last["hash"] if last else GENESIS
            created = iso(now())
            body = json.dumps(payload, sort_keys=True, ensure_ascii=False)
            h = hash_secret("|".join([prev, kind, device_id or "", created, body]))
            c.execute("INSERT INTO log (kind, device_id, payload, created, prev_hash, hash) VALUES (?,?,?,?,?,?)",
                      (kind, device_id, body, created, prev, h))
            c.commit()
            return {"kind": kind, "hash": h}

    def verify_log(self) -> dict:
        prev, n = GENESIS, 0
        for r in self._c().execute("SELECT * FROM log ORDER BY seq"):
            want = hash_secret("|".join([prev, r["kind"], r["device_id"] or "", r["created"], r["payload"]]))
            if r["prev_hash"] != prev or r["hash"] != want:
                return {"ok": False, "entries": n, "broken_at": r["seq"]}
            prev, n = r["hash"], n + 1
        return {"ok": True, "entries": n, "head": prev}

    # ---------- devices and pairing ----------

    def _new_token(self, device_id: str) -> str:
        token = "km_" + secrets.token_urlsafe(24)
        c = self._c()
        c.execute("INSERT INTO tokens (token_hash, device_id, created) VALUES (?,?,?)",
                  (hash_secret(token), device_id, iso(now())))
        c.commit()
        return token

    def _new_device(self, name: str, platform: str | None, this_computer: bool) -> tuple[dict, str]:
        did = "d_" + secrets.token_urlsafe(6)
        c = self._c()
        c.execute("INSERT INTO devices (id, name, platform, this_computer, created) VALUES (?,?,?,?,?)",
                  (did, clean(name, 60) or "Unnamed device", clean(platform, 30) or None, int(this_computer),
                   iso(now())))
        c.commit()
        self.log("device.joined", did, {"name": clean(name, 60), "platform": clean(platform, 30),
                                       "this_computer": this_computer})
        return self.device(did), self._new_token(did)

    def this_computer(self, name: str, platform: str | None) -> tuple[dict, str]:
        """The Mac running the hub: one device, and a new login for each program on it that joins."""
        dev = self.this_computer_device()
        if not dev:
            return self._new_device(name, platform, True)
        return dev, self._new_token(dev["id"])

    def this_computer_device(self) -> dict | None:
        """The Mac running the hub, if it has joined. Makes no login."""
        row = self._c().execute("SELECT id FROM devices WHERE this_computer=1 AND removed=0").fetchone()
        return self.device(row["id"]) if row else None

    def new_pair_code(self, created_by: str) -> dict:
        code = f"{secrets.randbelow(10**6):06d}"
        expires = now() + timedelta(seconds=PAIR_CODE_SECONDS)
        c = self._c()
        c.execute("INSERT OR REPLACE INTO pair_codes (code_hash, created_by, expires) VALUES (?,?,?)",
                  (hash_secret(code), created_by, iso(expires)))
        c.commit()
        self.log("pair.code", created_by, {"expires": iso(expires)})
        return {"code": code, "expires": iso(expires)}

    def pair(self, code: str, name: str, platform: str | None) -> tuple[dict, str]:
        """A new device joins with a code from a device that already joined. Each code works once."""
        with self._wrong_lock:
            since = now() - timedelta(seconds=PAIR_CODE_SECONDS)
            self._wrong_codes = [t for t in self._wrong_codes if t > since]
            if len(self._wrong_codes) >= MAX_WRONG_CODES:
                raise MeshError(429, "Too many wrong pairing codes. Wait 10 minutes, then make a new code.")
            c = self._c()
            took = c.execute("UPDATE pair_codes SET used=1 WHERE code_hash=? AND used=0 AND expires>=?",
                             (hash_secret(str(code).strip()), iso(now()))).rowcount
            c.commit()
            if not took:
                self._wrong_codes.append(now())
                if len(self._wrong_codes) == MAX_WRONG_CODES:
                    self.log("pair.locked", None, {"wrong_codes": MAX_WRONG_CODES})
                raise MeshError(403, "That pairing code is wrong, used or expired. Make a new one on a joined device.")
        return self._new_device(name, platform, False)

    def device(self, device_id: str) -> dict | None:
        r = self._c().execute("SELECT * FROM devices WHERE id=? AND removed=0", (device_id,)).fetchone()
        return self._device_view(r) if r else None

    def device_by_token(self, token: str) -> dict | None:
        if not token:
            return None
        r = self._c().execute("SELECT d.* FROM tokens t JOIN devices d ON d.id=t.device_id "
                              "WHERE t.token_hash=? AND d.removed=0", (hash_secret(token),)).fetchone()
        if not r:
            return None
        c = self._c()
        c.execute("UPDATE devices SET last_seen=? WHERE id=?", (iso(now()), r["id"]))
        c.commit()
        return self._device_view(r)

    def _device_view(self, r) -> dict:
        return {"id": r["id"], "name": r["name"], "platform": r["platform"],
                "this_computer": bool(r["this_computer"]), "last_seen": r["last_seen"]}

    def remove_device(self, device_id: str, by: str) -> bool:
        c = self._c()
        n = c.execute("UPDATE devices SET removed=1 WHERE id=? AND removed=0", (device_id,)).rowcount
        c.commit()
        if n:
            self.log("device.removed", by, {"device": device_id})
        return bool(n)

    # ---------- cards: what each device's agent can do ----------

    def set_card(self, device_id: str, agent: str | None, skills: list, state: dict | None) -> dict:
        clean_skills = []
        for s in (skills or [])[:100]:
            if isinstance(s, dict) and clean(s.get("name"), 60):
                clean_skills.append({"name": clean(s.get("name"), 60), "summary": clean(s.get("summary"), 200)})
        clean_state = {clean(k, 40): v for k, v in (state or {}).items()
                       if isinstance(v, (str, int, float, bool)) or v is None}
        t = iso(now())
        c = self._c()
        c.execute("INSERT INTO cards (device_id, agent, skills, state, updated, polled) VALUES (?,?,?,?,?,?) "
                  "ON CONFLICT(device_id) DO UPDATE SET agent=excluded.agent, skills=excluded.skills, "
                  "state=excluded.state, updated=excluded.updated, polled=excluded.polled",
                  (device_id, clean(agent, 80) or None, json.dumps(clean_skills), json.dumps(clean_state), t, t))
        c.commit()
        return {"device_id": device_id, "skills": len(clean_skills)}

    def devices(self) -> list[dict]:
        """Every device, with its card (if it runs an agent) and whether it's reachable right now."""
        cards = {r["device_id"]: r for r in self._c().execute("SELECT * FROM cards")}
        out = []
        for r in self._c().execute("SELECT * FROM devices WHERE removed=0 ORDER BY created"):
            card = cards.get(r["id"])
            polled = parse(card["polled"]) if card else None
            out.append({**self._device_view(r), "agent": card["agent"] if card else None,
                        "skills": json.loads(card["skills"]) if card else [],
                        "state": json.loads(card["state"]) if card else {},
                        "online": bool(polled and (now() - polled).total_seconds() <= ONLINE_SECONDS)})
        return out

    def find_device(self, name_or_id: str) -> dict | None:
        """A device that runs an agent, by id or by name (case-insensitive; 'iphone' matches "Shiva's iPhone")."""
        agents = [d for d in self.devices() if d["agent"]]
        for d in agents:
            if d["id"] == name_or_id:
                return d
        want = (name_or_id or "").strip().casefold()
        exact = [d for d in agents if d["name"].casefold() == want]
        if len(exact) == 1:
            return exact[0]
        partial = [d for d in agents if want and (want in d["name"].casefold() or want == (d["platform"] or ""))]
        return partial[0] if len(partial) == 1 else None

    # ---------- tasks ----------

    def _expire(self) -> None:
        c = self._c()
        t = iso(now())
        n = c.execute("UPDATE tasks SET status='expired', updated=? WHERE status IN ('submitted','working',"
                      "'input-required') AND expires<?", (t, t)).rowcount
        lost = [r["id"] for r in c.execute("SELECT id FROM tasks WHERE status='working' AND lease_until IS NOT NULL "
                                           "AND lease_until<?", (t,))]
        if lost:
            c.execute("UPDATE tasks SET status='submitted', lease_until=NULL, updated=? WHERE status='working' AND "
                      "lease_until IS NOT NULL AND lease_until<?", (t, t))
        c.commit()
        for task_id in lost:
            self.log("task.requeued", None, {"task": task_id, "why": "taken but never acknowledged"})
        if n or lost:
            self._notify()

    def _task_view(self, r, names: dict | None = None) -> dict:
        names = names or {d["id"]: d["name"] for d in self.devices()}
        return {"id": r["id"], "from": {"id": r["from_device"], "name": names.get(r["from_device"], "a removed device")},
                "to": {"id": r["to_device"], "name": names.get(r["to_device"], "a removed device")},
                "words": r["words"], "status": r["status"], "progress": json.loads(r["progress"]),
                "answer": r["answer"], "created": r["created"], "updated": r["updated"], "expires": r["expires"]}

    def create_task(self, from_device: str, to: str, words: str, expires_in: float = 600) -> dict:
        words = clean(words, MAX_WORDS)
        if not words:
            raise MeshError(422, "Say what the device should do.")
        target = self.find_device(to)
        if not target:
            raise MeshError(404, f"No device running Kairos is called {to!r}.")
        t = now()
        task_id = "t_" + secrets.token_urlsafe(8)
        expires = t + timedelta(seconds=max(30.0, min(float(expires_in or 600), 3600.0)))
        c = self._c()
        c.execute("INSERT INTO tasks (id, from_device, to_device, words, status, created, updated, expires) "
                  "VALUES (?,?,?,?,'submitted',?,?,?)", (task_id, from_device, target["id"], words, iso(t), iso(t),
                                                          iso(expires)))
        c.commit()
        self.log("task.submitted", from_device, {"task": task_id, "to": target["id"], "words": words[:200]})
        self._notify()
        return {**self.get_task(task_id), "target_online": target["online"]}

    def next_task(self, device_id: str, wait: float = 0) -> dict | None:
        """For a device's own agent: the oldest task waiting for it, held open up to `wait` seconds."""
        if not self._c().execute("SELECT 1 FROM cards WHERE device_id=?", (device_id,)).fetchone():
            raise MeshError(409, "Send this device's card first (POST /api/card).")
        deadline = now() + timedelta(seconds=max(0.0, min(float(wait or 0), MAX_WAIT)))
        while True:
            c = self._c()
            c.execute("UPDATE cards SET polled=? WHERE device_id=?", (iso(now()), device_id))
            c.commit()
            self._expire()
            r = self._c().execute("SELECT * FROM tasks WHERE to_device=? AND status='submitted' ORDER BY created "
                                  "LIMIT 1", (device_id,)).fetchone()
            if r:
                c = self._c()
                took = c.execute("UPDATE tasks SET status='working', updated=?, lease_until=? WHERE id=? AND "
                                 "status='submitted'", (iso(now()), iso(now() + timedelta(seconds=LEASE_SECONDS)),
                                                        r["id"])).rowcount
                c.commit()
                if took:
                    self.log("task.working", device_id, {"task": r["id"]})
                    self._notify()
                    return self.get_task(r["id"])
                continue
            left = (deadline - now()).total_seconds()
            if left <= 0:
                return None
            self._wait(left)

    def update_task(self, device_id: str, task_id: str, status: str | None = None, progress: str | None = None,
                    answer: str | None = None) -> dict:
        """For the device doing the work only: report progress, ask for the owner, or finish."""
        r = self._c().execute("SELECT * FROM tasks WHERE id=? AND to_device=?", (task_id, device_id)).fetchone()
        if not r:
            raise MeshError(404, "No such task for this device.")
        if r["status"] in FINISHED:
            raise MeshError(409, f"That task is already {r['status']}.")
        if status is not None and status not in WORKER_MAY_SET:
            raise MeshError(422, "status must be one of: " + ", ".join(WORKER_MAY_SET))
        steps = json.loads(r["progress"])
        line = clean(progress, 200)
        if line:
            steps = (steps + [{"at": iso(now()), "text": line}])[-30:]
        new_status = status or r["status"]
        new_answer = clean(answer, MAX_ANSWER) if answer is not None else r["answer"]
        c = self._c()
        c.execute("UPDATE tasks SET status=?, progress=?, answer=?, updated=?, lease_until=NULL WHERE id=?",
                  (new_status, json.dumps(steps), new_answer, iso(now()), task_id))  # any update acknowledges it
        c.commit()
        if status and status != r["status"]:
            self.log(f"task.{status}", device_id, {"task": task_id})
        self._notify()
        return self.get_task(task_id)

    def cancel_task(self, device_id: str, task_id: str) -> dict:
        """For the device that asked: stop a task that hasn't finished."""
        c = self._c()
        n = c.execute("UPDATE tasks SET status='canceled', updated=? WHERE id=? AND from_device=? AND status IN "
                      "('submitted','working','input-required')", (iso(now()), task_id, device_id)).rowcount
        c.commit()
        if not n:
            raise MeshError(409, "Only an unfinished task you asked for can be cancelled.")
        self.log("task.canceled", device_id, {"task": task_id})
        self._notify()
        return self.get_task(task_id)

    def get_task(self, task_id: str, wait: float = 0) -> dict:
        deadline = now() + timedelta(seconds=max(0.0, min(float(wait or 0), MAX_WAIT)))
        while True:
            self._expire()
            r = self._c().execute("SELECT * FROM tasks WHERE id=?", (task_id,)).fetchone()
            if not r:
                raise MeshError(404, "No such task.")
            left = (deadline - now()).total_seconds()
            if r["status"] in FINISHED or left <= 0:
                return self._task_view(r)
            self._wait(left)

    def tasks(self, limit: int = 20) -> list[dict]:
        """The task board: newest first."""
        self._expire()
        names = {d["id"]: d["name"] for d in self.devices()}
        rows = self._c().execute("SELECT * FROM tasks ORDER BY created DESC LIMIT ?", (max(1, min(int(limit), 100)),))
        return [self._task_view(r, names) for r in rows]

    # ---------- the one conversation across devices ----------

    def add_turn(self, device_id: str, role: str, text: str) -> dict:
        if role not in ("user", "assistant"):
            raise MeshError(422, "role must be user or assistant")
        text = clean(text, MAX_TURN)
        if not text:
            raise MeshError(422, "Empty turn.")
        c = self._c()
        cur = c.execute("INSERT INTO turns (device_id, role, text, created) VALUES (?,?,?,?)",
                        (device_id, role, text, iso(now())))
        c.commit()
        return {"seq": cur.lastrowid}

    def turns(self, limit: int = 20) -> list[dict]:
        names = {d["id"]: d["name"] for d in self.devices()}
        rows = self._c().execute("SELECT * FROM turns ORDER BY seq DESC LIMIT ?", (max(1, min(int(limit), 200)),))
        return [{"seq": r["seq"], "device": names.get(r["device_id"], "a removed device"), "device_id": r["device_id"],
                 "role": r["role"], "text": r["text"], "at": r["created"]} for r in reversed(rows.fetchall())]
