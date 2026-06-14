// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import SwiftUI

extension Color {
    /// The default window/page background, cross-platform (UIKit's `systemBackground` is
    /// iOS-only; AppKit's `windowBackgroundColor` is the macOS analogue).
    static var systemBackground: Color {
        #if os(iOS)
        Color(.systemBackground)
        #elseif os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(white: 1)
        #endif
    }
}

// macOS shims for the handful of iOS-only SwiftUI modifiers the app uses, so the shared
// view code compiles unchanged on the Mac build. Each shim is a no-op (or a sensible macOS
// mapping) — they exist purely to satisfy the compiler on macOS, where these modifiers and
// placements don't exist. Compiled out entirely on iOS.
#if os(macOS)
import SwiftUI

// `.topBarLeading` / `.topBarTrailing` are iOS toolbar placements; map to the macOS equivalents.
extension ToolbarItemPlacement {
    static var topBarLeading: ToolbarItemPlacement { .navigation }
    static var topBarTrailing: ToolbarItemPlacement { .primaryAction }
}

// Stand-in for UIKit's keyboard type so `.keyboardType(.decimalPad)` etc. resolve on macOS.
enum SpendWiseKeyboardType {
    case `default`, decimalPad, emailAddress, numberPad, numbersAndPunctuation
}

// Stand-in for `TextInputAutocapitalization` so `.textInputAutocapitalization(.never)` resolves.
struct SpendWiseTextInputAutocapitalization {
    static let never = SpendWiseTextInputAutocapitalization()
    static let sentences = SpendWiseTextInputAutocapitalization()
    static let words = SpendWiseTextInputAutocapitalization()
    static let characters = SpendWiseTextInputAutocapitalization()
}

extension View {
    /// No-op on macOS (navigation bars have no inline/large distinction here).
    func navigationBarTitleDisplayMode(_ mode: NavigationBarItemTitleDisplayModeShim) -> some View { self }

    func statusBarHidden(_ hidden: Bool = true) -> some View { self }

    func keyboardType(_ type: SpendWiseKeyboardType) -> some View { self }

    func textInputAutocapitalization(_ autocap: SpendWiseTextInputAutocapitalization?) -> some View { self }

    /// macOS has no full-screen cover; present as a sheet instead.
    func fullScreenCover<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        sheet(item: item, content: content)
    }

    func fullScreenCover<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        sheet(isPresented: isPresented, content: content)
    }
}

enum NavigationBarItemTitleDisplayModeShim {
    case automatic, inline, large
}
#endif
