// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import Foundation
import SwiftUI
import Combine

@MainActor
final class TransactionStore: ObservableObject {
    @Published var transactions: [Transaction] = []
    @Published var isSyncing = false
    @Published var lastSync: Date?
    @Published var syncError: String?
    /// e.g. "March 2026" — the month currently being imported (nil when idle).
    @Published var syncProgress: String?
    /// nil = whole family; otherwise show only this account's spending.
    @Published var memberFilter: String?
    /// User-assigned tags keyed by normalized merchant ("party"). A party tagged once
    /// stays tagged as new transactions from it arrive on future syncs.
    @Published var partyTags: [String: [String]] = [:]
    /// The user's family. Apple Intelligence matches transfer recipients against these
    /// (name, relationship, aliases) to flag money sent to family.
    @Published var familyMembers: [FamilyMember] = []
    /// The user's own identity, used to sharpen inference (e.g. excluding self-transfers).
    @Published var userProfile = UserProfile()

    private let db = TransactionDatabase()

    private static let partyTagsKey = "party_tags"
    private static let familyMembersKey = "family_members_v2"
    private static let userProfileKey = "user_profile"

    let gmail = GmailService()
    /// Two-way iCloud sync (iPhone email capture ↔ Mac SMS capture). Inert until iCloud is
    /// signed in and the container is entitled, so the app runs unchanged without it.
    private let cloud = CloudSyncEngine()
    /// Free-account peer-to-peer sync over the local Wi-Fi network (no paid capabilities needed).
    /// The iPhone and Mac discover each other and exchange ledgers directly.
    private let localSync = LocalSyncService()
    /// Name of the nearby device we last synced with over Wi-Fi (for a Settings status line).
    @Published var nearbyDeviceName: String?
    /// Sentinel `syncError` value the macOS UI maps to the "Grant Full Disk Access" flow.
    /// Declared cross-platform so view code can compare against it without `#if`.
    static let fullDiskAccessSentinel = "FULL_DISK_ACCESS"
    #if os(macOS)
    /// Reads bank SMS from the Messages chat.db (macOS only — Apple blocks SMS access on iOS).
    private let smsSource = SMSTransactionSource()
    private static let smsWatermarkKey = "sms_watermark"
    /// Human-readable result of the last SMS sync, shown in Settings.
    @Published var smsStatus: String?
    /// Re-reads SMS on a timer while the Mac app runs, so new bank SMS flow in automatically
    /// (and reach nearby devices over Wi-Fi) without manual syncing.
    private var smsSyncTimer: Timer?
    #endif
    /// Apple Intelligence detector for transfers sent to family members (iOS 26+).
    private let familyDetector = AIFamilyTransferService()
    private var isDetectingFamily = false
    /// Apple Intelligence duplicate detector — judges whether two same-amount/same-day alerts are
    /// the same payment (email+SMS of one transfer) or genuinely separate.
    private let dupeDetector = AIDuplicateDetector()
    /// Status of the last AI duplicate pass, shown in Settings.
    @Published var dedupStatus: String?
    /// Apple Intelligence validator — tells a completed payment from a notice (bill due, scheduled
    /// auto-debit, payment request, declined).
    private let spendingValidator = AISpendingValidator()
    /// Status of the last AI non-transaction cleanup, shown in Settings.
    @Published var validationStatus: String?
    /// On-device, self-improving category classifier (warm-started from keyword seeds).
    /// Used as the fallback when Apple Intelligence isn't available.
    private let classifier = CategoryClassifier()
    /// Primary classifier: Apple Intelligence's on-device model (iOS 26+). Falls through
    /// to `classifier` when unavailable.
    private let aiClassifier = AICategoryClassifier()
    /// Confidence below which we trust the parser's keyword category instead of the model.
    private static let classifierThreshold = 0.55
    private var cancellables = Set<AnyCancellable>()

    init() {
        AppFiles.migrateLegacyStorageIfNeeded()   // move data out of ~/Documents (older builds)
        load()
        #if DEBUG
        // Screenshot/marketing mode: seed rich, fully-tagged demo data and skip the normal
        // empty-start + sync pipeline. Gated on a launch env var; compiled out of Release builds.
        if ProcessInfo.processInfo.environment["DEMO_DATA"] != nil { seedDemoData(); return }
        #endif
        backfillReferenceIDs()   // populate reference numbers on rows imported before ref tracking
        collapseDuplicates()     // collapse duplicates (by reference number, then by content)
        if let data = UserDefaults.standard.data(forKey: Self.partyTagsKey),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            partyTags = decoded
        }
        if let data = UserDefaults.standard.data(forKey: Self.familyMembersKey),
           let decoded = try? JSONDecoder().decode([FamilyMember].self, from: data) {
            familyMembers = decoded
        }
        if let data = UserDefaults.standard.data(forKey: Self.userProfileKey),
           let decoded = try? JSONDecoder().decode(UserProfile.self, from: data) {
            userProfile = decoded
        }
        // No demo/sample seeding — the app starts empty and fills from Gmail (iPhone) and SMS (Mac).
        transactions.removeAll { $0.source == "sample" }

        // One-time: clear family-transfer verdicts from earlier builds that wrongly name-matched
        // generic-recipient transfers (e.g. "UPI transfer" → a family member). They re-evaluate
        // with the fixed, guard-railed logic on the next detection pass.
        if !UserDefaults.standard.bool(forKey: "family_reclassified_v4") {
            for i in transactions.indices where transactions[i].isTransfer {
                transactions[i].toFamily = nil
                transactions[i].familyMember = nil
                transactions[i].isSelfTransfer = nil
            }
            UserDefaults.standard.set(true, forKey: "family_reclassified_v4")
            save()
        }
        // One-time re-categorization: rows imported before category rules improved (e.g. UPI
        // payments to Amazon/Zomato bucketed as "Transfers", securities mandates as "Transfers")
        // get re-run through the keyword categorizer and upgraded to a more specific category.
        if !UserDefaults.standard.bool(forKey: "recategorize_v1") {
            for i in transactions.indices where transactions[i].category == .transfer && !transactions[i].isIncome {
                let newCat = TransactionParser.categorize(merchant: transactions[i].merchant,
                                                          fullText: (transactions[i].rawSnippet ?? "").lowercased())
                if newCat != .other && newCat != .transfer { transactions[i].category = newCat }
            }
            UserDefaults.standard.set(true, forKey: "recategorize_v1")
            save()
        }
        // One-time: give SMS rows imported before timestamp handling a real time-of-day, recovered
        // from the transaction time stated in their stored message body.
        if !UserDefaults.standard.bool(forKey: "sms_timestamps_v1") {
            backfillSMSTimestamps()
            UserDefaults.standard.set(true, forKey: "sms_timestamps_v1")
        }
        // One-time: re-parse transfer rows with the improved SI/NEFT recipient extraction (recovers
        // the payee account/name HDFC prints as "Info: XXXXXXXXXX1234 NET BANKING SI -Alex") and
        // clear stale family verdicts so the launch detection re-tags them deterministically.
        if !UserDefaults.standard.bool(forKey: "family_si_v5") {
            refreshTransferRecipients()
            UserDefaults.standard.set(true, forKey: "family_si_v5")
            save()
        }
        detectSelfTransfers()   // net out moves between the user's own accounts

