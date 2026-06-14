// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import Foundation
import FoundationModels

/// Result of matching a transfer recipient against the user's family.
struct FamilyTransferMatch {
    let isFamily: Bool
    let member: String?   // the family name it matched, when isFamily == true
}

/// Decides whether a person-to-person transfer is going to a family member, using Apple
/// Intelligence (Foundation Models, iOS 26+). The model fuzzy-matches the transfer's
/// recipient against the user's list of family names — handling nicknames ("Mummy" ≈ "Mom"),
/// partial names ("Rohan" ≈ "Rohan Verma"), and spelling/case differences that plain string
/// matching would miss. Returns nil when Apple Intelligence is unavailable.
///
/// FoundationModels is weak-linked: every use is guarded by `#available(iOS 26.0, macOS 26.0, *)`.
final class AIFamilyTransferService {

    func isAvailable() -> Bool {
        guard #available(iOS 26.0, macOS 26.0, *) else { return false }
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// `recipient` is the payee name on the alert; `note` is the original snippet (optional).
    /// `family` is the user's family; `userProfile` is the user's own identity (so a transfer
    /// to *your own* account isn't counted as family).
    func match(recipient: String, note: String,
               family: [FamilyMember], userProfile: UserProfile) async -> FamilyTransferMatch? {
        guard #available(iOS 26.0, macOS 26.0, *),
              case .available = SystemLanguageModel.default.availability,
              !family.isEmpty else { return nil }
        do {
            let session = LanguageModelSession(
                instructions: Self.instructions(family: family, userProfile: userProfile))
            let prompt = """
            Transfer recipient: \(recipient)
            Alert text: \(note)
            """
            let result = try await session.respond(to: prompt, generating: AIFamilyMatch.self).content
            // Guardrails: only trust a positive if the model named an ACTUAL family member AND
            // that member's name/alias actually appears in the message. The on-device model
            // otherwise hallucinates matches for generic recipients ("UPI transfer", "IMPS
            // transfer") — defaulting to a family name that isn't in the text at all.
            guard result.isFamilyMember,
                  let matched = Self.resolve(result.matchedName, in: family),
                  Self.nameAppears(matched, in: recipient + " " + note) else {
                return FamilyTransferMatch(isFamily: false, member: nil)
            }
            return FamilyTransferMatch(isFamily: true, member: matched.name)
        } catch {
            NSLog("SPENDWISE_AI: family-transfer error — \(error.localizedDescription)")
            return nil
        }
    }

    /// True if a significant token of the member's name or aliases actually appears in the
    /// message text — the deterministic backstop against the model inventing a family match for a
    /// recipient whose name isn't in the message (rail labels, account numbers, merchants).
    private static func nameAppears(_ member: FamilyMember, in text: String) -> Bool {
        let hay = text.lowercased()
        let tokens = (member.name + " " + member.aliases)
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 }
        return tokens.contains { hay.contains($0) }
    }

    /// Resolves a model-returned name to a real family member (case-insensitive, allowing the
    /// returned value to be a member's name or one of their aliases, in either direction).
    private static func resolve(_ returned: String, in family: [FamilyMember]) -> FamilyMember? {
        let r = returned.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty else { return nil }
        return family.first { m in
            let hay = (m.name + " " + m.aliases).lowercased()
            return hay.contains(r) || r.contains(m.name.lowercased())
        }
    }

    private static func instructions(family: [FamilyMember], userProfile: UserProfile) -> String {
        let list = family.map { "- \($0.descriptor)" }.joined(separator: "\n")
        let you = userProfile.isEmpty ? "" : """

            The user themselves is: \(userProfile.descriptor). A transfer to the user's OWN
            name/handles is NOT a family transfer — return false for those.
            """
        return """
        You decide whether a person-to-person money transfer is going to one of the user's
        family members. The user's family:
        \(list)\(you)

        Be CONSERVATIVE — tag as family ONLY when you are confident the recipient genuinely IS one
        of the listed members: the recipient's name or UPI handle in the message clearly
        corresponds to a member's name, nickname, alias, or handle (allowing short/partial names
        like "Rohan" ≈ "Rohan Verma" and spelling/case differences). Do NOT guess and do NOT invent
        a match. Return false for companies, merchants, shops, banks, clearing houses, securities
        firms, landlords, service providers, the user's own name/accounts, generic labels such as
        "UPI transfer" or "IMPS transfer", bare account numbers, or any recipient you cannot
        confidently tie to a specific listed family member. When in doubt, return false.
        When it IS a clear family member, return that member's exact name from the list.
        """
    }
}

/// Guided-generation shape. iOS 26+ only.
@available(iOS 26.0, macOS 26.0, *)
@Generable
private struct AIFamilyMatch {
    @Guide(description: "True only if the transfer recipient is one of the listed family members.")
    var isFamilyMember: Bool

    @Guide(description: "The matching family member's name, or empty when not a family member.")
    var matchedName: String
}
