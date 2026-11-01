"""iPhone <-> Mac through the shared brain: joining, tasks both ways, one conversation, Jarvis, and who can reach
the hub at all."""
import json
import logging
import os
import tempfile
import threading

os.environ["KAIROS_MESH_DB"] = os.path.join(tempfile.mkdtemp(prefix="mesh-test-"), "unused.db")  # never data/
os.environ["KAIROS_MESH_TEST_CLIENT_IP"] = "127.0.0.1"

import httpx  # noqa: E402
import pytest  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from mesh import app as hub  # noqa: E402
from mesh import tailnet  # noqa: E402
from mesh.brain import Brain, build_context  # noqa: E402
from mesh.store import Store  # noqa: E402


@pytest.fixture(autouse=True)
def no_real_tailscale(monkeypatch):
    """Tests never ask this Mac's real Tailscale, and start with the owner check off."""
    monkeypatch.setattr(tailnet, "tailscale_json", lambda *args, **kwargs: None)
    tailnet._cache.clear()
    for name in ("KAIROS_MESH_PUBLIC_URL", "KAIROS_MESH_OWNER"):
        monkeypatch.delenv(name, raising=False)


@pytest.fixture()
def client(tmp_path):
    hub.use_store(Store(tmp_path / "mesh.db"))
    os.environ["KAIROS_MESH_TEST_CLIENT_IP"] = "127.0.0.1"
    with TestClient(hub.app, base_url="http://127.0.0.1:8778") as c:  # the hub answers only names it knows
        yield c
    os.environ["KAIROS_MESH_TEST_CLIENT_IP"] = "127.0.0.1"


def auth(token):
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture()
def mac(client):
    r = client.post("/api/join", json={"name": "MacBook", "platform": "macos"})
    assert r.status_code == 200, r.text
    token = r.json()["token"]
    client.post("/api/card", headers=auth(token), json={
        "agent": "Kairos for Mac", "skills": [{"name": "find_files", "summary": "Find documents"}]})
    return auth(token), r.json()["device"]["id"]


@pytest.fixture()
def iphone(client, mac):
    code = client.post("/api/pair", headers=mac[0]).json()["code"]
    os.environ["KAIROS_MESH_TEST_CLIENT_IP"] = "192.168.1.23"  # the phone on the Wi-Fi
    r = client.post("/api/join", json={"name": "Shiva's iPhone", "platform": "ios", "code": code})
    assert r.status_code == 200, r.text
    token = r.json()["token"]
    client.post("/api/card", headers=auth(token), json={
        "agent": "Kairos for iPhone", "skills": [{"name": "get_calendar_events", "summary": "What's on a day"}]})
    return auth(token), r.json()["device"]["id"]


def test_this_computer_joins_alone_others_need_a_single_use_code(client, mac):
    os.environ["KAIROS_MESH_TEST_CLIENT_IP"] = "192.168.1.50"
    assert client.post("/api/join", json={"name": "stranger"}).status_code == 403
    os.environ["KAIROS_MESH_TEST_CLIENT_IP"] = "127.0.0.1"
    tunnel = client.post("/api/join", json={"name": "x"}, headers={"X-Forwarded-For": "8.8.8.8"})
    assert tunnel.status_code == 403  # a tunnel looks like loopback; its forwarding header gives it away

    page = client.post("/api/join", json={"name": "MacBook"}).json()  # the Mac's browser page: same device, own login
    assert page["device"]["id"] == mac[1]
    assert client.get("/api/devices", headers=mac[0]).status_code == 200  # the node's login still works
    assert client.get("/api/devices", headers=auth(page["token"])).status_code == 200

    code = client.post("/api/pair", headers=mac[0]).json()["code"]
    os.environ["KAIROS_MESH_TEST_CLIENT_IP"] = "192.168.1.50"
    assert client.post("/api/join", json={"name": "phone", "code": code}).status_code == 200
    assert client.post("/api/join", json={"name": "again", "code": code}).status_code == 403


def test_guessing_codes_through_a_tunnel_is_capped_for_the_whole_hub(client, mac):
    from mesh.store import MAX_WRONG_CODES
    code = client.post("/api/pair", headers=mac[0]).json()["code"]
    wrong = f"{(int(code) + 1) % 10**6:06d}"
    for i in range(MAX_WRONG_CODES):  # each guess from a different address, as through a tunnel
        os.environ["KAIROS_MESH_TEST_CLIENT_IP"] = f"203.0.113.{i + 1}"
        assert client.post("/api/join", json={"name": "guess", "code": wrong}).status_code == 403
    os.environ["KAIROS_MESH_TEST_CLIENT_IP"] = "198.51.100.7"
    assert client.post("/api/join", json={"name": "guess", "code": code}).status_code == 429  # even the right one
    assert any(e["kind"] == "pair.locked" for e in hub.store._c().execute("SELECT kind FROM log"))
    assert client.get("/api/devices", headers=mac[0]).status_code == 200  # joined devices carry on


