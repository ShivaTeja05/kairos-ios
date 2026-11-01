# Architecture diagrams

Each diagram is an SVG you can open in any browser, and each has a note: why we drew it, the use case it serves,
how to read it, and what's real today versus still to build.

**Colours:**
- **teal:** our code, already built;
- **dashed coral:** to build;
- **solid coral:** a cloud service that needs an API key;
- **purple:** data steps;
- **white:** other devices.

## How it works today
| # | Diagram | Answers |
|---|---|---|
| 01 | [The whole system](01-system-today.md) | Where does each part live, and what talks to what? |
| 02 | [One request on the iPhone](02-iphone-request.md) | How does Kairos decide and act, and where does the safety gate sit? |
| 03 | [Cross-device today](03-cross-device-today.md) | What can the iPhone already make the Mac do, and what's missing? |
| 04 | [Device data → hub](04-device-data-to-hub.md) | How does data from any brand of device reach the Mac? |

## What we're building
| # | Diagram | Answers |
|---|---|---|
| 05 | [Two-way Jarvis](05-two-way-jarvis.md) | iPhone ↔ Mac in both directions, each device with its own veto |
| 06 | [One memory across devices](06-shared-context-timeline.md) | Start on the iPhone, ask the Mac five minutes later, and it knows |
| 07 | [Open models, no keys](07-open-model-stack.md) | Which models run where, and why |
| 08 | [Training kairos-router](08-router-training.md) | What we train, why, and how we check it |

Earlier drafts drawn in chat (the first "nodes" sketch, and the phone-node-only flow) were replaced by 05 and 06.
