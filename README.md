# Kairos for iPhone

**AI agents that live on the iPhone and get things done for people who aren't confident with technology.**
You speak, through Siri or a natural ElevenLabs voice, and Kairos's agents do the job on the phone itself:
alarms and reminders, reading a letter, catching a scam, starting worker agents that research or read a paper for you,
and even using other apps the way a person would. Nothing risky ever happens without the owner's Yes and Face ID.

Built at OxHack 2026 (theme: TIME). Status: hackathon build, still being tested on a real iPhone 12 Pro Max.

```
 YOU ──speak──▶ Siri ("Hey Siri, ask Kairos") or the ElevenLabs voice (Talk)
                   │  the request, plus the recent conversation
                   ▼
            KAIROS on the iPhone (Swift)  ── brain: Google Gemini, with the owner's own API key
              • rules first (instant, offline), then Gemini picks the right agent
              • sees what's happening on the phone (agents, routines, recent actions, calendar)
                   │
   ┌───────────────┼──────────────────────────────────────────────────────────────┐
   ▼               ▼                     ▼                     ▼                   ▼
 Helpers        Worker agents         Phone operator        Routines            Agent Studio
 time, people,  go and do a job:      uses other apps via   "do my morning"     ready-made and
 letters, scam, web search, read      iCTRL (taps, reads    replays saved steps your own saved
 money, weather papers/PDFs, report   screens), Gemini      with no model call  helpers
                back on a live board  decides each step
                   │
                   ▼
   SAFETY GATE (code, not the model): calls, messages, posts and payments need the owner's Yes + Face ID;
   banks are always locked; text from letters or web pages is never treated as an instruction.
```

## What it can do

| | |
|---|---|
| **Talk to it** | "Hey Siri, ask Kairos …", the **Talk** button (ElevenLabs voice), or type in "Kairos on this phone" |
| **Everyday helpers** | Alarms, timers, reminders, calendar; call or text your people; read a letter or bill and explain it; scam checks (offline); directions, weather, phone how-tos; run your Shortcuts |
| **Worker agents** | "Create an agent to find the research paper *Attention Is All You Need*, read it and tell me the results." Workers search the web, read pages and PDFs (arXiv), run in parallel, and show on the **Agents board** with timestamps and status |
| **Research team** | "Research …": a planner, three researchers in parallel, a writer, and a cited report |
| **Phone operator** | "Open WhatsApp and read me the latest message." Drives apps through iCTRL (OpenMinis' open-source UI-automation runner on the phone) |
| **Routines** | "Create a routine for my mornings …" saves the steps; "do my morning" replays them; each routine is also a Siri phrase and Shortcuts action |
| **Agent Studio** | 12 ready-made helpers plus your own, saved and shareable as JSON |
| **Owner permissions** | The owner decides what agents may do without asking (e.g. post to Instagram for an hour). Banks, payments, passwords and security settings can never be unlocked |
| **Present mode** | Tap the title 5 times. Kairos presents itself: agents work live while the voice explains, then it hands over to the audience |
| **Shared context** | The ElevenLabs voice and Gemini share what is happening on the phone, so follow-ups like "make it 8 instead" work |

## Build and run (about 10 minutes)

Needs a Mac with Xcode 26 or newer, an iPhone on iOS 17 or newer (some features need iOS 26), and an Apple ID
(a free Personal Team works; apps then expire after 7 days).

```bash
brew install xcodegen
cp Config/Local.xcconfig.example Config/Local.xcconfig   # put in your own team ID
xcodegen generate
open Tempo.xcodeproj                                     # choose your iPhone, press Run
```

Then, on the iPhone:

1. Open Kairos and tap **Kairos on this phone**. Allow Reminders, Calendar, Alarms and Contacts.
2. Get a Gemini API key at [aistudio.google.com/apikey](https://aistudio.google.com/apikey). Copy it on the phone,
   then tap the **gear** and **Paste key from clipboard**. The key is kept only in the iPhone's Keychain.
3. Try "Set a timer for 2 minutes", "What's on tomorrow?", or "Create an agent to find out what's new in iOS 27".

**Models.** Kairos thinks with `gemini-3.5-flash-lite` and searches the web with `gemini-2.5-flash`, because on the
free tier the 3.5 models can't use Google Search. Change either one in settings, or with
`kairos.agents.searchModel`. A second "backup" key from another Google project raises the per-minute allowance.

**Optional: the ElevenLabs voice and the Mac hub** live in the separate `tempo-hub` project (voice agent config, token
server, Guardian). Without them, Siri and typing still work.

**Optional: the phone operator** needs the iCTRL runner on the phone (Developer Mode, started from the Mac with
Xcode). iOS stops the runner whenever the phone locks; keep Auto-Lock off during a demo, or run a watchdog that
restarts it.

## Checking it works

```bash
Tools/GeminiSmoke/run.sh                     # 5 real Gemini calls with the app's own Swift code (key from tempo-hub/agents/.env)
python3 -I Tools/GeminiSmoke/search_check.py # which models can use Google Search on your key, and why not
```

On the phone, a dry-run **self-test** runs about 30 requests through the real agent and the real model without
doing anything. It checks that each one goes to the right agent: More › Developer › Run self-test, or launch with
`-KairosSelfTest`.

## Project layout

```
TempoApp/                 the app (SwiftUI)
  Agents/Core             orchestrator (KairosAgent), safety gate, Gemini client, rate limiting
  Agents/Context          shared context for Gemini and the voice
  Agents/Specialists      planner, people, letter reader, scam shield, money, everyday helpers
  Agents/Workers(UI)      worker agents + Agents board
  Agents/Research(UI)     research team + reports
  Agents/Operator, Hands  phone operator + iCTRL client
  Agents/Routines         saved routines (+ Siri / Shortcuts entities)
  Agents/Studio(UI)       Agent Studio
  Agents/Trust            owner permissions
  Agents/Media            take a photo and share it
  Agents/Showcase(UI)     Present mode
  Agents/Siri             App Intents (Ask Kairos, Tell Kairos, …)
  Bridge/                 "Write for me" message drafting (team code)
Tools/                    Gemini smoke test, search check
project.yml               xcodegen project definition
```

## Privacy

Requests (and photos of letters, when you use that) go to Google Gemini with **your own key**; voice calls go to
ElevenLabs. Contacts, reminders, the calendar, routines, agents and history stay on the iPhone. Only what a step
needs is sent (for example a contact's name, never the address book).

## Licence

Apache License 2.0. See [LICENSE](LICENSE). Uses the ElevenLabs Swift SDK and LiveKit (their own licences). iCTRL is a
separate Apache-2.0 project and is not included here.
