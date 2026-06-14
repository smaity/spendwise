// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import Foundation
import FoundationModels

/// Categorizes a spend transaction with Apple Intelligence's on-device model
/// (the Foundation Models framework, iOS 26+). Used as the *primary* classifier
/// when Apple Intelligence is available; the caller falls back to the embedding
/// `CategoryClassifier` on older iOS or when Apple Intelligence is turned off.
///
/// The FoundationModels framework is weak-linked: every use is guarded by
/// `#available(iOS 26.0, macOS 26.0, *)`, so the app still launches on iOS 17–25.
final class AICategoryClassifier {

    /// Whether the on-device model can run right now. Logs the reason when it can't.
    func isAvailable() -> Bool {
        guard #available(iOS 26.0, macOS 26.0, *) else {
            NSLog("SPENDWISE_AI: OS < 26 — Apple Intelligence unavailable")
            return false
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            return true
        case .unavailable(let reason):
            NSLog("SPENDWISE_AI: unavailable — \(String(describing: reason))")
            return false
        @unknown default:
            return false
        }
    }

    /// Classifies one expense. Returns nil on any failure so the caller keeps the
    /// embedding classifier's guess.
    func classify(merchant: String, snippet: String) async -> SpendCategory? {
        guard #available(iOS 26.0, macOS 26.0, *),
              case .available = SystemLanguageModel.default.availability else { return nil }
        do {
            let session = LanguageModelSession(instructions: Self.instructions)
            let prompt = """
            Merchant: \(merchant)
            Bank alert: \(snippet)
            """
            let response = try await session.respond(to: prompt, generating: AICategory.self)
            return response.content.spendCategory
        } catch {
            NSLog("SPENDWISE_AI: classify error — \(error.localizedDescription)")
            return nil
        }
    }

    private static let instructions = """
    You categorize a single bank debit / spending transaction into exactly one category,
    using the merchant name and bank alert text. Indian merchants and banks are common.

    Category definitions:
    - foodAndDining: restaurants, cafes, food delivery (Swiggy, Zomato), bars.
    - groceries: supermarkets and grocery/quick-commerce (BigBasket, Zepto, Blinkit, DMart).
    - transport: fuel/petrol/diesel (Indian Oil, HP, Bharat Petroleum), cabs (Uber, Ola),
      metro, bus, parking, tolls (FASTag).
    - shopping: retail, apparel, electronics, marketplaces (Amazon, Flipkart, Myntra).
    - entertainment: movies (PVR, INOX), streaming/OTT (Netflix, Spotify), games, events.
    - billsAndUtilities: electricity, water, gas, mobile/broadband recharge (Jio, Airtel), DTH.
    - health: pharmacies and medicines (Apollo Pharmacy, PharmEasy, 1mg), doctors, hospitals,
      clinics, diagnostics, gyms.
    - travel: flights, trains (IRCTC), hotels, holiday bookings (MakeMyTrip).
    - education: tuition, courses, school/college fees, books for study.
    - investment: mutual funds/SIP, stocks, brokerages (Groww, Zerodha), insurance premiums.
    - transfer: person-to-person transfers, wallet top-ups, UPI to individuals.
    - other: only when nothing above fits.

    Choose the single best-fitting category.
    """
}

/// The categories Apple Intelligence may choose from (guided generation constrains the
/// model's output to exactly one of these cases). Maps onto the app's `SpendCategory`.
@available(iOS 26.0, macOS 26.0, *)
@Generable
enum AICategory {
    case foodAndDining
    case groceries
    case transport
    case shopping
    case entertainment
    case billsAndUtilities
    case health
    case travel
    case education
    case investment
    case transfer
    case other

    var spendCategory: SpendCategory {
        switch self {
        case .foodAndDining:      return .food
        case .groceries:          return .groceries
        case .transport:          return .transport
        case .shopping:           return .shopping
        case .entertainment:      return .entertainment
        case .billsAndUtilities:  return .utilities
        case .health:             return .health
        case .travel:             return .travel
        case .education:          return .education
        case .investment:         return .investment
        case .transfer:           return .transfer
        case .other:              return .other
        }
    }
}
