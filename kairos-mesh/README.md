# kairos-mesh

**This folder is the Mac hub of Kairos.** It joins your iPhone and your Mac into one assistant over a private
Tailscale network. For the whole system, start with the [main README](../README.md). The iPhone app is in
[kairos-ios/](../kairos-ios/), and the current architecture, checked against the code, is in
[docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md).

**One agent across all your devices, where each device keeps its own data and its own veto.**

From any device you own, ask Kairos to do something. The agent on the device that holds what's needed does it
there, under that device's own safety rules, and the answer comes back. Every device shares one conversation and one
task board, so you can start something on your iPhone and ask your Mac how it's going.

- **Why, prior art (OpenClaw, UFO³, DevicesWorld), what we borrow:** [docs/DESIGN.md](docs/DESIGN.md)
- **Plan and phases:** [docs/PLAN.md](docs/PLAN.md)
- **Architecture diagrams (design notes from 30–31 Oct), each with a note on the motive and the use case:** [docs/architecture/](docs/architecture/README.md)

## Status (checked 1 Nov 2026, phase 1)

Status words, as in the main README: *run on device* = seen working on the real iPhone or Mac · *built* = code
exists and is wired in, not yet run end to end · *planned* = only in the plans. *Tested* means the hub's pytest tests
cover it.

