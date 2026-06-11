// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import SwiftUI
import LocalAuthentication

/// Optional biometric app lock. When enabled, the UI is hidden behind `LockView` until the
/// user authenticates with Face ID / Touch ID (falling back to the device passcode), and it
/// re-locks whenever the app goes to the background.
@MainActor
final class AppLock: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published var isUnlocked: Bool
    private var isAuthenticating = false

    private static let key = "app_lock_enabled"

    init() {
        let on = UserDefaults.standard.bool(forKey: Self.key)
        enabled = on
        isUnlocked = !on            // if the lock is off, the app is open
    }

    /// Whether the lock overlay should currently be shown.
    var isLocked: Bool { enabled && !isUnlocked }

    var biometryType: LABiometryType {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return ctx.biometryType
    }

    var biometryLabel: String {
        switch biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "device passcode"
        }
    }

    var biometryIcon: String {
        switch biometryType {
        case .faceID: return "faceid"
        case .touchID, .opticID: return "touchid"
        default: return "lock.fill"
        }
    }

    /// Turn the lock on/off. Enabling immediately challenges so the user confirms it works.
    func setEnabled(_ on: Bool) {
        guard on else { enabled = false; isUnlocked = true; persist(); return }
        // Only enable if the device can actually authenticate (passcode set).
        var error: NSError?
        guard LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return }
        enabled = true
        isUnlocked = false
        persist()
        authenticate()
    }

    /// Re-lock (called when the app backgrounds).
    func lock() { if enabled { isUnlocked = false } }

    /// Prompt for biometrics / passcode. No-op if disabled, already unlocked, or in progress.
    func authenticate() {
        guard enabled, !isUnlocked, !isAuthenticating else { return }
        isAuthenticating = true
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Use Passcode"
        ctx.evaluatePolicy(.deviceOwnerAuthentication,
                           localizedReason: "Unlock SpendWise to view your finances") { success, _ in
            Task { @MainActor in
                self.isAuthenticating = false
                if success { self.isUnlocked = true }
            }
        }
    }

    private func persist() { UserDefaults.standard.set(enabled, forKey: Self.key) }
}

/// Full-screen cover shown while the app is locked.
struct LockView: View {
    @EnvironmentObject var appLock: AppLock

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 18) {
                BrandLogo(size: 76)
                    .shadow(color: Brand.accent.opacity(0.3), radius: 12, y: 6)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "lock.fill")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(Brand.accent, in: Circle())
                            .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 2))
                            .offset(x: 6, y: 6)
                    }
                VStack(spacing: 4) {
                    Text("\(Brand.name) is locked").font(.headline)
                    Text(Brand.tagline)
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button {
                    appLock.authenticate()
                } label: {
                    Label("Unlock", systemImage: appLock.biometryIcon)
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .onAppear { appLock.authenticate() }
    }
}
