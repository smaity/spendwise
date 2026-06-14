<h1 align="center">SpendWise</h1>

<p align="center"><strong>Spending insights that never leave your devices.</strong></p>

<p align="center">
  SpendWise turns your banks' alert emails and SMS into a clear, on-device picture of where your
  money goes — with Apple&nbsp;Intelligence insights and answers that stay private to your iPhone
  and Mac.
</p>

<p align="center">
  <img alt="Platform: iOS 17+" src="https://img.shields.io/badge/iOS-17%2B-black?logo=apple">
  <img alt="Platform: macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple">
  <img alt="Built with SwiftUI" src="https://img.shields.io/badge/SwiftUI-5-blue?logo=swift&logoColor=white">
  <img alt="Apple Intelligence" src="https://img.shields.io/badge/Apple%20Intelligence-on--device-purple?logo=apple">
  <img alt="Privacy: on-device" src="https://img.shields.io/badge/privacy-on--device-brightgreen">
  <img alt="License: Apache 2.0" src="https://img.shields.io/badge/license-Apache%202.0-lightgrey">
</p>

<p align="center">
  <img src="screenshots/spendwise-demo.gif" width="300" alt="SpendWise screens cycling through Dashboard, Transactions, Balance Sheet, Insights, Repeats, and Settings">
</p>

---

**Why on-device?** Your spending is some of your most sensitive data. SpendWise reads your bank
alerts, analyzes them, categorizes with Apple Intelligence, and answers your questions — all on
your own devices. Nothing is uploaded to any server; there's no account to create.

**Gmail + SMS.** On iPhone, SpendWise reads your banks' alert *emails* from Gmail — iOS blocks
third-party apps from reading SMS. On **Mac**, it additionally reads bank *SMS* that your iPhone
forwards to Messages (via Continuity), closing the gap for the UPI and small-value payments that
in India often arrive only by SMS. The two devices converge over your **local Wi-Fi** — no server
and no paid iCloud required. A payment seen on both channels is de-duplicated so it counts once.

## Features

- **Runs on iPhone + Mac** — one app, one codebase; the Mac adds SMS capture and a desktop sidebar layout
- **Dashboard** — monthly total, income-vs-spending, investments, category donut, daily trend, month-over-month comparison
- **Transactions** — searchable list with source badges (SMS / email / manual), timestamps, manual add, swipe to delete, long-press to recategorize
- **Balance Sheet** — an income & expenditure statement by **month / year / all-time**, with drill-down into every category
- **Insights** — category spend spikes, food-delivery overuse, subscription detection, small-purchase leaks
- **Repeats** — recurring payments and subscriptions surfaced automatically
- **macOS SMS capture** — reads bank SMS forwarded to Messages (`chat.db`, Full Disk Access) through the same parser as email, with cross-channel de-duplication
- **Cross-device sync** — local Wi-Fi peer sync (MultipeerConnectivity); optional CloudKit behind a build flag
- **Family spending** — tag transfers to family members by account number or name (deterministic, with optional Apple Intelligence); they count as spending and show a "To family" badge
- **Named accounts** — name recipient accounts the bank reports only by number (e.g. society maintenance, rent) → a readable payee and the right category; editable in Settings
- **Apple Intelligence** (iOS 26+ / macOS 26+, on-device, via Foundation Models):
  - *Categorization* — the on-device LLM is the primary categorizer, falling back to the embedding classifier when unavailable
  - *Insights summary* — a natural-language overview of your month plus tailored money-saving tips
  - *Ask your data* — chat with your own finances ("How much on food this month?"); answers are grounded in a local digest and never leave the device
  - *Family & duplicate detection* — fuzzy name matching and cross-channel dedup for the hard cases heuristics miss
- **Smart categorization** — an on-device, self-improving classifier (exact-merchant memory + `NLContextualEmbedding` kNN, warm-started from keyword rules) that learns from your corrections; the fallback when Apple Intelligence isn't available
- **Custom detection rules** — in-app editor (Settings → Detection Rules) for bank senders, keyword→category mappings, and named accounts, all taking precedence over the built-ins
- **Spending Story** — an Apple-Intelligence-narrated video recap of your month ("Hey Siri, show my spending story")
- **App lock** — optional Face ID / Touch ID lock (with passcode fallback) that re-locks on backgrounding
- Ships with sample data so the app works immediately, before any account is connected

## Requirements

- Mac with **Xcode 16+**
- iPhone on **iOS 17+** and/or Mac on **macOS 14+**
- Free Google Cloud account (for Gmail sync)
- Apple Intelligence features need **iOS 26 / macOS 26** on supported hardware; everything else works without it
- macOS SMS capture needs **Text Message Forwarding** enabled on your iPhone and **Full Disk Access** granted to the Mac app

## Run it

1. Open `SpendWise.xcodeproj` in Xcode.
2. Select the SpendWise target → Signing & Capabilities → choose your Team (a free Apple ID works).
3. Pick **My Mac** or an iPhone / simulator → ⌘R.

