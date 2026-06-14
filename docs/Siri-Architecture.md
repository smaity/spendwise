# How Siri Works Internally — Architecture, Hardware/Software Components, and App Plug‑in Points

*A reference document. Written June 2026. Covers the classic Siri pipeline and the
Apple‑Intelligence‑era redesign, plus every way an iOS app can customize Siri.*

> Sources are Apple's Machine Learning Research blog, Apple Developer documentation, and
> Apple's Private Cloud Compute security materials. See **References** at the end. Where a
> capability was announced but is still rolling out (the "personal‑context" Siri), this is
> called out explicitly rather than presented as shipped fact.

---

## 1. The big picture

Siri is not one program. It is a **layered pipeline** that hands a request through a series of
increasingly capable (and increasingly expensive/privacy‑sensitive) stages, stopping as early
as it can. The guiding design principles:

1. **On‑device first.** The cheapest, most private stages run on the phone's own silicon. Audio
   never leaves the device unless a stage decides it must.
2. **Escalate only when needed.** A tiny always‑on detector wakes a bigger detector, which wakes
   the full recognizer, which may (or may not) call a server.
3. **Privacy by construction.** Wake‑word audio is processed locally; server requests are tied to
   a random device identifier, not your Apple Account; heavy AI runs on **Private Cloud Compute**
   (PCC), which is stateless and externally auditable.
4. **Apps are plug‑ins, not bystanders.** Siri's "skills" for third‑party apps are *declared in
   code* (App Intents) and indexed by the system, so Siri/Apple Intelligence can discover and
   invoke them.

### End‑to‑end lifecycle of a voice request

