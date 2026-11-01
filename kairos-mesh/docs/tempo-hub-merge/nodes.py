"""Any device -> any device: the hub hands a task to the device that should do it, and the answer back.

A node is one of the person's devices that runs an agent: the Kairos app on an iPhone, agent/node.py on a Mac,
Windows or Linux computer. It says what it can do (announce), then keeps one request open for work (next_task,
a long-poll). Any of the person's other devices (a browser on an Android phone, a Windows laptop, the Conductor)
can hand a node a task in plain words and wait for its answer.

The hub only routes. Each node runs the task through its own agent and its own safety rules (on the iPhone:
SafetyGate, OwnerPolicy and Face ID; on a computer: node.py's short list of safe actions), so nothing sent here
can make a device do what its owner's rules don't allow. Tasks never cross from one person's devices to another's.

Every task is written to the event log as hub.node_task (vault class: the person's own devices see it; ask-only
callers and remote models don't), so "what did my devices do for each other today?" has an answer.
"""
from __future__ import annotations

import json
import secrets
import threading
from datetime import datetime, timedelta, timezone
from typing import Any, Callable

from . import db

SCHEMA = """
CREATE TABLE IF NOT EXISTS nodes (
  device_id TEXT PRIMARY KEY,
  person_id TEXT NOT NULL,
  agent TEXT,
  skills TEXT NOT NULL DEFAULT '[]',
  announced_utc TEXT NOT NULL,
  polled_utc TEXT
);
CREATE TABLE IF NOT EXISTS node_tasks (
  id TEXT PRIMARY KEY,
  person_id TEXT NOT NULL,
  from_device TEXT NOT NULL,
  to_device TEXT NOT NULL,
  words TEXT NOT NULL,
  status TEXT NOT NULL,
  answer TEXT,
  steps TEXT NOT NULL DEFAULT '[]',
  created_utc TEXT NOT NULL,
  delivered_utc TEXT,
  finished_utc TEXT,
  expires_utc TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS node_tasks_to ON node_tasks(to_device, status, created_utc);
"""

ONLINE_SECONDS = 40      # a node re-polls at least every 25 s, so 40 s without a poll means it's gone
MAX_WAIT = 25.0          # longest a single long-poll (or a caller waiting for an answer) is held open
MAX_WORDS = 2000
MAX_ANSWER = 4000
MAX_SKILLS = 80
FINISHED = ("done", "refused", "failed", "expired")

_changed = threading.Condition()  # notified on every new task and every result; waiters re-check their own rows
_ready: set[str] = set()


class NodeError(Exception):
    """A request the hub refuses, with the HTTP status the route should answer."""

    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status


def _c():
    c = db.conn()
    key = str(db.DB_PATH)
    if key not in _ready:
        c.executescript(SCHEMA)
        _ready.add(key)
    return c


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _iso(dt: datetime) -> str:
    return dt.isoformat(timespec="seconds").replace("+00:00", "Z")


def _parse(s: str | None) -> datetime | None:
    return datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None


def _clean(s: Any, n: int) -> str:
    return db.clean_str(str(s or ""))[:n].strip()


def _online(row) -> bool:
    polled = _parse(row["polled_utc"]) if row else None
    return bool(polled and (_now() - polled).total_seconds() <= ONLINE_SECONDS)


def _devices(person_id: str) -> dict[str, dict]:
    return {d["id"]: d for d in db.list_devices(person_id)}


def _who(devices: dict, device_id: str) -> dict:
    d = devices.get(device_id) or {}
    return {"id": device_id, "name": d.get("name") or "a removed device", "platform": d.get("platform"),
            "kind": d.get("kind")}


def _view(row, devices: dict) -> dict:
    return {"id": row["id"], "from": _who(devices, row["from_device"]), "to": _who(devices, row["to_device"]),
            "words": row["words"], "status": row["status"], "answer": row["answer"],
            "steps": json.loads(row["steps"] or "[]"), "created": row["created_utc"],
            "delivered": row["delivered_utc"], "finished": row["finished_utc"], "expires": row["expires_utc"]}


