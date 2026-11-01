"""Any device -> any device: a browser asks, the node that holds the data does it, the answer comes back."""
import os
import tempfile
import threading
import time

os.environ["TEMPO_DB"] = os.path.join(tempfile.mkdtemp(prefix="tempo-test-"), "unused.db")  # never data/
os.environ["TEMPO_TEST_CLIENT_IP"] = "127.0.0.1"
os.environ["TEMPO_MDNS"] = "0"
os.environ["TEMPO_LLM_BASE_URL"] = "http://127.0.0.1:9"

import pytest  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from hub import db, main, nodes  # noqa: E402


@pytest.fixture()
def client(tmp_path):
    db.init(tmp_path / "a.db")
    with TestClient(main.app) as c:
        yield c
    os.environ["TEMPO_TEST_CLIENT_IP"] = "127.0.0.1"


def join(client, name, platform=None):
    r = client.post("/api/devices/register", json={"name": name, "platform": platform})
    assert r.status_code == 200, r.text
    return {"Authorization": f"Bearer {r.json()['device_token']}"}, r.json()["device_id"]


@pytest.fixture()
def phone(client):
    auth, did = join(client, "Shiva's iPhone", "ios")
    r = client.post("/api/nodes/announce", headers=auth, json={
        "agent": "Kairos for iPhone", "skills": [{"name": "get_calendar_events", "summary": "What's on a day"}]})
    assert r.status_code == 200, r.text
    return auth, did


def test_a_browser_task_reaches_the_phone_and_the_answer_comes_back(client, phone):
    phone_auth, phone_id = phone
    browser, _ = join(client, "Android browser", "android")

    [me, ph] = sorted(client.get("/api/nodes", headers=browser).json()["nodes"], key=lambda n: n["name"])
    assert ph["name"] == "Shiva's iPhone" and ph["node"] and ph["online"] and ph["agent"] == "Kairos for iPhone"
    assert me["you"] and not me["node"]

    sent = client.post("/api/nodes/tasks", headers=browser, json={"to": "shiva's iphone", "words": "What's on tomorrow?"})
    assert sent.status_code == 200, sent.text
    task = sent.json()
    assert task["status"] == "queued" and task["to"]["id"] == phone_id and task["target_online"]

    got = client.get("/api/nodes/tasks/next", headers=phone_auth).json()["task"]
    assert got["id"] == task["id"] and got["words"] == "What's on tomorrow?" and got["from"]["name"] == "Android browser"
    assert client.get("/api/nodes/tasks/next", headers=phone_auth).json()["task"] is None  # delivered once

    r = client.post(f"/api/nodes/tasks/{task['id']}/result", headers=phone_auth,
                    json={"status": "done", "answer": "Dentist at 3.", "steps": ["Calendar helper: 1 event"]})
    assert r.status_code == 200 and r.json()["status"] == "done"
    done = client.get(f"/api/nodes/tasks/{task['id']}", headers=browser).json()
    assert done["answer"] == "Dentist at 3." and done["steps"] == ["Calendar helper: 1 event"]

    log = [e for e in client.get("/api/events?after=0", headers=browser).json()["events"] if e["kind"] == "hub.node_task"]
    assert [e["payload"]["status"] for e in log] == ["queued", "done"]
    assert all(e["trust_level"] == "hub" for e in log)


def test_waiting_for_the_answer_returns_as_soon_as_the_node_finishes(client, phone):
    phone_auth, phone_id = phone
    browser, _ = join(client, "Windows laptop", "windows")

    def node():
        task = client.get("/api/nodes/tasks/next?wait=5", headers=phone_auth).json()["task"]
        client.post(f"/api/nodes/tasks/{task['id']}/result", headers=phone_auth, json={"status": "done", "answer": "62%"})

    t = threading.Thread(target=node)
    t.start()
    started = time.monotonic()
    r = client.post("/api/nodes/tasks", headers=browser, json={"to": phone_id, "words": "Phone battery?", "wait": 10})
    t.join()
    assert r.json()["status"] == "done" and r.json()["answer"] == "62%"
    assert time.monotonic() - started < 8


