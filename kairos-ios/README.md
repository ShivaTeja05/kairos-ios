# Kairos for iPhone (kairos-ios)

This folder is the Kairos iPhone app: one big Talk button, the on-phone agent (`KairosAgent`), its 60 tools in 15
helpers, and the SafetyGate that checks every proposed action in code before it runs. It is Swift and SwiftUI, and the
Xcode project is made from `project.yml` by XcodeGen. The app began as "Tempo" at OxHack 2026, so the Xcode project and
target are still called `Tempo`, the source folder is `TempoApp/`, and the bundle id starts `uk.oxhack.tempo`; on the
phone it is called Kairos. What Kairos is, what works today, the safety rules and the status words (*run on device*,
*built*, *compiled only*, *planned*) are in the [main README](../README.md).

All commands below run from this folder, `kairos-ios/`, unless they say otherwise.

## Build and run

Needs a Mac with Xcode 26 or newer, an iPhone on iOS 17 or newer (some features need iOS 26), and an Apple ID
(a free Personal Team works; apps then expire after 7 days).

```bash
brew install xcodegen
cp Config/Local.xcconfig.example Config/Local.xcconfig   # git-ignored; put in your team ID twice: DEVELOPMENT_TEAM,
                                                         # and DEVELOPMENT_TEAM_LOWER in lower case
xcodegen generate
open Tempo.xcodeproj                                     # choose your iPhone, press Run
```

Find the team ID in Xcode › Settings › Accounts › your Apple ID. `DEVELOPMENT_TEAM_LOWER` makes the bundle id unique
to you: it becomes `uk.oxhack.tempo.<your team ID in lower case>`. `Tempo.xcodeproj` is generated, and git-ignored, so
run `xcodegen generate` again after adding or moving files.

Then, on the iPhone:

1. Open Kairos and tap **More: type, photos, helpers**. Allow Reminders, Calendar, Alarms and Contacts.
2. Get a Gemini API key at [aistudio.google.com/apikey](https://aistudio.google.com/apikey). Copy it on the phone,
   tap the **gear**, then **Paste key from clipboard**. The key is kept only in the iPhone's Keychain. (No key? Join
   your Mac, below, and choose **Your Mac** as the brain. Reading letters still needs Gemini.)
3. Try "Set a timer for 2 minutes", "What's on tomorrow?", or "Create an agent to find out what's new in iOS 27".

**Demo payees.** In a Debug build with no saved payee book, the Money helper starts from a demo book of made-up payees
(such as "Arjun Rao" and "Priya Rao") and billers, so the payment check can be tried without real bank details. A
Release build starts with an empty book. Kairos never pays either way.

## Models

Kairos thinks with `gemini-3.5-flash-lite` and falls back to `gemini-2.5-flash`, then `gemini-3.5-flash`.
Settings also offers `gemini-3.8-flash` ("Careful") and `gemini-2.5-flash` ("Older model"), or a model name of your
own. Web search uses `gemini-2.5-flash`, because on 25 Oct the 3.5 models answered every grounded search with a
rate-limit error on a free key; change it with the `kairos.agents.searchModel` setting. A second "backup" key from
another Google project raises the per-minute allowance. Kairos keeps itself under the free tier on its own
(14 requests a minute for lite models, 9 for others), and your own requests always go before background work.

The code is in `TempoApp/Agents/Core/ModelProvider.swift` and `TempoApp/Agents/Research/GroundedSearch.swift`.

## Joining your Mac

Optional: one Kairos across your iPhone and Mac. This needs the Mac hub in [../kairos-mesh](../kairos-mesh/README.md),
set up as its README says (a Python 3.12 `.venv` inside `kairos-mesh/`, and Ollama with `qwen2.5:7b`).

