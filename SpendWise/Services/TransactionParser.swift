import Foundation

/// Parses transaction-alert emails from Indian banks (HDFC, ICICI, SBI, Axis, Kotak, etc.)
/// into `Transaction` values. Works on the email snippet/body text.
struct TransactionParser {

    // MARK: Amount

    /// Matches "Rs.1,234.56", "Rs 500", "INR 2,000.00", "₹350"
    private static let amountRegex = try! NSRegularExpression(
        pattern: #"(?:Rs\.?|INR|₹)\s*([\d,]+(?:\.\d{1,2})?)"#,
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
    ]

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
        (["zerodha", "groww", "upstox", "mutual fund", "sip", "nps", "ppf", "etmoney", "indmoney", "coin"], .investment),
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

    // MARK: Public API

    /// Parse a single email into a transaction (debit = spend, salary/credit = income).
    /// Returns nil for non-transaction mail (OTP, promos, refunds, beneficiary-side credits).
    static func parse(text: String, from sender: String, fallbackDate: Date) -> Transaction? {
        let lower = text.lowercased()

        // Skip OTP / promo mail.
        if lower.contains("otp") || lower.contains("one time password") { return nil }
        guard let amount = firstAmount(in: text), amount > 0 else { return nil }

        // Money sent to a beneficiary is OUTGOING even when worded "credited to the beneficiary".
        let isOutgoingTransfer = lower.contains("beneficiary")
        let hasDebit = isOutgoingTransfer || debitKeywords.contains(where: lower.contains)
        let isIncome = !isOutgoingTransfer && looksLikeIncome(lower)

        let bank = bankSenders.first { sender.lowercased().contains($0.needle) }?.bank ?? "Bank"
        let date = extractDate(from: text) ?? fallbackDate

        if isIncome && !hasDebit {
            let source = extractIncomeSource(from: text) ?? (lower.contains("salary") ? "Salary" : "Credit")
            var tx = Transaction(
                date: date, amount: amount, merchant: source,
                category: .income, bank: bank, source: "gmail",
                rawSnippet: String(text.prefix(200))
            )
            tx.kind = .income
            return tx
        }

        guard hasDebit else { return nil }   // not a spend and not income → ignore

        var merchant = extractMerchant(from: text) ?? "Unknown"
        // Transfers (NEFT/IMPS/RTGS/UPI): identify by payee so different recipients are
        // distinct parties, not all lumped under one "IMPS transfer" group.
        if merchant == "Unknown" || merchant.lowercased().contains("beneficiary") {
            let rail = transferLabel(lower)?.replacingOccurrences(of: " transfer", with: "")
            if let payee = transferPayee(from: text) {
                merchant = rail.map { "\($0) · \(payee)" } ?? payee
            } else {
                merchant = transferLabel(lower) ?? merchant
            }
        }
        let category = categorize(merchant: merchant, fullText: lower)
        var tx = Transaction(
            date: date, amount: amount, merchant: merchant,
            category: category, bank: bank, source: "gmail",
            rawSnippet: String(text.prefix(200))
        )
        tx.kind = .expense
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
    // Matches "credited to the account ending xxxxxxxxxx1466", "transferred to a/c ...1466", etc.
    private static let payeeAccountRegex = try! NSRegularExpression(
        pattern: #"(?:credited to|transferred to|sent to|paid to|to beneficiary)\b[^0-9]{0,40}?(\d{3,4})\b"#,
        options: [.caseInsensitive])

    private static func transferPayee(from text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        if let m = beneficiaryNameRegex.firstMatch(in: text, range: range),
           let r = Range(m.range(at: 1), in: text) {
            let name = cleanMerchant(String(text[r]))
            if name.count >= 3 { return name }
        }
        if let m = payeeAccountRegex.firstMatch(in: text, range: range),
           let r = Range(m.range(at: 1), in: text) {
            return "A/c ••\(text[r])"
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

    private static func extractDate(from text: String) -> Date? {
        let range = NSRange(text.startIndex..., in: text)
        guard let m = dateRegex.firstMatch(in: text, range: range),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        let candidate = String(text[r])
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_IN")
        for fmt in dateFormats {
            f.dateFormat = fmt
            if let d = f.date(from: candidate), d <= Date() { return d }
        }
        return nil
    }

    private static func cleanMerchant(_ raw: String) -> String {
        var name = raw
        if let at = name.firstIndex(of: "@") { name = String(name[..<at]) }   // VPA → handle
        name = name.replacingOccurrences(of: #"[*_\-]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return name.capitalized
    }
}