The app runs with sample data out of the box. Gmail sync and macOS SMS capture each need a one-time setup below.

## Gmail setup (one-time, ~10 minutes)

1. Go to [Google Cloud Console](https://console.cloud.google.com/) → create a project (e.g. "SpendWise").
2. **APIs & Services → Library** → enable **Gmail API**.
3. **APIs & Services → OAuth consent screen** → External → fill app name + your email → add scope `gmail.readonly` → add yourself as a **Test user**.
4. **APIs & Services → Credentials → Create Credentials → OAuth client ID** → Application type: **iOS** → Bundle ID: `com.eduquizacademy.spendwise` (must match the Bundle Identifier in Xcode).
5. Copy `Secrets.swift.example` (repo root) to `SpendWise/Secrets.swift` and paste in your client ID:
   ```swift
   enum AppSecrets {
       static let googleClientID = "1234567890-abc.apps.googleusercontent.com"
   }
   ```
   `SpendWise/Secrets.swift` is git-ignored, so your credential is never committed.
6. Run the app → Settings → **Connect Gmail** → sign in. It fetches the last 90 days of alerts.
7. **Family members**: tap **Add family member's Gmail** in Settings and have them sign in on your phone. Each account must also be added as a Test user in step 3.

Notes:
- While the consent screen is in "Testing" mode, only the test users you added can sign in — fine for personal use, no Google review needed.
- The app requests only `gmail.readonly` and filters to bank-alert senders. Tokens live in the Keychain; transactions in a local SQLite database under Application Support.

## macOS SMS capture (optional)

On a Mac, SpendWise can read the bank SMS your iPhone forwards to Messages:

1. On **iPhone**: Settings → Messages → **Text Message Forwarding** → enable your Mac.
2. Run the **macOS** app → Settings → **Grant Full Disk Access** (so it can read the local Messages database). The app is non-sandboxed for this reason.
3. New bank SMS are imported automatically (and periodically while the Mac is awake), then sync to your iPhone over local Wi-Fi.

Apple blocks SMS access on iOS, so this capture path is macOS-only; your iPhone still reads bank alerts from Gmail.

## Customizing

- **No code needed**: add bank senders, keyword→category rules, and named accounts in-app via **Settings → Detection Rules**. Custom rules persist on-device and override the built-ins.
- **Add your bank in code**: extend `bankSenders` / `bankBodyNeedles` in `TransactionParser.swift` and, if its wording differs, the regexes there.
- **Built-in category rules**: edit `categoryRules` in `TransactionParser.swift` — these also seed the on-device classifier in `CategoryClassifier.swift`.
- **Insight thresholds**: tune the rules in `InsightsEngine.swift`.

## Project layout

```
SpendWise/
├── SpendWiseApp.swift              App entry, scene phases, background refresh
├── Brand.swift                     Product identity (name, tagline, colors)
├── Models/
│   ├── Transaction.swift           Transaction, category, statement model
│   ├── FamilyMember.swift          Family member + user profile
│   └── SpendingStory.swift         Spending Story model
├── Stores/
│   ├── TransactionStore.swift      State, SQLite persistence, analytics, sync, sample data
│   └── RulesStore.swift            User-editable senders, category, and named-account rules
├── Services/
│   ├── GmailService.swift          OAuth (PKCE) + Gmail API fetch
│   ├── SMSTransactionSource.swift  macOS: reads bank SMS from Messages chat.db
│   ├── TransactionParser.swift     Parsing of Indian bank alert emails / SMS
│   ├── TransactionDatabase.swift   SQLite store
│   ├── AppFiles.swift              App-private storage location
│   ├── LocalSyncService.swift      Local Wi-Fi peer sync (MultipeerConnectivity)
│   ├── CloudSyncEngine.swift       Optional CloudKit sync + field-merge resolver
│   ├── CategoryClassifier.swift    On-device embedding classifier (fallback)
│   ├── AICategoryClassifier.swift  Apple Intelligence categorizer (primary)
│   ├── AIInsightsService.swift     Apple Intelligence insights summary
│   ├── AIQueryService.swift        Apple Intelligence spending Q&A
│   ├── AIFamilyTransferService.swift / AIDuplicateDetector.swift / AISpendingValidator.swift
│   ├── InsightsEngine.swift        Savings + investment suggestion rules
│   ├── Story*.swift                Spending Story narration, recording, export
│   └── AppLock.swift               Optional Face ID / Touch ID app lock
└── Views/                          MainNavigation (tabs / macOS sidebar), Dashboard,
                                    Transactions, BalanceSheet (NetWorthView), Insights,
                                    Repeats, Settings, RulesView, AskAI, Spending Story
```

## Disclaimer

Investment suggestions are rule-based educational pointers, not financial advice. Consult a SEBI-registered investment advisor for personalised guidance.

## License

Licensed under the [Apache License, Version 2.0](LICENSE). Copyright 2026 Sajal Maity.
