// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import Foundation
import FoundationModels

/// Decides whether a bank alert is an ACTUAL completed money movement, or merely a NOTICE —
/// a bill reminder, a scheduled/upcoming auto-debit or e-mandate, a payment request, or a
/// failed/declined attempt. These notices carry an amount and a debit word, so keyword parsing
/// mistakes them for spends; the on-device model reads the wording (tense, "due"/"scheduled"/
/// "will be"/"declined") to tell them apart. Used to filter out false-positive "transactions".
///
/// FoundationModels is weak-linked: every use is guarded by `#available(iOS 26.0, macOS 26.0, *)`.
final class AISpendingValidator {

    func isAvailable() -> Bool {
        guard #available(iOS 26.0, macOS 26.0, *) else { return false }
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Returns true if the alert is a completed transaction that actually moved money, false if it
    /// is only a notice/reminder/scheduled/failed message, nil if the model is unavailable/errors
    /// (caller should then keep the row — don't drop on uncertainty).
    func isCompletedTransaction(text: String) async -> Bool? {
        guard #available(iOS 26.0, macOS 26.0, *),
              case .available = SystemLanguageModel.default.availability else { return nil }
        do {
            let session = LanguageModelSession(instructions: Self.instructions)
            let result = try await session.respond(to: "Bank message:\n\(text)",
                                                   generating: AISpendingVerdict.self).content
            return result.isCompletedPayment
        } catch {
            NSLog("SPENDWISE_AI: spending-validator error — \(error.localizedDescription)")
            return nil
        }
    }

    private static let instructions = """
    You read a single Indian bank/card alert and decide whether it reports a payment that has
    ALREADY happened (money actually moved), or whether it is only a NOTICE about something that
    has not happened.

    COMPLETED (answer true): money has already been debited or credited — e.g. "debited", "spent",
    "paid", "sent", "withdrawn", "credited", "successfully debited", "txn of Rs… at …". Executed
    auto-debits/UPI-AutoPay/e-mandate that say the amount WAS debited/sent are completed.

    NOT completed (answer false): bill reminders and dues ("bill is due on…", "amount due",
    "minimum due", "pay now", "new bill alert"); scheduled or upcoming debits ("will be deducted",
    "is scheduled on", "e-mandate! Rs… will be deducted", "please ensure sufficient balance");
    payment/collect requests; OTP or promotional messages; and failed/declined/reversed attempts
    ("declined", "failed", "insufficient balance").

    The key signal is tense and intent: a payment that WILL/MAY happen, is DUE, is REQUESTED, or
    FAILED is not a completed transaction. When genuinely unsure, answer true (keep it).
    """
}

/// Guided-generation shape. iOS 26+/macOS 26+ only.
@available(iOS 26.0, macOS 26.0, *)
@Generable
private struct AISpendingVerdict {
    @Guide(description: "True if money has ALREADY moved (a completed debit or credit). False if it is only a reminder, a due bill, a scheduled/upcoming debit, a payment request, or a failed/declined attempt.")
    var isCompletedPayment: Bool
}
