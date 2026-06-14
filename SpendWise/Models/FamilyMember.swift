// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import Foundation

/// A person the user considers family. The richer these details, the better Apple
/// Intelligence can match a transfer recipient to the right person.
struct FamilyMember: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var relationship: String = ""   // e.g. "Mother", "Brother", "Spouse"
    var aliases: String = ""        // comma-separated nicknames / UPI handles, optional
    var accountLast4: String = ""   // last 4 digits of their bank account, optional

    /// The member's account last-4 used for *deterministic* transfer matching. Reads the
    /// dedicated field first; falls back to a standalone 4-digit token in `aliases`, so
    /// accounts typed there before this field existed still match. nil when none is set.
    var accountLast4Digits: String? {
        let primary = accountLast4.filter(\.isNumber)
        if primary.count >= 4 { return String(primary.suffix(4)) }
        if let r = aliases.range(of: #"\b\d{4}\b"#, options: .regularExpression) {
            return String(aliases[r])
        }
        return nil
    }

    /// One-line description handed to the model.
    var descriptor: String {
        var parts = [name]
        if !relationship.trimmingCharacters(in: .whitespaces).isEmpty { parts.append("(\(relationship))") }
        let a = aliases.trimmingCharacters(in: .whitespaces)
        if !a.isEmpty { parts.append("— also known as: \(a)") }
        if let last4 = accountLast4Digits { parts.append("— account ending \(last4)") }
        return parts.joined(separator: " ")
    }
}

/// The app owner's own details. Used so the model knows who "you" are — e.g. not to count
/// transfers to your *own* accounts as family, and to personalize insights.
struct UserProfile: Codable, Hashable {
    var name: String = ""
    var aliases: String = ""    // your other names / UPI handles, optional
    var accounts: String = ""   // your own accounts' last-4 digits, comma/space separated

    var isEmpty: Bool {
        name.trimmingCharacters(in: .whitespaces).isEmpty &&
        aliases.trimmingCharacters(in: .whitespaces).isEmpty &&
        accountLast4Set.isEmpty
    }

    /// The last-4 of every account the user marked as their own. A transfer landing on one of
    /// these is a move between your *own* accounts, not real spending to someone else.
    var accountLast4Set: Set<String> {
        let tokens = accounts.split { !$0.isNumber }   // split on anything non-numeric
        return Set(tokens.filter { $0.count == 4 }.map(String.init))
    }

    var descriptor: String {
        let a = aliases.trimmingCharacters(in: .whitespaces)
        return a.isEmpty ? name : "\(name) — also known as: \(a)"
    }
}