        // Re-render views observing this store when accounts change (connect/rename/remove).
        gmail.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Mirror small user settings across devices via iCloud key-value store, and pull any
        // edits made on another device.
        loadSettingsFromCloud()
        NotificationCenter.default.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification)
            .sink { [weak self] _ in self?.loadSettingsFromCloud() }
            .store(in: &cancellables)

        // Activate transaction sync (no-op if iCloud isn't available).
        Task { await cloud.start(store: self) }

        // Activate local-network (Wi-Fi) peer sync: hand received ledgers to the same merge
        // pipeline. Seed the snapshot with our current ledger for peers that connect first.
        localSync.onReceive = { [weak self] received in
            self?.applyRemote(modified: received, deletedIDs: [])
        }
        localSync.onConnected = { [weak self] name in self?.nearbyDeviceName = name }
        localSync.updateLedger(transactions)
        localSync.start()

        #if os(macOS)
        // Read SMS now and then periodically, so new bank SMS flow in automatically and sync to
        // nearby devices over Wi-Fi.
        startPeriodicSMSSync()
        Task { if canReadSMS() { await syncFromSMS() } }
        #endif
    }

    /// Re-kicks Wi-Fi peer discovery and re-publishes the current ledger. Call when the app
    /// launches or returns to the foreground so it promptly syncs with the other device.
    func restartLocalSync() {
        localSync.updateLedger(transactions)
        localSync.restart()
    }

    /// Pushes locally-originated changes to all sync transports (iCloud queue + Wi-Fi peers).
    private func pushChanges(_ ids: [UUID]) {
        cloud.recordLocalChanges(ids)
        localSync.updateLedger(transactions)
    }

    /// Look up a single transaction by id — used by the CloudKit sync engine.
    func transaction(withID id: UUID) -> Transaction? {
        transactions.first { $0.id == id }
    }

    // MARK: Persistence

    func load() {
        transactions = db.loadAll()
        // One-time migration from the legacy transactions.json written by earlier builds.
        if db.isEmpty {
            let legacy = AppFiles.url("transactions.json")
            if let data = try? Data(contentsOf: legacy),
               let decoded = try? JSONDecoder().decode([Transaction].self, from: data) {
                transactions = decoded
                db.replaceAll(decoded)
                try? FileManager.default.removeItem(at: legacy)
                NSLog("SPENDWISE_DB: migrated \(decoded.count) rows from JSON to SQLite")
            }
        }
    }

    func save() {
        db.replaceAll(transactions)
    }

    // MARK: Mutations

    func add(_ tx: Transaction) {
        var tx = tx
        tx.modifiedAt = Date()
        transactions.append(tx)
        transactions.sort { $0.date > $1.date }
        if !tx.isIncome {
            classifier.train(merchant: tx.merchant, text: Self.trainingText(tx), category: tx.category)
        }
        save()
        pushChanges([tx.id])
    }

    func delete(_ tx: Transaction) {
        transactions.removeAll { $0.id == tx.id }
        save()
        cloud.recordLocalDeletions([tx.id])
    }

    func recategorize(_ tx: Transaction, to category: SpendCategory) {
        guard let i = transactions.firstIndex(where: { $0.id == tx.id }) else { return }
        transactions[i].category = category
        transactions[i].kind = category == .income ? .income : .expense   // keep direction consistent
        transactions[i].modifiedAt = Date()
        // A user correction is the strongest training signal — teach the model.
        if category != .income {
            classifier.train(merchant: transactions[i].merchant,
                             text: Self.trainingText(transactions[i]), category: category, weight: 2.0)
        }
        save()
        pushChanges([tx.id])
    }

    /// Text the classifier learns from / predicts on: merchant plus the original alert body.
    private static func trainingText(_ tx: Transaction) -> String {
        tx.merchant + " " + (tx.rawSnippet ?? "")
    }

    /// Applies the learned model to a freshly fetched expense, overriding the parser's
    /// keyword guess only when the model is confident. Income categories are left as-is.
    private func categorized(_ tx: Transaction) -> Transaction {
        guard !tx.isIncome else { return tx }
        guard let prediction = classifier.classify(merchant: tx.merchant, text: Self.trainingText(tx)),
              prediction.confidence >= Self.classifierThreshold else { return tx }
        var t = tx
        t.category = prediction.category
        return t
    }

    /// Disconnects a Gmail account and removes its transactions.
    func removeMember(_ account: GmailAccount) {
        gmail.disconnect(account)
        let removedIDs = transactions.filter { $0.account == account.email }.map(\.id)
        transactions.removeAll { $0.account == account.email }
        if memberFilter == account.email { memberFilter = nil }
        save()
        cloud.recordLocalDeletions(removedIDs)
    }

    // MARK: Gmail sync

    func syncFromGmail(daysBack: Int = 90) async {
        isSyncing = true
        syncError = nil
        defer { isSyncing = false }
        do {
            let fetched = try await gmail.fetchTransactions(daysBack: daysBack)
            let addedIDs = commitMerge(fetched)
            await refineWithAI(addedIDs)
            await detectFamilyTransfers()
            lastSync = Date()
        } catch {
            syncError = error.localizedDescription
        }
    }

    /// Wipes synced (Gmail/sample) transactions and re-imports the last `monthsBack` months.
    /// Manual entries and party tags are preserved — tags re-attach to re-synced parties by name.
    func resyncAll(monthsBack: Int = 12) async {
        transactions.removeAll { $0.source != "manual" }
        save()
        if gmail.isConnected {
            await syncFromGmail(monthsBack: monthsBack)
        }
    }

    /// Imports `monthsBack` months of history one calendar month at a time (newest first),
    /// so each Gmail query stays under the result cap. Pass 12 to pull the last year.
    func syncFromGmail(monthsBack: Int) async {
        guard gmail.isConnected else { return }
        isSyncing = true
        syncError = nil
        defer { isSyncing = false; syncProgress = nil }

        let cal = Calendar.current
        let now = Date()
        let thisMonthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now

        var fetchedAll: [Transaction] = []
        var errors: [String] = []

        for m in 0..<max(monthsBack, 1) {
            guard let monthStart = cal.date(byAdding: .month, value: -m, to: thisMonthStart),
                  let nextMonth = cal.date(byAdding: .month, value: 1, to: monthStart) else { continue }
            let before = min(nextMonth, now)
            syncProgress = monthStart.formatted(.dateTime.month(.wide).year())

            for account in gmail.accounts {
                do {
                    fetchedAll += try await gmail.fetchTransactions(for: account, after: monthStart, before: before)
                } catch {
                    errors.append("\(account.label): \(error.localizedDescription)")
                }
            }
        }

        let addedIDs = commitMerge(fetchedAll)
        if addedIDs.isEmpty, let first = errors.first { syncError = first }
        await refineWithAI(addedIDs)
        await detectFamilyTransfers()
        lastSync = Date()
    }

    #if os(macOS)
    // MARK: SMS sync (macOS only)

    /// Whether the Mac can currently read the Messages database (Full Disk Access granted).
    func canReadSMS() -> Bool { smsSource.canReadMessages() }

    /// Starts periodic background SMS reads (every 15 min) while the Mac app is running. Quietly
    /// skips when busy or when Full Disk Access hasn't been granted (so it doesn't nag).
    func startPeriodicSMSSync() {
        guard smsSyncTimer == nil else { return }
        smsSyncTimer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isSyncing, self.canReadSMS() else { return }
                await self.syncFromSMS()
            }
        }
    }

    /// Wipes SMS-sourced transactions, resets the read watermark, and re-imports everything from
    /// the Messages database. Mirrors the Gmail "Clear & re-sync". Tags and manual/Gmail rows are
    /// untouched. Useful after parser improvements or to rebuild a clean SMS ledger.
    func clearAndResyncSMS() async {
        let removed = transactions.filter { $0.source == "sms" }.map(\.id)
        transactions.removeAll { $0.source == "sms" }
        UserDefaults.standard.removeObject(forKey: Self.smsWatermarkKey)
        save()
        cloud.recordLocalDeletions(removed)
        localSync.updateLedger(transactions)
        await syncFromSMS()
    }

    /// Imports bank SMS from the Messages chat.db, runs them through the same merge/AI/family
    /// pipeline as Gmail, and syncs the results to other devices via iCloud. Sets
    /// `syncError == fullDiskAccessSentinel` when Full Disk Access hasn't been granted.
    func syncFromSMS() async {
        isSyncing = true
        syncError = nil
        defer { isSyncing = false }
        smsStatus = nil
        do {
            let watermark = (UserDefaults.standard.object(forKey: Self.smsWatermarkKey) as? Date) ?? .distantPast
            let result = try smsSource.fetchTransactions(since: watermark)
            let addedIDs = commitMerge(result.transactions)
            UserDefaults.standard.set(result.watermark, forKey: Self.smsWatermarkKey)
            await refineWithAI(addedIDs)
            await detectFamilyTransfers()
            lastSync = Date()
            smsStatus = addedIDs.isEmpty
                ? "No new bank transactions found in Messages. (If you just enabled Text Message Forwarding, new bank SMS will appear here.)"
                : "Imported \(addedIDs.count) transaction\(addedIDs.count == 1 ? "" : "s") from SMS."
        } catch SMSTransactionSource.SMSAccessError.fullDiskAccessDenied {
            syncError = Self.fullDiskAccessSentinel
        } catch SMSTransactionSource.SMSAccessError.databaseUnavailable {
            syncError = "No Messages history found on this Mac. Enable Text Message Forwarding on your iPhone."
        } catch {
            syncError = error.localizedDescription
        }
    }
    #endif

    /// Merges fetched transactions into the store, persisting only if anything changed.
    /// Returns the IDs of the genuinely new transactions added.
    @discardableResult
    private func commitMerge(_ fetched: [Transaction]) -> [UUID] {
        let result = merge(fetched)
        if result.changed {
            if result.added > 0 {
                transactions.removeAll { $0.source == "sample" }   // drop demo data once real data arrives
            }
            transactions.sort { $0.date > $1.date }
            collapseDuplicates()   // collapse same-transaction-multiple-SMS (and email+SMS) duplicates
            save()
            pushChanges(result.addedIDs)
        }
        return result.addedIDs
    }

    /// Applies changes pulled FROM iCloud (the other device). Same-id rows are field-merged so
    /// local AI enrichment is never clobbered; genuinely new rows are inserted. Does not re-push
    /// (these came from the cloud) except to propagate a merge the other device hadn't seen.
    func applyRemote(modified: [Transaction], deletedIDs: [UUID]) {
        var changed = false
        var rePush: [UUID] = []
        for remote in modified {
            if let i = transactions.firstIndex(where: { $0.id == remote.id }) {
                let merged = CloudSyncEngine.merge(transactions[i], remote)
                if merged != transactions[i] { transactions[i] = merged; changed = true }
                if merged != remote { rePush.append(remote.id) }   // our copy was richer — share it back
            } else if let sid = remote.sourceID,
                      let i = transactions.firstIndex(where: { $0.sourceIDs.contains(sid) }) {
                // Same provider id (e.g. same Gmail message) imported separately on each device, so
                // local ids differ. It's ONE transaction — field-merge into our row, keep our id.
                let merged = mergeDuplicate(transactions[i], remote)
                if merged != transactions[i] { transactions[i] = merged; changed = true }
            } else if let j = transactions.firstIndex(where: {
                $0.source != remote.source && Self.crossChannelKey($0) == Self.crossChannelKey(remote)
            }) {
                // Cross-device, cross-channel duplicate (email on iPhone, SMS on Mac). Converge
                // deterministically so BOTH devices pick the same survivor without coordinating.
                let local = transactions[j]
                var merged = CloudSyncEngine.merge(local, remote)
                let survivorID = min(local.id.uuidString, remote.id.uuidString)
                merged.id = survivorID == local.id.uuidString ? local.id : remote.id
                let loserID = merged.id == local.id ? remote.id : local.id
                merged.modifiedAt = Date()
                transactions[j] = merged
                changed = true
                rePush.append(merged.id)
                cloud.recordLocalDeletions([loserID])
            } else {
                transactions.append(remote)
                changed = true
            }
        }
        for id in deletedIDs where transactions.contains(where: { $0.id == id }) {
            transactions.removeAll { $0.id == id }
            changed = true
        }
        guard changed else { return }
        // Once real rows arrive from another device, the local demo data is no longer wanted.
        if transactions.contains(where: { $0.source != "sample" }) {
            transactions.removeAll { $0.source == "sample" }
        }
        transactions.sort { $0.date > $1.date }
        collapseDuplicates()
        save()
        cloud.recordLocalChanges(rePush)
        localSync.refreshSnapshot(transactions)   // keep snapshot current; do NOT re-broadcast
    }

    // MARK: iCloud key-value sync for small settings (tags, family, profile)

    private func loadSettingsFromCloud() {
        let kv = NSUbiquitousKeyValueStore.default
        if let data = kv.data(forKey: Self.partyTagsKey),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data),
           decoded != partyTags {
            partyTags = decoded
            UserDefaults.standard.set(data, forKey: Self.partyTagsKey)
        }
        if let data = kv.data(forKey: Self.familyMembersKey),
           let decoded = try? JSONDecoder().decode([FamilyMember].self, from: data),
           decoded != familyMembers {
            familyMembers = decoded
            UserDefaults.standard.set(data, forKey: Self.familyMembersKey)
            reclassifyFamilyTransfers()
        }
        if let data = kv.data(forKey: Self.userProfileKey),
           let decoded = try? JSONDecoder().decode(UserProfile.self, from: data),
           decoded != userProfile {
            userProfile = decoded
            UserDefaults.standard.set(data, forKey: Self.userProfileKey)
        }
    }

    /// Primary categorization: upgrades freshly-imported expenses with Apple Intelligence
    /// when it's available, overwriting the embedding classifier's guess. A no-op (keeps the
    /// fallback guess) on iOS < 26 or when Apple Intelligence is off. AI's decisions also
    /// train the embedding classifier, so the fallback keeps improving.
    private func refineWithAI(_ ids: [UUID]) async {
        guard !ids.isEmpty, aiClassifier.isAvailable() else { return }
        var changedIDs: [UUID] = []
        for id in ids {
            guard let i = transactions.firstIndex(where: { $0.id == id }), !transactions[i].isIncome,
                  let cat = await aiClassifier.classify(merchant: transactions[i].merchant,
                                                        snippet: transactions[i].rawSnippet ?? "")
            else { continue }
            if transactions[i].category != cat {
                transactions[i].category = cat
                transactions[i].modifiedAt = Date()
                changedIDs.append(id)
            }
            classifier.train(merchant: transactions[i].merchant,
                             text: Self.trainingText(transactions[i]), category: cat)
        }
        if !changedIDs.isEmpty { save(); pushChanges(changedIDs) }
    }

    /// De-duplicates by stable Gmail message-ID. For rows imported before IDs were tracked,
    /// matches on the legacy heuristic key and backfills the ID in place (one-time migration)
    /// rather than creating a duplicate. Manual/sample rows fall back to the heuristic key.
    private func merge(_ fetched: [Transaction]) -> (added: Int, changed: Bool, addedIDs: [UUID]) {
        var knownIDs = Set(transactions.flatMap(\.sourceIDs))
        var knownHeuristic = Set(transactions.map(Self.heuristicKey))
        // Legacy Gmail rows (no sourceID yet) eligible for ID backfill — never sample/manual.
        var legacyIndex: [String: Int] = [:]
        for (i, tx) in transactions.enumerated() where tx.sourceID == nil && tx.source == "gmail" {
            legacyIndex[Self.heuristicKey(tx)] = i
        }
        // Index for cross-channel convergence (email row ↔ SMS row of the same purchase).
        var crossIndex: [String: Int] = [:]
        for (i, tx) in transactions.enumerated() { crossIndex[Self.crossChannelKey(tx)] = i }

        var added = 0
        var changed = false
        var addedIDs: [UUID] = []
        for tx in fetched {
            if let sid = tx.sourceID {
                if knownIDs.contains(sid) { continue }
                if let i = legacyIndex.removeValue(forKey: Self.heuristicKey(tx)) {
                    transactions[i].sourceID = sid       // migrate existing row, don't duplicate
                    knownIDs.insert(sid)
                    changed = true
                    continue
                }
                // Cross-channel: the same purchase already imported via the OTHER channel.
                // Keep the existing (often AI-enriched) row and record this channel's id on it.
                if let j = crossIndex[Self.crossChannelKey(tx)], transactions[j].source != tx.source {
                    if transactions[j].sourceID == nil {
                        transactions[j].sourceID = sid
                    } else if transactions[j].sourceID != sid, transactions[j].altSourceID == nil {
                        transactions[j].altSourceID = sid
                    }
                    transactions[j].modifiedAt = Date()
                    knownIDs.insert(sid)
                    changed = true
                    continue
                }
                var row = categorized(tx)
                row.modifiedAt = Date()
                transactions.append(row)
                knownIDs.insert(sid)
                knownHeuristic.insert(Self.heuristicKey(tx))
                crossIndex[Self.crossChannelKey(tx)] = transactions.count - 1
                addedIDs.append(row.id)
                added += 1; changed = true
            } else {
                let key = Self.heuristicKey(tx)
                if knownHeuristic.contains(key) { continue }
                var row = categorized(tx)
                row.modifiedAt = Date()
                transactions.append(row)
                knownHeuristic.insert(key)
                addedIDs.append(row.id)
                added += 1; changed = true
            }
        }
        return (added, changed, addedIDs)
    }

    /// Content identity for collapsing the SAME transaction that arrived more than once — most
    /// often the same purchase delivered as multiple bank SMS (a debit alert + a balance/confirm
    /// SMS), but also an email + SMS of one purchase. Conservative and transfer-safe: same day,
    /// exact amount, normalized merchant, recipient account (so different payees stay separate),
    /// and direction (so a debit never merges with a credit of the same amount).
    private static func dedupKey(_ tx: Transaction) -> String {
        // A shared bank reference number is authoritative: identical across email+SMS for one
        // payment, distinct for separate payments. Direction is kept so a debit and a credit
        // that happen to share a ref (the two legs of a self-transfer) don't merge.
        if let ref = tx.referenceID, !ref.isEmpty { return "ref:\(ref)|\(tx.isIncome)" }
        let day = Int(Calendar.current.startOfDay(for: tx.date).timeIntervalSinceReferenceDate / 86400)
        let merchant = tx.merchant.lowercased().filter { $0.isLetter || $0.isNumber }
        return "\(day)|\(tx.amount)|\(merchant)|\(tx.recipientAccountLast4 ?? "")|\(tx.isIncome)"
    }

    /// Populates `referenceID` on existing rows by re-extracting it from their stored snippet —
    /// catches rows imported before reference tracking (SMS snippets carry the ref; older Gmail
    /// snippets were truncated before it, so those gain a ref only on the next Gmail re-sync).
    func backfillReferenceIDs() {
        var changed = false
        for i in transactions.indices where (transactions[i].referenceID ?? "").isEmpty {
            if let ref = TransactionParser.referenceNumber(in: transactions[i].rawSnippet ?? "") {
                transactions[i].referenceID = ref
                changed = true
            }
        }
        if changed { save() }
    }

    #if DEBUG
    /// Loads the screenshot/marketing demo dataset (see `SampleData.demoTransactions`). Sets a
    /// matching family + named-account rule so every screen and badge is populated. Never runs in
    /// production — gated by the DEMO_DATA launch env var and compiled out of Release builds.
    func seedDemoData() {
        familyMembers = SampleData.familyMembers
        userProfile = UserProfile(name: "Alex Kumar", aliases: "", accounts: "5832")
        RulesStore.shared.setPayeeRule(accountLast4: "1234", payee: "Green Acres Maintenance",
                                       category: .utilities)
        transactions = SampleData.demoTransactions.sorted { $0.date > $1.date }
    }
    #endif

    /// Recovers a time-of-day for SMS rows still sitting at midnight, by re-reading the transaction
    /// time the bank stated in the stored message body. Rows whose body has no time stay as-is.
    func backfillSMSTimestamps() {
        let cal = Calendar.current
        func hasTime(_ d: Date) -> Bool {
            let c = cal.dateComponents([.hour, .minute, .second], from: d)
            return (c.hour ?? 0) != 0 || (c.minute ?? 0) != 0 || (c.second ?? 0) != 0
        }
        var changed = false
        for i in transactions.indices
        where transactions[i].source == "sms" && !hasTime(transactions[i].date) {
            guard let snippet = transactions[i].rawSnippet,
                  let bodyDate = TransactionParser.bodyDate(in: snippet),
                  hasTime(bodyDate),
                  cal.isDate(bodyDate, inSameDayAs: transactions[i].date) else { continue }
            transactions[i].date = bodyDate
            changed = true
        }
        #if os(macOS)
        // Some bank SMS state only a date (interest credits, NEFT). Recover a time-of-day from the
        // message's own receipt timestamp in chat.db, matched by GUID.
        if canReadSMS() {
            let stillMidnight = transactions.indices.filter {
                transactions[$0].source == "sms" && !hasTime(transactions[$0].date)
            }
            let guids = Set(stillMidnight.compactMap { idx -> String? in
                transactions[idx].sourceIDs.first { $0.hasPrefix("sms:") }?.replacingOccurrences(of: "sms:", with: "")
            })
            let receipts = smsSource.receiptDates(forGUIDs: guids)
            for idx in stillMidnight {
                guard let sid = transactions[idx].sourceIDs.first(where: { $0.hasPrefix("sms:") }),
                      let receipt = receipts[String(sid.dropFirst(4))],
                      hasTime(receipt) else { continue }
                // Keep the body-stated transaction day; attach the SMS receipt's time-of-day.
                let t = cal.dateComponents([.hour, .minute, .second], from: receipt)
                if let grafted = cal.date(bySettingHour: t.hour ?? 0, minute: t.minute ?? 0,
                                          second: t.second ?? 0, of: transactions[idx].date) {
                    transactions[idx].date = grafted
                    changed = true
                }
            }
        }
        #endif
        if changed { save() }
    }

    /// Re-parses captured (SMS/Gmail) rows with the current parser to recover transfer recipients
    /// the older parser missed (masked "Info:" account, NEFT/SI payee name), upgrade rows wrongly
    /// left as a non-transfer category, and reset family verdicts on every transfer so the next
    /// detection pass re-tags them from scratch. Manual rows and income are left untouched.
    func refreshTransferRecipients() {
        for i in transactions.indices {
            let t = transactions[i]
            guard (t.source == "sms" || t.source == "gmail"), !t.isIncome,
                  let snippet = t.rawSnippet, !snippet.isEmpty,
                  let reparsed = TransactionParser.parse(text: snippet, from: t.bank,
                                                         fallbackDate: t.date, source: t.source)
            else { continue }
            let wasTransfer = t.category == .transfer
            guard reparsed.category == .transfer || wasTransfer else { continue }
            // Adopt the re-parsed category — this also lets a payee rule reclassify an account-only
            // transfer (e.g. maintenance to …1234) from Transfers to Bills & Utilities.
            transactions[i].category = reparsed.category
            if transactions[i].recipientAccountLast4 == nil {
                transactions[i].recipientAccountLast4 = reparsed.recipientAccountLast4
            }
            // Replace a generic merchant ("Unknown" / "NEFT transfer") with the recovered payee.
            if reparsed.merchant != "Unknown",
               (transactions[i].merchant == "Unknown" || transactions[i].merchant.lowercased().hasSuffix("transfer")) {
                transactions[i].merchant = reparsed.merchant
            }
            // Clear stale family verdicts: re-evaluate on the next detection pass if still a
            // transfer; otherwise it's a named bill, not family.
            if transactions[i].category == .transfer {
                transactions[i].toFamily = nil
                transactions[i].familyMember = nil
            } else {
                transactions[i].toFamily = false
                transactions[i].familyMember = nil
            }
            transactions[i].isSelfTransfer = nil
            transactions[i].modifiedAt = Date()
        }
    }

    /// Applies a user's payee rule (recipient account → name + category) across existing history:
    /// every transfer to that account is relabelled with the payee name and category, backfilling
    /// the recipient-account field on older rows that never captured it. Lets a rule added in
    /// Settings take effect retroactively, not just on future syncs.
    @discardableResult
    func applyPayeeRule(accountLast4: String) -> Int {
        guard let rule = RulesStore.shared.payeeRule(forAccountLast4: accountLast4) else { return 0 }
        var changedIDs: [UUID] = []
        for i in transactions.indices {
            let t = transactions[i]
            guard !t.isIncome else { continue }
            let last4 = t.recipientAccountLast4
                ?? t.rawSnippet.flatMap { TransactionParser.recipientAccountLast4(in: $0) }
            guard last4 == rule.accountLast4 else { continue }
            transactions[i].recipientAccountLast4 = last4
            transactions[i].merchant = rule.payee
            transactions[i].category = rule.category
            transactions[i].toFamily = false       // a named bill, not a family transfer
            transactions[i].familyMember = nil
            transactions[i].modifiedAt = Date()
            changedIDs.append(t.id)
        }
        if !changedIDs.isEmpty { save(); pushChanges(changedIDs) }
        return changedIDs.count
    }

    /// Field-merges a duplicate into the survivor, preserving enrichment and recording the other
    /// occurrence's provider id. Keeps the survivor's own `id`.
    private func mergeDuplicate(_ keep: Transaction, _ dup: Transaction) -> Transaction {
        var m = keep
        if m.category == .other && dup.category != .other { m.category = dup.category }
        if m.merchant == "Unknown" && dup.merchant != "Unknown" { m.merchant = dup.merchant }
        // Keep the more precise timestamp: if the survivor is date-only (e.g. an email row) but the
        // duplicate carries a time-of-day (e.g. the SMS), adopt the SMS time for the same day.
        let cal = Calendar.current
        func hasTime(_ d: Date) -> Bool {
            let c = cal.dateComponents([.hour, .minute, .second], from: d)
            return (c.hour ?? 0) != 0 || (c.minute ?? 0) != 0 || (c.second ?? 0) != 0
        }
        if !hasTime(m.date) && hasTime(dup.date) && cal.isDate(m.date, inSameDayAs: dup.date) {
            m.date = dup.date
        }
        m.toFamily = m.toFamily ?? dup.toFamily
        m.familyMember = m.familyMember ?? dup.familyMember
        m.isSelfTransfer = m.isSelfTransfer ?? dup.isSelfTransfer
        m.recipientAccountLast4 = m.recipientAccountLast4 ?? dup.recipientAccountLast4
        m.referenceID = m.referenceID ?? dup.referenceID
        let ids = [keep.sourceID, keep.altSourceID, dup.sourceID, dup.altSourceID].compactMap { $0 }
        m.sourceID = ids.first
        m.altSourceID = ids.dropFirst().first { $0 != m.sourceID }
        return m
    }

    /// A merchant with no real payee — a rail label ("UPI transfer"), an account number, or
    /// "Unknown". One side of a cross-channel pair is usually generic, which is the signal that
    /// two same-amount rows from different channels are the SAME payment, not distinct purchases.
    private static func isGenericMerchant(_ merchant: String) -> Bool {
        let m = merchant.lowercased().trimmingCharacters(in: .whitespaces)
        if m.isEmpty || m == "unknown" { return true }
        if m.hasSuffix("transfer") || m.hasPrefix("a/c") || m.contains("· a/c") || m.contains("a/c x") { return true }
        return m.filter(\.isLetter).count < 3   // mostly digits/masking → an account number
    }

    /// Cross-CHANNEL grouping key: same day, amount, bank, direction (merchant deliberately
    /// excluded, since email and SMS label the same transfer differently).
    private static func crossBankKey(_ tx: Transaction) -> String {
        let day = Int(Calendar.current.startOfDay(for: tx.date).timeIntervalSinceReferenceDate / 86400)
        return "\(day)|\(tx.amount)|\(tx.bank.lowercased())|\(tx.isIncome)"
    }

    /// Collapses duplicate rows in two deterministic passes — first exact (reference number /
    /// same merchant), then cross-channel transfers (same email reported by email and SMS with
    /// different payee text). Survivor selection is deterministic so synced devices converge.
    @discardableResult
    func collapseDuplicates() -> Int {
        let before = transactions.count

        // Generic group-collapse: merge each eligible group into one survivor.
        func collapse(_ rows: [Transaction],
                      key: (Transaction) -> String,
                      eligible: ([Transaction]) -> Bool,
                      survivorFirst: (Transaction, Transaction) -> Bool) -> [Transaction] {
            var out: [Transaction] = []
            for (_, group) in Dictionary(grouping: rows, by: key) {
                guard group.count > 1, eligible(group) else { out.append(contentsOf: group); continue }
                let ordered = group.sorted(by: survivorFirst)
                var survivor = ordered[0]
                for dup in ordered.dropFirst() { survivor = mergeDuplicate(survivor, dup) }
                out.append(survivor)
            }
            return out
        }

        // Pass 1 — exact duplicates. Survivor = smallest id (deterministic across devices).
        var rows = collapse(transactions, key: Self.dedupKey, eligible: { _ in true },
                            survivorFirst: { $0.id.uuidString < $1.id.uuidString })

        // Pass 2 — cross-channel transfer duplicates. Merge a same day/amount/bank group ONLY when
        // it spans more than one channel, at least one side is a generic rail label (so two
        // distinct clean-merchant purchases are never merged), and there is at most one bank
        // reference number in the group (more than one ref = genuinely separate payments).
        rows = collapse(rows, key: Self.crossBankKey,
                        eligible: { group in
                            let distinctRealMerchants = Set(group
                                .filter { !Self.isGenericMerchant($0.merchant) }
                                .map { $0.merchant.lowercased() })
                            return Set(group.map(\.source)).count > 1
                                && group.contains(where: { Self.isGenericMerchant($0.merchant) })
                                && distinctRealMerchants.count <= 1   // never merge two distinct named merchants
                                && Set(group.compactMap { ($0.referenceID?.isEmpty == false) ? $0.referenceID : nil }).count <= 1
                        },
                        survivorFirst: { a, b in
                            let ag = Self.isGenericMerchant(a.merchant), bg = Self.isGenericMerchant(b.merchant)
                            return ag == bg ? a.id.uuidString < b.id.uuidString : !ag   // keep the real merchant name
                        })

        guard rows.count != before else { return 0 }
        rows.sort { $0.date > $1.date }
        transactions = rows
        save()
        return before - rows.count
    }

    /// Candidate key for AI duplicate detection: rows that share a day, exact amount, and
    /// direction are the only ones worth asking the model about (a cheap, deterministic pre-filter
    /// over the whole ledger). Merchant/bank are deliberately excluded — that's exactly what the
    /// model resolves.
    private static func dupeCandidateKey(_ tx: Transaction) -> String {
        let day = Int(Calendar.current.startOfDay(for: tx.date).timeIntervalSinceReferenceDate / 86400)
        return "\(day)|\(tx.amount)|\(tx.isIncome)"
    }

    /// Uses Apple Intelligence to collapse same-payment duplicates that the deterministic pass
    /// can't (cross-channel transfers with different payee text). Only rows sharing day+amount+
    /// direction are compared, pairwise, and clustered with union-find; each confirmed cluster
    /// collapses to one field-merged survivor. A no-op when Apple Intelligence is unavailable.
    /// Safe to run after a sync; only re-examines groups that still have >1 row.
    func collapseDuplicatesWithAI() async {
        guard dupeDetector.isAvailable() else {
            dedupStatus = "Apple Intelligence isn't available on this device (needs macOS 26 / iOS 26 with Apple Intelligence enabled)."
            return
        }
        let groups = Dictionary(grouping: transactions, by: Self.dupeCandidateKey).filter { $0.value.count > 1 }
        guard !groups.isEmpty else { dedupStatus = "No possible duplicates to check."; return }

        dedupStatus = "Checking \(groups.values.reduce(0) { $0 + $1.count }) possible duplicates with Apple Intelligence…"
        var removed: Set<UUID> = []
        var merged: [UUID: Transaction] = [:]

        for (_, rows) in groups {
            // Union-find over the rows in this candidate group.
            var parent = Array(0..<rows.count)
            func find(_ x: Int) -> Int { var x = x; while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }; return x }
            for i in 0..<rows.count {
                for j in (i + 1)..<rows.count where find(i) != find(j) {
                    if await dupeDetector.isSamePayment(rows[i], rows[j]) == true { parent[find(i)] = find(j) }
                }
            }
            var clusters: [Int: [Int]] = [:]
            for k in 0..<rows.count { clusters[find(k), default: []].append(k) }
            for (_, members) in clusters where members.count > 1 {
                let group = members.map { rows[$0] }.sorted { $0.id.uuidString < $1.id.uuidString }
                var survivor = group[0]
                for dup in group.dropFirst() { survivor = mergeDuplicate(survivor, dup); removed.insert(dup.id) }
                merged[survivor.id] = survivor
            }
        }

        guard !removed.isEmpty else { dedupStatus = "No duplicates found by Apple Intelligence."; return }
        transactions = transactions.compactMap { tx in
            if removed.contains(tx.id) { return nil }
            return merged[tx.id] ?? tx
        }
        save()
        dedupStatus = "Apple Intelligence merged \(removed.count) duplicate\(removed.count == 1 ? "" : "s")."
        NSLog("SPENDWISE_AI: duplicate detector merged \(removed.count) rows")
    }

    /// Cheap pre-filter: a row is worth an AI "is this real?" check only if its text hints at a
    /// notice (a reminder/scheduled/failed/request message). Terse completed-debit alerts are
    /// skipped, keeping the number of model calls small.
    private static func looksLikePossibleNotice(_ tx: Transaction) -> Bool {
        let s = (tx.rawSnippet ?? "").lowercased()
        let hints = ["mandate", "autopay", "auto pay", "auto-pay", "due", "scheduled", "will be",
                     "bill", "emi", "sip", "request", "declined", "insufficient", "reminder",
                     "ensure", "upcoming", "standing instruction"]
        return hints.contains { s.contains($0) }
    }

    /// Uses Apple Intelligence to remove rows that aren't actual transactions — bill reminders,
    /// scheduled/upcoming auto-debits, payment requests, declined/failed attempts — that the
    /// keyword parser logged as spends. Only checks rows flagged by the cheap pre-filter, and only
    /// removes a row when the model is confident it's a notice (uncertainty keeps the row).
    func removeNonTransactionsWithAI() async {
        guard spendingValidator.isAvailable() else {
            validationStatus = "Apple Intelligence isn't available on this device (needs macOS 26 / iOS 26 with Apple Intelligence enabled)."
            return
        }
        let candidates = transactions.filter(Self.looksLikePossibleNotice)
        guard !candidates.isEmpty else { validationStatus = "No suspicious notifications to check."; return }
        validationStatus = "Checking \(candidates.count) messages with Apple Intelligence…"
        var remove: Set<UUID> = []
        for tx in candidates {
            if await spendingValidator.isCompletedTransaction(text: tx.rawSnippet ?? "") == false {
                remove.insert(tx.id)
            }
        }
        guard !remove.isEmpty else { validationStatus = "No non-transactions found."; return }
        let ids = Array(remove)
        transactions.removeAll { remove.contains($0.id) }
        save()
        cloud.recordLocalDeletions(ids)
        localSync.updateLedger(transactions)
        validationStatus = "Removed \(remove.count) notification\(remove.count == 1 ? "" : "s") that weren't real transactions."
        NSLog("SPENDWISE_AI: removed \(remove.count) non-transactions")
    }

    /// Fallback identity for rows without a stable provider ID (manual entries, pre-migration).
    private static func heuristicKey(_ tx: Transaction) -> String {
        let day = Calendar.current.startOfDay(for: tx.date).timeIntervalSince1970
        return "\(day)|\(tx.amount)|\(tx.merchant.lowercased())|\(tx.account ?? "")"
    }

    /// Cross-CHANNEL identity: matches the SAME logical transaction arriving via different
    /// channels (email on iPhone vs SMS on Mac), which carry different ids and different
    /// `sourceID`s. Conservative by design — exact amount + same day + normalized merchant
    /// (account is dropped: email has one, SMS doesn't). Used only to converge rows whose
    /// `source` differs, so two genuinely distinct same-channel spends never collapse.
    private static func crossChannelKey(_ tx: Transaction) -> String {
        let day = Calendar.current.startOfDay(for: tx.date).timeIntervalSince1970
        let merchant = tx.merchant.lowercased().filter { $0.isLetter || $0.isNumber }
        return "\(day)|\(tx.amount)|\(merchant)"
    }

    // MARK: Party tags

    private static func partyKey(_ merchant: String) -> String {
        merchant.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Tags assigned to a merchant ("party").
    func tags(forMerchant merchant: String) -> [String] {
        partyTags[Self.partyKey(merchant)] ?? []
    }

    func addTag(_ raw: String, toMerchant merchant: String) {
        let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return }
        let key = Self.partyKey(merchant)
        var tags = partyTags[key] ?? []
        guard !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else { return }
        tags.append(tag)
        partyTags[key] = tags
        saveTags()
    }

    func removeTag(_ tag: String, fromMerchant merchant: String) {
        let key = Self.partyKey(merchant)
        partyTags[key]?.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
        if partyTags[key]?.isEmpty == true { partyTags[key] = nil }
        saveTags()
    }

    /// Every distinct tag in use, alphabetised.
    var allTags: [String] {
        Set(partyTags.values.flatMap { $0 })
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func saveTags() {
        if let data = try? JSONEncoder().encode(partyTags) {
            UserDefaults.standard.set(data, forKey: Self.partyTagsKey)
            NSUbiquitousKeyValueStore.default.set(data, forKey: Self.partyTagsKey)
        }
    }

    // MARK: Family transfers (Apple Intelligence)

    /// Adds or updates a family member (matched by id), persists, and re-runs detection.
    func upsertFamilyMember(_ member: FamilyMember) {
        guard !member.name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if let i = familyMembers.firstIndex(where: { $0.id == member.id }) {
            familyMembers[i] = member
        } else {
            familyMembers.append(member)
        }
        saveFamilyMembers()
        reclassifyFamilyTransfers()
    }

    func removeFamilyMember(_ member: FamilyMember) {
        familyMembers.removeAll { $0.id == member.id }
        saveFamilyMembers()
        reclassifyFamilyTransfers()
    }

    func updateUserProfile(_ profile: UserProfile) {
        userProfile = profile
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: Self.userProfileKey)
            NSUbiquitousKeyValueStore.default.set(data, forKey: Self.userProfileKey)
        }
        reclassifyFamilyTransfers()   // your own identity affects what counts as a family transfer
    }

    /// Clears prior family-transfer verdicts so the (changed) family/profile is re-applied.
    private func reclassifyFamilyTransfers() {
        for i in transactions.indices where transactions[i].isTransfer {
            transactions[i].toFamily = nil
            transactions[i].familyMember = nil
            transactions[i].isSelfTransfer = nil
        }
        Task { await detectFamilyTransfers() }
    }

    private func saveFamilyMembers() {
        if let data = try? JSONEncoder().encode(familyMembers) {
            UserDefaults.standard.set(data, forKey: Self.familyMembersKey)
            NSUbiquitousKeyValueStore.default.set(data, forKey: Self.familyMembersKey)
        }
    }

    /// Flags moves between the user's OWN accounts as self-transfers, so both legs (the debit out
    /// and the credit in) net to zero — counted as neither income nor spending. Detected
    /// deterministically: the counterparty is the user themselves (their own name or a UPI-handle
    /// alias appears in the message), or the destination is one of the user's own accounts.
    /// Requires the user's profile (name / handles / account last-4) to be set.
    @discardableResult
    func detectSelfTransfers() -> Int {
        guard !userProfile.isEmpty else { return 0 }
        let ownAccounts = userProfile.accountLast4Set
        let nameNorm = userProfile.name.lowercased().filter { $0.isLetter }
        let aliases = userProfile.aliases.lowercased()
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 5 }
        var count = 0
        for i in transactions.indices where transactions[i].isSelfTransfer != true {
            let tx = transactions[i]
            let merchantNorm = tx.merchant.lowercased().filter { $0.isLetter }
            let hay = (tx.merchant + " " + (tx.rawSnippet ?? "")).lowercased()
            let ownName = nameNorm.count >= 4 && merchantNorm.contains(nameNorm)   // full-name match (avoids common first names)
            let ownAlias = aliases.contains { hay.contains($0) }
            let ownAccount = tx.recipientAccountLast4.map { ownAccounts.contains($0) } ?? false
            if ownName || ownAlias || ownAccount {
                transactions[i].isSelfTransfer = true
                count += 1
            }
        }
        if count > 0 { save() }
        return count
    }

    /// Flags transfers going to family members. Runs only on transfers not yet checked
    /// (`toFamily == nil`); a no-op when no family is set. Two passes: a deterministic
    /// account-last-4 match (exact, and works without Apple Intelligence), then an AI
    /// name/nickname match for anything the first pass didn't cover. Cheap and idempotent —
    /// safe to call on launch and after each sync.
    func detectFamilyTransfers() async {
        detectSelfTransfers()   // net out own-account moves first (runs on launch + every sync)
        // Run if there's anyone to match against: family members, or the user's own accounts.
        guard !isDetectingFamily,
              !(familyMembers.isEmpty && userProfile.accountLast4Set.isEmpty) else { return }
        isDetectingFamily = true
        defer { isDetectingFamily = false }
        let pending = transactions.enumerated().filter { $0.element.isTransfer && !$0.element.isIncome && $0.element.toFamily == nil }
        guard !pending.isEmpty else { return }
        var changedIDs: [UUID] = []
        let ownAccounts = userProfile.accountLast4Set

        // Pass 0 — own accounts: a transfer landing on one of the user's *own* accounts is a
        // move between their accounts, not family. Tagged (still counts as spend), and never
        // handed to the family passes. Deterministic; no AI required.
        var stillPending: [Transaction] = []
        for (_, tx) in pending {
            if let last4 = tx.recipientAccountLast4, ownAccounts.contains(last4) {
                if let i = transactions.firstIndex(where: { $0.id == tx.id }) {
                    transactions[i].isSelfTransfer = true
                    transactions[i].toFamily = false   // own account is not family
                    transactions[i].modifiedAt = Date()
                    changedIDs.append(tx.id)
                }
            } else {
                stillPending.append(tx)
            }
        }

        // Pass 1 — deterministic: match the recipient account's last 4 digits against a
        // family member's saved account number. Exact and reliable; no AI required.
        var afterFamilyAccount: [Transaction] = []
        for tx in stillPending {
            if let last4 = tx.recipientAccountLast4,
               let member = familyMembers.first(where: { $0.accountLast4Digits == last4 }) {
                if let i = transactions.firstIndex(where: { $0.id == tx.id }) {
                    transactions[i].toFamily = true
                    transactions[i].familyMember = member.name
                    transactions[i].modifiedAt = Date()
                    changedIDs.append(tx.id)
                }
            } else {
                afterFamilyAccount.append(tx)
            }
        }
        stillPending = afterFamilyAccount

        // Pass 1.5 — deterministic name match (no Apple Intelligence required). A transfer whose
        // message literally contains exactly ONE family member's name/alias token is tagged to that
        // member. Safe because it matches the user's *configured* names as literal substrings (not a
        // model guess), and the exactly-one rule avoids ambiguity. This is what makes recurring SIs
        // (e.g. "NEFT Dr-…-ALEX KUMAR-…", "SI -Alex") tag correctly on Macs without on-device AI.
        var afterName: [Transaction] = []
        for tx in stillPending {
            let haystack = (tx.merchant + " " + (tx.rawSnippet ?? "")).lowercased()
            let matched = familyMembers.filter { member in
                Self.nameTokens(member.name + " " + member.aliases).contains { haystack.contains($0) }
            }
            if matched.count == 1, let i = transactions.firstIndex(where: { $0.id == tx.id }) {
                transactions[i].toFamily = true
                transactions[i].familyMember = matched[0].name
                transactions[i].modifiedAt = Date()
                changedIDs.append(tx.id)
            } else {
                afterName.append(tx)
            }
        }
        stillPending = afterName

        // Pass 2 — Apple Intelligence: confirm a name match, but ONLY for transfers whose message
        // actually mentions a family member's name/alias. This deterministic pre-filter is what
        // prevents wrong tags: a transfer that doesn't name anyone in the family is never sent to
        // the model (so it can't hallucinate a match), and it keeps AI calls to a minimum.
        if familyDetector.isAvailable() {
            let familyTokens = familyMembers.flatMap { Self.nameTokens($0.name + " " + $0.aliases) }
            for tx in stillPending {
                let haystack = (tx.merchant + " " + (tx.rawSnippet ?? "")).lowercased()
                guard familyTokens.contains(where: { haystack.contains($0) }) else { continue }
                guard let match = await familyDetector.match(recipient: tx.merchant,
                                                             note: tx.rawSnippet ?? "",
                                                             family: familyMembers,
                                                             userProfile: userProfile) else { continue }
                guard let i = transactions.firstIndex(where: { $0.id == tx.id }) else { continue }
                transactions[i].toFamily = match.isFamily
                transactions[i].familyMember = match.isFamily ? match.member : nil
                transactions[i].modifiedAt = Date()
                changedIDs.append(tx.id)
            }
        }
        if !changedIDs.isEmpty { save(); pushChanges(changedIDs) }
    }

    /// Significant lowercased name tokens (≥3 chars) from a name/alias string — used to check
    /// whether a family member is actually named in a transfer message before tagging it.
    /// Drops the domain of any UPI handle (the part after "@") so a generic bank suffix like
    /// "oksbi"/"okhdfcbank"/"ybl" — shared by *every* handle on that PSP — is never a match token;
    /// only the distinctive local part (e.g. "alex.kumar") is kept.
    private static func nameTokens(_ s: String) -> [String] {
        let withoutHandleDomain = s.lowercased()
            .replacingOccurrences(of: #"@[a-z0-9.\-]+"#, with: " ", options: .regularExpression)
        return withoutHandleDomain.split { !$0.isLetter && !$0.isNumber }
            .map(String.init).filter { $0.count >= 3 }
    }

    /// Transfers to family in the given month (respects the member filter), newest first.
    func familyTransfers(inMonthOf date: Date = Date()) -> [Transaction] {
        let cal = Calendar.current
        return visibleTransactions
            .filter { $0.toFamily == true && cal.isDate($0.date, equalTo: date, toGranularity: .month) }
            .sorted { $0.date > $1.date }
    }

    // MARK: Tag / party drill-down (respect the member filter)

    func transactions(forMerchant merchant: String) -> [Transaction] {
        let key = Self.partyKey(merchant)
        return visibleTransactions.filter { Self.partyKey($0.merchant) == key }
    }

    func transactions(taggedWith tag: String) -> [Transaction] {
        visibleTransactions.filter { tx in
            tags(forMerchant: tx.merchant).contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
        }
    }

    /// Spend per month for the last `count` months ending at `date` (inclusive), oldest first.
    /// Months with no spend are included as 0 so the trend line stays continuous.
    func monthlyTotals(lastMonths count: Int, endingAt date: Date = Date()) -> [(month: Date, total: Double)] {
        let cal = Calendar.current
        guard let end = cal.date(from: cal.dateComponents([.year, .month], from: date)) else { return [] }
        var buckets: [Date: Double] = [:]
        for i in 0..<max(count, 1) {
            if let m = cal.date(byAdding: .month, value: -i, to: end) { buckets[m] = 0 }
        }
        for tx in visibleTransactions where tx.isConsumption {
            guard let m = cal.date(from: cal.dateComponents([.year, .month], from: tx.date)),
                  buckets[m] != nil else { continue }
            buckets[m, default: 0] += tx.amount
        }
        return buckets.map { (month: $0.key, total: $0.value) }.sorted { $0.month < $1.month }
    }

    /// Spend bucketed by calendar month (ascending) — feeds the over-time drill-down chart.
    func monthlySpend(of txs: [Transaction]) -> [(month: Date, total: Double)] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: txs) {
            cal.date(from: cal.dateComponents([.year, .month], from: $0.date)) ?? $0.date
        }
        return groups.map { (month: $0.key, total: $0.value.reduce(0) { $0 + $1.amount }) }
            .sorted { $0.month < $1.month }
    }

    // MARK: Family members

    /// Distinct accounts present in the data (emails), sorted.
    var memberEmails: [String] {
        Array(Set(transactions.compactMap(\.account))).sorted()
    }

    /// Display name for an account email: connected-account label, else mailbox prefix.
    func memberLabel(for email: String?) -> String {
        guard let email, !email.isEmpty else { return "Manual" }
        if let label = gmail.label(forEmail: email) { return label }
        return email.split(separator: "@").first.map { String($0).capitalized } ?? email
    }

    /// Transactions visible under the current member filter.
    var visibleTransactions: [Transaction] {
        guard let memberFilter else { return transactions }
        return transactions.filter { $0.account == memberFilter }
    }

    /// Visible spends only (income excluded) — the basis for all spend analytics.
    /// The basis for all spending analytics: actual CONSUMPTION only — income, transfers, and
    /// investments (money moved, not consumed) are excluded. See `Transaction.isConsumption`.
    var visibleExpenses: [Transaction] { visibleTransactions.filter(\.isConsumption) }

    /// The transactions behind one statement line (an income source, or a spending category) in a
    /// period — for drilling into the Balance Sheet. Newest first.
    func transactions(forStatementLine name: String, isIncome: Bool, in interval: DateInterval?) -> [Transaction] {
        let inScope: (Transaction) -> Bool = { tx in interval.map { $0.contains(tx.date) } ?? true }
        if isIncome {
            return visibleTransactions
                .filter { $0.isIncome && !$0.isSelf && inScope($0)
                    && ($0.merchant.lowercased().contains("salary") ? "Salary" : "Other income") == name }
                .sorted { $0.date > $1.date }
        }
        return visibleExpenses.filter { inScope($0) && $0.category.rawValue == name }
            .sorted { $0.date > $1.date }
    }

    /// A simple income & expenditure statement (receipts and payments) for a period — the format
    /// accountants recognise: income sources, expenditure by category, and the net surplus or
    /// deficit. Pass `nil` for all-time. Respects the member filter; self-transfers are excluded.
    func financialStatement(in interval: DateInterval?) -> FinancialStatement {
        let inScope: (Transaction) -> Bool = { tx in interval.map { $0.contains(tx.date) } ?? true }
        let incomeTx = visibleTransactions.filter { $0.isIncome && !$0.isSelf && inScope($0) }
        let expenseTx = visibleExpenses.filter(inScope)

        let incomeLines = Dictionary(grouping: incomeTx) {
            $0.merchant.lowercased().contains("salary") ? "Salary" : "Other income"
        }
        .map { StatementLine(name: $0.key, amount: $0.value.reduce(0) { $0 + $1.amount },
                             icon: $0.key == "Salary" ? "briefcase.fill" : "arrow.down.circle.fill") }
        .sorted { $0.amount > $1.amount }

        let expByCat = Dictionary(grouping: expenseTx, by: \.category)
            .map { StatementLine(name: $0.key.rawValue, amount: $0.value.reduce(0) { $0 + $1.amount },
                                 icon: $0.key.icon) }
            .sorted { $0.amount > $1.amount }

        let period: ClosedRange<Date>?
        if let interval { period = interval.start...interval.end }
        else { let d = visibleTransactions.map(\.date); period = d.min().flatMap { lo in d.max().map { lo...$0 } } }

        return FinancialStatement(period: period,
                                  income: incomeTx.reduce(0) { $0 + $1.amount }, incomeLines: incomeLines,
                                  expenditure: expenseTx.reduce(0) { $0 + $1.amount }, expenditureLines: expByCat)
    }

    /// Investments — money put into brokerages/funds (savings, not spending). Shown on its own
    /// card. Returns the selected month's total, the all-time total (investments accumulate), and
    /// a breakdown by destination (brokerage/fund), largest first.
    func investments(inMonthOf date: Date)
        -> (month: Double, allTime: Double, parties: [(name: String, amount: Double, count: Int)]) {
        let cal = Calendar.current
        let all = visibleTransactions.filter { $0.category == .investment && !$0.isSelf }
        let monthTx = all.filter { cal.isDate($0.date, equalTo: date, toGranularity: .month) }
        let parties = Dictionary(grouping: monthTx, by: \.merchant)
            .map { (name: $0.key, amount: $0.value.reduce(0) { $0 + $1.amount }, count: $0.value.count) }
            .sorted { $0.amount > $1.amount }
        return (monthTx.reduce(0) { $0 + $1.amount }, all.reduce(0) { $0 + $1.amount }, parties)
    }


    /// Per-member SPEND totals for a month (ignores the filter — used for the family breakdown card).
    func memberTotals(inMonthOf date: Date) -> [(email: String, label: String, total: Double)] {
        let cal = Calendar.current
        let monthTxs = transactions.filter { !$0.isIncome && cal.isDate($0.date, equalTo: date, toGranularity: .month) }
        let groups = Dictionary(grouping: monthTxs) { $0.account ?? "" }
        return groups.map { (email: $0.key, label: memberLabel(for: $0.key), total: $0.value.reduce(0) { $0 + $1.amount }) }
            .sorted { $0.total > $1.total }
    }

    // MARK: Analytics (respect the member filter)

    /// Spends in a month (income excluded) — feeds totals, donut, daily/category breakdowns.
    func transactions(inMonthOf date: Date) -> [Transaction] {
        let cal = Calendar.current
        return visibleExpenses.filter { cal.isDate($0.date, equalTo: date, toGranularity: .month) }
    }

    func total(inMonthOf date: Date) -> Double {
        transactions(inMonthOf: date).reduce(0) { $0 + $1.amount }
    }

    /// ML forecast: run-rate projection of total spend for the in-progress month, or nil if
    /// `date` isn't the current month or it's too early/late to project. Respects the filter.
    func projectedMonthEnd(for date: Date) -> Double? {
        let cal = Calendar.current
        let today = Date()
        guard cal.isDate(date, equalTo: today, toGranularity: .month),
              let range = cal.range(of: .day, in: .month, for: today) else { return nil }
        let spent = total(inMonthOf: date)
        let dayOfMonth = Double(cal.component(.day, from: today))
        let daysInMonth = Double(range.count)
        guard spent > 0, dayOfMonth >= 3, dayOfMonth < daysInMonth - 1 else { return nil }
        return spent / dayOfMonth * daysInMonth
    }

    /// Total income credited in a month (respects the member filter).
    func income(inMonthOf date: Date) -> Double {
        let cal = Calendar.current
        return visibleTransactions
            .filter { $0.isIncome && !$0.isSelf && cal.isDate($0.date, equalTo: date, toGranularity: .month) }
            .reduce(0) { $0 + $1.amount }
    }

    func categorySummaries(inMonthOf date: Date) -> [CategorySummary] {
        let txs = transactions(inMonthOf: date)
        let total = txs.reduce(0) { $0 + $1.amount }
        guard total > 0 else { return [] }
        let groups = Dictionary(grouping: txs, by: \.category)
        return groups.map { cat, items in
            let sum = items.reduce(0) { $0 + $1.amount }
            return CategorySummary(category: cat, total: sum, count: items.count,
                                   percentOfSpend: sum / total * 100)
        }
        .sorted { $0.total > $1.total }
    }

    /// Daily totals for the current month — feeds the trend chart.
    func dailyTotals(inMonthOf date: Date) -> [(day: Date, total: Double)] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: transactions(inMonthOf: date)) {
            cal.startOfDay(for: $0.date)
        }
        return groups.map { ($0.key, $0.value.reduce(0) { $0 + $1.amount }) }
            .sorted { $0.0 < $1.0 }
    }
}