def test_the_mac_asks_the_iphone_and_the_answer_comes_back(client, mac, iphone):
    task = client.post("/api/tasks", headers=mac[0], json={"to": "iphone", "words": "What's on tomorrow?"}).json()
    assert task["status"] == "submitted" and task["to"]["name"] == "Shiva's iPhone" and task["target_online"]

    got = client.get("/api/tasks/next", headers=iphone[0]).json()["task"]
    assert got["id"] == task["id"] and got["status"] == "working" and got["from"]["name"] == "MacBook"
    client.post(f"/api/tasks/{task['id']}/update", headers=iphone[0], json={"progress": "Reading the calendar"})
    client.post(f"/api/tasks/{task['id']}/update", headers=iphone[0], json={"status": "input-required",
                                                                            "progress": "Waiting for Face ID"})
    done = client.post(f"/api/tasks/{task['id']}/update", headers=iphone[0],
                       json={"status": "completed", "answer": "Dentist at 3."}).json()
    assert done["status"] == "completed" and [p["text"] for p in done["progress"]] == [
        "Reading the calendar", "Waiting for Face ID"]
    seen = client.get(f"/api/tasks/{task['id']}", headers=mac[0]).json()
    assert seen["answer"] == "Dentist at 3."
    assert client.get("/api/log/verify", headers=mac[0]).json()["ok"]


def test_the_iphone_asks_the_mac_too(client, mac, iphone):
    task = client.post("/api/tasks", headers=iphone[0], json={"to": "MacBook", "words": "Find my OxHack notes"}).json()
    assert client.get("/api/tasks/next", headers=mac[0]).json()["task"]["id"] == task["id"]


def test_only_the_worker_moves_a_task_and_only_the_asker_cancels_it(client, mac, iphone):
    task = client.post("/api/tasks", headers=mac[0], json={"to": "iphone", "words": "hi"}).json()
    assert client.post(f"/api/tasks/{task['id']}/update", headers=mac[0],
                       json={"status": "completed"}).status_code == 404
    assert client.post(f"/api/tasks/{task['id']}/update", headers=iphone[0],
                       json={"status": "submitted"}).status_code == 422
    assert client.post(f"/api/tasks/{task['id']}/cancel", headers=iphone[0]).status_code == 409
    assert client.post(f"/api/tasks/{task['id']}/cancel", headers=mac[0]).json()["status"] == "canceled"
    assert client.get("/api/tasks/next", headers=iphone[0]).json()["task"] is None
    assert client.post("/api/tasks", headers=mac[0], json={"to": "toaster", "words": "hi"}).status_code == 404


def test_a_device_that_stops_polling_goes_offline_and_old_tasks_expire(client, mac, iphone):
    task = client.post("/api/tasks", headers=mac[0], json={"to": "iphone", "words": "hi", "expires_in": 30}).json()
    c = hub.store._c()
    c.execute("UPDATE cards SET polled='2020-01-01T00:00:00Z' WHERE device_id=?", (iphone[1],))
    c.execute("UPDATE tasks SET expires='2020-01-01T00:00:00Z' WHERE id=?", (task["id"],))
    c.commit()
    ph = next(d for d in client.get("/api/devices", headers=mac[0]).json()["devices"] if d["id"] == iphone[1])
    assert not ph["online"]
    assert client.get(f"/api/tasks/{task['id']}", headers=mac[0]).json()["status"] == "expired"


def test_a_task_taken_by_a_device_that_died_goes_back_in_the_queue(client, mac, iphone):
    task = client.post("/api/tasks", headers=mac[0], json={"to": "iphone", "words": "What's on tomorrow?"}).json()
    lost = client.get("/api/tasks/next", headers=iphone[0]).json()["task"]  # handed to a poll that never answers
    assert lost["id"] == task["id"]
    c = hub.store._c()
    c.execute("UPDATE tasks SET lease_until='2020-01-01T00:00:00Z' WHERE id=?", (task["id"],))  # 30 s pass
    c.commit()
    again = client.get("/api/tasks/next", headers=iphone[0]).json()["task"]  # the relaunched app asks again
    assert again["id"] == task["id"] and again["status"] == "working"
    client.post(f"/api/tasks/{task['id']}/update", headers=iphone[0], json={"progress": "On it"})  # acknowledged
    c = hub.store._c()
    assert c.execute("SELECT lease_until FROM tasks WHERE id=?", (task["id"],)).fetchone()[0] is None
    assert client.get("/api/log/verify", headers=mac[0]).json()["ok"]


