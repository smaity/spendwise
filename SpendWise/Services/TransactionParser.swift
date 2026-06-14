// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import Foundation

/// Parses transaction-alert emails from Indian banks (HDFC, ICICI, SBI, Axis, Kotak, etc.)
/// into `Transaction` values. Works on the email snippet/body text.
struct TransactionParser {

    // MARK: Amount

    /// Matches "Rs.1,234.56", "Rs 500", "INR 2,000.00", "₹350", and "Rs:580.00" (Union Bank uses a
    /// colon after the currency token).
    private static let amountRegex = try! NSRegularExpression(
        pattern: #"(?:Rs\.?|INR|₹)[\s:]*([\d,]+(?:\.\d{1,2})?)"#,
        options: [.caseInsensitive]
    )

    /// Words indicating money going OUT (incl. auto-pay / e-mandate / SIP / bill-pay debits).
    private static let debitKeywords = [
        "debited", "spent", "paid", "purchase", "withdrawn", "sent", "txn of", "transaction of",
        "deducted", "auto-debited", "auto debited", "autopay", "auto pay",
        "bill payment", "billpay", "bill pay",
    ]
    /// Words indicating money coming IN.
    private static let creditKeywords = ["credited", "received", "deposited"]
    /// Credits that are NOT earnings — refunds/reversals/cashback shouldn't count as income.
    private static let nonIncomeCredit = ["refund", "reversed", "reversal", "cashback", "failed", "declined"]
    /// Phrases that confirm money landed in the user's own account.
    private static let incomingMarkers = ["to your a", "in your a", "to a/c", "to your account", "in your account"]

    // MARK: Merchant