def _expire(person_id: str) -> None:
    c = _c()
    c.execute("UPDATE node_tasks SET status='expired', finished_utc=? WHERE person_id=? "
              "AND status IN ('queued','delivered') AND expires_utc < ?", (_iso(_now()), person_id, _iso(_now())))
    c.commit()


# ---------- what each node can do ----------

def announce(dev: dict, agent: str | None, skills: list) -> dict:
    """A device says it runs an agent and what that agent can do (skills: [{name, summary}])."""
    clean = []
    for s in (skills or [])[:MAX_SKILLS]:
        if isinstance(s, dict) and _clean(s.get("name"), 60):
            clean.append({"name": _clean(s.get("name"), 60), "summary": _clean(s.get("summary"), 200)})
    now = _iso(_now())
    c = _c()
    c.execute("INSERT INTO nodes (device_id, person_id, agent, skills, announced_utc, polled_utc) "
              "VALUES (?,?,?,?,?,?) ON CONFLICT(device_id) DO UPDATE SET agent=excluded.agent, "
              "skills=excluded.skills, announced_utc=excluded.announced_utc, polled_utc=excluded.polled_utc",
              (dev["id"], dev["person_id"], _clean(agent, 80) or None, json.dumps(clean), now, now))
    c.commit()
    return {"device_id": dev["id"], "agent": _clean(agent, 80) or None, "skills": len(clean), "online": True}


def list_nodes(person_id: str, me: str) -> list[dict]:
    """Every device of this person, marking which ones run an agent and are reachable right now."""
    rows = {r["device_id"]: r for r in _c().execute("SELECT * FROM nodes WHERE person_id=?", (person_id,))}
    out = []
    for d in _devices(person_id).values():
        r = rows.get(d["id"])
        out.append({"device_id": d["id"], "name": d["name"], "platform": d.get("platform"), "kind": d.get("kind"),
                    "you": d["id"] == me, "node": r is not None, "online": _online(r),
                    "agent": r["agent"] if r else None,
                    "skills": json.loads(r["skills"]) if r else [], "last_seen": d.get("last_seen_at")})
    out.sort(key=lambda n: (not n["online"], not n["node"], n["name"].lower()))
    return out


def online(person_id: str, device_id: str) -> bool:
    return _online(_c().execute("SELECT polled_utc FROM nodes WHERE device_id=? AND person_id=?",
                                (device_id, person_id)).fetchone())


def find(person_id: str, name_or_id: str) -> str | None:
    """A node's device id from its id or its name (case-insensitive)."""
    rows = _c().execute("SELECT device_id FROM nodes WHERE person_id=?", (person_id,)).fetchall()
    ids = {r["device_id"] for r in rows}
    devices = _devices(person_id)
    if name_or_id in ids and name_or_id in devices:
        return name_or_id
    want = (name_or_id or "").strip().casefold()
    named = [i for i in ids if i in devices and devices[i]["name"].casefold() == want]
    return named[0] if len(named) == 1 else None


# ---------- the queue ----------

def submit(dev: dict, to: str, words: str, expires_in: float, log: Callable) -> dict:
    """Queue a task for one of this person's nodes. It waits until that node next polls (or expires)."""
    words = _clean(words, MAX_WORDS)
    if not words:
        raise NodeError(422, "Say what the device should do.")
    target = find(dev["person_id"], to)
    if not target:
        raise NodeError(404, "That isn't one of your devices running Kairos.")
    now = _now()
    task_id = "t_" + secrets.token_urlsafe(9)
    expires = now + timedelta(seconds=max(30.0, min(float(expires_in or 300), 3600.0)))
    c = _c()
    c.execute("INSERT INTO node_tasks (id, person_id, from_device, to_device, words, status, created_utc, expires_utc) "
              "VALUES (?,?,?,?,?,'queued',?,?)", (task_id, dev["person_id"], dev["id"], target, words, _iso(now),
                                                   _iso(expires)))
    c.commit()
    devices = _devices(dev["person_id"])
    log(dev, "hub.node_task", {"task": task_id, "status": "queued", "from": _who(devices, dev["id"])["name"],
                               "to": _who(devices, target)["name"], "words": words[:200]})
    with _changed:
        _changed.notify_all()
    return {**get(dev, task_id), "target_online": online(dev["person_id"], target)}


