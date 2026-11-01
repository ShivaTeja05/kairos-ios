# kairos-mesh: one agent across all your devices

**Goal:** from any device you own, of any brand, ask Kairos to do something. The agent on the device that holds
what's needed does it there, under that device's own safety rules, and the answer comes back to you.

> Ask on your Android phone's browser: "what's on tomorrow, and text Priya I'll be late". The iPhone reads its own
> calendar and prepares the text. Face ID appears **on the iPhone** before anything is sent.

This repo builds that layer on its own, so the existing hub (`tempo-hub`) stays untouched until we merge
(`docs/tempo-hub-routes.patch` holds the routes for that merge).

## 0. The vision: one Jarvis for all your devices

Whichever device you're holding, you can reach the others over the internet:

| # | Capability | On the market? |
|---|---|---|
| 1 | From the Mac, get information that lives on the iPhone, with the phone not with you | Partly (OpenClaw push-wakes its iPhone app for a few features; iCloud covers data that's already synced) |
| 2 | From the iPhone, while out, make the Mac do a job | Yes (Claude Dispatch, OpenClaw, Rabbit OS3) |
| 3 | Several agents at once, e.g. one busy on the iPhone while another starts a new job | Yes, in parts (OpenClaw, UFO³; `tempo-hub`'s conductor runs up to 5 in parallel) |
| 4 | **Agents that move between devices** as the job needs, carrying their goal, notes and permissions | **No product found.** Research only (UFO³, Unified Agent). The 1990s "mobile agents" idea (General Magic's Telescript) was largely dropped over security |
| 5 | **All of it together** | **No** |

**Kairos's answer to the old security problem:** an agent that arrives on a device can only ask. The device's own
agent does the step under its own rules, and anything risky needs Face ID on that device.

**When a device is away:**
- The other devices answer from the private copy the hub keeps: health, location and notifications today; calendar, notes and a file index next.
- Anything only the absent device can do waits, and that device gets a notification.

**Operating other iPhone apps (WhatsApp, Uber, …) works on our own phone,** through the iCTRL UI-automation runner
(kairos-ios Phone operator). OpenClaw's iPhone app doesn't do this; its docs describe app control only on Android.
The conditions come from `phone-control/keep_ictrl_alive.sh` and `start_ictrl.sh`:

| Condition | Effect |
|---|---|
| The runner dies whenever the phone locks | A locked phone in a pocket: no app control |
| Restarting it needs the iPhone visible to the Mac's Xcode (cable or same Wi-Fi) and unlocked | It can't be restarted remotely |
| Developer Mode + Enable UI Automation | Our own phone, yes; App Store users, no |
| A free Apple ID build expires after 7 days | Rebuild weekly |

**"Home phone" mode:** iPhone on a charger, Auto-Lock off, runner alive. A task reaches the Kairos app over the
internet, and the app drives other apps through iCTRL on loopback (`127.0.0.1:8200`). The Mac doesn't need to be on
the same Wi-Fi once the runner is up.

**Routing rule:** before sending a phone task, check the phone's hands (iCTRL `whoami` / `is_locked`):
1. Unlocked with the runner alive: operate apps.
2. Otherwise: Kairos's own tools (calendar, reminders, contacts, alarms, health, its own data), when the phone is woken.
3. Otherwise: answer from the hub's copy, or wait and tell the person.

## 0b. First target: two devices, both ways, one shared context

Focus on the **iPhone and the MacBook** first. Other devices come later.

**Both ways:**
- The iPhone can give the Mac work (find a file, research something, use an app).
- The Mac can give the iPhone work. The phone's own `KairosAgent` does it with its tools and Face ID, or uses iCTRL for other apps when the runner is up.
- A worker can move between the two mid-task.

**One shared context** ("Jarvis is the same on both devices"):
- Neither device keeps the conversation to itself. The hub keeps three things:
  1. **one conversation:** turns from both devices, each tagged with where it was said;
  2. **a task board:** every running worker, which device it's on now, its progress, and which device started it;
  3. **device states:** awake or locked, and whether app control is available.
- An AI's context window is per request, so we don't literally share one. **Every time you speak, on either device, that device's window is rebuilt from the shared state.** That's how the Mac can answer "how's my flight search going?" about a task you started on the iPhone five minutes ago.
- **Progress reaches whichever device you're talking to.** This lifts two things the iPhone app already does for one device up to the hub: `VoiceContextBridge` (live updates into a call) and `PhoneContext` ("what's happening right now").
- **Follow-ups work across devices.** "Make it 8 instead" on the Mac resolves against the task board, even when the alarm was set on the iPhone.

**OpenClaw on the Mac:** its Mac node runs commands (with an approval prompt for each), controls the computer, and
has browser and MCP commands ([docs](https://docs.openclaw.ai/platforms/macos)). It could become the Mac's "hands"
behind the Kairos Mac agent, so Kairos keeps the brain and the veto. Its docs don't say how another program triggers
those commands; check its [macOS IPC](https://docs.openclaw.ai/platforms/mac/xpc) and Gateway docs first. Until then,
`laptop_agent.py` is the Mac's hands.

**Market check:** chat apps already keep one conversation across your devices. What we didn't find is a live task
that you start by voice on one device, then check and steer by voice from another, while the work itself moves
between both devices.

---

## 1. Is anyone already doing this? (checked 30 Oct 2026)

**"Nobody lets you reach all your devices" is false.** **OpenClaw** already does it: an MIT-licensed project with
393k GitHub stars, self-hosted, with nodes on macOS, iOS, watchOS, Android and any OS. Reviewers will know it.
Cross-device agents are also an active research problem that nobody has solved.

✅ = checked against the primary source this session. Rows without ✅ come from the research agent's report, with
their sources, and were not re-checked.

| Who | What works across devices | Brain | Approval for a risky action |
|---|---|---|---|
| **OpenClaw** ✅ ([repo](https://github.com/openclaw/openclaw), [nodes](https://docs.openclaw.ai/nodes), [policy](https://docs.openclaw.ai/nodes/command-policy), [iOS](https://docs.openclaw.ai/platforms/ios)) | A self-hosted Gateway reaches node devices: camera, location, screen, notifications, `system.run`, and contacts/calendar on some platforms. iOS app on the App Store (iOS 26.2+), woken by push; Tailscale Serve for remote access | **The Gateway.** Nodes are "peripherals, not gateways" | An operator-approved command allowlist at the Gateway ("deny always wins"), plus the device's own OS permissions. No per-request Face ID on the device doing the work is described |
| **Microsoft UFO³** ✅ ([paper](https://arxiv.org/abs/2511.11332)) | A request becomes a graph of subtasks across machines; 70.9% task success on 55 tasks | A central orchestrator | Not the focus |
| **DevicesWorld** ✅ ([paper](https://arxiv.org/abs/2607.13465), SJTU + Honor) | A benchmark of 6,140 tasks across mobile, desktop and IoT | — | — |
| **Unified Agent** ✅ ([paper](https://arxiv.org/abs/2608.05729), UCSD) | Argues for state carried across devices and moments | One agent | — |
| Claude Dispatch ([support](https://support.claude.com/en-us/articles/13947068-assign-tasks-from-anywhere-in-claude-cowork)) | Assign a task on the phone; it runs on the desktop | Cloud | A push to the phone that asked, not to the machine doing the work |
| Rabbit OS3 ([report](https://www.helpnetsecurity.com/2026/09/23/rabbit-os3-ai-agent-now-available/)) | A cloud agent drives up to 5 Windows, Mac or Linux machines; phones are only chat channels | Cloud | — |
| Copilot phone plugin ([support](https://support.microsoft.com/en-us/topic/using-the-phone-plugin-with-microsoft-copilot-9e7182b4-22b8-4940-ae24-7b3be04bb646)) | A Windows PC texted, read messages and set alarms on a linked **Android** phone; being retired (May 2026) | Cloud | — |
| Apple, Google, Samsung, Huawei, Amazon | Each works across its **own** brand's devices; the brain is in the cloud or tied to the platform | Cloud / platform | Platform-specific |

DevicesWorld's numbers show how open the problem is: the best of 5 frontier systems succeeded on **12.5%** of
tasks. Agents confused which device was the source and which the output, or stopped early.

**What's honestly still open, and what Kairos already has the pieces for:**
1. **Each device is an agent, not a peripheral.** The iPhone runs `KairosAgent` with its 57 tools and answers from
   its own data. Only the answer travels, not the calendar or the contacts. This is MinionS's "send the question to
   the data". OpenClaw sends a device's data to the Gateway's model.
2. **The device doing the work holds the veto.** A request from another device still goes through the iPhone's
   `SafetyGate` and `OwnerPolicy`, and anything risky needs **Face ID on that iPhone**. The relay only routes, so a
   compromised relay can't approve anything; v2 makes approvals Secure Enclave signatures.
3. **Built for people who aren't confident with technology,** in Telugu and Hindi. OpenClaw is a power-user tool:
   CLI, operators, allowlists in config.
4. **A router trained for this** (`kairos-models`): act only on what the owner said, ask when a detail is missing,
   and hand hard work to a bigger device.

**The defensible one-liner:** *"OpenClaw turned your devices into peripherals of one agent. Kairos makes each device
an agent that keeps its own data and its own veto."*

---

## 2. Borrow, don't rebuild

| Take | From | How we use it |
|---|---|---|
| **Agent Card + task states** | [A2A](https://a2a-protocol.org/v1.0.0/specification/) (Apache-2.0, v1.0, Linux Foundation) | Each node's card lists its skills; tasks use A2A states, with `input-required` meaning "waiting for Face ID". Speaking A2A's shapes keeps the door open to other agents |
| **Pairing that needs approval; deny always wins; a node can't widen its own powers** | [OpenClaw command policy](https://docs.openclaw.ai/nodes/command-policy) (MIT) | A new device, or a node adding skills, waits for the owner's OK; a deny list beats any allow |
| **Signed HTTPS polling for the watch** | [OpenClaw nodes](https://docs.openclaw.ai/nodes) | watchOS blocks ordinary low-level networking, so the watch polls over HTTPS with signed requests |
| **Push wake that never stores the raw APNs token at the gateway** | [OpenClaw iOS](https://docs.openclaw.ai/platforms/ios) | When we add push: a relay holds the token, not the hub |
| **Reaching home from anywhere** | [Tailscale Serve](https://docs.openclaw.ai/platforms/ios) / [headscale](https://github.com/juanfont/headscale) (BSD-3) | v1 remote path; no NAT traversal of our own |
| **Dial by public key, direct links** | [iroh](https://github.com/n0-computer/iroh) (MIT/Apache, Swift bindings) | v2: device identity = key, phone ↔ laptop direct |
| **Task graph across devices** | [UFO³](https://arxiv.org/abs/2511.11332) (Microsoft, open source) | Multi-device requests become a small graph of subtasks run in parallel |
| **Results are data, never instructions** | [CaMeL](https://arxiv.org/abs/2503.18813), [design patterns](https://arxiv.org/abs/2506.08837), [Progent](https://arxiv.org/abs/2504.11703) | A node never acts on text from another node's result; the target's gate uses deterministic rules |
| **Android as a target device** | [DroidRun](https://github.com/droidrun/droidrun) (MIT, works with Ollama) | Later: an Android node that acts through the accessibility service |
| **Voice from a watch or a browser** | [LiveKit Agents](https://github.com/livekit/agents) (Apache-2.0, self-hostable, Swift SDK) | Later: voice transport into the hub |
| **How to measure it** | [DevicesWorld](https://arxiv.org/abs/2607.13465) | Our own personal-device test set, scored the same way: did each device do its part, was the source/output device right |

**Not taking:** libp2p (its iOS support is a proof of concept), Syncthing (file sync, not commands), Open Interpreter
01 (AGPL), KDE Connect as a transport (the iOS app is unreliable in the background). Learn from them; don't depend on
them.

**Build on OpenClaw instead?** Possible: Kairos's iPhone agent could register as an OpenClaw node that exposes one
command, `kairos.ask`, and run it through `KairosAgent` + Face ID locally. That gives us OpenClaw's Gateway, pairing,
Tailscale and chat channels for free. The cost: a large TypeScript codebase to learn, and our differentiator would
sit inside someone else's Gateway-centred design. **Plan:** keep our own small relay (it's already written and
matches `tempo-hub`), and make the node side protocol-agnostic so an OpenClaw bridge can come later.

---

## 3. Design

### Nodes and cards
- A **node** is a device running a Kairos agent: the iPhone app, `node.py` on Mac, Windows or Linux, and later a watch or glasses through the phone.
- Each node publishes a **card**: its name, platform, skills (tool names and summaries), and how it can be woken.
- The card follows A2A's Agent Card idea, so other agents could read it.

### Tasks
- A task is plain words plus who asked, sent to one node.
- States follow A2A's task lifecycle: `submitted` → `working` → `input-required` (waiting for the owner's approval on that device) → `completed`, `failed` or `rejected`, plus `expired` when nobody picks it up in time.
- **Results from another node are data, never instructions.** A node never acts on text that came from another device's result. This is the rule CaMeL and the prompt-injection design-patterns paper both call for, and it stops an injection hopping from device to device.

### The relay (hub)
- **Routes tasks; never runs them.** A FastAPI + SQLite service, small enough to merge into `tempo-hub`.
- **Logs every task as a hash-chained event**, so "what did my devices do for each other today?" has a verifiable answer.

### Waking a device
This is the hard part, and it's different for each device:

| Device | How it gets work | Notes |
|---|---|---|
| Mac / Windows / Linux | Long-poll: always connected | Works today |
| iPhone, app open | Long-poll while in the foreground | Demo path |
| iPhone, in the background | **Visible notification:** "Your MacBook asked: what's on tomorrow?" Tapping it opens Kairos, which runs the task. Approve/Deny actions can need Face ID (`.authenticationRequired`) | Apple throttles silent pushes (2–3 an hour, best effort), so they can't be relied on. Push needs a paid Apple developer account |
| iPhone, multi-step work | A "Kairos is working" Live Activity, started by push | Whether App Review allows this for agent work is unverified, so try it last |
| Watch, glasses | Go through the phone node | Later |

### Connectivity
- **v1:** the relay on the home network, plus the existing HTTPS tunnel.
- **v2:** Tailscale or iroh. You address a node by its public key; traffic goes through a relay at first and upgrades to a direct link (about 90% of connections in Tailscale's and iroh's measurements).
- We don't build NAT traversal ourselves.

### Identity and permission
- **v1:** device tokens, the same model as `tempo-hub`.
- **v2:**
  - Each node's identity is a **Secure Enclave P-256 key**.
  - Each task carries a **narrowed, short-lived capability** (UCAN-style), so a node can check what's allowed without trusting the hub.
  - A lost device is handled by revoking its key and its delegations.
- **Approvals are signatures:** Face ID unlocks a Secure Enclave key, which signs a hash of the exact action. A compromised relay can't forge them.

### Deciding which device does the work
1. **Hard rules first:** private data stays on its device, and the device that holds the data does the work.
2. **Then skills:** only nodes whose card lists the tool.
3. **Then compute:** the small model on the device, escalating to the larger model on the Mac. This is MinionS's "send the question to the data": the Mac plans, and the phone's small model reads the phone's private data.
4. **Later:** `kairos-router`, the fine-tuned model in `kairos-models`, makes this decision.

### Multi-device requests
- "Check my calendar, find the PDF, and text Priya" becomes a **small graph of subtasks**, in the spirit of UFO³: phone, laptop, then phone (needs Face ID).
- Independent subtasks run in parallel.
- Each step is checkpointed in the event log, so a failed step can be retried without repeating finished side effects (idempotency keys).

---

## 4. Build order

| Step | What | Shows |
|---|---|---|
| 1 | Relay: pairing, cards, tasks (A2A states), long-poll, hash-chained log, tests | The protocol works |
| 2 | `node.py` for Mac / Windows / Linux: safe local skills (battery, find and read files in Documents, open an app), with a local model to pick the skill | A computer answers a request from another device |
| 3 | "Ask any device" web page served by the relay, for any phone or laptop browser | Any brand can ask |
| 4 | iPhone node in kairos-ios: foreground long-poll → `KairosAgent.handle(source: .remote)` → result; Face ID card on the phone for risky actions | The headline demo |
| 5 | Our own cross-device test set: ~30 tasks across iPhone, Mac and a browser, scoring success, latency and whether approvals were honoured | A number, not a claim |
| 6 | Push wake for the iPhone, device keys, signed approvals, multi-device task graphs | The rest of §3 |
| 7 | Merge into `tempo-hub` | One hub |

## Sources
- UFO³: https://arxiv.org/abs/2511.11332
- DevicesWorld: https://arxiv.org/abs/2607.13465
- Unified Agent: https://arxiv.org/abs/2608.05729
- A2A specification: https://a2a-protocol.org/v1.0.0/specification/
- Apple background pushes: https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app
- Notification actions that need authentication: https://developer.apple.com/documentation/usernotifications/unnotificationactionoptions/authenticationrequired
- Live Activity push: https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications
- Tailscale NAT traversal: https://tailscale.com/blog/how-nat-traversal-works
- iroh relays: https://docs.iroh.computer/concepts/relays
- Secure Enclave keys: https://developer.apple.com/documentation/security/protecting-keys-with-the-secure-enclave
- UCAN: https://github.com/ucan-wg/spec
- MinionS: https://arxiv.org/abs/2502.15964
- CaMeL: https://arxiv.org/abs/2503.18813
- Design patterns against prompt injection: https://arxiv.org/abs/2506.08837
- Prompt Infection (agent-to-agent injection): https://arxiv.org/abs/2410.07283
- Progent: https://arxiv.org/abs/2504.11703
