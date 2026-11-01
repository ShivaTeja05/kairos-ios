"""The kairos-mesh hub: the shared brain and the relay, as a small FastAPI app.

    .venv/bin/uvicorn mesh.app:app --port 8778            # this Mac only
    scripts/kairos up                                     # also your tailnet, through `tailscale serve` (HTTPS)

Joining:
- "This computer" (anything connecting from 127.0.0.1 to http://127.0.0.1 or http://localhost, with no forwarding
  headers) joins by itself as the Mac. The Mac's node and the Mac's browser page share that one identity, so turns
  said on the Mac are tagged "MacBook".
- Any other device joins with a 6-digit pairing code made on a device that already joined. Each code works once and
  lasts 10 minutes.

Every route except /, /api/hello and joining needs `Authorization: Bearer <device token>`.

Who can reach it at all:
- Only these names in the Host header: 127.0.0.1, localhost, [::1], *.ts.net, and any in KAIROS_MESH_HOSTS
  (comma-separated). To use it over the Wi-Fi or the USB cable with --host 0.0.0.0, list every name or address the
  iPhone uses for the Mac, e.g. KAIROS_MESH_HOSTS=my-mac.local,192.168.1.20. Anything else gets
  400 "Invalid host header".
- Never through Tailscale Funnel (the public internet).
- With KAIROS_MESH_OWNER=<your Tailscale login>, only that person's devices through `tailscale serve`.
"""
from __future__ import annotations

import ipaddress
import logging
import os
import platform
import socket
import subprocess
from pathlib import Path

import segno
from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel, Field
from starlette.datastructures import Headers
from starlette.middleware.trustedhost import TrustedHostMiddleware

from .brain import Brain
from .store import MAX_ANSWER, MAX_WAIT, MAX_WORDS, MeshError, Store, db_path
from .tailnet import pair_link, tailnet_url

DB_PATH = db_path()
WEB_DIR = Path(__file__).resolve().parent.parent / "web"
# Headers a proxy adds. A request carrying any of them came through a tunnel or `tailscale serve`, even though it
# arrives from loopback, so it is never "this computer".
FORWARDING_HEADERS = ("x-forwarded-for", "forwarded", "via", "x-forwarded-host", "x-forwarded-proto",
                      "tailscale-user-login")
LOCAL_NAMES = ("127.0.0.1", "localhost", "::1")  # how the Mac's node and its browser page address the hub

log = logging.getLogger("uvicorn.error")  # uvicorn prints this logger's info lines
app = FastAPI(title="kairos-mesh", version="0.1", docs_url=None, redoc_url=None, openapi_url=None)
store = Store(DB_PATH)
brain = Brain(store)


def allowed_hosts() -> list[str]:
    """Host names the hub answers to. Starlette keeps the brackets on IPv6, so it's "[::1]", not "::1"."""
    extra = [h.strip() for h in os.environ.get("KAIROS_MESH_HOSTS", "").split(",") if h.strip()]
    return ["127.0.0.1", "localhost", "[::1]", "*.ts.net", *extra]


_logins_seen: set[str] = set()


def note_login(login: str, owner: str) -> None:
    """Say once per Tailscale login whether tailnet requests carry one, so the owner can check before turning on
    KAIROS_MESH_OWNER. Logs the login name only, never a token."""
    if login in _logins_seen or len(_logins_seen) > 100:
        return
    _logins_seen.add(login)
    if login:
        log.info("tailnet request from Tailscale user %s (owner check: %s)", login, owner or "off")
    else:
        log.info("tailnet request with no Tailscale-User-Login (a tagged device, or not through tailscale serve); "
                 "owner check: %s", owner or "off")


def refusal(headers: Headers) -> str | None:
    """Why a request is turned away before it reaches any route, or None to let it in."""
    if "tailscale-funnel-request" in headers:
        return "Kairos is never shared on the public internet."
    if "x-forwarded-for" not in headers:
        return None
    login = headers.get("tailscale-user-login", "").strip()
    owner = os.environ.get("KAIROS_MESH_OWNER", "").strip()
    note_login(login, owner)
    if owner and login.casefold() != owner.casefold():
        return "This hub only answers its owner's devices."
    return None


