# SpendWise — macOS build, iCloud sync & notarization setup

This covers the steps that need your **Apple Developer account** and can't be scripted blindly
(they require your Team ID, certificates, and the CloudKit dashboard). The code for everything
below is already in the repo and both the iOS and macOS targets build today; these steps switch
the cloud sync and SMS capture on for real, signed builds.

## What's already done in code

- One app target builds for **iPhone + Mac** (`SDKROOT = auto`, macOS deployment 14.0).
- **CloudKit two-way sync** (`CloudSyncEngine`, `CKSyncEngine`) — inert until the entitlement +
  iCloud sign-in are present, so the app runs fine without it.
- **macOS SMS capture** from `~/Library/Messages/chat.db` (`SMSTransactionSource`), with a
  Full-Disk-Access onboarding screen and a "Sync from Messages" menu/Settings action.
- **Apple Intelligence** enabled on macOS 26 (graceful fallback below that).
- Entitlements files: `SpendWise/SpendWise-iOS.entitlements`, `SpendWise/SpendWise-macOS.entitlements`
  (sandbox **off** on macOS, on by default nowhere — Developer ID).

## 0. CloudKit sync is opt-in (so normal builds deploy today)

By default, **CloudKit sync is OFF** and the default entitlements are minimal:
- `SpendWise/SpendWise-iOS.entitlements` — empty (Gmail needs no special entitlement).
- `SpendWise/SpendWise-macOS.entitlements` — App Sandbox **off** only (for chat.db / Full Disk
  Access). Needs no special provisioning.

This is why the iOS app signs and deploys to a device today without the iCloud/Push capabilities.
`CloudSyncEngine` is gated behind the `SPENDWISE_CLOUDKIT` compilation condition and never touches
`CKContainer` unless it's set — so it can't crash on a build that lacks the entitlement.

The CloudKit-ready entitlements live in `SpendWise/SpendWise-CloudKit-iOS.entitlements` and
`SpendWise/SpendWise-CloudKit-macOS.entitlements`. To turn sync ON (steps below):
1. Enable the capabilities on the App ID (§1).
2. Point `CODE_SIGN_ENTITLEMENTS[sdk=iphoneos*]` / `[sdk=macosx*]` at the `-CloudKit-` files.
3. Add `SPENDWISE_CLOUDKIT` to `SWIFT_ACTIVE_COMPILATION_CONDITIONS`.

## 1. Enable capabilities on your App ID (one-time, for sync)

In the Apple Developer portal (or Xcode → Signing & Capabilities), for App ID
`com.eduquizacademy.spendwise` add:

- **iCloud** → CloudKit, container **`iCloud.com.eduquizacademy.spendwise`**
- **Push Notifications** (CKSyncEngine uses silent pushes for remote-change delivery)
- **Key-Value Storage** (the `ubiquity-kvstore` entitlement, for tags/family/profile sync)

Set the project's **`DEVELOPMENT_TEAM`** in `project.pbxproj` to your Team ID (`ZKSFH53SGY`) for
both Debug and Release if you want it baked in (the deploy script also passes it from `deploy.env`).

> Note: adding CloudKit to the App ID means your existing **iOS App Store** build will also need
> these capabilities enabled before its next submission. That's expected.

## 2. CloudKit schema

The record type auto-creates in the **Development** environment on first run (record type
`Transaction`, custom zone `transactions`, private database). Before shipping, open
**CloudKit Console → Deploy Schema to Production**.

## 3. macOS: Developer ID + notarization (not the Mac App Store)

The Mac app is **non-sandboxed** (required to read `chat.db` with Full Disk Access), so it ships
via Developer ID, not the Mac App Store. Hardened Runtime is already enabled for macOS
(`ENABLE_HARDENED_RUNTIME[sdk=macosx*] = YES`).

```sh
# Archive the macOS app
xcodebuild -project SpendWise.xcodeproj -scheme SpendWise \
  -destination 'generic/platform=macOS' -configuration Release \
  -archivePath build/SpendWise-mac.xcarchive archive

# Export with a Developer ID profile (see ExportOptions.plist; method = developer-id)
xcodebuild -exportArchive -archivePath build/SpendWise-mac.xcarchive \
  -exportOptionsPlist ExportOptions-macos.plist -exportPath build/mac

# Notarize + staple
xcrun notarytool submit build/mac/SpendWise.app --keychain-profile "AC_NOTARY" --wait
xcrun stapler staple build/mac/SpendWise.app

# Verify
spctl -a -vvv -t install build/mac/SpendWise.app
stapler validate build/mac/SpendWise.app
```

You'll need a **Developer ID Application** certificate and an App Store Connect API key stored as
a `notarytool` keychain profile (`AC_NOTARY` above). For signed local runs, set
`CODE_SIGN_IDENTITY[sdk=macosx*] = "Developer ID Application"` with a manually-managed
provisioning profile that includes the iCloud container (Automatic signing may not cover
Developer ID + CloudKit).

## 4. End-to-end verification

- **Build both:** `xcodebuild ... -destination 'platform=macOS'` and
  `-destination 'generic/platform=iOS Simulator'` — both succeed today.
- **macOS launch:** the app launches and shows sample data even without iCloud/FDA configured
  (sync + SMS stay inert — verified).
- **SMS read:** point the reader at a fixture with the `SMS_DB_PATH` env var, or grant Full Disk
  Access and use **Settings → Messages (SMS) → Sync bank SMS** / menu **Sync from Messages (⌘R)**.
- **Two-device sync:** sign two devices into the same iCloud account; a transaction created or
  recategorized on one appears on the other, with AI category/family enrichment preserved
  (field-merge resolver, not last-writer-wins).
- **Cross-channel dedup:** the same purchase arriving as a Gmail email (iPhone) and an SMS (Mac)
  converges to ONE row (conservative match: exact amount + same day + normalized merchant), with
  both source ids retained and a deterministic surviving id.

## Known follow-ups (not blocking)

- **Live Story screen-recording on Mac:** the Story video already exports on Mac via the
  cross-platform offline renderer (`StoryVideoExporter`). A ScreenCaptureKit live recorder
  (`StoryScreenRecorderMac`) is a future fidelity-only enhancement.
- **`attributedBody`-only SMS:** some recent-macOS bank SMS store the body in `attributedBody`
  with a NULL `text` column; those are skipped for now. Measure the miss rate before investing in
  `typedstream` decoding.
