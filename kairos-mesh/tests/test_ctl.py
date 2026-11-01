"""The `kairos` command's pure parts, and the hub's tailnet address, from sample Tailscale JSON.

The samples have the shape of `tailscale serve status --json` and `tailscale status --json` on a Mac running
Tailscale 1.102, with every name, address and key replaced by fakes. Nothing here runs Tailscale or launchctl.
"""
import copy
import plistlib
from datetime import datetime, timezone
from pathlib import Path

import pytest

from mesh import ctl, tailnet
from mesh.store import Store

HOST = "mac.tail1234.ts.net"

SERVE = {
    "TCP": {"443": {"HTTPS": True}},
    "Web": {f"{HOST}:443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8778"}}}},
}

STATUS = {
    "Version": "1.102.2-t0000000-g0000000",
    "TUN": False,
    "BackendState": "Running",
    "HaveNodeKey": True,
    "AuthURL": "",
    "TailscaleIPs": ["100.64.0.1", "fd7a:115c:a1e0::1"],
    "Self": {"ID": "n111", "HostName": "Test MacBook", "DNSName": f"{HOST}.", "OS": "macOS", "UserID": 1111,
             "TailscaleIPs": ["100.64.0.1"], "CurAddr": "", "Relay": "lhr", "PeerRelay": "", "Online": True,
             "Active": False, "KeyExpiry": "2027-02-12T01:46:49Z"},
    "Health": [],
    "MagicDNSSuffix": "tail1234.ts.net",
    "CurrentTailnet": {"Name": "owner@example.com", "MagicDNSSuffix": "tail1234.ts.net", "MagicDNSEnabled": True},
    "CertDomains": [HOST],
    "Peer": {
        "nodekey:aaaa": {"ID": "n222", "HostName": "localhost", "DNSName": "test-iphone.tail1234.ts.net.",
                         "OS": "iOS", "UserID": 1111, "TailscaleIPs": ["100.64.0.2"], "CurAddr": "", "Relay": "lhr",
                         "PeerRelay": "", "Online": True, "Active": False, "KeyExpiry": "2027-04-29T00:45:21Z",
                         "LastSeen": "0001-01-01T00:00:00Z"},
        "nodekey:bbbb": {"ID": "n333", "HostName": "Laptop", "DNSName": "laptop.tail9999.ts.net.", "OS": "windows",
                         "UserID": 2222, "CurAddr": "", "Relay": "blr", "Online": False, "Active": False,
                         "KeyExpiry": "2027-02-12T02:04:56Z", "LastSeen": "2026-09-12T03:51:40.1Z"},
    },
    "User": {"1111": {"ID": 1111, "LoginName": "owner@example.com", "DisplayName": "Owner"},
             "2222": {"ID": 2222, "LoginName": "friend@example.com", "DisplayName": "Friend"}},
}

NOW = datetime(2026, 10, 31, tzinfo=timezone.utc)


@pytest.fixture(autouse=True)
def no_remembered_address(monkeypatch):
    """Each test starts without a remembered tailnet address or an address setting from the shell."""
    monkeypatch.delenv("KAIROS_MESH_PUBLIC_URL", raising=False)
    tailnet._cache.clear()
    yield
    tailnet._cache.clear()


def changed(sample, **fields):
    out = copy.deepcopy(sample)
    out.update(fields)
    return out


def iphone(**fields):
    return {**STATUS["Peer"]["nodekey:aaaa"], **fields}


# ---------- the hub's tailnet address ----------