// MARK: - Sample data (shown before Gmail is connected)

enum SampleData {
    static var transactions: [Transaction] {
        let cal = Calendar.current
        func daysAgo(_ n: Int) -> Date { cal.date(byAdding: .day, value: -n, to: Date())! }
        let rows: [(Int, Double, String, SpendCategory, String)] = [
            (0, 420, "Swiggy", .food, "HDFC"),
            (1, 1250, "Big Bazaar", .groceries, "HDFC"),
            (1, 199, "Spotify", .entertainment, "ICICI"),
            (2, 310, "Uber", .transport, "HDFC"),
            (3, 2899, "Amazon", .shopping, "ICICI"),
            (4, 650, "Zomato", .food, "HDFC"),
            (5, 999, "Airtel Recharge", .utilities, "SBI"),
            (6, 540, "Blinkit", .groceries, "HDFC"),
            (8, 180, "Rapido", .transport, "ICICI"),
            (9, 3500, "Myntra", .shopping, "HDFC"),
            (10, 649, "Netflix", .entertainment, "ICICI"),
            (11, 850, "Apollo Pharmacy", .health, "SBI"),
            (12, 380, "Swiggy", .food, "HDFC"),
            (14, 2100, "BESCOM Electricity", .utilities, "HDFC"),
            (15, 5000, "Groww SIP", .investment, "ICICI"),
            (17, 720, "Zomato", .food, "HDFC"),
            (19, 1500, "Indian Oil Petrol", .transport, "SBI"),
            (21, 460, "Zepto", .groceries, "HDFC"),
            (23, 1299, "BookMyShow", .entertainment, "ICICI"),
            (25, 899, "Flipkart", .shopping, "HDFC"),
            (32, 410, "Swiggy", .food, "HDFC"),
            (33, 199, "Spotify", .entertainment, "ICICI"),
            (35, 2750, "Amazon", .shopping, "ICICI"),
            (36, 980, "Airtel Recharge", .utilities, "SBI"),
            (38, 5000, "Groww SIP", .investment, "ICICI"),
            (40, 649, "Netflix", .entertainment, "ICICI"),
            (42, 1850, "BigBasket", .groceries, "HDFC"),
            (45, 600, "Ola", .transport, "HDFC"),
            (48, 1100, "Dominos", .food, "ICICI"),
            (52, 3200, "MakeMyTrip", .travel, "HDFC"),
            // Person-to-person transfers — some to family, some not. The Apple Intelligence
            // family detector decides which (matched against SampleData.familyNames).
            (2, 8000, "Priya Sharma", .transfer, "HDFC"),    // Mom
            (7, 3000, "Rohan", .transfer, "ICICI"),          // brother
            (16, 1200, "Ramesh Kumar", .transfer, "HDFC"),   // landlord — not family
            (27, 600, "Sandeep Plumber", .transfer, "SBI"),  // service — not family
        ]
        // Two sample members to demonstrate family segregation.
        var txs = rows.map {
            Transaction(date: daysAgo($0.0), amount: $0.1, merchant: $0.2,
                        category: $0.3, bank: $0.4, source: "sample", rawSnippet: nil)
        }
        for i in txs.indices {
            txs[i].account = i % 3 == 0 ? "family@sample.in" : "you@sample.in"
        }
        return txs
    }

