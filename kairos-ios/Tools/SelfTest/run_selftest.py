#!/usr/bin/env python3
"""Run Kairos's self-test on the real iPhone with a set of cases, and bring the results back.

    cd kairos-ios
    export KAIROS_DEVICE=<id from: xcrun devicectl list devices>  KAIROS_BUNDLE=<your build's bundle id>
    python3 -I Tools/SelfTest/run_selftest.py Tools/SelfTest/cases.json --out Tools/SelfTest/results

1. Copies the cases onto the phone (Documents/kairos-selftest-cases.json in Kairos's container).
2. Starts Kairos with -KairosSelfTest: it runs every case (dry run; "live" cases really read) and writes
   Documents/kairos-selftest.json as it goes.
3. Copies that file back every 20 s, prints progress, and stops when the run says it finished.
4. Prints the results by category and every failure with its reason.

The phone must be unlocked, with Kairos allowed to run (the self-test keeps the screen awake). Live WhatsApp cases
also need the iCTRL runner on the phone (Tools/iCTRL/README.md). Nothing here reads or prints a secret.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
from collections import defaultdict
from pathlib import Path

# Your iPhone and your build: the bundle id ends with your team id, which this repo keeps out of git.
DEVICE = os.environ.get("KAIROS_DEVICE", "")
BUNDLE = os.environ.get("KAIROS_BUNDLE", "")
ENV = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}


def devicectl(*args: str, timeout: float = 90) -> subprocess.CompletedProcess:
    return subprocess.run(["xcrun", "devicectl", *args], capture_output=True, text=True, timeout=timeout, env=ENV)


def push_cases(cases: Path) -> None:
    r = devicectl("device", "copy", "to", "--device", DEVICE, "--domain-type", "appDataContainer",
                  "--domain-identifier", BUNDLE, "--source", str(cases),
                  "--destination", "Documents/kairos-selftest-cases.json")
    if r.returncode != 0:
        sys.exit(f"Couldn't copy the cases to the phone:\n{r.stderr.strip()[-600:]}")


def launch() -> None:
    r = devicectl("device", "process", "launch", "--device", DEVICE, "--terminate-existing", BUNDLE, "--", "-KairosSelfTest")
    if r.returncode != 0:
        sys.exit(f"Couldn't start Kairos (is the phone unlocked?):\n{r.stderr.strip()[-600:]}")


def pull(dest: Path) -> dict | None:
    with tempfile.TemporaryDirectory() as tmp:
        target = Path(tmp) / "kairos-selftest.json"
        r = devicectl("device", "copy", "from", "--device", DEVICE, "--domain-type", "appDataContainer",
                      "--domain-identifier", BUNDLE, "--source", "Documents/kairos-selftest.json",
                      "--destination", str(target))
        if r.returncode != 0 or not target.exists():
            return None
        try:
            data = json.loads(target.read_text())
        except json.JSONDecodeError:
            return None
        dest.write_text(json.dumps(data, indent=1, ensure_ascii=False))
        return data


WATCHED = ("Tempo", "Kairos", "WhatsApp", "iCTRL", "JetsamEvent")


def crash_logs() -> set[str]:
    """Names of the phone's crash logs (and iOS memory events) for Kairos, WhatsApp and the iCTRL runner."""
    r = devicectl("device", "info", "files", "--device", DEVICE, "--domain-type", "systemCrashLogs")
    names = {line.split()[0] for line in r.stdout.splitlines() if line.strip() and line.split()[0].endswith(".ips")}
    return {n for n in names if n.startswith(WATCHED)}


def report(data: dict) -> None:
    s = data["summary"]
    judged = [c for c in data["cases"] if not c.get("notJudged")]
    skipped = len(data["cases"]) - len(judged)
    print(f"\n{s['passed']} of {len(judged)} judged cases passed (model: {s['model']})")
    if len(data["cases"]) < s["total"]:
        print(f"Only {len(data['cases'])} of {s['total']} cases ran.")
    if skipped:
        print(f"{skipped} not judged: Gemini's free allowance was used up, so Kairos never saw the words.")
    if s.get("stopped"):
        print(s["stopped"])
    if s.get("cooledSeconds"):
        print(f"Paused {s['cooledSeconds'] // 60} min {s['cooledSeconds'] % 60} s in all to let the phone cool.")
    by = defaultdict(lambda: [0, 0])
    for c in judged:
        by[c.get("category") or "?"][0] += c["pass"]
        by[c.get("category") or "?"][1] += 1
    for cat, (p, t) in sorted(by.items()):
        print(f"  {cat:<12} {p:>3}/{t:<3}")
    fails = [c for c in judged if not c["pass"]]
    if fails:
        print(f"\nFailures ({len(fails)}):")
        for c in fails:
            tag = " [live]" if c.get("live") else ""
            tag += " [siri]" if c.get("source") == "siriBackground" else ""
            print(f"- {c['id']}{tag}: {c['words']}\n    {c['why']}\n    reply: {c['reply'][:160]}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("cases", type=Path)
    ap.add_argument("--out", type=Path, default=Path("Tools/SelfTest/results"))
    ap.add_argument("--timeout", type=float, default=3600, help="seconds to wait for the run")
    ap.add_argument("--report-only", action="store_true", help="just pull and print the latest results")
    a = ap.parse_args()
    if not DEVICE or not BUNDLE:
        sys.exit("Set KAIROS_DEVICE (from: xcrun devicectl list devices) and KAIROS_BUNDLE (your build's bundle id).")
    a.out.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = a.out / f"selftest-{stamp}.json"

    before = crash_logs()
    if not a.report_only:
        total = len(json.loads(a.cases.read_text())["cases"])
        push_cases(a.cases)
        launched = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 60))
        launch()
        print(f"Running {total} cases on the phone…")
        started, last = time.time(), -1
        time.sleep(20)
        while time.time() - started < a.timeout:
            data = pull(dest)
            fresh = data and (data["summary"].get("startedAt") or "") >= launched   # not an older run's file
            if fresh and len(data["cases"]) != last:
                last = len(data["cases"])
                print(f"  {last}/{data['summary']['total']} done, {data['summary']['passed']} passed", flush=True)
            if fresh and data["summary"].get("finishedAt"):   # all done, or stopped early (see summary.stopped)
                break
            time.sleep(20)
    data = pull(dest)
    if not data:
        sys.exit("No results on the phone yet.")
    report(data)
    new = sorted(crash_logs() - before)
    print("\nCrashes during the run: " + (", ".join(new) if new else "none (Kairos, WhatsApp, iCTRL, iOS memory events)"))
    print(f"Saved: {dest}")


if __name__ == "__main__":
    main()