def test_the_tailnet_address_comes_from_the_serve_site_that_proxies_to_the_hub():
    assert tailnet.find_tailnet_url(SERVE, None) == f"https://{HOST}"
    on_8443 = {"TCP": {"8443": {"HTTPS": True}},
               "Web": {f"{HOST}:8443": {"Handlers": {"/": {"Proxy": "http://localhost:8778"}}}}}
    assert tailnet.find_tailnet_url(on_8443, None) == f"https://{HOST}:8443"
    elsewhere = {"TCP": {"443": {"HTTPS": True}},
                 "Web": {f"{HOST}:443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:3000"}}}}}
    assert tailnet.find_tailnet_url(elsewhere, STATUS) is None
    assert tailnet.find_tailnet_url({}, STATUS) is None and tailnet.find_tailnet_url(None, None) is None


RAW_TCP = {"TCP": {"443": {"TCPForward": "127.0.0.1:8778", "TerminateTLS": HOST}}}


def test_this_macs_https_name_is_used_when_a_web_handler_reaches_the_hub_on_another_path():
    on_a_path = {"TCP": {"443": {"HTTPS": True}},
                 "Web": {f"{HOST}:443": {"Handlers": {"/kairos": {"Proxy": "http://127.0.0.1:8778"}}}}}
    assert tailnet.find_tailnet_url(on_a_path, STATUS) == f"https://{HOST}"
    assert tailnet.find_tailnet_url(on_a_path, changed(STATUS, CertDomains=None)) is None


def test_a_raw_tcp_forward_to_the_hub_never_becomes_the_pairing_address():
    """Raw TCP carries no forwarding headers, so through it every tailnet device would look like this computer."""
    assert tailnet.find_tailnet_url(RAW_TCP, STATUS) is None and not tailnet.serves_hub(RAW_TCP)
    assert tailnet.tcp_forwards(RAW_TCP) == ["443"] and tailnet.tcp_forwards(SERVE) == []
    assert tailnet.reaches_hub(RAW_TCP, f"{HOST}:443") and tailnet.reaches_hub(SERVE, f"{HOST}:443")
    assert not tailnet.reaches_hub(SERVE, f"{HOST}:8443")


def test_the_ways_serve_writes_the_hubs_address():
    for target in ("http://127.0.0.1:8778", "http://localhost:8778", "127.0.0.1:8778", "http://127.0.0.1:8778/"):
        assert tailnet.proxies_to_hub(target), target
    for target in ("http://127.0.0.1:8777", "https+insecure://127.0.0.1:8778", "http://127.0.0.1:8778/api",
                   "http://10.0.0.5:8778", "", None, "http://127.0.0.1:notaport"):
        assert not tailnet.proxies_to_hub(target), target


def test_the_tailnet_address_setting_wins_and_a_broken_tailscale_never_raises(monkeypatch):
    tailnet._cache.clear()
    monkeypatch.setenv("KAIROS_MESH_PUBLIC_URL", "https://hub.example.ts.net/")
    assert tailnet.tailnet_url() == "https://hub.example.ts.net"
    monkeypatch.delenv("KAIROS_MESH_PUBLIC_URL")

    def broken(*args, **kwargs):
        raise RuntimeError("tailscale fell over")
    monkeypatch.setattr(tailnet, "tailscale_json", broken)
    assert tailnet.tailnet_url() is None

    calls = []
    monkeypatch.setattr(tailnet, "tailscale_json", lambda *args, **kwargs: calls.append(args) or SERVE)
    tailnet._cache.clear()
    assert tailnet.tailnet_url() == f"https://{HOST}" and tailnet.tailnet_url() == f"https://{HOST}"
    assert calls == [("serve", "status")]  # read once, then remembered
    tailnet._cache.clear()


def test_the_pairing_link():
    assert tailnet.pair_link(f"https://{HOST}", "012345") == f"kairos://mesh?hub=https%3A%2F%2F{HOST}&code=012345"
    assert tailnet.pair_link(None, "012345") is None


# ---------- serve: is it right, and does up need to change it ----------

def test_up_leaves_a_right_serve_config_alone():
    assert ctl.serve_is_right(SERVE, HOST) and not ctl.serve_needs_change(SERVE, HOST)
    assert not ctl.serve_needs_change(SERVE, HOST.upper())


