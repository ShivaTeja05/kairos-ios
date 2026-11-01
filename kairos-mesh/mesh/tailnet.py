"""The hub's own address on your tailnet, read from Tailscale.

`tailscale serve` shares the hub (http://127.0.0.1:8778) with your own devices at https://<mac>.<tailnet>.ts.net.
These helpers only read Tailscale's state (`tailscale serve status --json`, `tailscale status --json`); they never
change it. The pure ones take that JSON as plain dicts, so they are easy to test.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
from urllib.parse import urlencode, urlsplit

HUB_PORT = 8778
TAILSCALE_APP = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
CACHE_SECONDS = 60
_cache: dict = {}  # {"at": when it was read, "url": the address or None}


def tailscale_bin() -> str | None:
    """The Tailscale CLI: on PATH, or inside the Mac app (a LaunchAgent's PATH has no /usr/local/bin)."""
    found = shutil.which("tailscale")
    if found:
        return found
    return TAILSCALE_APP if os.path.exists(TAILSCALE_APP) else None


def tailscale_json(*args: str, timeout: float = 3) -> dict | None:
    """Run a read-only Tailscale command with --json. None if Tailscale is missing, slow, or says no."""
    exe = tailscale_bin()
    if not exe:
        return None
    try:
        out = subprocess.run([exe, *args, "--json"], capture_output=True, text=True, timeout=timeout)
        data = json.loads(out.stdout) if out.returncode == 0 and out.stdout.strip() else None
        return data if isinstance(data, dict) else None
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return None


def proxies_to_hub(target: str | None, port: int = HUB_PORT) -> bool:
    """True for each way Serve may write the hub's address: http://127.0.0.1:8778, localhost:8778, ..."""
    if not target:
        return False
    url = urlsplit(target if "://" in target else "http://" + target)
    try:
        return (url.scheme == "http" and url.hostname in ("127.0.0.1", "localhost") and url.port == port
                and url.path in ("", "/"))
    except ValueError:
        return False


def hub_sites(serve: dict | None) -> list[str]:
    """Each "host:port" where Serve answers HTTPS and sends "/" to the hub."""
    serve = serve or {}
    tcp = serve.get("TCP") or {}
    sites = []
    for hostport, site in (serve.get("Web") or {}).items():
        port = hostport.rpartition(":")[2]
        handler = ((site or {}).get("Handlers") or {}).get("/") or {}
        if (tcp.get(port) or {}).get("HTTPS") and proxies_to_hub(handler.get("Proxy")):
            sites.append(hostport)
    return sites


def handlers_reach_hub(site: dict | None) -> bool:
    """A Serve web site sends at least one path to the hub."""
    return any(proxies_to_hub((h or {}).get("Proxy")) for h in ((site or {}).get("Handlers") or {}).values())


def serves_hub(serve: dict | None) -> bool:
    """Serve sends some path of a web site to the hub. A raw TCP forward doesn't count (see tcp_forwards)."""
    return any(handlers_reach_hub(site) for site in ((serve or {}).get("Web") or {}).values())


def tcp_forwards(config: dict | None) -> list[str]:
    """Ports where a Serve config hands raw TCP to the hub. Serve adds no headers to raw TCP, so the hub would see
    every tailnet device as a plain 127.0.0.1 client: "this computer"."""
    tcp = (config or {}).get("TCP") or {}
    return [port for port, h in tcp.items() if proxies_to_hub((h or {}).get("TCPForward"))]


def reaches_hub(config: dict | None, hostport: str) -> bool:
    """A site of a Serve config sends something to the hub: a web handler at any path, or a raw TCP forward."""
    config = config or {}
    return (handlers_reach_hub((config.get("Web") or {}).get(hostport))
            or hostport.rpartition(":")[2] in tcp_forwards(config))


def foreground(serve: dict | None) -> list[dict]:
    """The Serve configs of `tailscale serve` or `tailscale funnel` commands left running in a terminal (no --bg)."""
    return [f or {} for f in ((serve or {}).get("Foreground") or {}).values()]


def site_url(hostport: str) -> str:
    """"mac.tail1234.ts.net:443" -> "https://mac.tail1234.ts.net" (443 is HTTPS's own port, so it's dropped)."""
    host, _, port = hostport.rpartition(":")
    return f"https://{host}" if port == "443" else f"https://{hostport}"


def url_from_serve(serve: dict | None) -> str | None:
    sites = sorted(hub_sites(serve), key=lambda s: not s.endswith(":443"))  # port 443 first
    return site_url(sites[0]) if sites else None


def url_from_cert_domains(status: dict | None) -> str | None:
    domains = (status or {}).get("CertDomains") or []
    return f"https://{domains[0]}" if domains else None


def find_tailnet_url(serve: dict | None, status: dict | None) -> str | None:
    """The hub's tailnet address from Tailscale's JSON: the Serve site that proxies to the hub, else this Mac's
    HTTPS name when a Serve web handler sends some path to the hub. Never a raw TCP forward."""
    return url_from_serve(serve) or (url_from_cert_domains(status) if serves_hub(serve) else None)


def env_url() -> str | None:
    return os.environ.get("KAIROS_MESH_PUBLIC_URL", "").strip().rstrip("/") or None


def tailnet_url() -> str | None:
    """The hub's own tailnet HTTPS address, or None. KAIROS_MESH_PUBLIC_URL wins; otherwise Tailscale is asked
    (3 s at most, remembered for 60 s). Never raises."""
    if env_url():
        return env_url()
    if _cache and time.monotonic() - _cache["at"] < CACHE_SECONDS:
        return _cache["url"]
    try:
        serve = tailscale_json("serve", "status")
        url = url_from_serve(serve)
        if not url and serves_hub(serve):
            url = url_from_cert_domains(tailscale_json("status"))
    except Exception:  # noqa: BLE001 - pairing must still work without Tailscale
        url = None
    _cache.update(at=time.monotonic(), url=url)
    return url


def pair_link(hub: str | None, code: str) -> str | None:
    """The link the iPhone opens to join: kairos://mesh?hub=...&code=..., or None without a hub address."""
    return "kairos://mesh?" + urlencode({"hub": hub, "code": code}) if hub else None