class Gate:
    """Turns away Funnel requests, and (with KAIROS_MESH_OWNER set) tailnet requests from anyone but the owner."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        why = refusal(Headers(scope=scope)) if scope["type"] == "http" else None
        if why:
            await JSONResponse({"detail": why}, status_code=403)(scope, receive, send)
            return
        await self.app(scope, receive, send)


app.add_middleware(Gate)
app.add_middleware(TrustedHostMiddleware, allowed_hosts=allowed_hosts())  # added last, so it runs first


def use_store(new: Store, new_brain: Brain | None = None) -> None:
    """Point the app at another database (tests)."""
    global store, brain
    store, brain = new, new_brain or Brain(new)


def client_ip(request: Request):
    raw = os.environ.get("KAIROS_MESH_TEST_CLIENT_IP") or (request.client.host if request.client else "")
    try:
        return ipaddress.ip_address(raw)
    except ValueError:
        return None


def from_this_computer(request: Request) -> bool:
    """From loopback, addressed to this Mac's own name, with no proxy headers. A tunnel looks like loopback but adds
    forwarding headers; a raw TCP forward adds none, but the device on the far end asks for its own name for the hub
    (mac.tailnet.ts.net), not localhost."""
    ip = client_ip(request)
    forwarded = any(h in request.headers for h in FORWARDING_HEADERS)
    local_name = request.url.hostname in LOCAL_NAMES
    return bool(ip and ip.is_loopback and local_name and not forwarded)


def qr_svg(text: str) -> str:
    """A QR code as inline SVG, black on white so it scans on a dark page too."""
    return segno.make(text, error="m").svg_inline(scale=5, border=4, dark="#000", light="#fff")


def computer_name() -> str:
    """The friendly name ("Shiva's MacBook Pro"), not the network hostname ("Sams-MacBook-Pro")."""
    if platform.system() == "Darwin":
        try:
            name = subprocess.run(["scutil", "--get", "ComputerName"], capture_output=True, text=True,
                                  timeout=3).stdout.strip()
            if name:
                return name.replace("’", "'")
        except (OSError, subprocess.TimeoutExpired):
            pass
    return socket.gethostname().split(".")[0] or "This computer"


def call(fn, *args, **kwargs):
    try:
        return fn(*args, **kwargs)
    except MeshError as e:
        raise HTTPException(e.status, str(e))


def me(authorization: str = Header(default="")) -> dict:
    dev = store.device_by_token(authorization.removeprefix("Bearer ").strip())
    if not dev:
        raise HTTPException(401, "Unknown device. Join first (this computer joins by itself; others need a code).")
    return dev


# ---------- joining ----------

class JoinIn(BaseModel):
    name: str = Field(default="", max_length=60)
    platform: str | None = Field(default=None, max_length=30)
    code: str | None = Field(default=None, max_length=12)


@app.get("/api/hello")
def hello():
    return {"hub": "kairos-mesh", "version": app.version}


@app.post("/api/join")
def join(body: JoinIn, request: Request):
    if body.code:
        dev, token = call(store.pair, body.code, body.name or "New device", body.platform)
    elif from_this_computer(request):
        name = body.name or computer_name()
        dev, token = store.this_computer(name, body.platform or platform.system().lower().replace("darwin", "macos"))
    else:
        raise HTTPException(403, "Not this computer: join with a pairing code from a device that already joined.")
    return {"device": dev, "token": token}


@app.post("/api/pair")
def pair_code(dev: dict = Depends(me)):
    """A one-time code, and when the hub has a tailnet address, a link and QR code the iPhone's Camera can open."""
    made = store.new_pair_code(dev["id"])
    hub = tailnet_url()
    link = pair_link(hub, made["code"])
    return {**made, "hub": hub, "link": link, "qr_svg": qr_svg(link) if link else None}