def test_only_the_target_may_answer_and_only_the_two_devices_may_read(client, phone):
    phone_auth, phone_id = phone
    browser, _ = join(client, "browser", "android")
    other, _ = join(client, "kitchen tablet", "android")
    task = client.post("/api/nodes/tasks", headers=browser, json={"to": phone_id, "words": "hi"}).json()

    assert client.post(f"/api/nodes/tasks/{task['id']}/result", headers=other, json={"status": "done"}).status_code == 404
    assert client.get(f"/api/nodes/tasks/{task['id']}", headers=other).status_code == 404
    assert client.get("/api/nodes/tasks/next", headers=other).status_code == 409  # not a node
    assert client.post("/api/nodes/tasks", headers=browser, json={"to": "nobody", "words": "hi"}).status_code == 404
    assert client.post("/api/nodes/tasks", headers=browser, json={"to": phone_id, "words": " "}).status_code == 422

    client.get("/api/nodes/tasks/next", headers=phone_auth)
    client.post(f"/api/nodes/tasks/{task['id']}/result", headers=phone_auth, json={"status": "refused", "answer": "No."})
    again = client.post(f"/api/nodes/tasks/{task['id']}/result", headers=phone_auth, json={"status": "done"})
    assert again.status_code == 409


def test_a_node_that_stops_polling_goes_offline_and_old_tasks_expire(client, phone):
    phone_auth, phone_id = phone
    browser, _ = join(client, "browser")
    task = client.post("/api/nodes/tasks", headers=browser, json={"to": phone_id, "words": "hi", "expires_in": 30}).json()
    c = db.conn()
    c.execute("UPDATE nodes SET polled_utc='2020-01-01T00:00:00Z'")
    c.execute("UPDATE node_tasks SET expires_utc='2020-01-01T00:00:00Z' WHERE id=?", (task["id"],))
    c.commit()
    ph = next(n for n in client.get("/api/nodes", headers=browser).json()["nodes"] if n["device_id"] == phone_id)
    assert not ph["online"]
    assert client.get(f"/api/nodes/tasks/{task['id']}", headers=browser).json()["status"] == "expired"
    assert client.get("/api/nodes/tasks/next", headers=phone_auth).json()["task"] is None


def test_removed_devices_and_ask_only_devices_cannot_use_nodes(client, phone):
    phone_auth, phone_id = phone
    admin, _ = join(client, "hub computer")
    assert client.delete(f"/api/devices/{phone_id}", headers=admin).status_code == 200
    assert client.get("/api/nodes/tasks/next", headers=phone_auth).status_code == 410
    assert client.post("/api/nodes/tasks", headers=admin, json={"to": phone_id, "words": "hi"}).status_code == 404

    os.environ["TEMPO_TEST_CLIENT_IP"] = "8.8.8.8"  # not this computer and not its Wi-Fi: no auto-join
    voice = client.post("/api/devices/register", json={"name": "voice"})
    assert voice.status_code == 403


def test_tasks_never_cross_to_another_persons_devices(client, phone):
    _, phone_id = phone
    me, _ = join(client, "browser")
    c = db.conn()
    c.execute("INSERT INTO persons (id, name, join_token, ingest_key, created_at) VALUES "
              "('p_other', 'Someone else', 'jt_other_000000000000', 'ik_other_000000000000', '2026-10-30T00:00:00Z')")
    c.commit()
    stranger = db.add_device("p_other", "stranger", "ios", "phone", [], "owner-cli", None)
    c = db.conn()
    c.execute("INSERT INTO nodes (device_id, person_id, skills, announced_utc, polled_utc) VALUES (?,?,?,?,?)",
              (stranger["id"], "p_other", "[]", "2026-10-30T00:00:00Z", db.now_utc()))
    c.commit()
    assert client.post("/api/nodes/tasks", headers=me, json={"to": stranger["id"], "words": "hi"}).status_code == 404
    assert all(n["device_id"] != stranger["id"] for n in client.get("/api/nodes", headers=me).json()["nodes"])