```
  ┌──────────────────────────────────────────────────────────────────────────────┐
  │  1. WAKE          "Hey Siri" / side‑button                                     │
  │     Always‑On Processor → tiny DNN → 2nd‑pass DNN → speaker check              │
  ├──────────────────────────────────────────────────────────────────────────────┤
  │  2. CAPTURE       Core Audio → mel features → endpointing (when did you stop?) │
  ├──────────────────────────────────────────────────────────────────────────────┤
  │  3. ASR           Speech → text (on‑device recognizer; server for hard cases)  │
  ├──────────────────────────────────────────────────────────────────────────────┤
  │  4. UNDERSTAND    Intent + entities; pick a DOMAIN or an APP INTENT            │
  │     (Apple‑Intelligence era: the "system orchestrator" + semantic index)      │
  ├──────────────────────────────────────────────────────────────────────────────┤
  │  5. ACT / REASON  Run an App Intent, query a service, or call the LLM          │
  │     On‑device foundation model → Private Cloud Compute if too complex          │
  ├──────────────────────────────────────────────────────────────────────────────┤
  │  6. RESPOND       Compose dialog + (optional) snippet UI → Neural TTS speaks   │
  └──────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Hardware components

| Component | Role in Siri |
|---|---|
| **Microphones** | Convert speech to a waveform sampled at **16 kHz**. Fed into Core Audio. |
| **Always‑On Processor (AOP)** — the "embedded Motion Coprocessor" | A low‑power island (on iPhone 6S and later) that **continuously listens** for the wake phrase while the main CPU sleeps. Runs the small "Hey Siri" DNN on a tiny slice of its compute budget. This is why "Hey Siri" works without draining the battery. |
| **Application Processor (main CPU)** | Woken by the AOP to run the **larger second‑pass** wake‑word DNN, on‑device ASR, NLU, and to host App Intents execution. |
| **Apple Neural Engine (ANE)** | The dedicated ML accelerator on Apple Silicon. Runs the heavier neural networks efficiently — on‑device speech recognition, the on‑device **foundation model** behind Apple Intelligence, and neural text‑to‑speech. (Apple's original "Hey Siri" papers predate the ANE and describe the detector running on the AOP/CPU; modern on‑device ML for Siri leans heavily on the ANE.) |
| **Secure Enclave** | Stores biometric/key material; underpins the device identity and the attestation used when talking to servers. Personalization ("your" Hey Siri voiceprint) is kept on device. |
| **Apple Silicon servers (Private Cloud Compute)** | For requests too large for the phone, Apple runs the **same family of models** on Apple‑Silicon servers in a hardened, stateless, auditable environment. |

**Key idea:** the wake word is a *hardware‑assisted* feature. A small neural net on a coprocessor
is always running; everything else is dormant until it fires.

---

## 3. Software stack, stage by stage

### 3.1 The "Hey Siri" voice trigger (most documented stage)

The detector is a **specialized speech recognizer that only listens for one phrase.**

- **Front end:** Core Audio receives 16 kHz samples → a spectrum analysis stage turns them into
  **frames of ~0.01 s** → **mel filter‑bank** analysis weights frequencies the way human hearing
  does → these features feed the acoustic model.
- **Acoustic model (DNN):** a fully‑connected deep neural network, typically **5 hidden layers**.
  Layer width is **32, 128, or 192 units** depending on the device's memory/power budget. Input is
  ~**20 frames (~0.2 s)** of audio; output is a probability distribution over **~20 sound classes**
  (the phonetic pieces of "Hey Siri," plus silence/other speech), via a softmax producing log
  probabilities.
- **Confidence via temporal integration:** a dynamic‑programming recurrence accumulates per‑frame
  scores into a confidence that the *sequence* "Hey Siri" was spoken (not just the right sounds in
  any order).
- **Two‑pass escalation:**
  - **Pass 1 (AOP):** a *small* net (**5 layers × 32 units**) runs continuously on the motion
    coprocessor. Crossing its threshold wakes the main processor.
  - **Pass 2 (main CPU):** a *larger* net (**5 layers × 192 units**) re‑checks with stricter
    thresholds before actually triggering Siri.
- **Adaptive thresholds:** a normal threshold for confident hits, plus a **lower threshold** that
  briefly puts the detector into a "more sensitive" state, so a marginal "Hey Siri" lets you retry
  without repeating yourself.
- **Personalized Hey Siri:** during a **five‑phrase enrollment**, a separately‑trained DNN maps your
  utterances into a "speaker space." At runtime the system compares the distance of the incoming
  phrase to your enrolled reference, reducing false triggers from other people's voices.
- **Server cross‑check:** even after the phone is satisfied, the main speech recognizer on the
  server can *veto* — if it decides you actually said "Hey, seriously…," it sends a **cancellation
  signal** to put the phone back to sleep.
- **Apple Watch** uses a **single‑pass** intermediate‑size detector, gated by the wrist‑raise
  gesture, and gets only ~5% of the compute budget in that window.

### 3.2 Audio capture, VAD & endpointing

Once awake, Siri records the actual request. It runs **voice‑activity detection** and
**endpointing** to decide *when you finished speaking* so it can stop listening and process — a
surprisingly hard problem that directly affects how responsive Siri feels.

### 3.3 Automatic Speech Recognition (ASR)

Speech → text. Modern Siri does a great deal of this **on device** (neural ASR on the ANE),
falling back to the **server recognizer** for harder audio, less common languages, or when more
context is needed. Dictation and many command recognitions are fully on‑device on recent hardware.

### 3.4 Natural‑Language Understanding (NLU) & routing

The recognized text is classified into an **intent** ("what do you want") with **entities/slots**
("the details"). Historically Siri routed into a fixed set of **domains** (Messaging, Maps,
Music, Timers, Phone, Payments, etc.). The request is dispatched to whichever handler owns that
domain — a built‑in feature, or a third‑party app that registered for it.

### 3.5 The Apple‑Intelligence "system orchestrator" (the redesign)

The newer Siri adds an orchestration layer Apple calls the **system orchestrator**, coordinating
three things:

- **Spotlight's semantic index** — effectively a **vector database of embeddings** over your
  texts, emails, events, photos, and app content, enabling *personal context* ("the address Mom
  texted me yesterday").
- **On‑screen awareness** — what's currently visible (apps annotate their views so Siri can
  reference "this" / "that").
- **The App Intents catalog** — the set of actions every installed app exposes, so Siri can
  *do things inside apps*, chaining steps across apps.

> **Honesty note:** the deeply personalized, in‑app‑action Siri ("personal context," richer
> on‑screen awareness, cross‑app actions) was announced for Apple Intelligence and has rolled out
> in stages — some pieces shipped, the most ambitious personal‑context version arrived later than
> first demoed. Treat this section as the *target architecture*, parts of which are live.

### 3.6 Reasoning / generation (the LLM tier)

For open‑ended requests, Apple Intelligence uses a **two‑tier model strategy**:

- **On‑device foundation model** (the same one exposed to apps via the *Foundation Models*
  framework) handles summarization, rewriting, short answers, and tool‑calling **locally**.
- **Private Cloud Compute (PCC)** handles requests too large for the phone, using bigger
  Apple‑Silicon server models. PCC is **stateless** (no user data retained), cryptographically
  attested, and its software images are **published for independent inspection** — so the privacy
  guarantees are verifiable, not just promised.
- Optionally, with explicit user permission, Siri can hand a request to a **third‑party world‑
  knowledge model** (e.g. ChatGPT) — a separate, opt‑in path.

### 3.7 Response generation & Text‑to‑Speech

The result becomes a **spoken dialog string** plus an optional **visual snippet**. The voice is
produced by Apple's **neural TTS** (the modern Siri voices are sampled/neural, not the old
concatenative unit‑selection synthesis), rendered on device.

---

## 4. Private Cloud Compute in one paragraph

When the phone can't handle a request locally, PCC extends the device's security model into the
cloud: requests run on **Apple‑Silicon servers** with a hardened OS, **no persistent user‑data
storage**, **no privileged remote shell**, and **cryptographic attestation** so the phone will
only send data to a node whose software it can verify. Apple publishes the production images and
invites security researchers to audit them. The point: "use a big model" without "give a company
your data forever."

---

## 5. Plug‑in points for iOS apps (how *you* customize Siri)

This is the part most relevant to building an app like **SpendWise**. There are two generations of
API; new apps should use the second.

### 5.1 Generation 1 — SiriKit (legacy)

The original mechanism. Your app implemented an **Intents extension** that handled a **fixed
catalog of system domains** (Messaging, Payments, Ride Booking, Workouts, Media, etc.). You could
only do what a domain allowed, and a separate **Intents UI extension** drew custom result UI.
Still supported for those domains, but **superseded** by App Intents for new work.

### 5.2 Generation 2 — App Intents (current, iOS 16+; the path Apple Intelligence uses)

A pure‑Swift framework. You declare your app's **actions** and **data** in code; the system indexes
them and makes them available to **Siri, Apple Intelligence, Spotlight, Shortcuts, the Action
Button, Control Center, widgets, and Apple Watch** — with no separate extension and no server.

**Core building blocks:**

| Type | "Part of speech" | What it does |
|---|---|---|
| `AppIntent` | **verb** | A single action. Its `perform()` runs your code and returns a result (and optional dialog/UI). |
| `@Parameter` | **arguments** | Typed inputs to an intent; Siri/Shortcuts can prompt for or infer them. |
| `AppEntity` | **noun** | A model object Siri can reference and operate on (e.g. a *Transaction*, a *Category*). |
| `EntityQuery` | **lookup** | How the system finds entities by id, by suggestion, or by search string. |
| `AppEnum` | **fixed choices** | An enumeration parameter (e.g. *This Month / Last Month*). |
| `AppShortcut` + `AppShortcutsProvider` | **voice phrases** | Auto‑exposes an intent system‑wide and registers spoken trigger phrases — **no user setup**. |
| `ProvidesDialog` | **spoken reply** | The text Siri speaks back. |
| `ShowsSnippetView` | **visual reply** | A small SwiftUI view shown in the Siri/Spotlight result. |
| **App Intent Domains** + **Assistant Schemas** (`@AssistantIntent`, `@AssistantEntity`) | **semantic typing** | Tag your intents/entities with Apple‑defined *schemas* (e.g. "search photos," "send message," financial domains) so Apple Intelligence understands them precisely and can chain them in natural language. |
| **Focus Filters** | **automation** | React to Focus mode changes. |
| `Undoable` / `Transferable` | **richness** | Undo/redo support; hand off across devices. |

**How an app contributes to the new Siri's brain:**
- **Intent schemas** make your *actions* invokable by natural language ("take action on my content").
- **Entity schemas** contribute your *content* to **Spotlight's semantic index**, so Siri's
  personal‑context understanding can see it.
- **Donations / predictions:** when users perform actions, the system learns to **suggest** them by
  time, location, and routine (Siri Suggestions, Spotlight, the Action Button).
- **View annotations** map on‑screen views to entities for **on‑screen awareness**.

**System surfaces a single App Intent lights up:** Siri (voice + type‑to‑Siri), Apple Intelligence,
Spotlight, the Shortcuts app and automations, the Action Button, Control Center controls, Lock
Screen / Home Screen widgets, and Apple Watch.

### 5.3 The minimal recipe (and SpendWise's real example)

To make Siri *speak your data*, you need exactly two things: an `AppIntent` whose `perform()`
returns `ProvidesDialog`, and an `AppShortcutsProvider` that registers the spoken phrases.

This is precisely what SpendWise ships in
[`SpendingIntents.swift`](../SpendWise/Services/SpendingIntents.swift):

```swift
struct DescribeSpendingIntent: AppIntent {
    static var title: LocalizedStringResource = "Describe My Spending"