def test_one_conversation_both_devices_see_it(client, mac, iphone):
    client.post("/api/turns", headers=iphone[0], json={"role": "user", "text": "Find flights to Delhi under £600"})
    task = client.post("/api/tasks", headers=iphone[0], json={"to": "MacBook", "words": "Find flights to Delhi under £600"}).json()
    client.get("/api/tasks/next", headers=mac[0])
    client.post(f"/api/tasks/{task['id']}/update", headers=mac[0], json={"progress": "3 flights found so far"})

    ctx = client.get("/api/context", headers=mac[0]).json()["text"]
    assert "[Shiva's iPhone" in ctx and "Find flights to Delhi under £600" in ctx
    assert "asked on Shiva's iPhone" in ctx and "done by MacBook" in ctx and "3 flights found so far" in ctx


def fake_model(script):
    """A stand-in for the LLM: returns scripted replies and records what it was shown."""
    seen = []

    def chat(messages, tools):
        seen.append({"messages": messages, "tools": tools})
        return script[len(seen) - 1](messages, tools)
    return chat, seen


def test_jarvis_hands_the_job_to_the_iphone_and_answers_with_its_result(client, mac, iphone):
    def call_iphone(messages, tools):
        assert tools[0]["function"]["parameters"]["properties"]["device"]["enum"] == ["MacBook", "Shiva's iPhone"]
        return {"content": "", "tool_calls": [{"id": "c1", "function": {
            "name": "ask_device", "arguments": json.dumps({"device": "Shiva's iPhone", "task": "What's on tomorrow?"})}}]}

    def answer(messages, tools):
        result = json.loads(messages[-1]["content"])
        assert result["status"] == "completed" and result["answer_from_device"] == "Dentist at 3."
        return {"content": "You've got the dentist at 3 tomorrow."}

    chat, _ = fake_model([call_iphone, answer])
    hub.use_store(hub.store, Brain(hub.store, chat))

    def phone_node():
        t = client.get("/api/tasks/next?wait=10", headers=iphone[0]).json()["task"]
        client.post(f"/api/tasks/{t['id']}/update", headers=iphone[0], json={"status": "completed", "answer": "Dentist at 3."})

    th = threading.Thread(target=phone_node)
    th.start()
    r = client.post("/api/ask", headers=mac[0], json={"text": "What's on my calendar tomorrow?", "wait": 10})
    th.join()
    out = r.json()
    assert out["answer"] == "You've got the dentist at 3 tomorrow." and out["via"] == "model"
    assert out["tasks"][0]["to"]["name"] == "Shiva's iPhone"
    turns = client.get("/api/state", headers=iphone[0]).json()["turns"]
    assert [(t["device"], t["role"]) for t in turns] == [("MacBook", "user"), ("MacBook", "assistant")]


def test_the_mac_knows_what_was_started_on_the_iphone(client, mac, iphone):
    task = client.post("/api/tasks", headers=iphone[0], json={"to": "MacBook", "words": "Find flights to Delhi"}).json()
    client.post("/api/turns", headers=iphone[0], json={"role": "user", "text": "Find flights to Delhi"})
    client.get("/api/tasks/next", headers=mac[0])
    client.post(f"/api/tasks/{task['id']}/update", headers=mac[0], json={"progress": "3 found, cheapest £540"})

    def reads_the_board(messages, tools):
        system = messages[0]["content"]
        assert "talking to you on MacBook" in system
        assert "asked on Shiva's iPhone" in system and "3 found, cheapest £540" in system
        return {"content": "It started on your iPhone; 3 found so far, cheapest £540."}

    chat, _ = fake_model([reads_the_board])
    hub.use_store(hub.store, Brain(hub.store, chat))
    out = client.post("/api/ask", headers=mac[0], json={"text": "How's my flight search going?"}).json()
    assert out["answer"].startswith("It started on your iPhone") and out["tasks"] == []


def test_a_call_written_as_text_is_still_routed_and_flagged(client, mac, iphone):
    def writes_it(messages, tools):
        return {"content": 'ask_device(device="Shiva\'s iPhone", task="What\'s on my calendar tomorrow?")'}

    def answer(messages, tools):
        return {"content": "I've asked your iPhone."}

    chat, _ = fake_model([writes_it, answer])
    hub.use_store(hub.store, Brain(hub.store, chat))
    out = client.post("/api/ask", headers=mac[0], json={"text": "What's on my calendar tomorrow?", "wait": 0}).json()
    assert out["via"] == "model (call written as text)" and out["tasks"][0]["to"]["name"] == "Shiva's iPhone"
    assert out["tasks"][0]["words"] == "What's on my calendar tomorrow?"