| Piece | State |
|---|---|
| Hub (`mesh/`): joining, pairing codes, device cards, tasks with A2A states, long-poll | Run on device; tested |
| Hash-chained log, checked at `/api/log/verify` | Built, tested |
| Shared brain: one conversation across devices, task board, context rebuilt per device | Run on device; tested |
| Jarvis, the hub brain (`mesh/brain.py`, `/api/ask`): a local model (Ollama, no key) hands work to devices and answers; plain rules if the model fails | Run end to end on the Mac with `qwen2.5:7b`; tested |
| Rules first in the brain: a request naming one device goes straight there, with no model call | Built, tested |
| Task leases: a task handed to a device that just died goes back in the queue after 30 s | Built, tested; seen working with the app in the iOS Simulator (killed mid-poll) |
| Mac node (`node/`): the Mac's agent with five safe tools (battery and disk, find files, list a folder, read a file, open an app) | Run on device; tested |
| Web page (`web/`): talk or type from any browser; conversation, devices, task board | Run on device (in the Mac's browser) |
| **iPhone node**, in the iPhone app: `kairos-ios/TempoApp/Agents/Mesh/MeshNode.swift`, plus the `.remote` source in `KairosAgent` | Run on device: first in the iOS Simulator, then on the real iPhone over the USB cable and over **Tailscale** |
| Mac → iPhone over Tailscale (the hub shared with `tailscale serve`: HTTPS, tailnet only) | Run on device (31 Oct): an answer from the iPhone's calendar in 0.4 s |
| iPhone → Mac (`ask_my_mac`, in `kairos-ios/TempoApp/Agents/Mesh/DevicesAgent.swift`) | Run on device in the 31 Oct on-phone self-test (the Mac's battery, a file search). Asking from the Talk button not yet tried |
| Pairing: 6-digit codes, and a QR link from `kairos pair` or "Add a device" | Codes run on device; QR link built |
| Hub hardening: Host check, Funnel refused, API docs off, optional owner check | Built, tested |
| `kairos` command (`scripts/kairos up/status/down/pair/install`) | `up` and `status` run on device; `down`, `pair` and `install` built (`install`, start at login, not run yet); tested |
| **One Kairos in the iPhone app** (one engine behind the big button; the old ElevenLabs/tempo-hub call off behind a flag) | Built, reviewed, installed on the real iPhone (31 Oct); the end-to-end check on the phone is still to do |
| The phone's brain without Gemini: what the phone's rules don't know goes to the Mac's open model (`/api/ask`) | Built (Settings › Who thinks for Kairos); not yet run in the self-test. The open model can't use the phone's own tools yet |
| Push wake, device keys, signed approvals, OpenClaw as the Mac's hands, merge into tempo-hub | Planned (later phases) |

**iPhone node, run in the Simulator (30 Oct, about 23:30):**

| From the Mac | What happened on the iPhone | Result |
|---|---|---|
| Pair with `kairos://mesh?hub=…&code=…` | Joined, sent a card with **56 skills** (all its tools at the time except `allow_without_asking`, which other devices may never use) | Worked |
| "What's on my iPhone calendar tomorrow?" | `KairosAgent` rules → Time helper read the calendar | Worked: "There's nothing in your calendar for tomorrow." in **6.5 s** |
| "Call [a contact] from my phone" (one of the Simulator's sample contacts) | Call card **forced** on the phone; the board showed **"waiting for owner"**; Yes + **Face ID** on the phone | Completed: "Calling [name]'s mobile. Tap Call on the screen to start." (the Simulator can't place calls) |
| "Put the dentist in my iPhone calendar tomorrow at 3pm" | Not a rule match; the phone needs its model, and the Simulator had no Gemini key | Failed, honestly: "I need a Gemini key"; the board says no tool was used |
| App killed mid-poll, task sent, app relaunched | The task went to the dead poll, was **requeued 30 s later**, and the relaunched app answered it | Worked |

**What building it taught us:**
- **An unsigned Simulator build can't use the Keychain,** so the login was silently lost. `MeshNode` now also keeps the login in memory and logs loudly if the Keychain refuses it.
- **A long-poll can hand a task to a device that just died.** Leases fix it.
- **The local model sometimes says "I'll add that" without making the call,** and answered a repeat question from memory. Rules first fixes both for requests that name a device.
- **On a phone with no passcode, `OwnerCheck` accepts the Yes tap alone.** For requests from other devices we should probably require a passcode. Not done yet.

**On the real iPhone (iPhone 12 Pro Max, 31 Oct):**
- Paired over plain http at the Mac's `.local` name, port 8778 (before the hub checked Host names; today that address needs `KAIROS_MESH_HOSTS`, see Run it, step 5). From the Mac, "What's on my iPhone calendar tomorrow?" came back from the real phone's calendar in **0.8 s**.
- **That worked only over the USB cable.** The phone reached the Mac over the cable's own link (`169.254.x`). Over the Wi-Fi we were on, it couldn't reach the Mac's Wi-Fi address: the network seems to stop its devices talking to each other, as many campus and guest networks do.
- **"Couldn't reach Kairos. Check the Wi-Fi and your Mac."** isn't the mesh. It comes from the old Talk voice call (`TempoSession.swift`), which needs tempo-hub's voice server. Requests from other devices come in through "Kairos on this phone". That is why the app had "two Kairos", and why it now has one (below).
- **The fix for the Wi-Fi, and for "my phone isn't with me", is Tailscale:** a private network between your own devices that works over any connection. On 31 Oct the Mac couldn't sign in. The secure connection to `controlplane.tailscale.com` opened, then nothing came back. At the same time Tailscale's status page showed an incident, "Coordination service issues" (investigating since 30 Oct 23:56 UTC). The rest of the internet, and `tailscale.com` itself, worked.
- **Once the incident ended (00:40 UTC), Tailscale worked.** Both devices joined the tailnet. The phone reaches the Mac through Tailscale's relay (about 95 ms), because this Wi-Fi blocks a direct link. The hub now listens only on `127.0.0.1`, and `tailscale serve` shares it at `https://<mac>.<tailnet>.ts.net`, reachable only inside the tailnet. The phone paired at that address. "What's on my iPhone calendar tomorrow?" asked on the Mac came back from the phone in **0.4 s**.
- **Why HTTPS through `tailscale serve`, not plain http to the Mac's 100.x address:** iOS (App Transport Security) refuses plain http to Tailscale's 100.64/10 addresses and to `*.ts.net` names, so that route would need an exception in the app. `serve` uses a real certificate, so the app needs no change. It also adds `X-Forwarded-For`, so the hub never mistakes a tailnet request for this computer: those requests still need a pairing code. The first certificate took about 30 s to arrive.
- **The iPhone asked the Mac too.** In the on-phone self-test (31 Oct), the iPhone asked the Mac twice, for its battery and for a file search, and both answers were real. Asking the Mac from the Talk button hasn't been tried yet.
- **iCTRL (the phone's "hands") stops whenever the phone locks.** Start the runner again after unlocking. The first run also needs the developer certificate trusted on the phone (Settings › General › VPN & Device Management). Our crash fixes for iCTRL are in [kairos-ios/Tools/iCTRL/](../kairos-ios/Tools/iCTRL/README.md).

**One Kairos in the app (31 Oct, night):**
- **Before:** the big button started an ElevenLabs call to tempo-hub (not running, so "Couldn't reach Kairos"), started by itself on every open; "Kairos on this phone" was a second, separate agent.
- **Now:** the big button, Siri "Talk to Kairos", `kairos://talk` and "More" all use the one on-phone agent (`KairosAgent` + `AgentVoice`, speech to words on the phone). Rules first (alarms, reminders, calls, calendar, "… on my Mac"); what they don't know goes to the person's chosen brain: **your Mac** (the hub's open model, no key, the default without a Gemini key) or Gemini. The microphone never opens without a tap.
- **One conversation:** what is said on the phone is added to the hub's conversation (`/api/turns`; what a letter or the screen said stays on the phone), and the phone learns what was said on the Mac by asking the hub's brain, which holds the whole conversation.
- **A line under the title says where the Mac is,** in plain words: connected (private Tailscale link), Tailscale off on this iPhone, the Mac asleep, Kairos not running on the Mac, or not joined. Tap it to try again.
- **Pairing by QR** (built; not yet tried on the real phone): `kairos pair` or "Add a device" shows a QR of `kairos://mesh?hub=https://<mac>.<tailnet>.ts.net&code=…`. Kairos asks first, then Face ID, and the join counts only if the connection really went through Tailscale (a 100.x / `fd7a:115c:a1e0::` address), so a public Funnel name with the same `.ts.net` ending is refused.
- **Kept, switched off:** the old ElevenLabs call, the Shield badge, Write for me and the tempo-hub payment cards (`TempoSession.legacyVoice`, UserDefaults `kairos.legacy_voice`). We plan to delete them later.
- **Reviewed adversarially** (3 lenses: correctness, security, regressions); 36 findings, the real ones fixed, including: Join on the pairing alert did nothing; the green "Connected" showed before the Mac had answered; "Nothing goes to Google" wasn't true for the research and worker helpers; a Funnel name could pose as "your Mac".

**First real run** (`scripts/demo_two_devices.py`, on our Mac, `qwen2.5:7b`):
1. On the iPhone stand-in, *"What's my Mac's battery and free disk space?"*: the brain gave the job to the Mac's node, which checked itself and answered (54%, charging; 139.4 GB free).
2. On the Mac, *"What did I just ask from my iPhone?"*: answered from the shared conversation.
3. On the Mac, *"What's on my iPhone calendar tomorrow?"*: the job went to the iPhone, and its answer came back. That answer is the **stand-in's fixed text**, not a real calendar.

**What the run taught us about the model:**
- `qwen2.5:7b` first asked "when is tomorrow?" (over-asking). Worked examples in the prompt fixed that.
- It then wrote the tool call as text. The brain now accepts a well-formed written call and flags it (`via: "model (call written as text)"`).
- Both are failures the planned router training is meant to fix ([note 08](docs/architecture/08-router-training.md); that work, kairos-models, isn't in this repo).

## Run it

Needs Python 3.10 or newer (we use 3.12) and [Ollama](https://ollama.com) with `qwen2.5:7b` (or set
`KAIROS_MESH_MODEL`). The tests need neither Ollama nor Tailscale. The hub uses port **8778**.

```bash
cd kairos-mesh                                        # from the top of this repo; every command below runs here
uv venv --python 3.12 .venv                           # or: python3.12 -m venv .venv
uv pip install --python .venv/bin/python fastapi uvicorn httpx segno pytest   # or: .venv/bin/pip install ...
.venv/bin/uvicorn mesh.app:app --port 8778            # the hub (this Mac only); 'scripts/kairos up' shares it on your tailnet
.venv/bin/python -m node.mac_node                     # the Mac's agent node, in another terminal
open http://localhost:8778                            # the web page: talk to Kairos from the Mac's browser
.venv/bin/python scripts/demo_two_devices.py          # the two-device demo (a labelled iPhone stand-in)
```

Install the dependencies by name, as above: `pip install -e .` doesn't work yet, because `pyproject.toml` doesn't
list its packages. The venv must be `kairos-mesh/.venv`, because `scripts/kairos` uses it.

**The real iPhone app** (in [kairos-ios/](../kairos-ios/)):
1. Build and install it, as [its README](../kairos-ios/README.md) says.
2. Install Tailscale on the Mac and the iPhone with the same account (on the iPhone, VPN On Demand keeps it on).
3. On the Mac: `scripts/kairos up` (the first time, Tailscale asks you to allow Serve and HTTPS for your tailnet), then `scripts/kairos pair`, or tap **Add a device** on the Mac page.
4. On the iPhone, scan the QR code with the Camera, or open `kairos://mesh?hub=https://<mac>.<tailnet>.ts.net&code=<code>`, or type both into Settings › Your Mac. Only your tailnet can reach the hub.
5. Without Tailscale: start the hub with `--host 0.0.0.0` and `KAIROS_MESH_HOSTS=<name>.local,<the Mac's Wi-Fi or USB IP address>` (the hub answers only the names it is told; anything else gets `400 Invalid host header`). On Wi-Fi that blocks device-to-device traffic, this works only with the USB cable plugged in.
6. The phone takes tasks only while Kairos is open on screen.

```bash
.venv/bin/python -m pytest -q                         # 61 tests, with a fake model and fake Tailscale
```

## The `kairos` command

`scripts/kairos <command>` runs `mesh/ctl.py` with `kairos-mesh/.venv` (it finds this folder even through a symlink).
Every check prints one line: `OK  ...`, or `FIX ...` followed by what to do.

| Command | What it does |
|---|---|
| `kairos status` | Changes nothing. Checks: Tailscale on and signed in; MagicDNS and HTTPS certificates on; Serve sharing HTTPS 443 → `http://127.0.0.1:8778`; no raw TCP forward to the hub; no Funnel reaching the hub; Ollama has the model (`KAIROS_MESH_MODEL`, default `qwen2.5:7b`); the hub answers; the Mac node runs; the tailnet address answers; each iPhone online, direct or through a relay; Tailscale keys not expiring within 14 days. Exit code 0 when all are OK. |
| `kairos up` | Safe to run again. Opens Tailscale if it's off. Shares the hub on HTTPS 443 inside your tailnet, only when that isn't set up yet; this also turns Funnel off on 443. Starts the hub (under `caffeinate -s`) and the Mac node if they aren't running. Waits up to 90 s for the first certificate, then prints `status`. Stops with a FIX line (exit code 2) if you need to sign in, approve Serve, or remove a raw TCP forward to the hub. Never runs `tailscale serve reset`. |
| `kairos down` | Stops the hub and the Mac node that runs from this folder. Tailscale and Serve stay as they are, so the iPhone says Kairos isn't running on your Mac. |
| `kairos pair` | A 6-digit code, the `kairos://mesh?hub=...&code=...` link and a QR code in the terminal, made for "this computer" without a new login. On the iPhone, open the Camera and point it at the code. Tailscale must be on. |
| `kairos install` | Starts the hub and the node at login, and restarts them if they stop (LaunchAgents `com.kairos.hub` and `com.kairos.macnode`; logs in `~/Library/Logs/kairos-*.log`). Refuses if something else is using port 8778. Settings like `KAIROS_MESH_OWNER` and `KAIROS_MESH_HOSTS` are copied in only if they are set when you run it. |
| `kairos uninstall` | Removes those LaunchAgents. |

We haven't run `install` yet: on our Mac, the hub and node run from `kairos up` until the Mac restarts.

Settings:
- `KAIROS_MESH_OWNER=<your Tailscale login>`: only your devices get in through `tailscale serve`. Off by default. Check the hub log first: it logs which Tailscale login each tailnet request carries.
- `KAIROS_MESH_HOSTS=<names,addresses>`: extra Host names the hub answers. Only needed without Tailscale, e.g. `my-mac.local,192.168.1.20`.
- `KAIROS_MESH_PUBLIC_URL`: overrides the tailnet address used in pairing links.
- `KAIROS_MESH_MODEL` (default `qwen2.5:7b`) and `KAIROS_MESH_MODEL_URL` (default Ollama at `http://127.0.0.1:11434/v1`; any OpenAI-compatible endpoint): the brain's model. The Mac node uses the same model unless `KAIROS_NODE_MODEL` is set.
- `KAIROS_MESH_TZ` (default `Europe/London`): the time zone of the date and times the brain gives the model.
- `KAIROS_MESH_DB`: where the hub keeps its SQLite database (default `data/mesh.db`, git-ignored).

The hub is never reachable through Funnel: requests that come through Funnel get 403. Funnel on another port, for another app, is left alone.

## How joining works
- **The Mac running the hub joins by itself.** Its node and its browser page share one device identity, with a separate login each.
- **Any other device joins with a 6-digit code** made on a joined device ("Add a device"). Each code works once and lasts 10 minutes.
- **Guessing is capped for the whole hub:** after 20 wrong codes in 10 minutes, joining pauses for everyone (joined devices carry on). With codes at 1 in a million, that keeps guessing hopeless even if the hub is reachable through a tunnel.
- **A request through a tunnel is never treated as "this computer",** even though it arrives from loopback: its forwarding headers give it away, and "this computer" must also be addressed as `127.0.0.1` or `localhost`. Never share the hub with a raw TCP forward (`tailscale serve --tcp`): it adds no headers, so `kairos status` flags it.

## Layout
```
mesh/store.py     devices, pairing, cards, tasks, the shared conversation, hash-chained log (SQLite)
mesh/brain.py     Jarvis: context rebuilt per device, rules first, then a local model with ask_device; plain rules if it fails
mesh/app.py       the hub's HTTP API and the web page (Host check, Funnel refused, optional owner check)
mesh/tailnet.py   read-only Tailscale helpers: the hub's own tailnet URL, pairing links
mesh/ctl.py       the `kairos` command (scripts/kairos): up, status, down, pair, install, uninstall
node/mac_node.py  the Mac's agent: joins, sends its card, long-polls for tasks, runs them, reports progress
node/mac_tools.py the Mac's five safe tools (Documents, Desktop and Downloads only; secrets refused; file text = information)
web/index.html    one conversation, your devices, the task board
scripts/          kairos (the command), demo_two_devices.py (two-device demo with a labelled iPhone stand-in)
tests/            61 pytest tests, with a fake model and fake Tailscale
docs/             design, plan, architecture diagrams (design notes), tempo-hub-merge/ (for the later merge),
                  frontend/ (an earlier version of the web page)
pyproject.toml    name, Python version and dependencies
data/             made on first run and git-ignored: the hub's SQLite database, and the Mac node's login when
                  `kairos up` or `kairos install` starts it (a node started by hand keeps it in ~/.kairos-mesh/)
```