def test_up_changes_serve_when_the_hub_isnt_shared_or_funnel_is_on():
    assert ctl.serve_needs_change({}, HOST) and ctl.serve_needs_change(None, HOST)
    assert ctl.serve_needs_change(changed(SERVE, TCP={}), HOST)  # 443 isn't HTTPS
    assert ctl.serve_needs_change(SERVE, "other.tail1234.ts.net")
    funnel = changed(SERVE, AllowFunnel={f"{HOST}:443": True})
    assert ctl.serve_needs_change(funnel, HOST) and ctl.funnel_sites(funnel) == [f"{HOST}:443"]
    assert ctl.funnel_sites(changed(SERVE, AllowFunnel={f"{HOST}:443": False})) == []


def test_serve_and_funnel_lines():
    assert ctl.check_serve(SERVE, HOST) == (True, f"Tailscale shares the hub with your own devices at https://{HOST}")
    assert ctl.check_serve({}, HOST)[0] is False and "kairos up" in ctl.check_serve({}, HOST)[1]
    assert ctl.check_funnel(SERVE, HOST)[0] is True
    ok, text = ctl.check_funnel(changed(SERVE, AllowFunnel={f"{HOST}:443": True}), HOST)
    assert not ok and text == f"Funnel puts the hub on the public internet: {HOST}:443: run 'kairos up'"


def test_funnel_on_another_port_gets_the_command_that_turns_it_off():
    """`up` only fixes 443, so Funnel on another port that reaches the hub gets its own command, not 'kairos up'."""
    on_8443 = {"TCP": {"443": {"HTTPS": True}, "8443": {"HTTPS": True}},
               "Web": {**SERVE["Web"], f"{HOST}:8443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8778"}}}},
               "AllowFunnel": {f"{HOST}:8443": True}}
    ok, text = ctl.check_funnel(on_8443, HOST)
    assert not ok and text.endswith(f"{HOST}:8443: run 'tailscale serve --https=8443 off'")
    assert not ctl.serve_needs_change(on_8443, HOST)  # up leaves it to that command instead of looping

    raw = {"TCP": {"10000": {"TCPForward": "127.0.0.1:8778"}}, "AllowFunnel": {f"{HOST}:10000": True}}
    assert ctl.check_funnel(raw, HOST)[1].endswith("run 'tailscale serve --tcp=10000 off'")


def test_funnel_for_another_app_is_only_mentioned():
    other = {**SERVE, "TCP": {**SERVE["TCP"], "8443": {"HTTPS": True}},
             "Web": {**SERVE["Web"], f"{HOST}:8443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:3000"}}}},
             "AllowFunnel": {f"{HOST}:8443": True}}
    assert ctl.check_funnel(other, HOST) == (True, f"Funnel is on only for {HOST}:8443, which doesn't reach the hub")
    assert not ctl.serve_needs_change(other, HOST)