    /// "to VPA swiggy@icici", "at AMAZON", "towards Netflix", "Info: UPI/123/ZOMATO"
    private static let merchantPatterns: [NSRegularExpression] = [
        #"(?:to\s+VPA\s+)([\w.\-@]+)"#,
        #"(?:Info:\s*UPI[/\-]\w*[/\-])([A-Za-z0-9 .&\-]+)"#,
        #"(?:\bat\s+)([A-Za-z0-9 .&\-*]{3,40}?)(?:\s+on\b|\s+using\b|\.|,|$)"#,
        #"(?:towards\s+)([A-Za-z0-9 .&\-]{3,40}?)(?:\s+on\b|\.|,|$)"#,
        #"(?:to\s+)([A-Za-z][A-Za-z0-9 .&\-]{2,40}?)(?:\s+on\b|\.|,|$)"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    // MARK: Bank detection

    private static let bankSenders: [(needle: String, bank: String)] = [
        ("hdfcbank", "HDFC"), ("icicibank", "ICICI"), ("sbi", "SBI"),
        ("axisbank", "Axis"), ("kotak", "Kotak"), ("idfcfirst", "IDFC First"),
        ("yesbank", "Yes Bank"), ("indusind", "IndusInd"), ("paytm", "Paytm"),
        // SMS sender short-codes (e.g. VM-HDFCBK, AD-ICICIB, JD-SBIINB, BP-AXISBK).
        ("hdfcbk", "HDFC"), ("icicib", "ICICI"), ("sbiinb", "SBI"), ("axisbk", "Axis"),
        ("kotakb", "Kotak"), ("idfcfb", "IDFC First"), ("idfcbk", "IDFC First"),
    ]

    /// Last-resort bank inference from the message body itself — needed for SMS, whose sender
    /// is a short-code that may not match the list above. Harmless for email.
    private static let bankBodyNeedles: [(needle: String, bank: String)] = [
        ("hdfc", "HDFC"), ("icici", "ICICI"), ("state bank", "SBI"), ("axis", "Axis"),
        ("kotak", "Kotak"), ("idfc", "IDFC First"), ("yes bank", "Yes Bank"),
        ("indusind", "IndusInd"), ("paytm", "Paytm"), ("bank of baroda", "BoB"),
        ("punjab national", "PNB"), ("canara", "Canara"), ("union bank", "Union Bank"),
    ]

    static func bankFromBody(_ lowercasedText: String) -> String? {
        bankBodyNeedles.first { lowercasedText.contains($0.needle) }?.bank
    }

    // MARK: Non-transaction notices

    /// Phrases that mark a message as a NOTICE about a future/pending/failed payment rather than a
    /// completed money movement — bill reminders, scheduled auto-debits/e-mandates, declines.
    /// These carry an amount + a debit word, so without this guard the keyword parser logs them as
    /// real spends. The actual debit (e.g. "Sent Rs…", "successfully debited") arrives separately
    /// and is kept. Apple Intelligence (`AISpendingValidator`) handles anything worded unusually.
    private static let noticeMarkers = [
        "is due", "due on", "due date", "payment due", "amount due", "minimum amount due",
        "total amount due", "overdue", "bill alert", "new bill", "pay now",
        "will be deducted", "will be debited", "would be deducted", "to be debited", "shall be debited",
        "is scheduled", "scheduled on", "please ensure", "insufficient",
        "declined", "reminder", "kindly pay", "please pay",
        "payment request", "collect request", "requesting you", "has requested",
        "e-mandate!", "e-statement", "statement is generated", "bill generated",
    ]

    static func isNonTransactionNotice(_ lowercasedText: String) -> Bool {
        noticeMarkers.contains { lowercasedText.contains($0) }
    }

    // MARK: Reference number

    /// Bank reference / UPI reference / UTR / RRN — a number that is IDENTICAL across an email and
    /// SMS for the same payment, and different for distinct payments. Matches e.g. "Ref-616332746805",
    /// "Ref 616282326248", "UPI transaction reference no.: 616...", "UTR: 1234567890".
    private static let referenceRegex = try! NSRegularExpression(
        pattern: #"(?:\bref(?:erence)?\b(?:\s*(?:no|number))?\.?|\bUTR\b|\bRRN\b)[\s:#/\-]*(\d{9,})"#,
        options: [.caseInsensitive]
    )

    static func referenceNumber(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let m = referenceRegex.firstMatch(in: text, range: range),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }


    // MARK: Category rules

    private static let categoryRules: [(keywords: [String], category: SpendCategory)] = [
        (["swiggy", "zomato", "dominos", "mcdonald", "kfc", "pizza", "restaurant", "cafe", "eatfit", "faasos"], .food),
        (["bigbasket", "blinkit", "zepto", "grofers", "dmart", "grocery", "instamart", "jiomart"], .groceries),
        (["uber", "ola", "rapido", "irctc", "redbus", "metro", "petrol", "fuel", "hpcl", "iocl", "bpcl", "fastag"], .transport),
        (["amazon", "flipkart", "myntra", "ajio", "meesho", "nykaa", "croma", "reliance digital"], .shopping),
        (["netflix", "hotstar", "spotify", "prime video", "bookmyshow", "sonyliv", "youtube", "pvr", "inox", "steam", "playstation"], .entertainment),
        (["electricity", "bescom", "tneb", "mseb", "airtel", "jio", "vi ", "vodafone", "broadband", "recharge", "dth", "gas", "water bill", "tata power"], .utilities),
        (["pharmacy", "apollo", "medplus", "1mg", "pharmeasy", "hospital", "clinic", "practo", "cult.fit"], .health),
        (["makemytrip", "goibibo", "cleartrip", "indigo", "air india", "vistara", "oyo", "airbnb", "yatra", "hotel"], .travel),
        (["udemy", "coursera", "byjus", "unacademy", "school", "college", "tuition"], .education),
        (["zerodha", "groww", "upstox", "mutual fund", "sip", "nps", "ppf", "etmoney", "indmoney", "coin",
          "securities", "raise securities", "raisesecurities", "indian clearing", "clearing corp", "iccl",
          "moneylicious", "broking", "demat", "icicidirect", "angelbroking", "5paisa", "kuvera", "smallcase"], .investment),
        (["upi", "imps", "neft", "rtgs", "vpa"], .transfer),
    ]

    /// Keyword seeds used to warm-start the on-device `CategoryClassifier`.
    static var categorySeeds: [(keywords: [String], category: SpendCategory)] { categoryRules }

    // MARK: Date

    private static let dateFormats = [
        "dd-MM-yy", "dd-MM-yyyy", "dd-MMM-yy", "dd-MMM-yyyy",
        "ddMMMyy", "dd/MM/yy", "dd/MM/yyyy", "MMM dd, yyyy",
    ]
    private static let dateRegex = try! NSRegularExpression(
        pattern: #"\b(\d{1,2}[-/]\w{2,3}[-/]\d{2,4}|\d{1,2}\w{3}\d{2}|\w{3}\s\d{1,2},\s\d{4})\b"#
    )
    /// A clock time stated in the body, e.g. "12:40:01" or "20:39" — banks print the transaction
    /// time right after the date (e.g. "on 14-06-2026 12:40:01"). Used to give the date a real
    /// time-of-day instead of midnight.
    private static let timeRegex = try! NSRegularExpression(
        pattern: #"\b([01]?\d|2[0-3]):([0-5]\d)(?::([0-5]\d))?\b"#
    )

    // MARK: Public API

    /// Parse a single email into a transaction (debit = spend, salary/credit = income).
    /// Returns nil for non-transaction mail (OTP, promos, refunds, beneficiary-side credits).
    static func parse(text: String, from sender: String, fallbackDate: Date, source: String = "gmail") -> Transaction? {
        let lower = text.lowercased()

        // Skip OTP / promo mail.
        if lower.contains("otp") || lower.contains("one time password") { return nil }
        // Skip bill reminders, scheduled/future auto-debits, declines — not completed spends.
        if isNonTransactionNotice(lower) { return nil }
        guard let amount = firstAmount(in: text), amount > 0 else { return nil }

        // Money sent to a beneficiary is OUTGOING even when worded "credited to the beneficiary".
        let isOutgoingTransfer = lower.contains("beneficiary")
        let hasDebit = isOutgoingTransfer || debitKeywords.contains(where: lower.contains)
        let isIncome = !isOutgoingTransfer && looksLikeIncome(lower)

        // Sender match first (works for email + SMS short-codes); fall back to the body text.
        let bank = bankSenders.first { sender.lowercased().contains($0.needle) }?.bank
            ?? bankFromBody(lower) ?? "Bank"
        let date = extractDate(from: text) ?? fallbackDate

        if isIncome && !hasDebit {
            let incomeSource = extractIncomeSource(from: text) ?? (lower.contains("salary") ? "Salary" : "Credit")
            var tx = Transaction(
                date: date, amount: amount, merchant: incomeSource,
                category: .income, bank: bank, source: source,
                rawSnippet: String(text.prefix(500))
            )
            tx.kind = .income
            tx.referenceID = referenceNumber(in: text)
            return tx
        }

        guard hasDebit else { return nil }   // not a spend and not income → ignore

        var merchant = extractMerchant(from: text) ?? "Unknown"
        // Transfers (NEFT/IMPS/RTGS/UPI/standing-instruction): identify by payee so different
        // recipients are distinct parties, not all lumped under one "IMPS transfer" group.
        let isTransferLike = transferLabel(lower) != nil
            || lower.contains("standing instruction") || lower.contains("net banking si")
        if merchant == "Unknown" || merchant.lowercased().contains("beneficiary") {
            let rail = transferLabel(lower)?.replacingOccurrences(of: " transfer", with: "")
            if let payee = transferPayee(from: text) {
                merchant = rail.map { "\($0) · \(payee)" } ?? payee
            } else {
                merchant = transferLabel(lower) ?? merchant
            }
        }
        var category = categorize(merchant: merchant, fullText: lower)
        // A bank transfer to a person (SI / NEFT / IMPS) with no other category match is a transfer,
        // not "Other" or a mis-guessed spend category.
        if isTransferLike && category == .other { category = .transfer }
        var tx = Transaction(
            date: date, amount: amount, merchant: merchant,
            category: category, bank: bank, source: source,
            rawSnippet: String(text.prefix(500))
        )
        tx.kind = .expense
        tx.referenceID = referenceNumber(in: text)
        // Capture the recipient account's last 4 digits for transfers — independent of the
        // payee name, so account-tagged family members match even when a name is present.
        if category == .transfer { tx.recipientAccountLast4 = recipientLast4(from: text) }
        // A user-defined payee rule (recipient account → name + category) makes account-only
        // transfers readable, e.g. "IMPS … To A/c …1234" → "Society Maintenance" / Utilities.
        if let rule = RulesStore.shared.payeeRule(forAccountLast4: tx.recipientAccountLast4) {
            tx.merchant = rule.payee
            tx.category = rule.category
        }
        return tx
    }

    /// Names a transfer by rail when there's no readable payee, e.g. "NEFT transfer".
    private static func transferLabel(_ lower: String) -> String? {
        for rail in ["neft", "imps", "rtgs", "upi"] where lower.contains(rail) {
            return rail.uppercased() + " transfer"
        }
        return nil
    }

    /// Identifies a transfer's recipient: beneficiary name, then destination account's last
    /// 4 digits. Lets distinct payees form distinct parties while recurring ones still group.
    private static let beneficiaryNameRegex = try! NSRegularExpression(
        pattern: #"(?:beneficiary|payee)(?:\s*name)?[:\s]+([A-Za-z][A-Za-z .]{2,39}?)(?:\s+(?:on|via|ref|a/c|account|acct)\b|[.,]|$)"#,
        options: [.caseInsensitive])
    // Anchored on the *credited* side so we capture the recipient's account, not the sender's.
    // Matches "credited to the account ending xxxxxxxxxx1234", "transferred to a/c ...1234", etc.
    // Captures the whole trailing digit run so we can take its LAST 4 (a fully-numeric account
    // like "...211234" would otherwise yield its first 4 digits, not the real last 4).
    private static let payeeAccountRegex = try! NSRegularExpression(
        pattern: #"(?:credited to|transferred to|sent to|paid to|to beneficiary)\b[^0-9]{0,40}?(\d{4,})\b"#,
        options: [.caseInsensitive])
    // Recipient account in a masked "Info:" field, e.g. "Info: XXXXXXXXXX1234" (HDFC SI alerts
    // print the payee account this way, with no "credited to" wording).
    private static let infoAccountRegex = try! NSRegularExpression(
        pattern: #"\bInfo:\s*[X*x]{2,}(\d{4})\b"#)
    // Recipient account in an IMPS/NEFT "To A/c xxxxxxxxxxx1234" line.
    private static let toAccountRegex = try! NSRegularExpression(
        pattern: #"\bTo\s+A/?c\.?\s*[X*x]*(\d{4})\b"#,
        options: [.caseInsensitive])
    // Payee name in a NEFT/IMPS/RTGS Info field: "NEFT Dr-<IFSC>-<NAME>-<purpose>-…".
    private static let neftNameRegex = try! NSRegularExpression(
        pattern: #"\b(?:NEFT|IMPS|RTGS)\s+(?:Dr|Cr)-[A-Z0-9]+-([A-Za-z][A-Za-z .]{2,30}?)-"#,
        options: [.caseInsensitive])
    // Standing-instruction payee: "NET BANKING SI -Alex". Reject all-caps values, which are
    // transaction reference codes (e.g. "SI -NBIVFPJPR6JKWAYP") rather than names.
    private static let siNameRegex = try! NSRegularExpression(
        pattern: #"\bSI\s*-\s*([A-Za-z][A-Za-z]{1,18})\b"#)

    /// The recipient account's last-4 digits stated in a transfer message, or nil. Exposed so the
    /// store can match a row against a user's payee rule (and backfill the field on old rows).
    static func recipientAccountLast4(in text: String) -> String? { recipientLast4(from: text) }

    /// The destination account's last 4 digits, or nil. Used for deterministic family matching.
    private static func recipientLast4(from text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        for regex in [payeeAccountRegex, infoAccountRegex, toAccountRegex] {
            if let m = regex.firstMatch(in: text, range: range),
               let r = Range(m.range(at: 1), in: text) {
                let digits = text[r].filter(\.isNumber)
                if digits.count >= 4 { return String(digits.suffix(4)) }
            }
        }
        return nil
    }

    private static func transferPayee(from text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        if let m = beneficiaryNameRegex.firstMatch(in: text, range: range),
           let r = Range(m.range(at: 1), in: text) {
            let name = cleanMerchant(String(text[r]))
            if name.count >= 3 { return name }
        }
        // NEFT/IMPS "Dr-<IFSC>-<NAME>-…" — the recipient's printed name.
        if let m = neftNameRegex.firstMatch(in: text, range: range),
           let r = Range(m.range(at: 1), in: text) {
            let name = cleanMerchant(String(text[r]))
            if name.count >= 3 { return name }
        }
        // Standing-instruction nickname "SI -Alex" (skip all-caps ref codes).
        if let m = siNameRegex.firstMatch(in: text, range: range),
           let r = Range(m.range(at: 1), in: text) {
            let raw = String(text[r])
            if raw.count >= 3, raw != raw.uppercased() { return cleanMerchant(raw) }
        }
        if let last4 = recipientLast4(from: text) {
            return "A/c ••\(last4)"
        }
        return nil
    }

    /// A credit is treated as income only if it's a genuine inflow (salary, or credited
    /// into the user's own account) and not a refund/reversal/cashback.
    private static func looksLikeIncome(_ lower: String) -> Bool {
        if nonIncomeCredit.contains(where: lower.contains) { return false }
        // Salary almost always means an inflow, regardless of exact "credited" phrasing.
        if lower.contains("salary") { return true }
        guard creditKeywords.contains(where: lower.contains) else { return false }
        let credited = lower.contains("credited") || lower.contains("deposited")
        return credited && incomingMarkers.contains(where: lower.contains)
    }

    /// "salary from ACME", "from VPA employer@hdfc", "by ACME PAYROLL"
    private static let incomeSourcePatterns: [NSRegularExpression] = [
        #"(?:salary(?:\s+credit)?\s+(?:from|by)\s+)([A-Za-z0-9 .&\-]{3,40}?)(?:\s+on\b|\.|,|$)"#,
        #"(?:from\s+VPA\s+)([\w.\-@]+)"#,
        #"(?:from\s+)([A-Za-z][A-Za-z0-9 .&\-]{2,40}?)(?:\s+on\b|\.|,|$)"#,
        #"(?:by\s+)([A-Za-z][A-Za-z0-9 .&\-]{2,40}?)(?:\s+on\b|\.|,|$)"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    private static func extractIncomeSource(from text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        for regex in incomeSourcePatterns {
            if let m = regex.firstMatch(in: text, range: range),
               let r = Range(m.range(at: 1), in: text) {
                let raw = text[r].trimmingCharacters(in: .whitespacesAndNewlines)
                if raw.count >= 3 { return cleanMerchant(raw) }
            }
        }
        return nil
    }

    static func firstAmount(in text: String) -> Double? {
        let range = NSRange(text.startIndex..., in: text)
        guard let m = amountRegex.firstMatch(in: text, range: range),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return Double(text[r].replacingOccurrences(of: ",", with: ""))
    }

    static func extractMerchant(from text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        for regex in merchantPatterns {
            if let m = regex.firstMatch(in: text, range: range),
               let r = Range(m.range(at: 1), in: text) {
                let raw = text[r].trimmingCharacters(in: .whitespacesAndNewlines)
                if raw.count >= 3 { return cleanMerchant(raw) }
            }
        }
        return nil
    }

    static func categorize(merchant: String, fullText: String) -> SpendCategory {
        let haystack = (merchant + " " + fullText).lowercased()
        // User-defined rules win over built-ins.
        for rule in RulesStore.shared.customCategoryRules where haystack.contains(rule.keyword) {
            return rule.category
        }
        for rule in categoryRules where rule.keywords.contains(where: haystack.contains) {
            return rule.category
        }
        return .other
    }

    /// The transaction date+time stated in the message body, if any. Exposed so existing rows can
    /// be re-dated from their stored snippet (timestamp backfill).
    static func bodyDate(in text: String) -> Date? { extractDate(from: text) }

    private static func extractDate(from text: String) -> Date? {
        let range = NSRange(text.startIndex..., in: text)
        guard let m = dateRegex.firstMatch(in: text, range: range),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        let candidate = String(text[r])
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_IN")
        for fmt in dateFormats {
            f.dateFormat = fmt
            if let d = f.date(from: candidate), d <= Date() {
                // Graft the clock time the bank stated (if any) onto the parsed day.
                if let t = extractTimeOfDay(from: text),
                   let withTime = Calendar.current.date(bySettingHour: t.h, minute: t.m, second: t.s, of: d),
                   withTime <= Date() {
                    return withTime
                }
                return d
            }
        }
        return nil
    }

    /// First clock time stated in the body ("12:40:01" / "20:39"), or nil. Bank alerts carry the
    /// transaction time and no other colon-separated time, so the first match is reliable.
    private static func extractTimeOfDay(from text: String) -> (h: Int, m: Int, s: Int)? {
        let range = NSRange(text.startIndex..., in: text)
        guard let m = timeRegex.firstMatch(in: text, range: range),
              let hr = Range(m.range(at: 1), in: text).flatMap({ Int(text[$0]) }),
              let mn = Range(m.range(at: 2), in: text).flatMap({ Int(text[$0]) }) else { return nil }
        let sc = Range(m.range(at: 3), in: text).flatMap { Int(text[$0]) } ?? 0
        return (hr, mn, sc)
    }

    private static func cleanMerchant(_ raw: String) -> String {
        var name = raw
        if let at = name.firstIndex(of: "@") { name = String(name[..<at]) }   // VPA → handle
        name = name.replacingOccurrences(of: #"[*_\-]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return name.capitalized
    }
}