@app.get("/api/devices")
def devices(dev: dict = Depends(me)):
    return {"devices": store.devices(), "you": dev["id"]}


@app.delete("/api/devices/{device_id}")
def remove(device_id: str, dev: dict = Depends(me)):
    if not dev["this_computer"]:
        raise HTTPException(403, "Remove devices from the hub computer.")
    if not store.remove_device(device_id, dev["id"]):
        raise HTTPException(404, "No such device.")
    return {"removed": device_id}


# ---------- cards and tasks ----------

class CardIn(BaseModel):
    agent: str | None = Field(default=None, max_length=80)
    skills: list[dict] = Field(default_factory=list, max_length=200)
    state: dict = Field(default_factory=dict)


class TaskIn(BaseModel):
    to: str = Field(min_length=1, max_length=120)
    words: str = Field(min_length=1, max_length=MAX_WORDS)
    wait: float = Field(default=0, ge=0, le=MAX_WAIT)
    expires_in: float = Field(default=600, ge=30, le=3600)


class TaskUpdateIn(BaseModel):
    status: str | None = None
    progress: str | None = Field(default=None, max_length=400)
    answer: str | None = Field(default=None, max_length=MAX_ANSWER)


@app.post("/api/card")
def card(body: CardIn, dev: dict = Depends(me)):
    return store.set_card(dev["id"], body.agent, body.skills, body.state)


@app.post("/api/tasks")
def new_task(body: TaskIn, dev: dict = Depends(me)):
    task = call(store.create_task, dev["id"], body.to, body.words, body.expires_in)
    if body.wait:
        task = call(store.get_task, task["id"], body.wait) | {"target_online": task["target_online"]}
    return task


@app.get("/api/tasks")
def board(limit: int = 20, dev: dict = Depends(me)):
    return {"tasks": store.tasks(limit)}


@app.get("/api/tasks/next")
def next_task(wait: float = 0, dev: dict = Depends(me)):
    return {"task": call(store.next_task, dev["id"], wait)}


@app.post("/api/tasks/{task_id}/update")
def update_task(task_id: str, body: TaskUpdateIn, dev: dict = Depends(me)):
    return call(store.update_task, dev["id"], task_id, body.status, body.progress, body.answer)


@app.post("/api/tasks/{task_id}/cancel")
def cancel_task(task_id: str, dev: dict = Depends(me)):
    return call(store.cancel_task, dev["id"], task_id)


@app.get("/api/tasks/{task_id}")
def get_task(task_id: str, wait: float = 0, dev: dict = Depends(me)):
    return call(store.get_task, task_id, wait)


# ---------- the shared brain ----------

class TurnIn(BaseModel):
    role: str = Field(pattern="^(user|assistant)$")
    text: str = Field(min_length=1, max_length=2000)


class AskIn(BaseModel):
    text: str = Field(min_length=1, max_length=2000)
    wait: float = Field(default=10, ge=0, le=MAX_WAIT)


@app.post("/api/turns")
def add_turn(body: TurnIn, dev: dict = Depends(me)):
    """For a device that talks with the person itself (e.g. the iPhone app answering locally): keep the shared
    conversation complete."""
    return call(store.add_turn, dev["id"], body.role, body.text)


@app.get("/api/context")
def context(dev: dict = Depends(me)):
    from .brain import build_context
    return {"for": dev["name"], "text": build_context(store, dev["id"])}


@app.get("/api/state")
def state(dev: dict = Depends(me)):
    return {"you": dev, "devices": store.devices(), "turns": store.turns(40), "tasks": store.tasks(20)}


@app.post("/api/ask")
def ask(body: AskIn, dev: dict = Depends(me)):
    return call(brain.ask, dev, body.text, body.wait)


@app.get("/api/log/verify")
def verify(dev: dict = Depends(me)):
    return store.verify_log()


# ---------- the page ----------

@app.get("/", include_in_schema=False)
def index():
    return FileResponse(WEB_DIR / "index.html")