def test_funnel_left_running_in_a_terminal_is_caught():
    """`tailscale funnel 8778` without --bg keeps its config under Foreground, Funnel included."""
    in_terminal = {**SERVE, "Foreground": {"sess1": {
        "TCP": {"10000": {"HTTPS": True}},
        "Web": {f"{HOST}:10000": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8778"}}}},
        "AllowFunnel": {f"{HOST}:10000": True}}}}
    ok, text = ctl.check_funnel(in_terminal, HOST)
    assert not ok and "running in a terminal (Ctrl-C)" in text
    other_app = copy.deepcopy(in_terminal)
    other_app["Foreground"]["sess1"]["Web"][f"{HOST}:10000"]["Handlers"]["/"]["Proxy"] = "http://127.0.0.1:3000"
    assert ctl.check_funnel(other_app, HOST)[0]


def test_a_raw_tcp_forward_to_the_hub_is_flagged():
    assert ctl.check_tcp_forward(SERVE) == (True, "Tailscale doesn't hand raw TCP to the hub")
    ok, text = ctl.check_tcp_forward(RAW_TCP)
    assert not ok and "every device on your tailnet counts as this computer" in text
    assert text.endswith("run 'tailscale serve --tls-terminated-tcp=443 off'")
    plain = {"TCP": {"5000": {"TCPForward": "localhost:8778"}}}
    assert ctl.check_tcp_forward(plain)[1].endswith("run 'tailscale serve --tcp=5000 off'")
    elsewhere = {"TCP": {"5000": {"TCPForward": "127.0.0.1:22"}}}
    assert ctl.check_tcp_forward(elsewhere)[0]
    in_terminal = {**SERVE, "Foreground": {"sess1": plain}}
    assert "running in a terminal" in ctl.check_tcp_forward(in_terminal)[1]


def test_up_stops_before_serve_when_tcp_is_forwarded_to_the_hub(monkeypatch, capsys):
    ran = []
    monkeypatch.setattr(ctl, "tailscale_json", lambda *args, **kw: RAW_TCP)
    monkeypatch.setattr(ctl, "run_with_output", lambda *args, **kw: ran.append(args) or ("", 0))
    assert ctl.ensure_serve(HOST) == 2 and ran == []
    assert capsys.readouterr().out.startswith("FIX Tailscale forwards raw TCP to the hub")


def test_the_link_tailscale_prints_when_serve_isnt_allowed_yet():
    waiting = ("Serve is not enabled on your tailnet.\nTo enable, visit:\n\n"
               "         https://login.tailscale.com/f/serve?node=nFAKE123\n")
    assert ctl.enable_url(waiting) == "https://login.tailscale.com/f/serve?node=nFAKE123"
    done = (f"Available within your tailnet:\n\nhttps://{HOST}/\n|-- proxy http://127.0.0.1:8778\n\n"
            "Serve started and running in the background.\nTo disable the proxy, run: tailscale serve --https=443 off")
    assert ctl.enable_url(done) is None and ctl.enable_url("") is None


# ---------- the status lines ----------

def test_tailscale_line_says_what_to_do_in_each_state():
    ok, text = ctl.check_tailscale(STATUS)
    assert ok and text == "Tailscale is on, signed in as owner@example.com"
    assert "sign in" in ctl.check_tailscale(changed(STATUS, BackendState="NeedsLogin"))[1]
    assert "turn it on" in ctl.check_tailscale(changed(STATUS, BackendState="Stopped"))[1]
    assert "open the Tailscale app" in ctl.check_tailscale(None)[1]
    assert "isn't installed" in ctl.check_tailscale(None, installed=False)[1]
    assert not any(ctl.check_tailscale(s)[0] for s in (None, changed(STATUS, BackendState="NeedsMachineAuth")))


def test_https_names_line():
    assert ctl.check_https(STATUS) == (True, f"MagicDNS and HTTPS certificates are on: this Mac is {HOST}")
    for broken in (changed(STATUS, CertDomains=None),
                   changed(STATUS, CurrentTailnet={"MagicDNSEnabled": False})):
        ok, text = ctl.check_https(broken)
        assert not ok and "https://login.tailscale.com/admin/dns" in text


def test_the_iphone_line_says_how_it_is_connected():
    assert ctl.check_phones(STATUS) == [(True, "test-iphone is online on Tailscale, idle right now "
                                               "(the route shows once it's used)")]
    assert "relay in 'lhr'" in ctl.phone_line(iphone(Active=True))[1]
    assert "direct link" in ctl.phone_line(iphone(Active=True, CurAddr="203.0.113.9:41641"))[1]
    assert "peer relay" in ctl.phone_line(iphone(Active=True, PeerRelay="100.64.0.9:7777:vni:1"))[1]
    ok, text = ctl.phone_line(iphone(Online=False))
    assert not ok and text.startswith("test-iphone is offline")
    ok, text = ctl.check_phones(changed(STATUS, Peer={}))[0]
    assert not ok and "install Tailscale on the iPhone" in text


def test_keys_that_expire_soon_are_flagged():
    assert ctl.check_keys(STATUS, NOW)[0]
    ok, text = ctl.check_keys(STATUS, datetime(2027, 2, 1, tzinfo=timezone.utc))
    assert not ok and "this Mac on 12 Feb 2027" in text and "test-iphone" not in text
    no_expiry = changed(STATUS, Self={**STATUS["Self"], "KeyExpiry": None})
    assert ctl.check_keys(no_expiry, datetime(2027, 2, 1, tzinfo=timezone.utc))[0]


def test_model_hub_node_and_tailnet_lines():
    tags = {"models": [{"name": "qwen2.5:7b", "model": "qwen2.5:7b"}, {"name": "llama3:latest"}]}
    assert ctl.check_model(tags, "qwen2.5:7b")[0] and ctl.check_model(tags, "llama3")[0]
    assert ctl.check_model(tags, "qwen3:8b") == (False, "Ollama doesn't have qwen3:8b: run 'ollama pull qwen3:8b'")
    assert "ollama serve" in ctl.check_model(None)[1]
    assert ctl.check_hub({"hub": "kairos-mesh", "version": "0.1"})[0]
    assert "Something else" in ctl.check_hub(None, something_listening=True)[1]
    assert ctl.check_hub(None) == (False, "The hub isn't running: run 'kairos up'")
    assert ctl.check_node([123])[0] and not ctl.check_node([])[0]
    assert ctl.check_tailnet(f"https://{HOST}", {"hub": "kairos-mesh"})[0]
    assert "30 s" in ctl.check_tailnet(f"https://{HOST}", None)[1]
    assert not ctl.check_tailnet(None, None)[0]


def fake_mac(monkeypatch, status=STATUS, serve=SERVE, node=(4242,), urls=None):
    """Point every probe in ctl at sample answers."""
    answers = {"http://127.0.0.1:8778/api/hello": {"hub": "kairos-mesh"},
               "http://127.0.0.1:11434/api/tags": {"models": [{"name": ctl.MODEL}]},
               f"https://{HOST}/api/hello": {"hub": "kairos-mesh"}, **(urls or {})}
    monkeypatch.setattr(ctl, "tailscale_bin", lambda: "/fake/tailscale")
    monkeypatch.setattr(ctl, "tailscale_json", lambda *args, **kw: serve if args[0] == "serve" else status)
    monkeypatch.setattr(ctl, "get_json", lambda url, timeout=3: answers.get(url))
    monkeypatch.setattr(ctl, "node_pids", lambda: list(node))
    monkeypatch.setattr(ctl, "port_in_use", lambda port=8778: True)
    monkeypatch.delenv("KAIROS_MESH_PUBLIC_URL", raising=False)


def test_status_prints_one_line_per_check_and_exits_0_when_all_is_well(monkeypatch, capsys):
    fake_mac(monkeypatch)
    assert ctl.status() == 0
    lines = capsys.readouterr().out.splitlines()
    assert len(lines) == 11 and all(line.startswith("OK  ") for line in lines)


def test_status_exits_1_and_says_what_to_fix(monkeypatch, capsys):
    fake_mac(monkeypatch, node=(), urls={f"https://{HOST}/api/hello": None})
    assert ctl.status() == 1
    fixes = [line for line in capsys.readouterr().out.splitlines() if line.startswith("FIX ")]
    assert fixes == ["FIX The Mac node isn't running: run 'kairos up'",
                     f"FIX https://{HOST} doesn't answer: run 'kairos up' (the first HTTPS certificate can take "
                     "about 30 s)"]


def test_status_with_tailscale_off_skips_the_tailnet_checks(monkeypatch, capsys):
    fake_mac(monkeypatch, status=changed(STATUS, BackendState="Stopped"))
    assert ctl.status() == 1
    out = capsys.readouterr().out
    assert out.startswith("FIX Tailscale is off") and "iphone" not in out.lower() and "Funnel" not in out


# ---------- LaunchAgents ----------

def test_launch_agents_use_this_repos_absolute_paths():
    repo, logs = Path("/Users/me/kairos-mesh"), Path("/Users/me/Library/Logs")
    hub = ctl.hub_plist(repo, logs, {"KAIROS_MESH_OWNER": "owner@example.com"})
    assert hub["Label"] == "com.kairos.hub"
    assert hub["ProgramArguments"] == ["/usr/bin/caffeinate", "-s", "/Users/me/kairos-mesh/.venv/bin/uvicorn",
                                       "mesh.app:app", "--app-dir", "/Users/me/kairos-mesh", "--host", "127.0.0.1",
                                       "--port", "8778"]
    assert hub["RunAtLoad"] is True and hub["KeepAlive"] is True and hub["ThrottleInterval"] == 5
    assert hub["WorkingDirectory"] == "/Users/me/kairos-mesh"
    assert hub["StandardOutPath"] == hub["StandardErrorPath"] == "/Users/me/Library/Logs/kairos-hub.log"
    assert hub["EnvironmentVariables"]["KAIROS_MESH_OWNER"] == "owner@example.com"

    node = ctl.node_plist(repo, logs)
    assert node["Label"] == "com.kairos.macnode"
    assert node["ProgramArguments"] == ["/Users/me/kairos-mesh/.venv/bin/python", "-u", "-m", "node.mac_node",
                                        "--name", "MacBook"]
    assert node["EnvironmentVariables"]["KAIROS_MESH_HUB"] == "http://127.0.0.1:8778"
    assert node["EnvironmentVariables"]["KAIROS_NODE_STATE"] == "/Users/me/kairos-mesh/data/mac-node.json"
    assert node["StandardOutPath"] == "/Users/me/Library/Logs/kairos-macnode.log"
    assert plistlib.loads(plistlib.dumps(node)) == node  # a valid plist


def test_only_known_settings_are_copied_into_launch_agents():
    env = {"KAIROS_MESH_OWNER": "owner@example.com", "KAIROS_MESH_TEST_CLIENT_IP": "127.0.0.1", "HOME": "/x",
           "KAIROS_MESH_HOSTS": ""}
    assert ctl.passed_on(env) == {"KAIROS_MESH_OWNER": "owner@example.com"}


def test_who_is_listening_on_the_port():
    assert ctl.listener_names("p123\ncpython3.12\np456\ncnode\n") == ["python3.12", "node"]
    assert ctl.listener_names("") == []


def test_a_slow_launchctl_gives_a_failed_answer_not_a_traceback(monkeypatch):
    def slow(command, **kwargs):
        raise ctl.subprocess.TimeoutExpired(command, kwargs.get("timeout"))
    monkeypatch.setattr(ctl.subprocess, "run", slow)
    answer = ctl.launchctl("print", "gui/501/com.kairos.hub")
    assert answer.returncode == 1 and "didn't answer" in answer.stderr
    assert not ctl.loaded(ctl.HUB_LABEL)


# ---------- finding the hub and the node: only this repo's, never a shell that mentions them ----------

REPO = "/Users/me/kairos-mesh"
PS = f"""\
  101 /bin/zsh -c eval 'KAIROS_MESH_HUB=http://127.0.0.1:8778 .venv/bin/python -u -m node.mac_node --name MacBook'
  102 .venv/bin/python -u -m node.mac_node --name MacBook
  103 {REPO}/.venv/bin/python -u -m node.mac_node --name MacBook
  104 /Users/me/backups/kairos-mesh/.venv/bin/python -u -m node.mac_node --name MacBook
  105 /usr/bin/caffeinate -s {REPO}/.venv/bin/uvicorn mesh.app:app --app-dir {REPO} --host 127.0.0.1 --port 8778
  106 {REPO}/.venv/bin/python {REPO}/.venv/bin/uvicorn mesh.app:app --app-dir {REPO} --host 127.0.0.1 --port 8778
  107 /Users/me/backups/kairos-mesh/.venv/bin/python .venv/bin/uvicorn mesh.app:app --port 8779
  108 vim node/mac_node.py
  109 python3 -m node.mac_node_old
"""
CWDS = {101: REPO, 102: REPO, 103: "/", 104: "/Users/me/backups/kairos-mesh"}


def test_the_node_is_found_by_how_it_starts_and_where_it_runs(monkeypatch):
    listing = ctl.parse_ps(PS)
    assert listing[1] == (102, ".venv/bin/python -u -m node.mac_node --name MacBook")
    assert [pid for pid, command in listing if ctl.is_node_command(command)] == [102, 103, 104]
    monkeypatch.setattr(ctl, "REPO", Path(REPO))
    monkeypatch.setattr(ctl, "processes", lambda: listing)
    monkeypatch.setattr(ctl, "cwd_of", lambda pid: CWDS.get(pid))
    assert ctl.runs_this_repo(f"{REPO}/.venv/bin/python -m node.mac_node", None, Path(REPO))
    assert not ctl.runs_this_repo("/Users/me/backups/kairos-mesh/.venv/bin/python", "/", Path(REPO))
    assert ctl.node_pids() == [102, 103]  # not the zsh wrapper, not the backup copy's node


def test_the_hub_is_whatever_runs_mesh_app_on_port_8778(monkeypatch):
    monkeypatch.setattr(ctl, "processes", lambda: ctl.parse_ps(PS))
    monkeypatch.setattr(ctl, "listening_pids", lambda port=8778: [106])
    assert ctl.hub_pids() == [106]  # not the caffeinate wrapper, not the backup hub on 8779
    monkeypatch.setattr(ctl, "listening_pids", lambda port=8778: [999])
    assert ctl.hub_pids() == []  # something else holds the port: not ours to stop


def test_stop_never_signals_this_command_or_its_shell(monkeypatch):
    sent = []
    monkeypatch.setattr(ctl.os, "kill", lambda pid, sig: sent.append(pid))
    ctl.stop(lambda: [ctl.os.getpid(), ctl.os.getppid()], wait=0)
    assert sent == []


# ---------- pair: a code without a new login ----------

def test_pair_makes_a_code_for_this_computer_without_a_new_login(tmp_path, monkeypatch, capsys):
    db = tmp_path / "mesh.db"
    monkeypatch.setenv("KAIROS_MESH_DB", str(db))
    monkeypatch.setenv("KAIROS_MESH_PUBLIC_URL", f"https://{HOST}")
    assert ctl.pair() == 1 and "run 'kairos up' first" in capsys.readouterr().out
    assert not db.exists()  # no empty database made

    store = Store(db)
    store.this_computer("MacBook", "macos")
    logins = store._c().execute("SELECT COUNT(*) FROM tokens").fetchone()[0]
    assert ctl.pair() == 0
    out = capsys.readouterr().out
    code = out.split("Code:", 1)[1].split()[0]
    assert len(code) == 6 and f"kairos://mesh?hub=https%3A%2F%2F{HOST}&code={code}" in out
    assert "open the Camera" in out and "█" in out  # the QR code, drawn in the terminal
    assert store._c().execute("SELECT COUNT(*) FROM tokens").fetchone()[0] == logins
    phone, _ = store.pair(code, "iPhone", "ios")
    assert phone["name"] == "iPhone" and store.verify_log()["ok"]


def test_main_shows_the_commands_for_anything_else(capsys):
    assert ctl.main([]) == 2 and ctl.main(["reset"]) == 2
    assert "kairos up" in capsys.readouterr().out
