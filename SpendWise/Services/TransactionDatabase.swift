// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import Foundation
import SQLite3

/// SQLite-backed persistence for transactions, replacing the single `transactions.json` file.
/// Each transaction is one row (id + its JSON encoding), so writes go through a real database
/// (WAL journaling, atomic transactions) instead of rewriting the whole ledger as one file.
///
/// The app's analytics all run over the in-memory `[Transaction]` array, so this layer only needs
/// to load the whole set and persist it; it is accessed solely from the `@MainActor` store, so the
/// single connection is used single-threaded.
final class TransactionDatabase {

    private var db: OpaquePointer?
    private let dbURL = AppFiles.url("transactions.sqlite")
    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init() {
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            NSLog("SPENDWISE_DB: open failed — \(db.map { String(cString: sqlite3_errmsg($0)) } ?? "")")
            return
        }
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA foreign_keys=ON;")
        exec("""
        CREATE TABLE IF NOT EXISTS transactions (
            id         TEXT PRIMARY KEY,
            date       REAL,
            amount     REAL,
            source     TEXT,
            modifiedAt REAL,
            data       BLOB NOT NULL
        );
        """)
    }

    deinit { sqlite3_close(db) }

    // MARK: Load / save

    func loadAll() -> [Transaction] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT data FROM transactions ORDER BY date DESC", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        let decoder = JSONDecoder()
        var rows: [Transaction] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let blob = sqlite3_column_blob(stmt, 0) else { continue }
            let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 0)))
            if let tx = try? decoder.decode(Transaction.self, from: data) { rows.append(tx) }
        }
        return rows
    }

    /// Persists the full ledger, in one transaction (delete-all + insert), mirroring the previous
    /// whole-file write but with the atomicity and crash-safety of SQLite.
    func replaceAll(_ transactions: [Transaction]) {
        let encoder = JSONEncoder()
        exec("BEGIN IMMEDIATE;")
        exec("DELETE FROM transactions;")
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db,
            "INSERT INTO transactions (id, date, amount, source, modifiedAt, data) VALUES (?,?,?,?,?,?)",
            -1, &stmt, nil) == SQLITE_OK else { exec("ROLLBACK;"); return }
        for tx in transactions {
            guard let data = try? encoder.encode(tx) else { continue }
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, tx.id.uuidString, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 2, tx.date.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 3, tx.amount)
            sqlite3_bind_text(stmt, 4, tx.source, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 5, tx.modifiedAt?.timeIntervalSinceReferenceDate ?? 0)
            data.withUnsafeBytes { sqlite3_bind_blob(stmt, 6, $0.baseAddress, Int32(data.count), Self.SQLITE_TRANSIENT) }
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        exec("COMMIT;")
    }

    var isEmpty: Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM transactions LIMIT 1", -1, &stmt, nil) == SQLITE_OK else { return true }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) != SQLITE_ROW
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }
}