    /// Default family for the demo — the detector matches transfer recipients against these.
    static let familyMembers = [
        FamilyMember(name: "Priya Sharma", relationship: "Mother", aliases: "Mom, Mummy"),
        FamilyMember(name: "Rohan Verma", relationship: "Brother", aliases: "Rohan"),
        FamilyMember(name: "Anita Verma", relationship: "Spouse", aliases: ""),
    ]

    /// Rich, fully-tagged demo dataset for screenshots/marketing: income + spending across
    /// categories, investments, family transfers, a named-account bill, and a mix of capture
    /// channels (SMS with real times, email, manual) so every card and badge has something to show.
    static var demoTransactions: [Transaction] {
        let cal = Calendar.current
        func at(_ daysAgo: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
            let day = cal.date(byAdding: .day, value: -daysAgo, to: Date())!
            return cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
        var out: [Transaction] = []
        func add(_ daysAgo: Int, _ amount: Double, _ merchant: String, _ category: SpendCategory,
                 _ bank: String, source: String, hour: Int = 0, minute: Int = 0,
                 income: Bool = false, family: String? = nil, acct4: String? = nil) {
            var t = Transaction(date: at(daysAgo, hour, minute), amount: amount, merchant: merchant,
                                category: category, bank: bank, source: source, rawSnippet: nil)
            t.kind = income ? .income : .expense
            t.recipientAccountLast4 = acct4
            if let family { t.toFamily = true; t.familyMember = family }
            out.append(t)
        }
        // Income (drives the income-vs-spending card and the statement)
        add(4,  125000, "Acme Corp Payroll", .income, "HDFC", source: "gmail", income: true)
        add(34, 125000, "Acme Corp Payroll", .income, "HDFC", source: "gmail", income: true)
        // Everyday spending — SMS rows carry a time of day, email rows don't.
        add(0,  420,  "Swiggy",            .food,          "HDFC", source: "sms",   hour: 13, minute: 12)
        add(1,  1250, "Big Bazaar",        .groceries,     "HDFC", source: "sms",   hour: 19, minute: 40)
        add(1,  199,  "Spotify",           .entertainment, "ICICI", source: "gmail")
        add(2,  310,  "Uber",              .transport,     "HDFC", source: "sms",   hour: 9,  minute: 5)
        add(3,  2899, "Amazon",            .shopping,      "ICICI", source: "gmail")
        add(4,  650,  "Zomato",            .food,          "HDFC", source: "sms",   hour: 21, minute: 18)
        add(5,  999,  "Airtel Recharge",   .utilities,     "SBI",  source: "sms",   hour: 11, minute: 2)
        add(6,  540,  "Blinkit",           .groceries,     "HDFC", source: "sms",   hour: 20, minute: 33)
        add(8,  180,  "Rapido",            .transport,     "ICICI", source: "sms",  hour: 8,  minute: 51)
        add(9,  3500, "Myntra",            .shopping,      "HDFC", source: "gmail")
        add(11, 649,  "Netflix",           .entertainment, "ICICI", source: "gmail")
        add(11, 850,  "Apollo Pharmacy",   .health,        "SBI",  source: "sms",   hour: 17, minute: 9)
        add(14, 2100, "BESCOM Electricity", .utilities,    "HDFC", source: "gmail")
        add(18, 1299, "BookMyShow",        .entertainment, "ICICI", source: "manual")
        add(19, 1500, "Indian Oil Petrol", .transport,     "SBI",  source: "sms",   hour: 7,  minute: 44)
        add(22, 1100, "Dominos",           .food,          "ICICI", source: "sms",  hour: 20, minute: 15)
        add(26, 899,  "Flipkart",          .shopping,      "HDFC", source: "gmail")
        add(28, 3200, "MakeMyTrip",        .travel,        "HDFC", source: "gmail")
        // Investments (drives the investments card)
        add(7,  5000, "Groww SIP",         .investment,    "ICICI", source: "gmail")
        add(15, 15000, "Zerodha Stocks",   .investment,    "HDFC", source: "sms",   hour: 10, minute: 1)
        add(37, 5000, "Groww SIP",         .investment,    "ICICI", source: "gmail")
        // Family transfers (tagged → "To family" badge; counted as spending)
        add(2,  8000,  "Priya Sharma", .transfer, "HDFC",  source: "sms", hour: 9,  minute: 30, family: "Priya Sharma", acct4: "2048")
        add(9,  3000,  "Rohan",        .transfer, "ICICI", source: "sms", hour: 18, minute: 40, family: "Rohan Verma",  acct4: "7781")
        add(20, 20000, "Anita Verma",  .transfer, "HDFC",  source: "sms", hour: 11, minute: 0,  family: "Anita Verma",  acct4: "1190")
        // A named-account bill (society maintenance) and a non-family transfer
        add(10, 18500, "Green Acres Maintenance", .utilities, "HDFC", source: "sms", hour: 8, minute: 30, acct4: "1234")
        add(16, 1200,  "UPI transfer", .transfer, "HDFC", source: "sms", hour: 10, minute: 12)
        return out
    }
}