def test_rules_first_a_named_device_gets_the_job_with_no_model_call(client, mac, iphone):
    def must_not_be_called(messages, tools):
        raise AssertionError("the model was called for a request that names a device")
    hub.use_store(hub.store, Brain(hub.store, must_not_be_called))

    def phone_node():
        t = client.get("/api/tasks/next?wait=10", headers=iphone[0]).json()["task"]
        assert t["words"] == "Put the dentist in my calendar tomorrow at 3pm"
        client.post(f"/api/tasks/{t['id']}/update", headers=iphone[0],
                    json={"status": "completed", "answer": "Dentist added for tomorrow at 15:00."})

    th = threading.Thread(target=phone_node)
    th.start()
    out = client.post("/api/ask", headers=mac[0],
                      json={"text": "Put the dentist in my iPhone calendar tomorrow at 3pm", "wait": 10}).json()
    th.join()
    assert out["via"] == "rules" and out["answer"] == "Shiva's iPhone: Dentist added for tomorrow at 15:00."


def test_the_iphone_asks_the_mac_and_never_itself(client, mac, iphone):
    def must_not_be_called(messages, tools):
        raise AssertionError("rules should have routed this")
    hub.use_store(hub.store, Brain(hub.store, must_not_be_called))

    def mac_node():
        t = client.get("/api/tasks/next?wait=10", headers=mac[0]).json()["task"]
        assert t["words"] == "Find my OxHack notes" and t["from"]["name"] == "Shiva's iPhone"
        client.post(f"/api/tasks/{t['id']}/update", headers=mac[0], json={"status": "completed", "answer": "Found 2 files."})

    th = threading.Thread(target=mac_node)
    th.start()
    out = client.post("/api/ask", headers=iphone[0], json={"text": "Find my OxHack notes on my Mac", "wait": 10}).json()
    th.join()
    assert out["via"] == "rules" and out["tasks"][0]["to"]["name"] == "MacBook"
    turns = client.get("/api/state", headers=mac[0]).json()["turns"]
    assert turns[0]["device"] == "Shiva's iPhone" and turns[0]["text"] == "Find my OxHack notes on my Mac"

    def tries_itself(messages, tools):
        return {"content": "", "tool_calls": [{"id": "c1", "function": {
            "name": "ask_device", "arguments": json.dumps({"device": "Shiva's iPhone", "task": "set an alarm"})}}]}

    def answers(messages, tools):
        said = json.loads(messages[-1]["content"])["error"]
        assert "say it more simply on the phone" in said
        assert "'remind me at 5 to call Mum'" in said and "'set an alarm for 7'" in said
        return {"content": "Say it more simply here, like 'set an alarm for 7'."}

    chat, _ = fake_model([tries_itself, answers])
    hub.use_store(hub.store, Brain(hub.store, chat))
    out = client.post("/api/ask", headers=iphone[0], json={"text": "Set an alarm for 7", "wait": 0}).json()
    assert out["tasks"] == [] and client.get("/api/tasks/next", headers=iphone[0]).json()["task"] is None


def test_questions_about_earlier_requests_still_go_to_the_model(client, mac, iphone):
    chat, seen = fake_model([lambda m, t: {"content": "You asked about your calendar."}])
    hub.use_store(hub.store, Brain(hub.store, chat))
    out = client.post("/api/ask", headers=mac[0], json={"text": "What did I just ask from my iPhone?"}).json()
    assert out["via"] == "model" and len(seen) == 1 and out["tasks"] == []


def test_without_a_model_plain_rules_still_route_and_report(client, mac, iphone):
    def down(messages, tools):
        raise httpx.ConnectError("no model")
    hub.use_store(hub.store, Brain(hub.store, down))
    out = client.post("/api/ask", headers=mac[0], json={"text": "Check my iPhone calendar for tomorrow", "wait": 0}).json()
    assert out["via"].startswith("rules") and out["tasks"][0]["to"]["name"] == "Shiva's iPhone"
    status = client.post("/api/ask", headers=mac[0], json={"text": "how's it going?", "wait": 0}).json()
    assert status["via"].startswith("rules") and status["tasks"] == []
    assert '"Check my calendar for tomorrow"' in status["answer"] and "submitted" in status["answer"]


def test_context_is_built_for_the_device_you_talk_on(tmp_path):
    s = Store(tmp_path / "c.db")
    d, _ = s.this_computer("MacBook", "macos")
    assert "(nothing yet)" in build_context(s, d["id"]) and "(no tasks)" in build_context(s, d["id"])


