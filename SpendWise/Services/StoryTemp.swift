// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import Foundation

/// All Spending Story video artifacts live in one temp subfolder so they're easy to account
/// for and wipe. Kept small: at rest there's at most one finished video (~10–15MB), and the
/// folder is purged when the story screen closes.
enum StoryTemp {
    static var directory: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SpendingStory", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A fresh URL for `name` inside the folder (removes any prior file at that path).
    static func url(_ name: String) -> URL {
        let url = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        return url
    }

    static func remove(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Deletes the whole folder — called when leaving the story screen.
    static func purge() {
        try? FileManager.default.removeItem(at: directory)
    }
}
