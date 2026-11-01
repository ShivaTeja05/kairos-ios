# iCTRL fixes used by Kairos

Kairos's phone operator drives apps through [iCTRL](https://github.com/OpenMinis/iCTRL) (OpenMinis, Apache-2.0),
the UI-automation runner on the phone. `kairos-ictrl-fixes.patch` is our change to it, made against upstream
commit `874f528`. Without it the runner can crash the test session on a real iPhone:

- **No more NaN/infinite crashes.** An element with no frame (`CGRect.null`) gave NaN or infinite coordinates, and
  `Int(...)` on those traps. Taps, double taps, drags, scrolls and element lookups now refuse an element with no
  usable frame and return an error instead.
- **Safe number conversions.** RPC numbers go through `clampedInt`, which returns nil for NaN or infinity and clamps
  anything else to ±1e15 before converting.
- **Bounded durations.** Long press 0–60 s, page scroll 0–5 s, wait 0–4000 s.
- **Sturdier frame parsing.** Frames are read from the last `{{` in a description, and only finite values with a
  magnitude below 1e15 are accepted. This covers alert buttons and list rows.

Status: *compiled only*. The patch builds, but the patched runner hasn't run on the phone yet.

The app's side of the link is in `kairos-ios/TempoApp/Agents/Hands/` (`ICTRLHands.swift`, `ICTRLEnvelope.swift`).

Apply it to a fresh checkout:

```bash
git clone https://github.com/OpenMinis/iCTRL.git && cd iCTRL
git checkout 874f528
git apply /path/to/this-repo/kairos-ios/Tools/iCTRL/kairos-ictrl-fixes.patch
make build
```
