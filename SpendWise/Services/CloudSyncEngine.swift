// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import Foundation
import CloudKit
import Security
import os

/// Two-way sync of transactions through the user's OWN private iCloud database, so the iPhone
/// (email capture) and the Mac (SMS capture) converge on one ledger. Built on `CKSyncEngine`
/// (iOS 17+/macOS 14+) layered ON TOP of the existing `TransactionStore` + JSON store — the
/// hand-rolled merge/dedup, AI-refine, and family-detection pipeline stays the source of truth;
/// CloudKit only mirrors rows in and out.
///
/// Conflict resolution is a FIELD-LEVEL merge (not blanket last-writer-wins): AI-enriched fields
/// (category, toFamily, familyMember, isSelfTransfer) and stable source ids are never clobbered
/// by the other device's un-enriched copy — see `Self.merge`.
///
/// Safe-by-default: if iCloud isn't signed in / the container isn't entitled, the engine stays
/// inert and the app works exactly as it did before (local JSON only).
@MainActor
final class CloudSyncEngine {

    static let containerIdentifier = "iCloud.com.eduquizacademy.spendwise"
    static let recordType = "Transaction"

    private let zoneID = CKRecordZone.ID(zoneName: "transactions", ownerName: CKCurrentUserDefaultName)
    private let log = Logger(subsystem: "com.eduquizacademy.spendwise", category: "CloudSync")

    private weak var store: TransactionStore?
    private var engine: CKSyncEngine?
    private var container: CKContainer?   // created lazily in start(), only when entitled

    /// Whether this build actually carries the iCloud-container entitlement. `CKContainer(identifier:)`
    /// *traps* when it doesn't, so we must check before ever constructing one — this keeps the app
    /// from crashing on launch in a build where the CloudKit capability hasn't been configured yet.
    /// The entitlement-introspection API (`SecTask…`) is macOS-only; on iOS, real signed builds
    /// always carry the entitlement (it's applied at build/sign time), so we proceed.
    private static func hasICloudEntitlement() -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil),
              let identifiers = value as? [String] else { return false }
        return identifiers.contains(containerIdentifier)
        #else
        return true
        #endif
    }

    /// Persisted `CKSyncEngine` state (change tokens etc.), alongside transactions.json.
    private let stateURL = AppFiles.url("cksync-state.json")

    var isActive: Bool { engine != nil }

    // MARK: Lifecycle

    /// Activates sync if the user is signed into iCloud and the container is reachable. A no-op
    /// (stays inert) otherwise — never throws into the app.
    func start(store: TransactionStore) async {
        self.store = store
        guard engine == nil else { return }
        #if !SPENDWISE_CLOUDKIT
        // CloudKit sync is opt-in: enabled only once the iCloud/Push capabilities are provisioned
        // on the App ID and the SPENDWISE_CLOUDKIT compilation condition is set (see M6 docs).
        // Off by default so normal builds sign/deploy without those capabilities and never touch
        // CKContainer (which traps when the entitlement is absent).
        log.info("CloudKit sync not enabled in this build (SPENDWISE_CLOUDKIT unset)")
        return
        #else
        guard Self.hasICloudEntitlement() else {
            log.info("No iCloud container entitlement — sync inert")
            return
        }
        let container = CKContainer(identifier: Self.containerIdentifier)
        self.container = container
        let status = try? await container.accountStatus()
        guard status == .available else {
            log.info("iCloud unavailable (status: \(String(describing: status), privacy: .public)) — sync inert")
            return
        }
        var config = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: loadState(),
            delegate: self
        )
        config.automaticallySync = true
        engine = CKSyncEngine(config)
        log.info("CloudKit sync engine started")
        #endif
    }

    /// Queue locally-changed transactions to push to iCloud. No-op when inert.
    func recordLocalChanges(_ ids: [UUID]) {
        guard let engine, !ids.isEmpty else { return }
        engine.state.add(pendingRecordZoneChanges: ids.map { .saveRecord(recordID(for: $0)) })
    }

    /// Queue locally-deleted transactions to remove from iCloud. No-op when inert.
    func recordLocalDeletions(_ ids: [UUID]) {
        guard let engine, !ids.isEmpty else { return }
        engine.state.add(pendingRecordZoneChanges: ids.map { .deleteRecord(recordID(for: $0)) })
    }

    // MARK: State persistence

    private func loadState() -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private func saveState(_ state: CKSyncEngine.State.Serialization) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    // MARK: Record <-> Transaction mapping

    private func recordID(for id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    }

    /// Builds a CKRecord from the current local row, preserving the server change-tag carried in
    /// the engine state (CKSyncEngine supplies the base record when one exists).
    private func record(for tx: Transaction, base: CKRecord?) -> CKRecord {
        let rec = base ?? CKRecord(recordType: Self.recordType, recordID: recordID(for: tx.id))
        rec["date"] = tx.date as CKRecordValue
        rec["amount"] = tx.amount as CKRecordValue
        rec["merchant"] = tx.merchant as CKRecordValue
        rec["category"] = tx.category.rawValue as CKRecordValue
        rec["bank"] = tx.bank as CKRecordValue
        rec["source"] = tx.source as CKRecordValue
        rec["rawSnippet"] = tx.rawSnippet as CKRecordValue?
        rec["account"] = tx.account as CKRecordValue?
        rec["sourceID"] = tx.sourceID as CKRecordValue?
        rec["altSourceID"] = tx.altSourceID as CKRecordValue?
        rec["kind"] = tx.kind?.rawValue as CKRecordValue?
        rec["toFamily"] = tx.toFamily.map { NSNumber(value: $0) }
        rec["familyMember"] = tx.familyMember as CKRecordValue?
        rec["recipientAccountLast4"] = tx.recipientAccountLast4 as CKRecordValue?
        rec["isSelfTransfer"] = tx.isSelfTransfer.map { NSNumber(value: $0) }
        rec["modifiedAt"] = (tx.modifiedAt ?? Date(timeIntervalSince1970: 0)) as CKRecordValue
        return rec
    }

    private func transaction(from rec: CKRecord) -> Transaction? {
        guard let id = UUID(uuidString: rec.recordID.recordName),
              let date = rec["date"] as? Date,
              let amount = rec["amount"] as? Double,
              let merchant = rec["merchant"] as? String,
              let categoryRaw = rec["category"] as? String,
              let category = SpendCategory(rawValue: categoryRaw),
              let bank = rec["bank"] as? String,
              let source = rec["source"] as? String else { return nil }
        var tx = Transaction(id: id, date: date, amount: amount, merchant: merchant,
                             category: category, bank: bank, source: source)
        tx.rawSnippet = rec["rawSnippet"] as? String
        tx.account = rec["account"] as? String
        tx.sourceID = rec["sourceID"] as? String
        tx.altSourceID = rec["altSourceID"] as? String
        tx.kind = (rec["kind"] as? String).flatMap(TransactionKind.init(rawValue:))
        tx.toFamily = (rec["toFamily"] as? NSNumber)?.boolValue
        tx.familyMember = rec["familyMember"] as? String
        tx.recipientAccountLast4 = rec["recipientAccountLast4"] as? String
        tx.isSelfTransfer = (rec["isSelfTransfer"] as? NSNumber)?.boolValue
        tx.modifiedAt = rec["modifiedAt"] as? Date
        return tx
    }

    // MARK: Field-level merge (conflict + remote-apply)

    /// Merges two copies of the same logical transaction (same id). Protects enrichment:
    /// non-`.other` category, non-nil family verdicts, and non-nil source ids beat their
    /// defaults; ties break on the newer `modifiedAt`.
    static func merge(_ a: Transaction, _ b: Transaction) -> Transaction {
        let aNewer = (a.modifiedAt ?? .distantPast) >= (b.modifiedAt ?? .distantPast)
        let newer = aNewer ? a : b
        let older = aNewer ? b : a
        var m = newer

        // Category: prefer a real (non-.other) categorization; if both real and differ, newer wins.
        if newer.category == .other && older.category != .other { m.category = older.category }

        // Family verdicts: a decided verdict beats "not yet checked" (nil).
        m.toFamily = newer.toFamily ?? older.toFamily
        m.familyMember = newer.familyMember ?? older.familyMember
        m.isSelfTransfer = newer.isSelfTransfer ?? older.isSelfTransfer
        m.kind = newer.kind ?? older.kind

        // Source ids: keep both channels' ids if present.
        m.sourceID = newer.sourceID ?? older.sourceID
        let alts = Set([a.sourceID, a.altSourceID, b.sourceID, b.altSourceID].compactMap { $0 })
            .subtracting([m.sourceID].compactMap { $0 })
        m.altSourceID = alts.sorted().first

        m.rawSnippet = newer.rawSnippet ?? older.rawSnippet
        m.account = newer.account ?? older.account
        m.recipientAccountLast4 = newer.recipientAccountLast4 ?? older.recipientAccountLast4
        return m
    }
}

