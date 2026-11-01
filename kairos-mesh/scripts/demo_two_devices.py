#!/usr/bin/env python3
"""Demo: iPhone <-> Mac through the shared brain, with one conversation.

    .venv/bin/python scripts/demo_two_devices.py   # run from kairos-mesh/; hub on 127.0.0.1:8778, Mac node running

The Mac side is real: the hub, the Mac node and the local model. The iPhone side is a labelled STAND-IN played by
this script, so you can try the hub without a phone. (The real iPhone node is in the iPhone app:
kairos-ios/TempoApp/Agents/Mesh/MeshNode.swift.) The stand-in pairs like a real phone, sends its turns and tasks
through the same API, and answers the one task sent to it with a fixed, labelled answer.
"""
import os
import sys
import threading
import time

import httpx

HUB = os.environ.get("KAIROS_MESH_HUB", "http://127.0.0.1:8778")
http = httpx.Client(base_url=HUB, timeout=60)


def h(token):
    return {"Authorization": f"Bearer {token}"}


def say(who, text):
    print(f"\n[{time.strftime('%H:%M:%S')}] {who}: {text}", flush=True)


def ask(token, who, text, wait=25):
    say(who, text)
    out = http.post("/api/ask", headers=h(token), json={"text": text, "wait": wait}).json()
    tasks = ", ".join(f"{t['to']['name']} ({t['status']})" for t in out.get("tasks", []))
    print(f"   Jarvis ({out.get('via')}): {out.get('answer')}" + (f"\n   tasks: {tasks}" if tasks else ""), flush=True)
    return out


def main():
    mac = http.post("/api/join", json={"name": "MacBook"}).json()["token"]
    for d in http.get("/api/devices", headers=h(mac)).json()["devices"]:  # a fresh stand-in on every run
        if d["name"] == "iPhone (stand-in)":
            http.delete(f"/api/devices/{d['id']}", headers=h(mac))
    code = http.post("/api/pair", headers=h(mac)).json()["code"]
    phone = http.post("/api/join", json={"name": "iPhone (stand-in)", "platform": "ios", "code": code}).json()["token"]
    http.post("/api/card", headers=h(phone), json={"agent": "Kairos for iPhone (stand-in)", "skills": [
        {"name": "get_calendar_events", "summary": "What's on a day"}, {"name": "create_reminder", "summary": "Add a reminder"},
        {"name": "message_contact", "summary": "Text someone (Face ID)"}]})
    devices = http.get("/api/devices", headers=h(mac)).json()["devices"]
    print("Devices:", "; ".join(f"{d['name']} ({'reachable' if d['online'] else 'away'})" for d in devices))

    def stand_in_phone():  # answers the first task sent to the phone, like the real node will
        t = http.get("/api/tasks/next", params={"wait": 25}, headers=h(phone)).json()["task"]
        if t:
            http.post(f"/api/tasks/{t['id']}/update", headers=h(phone), json={"progress": "Reading the calendar"})
            http.post(f"/api/tasks/{t['id']}/update", headers=h(phone), json={
                "status": "completed", "answer": "Tomorrow: dentist at 15:00 (stand-in answer, not your real calendar)."})

    print("\n--- 1. On the iPhone: give the Mac a job ---")
    ask(phone, "You on iPhone", "What's my Mac's battery and free disk space?")

    print("\n--- 2. On the Mac: ask about what was said on the iPhone ---")
    ask(mac, "You on MacBook", "What did I just ask from my iPhone, and what was the answer?", wait=0)

    print("\n--- 3. On the Mac: give the iPhone a job ---")
    th = threading.Thread(target=stand_in_phone)
    th.start()
    ask(mac, "You on MacBook", "What's on my iPhone calendar tomorrow?")
    th.join()

    print("\n--- The one conversation, as both devices see it ---")
    for t in http.get("/api/state", headers=h(phone)).json()["turns"]:
        print(f"   [{t['device']}] {'You' if t['role'] == 'user' else 'Jarvis'}: {t['text']}")
    print("\nLog chain:", http.get("/api/log/verify", headers=h(mac)).json())


if __name__ == "__main__":
    try:
        main()
    except httpx.HTTPError as e:
        sys.exit(f"Hub not reachable at {HUB} ({type(e).__name__}). Start it first.")
