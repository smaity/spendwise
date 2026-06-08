# Privacy Policy — SpendWise

**Last updated: 8 June 2026**

SpendWise ("the app", "we", "us") is a personal spending-analysis app for iOS. This policy explains what data the app accesses, how it is used, and — importantly — what we do *not* do with it. SpendWise is designed so that your financial data never leaves your device.

## Summary

- All your data stays **on your iPhone**. We operate no servers and have no database that holds your data.
- We read **only** bank transaction-alert emails from your Gmail, using Google's read-only scope.
- We do **not** sell, share, transmit, or use your data for advertising, profiling, or training any model.

## What data the app accesses

**Gmail messages (read-only).** With your permission, SpendWise connects to your Google account using the `https://www.googleapis.com/auth/gmail.readonly` scope. It filters to alert emails from a fixed list of bank senders (e.g. HDFC, ICICI, SBI, Axis, Kotak, IDFC First) and extracts transaction details — amount, date, merchant, and account — to build your spending dashboard. The app cannot send, delete, or modify any email, and never reads messages outside the bank-alert senders it looks for.

**Account email address.** The `openid email` scope is used only to display which Google account is connected and to label transactions by family member. It is shown in the app and stored on-device only.

**Manually entered transactions.** Any transactions you add by hand are stored on-device alongside the parsed ones.

## Where your data is stored

- **Parsed transactions** are saved in a local JSON file inside the app's private container on your device.
- **OAuth tokens** (used to refresh access to Gmail) are stored in the **iOS Keychain**, encrypted by the operating system.
- Nothing is uploaded to us or to any third party. There is no SpendWise account, login, or cloud backup. (Your data may be included in your personal iCloud/iTunes device backup if you have those enabled — that backup is controlled by you and Apple, not by SpendWise.)

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

Questions about this policy? Contact the developer at **mr.sajal@gmail.com**.
