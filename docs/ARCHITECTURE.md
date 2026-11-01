# Architecture

This page explains how Kairos is put together, the iPhone app and the Mac hub, in seven diagrams. Each one says what
it shows, how to read it, and where the code is.

Where the code is: this repo has two parts. The iPhone app is in `kairos-ios/`, and its code is in
`kairos-ios/TempoApp/` (the Xcode project still uses the OxHack name, Tempo). Paths that start with `Agents/`, and bare
file names such as `TempoApp.swift`, `TempoSession.swift`, `ContentView.swift` and `KeyStore.swift`, are under
`kairos-ios/TempoApp/`. The test tools are in `kairos-ios/Tools/`. The Mac hub is in `kairos-mesh/`, and its files are
written in full, such as `kairos-mesh/mesh/app.py`. The hub also has its own notes and eight SVG diagrams in
`kairos-mesh/docs/architecture/`.

Status words, as in the [README](../README.md): *run on device* = seen working on the real iPhone or Mac;
*built* = code exists and is wired in, not yet run end to end; *compiled only* = written in the week to 1 Nov 2026,
builds, not yet run; *planned* = only in plans.

## A few terms first

- **KairosAgent** (`kairos-ios/TempoApp/Agents/Core/KairosAgent.swift`) is the one orchestrator. Almost every request
  goes through `KairosAgent.handle(_:source:images:)`. Siri routines, Siri asking a named helper while a helper is in focus,
  and an approved Siri stash enter at `runToolStep`, `StudioHandoff` or `resumeStashed` instead. All of them use the
  same `run()` and SafetyGate.
