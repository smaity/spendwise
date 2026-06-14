// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

#if os(macOS)
import SwiftUI

/// macOS menu-bar commands. The Mac has no background-refresh task, so syncing is driven from
/// the menu (⌘R for the SMS read; Gmail sync mirrors the iOS button).
struct SpendWiseCommands: Commands {
    let store: TransactionStore

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Sync from Messages") {
                Task { await store.syncFromSMS() }
            }
            .keyboardShortcut("r", modifiers: [.command])

            Button("Sync from Gmail") {
                Task { await store.syncFromGmail() }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!store.gmail.isConnected)
        }
    }
}
#endif