- **Join:** install Tailscale on both with the same account. In `kairos-mesh/` run `scripts/kairos up`, then
  `scripts/kairos pair` (or **Add a device** on the Mac's page), and scan the QR code with the iPhone's Camera: Kairos
  asks, then Face ID, and joins only if the Mac was really reached through Tailscale (built, not yet tried on a real
  phone). Or type the hub's address and the code into Settings › Your Mac and tap **Join**: there is no Face ID step,
  and a `.ts.net` address must still be reached through Tailscale. Pairing with a code has run on the phone.
- **Who thinks:** rules on the phone first. What they don't know goes to your chosen brain (Settings › Who thinks for
  Kairos): **Your Mac** (the hub's open model, no API key; the default when no Gemini key is saved) or **Gemini**.
  Reading letters needs Gemini, because the Mac's model can't read photos yet.
- **One conversation:** what you say here is added to the hub's conversation, so the Mac knows it.
- **Your Mac can ask this iPhone** while Kairos is open. The task runs through `KairosAgent` here. With Gemini as the
  brain it is handled like something you typed. With Your Mac as the brain, only requests the phone's rules understand
  work ("what's on my calendar tomorrow"). Anything that reaches a person or works another app always shows the card
  and needs Face ID here.
- **This iPhone can ask your Mac** ("What's my Mac's battery at?"). The 31 Oct on-phone self-test reached the Mac
  twice (the battery, and a file search); asking from the Talk button hasn't been tried yet.
- **The line under the title** says where your Mac is in plain words (connected, Tailscale off, Mac asleep, Kairos not
  running on the Mac). Tap it to try again.

The phone's side of the link is `TempoApp/Agents/Mesh/MeshNode.swift` and `TempoApp/Agents/Mesh/DevicesAgent.swift`.

## The phone operator and iCTRL

The phone operator reads and taps through other apps (WhatsApp, Messages, Phone, Mail) using iCTRL, a UI-automation
runner by OpenMinis (Apache-2.0) that runs on the same iPhone at `127.0.0.1:8200`. iCTRL is not included here.

- It needs Developer Mode and UI Automation on, and the runner built and started from the Mac with Xcode, as iCTRL's
  own README explains.
- iOS stops the runner whenever the phone locks, so keep Auto-Lock off while you use it. The first run also needs the
  developer certificate trusted on the phone (Settings › General › VPN & Device Management).
- Apply our crash fixes from [Tools/iCTRL](Tools/iCTRL/README.md) before building it. They compile but haven't run on
  the phone yet.

Status: built. On the phone it connected to iCTRL and navigated, but no app read has succeeded yet. The code is in
`TempoApp/Agents/Operator/` and `TempoApp/Agents/Hands/`.

## Legacy OxHack screens

The old ElevenLabs Talk call, the Shield badge, "Write for me" and the old letter screen all talk to the OxHack Mac hub
(`tempo-hub`), which is not in this repo. They are off unless `kairos.legacy_voice` is set in UserDefaults. Their code
is `TempoApp/TempoSession.swift`, `TempoApp/ShieldView.swift`, `TempoApp/LetterReader.swift` and `TempoApp/Bridge/`.

## Checking it works

Both checks below expect Xcode at `/Applications/Xcode.app`.

**GeminiSmoke** makes 5 real Gemini calls using the app's own Swift (a tool call, the tool result sent back, JSON, a
letter photo and a grounded search). It compiles for an Apple silicon Mac and exits 0 only if all 5 pass. The key comes
from `GEMINI_API_KEY`, or else from `tempo-hub/agents/.env` in the folder that holds this repo (the OxHack hub's key
file, if you have it). It prints at most the key's last 3 characters.

```bash
export GEMINI_API_KEY=<your key>                 # or keep it in tempo-hub/agents/.env beside this repo
Tools/GeminiSmoke/run.sh                         # optional: a model name (default gemini-3.5-flash-lite)

# Which models can use Google Search on your key, and why not. Never prints the key.
python3 -I Tools/GeminiSmoke/search_check.py     # optional: model names to try
```

