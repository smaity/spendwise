// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

#if os(macOS)
import Foundation
import SQLite3
import os

/// Reads bank transaction-alert SMS on the Mac. SMS sent to the user's iPhone are mirrored into
/// the macOS Messages app via Continuity (Text Message Forwarding) and stored in a local SQLite
/// database, `~/Library/Messages/chat.db`. This is the one capture path Apple blocks on iOS
/// (third-party apps can't read the SMS inbox there) but permits on the Mac — provided the app
/// has **Full Disk Access** and is not sandboxed.
///
/// Bodies are run through the SAME `TransactionParser` the Gmail path uses, so SMS and email
/// transactions categorize and dedup identically.
struct SMSTransactionSource {

    enum SMSAccessError: Error, Equatable {
        case fullDiskAccessDenied   // chat.db exists but we can't read it → user must grant FDA
        case databaseUnavailable    // Messages not set up / no chat.db yet
        case readFailed(String)
    }

    private let log = Logger(subsystem: "com.eduquizacademy.spendwise", category: "SMS")

    private var chatDBURL: URL {
        // Debug override so the reader can be pointed at a fixture database in tests.
        if let override = ProcessInfo.processInfo.environment["SMS_DB_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Messages/chat.db")
    }

    /// Reads bank SMS newer than `watermark`, parsed into transactions. Returns the new rows and
    /// the latest message timestamp seen (persist it to make the next read incremental).
    func fetchTransactions(since watermark: Date) throws -> (transactions: [Transaction], watermark: Date) {
        try withDatabaseCopy { try read(dbPath: $0, since: watermark) }
    }

