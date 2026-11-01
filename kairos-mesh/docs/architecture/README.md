# Architecture diagrams

**These eight diagrams are design notes, drawn on 30–31 Oct 2026.** Some of what they call "today" has changed since.
The current architecture, checked against the code, is [docs/ARCHITECTURE.md](../../../docs/ARCHITECTURE.md) at the
top of this repo.

Each diagram is an SVG you can open in any browser, and each has a note: why we drew it, the use case it serves,
how to read it, and what's real today versus still to build.

**Colours:**
- **teal:** our code, already built;
- **dashed coral:** to build;
- **solid coral:** a cloud service that needs an API key;
- **purple:** data steps;
- **white:** other devices.

## How it worked on 30–31 Oct
| # | Diagram | Answers | Since then |
|---|---|---|---|
| 01 | [The whole system](01-system-today.md) | Where does each part live, and what talks to what? | The Mac hub (`kairos-mesh/`) now joins the iPhone and the Mac over Tailscale, not ngrok, and the Mac asks the iPhone's own agent (`MeshNode.swift`). The app's old voice call to tempo-hub is off by default. |
| 02 | [One request on the iPhone](02-iphone-request.md) | How does Kairos decide and act, and where does the safety gate sit? | An emergency check (a fixed 999 answer) now runs before the rules. The brain can be the Mac's open model instead of Gemini (built; text answers only). Tasks from the Mac take the same path, with stricter checks. The app has 60 tools, not 57. |
| 03 | [Cross-device today](03-cross-device-today.md) | What can the iPhone already make the Mac do, and what's missing? | No longer one-way. The Mac asks the iPhone's own agent through kairos-mesh (run on device, 31 Oct), and the iPhone asked the Mac twice (battery, a file search) in the 31 Oct on-phone self-test. Agents still can't move between devices. |
| 04 | [Device data → hub](04-device-data-to-hub.md) | How does data from any brand of device reach the Mac? | Unchanged. This is the OxHack hub (tempo-hub), which isn't in this repo. kairos-mesh doesn't collect health, location or notification data. |

## What we're building
| # | Diagram | Answers |
|---|---|---|
| 05 | [Two-way Jarvis](05-two-way-jarvis.md) | iPhone ↔ Mac in both directions, each device with its own veto |
| 06 | [One memory across devices](06-shared-context-timeline.md) | Start on the iPhone, ask the Mac five minutes later, and it knows |
| 07 | [Open models, no keys](07-open-model-stack.md) | Which models run where, and why |
| 08 | [Training kairos-router](08-router-training.md) | What we train, why, and how we check it |

Earlier drafts drawn in chat (the first "nodes" sketch, and the phone-node-only flow) were replaced by 05 and 06.