**The on-phone self-test**, driven from the Mac. It sends each case through the real `KairosAgent` and the real
Gemini model on the phone as a dry run, then brings the results back. The phone must be connected and unlocked, with
Kairos installed and a Gemini key saved. Live WhatsApp cases also need the iCTRL runner. The runner needs two settings,
with no defaults:

- `KAIROS_DEVICE`: your iPhone's identifier. Run `xcrun devicectl list devices` and copy the Identifier column.
- `KAIROS_BUNDLE`: your build's bundle id, `uk.oxhack.tempo.<your team ID in lower case>` (Xcode shows it under the
  Tempo target's Signing & Capabilities).

Run it from `kairos-ios/`: the cases paths and the default `--out Tools/SelfTest/results` are relative.

```bash
export KAIROS_DEVICE=<your-device-identifier>
export KAIROS_BUNDLE=uk.oxhack.tempo.<yourteamid>

python3 -I Tools/SelfTest/run_selftest.py Tools/SelfTest/cases.json     # all 165 cases (about 15 to 20 minutes)
python3 -I Tools/SelfTest/run_selftest.py Tools/SelfTest/smoke.json     # 4-case quick check
python3 -I Tools/SelfTest/run_selftest.py Tools/SelfTest/cases.json --report-only   # pull and print the latest results
```

`--timeout` sets how long to wait for a run (default 3600 s). The runner also compares the phone's crash logs before
and after. Results are saved as `Tools/SelfTest/results/selftest-<date>-<time>.json` and are git-ignored, because they
hold real names and memories from the phone. For the same reason, don't paste the runner's failure printout into
issues: it includes the start of each reply.

You can also start the self-test on the phone: on the helpers screen tap **More › Developer › Run self-test (dry
run)**, or launch the app with `-KairosSelfTest`. It runs the cases the Mac last copied to the phone, or else 32
built-in ones.

How the cases are judged, and every result so far: [../docs/TESTING.md](../docs/TESTING.md).

## App layout

```
TempoApp/                   the app (SwiftUI)
  TempoApp.swift            entry point, Siri phrases, kairos:// links
  ContentView.swift         the main screen: one big Talk button
  KeyStore.swift            Keychain helper
  TempoSession.swift        old ElevenLabs call (legacy flag only)
  LetterReader.swift,
  ShieldView.swift          old OxHack screens that talk to tempo-hub (legacy flag only)
  Agents/
    AgentAppHooks.swift     wires the agents into the app
    Core                    KairosAgent, SafetyGate, AgentDirectory, tool contract, Gemini client, rate limiter
    Context                 what the model knows about the phone
    Specialists             time, people, letter reader, scam shield, money, everyday helpers
    Memory, MemoryUI        remembered facts and chat history
    Mesh                    link to the kairos-mesh hub, "ask my Mac"
    Workers, WorkersUI      worker agents and the Agents board
    Research, ResearchUI    research team and Reports
    Operator                phone operator: planner, screen digest, app skills
    Hands                   iCTRL client: pairing and sealed messages
    Hooks                   shared runner and the PhoneHands protocol
    Routines                saved routines, Siri and Shortcuts entities
    Studio, StudioUI        Agent Studio
    Trust                   owner permissions
    Media                   take a photo and share it
    Siri                    App Intents (Ask Kairos, Tell Kairos, …)
    SelfTest                on-phone dry-run self-test
    Showcase, ShowcaseUI    Present mode
    UI                      voice, settings, the More screen, approval card, camera
  Bridge/                   "Write for me" message drafting (OxHack team code, legacy flag only)
Tools/
  GeminiSmoke/              real Gemini calls with the app's own Swift; search check
  SelfTest/                 165 cases, 4-case smoke set, Mac runner (results/ is git-ignored)
  iCTRL/                    our crash-fix patch for iCTRL
Config/                     Local.xcconfig.example (your Local.xcconfig is git-ignored)
project.yml                 XcodeGen project definition
```

The system docs for the whole repo (architecture, testing, roadmap) are in [../docs/](../docs/ARCHITECTURE.md).