- **Source** says where a request came from: `app` (the Talk button or typing), `siriBackground` ("Ask Kairos"),
  `automation` (a Shortcut's "Tell Kairos"), or `remote` (a task from your Mac). A fifth value, `siriForeground`,
  exists but nothing passes it today.
- **Tools.** There are 60, spread across 15 specialist agents listed in `Agents/Core/AgentDirectory.swift`. Each tool
  follows the `KairosTool` contract in `Agents/Core/AgentKit.swift`: a name, a JSON schema, a risk level, an optional
  rules-first `quickMatch`, code checks in `validate`, the card text in `describe`, and `execute`.
- **Risk levels:** `read` (35 tools) < `localWrite` (19) < `reachesPerson` (5) < `money` (1). The SafetyGate uses
  them to decide whether a card and Face ID are needed.
- **Untrusted text.** Text from letters, web pages, pasted messages, Shortcuts and the Mac's answers goes into
  `TurnContext.documents`. It is information, never instructions. The person's own words go into `userWords`.

## 1. System overview

**What this shows:** every machine and service Kairos talks to, and how they connect.

```mermaid
flowchart LR
  subgraph PH["iPhone: the Kairos app"]
    UI["Talk button, typing, Siri"]
    KA["KairosAgent<br/>rules, brain, SafetyGate"]
    TL["60 tools in 15 helpers"]
    MN["MeshNode"]
    IC["iCTRL runner<br/>127.0.0.1:8200, same phone"]
  end
  subgraph TS["Tailscale: your private network"]
    SV["tailscale serve<br/>HTTPS, tailnet only"]
  end
  subgraph MAC["Mac"]
    HUB["kairos-mesh hub<br/>FastAPI and SQLite<br/>127.0.0.1:8778"]
    BR["Hub brain<br/>rules, then qwen2.5:7b"]
    NODE["Mac agent node<br/>5 safe tools"]
    OL["Ollama<br/>127.0.0.1:11434"]
    WEB["Web page<br/>any browser"]
  end
  subgraph CL["Cloud services"]
    GEM["Google Gemini API<br/>owner's own key"]
    OPEN["Open-Meteo, arXiv,<br/>DuckDuckGo (no keys)"]
    SITES["Any website a worker reads"]
    ASR["Apple speech recognition"]
    EL["ElevenLabs<br/>old call, off by default"]
  end
  UI --> KA
  KA --> TL
  TL -->|"operate_app, read_screen"| IC
  KA <--> MN
  MN <-->|"HTTPS"| SV
  SV <--> HUB
  HUB --> BR
  BR --> OL
  NODE --> OL
  NODE <-->|"long-poll for tasks"| HUB
  WEB --> HUB
  KA -->|"words, tool list, phone summary"| GEM
  TL -->|"letter photos, screen text,<br/>worker and research calls"| GEM
  TL -->|"weather, papers, search"| OPEN
  TL -->|"pages and PDFs workers read"| SITES
  UI -->|"speech, when the phone has no<br/>on-device model for the language"| ASR
  UI -.->|"only with kairos.legacy_voice"| EL
```

**How to read it.** Solid arrows are used today; the dotted one is the old voice call, which is off unless a flag is
set. The iPhone does its own work: rules, tools and the SafetyGate all run on the phone. Gemini is the only cloud
language model. It is meant to be used only when the owner picks it as the brain and has saved a key: the main
request path follows this, but not every part has been audited for it yet (see diagram 7). Speech to text stays on the
phone where the language allows; otherwise Apple's speech service is used. iCTRL is a separate test runner
that lives **on the same iPhone**; the app talks to it over loopback, not over the network. Started with `kairos up`,
the Mac hub listens only on `127.0.0.1`, and `tailscale serve` shares it with your own devices over HTTPS. A request
that comes through Tailscale Funnel (the public internet) gets `403`. Without Tailscale, the hub can instead be
started with `--host 0.0.0.0` and the names it should answer to in `KAIROS_MESH_HOSTS`, and the phone then talks to it
over plain http on the Wi-Fi or a USB cable (the 31 Oct USB test used plain http). The Mac node is the Mac's own
agent: it joins the hub by itself as "this computer" (no code, sharing that identity with the Mac's browser page),
while every other device needs a 6-digit code. It answers tasks with five safe tools (battery and disk, find files,
list a folder, read a file, open an app).

Status: *run on device* in both directions. On 31 Oct the Mac asked the real iPhone 12 Pro Max over USB (0.8 s) and
over Tailscale (0.4 s), and the iPhone asked the Mac inside the on-phone self-test. The Talk button asking the Mac
hasn't been tried yet.

**Code:** `TempoApp.swift`, `ContentView.swift`, `Agents/Core/KairosAgent.swift`,
`Agents/Core/ModelProvider.swift`, `Agents/Mesh/MeshNode.swift`, `Agents/Hands/ICTRLHands.swift`,
`Agents/UI/AgentVoice.swift`, `Agents/Workers/WebReader.swift`, `TempoSession.swift`; the hub:
`kairos-mesh/mesh/app.py`, `kairos-mesh/mesh/brain.py`, `kairos-mesh/mesh/store.py`, `kairos-mesh/mesh/ctl.py`,
`kairos-mesh/node/mac_node.py`, `kairos-mesh/node/mac_tools.py`, `kairos-mesh/web/index.html`.

## 2. One request, end to end

**What this shows:** what happens between "Text my son I'll be late" and the spoken reply, including the card and
Face ID.

```mermaid
sequenceDiagram
  participant U as Person
  participant V as AgentVoice
  participant K as KairosAgent
  participant G as Gemini
  participant S as SafetyGate
  participant C as Approval card
  participant T as message_contact
  participant H as Mac hub
  U->>V: taps, then says Text my son I will be late
  V->>V: speech to text (on the phone when iOS has an on-device model for the language, else Apple's speech service), stops after 1.8 s of quiet
  V->>K: handle(words, source: app)
  K->>K: emergency, take-back and keep-watching checks
  K->>K: rules first (quickMatch on each offered tool)
  alt a rule matches
    K->>K: the tool call comes from code, no model
  else no rule matches
    K->>G: words, phone summary, narrowed tool list
    G-->>K: proposes message_contact(person, text)
  end
  K->>S: check(message_contact, arguments)
  S-->>K: confirm, because it reaches a person
  K->>C: Kairos wants to: text your son (also read aloud)
  U->>C: taps Yes, do it
  C->>U: Face ID or passcode (OwnerCheck)
  U-->>C: verified
  C-->>K: approved (no answer in 90 s counts as No)
  K->>T: execute
  T-->>K: an sms link with the note filled in
  K->>U: opens Messages, and the person taps Send
  K->>K: reply built from the tool result, honesty checks
  K-->>V: what to say
  V-->>U: spoken reply
  K-)H: shares the turn (only when paired)
```

**How to read it.** Time runs downwards. The order inside `handleBody` is fixed: code-only checks (emergency,
"can't keep watching", "don't send that"), then rules, then a photo goes straight to `read_letter`, and only then the
model loop. The model loop runs up to 4 steps. In each step Gemini sees only the tools `ToolPicker` thinks the words
call for (plus a small core set), and every call it proposes goes back through the SafetyGate. If the brain is
**Your Mac** instead of Gemini, the phone sends the words to the hub and speaks the hub's text answer; the Mac's model
does not call the phone's tools. At the end, code checks the reply: a claim of an action no tool did, or a number no
tool returned, is replaced with an honest line. A Siri request in the background can't show a card, so the call is
stashed and Siri says "Open Kairos to check it and say yes".

Status: the request path up to the card is *run on device* (in dry runs); the card and Face ID are *built* and have
been seen only in the Simulator.

**Code:** `Agents/UI/AgentVoice.swift` (speech), `Agents/Core/KairosAgent.swift` (`handle`, `handleBody`, `run`,
`askOwner`, `claimsDone`, `numbersGrounded`), `Agents/Core/AgentKit.swift` (`ToolPicker`),
`Agents/Core/SafetyGate.swift`, `Agents/UI/AgentConfirmCard.swift`, `Agents/Specialists/PeopleAgent.swift`,
`Agents/Siri/AgentIntents.swift` (Siri's 12 s budget and the stash).

## 3. The agent map

**What this shows:** the 15 specialist agents KairosAgent can hand work to, and their tools.

```mermaid
flowchart LR
  K["KairosAgent"]
  K --> A1["Your devices<br/>ask_my_mac"]
  K --> A2["Worker agents<br/>spawn_agent, spawn_agents,<br/>agent_status, agent_result, stop_agent"]
  K --> A3["Permissions<br/>allow_without_asking (card),<br/>revoke_permission, list_permissions,<br/>recent_activity"]
  K --> A4["Photo helper<br/>take_photo, share_photo, save_photo"]
  K --> A5["Routines<br/>run_routine, create_routine,<br/>save_last_as_routine, list_routines,<br/>delete_routine"]
  K --> A6["Agent Studio<br/>talk_to_agent, ask_agent, create_agent,<br/>list_agents and 6 more"]
  K --> A7["Research team<br/>research_topic, ask_about_report,<br/>list_reports, share_report"]
  K --> A8["Memory<br/>remember_fact, forget_memory,<br/>what_do_you_remember, recall_conversation"]
  K --> A9["Time helper<br/>set_alarm, set_timer, create_reminder,<br/>add_calendar_event, get_calendar_events"]
  K --> A10["Calls and messages<br/>find_contact, call_contact (card),<br/>message_contact (card), remember_relation"]
  K --> A11["Letter reader<br/>read_letter, ask_letter"]
  K --> A12["Scam Shield<br/>check_scam, call_159 (card)"]
  K --> A13["Money helper<br/>prepare_payment (card), money_question"]
  K --> A14["Everyday helper<br/>what_time_and_date, phone_battery, torch,<br/>get_weather, get_directions, open_phone_setting,<br/>run_my_shortcut (card)"]
  K --> A15["Phone operator<br/>read_screen, operate_app"]
  A1 -.-> X1["kairos-mesh hub"]
  A2 -.-> X2["web pages, PDFs, arXiv"]
  A7 -.-> X3["Gemini Google Search grounding"]
  A15 -.-> X4["iCTRL on the phone"]
  A6 -.-> X5["12 ready-made helpers<br/>data, not code"]
```

**How to read it.** The agents are listed top to bottom in the order the rules try them, which matters: "on my Mac"
is matched before anything else, so the Mac wins. "(card)" marks the six tools that always need the Yes card and
Face ID. Dotted arrows show what an agent reaches outside the app. Agent Studio's 12 ready-made helpers (Medicine
Buddy, Scam Guardian, Letter Helper, Morning Briefer and others) are personas stored as data: each is a name,
instructions and a list of allowed tools. Talking to one ("focus mode") limits the offered tools to that helper's
list, plus a few core tools such as the way back to Kairos. Worker agents are created at run time; up to 3 run at once.

Some details worth knowing:

- **Workers** may finish as "done" only with evidence (a page or PDF they read, a grounded search, arXiv details or
  read-only phone data), and every number they report must appear in text they fetched.
- **The research team** plans 2 or 3 sub-questions, searches with Google Search grounding one search at a time
  (an app-wide pacer keeps to the free tier), and writes a report whose links come only from Google's grounding data.
- **Routines** replay saved steps with no model call, but every step still goes through the SafetyGate.
- **Calls and messages** hand a `tel:`, `sms:` or `wa.me` link to iOS; the person taps Call or Send.

Status: see the table in the [README](../README.md#what-it-can-do).

**Code:** `Agents/Core/AgentDirectory.swift`; the agents live under `Agents/` (`Mesh/DevicesAgent.swift`,
`Workers/`, `Trust/`, `Media/`, `Routines/`, `Studio/`, `Research/`, `Memory/`, `Operator/`, and six in
`Specialists/`: time, people, letters, Scam Shield, money and the everyday helper); ready-made helpers in
`Agents/Studio/BuiltinAgents.swift`.

## 4. The SafetyGate decision

**What this shows:** how code decides whether a proposed tool call is refused, needs a question, needs the card and
Face ID, or simply runs.

```mermaid
flowchart TD
  P["Proposed tool call"] --> L{"Offered for this request?"}
  L -->|"no"| E["Error back to the model<br/>nothing runs"]
  L -->|"yes"| DR{"Dry run (self-test)?"}
  DR -->|"yes"| DL["Log the gate's verdict, nothing runs<br/>allow or card: a fake success<br/>refuse or question: comes back as usual<br/>(live self-test reads run for real)"]
  DR -->|"no"| A{"From a Shortcut, and not<br/>an allowed look-up?"}
  A -->|"yes"| RF["Refuse in plain words"]
  A -->|"no"| RD{"From another device, and<br/>allow_without_asking?"}
  RD -->|"yes"| RF
  RD -->|"no"| V{"The tool's own checks<br/>(validate)"}
  V -->|"block"| RF
  V -->|"clarify"| Q["Ask one short question"]
  V -->|"ok"| DOC{"Reaches a person or money, with a<br/>number, link or email found only in<br/>a letter, message or web page?"}
  DOC -->|"yes: a number used as the address,<br/>or any link or email"| RF
  DOC -->|"yes: a number inside message text"| WN["Warning on the card"]
  WN --> CF
  DOC -->|"no"| PS{"A lasting change while a letter<br/>is in the conversation,<br/>and the person didn't ask?"}
  PS -->|"yes"| CF
  PS -->|"no"| RK{"Risk level"}
  RK -->|"reachesPerson or money"| CF
  RK -->|"read or localWrite"| RM{"From another device and on<br/>the always-confirm list?"}
  RM -->|"yes"| CF
  RM -->|"no"| RUN["Run the tool"]
  CF["Card: Kairos wants to ...<br/>Yes or No"]
  CF -->|"Yes"| FID{"Face ID or passcode"}
  FID -->|"passed"| RUN
  FID -->|"failed"| NO["Not done"]
  CF -->|"No, or 90 s of silence"| NO
  CF -.->|"Siri in the background"| ST["Stashed until you open Kairos"]
```

**How to read it.** Start at the top. Diamonds are checks made by code; none of them asks the model. Three things
come from the request's source: a Shortcut's text may only trigger read-only tools that don't open apps, the camera or
other helpers; "allow without asking" can only be granted on the phone itself; and from another device, 16 tools that
work other apps, read the screen or save lasting things (`remoteAlwaysConfirm`) always need the card. The
"found only in a letter" check is the injection veto. For tools that reach a person or money, it looks at every run of
6 or more digits, every link and every email in the arguments that appears in untrusted text but never in the
person's own words. Such a number used as the address (a field that would be dialled or paid to), and any such link
or email, is refused; such a number inside message text puts a warning on the card. `operate_app` and `read_screen`
run the same check in their own `validate` and always refuse. In a dry run, only the Shortcut rule and the gate are
checked (not the other-device rules), and `prepare_payment` is recorded as needing a card without running its check.
Two caveats: on a phone with no passcode, `OwnerCheck` lets the Yes tap stand alone; and the owner's "allow without
asking" permissions do not skip this gate. They apply only to the phone operator's taps (diagram 5).

Status: *built*. The gate runs on every request, and its verdicts were logged in the dry-run self-test on the phone,
but the letter-number veto hasn't fired in a test yet, and Face ID has been seen only in the Simulator.

**Code:** `Agents/Core/SafetyGate.swift` (`check`, `documentOnlyValue`, `persistent`, `OwnerCheck`),
`Agents/Core/KairosAgent.swift` (`run`, `automationDenied`, `remoteDenied`, `remoteAlwaysConfirm`, `askOwner`,
`dryRunOutcome`), `Agents/UI/AgentConfirmCard.swift`.

## 5. The phone operator and iCTRL

**What this shows:** how Kairos works another app for you, one screen at a time, and where code stops it.

```mermaid
flowchart TD
  S["operate_app or read_screen"] --> V{"Code checks first<br/>money app, Shortcut, secret,<br/>letter-only number, keep watching?"}
  V -->|"any of these"| X["Plain refusal"]
  V -->|"ok, from another device"| RC["SafetyGate card and Face ID"]
  RC -->|"Yes"| H
  RC -->|"No"| X
  V -->|"ok"| H["Check iCTRL<br/>whoami and is_locked, pair if needed"]
  H -->|"not running, locked,<br/>or pairing refused"| X
  H -->|"ready"| BG["Ask iOS for background time<br/>UIKit task, plus iOS 26 continued task"]
  BG -->|"read_screen"| RS["Open the app (WhatsApp by procedure),<br/>one Gemini reader call answers<br/>from the screen text"]
  RS -->|"answer found"| W
  RS -->|"not there: look read-only"| RD
  BG -->|"operate_app"| SK{"A known job?<br/>(AppSkills)"}
  SK -->|"yes"| PR["Code procedure, no model for navigation<br/>open an app, search, WhatsApp chat"]
  PR -->|"finished"| W
  PR -->|"read something"| RA["One Gemini call answers<br/>from the screen text"]
  RA --> W
  PR -->|"unexpected screen"| RD
  SK -->|"no"| RD["Read the screen<br/>numbered text list, OCR if thin"]
  RD --> GU{"Limits reached?<br/>90 s, 15 decisions, 2 idle decisions,<br/>same screen 3 times (4 when reading),<br/>under 10 s of background time, Stop everything"}
  GU -->|"yes"| W
  GU -->|"no"| PL["Gemini picks 1 to 3 actions<br/>from screen text, never a screenshot"]
  PL --> AC{"Each action checked in code"}
  AC -->|"tap, type, scroll"| IC["iCTRL JSON-RPC<br/>sealed, on 127.0.0.1:8200"]
  AC -->|"read_screen: a send, pay,<br/>call or delete tap"| RF2["Refused, back to the planner"]
  RF2 --> GU
  AC -->|"operate_app: a send, pay,<br/>call or delete tap"| TG{"TrustTapGate"}
  TG -->|"owner allowed this app and<br/>this request asked for it"| IC
  TG -->|"ask"| CARD["Back to Kairos<br/>card and Face ID"]
  TG -->|"refuse"| W
  CARD -->|"Yes"| IC
  CARD -->|"No"| W
  AC -->|"done, or ask the person"| W
  IC --> RD
  W["Wrap up<br/>back to Kairos, honest summary,<br/>screen text kept as untrusted"]
```

**How to read it.** The loop in the middle repeats: read the screen, decide, act, read again. From another device,
both tools first need the SafetyGate's card and Face ID (`remoteAlwaysConfirm`). In `operate_app`, known jobs navigate
as fixed code with no model calls; when they read something, one Gemini call answers from the screen text.
`read_screen` opens the app (WhatsApp by procedure), then one Gemini "reader" call answers from the screen text. If
the answer isn't there, the planner looks for it read-only, and any send, pay, call or delete tap is refused and goes
back to the planner. In the planner loop, Gemini sees the screen as a short numbered list of labels (at most 60 lines)
and proposes 1 to 3 actions. Code checks every one: it never taps the microphone, voice-message or Meta AI controls,
refuses number-pad digits and bank icons, types only words that came from the request, and never types into a PIN or
password field. In `operate_app`, a tap that sends, pays, calls or deletes goes to `TrustTapGate`. That is the one
place where the owner's "allow without asking" permission counts, and only when this request asked for that action in
an app it named; banks, payments and rows that ring someone always ask. The phone talks to iCTRL over loopback with
messages sealed with a key from a one-time X25519 pairing (an HMAC-SHA256 keystream and tag, not TLS). A
screen-changing call is never re-sent after a timeout, because iCTRL may still finish it.

Status: *built*. On the real phone the operator connected to iCTRL and navigated, but no app read has succeeded yet.
*Compiled only*: WhatsApp's new-design reading (86/86 checks on captured screens, in a harness kept outside the
repo), the hand-back when iOS ends background time early, FaceTime and gallery-photo routing, and our iCTRL crash
fixes (`kairos-ios/Tools/iCTRL/`).

**Code:** `Agents/Operator/PhoneOperatorAgent.swift` (`OperatorRun`, `OperatorDriver`, `OperatorPlanner`,
`OperatorBackground`), `Agents/Operator/AppSkills.swift`, `Agents/Operator/ScreenDigest.swift`,
`Agents/Trust/TrustAgent.swift` (`TrustTapGate`), `Agents/Trust/OwnerPolicy.swift`, `Agents/Hands/ICTRLHands.swift`,
`Agents/Hands/ICTRLEnvelope.swift`, `Agents/Hooks/AgentHooks.swift` (`PhoneHands`).

## 6. The mesh: pairing, and requests in both directions

**What this shows:** how the iPhone joins your Mac's hub, how the Mac asks the iPhone, and how the iPhone asks the Mac.

```mermaid
sequenceDiagram
  participant O as Owner
  participant K as KairosAgent
  participant P as MeshNode
  participant H as kairos-mesh hub
  participant N as Mac node
  Note over O,N: Pairing, once
  O->>H: kairos pair on the Mac, or Add a device
  H-->>O: a 6-digit code (single use, 10 min) and a QR link
  O->>P: scans the QR code with the Camera (kairos://mesh link)
  P->>O: asks Join your Mac?
  O->>P: Join, then Face ID or passcode
  P->>H: GET /api/hello over Tailscale HTTPS
  P->>P: checks the remote address is a Tailscale one
  P->>H: POST /api/join with the code
  H-->>P: a device token (the hub keeps only its hash)
  P->>P: saves the token in the Keychain
  P->>H: POST /api/card with its skills
  Note over O,N: Your Mac asks the iPhone
  O->>H: on the Mac, What is on my iPhone calendar tomorrow?
  H->>H: rules: it names the iPhone, so no model call
  P->>H: GET /api/tasks/next (long-poll, 25 s)
  H-->>P: the task (30 s lease: requeued only if the phone takes it and never acknowledges it, then working until answered or it expires, 10 min by default)
  P->>K: handle(words, source: remote)
  opt reaches a person, money or the always-confirm list
    P->>H: status input-required (waiting for owner)
    K->>O: card, then Face ID (the asked-from-another-device warning is added only for always-confirm tools)
    O->>K: Yes and Face ID
  end
  K-->>P: answer from the tool
  P->>H: completed, with the answer
  H-->>O: answer shown on the Mac
  Note over O,N: The iPhone asks your Mac
  O->>K: What is my Mac's battery at?
  K->>P: ask_my_mac (a rule matched: it names the Mac)
  P->>H: POST /api/ask
  H->>H: rules: it names the Mac
  N->>H: GET /api/tasks/next (long-poll)
  H-->>N: the task
  N->>N: qwen2.5:7b picks a safe tool (battery and disk)
  N->>H: completed, with the answer
  H-->>P: the answer
  P->>K: the answer, kept as untrusted text
  K-->>O: spoken answer
```

**How to read it.** Time runs downwards, in three parts. A QR link never joins silently: Kairos asks "Join your Mac?"
and needs Face ID or the passcode. For a `.ts.net` hub (by link or typed in), the join is refused if the remote
address iOS reports is outside `100.64.0.0/10` and `fd7a:115c:a1e0::/48`, so a public name with the same `.ts.net`
ending can't stand in. Your Mac's hub address looks like `https://mac.tail1234.ts.net`. Two gaps: typing an address
and code in Settings › Your Mac joins without Face ID, and a plain http address on the Wi-Fi or a USB cable skips the
Tailscale check (as does a connection where iOS reports no remote address). When the Mac asks, the phone runs the task
through the same `KairosAgent` and SafetyGate as anything you typed, and `remoteAlwaysConfirm` turns any risky "allow"
into a card on the phone; the hub's task board shows "waiting for owner" meanwhile. When the phone asks, the Mac's
answer comes back as untrusted text, so a number or link in it can't later be dialled or opened as if you had said it.
The phone takes tasks only while Kairos is open (`MeshNode` starts when the app is active and stops in the
background). After each request from the app or Siri, the phone also copies the turn to the hub's shared conversation.

Status: pairing by code, the Mac asking the iPhone (calendar: 0.8 s over USB and 0.4 s over Tailscale on 31 Oct), and
the iPhone asking the Mac inside the 31 Oct self-test are *run on device*. The QR link, the pairing alert with Face ID,
the Talk button asking the Mac and a Face ID approval on a remote task have not been tried on the real phone yet (the
remote call card worked in the Simulator).

**Code:** `Agents/Mesh/MeshNode.swift` (`handle`, `pair`, `run`, `work`, `ask`, `shareTurn`),
`Agents/Mesh/DevicesAgent.swift` (`ask_my_mac`), `Agents/Core/KairosAgent.swift` (`remoteDenied`,
`remoteAlwaysConfirm`), `ContentView.swift` (the "Join your Mac?" alert and the connection line); the hub:
`kairos-mesh/mesh/app.py`, `kairos-mesh/mesh/store.py`, `kairos-mesh/mesh/brain.py`, `kairos-mesh/mesh/tailnet.py`,
`kairos-mesh/node/mac_node.py`, `kairos-mesh/node/mac_tools.py`.

## 7. Where data lives

**What this shows:** what stays on the phone, what is kept on your Mac, and what is sent to cloud services today.

```mermaid
flowchart LR
  subgraph PH["Stays on the iPhone"]
    K1["Keychain<br/>Gemini keys, hub token, iCTRL key"]
    K2["Application Support/Kairos<br/>memory.json, chat history (90 days),<br/>agents.json, routines.json,<br/>workers.json, reports"]
    K3["UserDefaults<br/>settings, payee book and limits,<br/>permissions, taught relations"]
    K4["Apple's own stores<br/>Contacts, Calendar, Reminders, Photos"]
    K5["Memory only<br/>the last letter (1 hour),<br/>the last 6 requests"]
  end
  subgraph MC["On your Mac: kairos-mesh hub"]
    M1["SQLite database<br/>devices, token hashes, tasks,<br/>shared conversation, hash-chained log"]
  end
  subgraph GG["Sent to Google Gemini, owner's key"]
    G1["Your words, recent turns, tool results"]
    G2["Phone summary: next 2 days of calendar (up to 6 events),<br/>up to 6 remembered facts, recent actions and a waiting card,<br/>helper and routine names, permissions, worker status"]
    G3["Letter photos"]
    G4["Screen text from other apps"]
    G5["Web text workers read, search questions"]
  end
  subgraph OT["Other services, no key"]
    O1["Open-Meteo: a place name"]
    O2["DuckDuckGo and arXiv: search words"]
    O3["Websites workers read: the page address"]
  end
  subgraph AP["Apple speech service"]
    A1["Your voice, only when the phone can't<br/>recognise that language on the device"]
  end
  subgraph EL["ElevenLabs"]
    E1["Voice and call transcript"]
  end
  PH -->|"each request, Gemini brain"| GG
  PH -->|"each turn, when paired"| MC
  PH -->|"weather, worker searches and pages"| OT
  PH -->|"speech, when no on-device model"| AP
  PH -.->|"only with kairos.legacy_voice"| EL
```

**How to read it.** The left box is what stays on the phone. Arrows show what leaves it. Keeping your data on your own
devices is our goal, not today's state: with Gemini as the brain, each request sends your words and some context to
Google, and when the phone is paired, each turn is copied to the hub on your Mac. Some limits on what leaves:

- From your contacts, the model sees names, number types and the last 3 digits of a number, never the whole number.
  Screen text and letter photos can still contain whole numbers.
- Memory sends at most 6 relevant facts (700 characters) per request. PINs, passwords and codes are never remembered.
- A letter photo is shrunk to at most 1600 px and is never stored; the explanation is kept in memory for an hour.
- Turns that used `read_letter` or `read_screen` are copied to the Mac as "[answered on the iPhone]". Follow-up
  questions about a letter (`ask_letter`) and answers `operate_app` read off a screen are copied as said.
- The phone operator sends screen *text*, never screenshots, and refuses to read banking and payment apps for this
  reason.
- With **Your Mac** as the brain, the main request path doesn't call Google. Reading letters still needs Gemini, and
  we haven't yet audited every other part (such as the research team) for this setting.

**Code:** `Agents/Core/ModelProvider.swift` (`AgentSettings`, keys via `KeyStore.swift`), `Agents/UI/AgentVoice.swift`
(speech), `Agents/Context/PhoneContext.swift`, `Agents/Workers/WebReader.swift`, `Agents/Memory/MemoryStore.swift`,
`Agents/Memory/ConversationStore.swift`, `Agents/Memory/MemoryContext.swift`, `Agents/Studio/AgentSpec.swift`,
`Agents/Routines/RoutineStore.swift`, `Agents/Workers/WorkerRun.swift`, `Agents/Research/ReportStore.swift`,
`Agents/Specialists/MoneyAgent.swift`, `Agents/Trust/OwnerPolicy.swift`, `Agents/Specialists/LetterAgent.swift`,
`Agents/Mesh/MeshNode.swift` (`shareTurn`); the hub: `kairos-mesh/mesh/store.py`.
