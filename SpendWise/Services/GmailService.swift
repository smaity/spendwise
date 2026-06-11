// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import Foundation
import AuthenticationServices
import Security
import UIKit

/// A connected Gmail account (one per family member).
struct GmailAccount: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var email: String
    var label: String     // display name shown in the app, editable
}

/// Google OAuth (PKCE, no client secret) + Gmail readonly fetch.
/// Supports multiple accounts — each family member connects their own Gmail.
/// Setup: create an iOS OAuth Client ID in Google Cloud Console and paste it below — see README.
final class GmailService: NSObject, ObservableObject {

    // OAuth client ID lives in the untracked Secrets.swift (see Secrets.swift.example).
    static let clientID = AppSecrets.googleClientID

    /// Reversed client ID — Google's required redirect scheme for iOS clients.
    private var redirectScheme: String {
        Self.clientID.split(separator: ".").reversed().joined(separator: ".")
    }
    private var redirectURI: String { "\(redirectScheme):/oauth2redirect" }

    @Published var accounts: [GmailAccount] = []

    var isConnected: Bool { !accounts.isEmpty }

    private static let accountsKey = "gmail_accounts"

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: Self.accountsKey),
           let decoded = try? JSONDecoder().decode([GmailAccount].self, from: data) {
            accounts = decoded
        }
    }

    private func saveAccounts() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: Self.accountsKey)
        }
    }

    enum GmailError: LocalizedError {
        case notConfigured, authFailed(String), tokenExpired(String), api(String)
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Add your Google OAuth Client ID in GmailService.swift (see README)."
            case .authFailed(let m): return "Google sign-in failed: \(m)"
            case .tokenExpired(let email): return "Session expired for \(email) — reconnect in Settings."
            case .api(let m): return "Gmail API error: \(m)"
            }
        }
    }

    // MARK: - OAuth

    /// Runs the OAuth flow and adds the signed-in account. Call again to add more family members.
    @MainActor
    func connectAccount() async throws {
        guard !Self.clientID.hasPrefix("YOUR_") else { throw GmailError.notConfigured }

        let verifier = PKCE.randomVerifier()
        let challenge = PKCE.challenge(for: verifier)

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: Self.clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "https://www.googleapis.com/auth/gmail.readonly openid email"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent select_account"),   // always offer account chooser
        ]

        let callbackURL: URL = try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(url: comps.url!, callbackURLScheme: redirectScheme) { url, error in
                if let url { cont.resume(returning: url) }
                else { cont.resume(throwing: GmailError.authFailed(error?.localizedDescription ?? "cancelled")) }
            }
            session.presentationContextProvider = self
            // Ephemeral so each family member gets a fresh Google login screen.
            session.prefersEphemeralWebBrowserSession = true
            session.start()
        }

        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            throw GmailError.authFailed("no authorization code returned")
        }

        // Exchange code → tokens.
        let token: TokenResponse = try await postToken(body: formEncode([
            "client_id": Self.clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ]))

        // Whose mailbox is this?
        let email = try await fetchEmail(accessToken: token.access_token)

        if let existing = accounts.first(where: { $0.email == email }) {
            // Re-connect: refresh stored tokens.
            Keychain.write(accessKey(existing), token.access_token)
            if let r = token.refresh_token { Keychain.write(refreshKey(existing), r) }
        } else {
            let label = email.split(separator: "@").first.map { String($0).capitalized } ?? email
            let account = GmailAccount(email: email, label: label)
            Keychain.write(accessKey(account), token.access_token)
            if let r = token.refresh_token { Keychain.write(refreshKey(account), r) }
            accounts.append(account)
            saveAccounts()
        }
    }

    func disconnect(_ account: GmailAccount) {
        Keychain.delete(accessKey(account))
        Keychain.delete(refreshKey(account))
        accounts.removeAll { $0.id == account.id }
        saveAccounts()
    }

    func rename(_ account: GmailAccount, to label: String) {
        guard let i = accounts.firstIndex(where: { $0.id == account.id }),
              !label.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        accounts[i].label = label
        saveAccounts()
    }

    func label(forEmail email: String) -> String? {
        accounts.first { $0.email == email }?.label
    }

    private func accessKey(_ a: GmailAccount) -> String { "gmail_access_\(a.id.uuidString)" }
    private func refreshKey(_ a: GmailAccount) -> String { "gmail_refresh_\(a.id.uuidString)" }

    private func fetchEmail(accessToken: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        struct UserInfo: Decodable { let email: String? }
        guard let email = (try? JSONDecoder().decode(UserInfo.self, from: data))?.email else {
            throw GmailError.api("could not read account email")
        }
        return email.lowercased()
    }

    private func refreshAccessToken(for account: GmailAccount) async throws {
        guard let refresh = Keychain.read(refreshKey(account)) else {
            throw GmailError.tokenExpired(account.email)
        }
        let token: TokenResponse = try await postToken(body: formEncode([
            "client_id": Self.clientID,
            "refresh_token": refresh,
            "grant_type": "refresh_token",
        ]))
        Keychain.write(accessKey(account), token.access_token)
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
    }

    private func postToken(body: Data) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw GmailError.api(String(data: data, encoding: .utf8) ?? "token exchange failed")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func formEncode(_ params: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return params.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: allowed) ?? $1)" }
            .joined(separator: "&").data(using: .utf8)!
    }

    // MARK: - Gmail fetch

    /// Fetches bank-alert emails for ALL connected accounts; each transaction is
    /// tagged with the account email so spending can be segregated per member.
    func fetchTransactions(daysBack: Int) async throws -> [Transaction] {
        var all: [Transaction] = []
        var errors: [String] = []
        for account in accounts {
            do {
                all += try await fetchTransactions(for: account, daysBack: daysBack)
            } catch {
                errors.append("\(account.label): \(error.localizedDescription)")
            }
        }
        if all.isEmpty, let first = errors.first { throw GmailError.api(first) }
        return all
    }

    /// Built-in bank alert senders (shown read-only in the in-app Rules editor).
    static let builtinSenders = [
        "alerts@hdfcbank.net", "alerts@hdfcbank.bank.in", "hdfcbankbillpay@billdesk.in",
        "alerts@icicibank.com", "alerts@sbi.co.in", "alerts@axisbank.com",
        "noreply@kotak.com", "bankalerts@kotak.com", "transaction.alerts@idfcfirstbank.com",
    ]
    private static let keywordClause = #"(debited OR spent OR "txn" OR credited OR salary OR deposited)"#

    /// Sender + keyword filter shared by every transaction query. Includes the user's
    /// custom senders from the in-app Rules editor.
    private var bankFilter: String {
        let senders = (Self.builtinSenders + RulesStore.shared.customSenders).joined(separator: " OR ")
        return "from:(\(senders)) \(Self.keywordClause)"
    }

    /// Gmail's `after:`/`before:` operators expect yyyy/MM/dd in a fixed locale.
    private static let gmailDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy/MM/dd"
        return f
    }()

    func fetchTransactions(for account: GmailAccount, daysBack: Int) async throws -> [Transaction] {
        try await fetchTransactions(for: account, query: "\(bankFilter) newer_than:\(daysBack)d")
    }

    /// Fetches a single date window `[after, before)` — used for month-by-month historical import,
    /// which keeps each query well under Gmail's result cap.
    func fetchTransactions(for account: GmailAccount, after: Date, before: Date) async throws -> [Transaction] {
        let a = Self.gmailDateFormatter.string(from: after)
        let b = Self.gmailDateFormatter.string(from: before)
        return try await fetchTransactions(for: account, query: "\(bankFilter) after:\(a) before:\(b)")
    }

    private func fetchTransactions(for account: GmailAccount, query: String) async throws -> [Transaction] {
        let ids = try await listMessageIDs(query: query, account: account)
        var result: [Transaction] = []
        for id in ids.prefix(200) {
            if let msg = try? await getMessage(id: id, account: account),
               var tx = TransactionParser.parse(text: msg.text, from: msg.sender, fallbackDate: msg.date) {
                tx.account = account.email
                tx.sourceID = id          // stable Gmail message id → idempotent de-dupe
                result.append(tx)
            }
        }
        return result
    }

    private struct GmailMessage { let text: String; let sender: String; let date: Date }

    private func listMessageIDs(query: String, account: GmailAccount) async throws -> [String] {
        var ids: [String] = []
        var pageToken: String?
        repeat {
            var comps = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
            comps.queryItems = [
                .init(name: "q", value: query),
                .init(name: "maxResults", value: "100"),
            ]
            if let pageToken { comps.queryItems?.append(.init(name: "pageToken", value: pageToken)) }
            let data = try await authorizedGET(comps.url!, account: account)
            struct ListResp: Decodable {
                struct Ref: Decodable { let id: String }
                let messages: [Ref]?
                let nextPageToken: String?
            }
            let resp = try JSONDecoder().decode(ListResp.self, from: data)
            ids += (resp.messages ?? []).map(\.id)
            pageToken = resp.nextPageToken
        } while pageToken != nil && ids.count < 300
        return ids
    }

    private struct MsgResp: Decodable {
        struct Header: Decodable { let name: String; let value: String }
        struct Body: Decodable { let data: String? }
        struct Part: Decodable { let mimeType: String?; let body: Body?; let parts: [Part]? }
        let snippet: String?
        let internalDate: String?
        let payload: Part?

        private enum CodingKeys: String, CodingKey { case snippet, internalDate, payload }
        // `payload` has the same shape as Part plus headers:
        struct PayloadHeaders: Decodable { let headers: [Header]? }
        var headers: [Header]? { _headers }
        private var _headers: [Header]?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            snippet = try c.decodeIfPresent(String.self, forKey: .snippet)
            internalDate = try c.decodeIfPresent(String.self, forKey: .internalDate)
            payload = try c.decodeIfPresent(Part.self, forKey: .payload)
            _headers = try c.decodeIfPresent(PayloadHeaders.self, forKey: .payload)?.headers
        }
    }

    private func getMessage(id: String, account: GmailAccount) async throws -> GmailMessage {
        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)?format=full")!
        let data = try await authorizedGET(url, account: account)
        let msg = try JSONDecoder().decode(MsgResp.self, from: data)

        let sender = msg.headers?.first { $0.name.lowercased() == "from" }?.value ?? ""
        let date = (msg.internalDate.flatMap(Double.init)).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()

        // Prefer decoded text/plain body; fall back to snippet.
        var text = msg.snippet ?? ""
        if let body = Self.findPlainText(in: msg.payload), body.count > text.count {
            text = body
        }
        return GmailMessage(text: text, sender: sender, date: date)
    }

    private static func findPlainText(in part: MsgResp.Part?) -> String? {
        guard let part else { return nil }
        if part.mimeType == nil || part.mimeType == "text/plain",
           let d = part.body?.data, let s = decodeBase64URL(d), !s.isEmpty {
            return s
        }
        for child in part.parts ?? [] {
            if let found = findPlainText(in: child) { return found }
        }
        return nil
    }

    private static func decodeBase64URL(_ s: String) -> String? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func authorizedGET(_ url: URL, account: GmailAccount, retried: Bool = false) async throws -> Data {
        guard let token = Keychain.read(accessKey(account)) else {
            throw GmailError.tokenExpired(account.email)
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401, !retried {
            try await refreshAccessToken(for: account)
            return try await authorizedGET(url, account: account, retried: true)
        }
        guard status == 200 else {
            throw GmailError.api("HTTP \(status)")
        }
        return data
    }
}

// MARK: - ASWebAuthenticationSession presentation

extension GmailService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}

// MARK: - PKCE helpers

import CryptoKit

enum PKCE {
    static func randomVerifier() -> String {
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        return String((0..<64).map { _ in chars.randomElement()! })
    }
    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Minimal Keychain wrapper

enum Keychain {
    static func write(_ key: String, _ value: String) {
        delete(key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(query as CFDictionary, nil)
    }
    static func read(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
