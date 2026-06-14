// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import Foundation

/// App-private storage location. Uses **Application Support**, not Documents: on macOS the app is
/// non-sandboxed (so it can read the Messages chat.db), which means `FileManager.documentDirectory`
/// is the user's REAL `~/Documents` — we must not write app data there. Application Support is the
/// correct, app-private location on both iOS and macOS.
enum AppFiles {

    /// `…/Application Support/SpendWise/`, created on first access.
    static let baseDirectory: URL = {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("SpendWise", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func url(_ name: String) -> URL { baseDirectory.appendingPathComponent(name) }

    /// One-time move of files written by older builds (which used the Documents directory) into
    /// the app-private location. No-op once migrated.
    static func migrateLegacyStorageIfNeeded() {
        let fm = FileManager.default
        let oldDir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for name in ["transactions.json", "cksync-state.json", "spendwise-sms-debug.txt",
                     "detection_rules.json"] {
            let old = oldDir.appendingPathComponent(name)
            let new = url(name)
            if fm.fileExists(atPath: old.path) && !fm.fileExists(atPath: new.path) {
                try? fm.moveItem(at: old, to: new)
            }
        }
    }
}
