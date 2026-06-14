# Privacy Policy — SpendWise

**Last updated: 8 June 2026**

SpendWise ("the app", "we", "us") is a personal spending-analysis app for iPhone and Mac. This policy explains what data the app accesses, how it is used, and — importantly — what we do *not* do with it. SpendWise is designed so that your financial data stays under your control: it is processed on your devices, and the only place it is ever stored off-device is **your own private iCloud account**, if you choose to use sync.

## Summary

- Your data lives **on your devices**. We operate no servers and have no database that holds your data.
- If you use more than one device, transactions sync **directly between your own devices over your local Wi-Fi network** (Apple's MultipeerConnectivity) — peer-to-peer, encrypted, never through any server. (An optional iCloud/CloudKit sync through your own private iCloud database is also supported in builds configured for it.)
- On **iPhone**, we read **only** bank transaction-alert emails from your Gmail, using Google's read-only scope.
- On **Mac**, we can additionally read **only** bank transaction-alert SMS that your iPhone forwards to the Messages app — on-device, read-only.
- We do **not** sell, share, transmit (other than to your own iCloud), or use your data for advertising, profiling, or training any model.

## What data the app accesses

**Gmail messages (read-only).** With your permission, SpendWise connects to your Google account using the `https://www.googleapis.com/auth/gmail.readonly` scope. It filters to alert emails from a fixed list of bank senders (e.g. HDFC, ICICI, SBI, Axis, Kotak, IDFC First) and extracts transaction details — amount, date, merchant, and account — to build your spending dashboard. The app cannot send, delete, or modify any email, and never reads messages outside the bank-alert senders it looks for.

**Account email address.** The `openid email` scope is used only to display which Google account is connected and to label transactions by family member. It is shown in the app and stored on-device only.

**Messages / SMS (macOS only, read-only).** On the Mac, SpendWise can read bank transaction-alert **SMS** that your iPhone forwards to the Messages app (via Apple's Text Message Forwarding). This requires you to grant the app **Full Disk Access** in macOS System Settings; without it, no SMS are read. The app reads the local Messages database on-device only, filters to bank-alert senders, and extracts the same transaction details as the email path. It never reads personal messages into your ledger (non-bank messages are discarded), and nothing from Messages is transmitted anywhere except, like any transaction, into your own private iCloud if sync is enabled. This capability does not exist on iPhone, because Apple does not permit third-party apps to read the SMS inbox on iOS.

**Manually entered transactions.** Any transactions you add by hand are stored on-device alongside the parsed ones.

## Where your data is stored

- **Parsed transactions** are saved in a local JSON file inside the app's private container on each device.
- **Sync between your devices** is **peer-to-peer over your local Wi-Fi network** (MultipeerConnectivity): your iPhone and Mac discover each other on the same network and exchange transactions directly, end-to-end encrypted, with no server and nothing leaving your local network. It requires the **Local Network** permission and works when both apps are open on the same network. (Builds configured for it can instead sync via **CloudKit** in the private database of your own iCloud account — Apple-encrypted, accessible only to you, with no SpendWise server in the path.)
- **OAuth tokens** (used to refresh access to Gmail) are stored in the **iOS Keychain**, encrypted by the operating system.
- Other than your own iCloud sync, nothing is uploaded to us or to any third party. There is no SpendWise account or login. (Your data may also be included in your personal iCloud/iTunes device backup if you have those enabled — that backup is controlled by you and Apple, not by SpendWise.)

## How your data is used

Your transaction data is used solely, on your device, to:

- show spending dashboards, charts, and month-over-month comparisons;
- generate rule-based insights (e.g. category spikes, subscription detection); and
- produce educational saving/investment pointers.

It is never used for any other purpose.

## Data sharing

We do not share your data with anyone. No analytics SDKs, no advertising networks, no third-party trackers are present in the app. The only network calls the app makes are directly to **Google's Gmail API** to fetch your bank-alert emails, authenticated by you.

## Google API Services — Limited Use disclosure

SpendWise's use and transfer of information received from Google APIs adheres to the [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy), including the **Limited Use** requirements. Specifically:

- Data obtained from Gmail is used **only** to provide and improve the in-app spending-analysis features visible to you.
- We do **not** transfer this data to others except as necessary to provide those features (which, for SpendWise, means *no transfer at all* — processing happens on-device).
- We do **not** use this data for serving advertisements.
- We do **not** allow humans to read this data, and we do not use it to train generalized AI/ML models. Data is processed only by the app's automated parsing on your device.

## Revoking access

You can disconnect a Google account at any time from the app's **Settings** screen, which removes its tokens from the Keychain. You can also revoke SpendWise's access independently at any time via your Google Account: [Security → Third-party apps with account access](https://myaccount.google.com/connections).

## Deleting your data

Because all data is local, deleting the SpendWise app from your iPhone permanently removes all stored transactions and tokens. There is nothing for us to delete on our side, because we never hold your data.

## Children's privacy

SpendWise is not directed at children under 13 and does not knowingly collect data from them.

## Changes to this policy

We may update this policy as the app evolves. Material changes will be reflected here with a new "Last updated" date.

## Contact

Questions about this policy? Contact the developer at **your-email@example.com**.