# ---------- who can reach the hub ----------

def test_api_docs_are_off(client):
    for path in ("/docs", "/redoc", "/openapi.json"):
        assert client.get(path).status_code == 404


def test_only_host_names_the_hub_knows_are_answered(client):
    assert client.get("/api/hello", headers={"Host": "evil.example"}).status_code == 400  # e.g. DNS rebinding
    assert client.get("/api/hello", headers={"Host": "mac.ts.net.evil.example"}).status_code == 400
    for host in ("127.0.0.1:8778", "localhost:8778", "[::1]:8778", "mac.tail1234.ts.net"):
        assert client.get("/api/hello", headers={"Host": host}).status_code == 200, host


def test_more_host_names_can_be_added(monkeypatch):
    monkeypatch.setenv("KAIROS_MESH_HOSTS", "my-mac.local, kairos.home ,")
    assert hub.allowed_hosts() == ["127.0.0.1", "localhost", "[::1]", "*.ts.net", "my-mac.local",
                                   "kairos.home"]


def test_funnel_requests_are_always_refused(client, mac):
    assert client.get("/api/hello", headers={"Tailscale-Funnel-Request": "?1"}).status_code == 403
    assert client.get("/api/devices", headers={**mac[0], "Tailscale-Funnel-Request": "?1"}).status_code == 403
    assert client.post("/api/join", json={"name": "x"}, headers={"Tailscale-Funnel-Request": "?1"}).status_code == 403


def test_owner_check_is_off_until_set_then_only_the_owner_gets_in(client, mac, monkeypatch, caplog):
    stranger = {"X-Forwarded-For": "100.101.102.103", "Tailscale-User-Login": "someone@else.com"}
    hub._logins_seen.clear()
    with caplog.at_level(logging.INFO, logger="uvicorn.error"):
        assert client.get("/api/hello", headers=stranger).status_code == 200  # off by default
    assert "someone@else.com" in caplog.text and "km_" not in caplog.text  # logs who, never a token

    monkeypatch.setenv("KAIROS_MESH_OWNER", "Shiva@example.com")
    assert client.get("/api/hello", headers=stranger).status_code == 403
    assert client.get("/api/hello", headers={"X-Forwarded-For": "100.1.2.3"}).status_code == 403  # no login at all
    owner = {"X-Forwarded-For": "100.101.102.103", "Tailscale-User-Login": "shiva@example.com"}
    assert client.get("/api/devices", headers={**mac[0], **owner}).status_code == 200
    assert client.get("/api/devices", headers=mac[0]).status_code == 200  # this computer isn't forwarded


def test_a_request_through_tailscale_serve_is_never_this_computer(client):
    for headers in ({"Tailscale-User-Login": "shiva@example.com"}, {"X-Forwarded-Host": "mac.tail1234.ts.net"},
                    {"X-Forwarded-Proto": "https"}):
        assert client.post("/api/join", json={"name": "x"}, headers=headers).status_code == 403, headers
    assert client.post("/api/join", json={"name": "MacBook"}).status_code == 200
    assert client.post("/api/join", json={"name": "MacBook"}, headers={"Host": "localhost:8778"}).status_code == 200


def test_a_raw_tcp_forward_from_the_tailnet_is_not_this_computer(client):
    """`tailscale serve --tcp` adds no headers: the device on the far end still asks for the tailnet name."""
    raw = client.post("/api/join", json={"name": "x"}, headers={"Host": "mac.tail1234.ts.net"})
    assert raw.status_code == 403


def test_pairing_gives_a_link_and_qr_code_when_the_hub_has_a_tailnet_address(client, mac, monkeypatch):
    plain = client.post("/api/pair", headers=mac[0]).json()
    assert len(plain["code"]) == 6 and plain["hub"] is None and plain["link"] is None and plain["qr_svg"] is None

    monkeypatch.setenv("KAIROS_MESH_PUBLIC_URL", "https://mac.tail1234.ts.net/")
    p = client.post("/api/pair", headers=mac[0]).json()
    assert p["hub"] == "https://mac.tail1234.ts.net"
    assert p["link"] == f"kairos://mesh?hub=https%3A%2F%2Fmac.tail1234.ts.net&code={p['code']}"
    assert p["qr_svg"].startswith("<svg") and "<script" not in p["qr_svg"]
    os.environ["KAIROS_MESH_TEST_CLIENT_IP"] = "100.101.102.103"
    assert client.post("/api/join", json={"name": "iPhone", "code": p["code"]}).status_code == 200
