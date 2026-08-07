# Privacy Policy — SpendWise

**Last updated: 7 August 2026**

SpendWise ("the app", "we", "us") is a personal spending-analysis app for iPhone and Mac. This policy explains what data the app accesses, how it is used, and — importantly — what we do *not* do with it. SpendWise is designed so that your financial data never leaves your own devices.

## Summary

- All your data stays **on your own devices** (your iPhone and, if you use the Mac app, your Mac). We operate no servers and have no database that holds your data.
- We read **only** bank transaction-alert emails from your Gmail (read-only scope) and, on Mac, bank transaction-alert SMS that your iPhone forwards to the Messages app.
- Syncing between your iPhone and Mac happens **directly over your local Wi-Fi** — not through any server.
- We do **not** sell, share, transmit, or use your data for advertising, profiling, or training any model. Apple Intelligence features run entirely on-device.

## What data the app accesses

**Gmail messages (read-only).** With your permission, SpendWise connects to your Google account using the `https://www.googleapis.com/auth/gmail.readonly` scope. It filters to alert emails from a fixed list of bank senders (e.g. HDFC, ICICI, SBI, Axis, Kotak, IDFC First) and extracts transaction details — amount, date, merchant, and account — to build your spending dashboard. The app cannot send, delete, or modify any email, and never reads messages outside the bank-alert senders it looks for.

**Account email address.** The `openid email` scope is used only to display which Google account is connected and to label transactions by family member. It is shown in the app and stored on-device only.

**Bank SMS on Mac (optional).** If you use the Mac app and have **Text Message Forwarding** enabled on your iPhone, SpendWise — with the **Full Disk Access** permission you explicitly grant in System Settings — reads the local Messages database on your Mac to find transaction-alert SMS from recognized bank senders. Only messages matching those bank senders are parsed; other conversations are ignored. Parsed SMS go through the same on-device pipeline as emails, and a payment seen in both an email and an SMS is de-duplicated so it counts once. Nothing read from Messages ever leaves your Mac except via the local device-to-device sync described below.

**Manually entered transactions.** Any transactions you add by hand are stored on-device alongside the parsed ones.

## Apple Intelligence and on-device processing

Where available (iOS 26 / macOS 26 on supported hardware), SpendWise uses **Apple Intelligence via Apple's on-device Foundation Models** for transaction categorization, insights summaries, and the "ask your data" chat. This processing happens on your device; your financial data is not sent to us or to any third-party AI service. On devices without Apple Intelligence, categorization falls back to an on-device classifier — again with no data leaving the device.

## Where your data is stored

- **Parsed transactions** are saved in a local JSON file inside the app's private container on your device.
- **OAuth tokens** (used to refresh access to Gmail) are stored in the system **Keychain** on your iPhone or Mac, encrypted by the operating system.
- Nothing is uploaded to us or to any third party. There is no SpendWise account, login, or cloud backup. (Your data may be included in your personal iCloud/iTunes device backup if you have those enabled — that backup is controlled by you and Apple, not by SpendWise.)

## Syncing between your devices

If you use SpendWise on both iPhone and Mac, the two apps discover each other **on your local Wi-Fi network** and exchange transaction data **directly, device to device** (using Apple's MultipeerConnectivity framework). No server, no SpendWise account, and no third party is involved; data moves only between devices you own, on your own network, and transactions seen by both devices are de-duplicated. Optionally, builds compiled with the CloudKit flag can instead sync through **your personal iCloud** — in that case the data lives in your private iCloud database under Apple's terms; SpendWise still has no server of its own. This flag is off by default.

## How your data is used

Your transaction data is used solely, on your device, to:

- show spending dashboards, charts, and month-over-month comparisons;
- generate rule-based insights (e.g. category spikes, subscription detection); and
- produce educational saving/investment pointers.

It is never used for any other purpose.

## Data sharing

We do not share your data with anyone. No analytics SDKs, no advertising networks, no third-party trackers are present in the app. The only internet calls the app makes are directly to **Google's Gmail API** to fetch your bank-alert emails, authenticated by you. The only other network traffic is the **local Wi-Fi sync between your own devices** described above, which never leaves your network.

## Google API Services — Limited Use disclosure

SpendWise's use and transfer of information received from Google APIs adheres to the [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy), including the **Limited Use** requirements. Specifically:

- Data obtained from Gmail is used **only** to provide and improve the in-app spending-analysis features visible to you.
- We do **not** transfer this data to others except as necessary to provide those features (which, for SpendWise, means *no transfer at all* — processing happens on-device).
- We do **not** use this data for serving advertisements.
- We do **not** allow humans to read this data, and we do not use it to train generalized AI/ML models. Data is processed only by the app's automated parsing on your device.

## Revoking access

You can disconnect a Google account at any time from the app's **Settings** screen, which removes its tokens from the Keychain. You can also revoke SpendWise's access independently at any time via your Google Account: [Security → Third-party apps with account access](https://myaccount.google.com/connections).

## Deleting your data

Because all data is local, deleting the SpendWise app from a device permanently removes all transactions and tokens stored on that device (delete it from each device you use it on). To stop Mac SMS capture, revoke Full Disk Access in System Settings or disable Text Message Forwarding on your iPhone. There is nothing for us to delete on our side, because we never hold your data.

## Children's privacy

SpendWise is not directed at children under 13 and does not knowingly collect data from them.

## Changes to this policy

We may update this policy as the app evolves. Material changes will be reflected here with a new "Last updated" date.

## Contact

Questions about this policy? Contact the developer at **mr.sajal@gmail.com**.