// MARK: - CKSyncEngineDelegate

extension CloudSyncEngine: CKSyncEngineDelegate {

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let e):
            saveState(e.stateSerialization)

        case .fetchedRecordZoneChanges(let e):
            let modified = e.modifications.compactMap { transaction(from: $0.record) }
            let deletedIDs = e.deletions.compactMap { UUID(uuidString: $0.recordID.recordName) }
            store?.applyRemote(modified: modified, deletedIDs: deletedIDs)

        case .sentRecordZoneChanges(let e):
            // Re-queue records the server had a newer copy of, after field-merging.
            for failed in e.failedRecordSaves {
                guard case .serverRecordChanged = failed.error.code,
                      let serverRecord = failed.error.serverRecord,
                      let serverTx = transaction(from: serverRecord),
                      let localTx = store?.transaction(withID: serverTx.id) else { continue }
                let merged = Self.merge(localTx, serverTx)
                store?.applyRemote(modified: [merged], deletedIDs: [])
                syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(serverRecord.recordID)])
            }

        case .accountChange(let e):
            handleAccountChange(e)

        default:
            break   // willSend/didSend/willFetch/didFetch/fetchedDatabaseChanges — nothing to do
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !pending.isEmpty else { return nil }

        // Build the records up front on the main actor; the batch's record provider then just
        // reads from this prepared map (it runs outside the actor, so it can't touch the store).
        var recordsByID: [CKRecord.ID: CKRecord] = [:]
        for change in pending {
            guard case .saveRecord(let recordID) = change else { continue }
            if let id = UUID(uuidString: recordID.recordName), let tx = store?.transaction(withID: id) {
                recordsByID[recordID] = record(for: tx, base: nil)
            } else {
                // The row no longer exists locally — drop the pending save.
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            }
        }

        let records = recordsByID   // immutable snapshot for the @Sendable provider closure
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            records[recordID]
        }
    }

    private func handleAccountChange(_ event: CKSyncEngine.Event.AccountChange) {
        switch event.changeType {
        case .signOut, .switchAccounts:
            // Leave local data intact; just drop the engine so a fresh account re-syncs clean.
            engine = nil
            try? FileManager.default.removeItem(at: stateURL)
        default:
            break
        }
    }
}