def next_task(dev: dict, wait: float) -> dict | None:
    """For the node itself: the oldest task waiting for it, held open up to `wait` seconds if there's none yet."""
    c = _c()
    if not c.execute("SELECT 1 FROM nodes WHERE device_id=?", (dev["id"],)).fetchone():
        raise NodeError(409, "Announce this device as a node first.")
    deadline = _now() + timedelta(seconds=max(0.0, min(float(wait or 0), MAX_WAIT)))
    while True:
        c = _c()
        c.execute("UPDATE nodes SET polled_utc=? WHERE device_id=?", (_iso(_now()), dev["id"]))
        c.commit()
        _expire(dev["person_id"])
        row = _c().execute("SELECT * FROM node_tasks WHERE to_device=? AND status='queued' "
                           "ORDER BY created_utc LIMIT 1", (dev["id"],)).fetchone()
        if row:
            c = _c()
            took = c.execute("UPDATE node_tasks SET status='delivered', delivered_utc=? WHERE id=? AND status='queued'",
                             (_iso(_now()), row["id"])).rowcount
            c.commit()
            if took:  # another poll from the same device may have taken it first
                devices = _devices(dev["person_id"])
                return {"id": row["id"], "words": row["words"], "from": _who(devices, row["from_device"]),
                        "expires": row["expires_utc"]}
            continue
        left = (deadline - _now()).total_seconds()
        if left <= 0:
            return None
        with _changed:
            _changed.wait(timeout=min(left, 5.0))


def finish(dev: dict, task_id: str, status: str, answer: str, steps: list, log: Callable) -> dict:
    """For the node that was given the task: its outcome, in words the asker can be shown or told."""
    if status not in ("done", "refused", "failed"):
        raise NodeError(422, "status must be done, refused or failed")
    c = _c()
    row = c.execute("SELECT * FROM node_tasks WHERE id=? AND to_device=?", (task_id, dev["id"])).fetchone()
    if not row:
        raise NodeError(404, "No such task for this device.")
    if row["status"] in FINISHED:
        raise NodeError(409, f"That task is already {row['status']}.")
    clean_steps = [_clean(s, 200) for s in (steps or [])[:20] if _clean(s, 200)]
    now = _now()
    c.execute("UPDATE node_tasks SET status=?, answer=?, steps=?, finished_utc=? WHERE id=?",
              (status, _clean(answer, MAX_ANSWER), json.dumps(clean_steps), _iso(now), task_id))
    c.commit()
    devices = _devices(dev["person_id"])
    took = (now - _parse(row["created_utc"])).total_seconds()
    log(dev, "hub.node_task", {"task": task_id, "status": status, "from": _who(devices, row["from_device"])["name"],
                               "to": _who(devices, dev["id"])["name"], "seconds": round(took, 1)})
    with _changed:
        _changed.notify_all()
    return get(dev, task_id)


def get(dev: dict, task_id: str, wait: float = 0) -> dict:
    """A task, for the device that sent it or the device doing it; optionally wait for it to finish."""
    deadline = _now() + timedelta(seconds=max(0.0, min(float(wait or 0), MAX_WAIT)))
    while True:
        _expire(dev["person_id"])
        row = _c().execute("SELECT * FROM node_tasks WHERE id=? AND person_id=? AND (from_device=? OR to_device=?)",
                           (task_id, dev["person_id"], dev["id"], dev["id"])).fetchone()
        if not row:
            raise NodeError(404, "No such task.")
        left = (deadline - _now()).total_seconds()
        if row["status"] in FINISHED or left <= 0:
            return _view(row, _devices(dev["person_id"]))
        with _changed:
            _changed.wait(timeout=min(left, 5.0))


def recent(dev: dict, limit: int = 20) -> list[dict]:
    """The latest tasks this device sent or was given, newest first."""
    _expire(dev["person_id"])
    rows = _c().execute("SELECT * FROM node_tasks WHERE person_id=? AND (from_device=? OR to_device=?) "
                        "ORDER BY created_utc DESC LIMIT ?", (dev["person_id"], dev["id"], dev["id"],
                                                             max(1, min(int(limit), 100)))).fetchall()
    devices = _devices(dev["person_id"])
    return [_view(r, devices) for r in rows]
