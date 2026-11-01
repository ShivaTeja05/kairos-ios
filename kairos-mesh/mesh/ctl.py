"""kairos: start, check and stop Kairos on this Mac, in plain words.

    scripts/kairos up         # Tailscale on, the hub shared on your tailnet, the hub and the Mac node running
    scripts/kairos status     # one line per check: "OK  ..." or "FIX ..." with what to do (changes nothing)
    scripts/kairos down       # stop the hub and the Mac node; Tailscale stays as it is
    scripts/kairos pair       # a pairing code, link and QR code for a new device
    scripts/kairos install    # start the hub and the Mac node at login (LaunchAgents)
    scripts/kairos uninstall  # remove those LaunchAgents

Running `up` twice changes nothing the second time. Nothing here runs `tailscale serve reset`.
"""
from __future__ import annotations

import os
import plistlib
import re
import signal
import socket
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import httpx

from .tailnet import (HUB_PORT, env_url, find_tailnet_url, foreground, hub_sites, pair_link, reaches_hub, site_url,
                      tailnet_url, tailscale_bin, tailscale_json, tcp_forwards)

REPO = Path(__file__).resolve().parent.parent
HUB = f"http://127.0.0.1:{HUB_PORT}"
OLLAMA = "http://127.0.0.1:11434"
MODEL = os.environ.get("KAIROS_MESH_MODEL", "qwen2.5:7b")
HUB_LABEL = "com.kairos.hub"
NODE_LABEL = "com.kairos.macnode"
# The hub is whatever listens on 8778 and runs this app. The node is a command line that starts with Python and
# runs `-m node.mac_node`, so a shell that merely mentions it (zsh -c '... -m node.mac_node ...') never matches.
HUB_APP = "mesh.app:app"
NODE_COMMAND = re.compile(r"\S*python[\d.]*(\s+-[^m\s]\S*)*\s+-m\s+node\.mac_node(\s|$)")
AGENTS = Path.home() / "Library" / "LaunchAgents"
LOGS = Path.home() / "Library" / "Logs"
# Settings the hub and the node read, copied into the LaunchAgents when they are set while you run install.
PASS_ON = ("KAIROS_MESH_OWNER", "KAIROS_MESH_HOSTS", "KAIROS_MESH_PUBLIC_URL", "KAIROS_MESH_DB", "KAIROS_MESH_MODEL",
           "KAIROS_MESH_MODEL_URL", "KAIROS_MESH_TZ", "KAIROS_NODE_MODEL")
KEY_WARNING_DAYS = 14

Line = tuple[bool, str]


def say(ok: bool, text: str) -> None:
    print(("OK  " if ok else "FIX ") + text, flush=True)


# ---------- what's running (read-only probes) ----------

def get_json(url: str, timeout: float = 3) -> dict | None:
    try:
        r = httpx.get(url, timeout=timeout)
        return r.json() if r.status_code == 200 else None
    except (httpx.HTTPError, ValueError):
        return None


def hub_answers() -> bool:
    return (get_json(HUB + "/api/hello") or {}).get("hub") == "kairos-mesh"


