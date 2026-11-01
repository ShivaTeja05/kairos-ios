# Plan: the universal agent

One agent you can talk to from any device. Its workers run on whichever device has what they need and move
between devices, and several work at once. Each device keeps its own veto.

## 1. Voice in and out (all open, no API keys)

Piper is **text-to-speech** (the agent's voice). Turning your voice into text needs a speech-recognition model.

| Job | Pick | Licence (checked on GitHub, 30 Oct 2026) | Runs on |
|---|---|---|---|
| Voice → text, Apple devices | **WhisperKit** ([argmax-oss-swift](https://github.com/argmaxinc/argmax-oss-swift)): Whisper on Core ML, in Swift | MIT | iPhone, Mac, Watch |
| Voice → text, everything else | **sherpa-onnx** ([k2-fsa/sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)) or whisper.cpp | Apache-2.0 | Windows, Linux, Android, also iOS |
| Telugu and Hindi candidates | **IndicConformer** ([AI4Bharat](https://github.com/AI4Bharat/IndicConformerASR)), built for Indian languages; community Whisper fine-tunes for Telugu (e.g. [whisper-telugu-base](https://huggingface.co/vasista22/whisper-telugu-base), Apache-2.0, reports 13.39 WER on FLEURS) | MIT / Apache-2.0 | Mac first |
| Text → voice | **Your own Piper voices** (Telugu, Hindi, Tamil, Kannada, English), run with **sherpa-onnx** | sherpa-onnx is Apache-2.0. Don't use the new Piper runtime ([piper1-gpl](https://github.com/OHF-Voice/piper1-gpl)): it's GPL-3.0. The original [rhasspy/piper](https://github.com/rhasspy/piper) (MIT) is archived | iPhone, Mac, any device |
| Fallback | Apple's own on-device speech recognition, which the app already uses | — | iPhone, Mac |

- **Choose the speech-to-text model by measuring it,** the same way `kairos-models` measures the router. Use ~50 of your own recordings in English, Hindi and Telugu, and score word error rate and speed for each candidate. The community WER numbers above use different test sets, so they can't be compared.
- **Check the licences of the datasets your Piper voices were trained on** before you publish them.

## 2. What we take from the iPhone app (kairos-ios)

| The universal agent needs | Already in kairos-ios | Where | Change |
|---|---|---|---|
| One skill format every device shares | `KairosTool`: name, summary, argument schema, risk, `quickMatch`, `validate`, `describe`, `execute` | `Agents/Core/AgentKit.swift` | Becomes each device's card. Already extracted to `kairos-models/tools/tools.json` |
| The same risk levels everywhere | `Risk`: read, localWrite, reachesPerson, money | `AgentKit.swift` | Use the same four on the Mac and Windows |
| A brain on each device | `KairosAgent`: rules first, then the model picks a tool, and it answers only from what actually happened | `Agents/Core/KairosAgent.swift` | Add `source: .remote` so tasks from other devices run through it |
| Each device's veto | `SafetyGate`, `OwnerPolicy`, the Face ID card | `Core/SafetyGate.swift`, `Trust/OwnerPolicy.swift`, `UI/AgentConfirmCard.swift` | Treat text from another device like text from a letter: information, never instructions |
| Swap the model without touching agents | `ModelProvider` protocol (Gemini today) | `Core/ModelProvider.swift` | Add an OpenAI-compatible provider (Ollama on the Mac); later an on-device model |
| Several agents at once, on a board | Worker agents, the Agents board | `Workers/*`, `WorkersUI/AgentBoardView.swift` | The board shows workers on every device |
| **Agents that can travel** | Agent Studio's `AgentSpec`: an agent saved as JSON (name, instructions, allowed tools, triggers) | `Studio/AgentSpec.swift` | A worker's spec plus its task notes become the thing that moves between devices |
| Multi-step plans | Routines: saved steps, Siri phrases | `Routines/*` | A step can name the device that does it |
| Memory | `MemoryStore`, `ConversationStore`, `MemoryContext` | `Memory/*` | Shared through the hub's event log |
| Knowing the device's state | `PhoneContext`, `VoiceContextBridge` | `Context/*` | Goes into the card: awake, locked, app control available |
| Operating other apps (WhatsApp, Uber) | `PhoneOperatorAgent`, `ICTRLHands`, `AppSkills`, `ScreenDigest` | `Operator/*`, `Hands/*` | Check `whoami` / `is_locked` before routing a task that needs it |
| Voice entry | Siri App Intents ("Ask Kairos"), `AgentVoice` | `Siri/AgentIntents.swift`, `UI/AgentVoice.swift` | Replace the ElevenLabs path with WhisperKit + Piper |
| Logging in to the Mac | `TempoSession`, `KeyStore` (base URL, phone key, device token) | `TempoSession.swift`, `KeyStore.swift` | The node uses the same login |
| Testing | `SelfTest` (~30 dry-run requests) | `SelfTest/SelfTest.swift` | Add cross-device cases |

**Not needed for the universal agent:** Present mode (`Showcase/*`), Bridge "Write for me" (team code), Money and
Navigator.

**From the Mac side** (`tempo-hub`, not in git), we reuse:
- the hub: devices, events, approvals
- the conductor: up to 5 agents in parallel across hub, laptop and phone
- `laptop_agent.py`: the Mac's hands
- `phone_agent.py`: iCTRL driven from the Mac
- Guardian: the vault, the signed log, the kill switch
- the MCP server and the desktop agent (Mac, Windows, Linux)

## 3. Build phases

**Phase 1 progress (31 Oct):**
- **Built and tested:** the hub, the shared brain, Jarvis (rules first, then the local model), the Mac node, the web page, task leases.
- **The iPhone node** (kairos-ios, branch `mesh-node`) runs against the hub in the iOS Simulator, in both directions:
  - the calendar read;
  - the Face ID-gated call;
  - recovery from a killed app.
- **Next:**
  1. The phone's own brain without Gemini: an open model through the Mac.
  2. Run on the real iPhone over Wi-Fi.
  3. Require a passcode for requests from other devices.

| Phase | Builds | Demo |
|---|---|---|
| **1. iPhone ↔ Mac, one shared context** | The kairos-mesh relay; device cards built from `KairosTool`; the iPhone node (`KairosAgent` with `source: .remote`); the Mac agent (on `laptop_agent`; OpenClaw as its hands once its API is checked). **Shared brain on the hub:** one conversation from both devices, the task board, device states, and a context builder that rebuilds each device's prompt from them. Live progress goes to whichever device you're talking to | Start a flight search by voice on the iPhone. Five minutes later, ask the Mac "how's it going?" and it knows. Ask the Mac for something from the phone's calendar, and the iPhone's own agent answers |
| **2. Many agents that move** | A worker = `AgentSpec` + task notes, handed from device to device; the board shows every device; the routing rule (where the data is, whether app control is available) | "Plan my Saturday": a worker starts on the Mac, moves to the iPhone (Face ID for the reminder), and comes back, while a second worker researches something on the Mac |
| **3. Voice everywhere** | WhisperKit / sherpa-onnx in, your Piper voices out, on every device; Telugu and Hindi | The same spoken request, in Telugu, from the Mac or the iPhone |
| **4. Works when a device is away** | The hub keeps copies of calendar, notes and a file index; push wake; "home phone" mode for app control | Phone at home: the MacBook still gets the answer, and the WhatsApp message goes out from the home phone |
| **5. Safety and the trained router** | Device keys and Face ID-signed approvals; `kairos-router` from `kairos-models` | A compromised relay can't approve anything |

Voice (phase 3) doesn't depend on phases 1–2, so it can run in parallel. Until then, the demo uses the voice input
the app already has (Siri and Apple's dictation).