    @Parameter(title: "Period", default: .thisMonth)   // an AppEnum
    var period: SpendingPeriodAppEnum

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = TransactionStore()                  // loads on‑device data
        let data  = StoryDataBuilder.build(period: period.storyPeriod,
                                           expenses: store.visibleExpenses)
        return .result(dialog: IntentDialog(stringLiteral: Self.spokenSummary(data)))
    }
}

struct SpendWiseAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: DescribeSpendingIntent(),
            phrases: [
                "Describe my spending in \(.applicationName)",
                "How much have I spent in \(.applicationName)",
            ],
            shortTitle: "Describe Spending",
            systemImageName: "indianrupeesign.circle.fill"
        )
    }
}
```

Mapping back to the pipeline above: when you say *"Hey Siri, describe my spending in SpendWise,"*
stages 1–4 (wake → capture → ASR → match the phrase to this intent) are **all Apple's**, and stage
5 is **your `perform()`** running on device, returning a dialog that stage 6 speaks with neural TTS.
SpendWise's summary is computed **deterministically on‑device** (no network, no model load), so it's
fast and works even when Siri runs the intent in the background.

> **Design choices an app makes here:** keep the intent *fast and side‑effect‑free* if it may run in
> the background; set `openAppWhenRun = false` for headless replies; return a **snippet view** when a
> chart says more than words; expose `AppEntity`s if you want Siri to let users pick *which* thing to
> act on; adopt **Assistant Schemas** if you want Apple Intelligence (not just Shortcuts) to reason
> about your actions.

---

## 6. Summary mental model

- **Hardware** gives Siri an always‑listening ear (AOP), a fast brain (ANE), a secure identity
  (Secure Enclave), and an off‑device overflow brain (PCC on Apple Silicon).
- **Software** is a stop‑early pipeline: wake → capture → recognize → understand → act/reason →
  respond, escalating from coprocessor to CPU to server only as needed.
- **Apple Intelligence** adds an orchestrator that fuses a **semantic index** of your data,
  **on‑screen context**, and the **App Intents catalog** so Siri can reason over your life and act
  inside apps.
- **Apps customize Siri** by *declaring* actions (`AppIntent`) and data (`AppEntity`) in Swift and
  registering phrases (`AppShortcut`). The system handles discovery, ranking, voice, and surfacing.

---

## References

- [Hey Siri: An On‑device DNN‑powered Voice Trigger — Apple ML Research](https://machinelearning.apple.com/research/hey-siri)
- [Personalized Hey Siri — Apple ML Research](https://machinelearning.apple.com/research/personalized-hey-siri)
- [Voice Trigger System for Siri — Apple ML Research](https://machinelearning.apple.com/research/voice-trigger)
- [Deep Learning for Siri's Voice (TTS) — Apple ML Research](https://machinelearning.apple.com/research/siri-voices)
- [App Intents — Apple Developer Documentation](https://developer.apple.com/documentation/appintents)
- [App Shortcuts — Apple Developer Documentation](https://developer.apple.com/documentation/appintents/app-shortcuts)
- [Accelerating app interactions with App Intents — Apple Developer](https://developer.apple.com/documentation/AppIntents/AcceleratingAppInteractionsWithAppIntents)
- [Apple Intelligence for Developers](https://developer.apple.com/apple-intelligence/)
- [Explore advanced App Intents features for Siri and Apple Intelligence — WWDC](https://developer.apple.com/videos/play/wwdc2026/343/)
- [Inside the new Siri AI and the privacy paradox of Apple Intelligence — Scientific American](https://www.scientificamerican.com/article/inside-the-new-siri-ai-and-the-privacy-paradox-of-apple-intelligence/)

*Note: Apple does not publish a single authoritative spec for the full Siri stack; this document
synthesizes Apple's research papers, developer docs, and security materials. The "Hey Siri"
numbers (layer sizes, sampling rate, sound‑class count) are from Apple's own papers; the
Apple‑Intelligence orchestrator details reflect Apple's developer guidance and reporting, with
roll‑out caveats noted inline.*
