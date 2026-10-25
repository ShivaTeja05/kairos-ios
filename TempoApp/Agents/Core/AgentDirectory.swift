import Foundation

/// The specialist agents Kairos can hand work to, in the order the model sees them.
/// Add a new agent here and it becomes available to the orchestrator, Siri and the screen.
/// Order matters for the rules-first pass (quickMatch): the narrowest matchers come first.
enum AgentDirectory {
    static var all: [any SpecialistAgent] {
        [
            WorkersAgent(),     // "create/assign/send an agent to <job>": a worker that goes and does it (Agents board)
            TrustAgent(),       // what agents may do without asking; "stop everything"
            PhotoAgent(),       // take a photo and post, send or upload it anywhere (Siri can't)
            RoutinesAgent(),    // the person's saved routines ("do my morning"), made from their own words
            StudioAgent(),      // saved helper personas the person talks to: talk to one, ask one, save one
            ResearchAgent(),    // a research team: plans, searches Google side by side, writes a cited report
            MemoryAgent(),      // remember / forget / what do you remember / what did we talk about
            PlannerAgent(),     // reminders, alarms, timers, calendar
            PeopleAgent(),      // find, call and message the person's people
            LetterAgent(),      // photo of a letter, bill or form → plain words + what to do
            ScamShieldAgent(),  // "is this a scam?" rules on the phone, works offline
            MoneyAgent(),       // payments: checks first, hands over to the bank's own app
            HelpersAgent(),     // directions, weather, phone how-tos, the person's own Shortcuts
            PhoneOperatorAgent(), // uses other apps for the person through iCTRL, with the owner's OK for anything sensitive
        ]
    }
}