def read_output(command: list[str]) -> str:
    """What a read-only command prints, or "" when it is missing or slow."""
    try:
        return subprocess.run(command, capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def parse_ps(output: str) -> list[tuple[int, str]]:
    """(pid, command line) from `ps -o pid=,command=` output."""
    found = []
    for line in output.splitlines():
        pid, _, command = line.strip().partition(" ")
        if pid.isdigit():
            found.append((int(pid), command.strip()))
    return found


def processes() -> list[tuple[int, str]]:
    """(pid, command line) of each of this user's processes."""
    return parse_ps(read_output(["/bin/ps", "-U", str(os.getuid()), "-o", "pid=,command="]))


def cwd_of(pid: int) -> str | None:
    """The folder a process was started in (`lsof -Fn` prints it as "n/path")."""
    out = read_output(["/usr/sbin/lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"])
    return next((line[1:] for line in out.splitlines() if line.startswith("n")), None)


def is_node_command(command: str) -> bool:
    return bool(NODE_COMMAND.match(command))


def runs_this_repo(command: str, cwd: str | None, repo: Path = REPO) -> bool:
    """The program lives in this repo (a LaunchAgent's absolute path), or it was started in this repo's folder (how
    `.venv/bin/python -m node.mac_node` finds the code). A copy of Kairos elsewhere is left alone."""
    return command.startswith(f"{repo}/") or cwd == str(repo)


def node_pids() -> list[int]:
    """This repo's Mac node."""
    return [pid for pid, command in processes()
            if is_node_command(command) and runs_this_repo(command, cwd_of(pid), REPO)]


def listening_pids(port: int = HUB_PORT) -> list[int]:
    out = read_output(["/usr/sbin/lsof", "-nP", "-t", f"-iTCP:{port}", "-sTCP:LISTEN"])
    return [int(p) for p in out.split() if p.isdigit()]


def hub_pids() -> list[int]:
    """The hub: what listens on 8778, when it runs mesh.app (not something else that took the port). Its caffeinate
    wrapper ends by itself when the hub does."""
    commands = dict(processes())
    return [pid for pid in listening_pids() if HUB_APP in commands.get(pid, "")]


def port_in_use(port: int = HUB_PORT) -> bool:
    try:
        socket.create_connection(("127.0.0.1", port), timeout=1).close()
        return True
    except OSError:
        return False


def listener_names(lsof_output: str) -> list[str]:
    """Command names from `lsof -F c` output ("p123\\ncpython3.12\\n" -> ["python3.12"])."""
    return [line[1:] for line in lsof_output.splitlines() if line.startswith("c")]


def who_listens(port: int = HUB_PORT) -> str:
    out = read_output(["/usr/sbin/lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-F", "c"])
    return ", ".join(sorted(set(listener_names(out))))


# ---------- the checks: each takes what was read and gives one line ----------

def tailscale_state(ts: dict | None) -> str:
    return (ts or {}).get("BackendState") or "NoState"


def check_tailscale(ts: dict | None, installed: bool = True) -> Line:
    state = tailscale_state(ts)
    if not installed:
        return False, "Tailscale isn't installed: get it from https://tailscale.com/download, then sign in"
    if ts is None:
        return False, "Tailscale isn't answering: open the Tailscale app"
    if state == "Running":
        return True, f"Tailscale is on, signed in as {login_name(ts) or 'you'}"
    if state == "NeedsLogin" or ts.get("AuthURL"):
        return False, "Tailscale needs you to sign in: open the Tailscale app and sign in"
    if state == "NeedsMachineAuth":
        return False, "Tailscale is waiting for this Mac to be approved: approve it at https://login.tailscale.com/admin/machines"
    return False, "Tailscale is off: open the Tailscale app and turn it on (Connect)"


def login_name(ts: dict | None) -> str:
    ts = ts or {}
    me = str((ts.get("Self") or {}).get("UserID", ""))
    return ((ts.get("User") or {}).get(me) or {}).get("LoginName", "")


def cert_host(ts: dict | None) -> str | None:
    """This Mac's HTTPS name on the tailnet, e.g. mac.tail1234.ts.net."""
    domains = (ts or {}).get("CertDomains") or []
    return domains[0].lower() if domains else None


def check_https(ts: dict | None) -> Line:
    magic = ((ts or {}).get("CurrentTailnet") or {}).get("MagicDNSEnabled")
    host = cert_host(ts)
    if magic and host:
        return True, f"MagicDNS and HTTPS certificates are on: this Mac is {host}"
    return False, ("Turn on MagicDNS and HTTPS certificates for your tailnet: https://login.tailscale.com/admin/dns "
                   "(both are on that page)")


def funnel_sites(config: dict | None) -> list[str]:
    """Each "host:port" that a Serve config puts on the public internet with Funnel."""
    return [hp for hp, on in ((config or {}).get("AllowFunnel") or {}).items() if on]


def off_command(config: dict | None, port: str) -> str:
    """The Tailscale command that stops what Serve shares on one port."""
    tcp = ((config or {}).get("TCP") or {}).get(port) or {}
    if tcp.get("TCPForward"):
        kind = "tls-terminated-tcp" if tcp.get("TerminateTLS") else "tcp"
    else:
        kind = "https" if tcp.get("HTTPS") else "http"
    return f"tailscale serve --{kind}={port} off"


IN_A_TERMINAL = "stop the 'tailscale serve' or 'tailscale funnel' that is running in a terminal (Ctrl-C)"


def serve_is_right(serve: dict | None, host: str) -> bool:
    """Serve answers HTTPS on 443 for this Mac's name and sends "/" to the hub."""
    return f"{host}:443".lower() in [s.lower() for s in hub_sites(serve)]


def serve_needs_change(serve: dict | None, host: str) -> bool:
    """Whether `up` has to run `tailscale serve`: the hub isn't shared on 443, or Funnel is on there."""
    on_funnel = [s.lower() for s in funnel_sites(serve)]
    return not serve_is_right(serve, host) or f"{host}:443".lower() in on_funnel


def check_serve(serve: dict | None, host: str | None) -> Line:
    if host and serve_is_right(serve, host):
        return True, f"Tailscale shares the hub with your own devices at https://{host}"
    return False, f"Tailscale doesn't share the hub on HTTPS (443 -> {HUB}): run 'kairos up'"


def check_tcp_forward(serve: dict | None) -> Line:
    """Raw TCP to the hub carries no forwarding headers, so every device on the tailnet would join as this Mac."""
    fixes = [f"run '{off_command(serve, port)}'" for port in tcp_forwards(serve)]
    if any(tcp_forwards(f) for f in foreground(serve)):
        fixes.append(IN_A_TERMINAL)
    if not fixes:
        return True, "Tailscale doesn't hand raw TCP to the hub"
    return False, ("Tailscale forwards raw TCP to the hub, so every device on your tailnet counts as this computer: "
                   + "; ".join(fixes))


def check_funnel(serve: dict | None, host: str | None = None) -> Line:
    """Funnel must never reach the hub. `up` turns it off on 443 when 443 shares the hub; anything else gets the
    exact command. Funnel for another app on this Mac doesn't touch the hub, so it's only mentioned."""
    fixes = []
    for site in funnel_sites(serve):
        if host and site.lower() == f"{host}:443".lower() and serve_is_right(serve, host):
            fixes.append(f"{site}: run 'kairos up'")
        elif reaches_hub(serve, site):
            fixes.append(f"{site}: run '{off_command(serve, site.rpartition(':')[2])}'")
    if any(reaches_hub(f, site) for f in foreground(serve) for site in funnel_sites(f)):
        fixes.append(IN_A_TERMINAL)
    if fixes:
        return False, "Funnel puts the hub on the public internet: " + "; ".join(fixes)
    others = funnel_sites(serve) + [site for f in foreground(serve) for site in funnel_sites(f)]
    if others:
        return True, f"Funnel is on only for {', '.join(others)}, which doesn't reach the hub"
    return True, "Funnel is off: the hub isn't on the public internet"


def check_model(tags: dict | None, model: str = MODEL) -> Line:
    if tags is None:
        return False, f"Ollama isn't answering on {OLLAMA}: open the Ollama app, or run 'ollama serve'"
    names = {m.get("name") for m in tags.get("models") or []} | {m.get("model") for m in tags.get("models") or []}
    if model in names or f"{model}:latest" in names:
        return True, f"Ollama is running and has {model}"
    return False, f"Ollama doesn't have {model}: run 'ollama pull {model}'"


def check_hub(hello: dict | None, something_listening: bool = False) -> Line:
    if (hello or {}).get("hub") == "kairos-mesh":
        return True, f"The hub answers on {HUB}"
    if something_listening:
        return False, f"Something else is using port {HUB_PORT}: stop it, then run 'kairos up'"
    return False, "The hub isn't running: run 'kairos up'"


def check_node(pids: list[int]) -> Line:
    if pids:
        return True, "The Mac node is running"
    return False, "The Mac node isn't running: run 'kairos up'"


def check_tailnet(url: str | None, hello: dict | None) -> Line:
    if not url:
        return False, "The hub has no tailnet address yet: run 'kairos up'"
    if (hello or {}).get("hub") == "kairos-mesh":
        return True, f"Your devices reach the hub at {url}"
    return False, f"{url} doesn't answer: run 'kairos up' (the first HTTPS certificate can take about 30 s)"


def phones(ts: dict | None) -> list[dict]:
    return [p for p in ((ts or {}).get("Peer") or {}).values() if p.get("OS") == "iOS"]


def peer_name(peer: dict) -> str:
    """iPhones report HostName "localhost", so use the first part of the tailnet name instead."""
    return (peer.get("DNSName") or "").split(".")[0] or peer.get("HostName") or "iPhone"


def phone_line(peer: dict) -> Line:
    name = peer_name(peer)
    if not peer.get("Online"):
        return False, f"{name} is offline on Tailscale: on the iPhone, open the Tailscale app and turn it on"
    if peer.get("CurAddr"):
        how = "with a direct link"
    elif peer.get("PeerRelay"):
        how = "through a peer relay"
    elif peer.get("Active") and peer.get("Relay"):
        how = f"through Tailscale's relay in '{peer['Relay']}' (works, a little slower than direct)"
    else:
        how = "idle right now (the route shows once it's used)"
    return True, f"{name} is online on Tailscale, {how}"


def check_phones(ts: dict | None) -> list[Line]:
    found = phones(ts)
    if not found:
        return [(False, "No iPhone on your tailnet: install Tailscale on the iPhone and sign in with the same account")]
    return [phone_line(p) for p in found]


def parse_time(s: str | None) -> datetime | None:
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None
    except ValueError:
        return None


def check_keys(ts: dict | None, now: datetime) -> Line:
    """Tailscale keys expire (180 days by default); after that the device drops off the tailnet."""
    nodes = [("this Mac", (ts or {}).get("Self") or {})] + [(peer_name(p), p) for p in phones(ts)]
    soon = []
    for name, node in nodes:
        when = parse_time(node.get("KeyExpiry"))
        if when and when - now < timedelta(days=KEY_WARNING_DAYS):
            soon.append(f"{name} on {when:%d %b %Y}")
    if soon:
        return False, ("Tailscale keys expire soon (" + ", ".join(soon) + "): sign in to Tailscale again on that "
                       "device, or choose Disable key expiry for it at https://login.tailscale.com/admin/machines")
    return True, f"Tailscale keys are good for at least {KEY_WARNING_DAYS} more days"


def enable_url(output: str) -> str | None:
    """The link `tailscale serve` prints when Serve or HTTPS isn't allowed on the tailnet yet."""
    for url in re.findall(r"https://[^\s\"'<>]+", output or ""):
        host = url.split("/")[2].lower()
        if not host.endswith(".ts.net"):
            return url
    return None


# ---------- status ----------

def status() -> int:
    """Every check, one line each. Exit code 0 when all are OK."""
    ts = tailscale_json("status")
    lines = [check_tailscale(ts, installed=bool(tailscale_bin()))]
    if tailscale_state(ts) == "Running":
        serve = tailscale_json("serve", "status")
        host = cert_host(ts)
        url = env_url() or find_tailnet_url(serve, ts)
        lines += [check_https(ts), check_serve(serve, host), check_tcp_forward(serve), check_funnel(serve, host)]
    hello = get_json(HUB + "/api/hello")
    lines += [check_model(get_json(OLLAMA + "/api/tags")), check_hub(hello, port_in_use()),
              check_node(node_pids())]
    if tailscale_state(ts) == "Running":
        lines += [check_tailnet(url, get_json(url + "/api/hello", timeout=5) if url else None), *check_phones(ts),
                  check_keys(ts, datetime.now(timezone.utc))]
    for ok, text in lines:
        say(ok, text)
    return 0 if all(ok for ok, _ in lines) else 1


# ---------- LaunchAgents ----------

def hub_command(repo: Path = REPO) -> list[str]:
    """The hub, under caffeinate -s so the Mac doesn't sleep while it's on power."""
    return ["/usr/bin/caffeinate", "-s", str(repo / ".venv" / "bin" / "uvicorn"), "mesh.app:app", "--app-dir",
            str(repo), "--host", "127.0.0.1", "--port", str(HUB_PORT)]


def node_command(repo: Path = REPO) -> list[str]:
    return [str(repo / ".venv" / "bin" / "python"), "-u", "-m", "node.mac_node", "--name", "MacBook"]


def node_env(repo: Path = REPO) -> dict:
    return {"KAIROS_MESH_HUB": HUB, "KAIROS_NODE_STATE": str(repo / "data" / "mac-node.json")}


def passed_on(environ: dict) -> dict:
    return {k: environ[k] for k in PASS_ON if environ.get(k)}


def agent_plist(label: str, command: list[str], log: Path, repo: Path, env: dict) -> dict:
    return {"Label": label, "ProgramArguments": command, "WorkingDirectory": str(repo), "RunAtLoad": True,
            "KeepAlive": True, "ThrottleInterval": 5, "StandardOutPath": str(log), "StandardErrorPath": str(log),
            "EnvironmentVariables": {"PYTHONUNBUFFERED": "1", **env}}


def hub_plist(repo: Path, logs: Path, env: dict | None = None) -> dict:
    return agent_plist(HUB_LABEL, hub_command(repo), logs / "kairos-hub.log", repo, env or {})


def node_plist(repo: Path, logs: Path, env: dict | None = None) -> dict:
    return agent_plist(NODE_LABEL, node_command(repo), logs / "kairos-macnode.log", repo,
                       {**(env or {}), **node_env(repo)})


def launchctl(*args: str) -> subprocess.CompletedProcess:
    """launchctl's answer. When it is slow or missing, a failed answer instead of an error, so the caller prints its
    FIX line."""
    command = ["/bin/launchctl", *args]
    try:
        return subprocess.run(command, capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        return subprocess.CompletedProcess(command, 1, "", "launchctl didn't answer in time")


def domain() -> str:
    return f"gui/{os.getuid()}"


def agent_path(label: str) -> Path:
    return AGENTS / f"{label}.plist"


def installed(label: str) -> bool:
    return agent_path(label).exists()


def loaded(label: str) -> bool:
    return launchctl("print", f"{domain()}/{label}").returncode == 0


def start_agent(label: str) -> None:
    if loaded(label):
        launchctl("kickstart", "-k", f"{domain()}/{label}")
    else:
        launchctl("bootstrap", domain(), str(agent_path(label)))


# ---------- starting and stopping ----------

def start_detached(command: list[str], log: Path, env: dict | None = None) -> None:
    """Start a program that keeps running after this command ends, its output going to `log`."""
    log.parent.mkdir(parents=True, exist_ok=True)
    full_env = {**os.environ, **(env or {})}
    full_env.pop("KAIROS_MESH_TEST_CLIENT_IP", None)  # tests only: it would make every request "this computer"
    with open(log, "ab") as out:
        subprocess.Popen(["/usr/bin/nohup", *command], cwd=REPO, env=full_env, stdin=subprocess.DEVNULL,
                         stdout=out, stderr=subprocess.STDOUT, start_new_session=True)


def stop(find, wait: float = 10) -> None:
    """Stop the processes `find()` gives, politely first. Never this command itself or the shell that ran it."""
    def targets() -> list[int]:
        return [pid for pid in find() if pid not in (os.getpid(), os.getppid())]

    for pid in targets():
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + wait
    while targets() and time.monotonic() < deadline:
        time.sleep(0.5)
    for pid in targets():
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def wait_until(check, seconds: float, every: float = 1) -> bool:
    deadline = time.monotonic() + seconds
    while True:
        if check():
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(every)


def ensure_tailscale(seconds: float = 30) -> dict | None:
    """Tailscale's status, opening the app first if it isn't running."""
    ts = tailscale_json("status")
    if tailscale_state(ts) == "Running" or not tailscale_bin():
        return ts
    try:
        subprocess.run(["/usr/bin/open", "-a", "Tailscale"], capture_output=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        pass  # the wait below, then the Tailscale line, says what's wrong
    if tailscale_state(ts) in ("NeedsLogin", "NeedsMachineAuth"):
        return ts  # waiting won't help: the person has to sign in
    wait_until(lambda: tailscale_state(tailscale_json("status")) in ("Running", "NeedsLogin"), seconds)
    return tailscale_json("status")


def run_with_output(command: list[str], timeout: float) -> tuple[str, int | None]:
    """(everything it printed, exit code), with None for the code when it was stopped after `timeout`."""
    try:
        out = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
        return out.stdout.decode(errors="replace"), out.returncode
    except subprocess.TimeoutExpired as e:
        out = e.stdout or b""
        return (out.decode(errors="replace") if isinstance(out, bytes) else out), None


def ensure_serve(host: str) -> int:
    """Share the hub on HTTPS 443, tailnet only, if it isn't already. Running `serve` as Serve (not Funnel) also
    turns Funnel off for that port. 0 when done, 2 when the person has to do something first."""
    serve = tailscale_json("serve", "status") or {}
    ok, text = check_tcp_forward(serve)  # Serve can't put HTTPS on a port that forwards TCP, and it's unsafe anyway
    if not ok:
        say(ok, text)
        return 2
    if not serve_needs_change(serve, host):
        return 0
    output, code = run_with_output([tailscale_bin(), "serve", "--bg", "--https=443", HUB], timeout=20)
    link = enable_url(output)
    if link:
        say(False, f"Allow Tailscale to share the hub on your tailnet: open {link}, approve it, then run 'kairos up' "
                   "again")
        return 2
    serve = tailscale_json("serve", "status") or {}
    if code != 0 or serve_needs_change(serve, host):
        last = output.strip().splitlines()[-1] if output.strip() else "no answer"
        say(False, f"Tailscale couldn't share the hub ({last}): run 'kairos up' again, or 'kairos status' to see why")
        return 2
    say(True, f"Tailscale now shares the hub with your own devices at https://{host}")
    return 0


def ensure_hub() -> None:
    if hub_answers():
        return
    if installed(HUB_LABEL):
        start_agent(HUB_LABEL)
    else:
        start_detached(hub_command(), LOGS / "kairos-hub.log")
    if wait_until(hub_answers, 20):
        say(True, "Started the hub")


def ensure_node() -> None:
    if node_pids():
        return
    if installed(NODE_LABEL):
        start_agent(NODE_LABEL)
    else:
        start_detached(node_command(), LOGS / "kairos-macnode.log", node_env())
    if wait_until(node_pids, 5):
        say(True, "Started the Mac node")


def up() -> int:
    ts = ensure_tailscale()
    ok, text = check_tailscale(ts, installed=bool(tailscale_bin()))
    if not ok:
        say(ok, text)
        return 2
    host = cert_host(ts)
    if not host:
        say(*check_https(ts))
        return 2
    if code := ensure_serve(host):
        return code
    ensure_hub()
    ensure_node()
    url = env_url() or site_url(f"{host}:443")
    if hub_answers() and not get_json(url + "/api/hello", timeout=5):
        print(f"Waiting for {url} (the first HTTPS certificate can take about 30 s)...", flush=True)
        wait_until(lambda: get_json(url + "/api/hello", timeout=5), 90, every=3)
    print(flush=True)
    return status()


def down() -> int:
    """Stop the hub and the node. Tailscale and Serve stay, so the iPhone says Kairos isn't running on the Mac."""
    for label in (NODE_LABEL, HUB_LABEL):
        if loaded(label):
            launchctl("bootout", f"{domain()}/{label}")
    stop(node_pids)
    stop(hub_pids)
    node_stopped, hub_stopped = not node_pids(), not hub_answers()
    say(node_stopped, "The Mac node has stopped" if node_stopped else
        "The Mac node is still running: run 'kairos down' again")
    say(hub_stopped, "The hub has stopped; your iPhone will say Kairos isn't running on your Mac" if hub_stopped
        else f"Something still answers on {HUB}: run 'kairos down' again")
    say(True, "Tailscale and its sharing are left as they are; 'kairos up' starts everything again")
    return 0 if node_stopped and hub_stopped else 1


# ---------- pairing ----------

def pair() -> int:
    """A pairing code made straight in the hub's database, for "this computer", without a new login."""
    import segno

    from .store import Store, db_path
    db = Path(db_path())
    store = Store(db) if db.exists() else None  # don't make an empty database
    mac = store.this_computer_device() if store else None
    if not mac:
        say(False, "The hub has no 'this computer' yet: run 'kairos up' first")
        return 1
    made = store.new_pair_code(mac["id"])
    expires = parse_time(made["expires"]).astimezone()
    link = pair_link(tailnet_url(), made["code"])
    print(f"Code:  {made['code']}   (works once, until {expires:%H:%M})")
    if not link:
        say(False, "The hub isn't shared on your tailnet, so there's no link or QR code: run 'kairos up'")
        return 1
    print(f"Link:  {link}\n")
    segno.make(link, error="m").terminal(compact=True, border=2)
    print("\nOn your iPhone, open the Camera and point it at this code. Tailscale must be on.")
    return 0


# ---------- install ----------

def install() -> int:
    if port_in_use() and not hub_answers():
        who = who_listens()
        say(False, f"Something else is listening on port {HUB_PORT}" + (f" ({who})" if who else "")
            + ": stop it first, then run 'kairos install' again")
        return 1
    for label in (NODE_LABEL, HUB_LABEL):
        if loaded(label):
            launchctl("bootout", f"{domain()}/{label}")
    stop(node_pids)  # copies started by hand or by 'kairos up'; launchd starts its own
    stop(hub_pids)
    AGENTS.mkdir(parents=True, exist_ok=True)
    LOGS.mkdir(parents=True, exist_ok=True)
    env = passed_on(dict(os.environ))
    failed = False
    for label, plist in ((HUB_LABEL, hub_plist(REPO, LOGS, env)), (NODE_LABEL, node_plist(REPO, LOGS, env))):
        agent_path(label).write_bytes(plistlib.dumps(plist))
        r = launchctl("bootstrap", domain(), str(agent_path(label)))
        if r.returncode == 0:
            say(True, f"{label} starts at login and restarts if it stops ({agent_path(label)})")
        else:
            failed = True
            say(False, f"launchctl couldn't load {label} ({r.stderr.strip() or r.returncode}): run 'kairos install' "
                       "again")
    hub_up = wait_until(hub_answers, 20)
    say(hub_up, f"The hub answers on {HUB}" if hub_up else "The hub didn't start: see ~/Library/Logs/kairos-hub.log")
    return 0 if hub_up and not failed else 1


def uninstall() -> int:
    for label in (NODE_LABEL, HUB_LABEL):
        if loaded(label):
            launchctl("bootout", f"{domain()}/{label}")
        agent_path(label).unlink(missing_ok=True)
        say(True, f"Removed {label}; it no longer starts at login")
    say(True, "'kairos up' starts the hub and the Mac node again, without LaunchAgents")
    return 0


COMMANDS = {"up": up, "status": status, "down": down, "pair": pair, "install": install, "uninstall": uninstall}


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if len(args) != 1 or args[0] not in COMMANDS:
        print(__doc__.strip())
        return 2
    return COMMANDS[args[0]]()


if __name__ == "__main__":
    sys.exit(main())
