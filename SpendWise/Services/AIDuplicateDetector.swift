// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import Foundation
import FoundationModels

/// Decides whether two bank alerts describe the SAME single payment, using Apple Intelligence
/// (Foundation Models, iOS 26+/macOS 26+). This is the reliable way to dedup the hard cases that
/// heuristics can't: one transfer reported by BOTH email and SMS often shows different payee text
/// ("UPI transfer" vs "Alex Kumar" vs "Vpa Acmesecurities") and even different categories — yet
/// the raw message text carries a shared reference/UTR/transaction number that identifies the
/// payment. Crucially, the model can also tell two *separate* same-amount, same-day transfers
/// apart (different reference numbers), so we don't under-count genuine repeated payments.
///
/// FoundationModels is weak-linked: every use is guarded by `#available(iOS 26.0, macOS 26.0, *)`.
final class AIDuplicateDetector {

    func isAvailable() -> Bool {
        guard #available(iOS 26.0, macOS 26.0, *) else { return false }
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Returns true if the two alerts are the same single payment, false if distinct, nil if the
    /// model is unavailable or errors (caller should then leave both rows in place).
    func isSamePayment(_ a: Transaction, _ b: Transaction) async -> Bool? {
        guard #available(iOS 26.0, macOS 26.0, *),
              case .available = SystemLanguageModel.default.availability else { return nil }
        do {
            let session = LanguageModelSession(instructions: Self.instructions)
            let prompt = """
            Both alerts are for ₹\(Int(a.amount)) on the same day.

            ALERT A — channel: \(a.source), bank: \(a.bank), payee/merchant: \(a.merchant)
            text: \(a.rawSnippet ?? "(no text)")

            ALERT B — channel: \(b.source), bank: \(b.bank), payee/merchant: \(b.merchant)
            text: \(b.rawSnippet ?? "(no text)")

            Are these the SAME single payment, or two separate payments?
            """
            return try await session.respond(to: prompt, generating: AIDuplicateVerdict.self).content.isSamePayment
        } catch {
            NSLog("SPENDWISE_AI: duplicate-detect error — \(error.localizedDescription)")
            return nil
        }
    }

    private static let instructions = """
    You decide whether two Indian bank transaction alerts describe the SAME single payment or two
    SEPARATE payments that merely share the same amount and date.

    They are the SAME payment when the underlying transaction is identical — for example the same
    transfer reported once by email and once by SMS, or the same alert delivered twice. The
    strongest evidence is a matching reference number (UPI ref / UTR / transaction id / RRN) in
    both texts; a matching recipient/VPA, account number, or timestamp is also strong evidence.
    Payee wording often differs between channels for the same payment (e.g. "UPI transfer",
    "Alex Kumar", and "VPA acmesecurities" can all be the same transfer) — do not treat
    different wording alone as different payments.

    They are SEPARATE payments when the texts carry DIFFERENT reference/UTR numbers, or clearly
    name different recipients/accounts, even though the amount and date match. Two genuine
    transfers of the same amount on the same day are separate — do not merge them.

    If the texts don't give enough evidence to be confident they are the same payment, answer
    false (keep them separate).
    """
}

/// Guided-generation shape. iOS 26+/macOS 26+ only.
@available(iOS 26.0, macOS 26.0, *)
@Generable
private struct AIDuplicateVerdict {
    @Guide(description: "True ONLY if both alerts describe the same single payment (matching reference/UTR number, recipient, or time). False if they are two separate payments or there isn't enough evidence.")
    var isSamePayment: Bool
}
