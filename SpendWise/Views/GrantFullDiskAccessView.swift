// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

#if os(macOS)
import SwiftUI
import AppKit

/// Shown on the Mac when SpendWise can't read the Messages database — reading bank SMS requires
/// Full Disk Access, which the user grants once in System Settings. Deep-links straight to the
/// right pane and offers a Recheck once they've toggled it on.
struct GrantFullDiskAccessView: View {
    /// Called when the user taps Recheck — return true if access now works.
    let recheck: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Allow SpendWise to read bank SMS", systemImage: "lock.shield")
                .font(.headline)

            Text("""
            Bank transaction alerts your iPhone receives as SMS appear in the Messages app on this \
            Mac (via Text Message Forwarding). To turn those into transactions, SpendWise needs \
            Full Disk Access. Your messages are read on-device only and never leave your Mac.
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                stepRow(1, "Open Full Disk Access settings below")
                stepRow(2, "Turn on the switch next to SpendWise")
                stepRow(3, "Come back and tap Recheck")
            }
            .font(.callout)

            HStack {
                Button("Open Full Disk Access Settings") { openSettings() }
                    .buttonStyle(.borderedProminent)
                Button("Recheck") { recheck() }
            }
            .padding(.top, 4)
        }
        .padding()
        .frame(maxWidth: 460, alignment: .leading)
    }

    private func stepRow(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n).").bold().foregroundStyle(Brand.accent)
            Text(text)
        }
    }

    private func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
#endif
