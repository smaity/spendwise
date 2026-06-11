// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import SwiftUI

/// Single source of truth for SpendWise's product identity — name, tagline, and
/// brand colors. Reference these everywhere instead of hard-coding strings/colors so
/// the branding stays consistent.
enum Brand {
    static let name = "SpendWise"

    /// Primary positioning line — privacy-first, on-device.
    static let tagline = "Spending insights that never leave your iPhone."

    /// Mark used alongside the wordmark.
    static let symbol = "indianrupeesign.circle.fill"

    /// Primary brand accent — a teal sampled from the logo. Kept in sync with the
    /// asset-catalog AccentColor so app chrome (tab bar, controls) matches.
    static let accent = Color(red: 0.04, green: 0.60, blue: 0.53)

    /// Apple Intelligence features are accented in purple to set them apart.
    static let ai = Color.purple
}

/// The SpendWise logo (the app-icon artwork) as a rounded badge, for use inside the app.
struct BrandLogo: View {
    var size: CGFloat = 28

    var body: some View {
        Image("BrandLogo")
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            )
            .accessibilityLabel("\(Brand.name) logo")
    }
}

/// Logo paired with the SpendWise wordmark.
struct BrandWordmark: View {
    var logoSize: CGFloat = 30

    var body: some View {
        HStack(spacing: 8) {
            BrandLogo(size: logoSize)
            Text(Brand.name)
                .font(.title3.weight(.bold))
        }
    }
}

extension Brand {
    /// Brand gradient, sampled from the app icon (so the logo blends into it).
    static let gradient = LinearGradient(
        colors: [Color(red: 0.10, green: 0.35, blue: 0.36),
                 Color(red: 0.07, green: 0.55, blue: 0.49)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}

/// Branded splash shown briefly at launch (over the system launch screen).
struct SplashView: View {
    var body: some View {
        ZStack {
            Brand.gradient.ignoresSafeArea()
            VStack(spacing: 18) {
                BrandLogo(size: 112)
                    .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
                VStack(spacing: 6) {
                    Text(Brand.name)
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(.white)
                    Text(Brand.tagline)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                }
            }
            .padding(40)
        }
    }
}