    /// Receipt timestamps (with time-of-day) for specific message GUIDs — used to backfill a time
    /// onto SMS rows whose body stated only a date. Best-effort: unreadable DB → empty map.
    func receiptDates(forGUIDs guids: Set<String>) -> [String: Date] {
        guard !guids.isEmpty else { return [:] }
        return (try? withDatabaseCopy { dbPath in
            var db: OpaquePointer?
            guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [:] }
            defer { sqlite3_close(db) }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT guid, date FROM message", -1, &stmt, nil) == SQLITE_OK else { return [:] }
            defer { sqlite3_finalize(stmt) }
            var out: [String: Date] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let g = sqlite3_column_text(stmt, 0) else { continue }
                let guid = String(cString: g)
                if guids.contains(guid) { out[guid] = Self.dateFromAppleTime(sqlite3_column_int64(stmt, 1)) }
            }
            return out
        }) ?? [:]
    }

    /// Copies chat.db + its WAL sidecars to a temp dir, runs `body` against the copy, then cleans
    /// up. Copying first means we never contend with Messages' writes and we pick up rows living
    /// only in the WAL. A copy failure on an existing file is the signature of missing Full Disk Access.
    private func withDatabaseCopy<T>(_ body: (_ dbPath: String) throws -> T) throws -> T {
        let fm = FileManager.default
        let src = chatDBURL
        guard fm.fileExists(atPath: src.path) else {
            log.error("chat.db not found at \(src.path, privacy: .public)")
            throw SMSAccessError.databaseUnavailable
        }
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("spendwise-sms-\(UUID().uuidString)")
        try? fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        let tmpDB = tmpDir.appendingPathComponent("chat.db")
        do {
            try fm.copyItem(at: src, to: tmpDB)
            for sidecar in ["chat.db-wal", "chat.db-shm"] {
                let s = src.deletingLastPathComponent().appendingPathComponent(sidecar)
                if fm.fileExists(atPath: s.path) {
                    try? fm.copyItem(at: s, to: tmpDir.appendingPathComponent(sidecar))
                }
            }
        } catch {
            log.error("chat.db copy failed — Full Disk Access denied: \(error.localizedDescription, privacy: .public)")
            throw SMSAccessError.fullDiskAccessDenied
        }
        return try body(tmpDB.path)
    }

    /// Probe used by the UI to decide whether to show the "Grant Full Disk Access" prompt.
    func canReadMessages() -> Bool {
        let src = chatDBURL
        guard FileManager.default.fileExists(atPath: src.path) else { return false }
        return FileManager.default.isReadableFile(atPath: src.path)
    }

    // MARK: - SQLite

    private func read(dbPath: String, since watermark: Date) throws -> (transactions: [Transaction], watermark: Date) {
        var db: OpaquePointer?
        // Open the temp COPY read-write so SQLite can play back the WAL (read-only opens of a
        // WAL database can fail or miss the newest rows). It's a throwaway copy, so this is safe.
        var rc = sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil)
        if rc != SQLITE_OK {
            rc = sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil)   // fallback
        }
        guard rc == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw SMSAccessError.readFailed(msg)
        }
        defer { sqlite3_close(db) }

        // is_from_me = 0 → received. Modern macOS often stores the body only in `attributedBody`
        // (a typedstream blob) with `text` NULL, so we fetch BOTH and fall back to decoding the blob.
        let sql = """
        SELECT m.guid, m.text, m.date, h.id, m.attributedBody
        FROM message m
        LEFT JOIN handle h ON m.handle_id = h.ROWID
        WHERE m.is_from_me = 0
        ORDER BY m.date ASC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SMSAccessError.readFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var transactions: [Transaction] = []
        var maxDate = watermark
        var scanned = 0, gotBody = 0, fromBlob = 0, parsed = 0, droppedNoBank = 0

        while sqlite3_step(stmt) == SQLITE_ROW {
            scanned += 1
            guard let guidC = sqlite3_column_text(stmt, 0) else { continue }
            let guid = String(cString: guidC)

            // Body: prefer the plain `text` column; fall back to decoding `attributedBody`.
            var body: String? = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            if body == nil, let blob = sqlite3_column_blob(stmt, 4) {
                let len = Int(sqlite3_column_bytes(stmt, 4))
                let data = Data(bytes: blob, count: len)
                if let decoded = Self.decodeAttributedBody(data) { body = decoded; fromBlob += 1 }
            }
            guard let body, !body.isEmpty else { continue }
            gotBody += 1

            let rawDate = sqlite3_column_int64(stmt, 2)
            let sender = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let date = Self.dateFromAppleTime(rawDate)

            if date > maxDate { maxDate = date }
            guard date > watermark else { continue }   // already imported on a prior sync

            guard var tx = TransactionParser.parse(text: body, from: sender,
                                                   fallbackDate: date, source: "sms") else { continue }
            parsed += 1
            // Precision filter: a real bank SMS names its bank (via sender short-code or body).
            guard tx.bank != "Bank" else { droppedNoBank += 1; continue }
            // Every SMS row must carry a real time-of-day. Prefer the time the bank stated in the
            // body (most accurate); when the body gave only a date, graft the SMS's own receipt
            // time onto the transaction day so the row is never left at midnight.
            if !Self.hasTimeOfDay(tx.date) { tx.date = Self.graftTime(from: date, onto: tx.date) }
            tx.sourceID = "sms:\(guid)"
            tx.account = nil                       // SMS has no email account
            transactions.append(tx)
        }

        log.notice("SMS scan: \(scanned) received, \(transactions.count) imported (\(droppedNoBank) dropped, \(fromBlob) from attributedBody)")
        return (transactions, maxDate)
    }

    /// Whether a date carries a real time of day (vs a date-only/midnight value).
    static func hasTimeOfDay(_ date: Date) -> Bool {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return (c.hour ?? 0) != 0 || (c.minute ?? 0) != 0 || (c.second ?? 0) != 0
    }

    /// Copies the time-of-day from `source` onto the calendar day of `day`.
    static func graftTime(from source: Date, onto day: Date) -> Date {
        let cal = Calendar.current
        let t = cal.dateComponents([.hour, .minute, .second], from: source)
        return cal.date(bySettingHour: t.hour ?? 0, minute: t.minute ?? 0, second: t.second ?? 0, of: day) ?? source
    }

    /// `message.date` is time since the 2001 reference date — nanoseconds on modern macOS,
    /// seconds on older databases. Disambiguate by magnitude.
    static func dateFromAppleTime(_ raw: Int64) -> Date {
        let seconds = raw > 1_000_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw)
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// Extracts the message text from Messages' `attributedBody` (an NSArchiver "streamtyped"
    /// blob — not a keyed archive). The body string is stored inline after the NSString class
    /// marker, introduced by the typedstream `+` (0x2B) C-string type code followed by a length
    /// (a single byte, or 0x81 + 2-byte little-endian for ≥ 128). Best-effort; returns nil on
    /// any layout it doesn't recognize.
    static func decodeAttributedBody(_ data: Data) -> String? {
        guard let marker = data.range(of: Data("NSString".utf8)) else { return nil }
        guard let plus = data.range(of: Data([0x2B]), options: [], in: marker.upperBound..<data.endIndex) else { return nil }
        let bytes = [UInt8](data)
        var i = plus.upperBound
        guard i < bytes.count else { return nil }
        let length: Int
        if bytes[i] == 0x81 {
            guard i + 2 < bytes.count else { return nil }
            length = Int(bytes[i + 1]) | (Int(bytes[i + 2]) << 8)
            i += 3
        } else {
            length = Int(bytes[i])
            i += 1
        }
        guard length > 0, i + length <= bytes.count else { return nil }
        return String(bytes: bytes[i ..< i + length], encoding: .utf8)
    }
}
#endif
