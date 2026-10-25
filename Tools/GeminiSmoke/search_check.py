"""Why does Google Search (grounding) fail on this key? Tries one grounded request per model and prints Google's own
reason: HTTP status, error status, quota metric/id and retry delay. Never prints the key.

Run:  python3 -I tempo-ios/Tools/GeminiSmoke/search_check.py   (reads GEMINI_API_KEY from tempo-hub/agents/.env)
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
ENV = os.path.join(ROOT, "tempo-hub", "agents", ".env")
MODELS = sys.argv[1:] or ["gemini-3.5-flash-lite", "gemini-3.5-flash", "gemini-2.5-flash"]


def key_from_env():
    try:
        for line in open(ENV, encoding="utf-8"):
            if line.startswith("GEMINI_API_KEY="):
                return line.split("=", 1)[1].strip()
    except OSError:
        pass
    sys.exit("No GEMINI_API_KEY in tempo-hub/agents/.env (run tempo-hub/agents/set_gemini_key.sh first).")


def call(model, key, body):
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "x-goog-api-key": key})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=40) as r:
            return r.status, json.loads(r.read() or b"{}"), time.time() - t0
    except urllib.error.HTTPError as e:
        try:
            data = json.loads(e.read() or b"{}")
        except ValueError:
            data = {}
        return e.code, data, time.time() - t0
    except (TimeoutError, OSError) as e:  # socket.timeout, URLError, connection resets
        return 0, {"error": {"status": "NO_REPLY", "message": f"no reply ({type(e).__name__}): Google may be busy, try again"}}, time.time() - t0


def reason(data):
    err = data.get("error", {})
    out = [f"status={err.get('status')}", f"message={str(err.get('message', ''))[:160]!r}"]
    for d in err.get("details", []):
        t = d.get("@type", "")
        if t.endswith("QuotaFailure"):
            for v in d.get("violations", []):
                out.append(f"quotaMetric={v.get('quotaMetric')} quotaId={v.get('quotaId')} "
                           f"dims={v.get('quotaDimensions')} value={v.get('quotaValue')}")
        elif t.endswith("RetryInfo"):
            out.append(f"retryDelay={d.get('retryDelay')}")
    return "\n      ".join(out)


def main():
    key = key_from_env()
    q = {"contents": [{"role": "user", "parts": [{"text": "What is the weather forecast for Oxford, UK tomorrow? One sentence."}]}],
         "tools": [{"google_search": {}}], "generationConfig": {"maxOutputTokens": 300}}
    plain = {"contents": [{"role": "user", "parts": [{"text": "Say OK."}]}], "generationConfig": {"maxOutputTokens": 20}}
    for model in MODELS:
        print(f"\n== {model}")
        code, data, secs = call(model, key, plain)
        print(f"   plain request: HTTP {code} in {secs:.1f}s" + ("" if code == 200 else "\n      " + reason(data)))
        code, data, secs = call(model, key, q)
        if code == 200:
            cand = (data.get("candidates") or [{}])[0]
            meta = cand.get("groundingMetadata", {})
            chunks = meta.get("groundingChunks", [])
            text = "".join(p.get("text", "") for p in cand.get("content", {}).get("parts", []) if not p.get("thought"))
            print(f"   GOOGLE SEARCH: OK in {secs:.1f}s, {len(chunks)} source(s), queries={meta.get('webSearchQueries')}")
            print(f"      answer: {text[:160]!r}")
        else:
            print(f"   GOOGLE SEARCH: HTTP {code} in {secs:.1f}s\n      " + reason(data))
        time.sleep(4)


if __name__ == "__main__":
    main()
